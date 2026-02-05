# Precompile Time and TTFX (Time To First Execution) — Diagnostics and Improvements

This document summarizes **tools and practices** for diagnosing and improving Julia package **precompile time** and **time to first execution (TTFX)**, and how they apply to EventRegistrations.jl.

---

## 1. Tools for Diagnosing Precompile / TTFX

### 1.1 PrecompileTools.jl (already in use)

- **Purpose**: Reduce first-usage latency by forcing precompilation of specific workloads.
- **Macros**:
  - **`@compile_workload`**: Precompiles all code needed to run a workload (including callees across packages). Best on Julia 1.9+.
  - **`@setup_workload`**: Code that runs only during precompilation (e.g. building toy data) but does *not* force compilation of that code.
  - **`@recompile_invalidations`**: Recompiles code invalidated by loading the package; use in “Startup” packages or when extending Base/other packages.
- **Docs**: <https://julialang.github.io/PrecompileTools.jl/stable/>
- **Tip**: Set `PrecompileTools.verbose[] = true` and `include("src/EventRegistrations.jl")` to see which method instances get precompiled.

### 1.2 SnoopCompile.jl (diagnostics)

- **Purpose**: Find *what* is being compiled and *why* latency is high (inference time, invalidations).
- **Workflow** (recommended order):
  1. **Check invalidations** with `@snoopr` (see below).
  2. **Record inference** with `@snoopi_deep` on a representative workload.
  3. **Analyze**: inferrability, method specialization, then add/fix precompile or code.

**Key macros / functions:**

| Tool | Purpose |
|------|--------|
| **`@snoopr`** | Record *invalidations* caused by loading the package (or defining methods). Run *before* other heavy compilation. |
| **`@snoopi`** | Coarse inference-time per top-level method. Good for a quick “who is slow.” |
| **`@snoopi_deep`** | Detailed inference tree (exclusive/inclusive time). Use for finding inference bottlenecks and runtime dispatch. |
| **`inference_triggers`**, **`accumulate_by_source`** | Find call sites that trigger new inference (runtime dispatch). |
| **`suggest(itrig)`** | Suggests fixes (e.g. type annotations, homogenize varargs, add `show` methods). |
| **`parcel`** | Split inference triggers by module; can generate `precompile` directives. |

**Docs**: <https://timholy.github.io/SnoopCompile.jl/stable/>

**Minimal invalidation check (run in a fresh session, no Revise in startup):**

```julia
# Start Julia with: julia --startup-file=no
using SnoopCompileCore
invalidations = @snoopr begin
    using EventRegistrations
end
using SnoopCompile
length(uinvalidated(invalidations))  # count
trees = invalidation_trees(invalidations)  # inspect
```

**Minimal inference profiling (after loading the package):**

```julia
using SnoopCompile
using EventRegistrations

# Representative workload (e.g. in-memory DB + a few calls)
db = EventRegistrations.init_database(":memory:")
EventRegistrations.list_events(db)
EventRegistrations.get_registrations(db, "dummy")

tinf = @snoopi_deep begin
    EventRegistrations.list_events(db)
    EventRegistrations.get_registrations(db, "dummy")
end

# Inspect
using ProfileView  # or SnoopCompile's flamegraph)
fg = flamegraph(tinf)
ProfileView.view(fg)

# Triggers (runtime dispatch / new inference)
itrigs = inference_triggers(tinf)
mtrigs = accumulate_by_source(Method, itrigs)
# Filter to this package
filtermod(EventRegistrations, mtrigs)
```

### 1.3 JET.jl and Cthulhu.jl

- **JET**: Static analysis for type errors and inference failures. Complements SnoopCompile (reproducible, but stops at first non-inferrable call).
- **Cthulhu**: Interactive “descend into typed code” to see why inference failed. Use with SnoopCompile’s `ascend(itrig)` for invalidation/inference chains.

### 1.4 PackageCompiler.jl

- **Purpose**: Build a custom system image (Julia + selected packages) that caches both inference and native code.
- **Use case**: End users who want minimal TTFX and rarely update packages. Not ideal for package *development* (any update requires a full rebuild).

---

## 2. What EventRegistrations.jl Does

- **PrecompileTools**: Used in `src/EventRegistrations.jl`: `@setup_workload` + `@compile_workload` to precompile:
  - **Always**: a minimal workload (in-memory DB, empty events dir, `list_events`, `get_registrations`) so the package loads even without any data directory.
  - **When `playground/` is present** (e.g. dev or full repo): a fuller workload using playground data: sync event configs, `process_email_folder!` on `playground/emails/`, `recalculate_costs!` for `PWE_2026_01`, `get_payment_summary`, `get_payment_table_data`, `export_payment_csv`, `get_registration_table_data`, and `get_registration_detail_table`. That precompiles email parsing, cost calculation, and export paths without relying on `testingfolder`.

---

## 3. Likely “Worst Offenders” and How to Improve Them

These are the usual suspects for TTFX in a package like EventRegistrations.jl. Use SnoopCompile (and optionally JET) to confirm and prioritize.

| Area | Why it hurts TTFX | Options to improve |
|------|-------------------|---------------------|
| **DuckDB / DBInterface** | First use of DB connection and queries compiles a lot of generic code. | Keep current `@compile_workload` with `init_database(":memory:")` and a few queries (e.g. `list_events`, `get_registrations`). Add more representative queries if SnoopCompile shows big inference in DB code paths. |
| **JSON / TOML parsing** | Parsing and `Dict`/struct construction can be poorly inferred. | Add type assertions or small wrapper functions with concrete types where possible; avoid `Dict{String,Any}` in hot paths if you can use typed structs. |
| **Config loading (TOML, event configs)** | `load_event_config`, `sync_event_configs_to_db!` touch many types and file I/O. | Precompile with an empty or minimal `config_dir` (already done in minimal workload). For heavy config paths, ensure key functions are called in `@compile_workload` with concrete paths/types. |
| **CostCalculator / rules** | Complex rules and `Dict`/regex can cause inference and specialization. | Use `@snoopi_deep` on `calculate_cost`/`calculate_cost_with_details`; add type annotations or `@nospecialize` where appropriate; precompile one or two concrete rule sets in `@compile_workload`. |
| **PrettyTables / TableExport / PDF/LaTeX** | First table render and first PDF/LaTeX run pull in large dependencies. | Precompile a minimal “print one table” and, if needed, one “export to CSV” path; defer heavy PDF/LaTeX to lazy compilation unless you want them in precompile. |
| **HTTP / WebDAV** | First request compiles HTTP stack. | If WebDAV is common, add a trivial (e.g. no-op or mock) call in `@compile_workload`; otherwise leave for first real use. |
| **Email (Mustache, SMTPClient)** | First template render and first send compile Mustache and SMTP. | Precompile a single `preview_email` or `render` call with a minimal template and one registration-like struct if that’s a critical path. |
| **REPL / LineEdit (CLI)** | First `run_cli` / REPL usage compiles REPL and option parsing. | Hard to precompile all branches; keep one or two CLI invocations in `@compile_workload` (e.g. `status`, `list-registrations`) if they are the main entry points. |
| **Method invalidations** | New methods (e.g. extending Base or DBInterface) can invalidate previously compiled code. | Run `@snoopr using EventRegistrations` and fix or narrow method definitions; prefer concrete types and inferrable code; consider `@recompile_invalidations` only for known, unavoidable invalidations. |

### 3.1 Quick checklist for “first session” improvements

1. Run **`@snoopr`** when loading EventRegistrations; if invalidation count is high, inspect `invalidation_trees` and fix the worst offenders (type stability, avoid type piracy).
2. Run **`@snoopi_deep`** on a small but representative workload (e.g. init DB + list_events + get_registrations + one export or one cost calculation).
3. **Filter by module**: `filtermod(EventRegistrations, mtrigs)` and fix inference in this package first; then consider key dependencies (DuckDB, Config, PrettyOutput).
4. **Precompile**: Ensure `@compile_workload` covers the same workload you measured; add more calls only if they show up as large inference nodes and are on the critical path.
5. **Heavy optional features** (PDF, LaTeX, WebDAV, email send): Either add minimal “warmup” calls to `@compile_workload` or accept their cost on first use.

---

## 4. References

- PrecompileTools: <https://julialang.github.io/PrecompileTools.jl/stable/>
- PrecompileTools invalidations: <https://julialang.github.io/PrecompileTools.jl/stable/invalidations/>
- SnoopCompile: <https://timholy.github.io/SnoopCompile.jl/stable/>
- SnoopCompile invalidations (`@snoopr`): <https://timholy.github.io/SnoopCompile.jl/stable/snoopr/>
- SnoopCompile inference analysis (`@snoopi_deep`): <https://timholy.github.io/SnoopCompile.jl/stable/snoopi_deep_analysis/>
- Julia blog: Invalidations — <https://julialang.org/blog/2020/08/invalidations/>
