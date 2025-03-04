function forward_pass!(policy::PolicyData{T}, problem::ProblemData{T}, data::SolverData{T},
            options::Options{T}; verbose=false) where T
    data.l = 0  # line search iteration counter
    data.status = 0
    data.step_size = T(1.0)
    Δφ = T(0.0)
    μ = data.μ
    τ = max(options.τ_min, T(1.0) - μ)

    θ_prev = data.primal_1_curr
    φ_prev = data.barrier_obj_curr
    θ = θ_prev

    Δφ_L, Δφ_Q = expected_decrease_cost(policy, problem, data.step_size)
    Δφ = Δφ_L + Δφ_Q
    min_step_size = estimate_min_step_size(Δφ_L, data, options)

    while data.step_size >= min_step_size
        α = data.step_size
        try
            rollout!(policy, problem, step_size=α; mode=:main)
        catch e
            # reduces step size if NaN or Inf encountered
            e isa DomainError && (data.step_size *= 0.5, continue)
            rethrow(e)
        end
        constraint!(problem, data.μ; mode=:current)
        
        data.status = check_fraction_boundary(problem, τ)
        # println("boundary failed")
        data.status != 0 && (data.step_size *= 0.5, continue)

        Δφ_L, Δφ_Q = expected_decrease_cost(policy, problem, α; mode=:main)
        Δφ = Δφ_L + Δφ_Q
        
        # used for sufficient decrease from current iterate step acceptance criterion
        θ = constraint_violation_1norm(problem, mode=:current)
        φ = barrier_objective!(problem, data, mode=:current)
        
        # check acceptability to filter
        data.status = !any(x -> all([θ, φ] .>= x), data.filter) ? 0 : 3
        # println("filter ", data.k, " ", data.status, " ", α, " ", θ, " ", φ, " ", μ)
        # println(data.filter)
        data.status != 0 && (data.step_size *= 0.5, data.l += 1, continue)  # failed, reduce step size
        
        # check for sufficient decrease conditions for the barrier objective/constraint violation
        data.switching = (Δφ < 0.0) && 
            ((-Δφ) ^ options.s_φ * α^(1-options.s_φ)  > options.δ * θ_prev ^ options.s_θ)
        # println("switch ", data.switching, " ", θ_prev, " ", -Δφ, " ", min_step_size)
        data.armijo_passed = φ - φ_prev - 10. * eps(Float64) * abs(φ_prev) <= options.η_φ * Δφ
        # println("armijo ", data.armijo_passed, " ", θ <= data.min_primal_1, " ", φ - φ_prev, " ", Δφ, " ", data.step_size)
        if (θ <= data.min_primal_1) && data.switching
            data.status = data.armijo_passed ? 0 : 4  #  sufficient decrease of barrier objective
        else
            suff = (θ <= (1. - options.γ_θ) * θ_prev) || (φ <= φ_prev - options.γ_φ * θ_prev)
            # println("suff ", θ, " ", (1. - options.γ_θ) * θ_prev, " ", φ, " ", φ_prev - options.γ_φ * θ_prev)
            data.status = suff ? 0 : 5
        end
        data.status != 0 && (data.step_size *= 0.5, data.l += 1, continue)  # failed, reduce step size
        
        data.barrier_obj_next = φ
        data.primal_1_next = θ
        break
    end
    data.step_size < min_step_size && (data.status = 7)
    data.status != 0 && (verbose && (@warn "Line search failed to find a suitable iterate"))
end

function check_fraction_boundary(problem::ProblemData{T}, τ::T) where T
    N = problem.horizon

    u = problem.controls
    ū = problem.nominal_controls
    vl = problem.ineq_duals_lo
    vu = problem.ineq_duals_up
    vl̄ = problem.nominal_ineq_duals_lo
    vū = problem.nominal_ineq_duals_up

    bounds = problem.bounds

    status = 0
    for t = 1:N-1
        bk = bounds[t]
        il = bk.indices_lower
        iu = bk.indices_upper
        # TODO: copying, slow: improve
        # equivalent to u - ul < (ū - ul) * (1 - τ)
        if any(u[t][il] - bk.lower[il] .* τ .< ū[t][il] .* (1. - τ))
            status = 2
            break
        end
        # equivalent to uu - u < (uu - ū) * (1 - τ)
        if any(u[t][iu] - bk.upper[iu] .* τ .> ū[t][iu] .* (1. - τ))
            status = 2
            break
        end

        if any(vl[t][il] .< vl̄[t][il] .* (1. - τ))
            status = 2
            break
        end
        if any(vu[t][iu] .< vū[t][iu] .* (1. - τ))
            status = 2
            break
        end
    end
    return status
end

function estimate_min_step_size(Δφ_L::T, data::SolverData{T}, options::Options{T}) where T
    # compute minimum step size based on linear models of step acceptance conditions
    θ_min = data.min_primal_1
    θ = data.primal_1_curr
    γ_θ = options.γ_θ
    γ_α = options.γ_α
    γ_φ = options.γ_φ
    s_θ = options.s_θ
    s_φ = options.s_φ
    δ = options.δ
    if Δφ_L < 0.0 && θ <= θ_min
        min_step_size = min(γ_θ, -γ_φ * θ / Δφ_L, δ * θ ^ s_θ / (-Δφ_L) ^ s_φ)
    elseif Δφ_L < 0.0 && θ > θ_min
        min_step_size = min(γ_θ, -γ_φ * θ / Δφ_L)
    else
        min_step_size = γ_θ
    end
    min_step_size *= γ_α
    min_step_size = max(min_step_size, eps(Float64))
    return min_step_size
end

function expected_decrease_cost(policy::PolicyData{T}, problem::ProblemData{T}, step_size::T; mode=:main) where T
    Δφ_L = T(0.0)
    Δφ_Q = T(0.0)
    N = problem.horizon
    Qu = policy.hamiltonian.gradient_control
    Quu = policy.hamiltonian.hessian_control_control
    gains = mode == :main ? policy.gains_main : policy.gains_soc
    
    for t = N-1:-1:1
        Δφ_L += dot(Qu[t], gains.ku[t])
        Δφ_Q += 0.5 * dot(gains.ku[t], Quu[t], gains.ku[t])
    end
    return Δφ_L * step_size, Δφ_Q * step_size^2
end

