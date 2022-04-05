module StabilityCheck

#
# Exhaustive enumeration of types for static type stability checking
#

export @stable, @stable!, @stable!_nop,
    is_stable_method, is_stable_function, is_stable_module, is_stable_moduleb,
    check_all_stable,
    convert,

    # Stats
    AgStats,
    aggregateStats,
    # CSV-aware tools
    checkModule, prepCsv,

    # Types
    MethStCheck,
    Stb, Uns, AnyParam, VarargParam, TcFail, OutOfFuel,
    SearchCfg

# Debug print:
# ENV["JULIA_DEBUG"] = StabilityCheck  # turn on
# ENV["JULIA_DEBUG"] = Nothing         # turn off

include("equality.jl")

using InteractiveUtils
using MacroTools
using CSV

import Base.convert

#
# Data structures to represent answers to stability check requests
#   and search configuration
#

JlType = Any
JlSignature = Vector{JlType}

# Hieararchy of possible answers to a stability check querry
abstract type StCheck end
struct Stb <: StCheck         # hooary, we're stable
    steps :: Int64
    skipexist :: Vector{JlType}
end
struct Uns <: StCheck         # no luck, record types that break stability
    fails :: Vector{Vector{Any}}
end
struct AnyParam    <: StCheck # give up on Any-params in methods; can't tell if it's stable
    sig :: Vector{Any}
end
struct VarargParam <: StCheck # give up on VA-params  in methods; can't tell if it's stable
    sig :: Vector{Any}
end
struct TcFail <: StCheck      # Julia typechecker sometimes fails for unclear reason
    sig :: Vector{Any}
end
struct OutOfFuel  <: StCheck  # fuel exhausted
end
struct UnboundExist <: StCheck  # we hit unbounded existentials, which we can't enumerate
    t :: JlType                 # (same as Any, but maybe interesting to analyze separately)
                                # TODO: this is not accounted for yet, as we don't distinguish
                                #       between various cases under SkippedUnionAlls
end

Base.:(==)(x::StCheck, y::StCheck) = structEqual(x,y)

# Result of a check along with the method under the check (for reporting purposes)
struct MethStCheck
    method :: Method
    check  :: StCheck
end

# Result of many checks (convinience alias)
StCheckResults = Vector{MethStCheck}

# Subtype enumeration procedure parameters
Base.@kwdef struct SearchCfg
    concrete_only  :: Bool = true
#   ^ -- enumerate concrete types ONLY;
#        Usually start in this mode, but can switch if we see a UnionAll and decide
#        to try abstract instantiations (whether we decide to do that or not, see
#        `abstract_args` below)

    skip_unionalls :: Bool = false
#   ^ -- don't try to instantiate UnionAll's / existential types, just forget about them
#        -- be default we do instantiate, but can loop if don't turn off on recursive call;

    abstract_args  :: Bool = false
#   ^ -- instantiate type variables with only concrete arguments or abstract arguments too;
#        if the latter, may quickly become unstable, so a reasonable default is be `false`

    exported_names_only :: Bool = false
#   ^ -- when doing stability check on the whole module at once: whether to check only
#        only exported functions

    fuel :: Int = typemax(Int)
#   ^ -- search fuel, i.e. how many types we want to enumerate before give up

    max_lattice_steps :: Int = typemax(Int)
#   ^ -- how many steps to perform max to get from the signature to a concrete type;
#        for some signatures we struggle to get to a leat type
end

default_scfg = SearchCfg()

# How many counterexamples to print by default
MAX_PRINT_UNSTABLE = 5

struct SkippedUnionAlls
    ts :: Vector{JlType}
end


#
#       Main interface utilities
#


# @stable!: method definition AST -> IO same definition
# Side effects: Prints warning if finds unstable signature instantiation.
#               Relies on is_stable_method.
macro stable!(def)
    (fname, argtypes) = split_def(def)
    quote
	    $(esc(def))
        m = which($(esc(fname)), $argtypes)
        mst = is_stable_method(m)

        print_uns(m, mst)
        (f,_) = split_method(m)
        f
    end
end

# Interface for delayed stability checks; useful for define-after-use cases (cf. Issue #3)
# @stable delays the check until `check_all_stable` is called. The list of checks to perform
# is stored in a global list that needs cleenup once in a while with `clean_checklist`.
checklist=[]
macro stable(def)
    push!(checklist, def)
    def
end
check_all_stable() = begin
    @debug "start check_all_stable"
    for def in checklist
        (fname, argtypes) = split_def(def)
        @debug "Process method $fname with signature: $argtypes"
        m = which(eval(fname), eval(argtypes))
        mst = is_stable_method(m)

        print_uns(m, mst)
    end
end
clean_checklist() = begin
    global checklist = [];
end

# Variant of @stable! that doesn't splice the provided function definition
# into the global namespace. Mostly for testing purposes. Relies on Julia's
# hygiene support.
macro stable!_nop(def)
    (fname, argtypes) = split_def(def)
    quote
	    $(def)
        m = which($(fname), $argtypes)
        mst = is_stable_method(m)

        print_uns(m, mst)
    end
end

# is_stable_module : Module, SearchCfg -> IO StCheckResults
# Check all(*) function definitions in the module for stability.
# Relies on `is_stable_function`.
# (*) "all" can mean all or exported; cf. `SearchCfg`'s  `exported_names_only`.
is_stable_module(mod::Module, scfg :: SearchCfg = default_scfg) :: StCheckResults = begin
    @debug "is_stable_module: $mod"
    res = []
    ns = names(mod; all=!scfg.exported_names_only)
    @info "number of methods in $mod: $(length(ns))"
    for sym in ns
        @debug "is_stable_module: check symbol $sym"
        evsym = Core.eval(mod, sym)
        isa(evsym, Function) || continue # not interested in non-functional symbols
        (sym == :include || sym == :eval) && continue # not interested in special functions
        res = vcat(res, is_stable_function(evsym, scfg))
    end
    return res
end

# bool-returning version of the above
is_stable_moduleb(mod::Module, scfg :: SearchCfg = default_scfg) :: Bool =
    convert(Bool, is_stable_module(mod, scfg))

# is_stable_function : Function, SearchCfg -> IO StCheckResults
# Convenience tool to iterate over all known methods of a function.
# Usually, direct use of `is_stable_method` is preferrable, but, for instance,
# `is_stable_module` has to rely on this one.
is_stable_function(f::Function, scfg :: SearchCfg = default_scfg) :: StCheckResults = begin
    @debug "is_stable_function: $f"
    map(m -> MethStCheck(m, is_stable_method(m, scfg)), methods(f).ms)
end

# is_stable_method : Method, SearchCfg -> StCheck
# Main interface utility: check if method is stable by enumerating
# all possible instantiations of its signature.
# If signature has Any at any place, yeild AnyParam immediately.
# If signature has Vararg at any place, yeild VarargParam immediately.
is_stable_method(m::Method, scfg :: SearchCfg = default_scfg) :: StCheck = begin
    @debug "is_stable_method: $m"
    (func, sig_types) = split_method(m)

    # corner cases where we give up
    Any ∈ sig_types && return AnyParam(sig_types)
    any(t -> is_vararg(t), sig_types) && return VarargParam(sig_types)

    # loop over all instantiations of the signature
    fails = Vector{Any}([])
    steps = 0
    skipexists = []
    for ts in Channel(ch -> all_subtypes(sig_types, scfg, ch))
        if ts == "done"
            break
        end
        if ts isa SkippedUnionAlls
            skipexists = vcat(skipexists, ts.ts)
            continue
        end
        try
            if ! is_stable_call(func, ts)
                push!(fails, ts)
            end
        catch
            return TcFail(ts)
        end
        steps += 1
        if steps > scfg.fuel
            return OutOfFuel()
        end
    end

    return if isempty(fails)
        Stb(steps, skipexists)
    else
        Uns(fails)
    end
end


#
#      Data analysis utilities
#


# Conversion to CSV

struct MethStCheckCsv
    check :: String
    extra :: String
    sig   :: String
    mod   :: String
    file  :: String
    line  :: Int
end

StCheckResultsCsv = Vector{MethStCheckCsv}

stCheckToCsv(::StCheck) :: String = error("unknown check")
stCheckToCsv(::Stb)         = "stable"
stCheckToCsv(::Uns)         = "unstable"
stCheckToCsv(::AnyParam)    = "Any"
stCheckToCsv(::VarargParam) = "vararg"
stCheckToCsv(::TcFail)      = "tc-fail"
stCheckToCsv(::OutOfFuel)   = "nofuel"
stCheckToCsv(::UnboundExist)= "unboundexist"

stCheckToExtraCsv(::StCheck) :: String = error("unknown check")
stCheckToExtraCsv(s::Stb)        = "$(s.steps)" * (s.skipexist == [] ? "" : ";" * string(s.skipexist))
stCheckToExtraCsv(::Uns)         = ""
stCheckToExtraCsv(::AnyParam)    = ""
stCheckToExtraCsv(::VarargParam) = ""
stCheckToExtraCsv(f::TcFail)     = "$(f.sig)"
stCheckToExtraCsv(::OutOfFuel)   = ""
stCheckToExtraCsv(::UnboundExist)   = ""

prepCsvCheck(mc::MethStCheck) :: MethStCheckCsv =
    MethStCheckCsv(
        stCheckToCsv(mc.check),
        stCheckToExtraCsv(mc.check),
        "$(mc.method.sig)",
        "$(mc.method.module)",
        "$(mc.method.file)",
        mc.method.line,
    )

prepCsv(mcs::StCheckResults) :: StCheckResultsCsv = map(prepCsvCheck, mcs)

struct AgStats
    methCnt :: Int64
    stblCnt :: Int64
    unsCnt  :: Int64
    anyCnt  :: Int64
    vaCnt   :: Int64
    tcfCnt  :: Int64
    nofCnt  :: Int64
    unbeCnt :: Int64
end

showAgStats(m::Module, ags::AgStats) :: String =
    "$m,$(ags.methCnt),$(ags.stblCnt),$(ags.unsCnt),$(ags.anyCnt),$(ags.vaCnt),$(ags.tcfCnt),$(ags.nofCnt),$(ags.unbeCnt)"

aggregateStats(mcs::StCheckResults) :: AgStats = AgStats(
    length(mcs),
    count(mc -> isa(mc.check, Stb), mcs),
    count(mc -> isa(mc.check, Uns), mcs),
    count(mc -> isa(mc.check, AnyParam), mcs),
    count(mc -> isa(mc.check, VarargParam), mcs),
    count(mc -> isa(mc.check, TcFail), mcs),
    count(mc -> isa(mc.check, OutOfFuel), mcs),
    count(mc -> isa(mc.check, UnboundExist), mcs),
)

storeCsv(name::String, mcs::StCheckResults) = CSV.write(name, prepCsv(mcs))

# checkModule :: Module, Path -> IO ()
# Check stability in the given module, store results under the given path
# Effects:
#   1. Module.csv with raw results
#   2. Module-agg.txt with aggregate results
checkModule(m::Module, out::String=".")= begin
    checkRes = is_stable_module(m)
    storeCsv(joinpath(out,"$m.csv"), checkRes)
    write(joinpath(out, "$m-agg.txt"), showAgStats(m, aggregateStats(checkRes)))
    return ()
end


#
#      Printing utilities
#


print_fails(uns :: Uns) = begin
    local i = 0
    for ts in uns.fails
        println("\t" * string(ts))
        i += 1
        if i == MAX_PRINT_UNSTABLE
            println("and $(length(uns.fails) - i) more... (adjust MAX_PRINT_UNSTABLE to see more)")
            return
        end
    end
end

print_uns(::Method, ::StCheck) = ()
print_uns(m::Method, mst::Union{AnyParam, TcFail, VarargParam, OutOfFuel}) = begin
    @warn "Method $(m.name) failed stabilty check with: $mst"
end
print_uns(m::Method, mst::Uns) = begin
    @warn "Method $(m.name) unstable on the following inputs"
    print_fails(mst)
end

print_check_results(checks :: Vector{MethStCheck}) = begin
    fails = filter(methAndCheck -> isa(methAndCheck.check, Uns), checks)
    if !isempty(fails)
        println("Some methods failed stability test")
        print_unsmethods(fails)
    end
end

print_unsmethods(fs :: StCheckResults) = begin
    for mck in fs
        print("The following method:\n\t")
        println(mck.method)
        println("is not stable for the following types of inputs")
        print_fails(mck.check)
    end
end

print_stable_check(f,ts,res_type,res) = begin
    print(lpad("is stable call " * string(f), 20) * " | " *
        rpad(string(ts), 35) * " | " * rpad(res_type, 30) * " |")
    println(res)
end


#
#      Aux utilities
#

# The heart of stability checking using Julia's built-in facilities:
# 1) compile the given function for the given argument types down to a typed IR
# 2) check the return type for concreteness
is_stable_call(@nospecialize(f :: Function), @nospecialize(ts :: Vector)) = begin
    ct = code_typed(f, (ts...,), optimize=false)
    if length(ct) == 0
        throw(DomainError("$f, $ts")) # type inference failed
    end
    (_ #=code=#, res_type) = ct[1] # we ought to have just one method body, I think
    res = is_concrete_type(res_type)
    #print_stable_check(f,ts,res_type,res)
    res
end

# all_subtypes: JlSignature, SearchCfg, Channel -> ()
# Instantiate method signature for concrete argument types.
# Input:
#   - "tuple" of types from the function signature (in the form of Vector, not Tuple);
#   - search configuration
#   - results channel to be consumed in asyncronous manner
# Output: ()
# Effects:
#   - subtypes of the input signature are sent to the channel
all_subtypes(ts::Vector, scfg :: SearchCfg, result :: Channel) = begin
    @debug "all_subtypes: $ts"
    sigtypes = Set{Any}([ts]) # worklist
    steps = 0
    while !isempty(sigtypes)
        tv = pop!(sigtypes)
        @debug "all_subtypes loop: $tv"
        if tv isa SkippedUnionAlls
            push!(result, tv)
            continue
        end
        isconc = all(is_concrete_type, tv)
        if isconc
            @debug "all_subtypes: concrete"
            put!(result, tv)
        else
            @debug "all_subtypes: abstract"

            # Special case: unbounded unionalls and forcedly-skipped ones (due to scfg)
            # if scfg.skipexist, skip it!
            unionalls = filter(t -> typeof(t) == UnionAll, tv)
            if scfg.skip_unionalls && !isempty(unionalls)
                put!(result, SkippedUnionAlls(unionalls))
                continue
            end
            # if unbounded unionall is around, bail out
            unb = filter(u -> u.var.ub == Any, unionalls)
            if !isempty(unb)
                put!(result, SkippedUnionAlls(unionalls))
                continue
            end

            # Normal case
            !scfg.concrete_only && put!(result, tv)
            dss = direct_subtypes(tv, scfg)
            union!(sigtypes, dss)
        end
        steps += 1
        if steps == scfg.max_lattice_steps
            break
        end
    end
    put!(result, "done")
end

blocklist = [Function]
is_vararg(t) = isa(t, Core.TypeofVararg)

# direct_subtypes: JlSignature, SearchCfg -> [Union{JlSignature, SkippedUnionAlls}]
# Auxilliary function: immediate subtypes of a tuple of types `ts1`
# Precondition: no unbounded existentials in ts1
direct_subtypes(ts1::Vector, scfg :: SearchCfg) = begin
    @debug "direct_subtypes: $ts1"
    isempty(ts1) && return [[]]

    ts = copy(ts1)
    t = pop!(ts)

    # subtypes of t -- first component in ts
    ss_first = if is_vararg(t) || any(b -> t <: b, blocklist)
        []
        else subtypes(t)
    end

    @debug "direct_subtypes of head: $(ss_first)"
    # no subtypes may mean it's a UnionAll requiring special handling
    if isempty(ss_first)
        if typeof(t) == UnionAll
            ss_first = subtype_unionall(t, scfg)
        end
    end

    res = []
    ss_rest = direct_subtypes(ts, scfg)
    for s_first in ss_first
        if s_first isa SkippedUnionAlls
            push!(res, s_first)
        else
            for s_rest in ss_rest
                if s_rest isa SkippedUnionAlls
                    push!(res, s_rest)
                else
                    push!(res, push!(Vector(s_rest), s_first))
                end
            end
        end
    end
    res
end

# instantiations: UnionAll, SearchCfg -> Channel{JlType}
# all possible instantiations of the top variable of a UnionAll,
# except unionalls (and their instances) -- to avoid looping.
# NOTE: don't forget to unwrap the contents of the results (tup -> tup[1]);
#       the reason this is needed: we expect insantiations to be a JlType,
#       but `all_subtypes` works with JlSignatures
instantiations(u :: UnionAll, scfg :: SearchCfg) =
    Channel(ch ->
                all_subtypes(
                    [u.var.ub],
                    SearchCfg(concrete_only  = scfg.abstract_args,
                                skip_unionalls = true,
                                abstract_args  = scfg.abstract_args),
                    ch))

# subtype_unionall: UnionAll, SearchCfg -> [Union{JlType, SkippedUnionAll}]
# For a non-Any upper-bounded UnionAll, enumerate all instatiations following `instantiations`.
#
# Note: ignore lower bounds for simplicity.
#
# Note (history): for unbounded (Any-bounded) unionalls we used to instantiate the variable
# with Any and Int.
#
# TODO: make result Channel-based
#
subtype_unionall(u :: UnionAll, scfg :: SearchCfg) = begin
    @debug "subtype_unionall of $u"

    @assert u.var.ub != Any

    res = []
    for t in instantiations(u, scfg)
        if t isa SkippedUnionAlls
            push!(res, t)
        else
            try # can fail due to unsond bounds (cf. #8)
                push!(res, u{t[1]})
            catch
                # skip failed instatiations
            end
        end
    end
    res
end

# is_concrete_type: Type -> Bool
#
# Note: Follows definition used in @code_warntype (cf. `warntype_type_printer` in:
# julia/stdlib/InteractiveUtils/src/codeview.jl)
is_concrete_type(@nospecialize(ty)) = begin
    if ty isa Type && (!Base.isdispatchelem(ty) || ty == Core.Box)
        if ty isa Union && Base.is_expected_union(ty)
            true # this is a "mild" problem, so we round up to "stable"
        else
            false
        end
    else
        true
    end
    # Note 1: Core.Box is a type of a heap-allocated value
    # Note 2: isdispatchelem is roughly eqviv. to
    #         isleaftype (from Julia pre-1.0)
    # Note 3: expected union is a trivial union (e.g.
    #         Union{Int,Missing}; those are deemed "probably
    #         harmless"
end

# In case we need to convert to Bool...
convert(::Type{Bool}, x::Stb) = true
convert(::Type{Bool}, x::Uns) = false

convert(::Type{Bool}, x::Vector{MethStCheck}) = all(mc -> isa(mc.check, Stb), x)

# Split method definition expression into name and argument types
split_def(def::Expr) = begin
    defparse = splitdef(def)
    fname    = defparse[:name]
    argtypes = map(a-> eval(splitarg(a)[2]), defparse[:args]) # [2] is arg type
    (fname, argtypes)
end

# Split method object into the corresponding function object and type signature
# of the method
split_method(m::Method) = begin
    msig = Base.unwrap_unionall(m.sig) # unwrap is critical for generic methods
    func = msig.parameters[1].instance
    sig_types = Vector{Any}([msig.parameters[2:end]...])
    (func, sig_types)
end


end # module
