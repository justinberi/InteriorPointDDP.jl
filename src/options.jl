Base.@kwdef mutable struct Options{T} 
    line_search::Symbol=:armijo
    max_iterations::Int=100
    max_dual_updates::Int=10
    min_step_size::T=1.0e-5
    objective_tolerance::T=1.0e-3
    lagrangian_gradient_tolerance::T=1.0e-3
    constraint_tolerance::T=5.0e-3
    constraint_norm::T=Inf
    initial_constraint_penalty::T=1.0
    scaling_penalty::T=10.0
    max_penalty::T=1.0e8
    reset_cache::Bool=false
    verbose=true
    # Regularisation Params
    reg::Int8 = 0
    start_reg::Int8 = 0
    end_reg::Int8 = 24
    reg_step::Int8 = 1
    # Error Params 
    opterr::Float64 = 0.0
    recovery::Float64 = 0.0 
    # IPDDP Params
    feasible::Bool = true
    method::Symbol=:ip # can be :al for augmented lagrangian
end 