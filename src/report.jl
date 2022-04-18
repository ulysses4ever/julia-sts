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

stCheckToExtraCsv(::StCheck) :: String = error("unknown check")
stCheckToExtraCsv(s::Stb)        = "$(s.steps)" * (s.skipexist == [] ? "" : ";" * string(s.skipexist))
stCheckToExtraCsv(::Uns)         = ""
stCheckToExtraCsv(::AnyParam)    = ""
stCheckToExtraCsv(::VarargParam) = ""
stCheckToExtraCsv(f::TcFail)     = "$(f.sig)"
stCheckToExtraCsv(::OutOfFuel)   = ""

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
end

showAgStats(m::Module, ags::AgStats) :: String =
    "$m,$(ags.methCnt),$(ags.stblCnt),$(ags.unsCnt),$(ags.anyCnt),$(ags.vaCnt),$(ags.tcfCnt),$(ags.nofCnt)"

aggregateStats(mcs::StCheckResults) :: AgStats = AgStats(
    length(mcs),
    count(mc -> isa(mc.check, Stb), mcs),
    count(mc -> isa(mc.check, Uns), mcs),
    count(mc -> isa(mc.check, AnyParam), mcs),
    count(mc -> isa(mc.check, VarargParam), mcs),
    count(mc -> isa(mc.check, TcFail), mcs),
    count(mc -> isa(mc.check, OutOfFuel), mcs),
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
