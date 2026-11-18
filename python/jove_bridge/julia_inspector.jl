let workspace = @__MODULE__
    rows = []
    for sym in Base.names(workspace; all=true, imported=false)
        name = Base.string(sym)
        if Base.startswith(name, "_") || Base.startswith(name, "#") ||
           Base.startswith(name, "@") || sym in (:In, :Out, :ans) || !isdefined(workspace, sym)
            continue
        end
        value = Core.getfield(workspace, sym)
        value isa Module && continue
        preview = try
            if value isa AbstractString
                Base.first(Base.repr(Base.first(value, 120)), 120)
            elseif value isa AbstractArray && Base.length(value) > 16
                Base.summary(value)
            else
                Base.first(Base.repr(value; context=:limit => true), 120)
            end
        catch
            "<repr failed>"
        end
        size = try
            n = Base.length(value)
            n isa Integer && !(n isa Bool) && 0 <= n <= typemax(Int) ? Int(n) : nothing
        catch
            nothing
        end
        Base.push!(rows, (; name, type=Base.string(Core.typeof(value)), value=preview, size))
    end
    writer = isdefined(Main.IJulia, :JSONX) ? Main.IJulia.JSONX : Main.IJulia.JSON
    Base.display("application/json", writer.json(rows))
    # IJulia sets ans even for silent requests. Return its old value to preserve it.
    Main.IJulia.ans
end
