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
- **Compatibility**: SnoopCompile 3.x supports Julia 1.12 (see [Project.toml](https://github.com/JuliaDebug/SnoopCompile.jl/blob/master/Project.toml) on master).
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
  - **Always**: A minimal workload so the package loads fast even without any data directory:
    - `init_database(":memory:")`, `list_events(db)`, `get_registrations(db, "dummy")`
    - **Pretty-print to captured IO**: `get_payment_table_data`, `print_payment_table(..., io=IOBuffer())`, `get_registration_table_data`, `print_registration_table(..., io=IOBuffer())`. This warms PrettyTables, Crayons, and terminal table code paths so the first `list-registrations` or `export-payment-status` to terminal is fast.
  - **When `test/assets/` exists** (e.g. dev or full repo): A fuller workload:
    - `run_cli(["sync", "--export-details=--format=csv", "--export-payments=--format=csv"])`
    - Then explicit **pretty-printing to IOBuffer**: payment table, registration table, and registration detail table (when rows exist). This precompiles the same terminal-output paths with real data and highlighters.

### 2.1 Automated analysis script

- **`scripts/analyze_precompile.jl`** runs a cost and inference report in one go:
  1. **Invalidations**: `@snoopr` while loading EventRegistrations; prints unique invalidation count and sample trees.
  2. **Inference cost**: `@snoopi_deep` on a representative workload (in-memory DB, list_events, get_registrations, get_payment_table_data, print_payment_table to IO, get_registration_table_data, print_registration_table to IO). Reports total inference time, top nodes by inclusive time, inference trigger count, triggers in this package, and `suggest()` hints.
  3. **Optional JET**: If JET is loaded, runs a quick type-stability check on `get_payment_table_data`.

**How to run (from package root):**

```bash
# One-off: add SnoopCompile to the main project, then run
julia --project -e 'using Pkg; Pkg.add("SnoopCompile"); Pkg.add("SnoopCompileCore")'
julia --startup-file=no --project -e 'include("scripts/analyze_precompile.jl")'
```

Use the script output to prioritize: fix invalidations first, then reduce inference triggers in EventRegistrations (type annotations, `show` methods, homogenize varargs), then add more `@compile_workload` calls only for hot paths that remain.

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

### 3.1 Type stability and inference

- **Improve inferrability** where `suggest(itrig)` or JET point to your code: add type annotations, avoid `Dict{String,Any}` in hot paths (use typed structs or `@nospecialize`), homogenize varargs, and add `show(io, ::MIME"text/plain", x::YourType)` for custom types that appear in tables or REPL output.
- **Pretty-printing**: Printing to a captured `IOBuffer` in `@compile_workload` (as done for payment/registration tables) fixes first-terminal-table latency by forcing compilation of PrettyTables, Crayons, and your table/highlighter code. Add similar warmup for any other `pretty_table` or custom `show` paths on the critical path.

### 3.2 Quick checklist for “first session” improvements

1. Run **`scripts/analyze_precompile.jl`** (or **`@snoopr`** when loading EventRegistrations); if invalidation count is high, inspect `invalidation_trees` and fix the worst offenders (type stability, avoid type piracy).
2. Run **`@snoopi_deep`** on a small but representative workload (same as in the script: DB + list_events + get_registrations + table data + print to IO).
3. **Filter by module**: `filtermod(EventRegistrations, mtrigs)` and fix inference in this package first; then consider key dependencies (DuckDB, Config, PrettyOutput).
4. **Precompile**: Ensure `@compile_workload` covers the same workload you measured; add more calls (e.g. pretty-print to IO) only if they show up as large inference nodes and are on the critical path.
5. **Heavy optional features** (PDF, LaTeX, WebDAV, email send): Either add minimal “warmup” calls to `@compile_workload` or accept their cost on first use.

---

## 4. Optional: TTFX diagnostics script

- **Location**: `docs/ttfx_diagnostics.jl`
- **Purpose**: Run `@snoopr` (invalidations) and `@snoopi_deep` (inference) on a minimal workload and print a short report.
- **Requirements**: Add SnoopCompile to the project (or use a temporary env); SnoopCompile 3.x supports Julia 1.12.
- **Usage**:
  ```bash
  julia --startup-file=no --project -e 'using Pkg; Pkg.add("SnoopCompile"); include("docs/ttfx_diagnostics.jl")'
  ```
  Or add SnoopCompile to the project, then:
  ```bash
  julia --startup-file=no --project -e 'include("docs/ttfx_diagnostics.jl")'
  ```

---

## 5. References

- PrecompileTools: <https://julialang.github.io/PrecompileTools.jl/stable/>
- PrecompileTools invalidations: <https://julialang.github.io/PrecompileTools.jl/stable/invalidations/>
- SnoopCompile: <https://timholy.github.io/SnoopCompile.jl/stable/>
- SnoopCompile invalidations (`@snoopr`): <https://timholy.github.io/SnoopCompile.jl/stable/snoopr/>
- SnoopCompile inference analysis (`@snoopi_deep`): <https://timholy.github.io/SnoopCompile.jl/stable/snoopi_deep_analysis/>
- Julia blog: Invalidations — <https://julialang.org/blog/2020/08/invalidations/>

---

## 6. Measuring load time

- **First load (cold)**: Includes precompilation; run once after changing code or dependencies (e.g. `julia --startup-file=no --project -e 'using EventRegistrations'`).
- **Subsequent loads (warm, TTFX)**: Time to `using EventRegistrations` after precompilation is already done. This is the latency users see on normal use.
- Typical warm load is on the order of 1–2 seconds depending on machine; cold load is dominated by precompilation (tens of seconds) and is one-time per environment.
