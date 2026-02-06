#!/usr/bin/env julia
# TTFX diagnostics: invalidations + inference.
# Requires SnoopCompile (3.x supports Julia 1.12).
# Run from repo root:
#   julia --startup-file=no --project -e 'using Pkg; Pkg.add("SnoopCompile"); include("docs/ttfx_diagnostics.jl")'
# or, if SnoopCompile is already in the project:
#   julia --startup-file=no --project -e 'include("docs/ttfx_diagnostics.jl")'

using SnoopCompile  # loads SnoopCompileCore
using SnoopCompileCore
invalidations = @snoopr begin
    using EventRegistrations
end

using SnoopCompile
n = length(uinvalidated(invalidations))
println("=== Invalidations (from loading EventRegistrations) ===")
println("Unique invalidated methods: ", n)
if n > 0
    trees = invalidation_trees(invalidations)
    sort!(trees; by=t -> (length(t.triggered_codes), length(t.caused_by)), rev=true)
    println("\nTop invalidation trees (by triggered + caused):")
    for (i, t) in enumerate(trees[1:min(15, end)])
        println("  ", i, ". triggered: ", length(t.triggered_codes), " caused_by: ", length(t.caused_by))
        for (j, c) in enumerate(t.caused_by[1:min(3, end)])
            println("      caused: ", c)
        end
    end
end

println("\n=== Inference (minimal workload) ===")
using EventRegistrations
db = EventRegistrations.init_database(":memory:")
EventRegistrations.sync_event_configs_to_db!(db, mktempdir())
tinf = @snoopi_deep begin
    EventRegistrations.list_events(db)
    EventRegistrations.get_registrations(db, "dummy")
end
using DBInterface
DBInterface.close!(db)

# Summary (ROOT node: inclusive = total inference time)
using SnoopCompileCore: inclusive, exclusive
incl_s = inclusive(tinf)
excl_s = exclusive(tinf)
println("Inference: ROOT exclusive ", round(excl_s; digits=3), " s, inclusive ", round(incl_s; digits=3), " s")

# Triggers (runtime dispatch)
itrigs = inference_triggers(tinf)
mtrigs = accumulate_by_source(Method, itrigs)
er = filtermod(EventRegistrations, mtrigs)
println("Inference triggers in EventRegistrations: ", length(er))
for (meth, triggers) in sort(collect(er); by=x->length(x[2]), rev=true)[1:min(20, end)]
    println("  ", length(triggers), " triggers  ", meth)
end

# Optional: suggest fixes
if length(itrigs) > 0
    println("\nSuggestions (first 5):")
    for (i, s) in enumerate(suggest.(itrigs))
        i > 5 && break
        isignorable(s) && continue
        println("  ", s)
    end
end
