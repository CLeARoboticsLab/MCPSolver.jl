"Utility to represent a parameterized optimization problem."
Base.@kwdef struct OptimizationProblem{T1,T2,T3}
    objective::T1
    private_equality::T2 = nothing
    private_inequality::T3 = nothing
end

"""A structure to represent a game with objectives and constraints parameterized by
a vector θ ∈ Rⁿ.

We will assume that the players' primal variables are stacked into a BlockVector
x with the i-th block corresponding to the i-th player's decision variable.
Similarly, we will assume that the parameter θ has a block structure so that the
i-th player's problem depends only upon the i-th block of θ.
"""
struct ParametricGame{T1,T2,T3}
    problems::Vector{<:OptimizationProblem}
    shared_equality::T1
    shared_inequality::T2
    dims::T3

    "PrimalDualMCP representation."
    mcp::PrimalDualMCP
end

function ParametricGame(;
    test_point,
    test_parameter,
    problems,
    shared_equality = nothing,
    shared_inequality = nothing,
    parametric_mcp_options = (;),
)
    N = length(problems)
    @assert N == length(blocks(test_point))

    dims = dimensions(
        test_point,
        test_parameter,
        problems,
        shared_equality,
        shared_inequality,
    )

    # Define primal and dual variables for the game, and game parameters..
    # Note that BlockArrays can handle blocks of zero size.
    backend = SymbolicUtils.SymbolicsBackend()
    x = SymbolicUtils.make_variables(backend, :x, sum(dims.x)) |> to_blockvector(dims.x)
    λ = SymbolicUtils.make_variables(backend, :λ, sum(dims.λ)) |> to_blockvector(dims.λ)
    μ = SymbolicUtils.make_variables(backend, :μ, sum(dims.μ)) |> to_blockvector(dims.μ)

    λ̃ = SymbolicUtils.make_variables(backend, :λ̃, dims.λ̃)
    μ̃ = SymbolicUtils.make_variables(backend, :μ̃, dims.μ̃)

    θ = SymbolicUtils.make_variables(backend, :θ, sum(dims.θ)) |> to_blockvector(dims.θ)

    # Build symbolic expressions for objectives and constraints.
    fs = map(problems, blocks(θ)) do p, θi
        p.objective(x, θi)
    end
    gs = map(problems, blocks(x), blocks(θ)) do p, xi, θi
        isnothing(p.private_equality) ? nothing : p.private_equality(xi, θi)
    end
    hs = map(problems, blocks(x), blocks(θ)) do p, xi, θi
        isnothing(p.private_inequality) ? nothing : p.private_inequality(xi, θi)
    end

    g̃ = isnothing(shared_equality) ? nothing : shared_equality(x, θ)
    h̃ = isnothing(shared_inequality) ? nothing : shared_inequality(x, θ)

    # Build gradient of each player's Lagrangian.
    ∇Ls = map(fs, gs, hs, blocks(x), blocks(λ), blocks(μ)) do f, g, h, xi, λi, μi
        L =
            f - (isnothing(g) ? 0 : sum(λi .* g)) - (isnothing(h) ? 0 : sum(μi .* h)) - (isnothing(g̃) ? 0 : sum(λ̃ .* g̃)) -
            (isnothing(h̃) ? 0 : sum(μ̃ .* h̃))
        SymbolicUtils.gradient(L, xi)
    end

    # Build MCP representation.
    F = Vector{Symbolics.Num}(
        filter!(
            !isnothing,
            [
                reduce(vcat, ∇Ls)
                reduce(vcat, gs)
                reduce(vcat, hs)
                g̃
                h̃
            ],
        ),
    )

    z = Vector{Symbolics.Num}(
        filter!(
            !isnothing,
            [
                x
                mapreduce(b -> length(b) == 0 ? nothing : b, vcat, blocks(λ))
                mapreduce(b -> length(b) == 0 ? nothing : b, vcat, blocks(μ))
                length(λ̃) == 0 ? nothing : λ̃
                length(μ̃) == 0 ? nothing : μ̃
            ],
        ),
    )

    z̲ = [
        fill(-Inf, length(x))
        fill(-Inf, length(λ))
        fill(0, length(μ))
        fill(-Inf, length(λ̃))
        fill(0, length(μ̃))
    ]

    z̅ = [
        fill(Inf, length(x))
        fill(Inf, length(λ))
        fill(Inf, length(μ))
        fill(Inf, length(λ̃))
        fill(Inf, length(μ̃))
    ]

    mcp = PrimalDualMCP(F |> collect, z |> collect, θ |> collect, z̲, z̅)

    ParametricGame(problems, shared_equality, shared_inequality, dims, mcp)
end

function dimensions(
    test_point,
    test_parameter,
    problems,
    shared_equality,
    shared_inequality,
)
    x = only(blocksizes(test_point))
    θ = only(blocksizes(test_parameter))
    λ = map(problems, blocks(test_point), blocks(test_parameter)) do p, xi, θi
        isnothing(p.private_equality) ? 0 : length(p.private_equality(xi, θi))
    end
    μ = map(problems, blocks(test_point), blocks(test_parameter)) do p, xi, θi
        isnothing(p.private_inequality) ? 0 : length(p.private_inequality(xi, θi))
    end

    λ̃ =
        isnothing(shared_equality) ? 0 :
        length(shared_equality(test_point, test_parameter))
    μ̃ =
        isnothing(shared_inequality) ? 0 :
        length(shared_inequality(test_point, test_parameter))

    (; x, θ, λ, μ, λ̃, μ̃)
end

"Solve a parametric game."
function solve(
    game::ParametricGame,
    θ;
    solver_type = InteriorPoint(),
    x₀ = nothing,
    y₀ = nothing,
    tol = 1e-4
)
    initial_x =
        !isnothing(x₀) ? x₀ : zeros(sum(game.dims.x) + sum(game.dims.λ) + game.dims.λ̃)
    initial_y = !isnothing(y₀) ? y₀ : zeros(sum(game.dims.μ) + game.dims.μ̃)

    (; x, y, s, kkt_error) = solve(
        solver_type,
        game.mcp;
        θ,
        x₀ = initial_x,
        y₀ = initial_y,
        tol
    )

    # Unpack primals per-player for ease of access later.
    end_dims = cumsum(game.dims.x)
    primals = map(1:num_players(game)) do ii
        (ii == 1) ? x[1:end_dims[ii]] : x[(end_dims[ii - 1] + 1):end_dims[ii]]
    end

    (; primals, variables = (; x, y), kkt_error)
end

"Return the number of players in this game."
function num_players(game::ParametricGame)
    length(game.problems)
end
