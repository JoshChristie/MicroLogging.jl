using MicroLogging
using Base.Test

import MicroLogging: LogLevel, BelowMinLevel, Debug, Info, Warn, Error, NoLogs

if VERSION < v"0.6-"
    # Override Test.@test_broken, which is broken on julia-0.5!
    # See https://github.com/JuliaLang/julia/issues/21008
    macro test_broken(exs...)
        esc(:(@test !($(exs...))))
    end
end

# Test helpers

mutable struct LogRecord
    level
    message
    module_
    filepath
    line
    id
    kwargs
end

LogRecord(args...; kwargs...) = LogRecord(args..., kwargs)
LogRecord(level, msg, module_=nothing, filepath=nothing, line=nothing, id=nothing; kwargs...) = LogRecord(level, msg, module_, filepath, line, id, kwargs)

mutable struct TestLogger
    records::Vector{LogRecord}
    min_level::LogLevel
end

TestLogger(min_level=BelowMinLevel) = TestLogger(LogRecord[], min_level)

function MicroLogging.shouldlog(logger::TestLogger, level, module_, filepath, line, id, max_log, progress)
    level >= logger.min_level
end

function MicroLogging.logmsg(logger::TestLogger, level, msg, module_, filepath, line, id; kwargs...)
    push!(logger.records, LogRecord(level, msg, module_, filepath, line, id, kwargs))
end

function collect_logs(f::Function, min_level=BelowMinLevel)
    logger = TestLogger(min_level)
    with_logger(f, logger)
    logger.records
end

function record_matches(r, ref::Tuple)
    if length(ref) == 1
        return (r.level,) == ref
    else
        return (r.level, r.message) == ref
    end
end

function record_matches(r, ref::LogRecord)
    (r.level, r.message) == (ref.level, ref.message)        || return false
    (ref.module_  == nothing || r.module_  == ref.module_)  || return false
    (ref.filepath == nothing || r.filepath == ref.filepath) || return false
    (ref.line     == nothing || r.line     == ref.line)     || return false
    (ref.id       == nothing || r.id       == ref.id)       || return false
    rkw = Dict(r.kwargs)
    for (k,v) in ref.kwargs
        (haskey(rkw, k) && rkw[k] == v) || return false
    end
    return true
end

# Use superset operator for improved log message reporting in @test
⊃(r::LogRecord, ref) = record_matches(r, ref)


#-------------------------------------------------------------------------------
#-------------------------------------------------------------------------------
@testset "MicroLogging" begin

@testset "Basic logging" begin
    logs = collect_logs() do
        @debug "a"
        @info  "b"
        @warn  "c"
        @error "d"
    end
    @test logs[1] ⊃ (Debug, "a")
    @test logs[2] ⊃ (Info , "b")
    @test logs[3] ⊃ (Warn , "c")
    @test logs[4] ⊃ (Error, "d")
    @test length(logs) == 4
end


#-------------------------------------------------------------------------------
# Front end

@testset "Log message formatting" begin
    logs = collect_logs() do
        # Message may be formatted any way the user pleases
        @info begin
            A = ones(4,4)
            "sum(A) = $(sum(A))"
        end
        x = 10.50
        @info "$x"
        @info @sprintf("%.3f", x)
    end

    @test logs[1] ⊃ (Info, "sum(A) = 16.0")
    @test logs[2] ⊃ (Info, "10.5")
    @test logs[3] ⊃ (Info, "10.500")
    @test length(logs) == 3
end

@testset "Programmatically defined levels" begin
    logs = collect_logs() do
        for level ∈ [Info,Warn]
            @logmsg level "X"
        end
    end

    @test logs[1] ⊃ (Info, "X")
    @test logs[2] ⊃ (Warn, "X")
    @test length(logs) == 2
end

@testset "Structured logging with key value pairs" begin
    foo_val = 10
    logs = collect_logs() do
        @info "test" progress=0.1 foo=foo_val real_line=(@__LINE__)
    end
    @test length(logs) == 1

    record = logs[1]

    kwargs = Dict(record.kwargs)

    # Builtin metadata
    @test record.module_ == Main
    @test record.filepath == Base.source_path()
    if Compat.macros_have_sourceloc # See #1
        @test record.line == kwargs[:real_line]
    end
    @test isa(record.id, Symbol)

    # User-defined metadata
    @test kwargs[:progress] == 0.1
    @test kwargs[:foo] == foo_val
end

@testset "Formatting exceptions are caught inside the logger" begin
    logs = collect_logs() do
        @info "foo $(1÷0)"
        @info "bar"
    end
    @test logs[1] ⊃ (Error,)
    @test logs[2] ⊃ (Info,"bar")
    @test length(logs) == 2
end

@testset "Special keywords" begin
    logs = collect_logs() do
        @info "foo" id=:asdf
    end
    @test length(logs) == 1
    record = logs[1]
    @test record.id == :asdf
    # TODO: More testing here, for interaction of special keywords with the
    # shouldlog() function.
end


#-------------------------------------------------------------------------------
# Very early task-global log filtering via disable_logging()
@testset "Early log filtering" begin
    function log_each_level()
        collect_logs() do
            @debug "a"
            @info  "b"
            @warn  "c"
            @error "d"
        end
    end

    disable_logging(BelowMinLevel)
    logs = log_each_level()
    @test logs[1] ⊃ (Debug, "a")
    @test logs[2] ⊃ (Info , "b")
    @test logs[3] ⊃ (Warn , "c")
    @test logs[4] ⊃ (Error, "d")
    @test length(logs) == 4

    disable_logging(Debug)
    logs = log_each_level()
    @test logs[1] ⊃ (Info , "b")
    @test logs[2] ⊃ (Warn , "c")
    @test logs[3] ⊃ (Error, "d")
    @test length(logs) == 3

    disable_logging(Info)
    logs = log_each_level()
    @test logs[1] ⊃ (Warn , "c")
    @test logs[2] ⊃ (Error, "d")
    @test length(logs) == 2

    disable_logging(Warn)
    logs = log_each_level()
    @test logs[1] ⊃ (Error, "d")
    @test length(logs) == 1

    disable_logging(Error)
    logs = log_each_level()
    @test length(logs) == 0

    # Reset to default
    disable_logging(BelowMinLevel)
end

@eval module A
    using MicroLogging
    function a()
        @debug "a"
        @info  "a"
        @warn  "a"
        @error "a"
    end

    module B
        using MicroLogging
        function b()
            @debug "b"
            @info  "b"
            @warn  "b"
            @error "b"
        end
    end
end

@testset "Disabling logging with the module heirarchy" begin
    logs = collect_logs() do
        disable_logging(A, Info)
        A.a()
        A.B.b()
        disable_logging(A.B, Warn)
        A.a()
        A.B.b()
    end

    @test logs[1] ⊃ LogRecord(Warn , "a", A)
    @test logs[2] ⊃ LogRecord(Error, "a", A)
    @test logs[3] ⊃ LogRecord(Warn , "b", A.B)
    @test logs[4] ⊃ LogRecord(Error, "b", A.B)

    @test logs[5] ⊃ LogRecord(Warn , "a", A)
    @test logs[6] ⊃ LogRecord(Error, "a", A)
    @test logs[7] ⊃ LogRecord(Error, "b", A.B)

    @test length(logs) == 7

    # Reset to default
    disable_logging(BelowMinLevel)
end


#-------------------------------------------------------------------------------

# Custom log levels

@eval module LogLevelTest
    using MicroLogging

    struct MyLevel
        level::Int
    end

    const critical = MyLevel(10000)
    const debug_verbose = MyLevel(-10000)

    # FIXME - should remove the need to mention LogLimit here.
    MicroLogging.shouldlog(lg::MicroLogging.LogLimit, l2::MyLevel) = Int(lg.max_disabled_level) < l2.level
    # Following needed for use in shouldlog(::TestLogger, ...)
    Base.:<(l1::MyLevel, l2::MicroLogging.LogLevel) = l1.level < Int(l2)
end

@testset "Custom log levels" begin
    logs = collect_logs(Info) do
        @logmsg LogLevelTest.critical "blah"
        @logmsg LogLevelTest.debug_verbose "blah"
    end

    @test logs[1] ⊃ (LogLevelTest.critical, "blah")
    @test length(logs) == 1
end


#-------------------------------------------------------------------------------

include("util.jl")

end
