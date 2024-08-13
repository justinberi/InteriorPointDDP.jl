function cost(problem::ProblemData; mode=:nominal)
    if mode == :nominal
        return cost(problem.costs.costs, problem.nominal_states, problem.nominal_actions)
    elseif mode == :current
        return cost(problem.costs.costs, problem.states, problem.actions)
    else 
        return 0.0 
    end
end

function cost!(data::SolverData, problem::ProblemData; mode=:nominal)
	if mode == :nominal
		data.objective = cost(problem.cost_data.costs, problem.nominal_states, problem.nominal_actions)
	elseif mode == :current
		data.objective = cost(problem.cost_data.costs, problem.states, problem.actions)
	end
	return data.objective
end

function constraint!(problem::ProblemData; mode=:nominal)
    constr_data = problem.constr_data
    states, actions = primal_trajectories(problem, mode=mode)
    constr_traj = mode == :nominal ? problem.nominal_constraints : problem.constraints
    ineq_lo_traj = mode == :nominal ? problem.nominal_ineq_lower : problem.ineq_lower
    ineq_up_traj = mode == :nominal ? problem.nominal_ineq_upper : problem.ineq_upper
    for (k, con) in enumerate(constr_data.constraints)
        if con.num_constraint > 0
            con.evaluate(con.evaluate_cache, states[k], actions[k])
            constr_traj[k] .= con.evaluate_cache
        end
        evaluate_ineq_lower!(ineq_lo_traj[k], actions[k], con.bounds_lower)
        evaluate_ineq_upper!(ineq_up_traj[k], actions[k], con.bounds_upper)
    end
end

function evaluate_ineq_lower!(res, actions, bound)
    m = length(actions)
    for i = 1:m
        res[i] = isinf(bound[i]) ? Inf : actions[i] - bound[i]
    end
end

function evaluate_ineq_upper!(res, actions, bound)
    m = length(actions)
    for i = 1:m
        res[i] = isinf(bound[i]) ? Inf : bound[i] - actions[i]
    end
end

function barrier_objective!(problem::ProblemData, data::SolverData; mode=:nominal)
    N = problem.horizon
    constr_data = problem.constr_data
    _, _, h, il, iu = primal_trajectories(problem, mode=mode)
    ϕ = mode == :nominal ? problem.nominal_eq_duals : problem.eq_duals
    
    barrier_obj = 0.
    for k = 1:N-1
        constr = constr_data.constraints[k]
        for i = 1:constr.num_action
            if !isinf(il[k][i])
                barrier_obj -= log(il[k][i])
            end
            if !isinf(iu[k][i])
                barrier_obj -= log(iu[k][i])
            end
        end
    end
    
    barrier_obj *= data.μ
    cost!(data, problem, mode=mode)
    barrier_obj += data.objective
    return barrier_obj
end

function constraint_violation_1norm(problem::ProblemData; mode=:nominal)
    _, _, h, _, _ = primal_trajectories(problem, mode=mode)
    constr_violation = 0.
    for hk in h
        constr_violation += norm(hk, 1)
    end
    return constr_violation
end

function update_nominal_trajectory!(data::ProblemData; resto=false) 
    N = data.horizon
    for k = 1:N
        data.nominal_states[k] .= data.states[k]
        k == N && continue
        data.nominal_actions[k] .= data.actions[k]
        data.nominal_constraints[k] .= data.constraints[k]
        data.nominal_ineq_lower[k] .= data.ineq_lower[k]
        data.nominal_ineq_upper[k] .= data.ineq_upper[k]
        data.nominal_eq_duals[k] .= data.eq_duals[k]
        data.nominal_ineq_duals_lo[k] .= data.ineq_duals_lo[k]
        data.nominal_ineq_duals_up[k] .= data.ineq_duals_up[k]
        if resto
            data.nominal_p[k] .= data.p[k]
            data.nominal_n[k] .= data.n[k]
            data.nominal_vp[k] .= data.vp[k]
            data.nominal_vn[k] .= data.vn[k]
        end
    end
end

function primal_trajectories(problem::ProblemData; mode=:nominal)
    x = mode == :nominal ? problem.nominal_states : problem.states
    u = mode == :nominal ? problem.nominal_actions : problem.actions
    h = mode == :nominal ? problem.nominal_constraints : problem.constraints
    il = mode == :nominal ? problem.nominal_ineq_lower : problem.ineq_lower
    iu = mode == :nominal ? problem.nominal_ineq_upper : problem.ineq_upper
    return x, u, h, il, iu 
end

function dual_trajectories(problem::ProblemData; mode=:nominal)
    ϕ = mode == :nominal ? problem.nominal_eq_duals : problem.eq_duals
    vl = mode == :nominal ? problem.nominal_ineq_duals_lo : problem.ineq_duals_lo
    vu = mode == :nominal ? problem.nominal_ineq_duals_up : problem.ineq_duals_up
    return ϕ, vl, vu
end

function fr_trajectories(problem::ProblemData; mode=:nominal)
    p = mode == :nominal ? problem.nominal_p : problem.p
    n = mode == :nominal ? problem.nominal_n : problem.n
    vp = mode == :nominal ? problem.nominal_vp : problem.vp
    vn = mode == :nominal ? problem.nominal_vn : problem.vn
    return p, n, vp, vn
end