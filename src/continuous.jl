using OrdinaryDiffEq, Requires, ForwardDiff
import OrdinaryDiffEq.ODEProblem
import OrdinaryDiffEq.ODEIntegrator

export ContinuousDS, variational_integrator, ODEIntegrator, ODEProblem
export ContinuousDynamicalSystem, DEFAULT_DIFFEQ_KWARGS, get_sol
export parallel_integrator

#######################################################################################
#                                     Constructors                                    #
#######################################################################################
"Abstract type representing continuous systems."
abstract type ContinuousDynamicalSystem <: DynamicalSystem end

"""
    ContinuousDS <: DynamicalSystem
`D`-dimensional continuous dynamical system.
## Fields
* `prob::ODEProblem` : The fundamental structure used to describe
  a continuous dynamical system and also used in the
  [DifferentialEquations.jl](http://docs.juliadiffeq.org/latest/index.html)
  suite.
  Contains the system's state (`prob.u0`), the equations of motion (`prob.f`),
  the parameters of the equations of motion (`prob.p`) and optionally other
  information like e.g. [callbacks](http://docs.juliadiffeq.org/latest/features/callback_functions.html#Event-Handling-and-Callback-Functions-1).
* `jacob!` (function) : The function that represents the Jacobian of the system,
  given in the format: `jacob!(J, u, p, t)` which means given a state `u`, a
  parameter container `p` and a time `t`, it writes the system's Jacobian in-place in
  `J`.
* `J::Matrix{T}` : Initialized Jacobian matrix.

The equations of motion function is contained in `prob.f`, the state is contained
in `prob.u0` and the parameters are contained in `prob.p`.

## Creating a `ContinuousDS`
The equations of motion function **must be** in the form `eom!(du, u, p, t)`,
as requested by DifferentialEquations.jl. They are **in-place** with the mutated
argument `du` being first. `p` stands for the parameters of the model and `t` stands
for the time variable (independent variable). Actually using `p` and `t` inside `eom!`
is completely optional, however *both must be used in the definition of the function*!
Both `u, du` **must be** `Vector`s.

If you have the `eom!` function, and optionally a function for the
Jacobian, you can use the constructor
```julia
ContinuousDS(state, eom! [, jacob! [, J]];
             tspan = (0.0, 100.0), parameters = nothing)
```
with `state` the initial condition of the system. `parameters` is a keyword
corresponding to the initial parameters of the model,
and if not given it is assumed to be `nothing` (which of course means that the
model does not have any parameters).

If instead you already have an `ODEProblem` because you also want to take advantage
of the callback functionality of DifferentialEquations.jl, you may use the constructor
```julia
ContinuousDS(odeproblem [, jacob! [, J]])
```

If the `jacob!` is not provided by the user, it is created automatically
using the module [`ForwardDiff`](http://www.juliadiff.org/ForwardDiff.jl/stable/),
which always passes `p = odeproblem.p, t=0` at the `eom!` (this interaction is
well-behavied for all functions exported by the DynamicalSystems.jl suite because
the parameter container is passed by reference and thus mutations in parameters
propagate correctly).

`ContinuousDS` by default are evolved using solver `Vern9()` and tolerances
`:abstol => 1e-9, :reltol => 1e-9`.

See also [`set_state!`](@ref).
"""
struct ContinuousDS{T<:Number, ODE<:ODEProblem, JJ} <: ContinuousDynamicalSystem
    prob::ODE
    jacob!::JJ
    J::Matrix{T}

    function ContinuousDS{T,ODE,JJ}(prob, j!, J) where {T,ODE,JJ}

        typeof(prob.u0) <: Vector || throw(ArgumentError(
        "We only support vectors as states, "*
        "see the documentation string of `ContinuousDS`."
        ))
        j!(J, prob.u0, prob.p, 0)

        eltype(prob.u0) == eltype(J) || throw(ArgumentError(
        "The state and the Jacobian must have same type of numbers."))

        return new(prob, j!, J)
    end
end

# Constructors with Jacobian:
function ContinuousDS(prob::ODE, j!::JJ, J::Matrix{T}) where
    {T<:Number, ODE<:ODEProblem, JJ}
    ContinuousDS{T, ODE,JJ}(prob, j!, J)
end

function ContinuousDS(prob::ODEProblem, j!)

    J = zeros(eltype(state), length(state), length(state))
    return ContinuousDS(prob, j!, J)
end

function ContinuousDS(state, eom!, j!,
    J = zeros(eltype(state), length(state), length(state));
    tspan=(0.0, 100.0), parameters = nothing)

    j!(J, state, parameters, 0)
    problem = ODEProblem{true}(eom!, state, tspan, parameters)

    return ContinuousDS(problem, j!, J)
end


# Constructors without Jacobian:
function ContinuousDS(prob::ODEProblem)
    u0 = prob.u0
    eom! = prob.f

    D = length(u0); T = eltype(u0)
    du = copy(u0)
    J = zeros(T, D, D)

    jeom! = (du, u) -> eom!(du, u, prob.p, 0)
    jcf = ForwardDiff.JacobianConfig(jeom!, du, u0)
    ForwardDiff_jacob! = (J, u, p, t) -> ForwardDiff.jacobian!(
    J, jeom!, du, u, jcf)
    ForwardDiff_jacob!(J, u0, prob.p, 0)

    return ContinuousDS(prob, ForwardDiff_jacob!, J)
end

function ContinuousDS(u0, eom!; parameters = nothing, tspan=(0.0, 100.0))

    D = length(u0); T = eltype(u0)
    du = copy(u0)
    J = zeros(T, D, D)

    problem = ODEProblem{true}(eom!, u0, tspan, parameters)

    jeom! = (du, u) -> eom!(du, u, problem.p, 0)
    jcf = ForwardDiff.JacobianConfig(jeom!, du, u0)
    ForwardDiff_jacob! = (J, u, p, t) -> ForwardDiff.jacobian!(
    J, jeom!, du, u, jcf)
    ForwardDiff_jacob!(J, u0, parameters, 0)

    return ContinuousDS(problem, ForwardDiff_jacob!, J)
end

# Basic
dimension(ds::ContinuousDS) = length(ds.prob.u0)
Base.eltype(ds::ContinuousDS{T,F,J}) where {T, F, J} = T
state(ds::ContinuousDS) = ds.prob.u0

jacobian(ds::ContinuousDynamicalSystem) =
(ds.jacob!(ds.J, state(ds), ds.prob.p, ds.prob.tspan[1]); ds.J)

set_state!(ds::ContinuousDS, u0) = (ds.state .= u0)

#######################################################################################
#                         Interface to DifferentialEquations                          #
#######################################################################################

"""
    ODEProblem(ds::ContinuousDS; kwargs...)
Create a new `ODEProblem` for the given dynamical system by optionally
changing specific aspects of the existing `ODEProblem`.

Keyword arguments: `state, t, parameters, callback, mass_matrix, tspan`. If
`callback` is given and a callback also exists already in `ds.prob` (i.e.
`ds.prob.cb ≠ nothing`) then the two callbacks are merged into a `CallbackSet`.

If `t` is given, a `tspan` is created with initial time assumed zero. If `tspan`
is given directly, the keyword `t` is disregarded.
"""
function ODEProblem(ds::ContinuousDS;
                    t = ds.prob.tspan[end],
                    state = ds.prob.u0,
                    parameters = ds.prob.p,
                    callback = ds.prob.callback,
                    mass_matrix = ds.prob.mass_matrix,
                    tspan = (zero(t), t))

    if ds.prob.callback == nothing
        cb = callback
    else
        cb = CallbackSet(callback, ds.prob.callback)
    end

    return ODEProblem{true}(ds.prob.f, state, tspan, parameters,
                      mass_matrix = mass_matrix, callback = cb)
end



function OrdinaryDiffEq.ODEIntegrator(ds::ContinuousDS,
    t, state::Vector = ds.prob.u0; diff_eq_kwargs = DEFAULT_DIFFEQ_KWARGS)
    prob = ODEProblem(ds; t = t, state = state)
    solver, newkw = extract_solver(diff_eq_kwargs)
    integrator = init(prob, solver; newkw..., save_everystep=false)
    return integrator
end



"""
    variational_integrator(ds::ContinuousDS, S::Matrix, [, t]; diff_eq_kwargs)
Return an `ODEIntegrator` that represents the variational equations
of motion for the system. `t` makes the `tspan` and if it is `Real`
instead of `Tuple`, initial time is assumed zero.

This integrator evolves in parallel the system and `k = size(S)[2] - 1` deviation
vectors ``w_i`` such that ``\\dot{w}_i = J\\times w_i`` with ``J`` the Jacobian
at the current state. `S` is the initial "conditions" which contain both the
system's state as well as the initial diviation vectors:
`S = cat(2, state, ws)` if `ws` is a matrix that has as *columns* the initial
deviation vectors.

The only keyword argument for this funcion is `diff_eq_kwargs` (see
[`trajectory`](@ref)).
"""
function variational_integrator(ds::ContinuousDS, S::Matrix, T = ds.prob.tspan;
    diff_eq_kwargs = DEFAULT_DIFFEQ_KWARGS)

    f! = ds.prob.f
    jac! = ds.jacob!
    J = ds.J
    k = size(S)[2]-1
    # the equations of motion `veom!` evolve the system and
    # k deviation vectors. Notice that the k deviation vectors
    # can also be considered a D×k matrix (which is the case
    # at `lyapunovs` function).
    # The e.o.m. for the system is f!(t, u , du) with `u` the system state.
    # The e.o.m. for the deviation vectors (tangent dynamics) are simply:
    # dY/dt = J(u) ⋅ Y
    # with J the Jacobian of the vector field at the current state
    # and Y being each of the k deviation vectors
    veom! = (du, u, p, t) -> begin
        us = view(u, :, 1)
        f!(view(du, :, 1), us, p, t)
        jac!(J, us, p, t)
        A_mul_B!(view(du, :, 2:k+1), J, view(u, :, 2:k+1))
    end

    if typeof(T) <: Real
        varprob = ODEProblem{true}(veom!, S, (zero(T), T), ds.prob.p)
    else
        varprob = ODEProblem{true}(veom!, S, T, ds.prob.p)
    end

    solver, newkw = extract_solver(diff_eq_kwargs)
    vintegrator = init(varprob, solver; newkw...)
    return vintegrator
end

"""
    parallel_integrator(ds::ContinuousDS, S::Matrix, [, t]; diff_eq_kwargs)
"""
function parallel_integrator(ds::ContinuousDS, S::Matrix, T = ds.prob.tspan;
    diff_eq_kwargs = DEFAULT_DIFFEQ_KWARGS)

    f! = ds.prob.f
    k = size(S)[2]

    veom! = (du, u, p, t) -> begin
        for j in 1:k
            f!(view(du, :, j), view(u, :, j), p, t)
        end
        return
    end

    if typeof(T) <: Real
        varprob = ODEProblem{true}(veom!, S, (zero(T), T), ds.prob.p)
    else
        varprob = ODEProblem{true}(veom!, S, T, ds.prob.p)
    end

    solver, newkw = extract_solver(diff_eq_kwargs)
    pintegrator = init(varprob, solver; newkw...)
    return pintegrator
end


function check_tolerances(d0, diff_eq_kwargs)
    defatol = 1e-6; defrtol = 1e-3
    atol = haskey(diff_eq_kwargs, :abstol) ? diff_eq_kwargs[:abstol] : defatol
    rtol = haskey(diff_eq_kwargs, :reltol) ? diff_eq_kwargs[:reltol] : defrtol
    if atol > 10d0
        warnstr = "Absolute tolerance (abstol) of integration is much larger than "
        warnstr*= "`d0`! It is highly suggested to decrease it using `diff_eq_kwargs`."
        warn(warnstr)
    end
    if rtol > 10d0
        warnstr = "Relative tolerance (reltol) of integration is much larger than "
        warnstr*= "`d0`! It is highly suggested to decrease it using `diff_eq_kwargs`."
        warn(warnstr)
    end
end
#######################################################################################
#                                Evolution of System                                  #
#######################################################################################
const DEFAULT_DIFFEQ_KWARGS = Dict{Symbol, Any}(:abstol => 1e-9, :reltol => 1e-9)
const DEFAULT_SOLVER = Vern9()

# See discrete.jl for the documentation string
function evolve(ds::ContinuousDS, t = 1.0, state = ds.prob.u0;
    diff_eq_kwargs = DEFAULT_DIFFEQ_KWARGS)
    if typeof(t) <: Real
        prob = ODEProblem(ds, t = t, state = state)
    else
        prob = ODEProblem(ds, tspan = t, state = state)
    end
    return get_sol(prob, diff_eq_kwargs)[1][end]
end

evolve!(ds::ContinuousDS, t; diff_eq_kwargs = DEFAULT_DIFFEQ_KWARGS) =
(ds.prob.u0 .= evolve(ds, t; diff_eq_kwargs = diff_eq_kwargs); ds.prob.u0)

function extract_solver(diff_eq_kwargs)
    # Extract solver from kwargs
    if haskey(diff_eq_kwargs, :solver)
        newkw = deepcopy(diff_eq_kwargs)
        solver = diff_eq_kwargs[:solver]
        pop!(newkw, :solver)
    else
        solver = DEFAULT_SOLVER
        newkw = diff_eq_kwargs
    end
    return solver, newkw
end

"""
    get_sol(prob::ODEProblem [, diff_eq_kwargs::Dict, extra_kwargs::Dict])
Solve the `prob` using `solve` and return the solutions vector as well as
the time vector. Always uses the keyword argument `save_everystep=false`.

The second and third
arguments are optional *position* arguments, passed to `solve` as keyword arguments.
They both have to be dictionaries of `Symbol` keys.
Only the second argument may contain a solver via the `:solver` key.

`get_sol` correctly uses `tstops` if necessary
(e.g. in the presence of `DiscreteCallback`s).
"""
function get_sol(prob::ODEProblem, diff_eq_kwargs::Dict = DEFAULT_DIFFEQ_KWARGS,
    extra_kwargs = Dict())

    solver, newkw = extract_solver(diff_eq_kwargs)
    # Take special care of callback sessions and use `tstops` if necessary
    # in conjuction with `saveat`
    if haskey(newkw, :saveat) && use_tstops(prob)
        sol = solve(prob, solver; newkw..., extra_kwargs..., save_everystep=false,
        tstops = newkw[:saveat])
    else
        sol = solve(prob, solver; newkw..., extra_kwargs..., save_everystep=false)
    end

    return sol.u, sol.t
end

function use_tstops(prob::ODEProblem)
    if prob.callback == nothing
        return false
    elseif typeof(prob.callback) <: CallbackSet
        return any(x->typeof(x)<:DiscreteCallback, prob.callback.discrete_callbacks)
    else
        return typeof(prob.callback) <: DiscreteCallback
    end
end

# See discrete.jl for the documentation string
function trajectory(ds::ContinuousDS, T;
    dt::Real=0.05, diff_eq_kwargs::Dict = DEFAULT_DIFFEQ_KWARGS)

    # Necessary due to DifferentialEquations:
    if typeof(T) <: Real && !issubtype(typeof(T), AbstractFloat)
        T<=0 && throw(ArgumentError("Total time `T` must be positive."))
        T = convert(Float64, T)
    end

    if typeof(T) <: Real
        t = zero(T):dt:T #time vector
        prob = ODEProblem(ds; t = T)
    elseif typeof(T) <: Tuple
        t = T[1]:dt:T[2]
        prob = ODEProblem(ds; tspan = T)
    end

    return Dataset(get_sol(prob, diff_eq_kwargs, Dict(:saveat => t))[1])
end

#######################################################################################
#                                 Pretty-Printing                                     #
#######################################################################################
Base.summary(ds::ContinuousDS) =
"$(dimension(ds))-dimensional continuous dynamical system"

function Base.show(io::IO, ds::ContinuousDS{S, F, J}) where {S, F, J}
    D = dimension(ds)
    text = summary(ds)
    print(io, text*":\n",
    "state: $(ds.prob.u0)\n", "e.o.m.: $(ds.prob.f)\n")
end

#=
using OrdinaryDiffEq, BenchmarkTools
@inline @inbounds function lorenz63_eom(du, u, p, t)
    σ = p[1]; ρ = p[2]; β = p[3]
    du[1] = σ*(u[2]-u[1])
    du[2] = u[1]*(ρ-u[3]) - u[2]
    du[3] = u[1]*u[2] - β*u[3]
    return nothing
end
p = [10,28,8/3]
u0 = [1.0;0.0;0.0]
tspan = (0.0,100.0)
prob = ODEProblem(lorenz63_eom,u0,tspan,p)
@btime solve(prob,Tsit5())

# Function that evolves `k` orbits in parallel:
S = rand(3, 2)
function f(prob, S)
    D = length(prob.u0)
    f! = prob.f
    k = size(S)[2]

    veom! = (du, u, p, t) -> begin
        for j in 1:k
            f!(view(du, :, j), view(u, :, j), p, t)
        end
        return
    end

    varprob = ODEProblem{true}(veom!, S, prob.tspan, prob.p)
end
varprob = f(prob,  S)
@btime solve(varprob,Tsit5());

=#
