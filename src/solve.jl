# function solve!(solver::Solver{T,N,M,NN,MM,MN,NNN,MNN,X,U,D,O}, args...; kwargs...) where {T,N,M,NN,MM,MN,NNN,MNN,X,U,D,O<:Costs{T}}
#     ipddp_solve!(solver, args...; kwargs...)
# end

function solve!(solver::Solver{T}, args...; kwargs...) where T
    solve!(solver, args...; kwargs...)
end

function solve!(solver::Solver{T}, x1::Vector{T}, controls::Vector{Vector{T}}; kwargs...) where T
    initialize_trajectory!(solver, controls, x1)
    solve!(solver; kwargs...)
end

function solve!(solver::Solver{T}) where T
    (solver.options.verbose && solver.data.k==0) && solver_info()
	
	policy = solver.policy
    problem = solver.problem
    options = solver.options
	data = solver.data
    
    reset!(problem.model)
    reset!(problem.cost_data)
    reset!(data)
    reset_duals!(problem)  # TODO: initialize better, wrap up with initialization of problem data
    
    # automatically select initial perturbation. loosely based on bound of CS condition (duality) for LPs
    cost!(data, problem, mode=:nominal)
    data.μ = options.μ_init

    constraint!(problem, data.μ; mode=:nominal)
    
    # update performance measures for first iterate (req. for sufficient decrease conditions for step acceptance)
    data.primal_1_curr = constraint_violation_1norm(problem, mode=:nominal)
    data.barrier_obj_curr = barrier_objective!(problem, data, mode=:nominal)
    
    # filter initialization for constraint violation and threshold for switching rule init. (step acceptance)
    data.max_primal_1 = 1e4 * max(1.0, data.primal_1_curr)
    data.min_primal_1 = 1e-4 * max(1.0, data.primal_1_curr)
    reset_filter!(data)

    while data.k < options.max_iterations
        iter_time = @elapsed begin
            evaluate_derivatives!(problem, mode=:nominal)
            
            backward_pass!(policy, problem, data, options, mode=:nominal, verbose=options.verbose)
            data.status != 0 && break
            # check (outer) overall problem convergence

            data.dual_inf, data.primal_inf, data.cs_inf = optimality_error(policy, problem, options, T(0.0), mode=:nominal)
            opt_err_0 = max(data.dual_inf, data.cs_inf, data.primal_inf)
            
            opt_err_0 <= options.optimality_tolerance && break
            
            # check (inner) barrier problem convergence and update barrier parameter if so
            dual_inf_μ, primal_inf_μ, cs_inf_μ = optimality_error(policy, problem, options, data.μ, mode=:nominal)
            opt_err_μ = max(dual_inf_μ, cs_inf_μ, primal_inf_μ)          
            if opt_err_μ <= options.κ_ϵ * data.μ
                data.μ = max(options.optimality_tolerance / 10.0, min(options.κ_μ * data.μ, data.μ ^ options.θ_μ))
                reset_filter!(data)
                # performance of current iterate updated to account for barrier parameter change
                constraint!(problem, data.μ; mode=:nominal)
                data.barrier_obj_curr = barrier_objective!(problem, data, mode=:nominal)
                data.primal_1_curr = constraint_violation_1norm(problem, mode=:nominal)
                data.j += 1
                continue
            end
            
            options.verbose && iteration_status(data, options)
            data.p = 0
            
            forward_pass!(policy, problem, data, options, verbose=options.verbose)
            data.status != 0 && break
            
            rescale_duals!(problem, data.μ, options)
            update_nominal_trajectory!(problem)
            (!data.armijo_passed && !data.switching) && update_filter!(data, options)
            data.barrier_obj_curr = data.barrier_obj_next
            data.primal_1_curr = data.primal_1_next
        end
        
        data.k += 1
        data.wall_time += iter_time
    end
    
    options.verbose && iteration_status(data, options)
    if data.k == options.max_iterations 
        data.status = 8
        options.verbose && @warn "Maximum solver iterations reached."
    end
    return nothing
end

function update_filter!(data::SolverData{T}, options::Options{T}) where T
    new_filter_pt = [(1. - options.γ_θ) * data.primal_1_curr,
                        data.barrier_obj_curr - options.γ_φ * data.primal_1_curr]
    push!(data.filter, new_filter_pt)
end

function reset_filter!(data::SolverData{T}) where T
    empty!(data.filter)
    push!(data.filter, [data.max_primal_1, T(-Inf)])
    data.status = 0
end

function optimality_error(policy::PolicyData{T}, problem::ProblemData{T},
            options::Options{T}, μ::T; mode=:nominal) where T
    dual_inf::T = 0     # dual infeasibility (stationarity of Lagrangian)
    primal_inf::T = 0   # constraint violation (primal infeasibility)
    cs_inf::T = 0       # complementary slackness violation
    ϕ_norm::T = 0       # norm of dual equality
    v_norm::T = 0       # norm of dual inequality
    
    N = problem.horizon
    bounds = problem.bounds
    h = mode == :nominal ? problem.nominal_constraints : problem.constraints
    u = mode == :nominal ? problem.nominal_controls : problem.controls
    ϕ, vl, vu = dual_trajectories(problem, mode=mode)
    
    Qu = policy.hamiltonian.gradient_control
    hu = problem.constraints_data.jacobian_control

    num_ineq = 0
    num_constr = problem.constraints_data.num_constraints[1]
    
    for t = N-1:-1:1
        bk = bounds[t]
        num_ineq += bk.num_lower + bk.num_upper

        # dual infeasibility (stationarity)

        policy.u_tmp[t] .= Qu[t]
        mul!(policy.u_tmp[t], transpose(hu[t]), ϕ[t], 1.0, 1.0)
        dual_inf = max(dual_inf, norm(policy.u_tmp[t], Inf))
        ϕ_norm += norm(ϕ[t], 1)

        # primal feasibility (eq. constraint satisfcontrol)

        primal_inf = max(primal_inf, norm(h[t], Inf))

        # complementary slackness

        (bk.num_upper == 0 && bk.num_lower == 0) && continue
        vlk = vl[t][bk.indices_lower]
        vuk = vu[t][bk.indices_upper]
        # TODO: slow, copies
        cs_inf = max(cs_inf, norm((u[t][bk.indices_lower] - bk.lower[bk.indices_lower])
                    .* vlk, Inf))
        cs_inf = max(cs_inf, norm((bk.upper[bk.indices_upper] - u[t][bk.indices_upper])
                    .* vuk, Inf))
        v_norm += sum(vlk)
        v_norm += sum(vuk)
    end
    cs_inf -= μ
    
    scaling_cs = max(options.s_max, v_norm / max(num_ineq, 1.0))  / options.s_max
    scaling_dual = max(options.s_max, (ϕ_norm + v_norm) / max(num_ineq + num_constr, 1.0))  / options.s_max
    return dual_inf / scaling_dual, primal_inf, cs_inf / scaling_cs
end

function rescale_duals!(problem::ProblemData{T}, μ::T, options::Options{T}; mode=:nominal) where T
    N = problem.horizon
    κ_Σ = options.κ_Σ
    u = mode == :nominal ? problem.nominal_controls : problem.num_controls
    bounds = problem.bounds
    _, vl, vu = dual_trajectories(problem, mode=mode)
    for t = 1:N-1
        bk = bounds[t]

        vlk = vl[t][bk.indices_lower]
        ilk = u[t][bk.indices_lower] - bk.lower[bk.indices_lower]
        vlk .= max.(min.(vlk, κ_Σ * μ ./ ilk), μ ./ (κ_Σ *  ilk))

        vuk = vu[t][bk.indices_upper]
        iuk = bk.upper[bk.indices_upper] - u[t][bk.indices_upper]
        vuk .= max.(min.(vuk, κ_Σ * μ ./ iuk), μ ./ (κ_Σ *  iuk))
    end
end

function reset_duals!(problem::ProblemData{T}) where T
    N = problem.horizon
    bounds = problem.bounds
    for t = 1:N-1
        fill!(problem.eq_duals[t], 0.0)
        fill!(problem.nominal_eq_duals[t], 0.0)
        fill!(problem.ineq_duals_lo[t], 0.0)
        fill!(problem.nominal_ineq_duals_lo[t], 0.0)
        fill!(problem.ineq_duals_up[t], 0.0)
        fill!(problem.nominal_ineq_duals_up[t], 0.0)
        problem.ineq_duals_lo[t][bounds[t].indices_lower].= 1.0
        problem.ineq_duals_up[t][bounds[t].indices_upper] .= 1.0
        problem.nominal_ineq_duals_lo[t][bounds[t].indices_lower] .= 1.0
        problem.nominal_ineq_duals_up[t][bounds[t].indices_upper] .= 1.0
    end
end

