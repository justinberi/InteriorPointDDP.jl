struct Constraint{T, J}
    evaluate
    jacobian
    second_order
    num_constraint::Int
    num_state::Int
    num_action::Int
    evaluate_cache::Vector{T}
    jacobian_cache::J
    second_order_cache::Matrix{T}
    indices_compl::Vector{Int}
end

Constraints{T, J} = Vector{Constraint{T, J}} where {T, J}

function Constraint(f::Function, num_constraint::Int, num_state::Int, num_action::Int; indices_compl=nothing)
    f_knot = z -> f(z[1:num_state], z[num_state+1:end])
    eval_cache = zeros(num_constraint)
    f_ip! = (res, x, u) -> res .= f(x, u) 

    res_jac = DiffResults.JacobianResult(zeros(num_constraint), zeros(num_state + num_action))
    cfg_jac = ForwardDiff.JacobianConfig(f_knot, zeros(num_state + num_action))
    f_jac! = (res, x, u) -> ForwardDiff.jacobian!(res, f_knot, [x; u], cfg_jac)

    second_order_cache = zeros(num_state + num_action, num_state + num_action)
    second_order! = (cache, x, u, v) -> ForwardDiff.jacobian!(cache, z -> ForwardDiff.jacobian(f_knot, z)' * v, [x; u])

    indices_compl = isnothing(indices_compl) ? Int64[] : indices_compl 

    return Constraint(
        f_ip!, f_jac!, second_order!,
        num_constraint, num_state, num_action,
        eval_cache, res_jac, second_order_cache,
        indices_compl)
end

function Constraint(f::Function, num_state::Int, num_action::Int; indices_compl=nothing)
    num_constraint = length(f(zeros(num_state), zeros(num_action)))
    return Constraint(f, num_constraint, num_state, num_action; indices_compl=indices_compl)
end

function Constraint()
    return Constraint(
        (c, x, u) -> nothing, (j, x, u) -> nothing, (h, x, u, v) -> nothing,
        0, 0, 0, 
        Float64[], Array{Float64}(undef, 0, 0), Array{Float64}(undef, 0, 0),
        Int64[])
end

function Constraint(f::Function, fz::Function, num_constraint::Int, num_state::Int, num_action::Int;
    indices_compl=nothing, vfyy::Function=nothing)

    return Constraint(
        f, fz, vfyy,
        num_constraint, num_state, num_action, 
        zeros(num_constraint), zeros(num_constraint, num_state + num_action),
        zeros(num_state + num_action, num_state + num_action),
        indices_compl)
end

function jacobian!(jacobian_states, jacobian_actions, constraints::Constraints{T}, states, actions) where T
    for (k, con) in enumerate(constraints)
        con.num_constraint == 0 && continue
        num_state = length(states[k])
        con.jacobian(con.jacobian_cache, states[k], actions[k])
        @views jacobian_states[k] .= DiffResults.jacobian(con.jacobian_cache)[:, 1:num_state]
        @views jacobian_actions[k] .= DiffResults.jacobian(con.jacobian_cache)[:, num_state+1:end]
    end
end

function second_order_contraction!(hessian_prod_state_state, hessian_prod_action_state, hessian_prod_action_action,
    constraint::Union{Dynamics{T}, Constraint{T}}, states, actions, lhs_vector) where T
    if !isnothing(constraint.second_order)
        num_state = length(states)
        constraint.second_order(constraint.second_order_cache, states, actions, lhs_vector)
        @views hessian_prod_state_state .= constraint.second_order_cache[1:num_state, 1:num_state]
        @views hessian_prod_action_state .= constraint.second_order_cache[num_state+1:end, 1:num_state]
        @views hessian_prod_action_action .= constraint.second_order_cache[num_state+1:end, num_state+1:end]
    end
end

