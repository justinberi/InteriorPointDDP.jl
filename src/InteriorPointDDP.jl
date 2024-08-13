module InteriorPointDDP

using LinearAlgebra 
using Symbolics 
using Scratch 
using JLD2
using Printf
using Crayons

include("costs.jl")
include("dynamics.jl")
include("constraints.jl")
include(joinpath("data", "model.jl"))
include(joinpath("data", "costs.jl"))
include(joinpath("data", "constraints.jl"))
include(joinpath("data", "policy.jl"))
include(joinpath("data", "problem.jl"))
include(joinpath("data", "solver.jl"))
include(joinpath("data", "methods.jl"))
include("options.jl")
include("solver.jl")
include("rollout.jl")
include("gradients.jl")
include("inertia_correction.jl")
include("feasibility_restoration/backward.jl")
include("feasibility_restoration/forward.jl")
include("feasibility_restoration/solve.jl")
include("backward_pass.jl")
include("forward_pass.jl")
include("print.jl")
include("solve.jl")
include("soc.jl")

# costs
export Cost

# constraints 
export Constraint

# dynamics 
export Dynamics

# solver 
export rollout, 
    dynamics!,
    Solver, Options,
    initialize_controls!, initialize_states!, 
    solve!,
    get_trajectory

end # module
