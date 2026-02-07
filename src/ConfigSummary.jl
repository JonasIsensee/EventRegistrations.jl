"""
ConfigSummary - Event Configuration Summary and Cost Combination Analysis

This module provides functions to analyze event configurations and generate
summaries showing all possible cost combinations. This is useful for validating
that cost rules are correctly configured before processing registrations.
"""
module ConfigSummary

using DBInterface: DBInterface
using DuckDB: DuckDB
using PrettyTables: pretty_table, ft_printf, hl_row

using ..Config: EventConfig, load_event_config, materialize_cost_rules
using ..CostCalculator: calculate_cost_with_details, CostCalculationResult

export ConfigSummaryResult, CostCombination
export generate_config_summary, print_config_summary
export get_all_field_values, generate_cost_combinations

"""
Represents a single cost combination - a set of field values and resulting cost.
"""
struct CostCombination
    fields::Dict{String, String}       # Field name → value
    cost::Float64                       # Calculated cost
    cost_breakdown::Vector{Tuple{String, Float64}}  # Rule descriptions and costs
    base_cost::Float64                  # Base cost
end

"""
Result of analyzing an event configuration.
"""
struct ConfigSummaryResult
    event_id::String
    event_name::String
    base_cost::Float64
    aliases::Dict{String, String}       # alias → actual field name
    rules::Vector{Dict{String, Any}}    # Cost rules
    computed_fields::Dict{String, Any}  # Computed fields (multipliers)
    field_values::Dict{String, Vector{String}}  # field → possible values
    combinations::Vector{CostCombination}       # All unique cost combinations
    unique_costs::Vector{Float64}       # Sorted list of unique costs
    warnings::Vector{String}            # Any warnings during analysis
end

"""
    get_all_field_values(cfg::EventConfig; db::Union{DuckDB.DB, Nothing}=nothing)

Extract all fields referenced in cost rules and their possible values.
Returns a Dict mapping field names to vectors of possible values.

If a database is provided, also looks up actual values from registrations.
"""
function get_all_field_values(cfg::EventConfig; db::Union{DuckDB.DB, Nothing}=nothing)
    field_values = Dict{String, Set{String}}()
    
    # Extract fields and values from rules
    for rule in cfg.rules
        field = get(rule, "field", "")
        isempty(field) && continue
        
        if !haskey(field_values, field)
            field_values[field] = Set{String}()
        end
        
        # Get explicit value
        if haskey(rule, "value")
            push!(field_values[field], string(rule["value"]))
        end
        
        # For pattern rules, we need to provide both matching and non-matching values
        # We'll add a placeholder for "matches pattern" and "doesn't match"
        if haskey(rule, "pattern")
            pattern = rule["pattern"]
            # Add a value that would match the pattern
            push!(field_values[field], "[matches: $pattern]")
            push!(field_values[field], "[no match]")
        end
        
        # Check unless/only_if conditions for additional fields
        for cond_key in ["unless", "only_if"]
            if haskey(rule, cond_key)
                conditions = rule[cond_key]
                conditions = conditions isa AbstractVector ? conditions : [conditions]
                for cond in conditions
                    if cond isa AbstractDict
                        cond_field = get(cond, "field", "")
                        if !isempty(cond_field)
                            if !haskey(field_values, cond_field)
                                field_values[cond_field] = Set{String}()
                            end
                            if haskey(cond, "value")
                                push!(field_values[cond_field], string(cond["value"]))
                            end
                        end
                    end
                end
            end
        end
    end
    
    # Extract fields from computed fields (multipliers)
    for (name, definition) in cfg.computed_fields
        if definition isa Dict && haskey(definition, "sum_of")
            for item in definition["sum_of"]
                field = get(item, "field", "")
                if !isempty(field)
                    if !haskey(field_values, field)
                        field_values[field] = Set{String}()
                    end
                    if haskey(item, "value")
                        push!(field_values[field], string(item["value"]))
                    end
                end
            end
        end
    end
    
    # For each field with values, add a "not selected" option
    for (field, values) in field_values
        if !isempty(values)
            # Add "Nein" or empty as non-selected option (common in German forms)
            push!(values, "Nein")
        end
    end
    
    # If database provided, also get actual values from registrations
    if db !== nothing
        try
            result = DBInterface.execute(db, """
                SELECT DISTINCT json_keys(fields) as keys
                FROM registrations 
                WHERE event_id = ? AND deleted_at IS NULL
            """, [cfg.event_id])
            
            for row in result
                if row[1] !== nothing
                    for field in row[1]
                        if !haskey(field_values, field)
                            field_values[field] = Set{String}()
                        end
                    end
                end
            end
            
            # Get actual values for fields we know about
            for field in keys(field_values)
                result = DBInterface.execute(db, """
                    SELECT DISTINCT json_extract_string(fields, ?) as val
                    FROM registrations
                    WHERE event_id = ? AND deleted_at IS NULL
                    AND json_extract_string(fields, ?) IS NOT NULL
                    LIMIT 20
                """, [field, cfg.event_id, field])
                
                for row in result
                    if row[1] !== nothing
                        push!(field_values[field], row[1])
                    end
                end
            end
        catch e
            @warn "Could not fetch field values from database" exception=e
        end
    end
    
    # Convert to sorted vectors
    result = Dict{String, Vector{String}}()
    for (field, values) in field_values
        result[field] = sort(collect(values))
    end
    
    return result
end

"""
    generate_cost_combinations(cfg::EventConfig, field_values::Dict{String, Vector{String}})

Generate all possible combinations of field values and calculate the cost for each.
Returns only unique cost combinations (deduplicates combinations with same cost).
"""
function generate_cost_combinations(cfg::EventConfig, field_values::Dict{String, Vector{String}})
    combinations = CostCombination[]
    rules = materialize_cost_rules(cfg)
    
    # Get all fields and their values
    fields = collect(keys(field_values))
    
    if isempty(fields)
        # No fields - just base cost
        empty_fields = Dict{String, String}()
        result = calculate_cost_with_details(rules, empty_fields)
        push!(combinations, CostCombination(
            empty_fields,
            result.total,
            result.rule_costs,
            result.base
        ))
        return combinations
    end
    
    # Generate all combinations using iterative approach
    # (avoid exponential blowup by limiting combinations)
    value_lists = [field_values[f] for f in fields]
    num_combinations = prod(length.(value_lists))
    
    # Limit to prevent memory issues
    max_combinations = 10000
    if num_combinations > max_combinations
        @warn "Too many combinations ($num_combinations), sampling subset" max=max_combinations
        # Sample random combinations instead
        return generate_sampled_combinations(cfg, field_values, max_combinations)
    end
    
    # Generate all combinations
    seen_costs = Dict{Float64, CostCombination}()
    
    for indices in Iterators.product([1:length(v) for v in value_lists]...)
        field_dict = Dict{String, String}()
        for (i, field) in enumerate(fields)
            field_dict[field] = value_lists[i][indices[i]]
        end
        
        # Skip combinations with placeholder pattern matches that don't make sense
        skip = false
        for (field, value) in field_dict
            if startswith(value, "[matches:") || value == "[no match]"
                # These are pattern placeholders - handle specially
                skip = true
                break
            end
        end
        skip && continue
        
        result = calculate_cost_with_details(rules, field_dict)
        
        # Store unique combinations by cost (keep first occurrence for each cost)
        if !haskey(seen_costs, result.total)
            seen_costs[result.total] = CostCombination(
                field_dict,
                result.total,
                result.rule_costs,
                result.base
            )
        end
    end
    
    # Sort by cost
    return sort(collect(values(seen_costs)), by=c -> c.cost)
end

"""
Generate sampled combinations when total space is too large.
"""
function generate_sampled_combinations(cfg::EventConfig, field_values::Dict{String, Vector{String}}, max_samples::Int)
    combinations = CostCombination[]
    rules = materialize_cost_rules(cfg)
    fields = collect(keys(field_values))
    
    seen_costs = Dict{Float64, CostCombination}()
    
    for _ in 1:max_samples
        field_dict = Dict{String, String}()
        for field in fields
            values = field_values[field]
            if !isempty(values)
                field_dict[field] = rand(values)
            end
        end
        
        # Skip pattern placeholders
        skip = false
        for (field, value) in field_dict
            if startswith(value, "[matches:") || value == "[no match]"
                skip = true
                break
            end
        end
        skip && continue
        
        result = calculate_cost_with_details(rules, field_dict)
        
        if !haskey(seen_costs, result.total)
            seen_costs[result.total] = CostCombination(
                field_dict,
                result.total,
                result.rule_costs,
                result.base
            )
        end
    end
    
    return sort(collect(values(seen_costs)), by=c -> c.cost)
end

"""
    generate_config_summary(event_id::String; events_dir::String="events", db::Union{DuckDB.DB, Nothing}=nothing)

Generate a complete summary of an event configuration including all possible cost combinations.
"""
function generate_config_summary(event_id::String; events_dir::String="events", db::Union{DuckDB.DB, Nothing}=nothing)
    warnings = String[]
    
    # Load config
    cfg = load_event_config(event_id, events_dir)
    if cfg === nothing
        return ConfigSummaryResult(
            event_id, event_id, 0.0,
            Dict{String, String}(),
            Dict{String, Any}[],
            Dict{String, Any}(),
            Dict{String, Vector{String}}(),
            CostCombination[],
            Float64[],
            ["Event configuration not found: $event_id.toml in $events_dir"]
        )
    end
    
    # Get field values
    field_values = get_all_field_values(cfg; db=db)
    
    if isempty(field_values)
        push!(warnings, "No fields found in cost rules. Only base cost will be applied.")
    end
    
    # Generate combinations
    combinations = generate_cost_combinations(cfg, field_values)
    
    # Extract unique costs
    unique_costs = sort(unique([c.cost for c in combinations]))
    
    return ConfigSummaryResult(
        cfg.event_id,
        cfg.name,
        cfg.base_cost,
        cfg.aliases,
        cfg.rules,
        cfg.computed_fields,
        field_values,
        combinations,
        unique_costs,
        warnings
    )
end

"""
    print_config_summary(summary::ConfigSummaryResult; io::IO=stdout, verbose::Bool=false)

Print a formatted summary of an event configuration.
"""
function print_config_summary(summary::ConfigSummaryResult; io::IO=stdout, verbose::Bool=false)
    println(io, "")
    println(io, "═══════════════════════════════════════════════════════════════════════════════")
    println(io, "EVENT CONFIGURATION SUMMARY: $(summary.event_id)")
    println(io, "═══════════════════════════════════════════════════════════════════════════════")
    println(io, "")
    
    # Event info
    println(io, "Event Name: $(summary.event_name)")
    println(io, "Base Cost:  $(summary.base_cost) €")
    println(io, "")
    
    # Warnings
    if !isempty(summary.warnings)
        println(io, "⚠️  WARNINGS:")
        for w in summary.warnings
            println(io, "  • $w")
        end
        println(io, "")
    end
    
    # Field aliases
    if !isempty(summary.aliases) && verbose
        println(io, "───────────────────────────────────────────────────────────────────────────────")
        println(io, "FIELD ALIASES")
        println(io, "───────────────────────────────────────────────────────────────────────────────")
        for (alias, actual) in sort(collect(summary.aliases))
            println(io, "  $alias → \"$actual\"")
        end
        println(io, "")
    end
    
    # Cost rules
    if !isempty(summary.rules)
        println(io, "───────────────────────────────────────────────────────────────────────────────")
        println(io, "COST RULES ($(length(summary.rules)) rules)")
        println(io, "───────────────────────────────────────────────────────────────────────────────")
        for (i, rule) in enumerate(summary.rules)
            field = get(rule, "field", "?")
            cost = get(rule, "cost", 0.0)
            cost_str = cost >= 0 ? "+$(cost)" : "$(cost)"
            
            if haskey(rule, "value")
                println(io, "  [$i] $field = \"$(rule["value"])\" → $cost_str €")
            elseif haskey(rule, "pattern")
                println(io, "  [$i] $field ~ /$(rule["pattern"])/ → $cost_str €")
            end
            
            # Show multiply_by
            if haskey(rule, "multiply_by")
                println(io, "       (× $(rule["multiply_by"]))")
            end
            
            # Show conditions
            if haskey(rule, "unless")
                conditions = rule["unless"]
                conditions = conditions isa AbstractVector ? conditions : [conditions]
                for cond in conditions
                    if cond isa AbstractDict
                        cf = get(cond, "field", "?")
                        cv = get(cond, "value", get(cond, "pattern", "?"))
                        println(io, "       unless $cf = \"$cv\"")
                    end
                end
            end
            if haskey(rule, "only_if")
                conditions = rule["only_if"]
                conditions = conditions isa AbstractVector ? conditions : [conditions]
                for cond in conditions
                    if cond isa AbstractDict
                        cf = get(cond, "field", "?")
                        cv = get(cond, "value", get(cond, "pattern", "?"))
                        println(io, "       only_if $cf = \"$cv\"")
                    end
                end
            end
        end
        println(io, "")
    end
    
    # Computed fields
    if !isempty(summary.computed_fields) && verbose
        println(io, "───────────────────────────────────────────────────────────────────────────────")
        println(io, "COMPUTED FIELDS (multipliers)")
        println(io, "───────────────────────────────────────────────────────────────────────────────")
        for (name, definition) in summary.computed_fields
            if definition isa Dict && haskey(definition, "sum_of")
                println(io, "  $name = sum of:")
                for item in definition["sum_of"]
                    f = get(item, "field", "?")
                    v = get(item, "value", "?")
                    c = get(item, "count", 1)
                    println(io, "    + $c if $f = \"$v\"")
                end
            end
        end
        println(io, "")
    end
    
    # Fields and possible values
    if !isempty(summary.field_values)
        println(io, "───────────────────────────────────────────────────────────────────────────────")
        println(io, "FIELDS AND POSSIBLE VALUES")
        println(io, "───────────────────────────────────────────────────────────────────────────────")
        for (field, values) in sort(collect(summary.field_values))
            values_str = join(values, ", ")
            if length(values_str) > 60
                values_str = values_str[1:57] * "..."
            end
            println(io, "  $field: $values_str")
        end
        println(io, "")
    end
    
    # Cost combinations
    println(io, "───────────────────────────────────────────────────────────────────────────────")
    println(io, "POSSIBLE COSTS ($(length(summary.unique_costs)) unique values)")
    println(io, "───────────────────────────────────────────────────────────────────────────────")
    
    if isempty(summary.combinations)
        println(io, "  No cost combinations found.")
    else
        # Show unique costs summary
        println(io, "")
        println(io, "  Unique cost values: $(join(["$(c) €" for c in summary.unique_costs], ", "))")
        println(io, "  Range: $(minimum(summary.unique_costs)) € - $(maximum(summary.unique_costs)) €")
        println(io, "")
        
        # Detailed breakdown of combinations leading to each cost
        println(io, "───────────────────────────────────────────────────────────────────────────────")
        println(io, "COST BREAKDOWN BY AMOUNT")
        println(io, "───────────────────────────────────────────────────────────────────────────────")
        
        for combo in summary.combinations
            println(io, "")
            println(io, "  $(combo.cost) € :")
            println(io, "    Base: $(combo.base_cost) €")
            
            if !isempty(combo.cost_breakdown)
                for (desc, rule_cost) in combo.cost_breakdown
                    sign = rule_cost >= 0 ? "+" : ""
                    println(io, "    $sign$(rule_cost) € : $desc")
                end
            end
            
            # Show the field combination that produces this cost
            if verbose && !isempty(combo.fields)
                println(io, "    Selection:")
                for (field, value) in sort(collect(combo.fields))
                    println(io, "      • $field = \"$value\"")
                end
            end
        end
    end
    
    println(io, "")
    println(io, "═══════════════════════════════════════════════════════════════════════════════")
    println(io, "")
end

"""
    print_config_summary(event_id::String; events_dir::String="events", db::Union{DuckDB.DB, Nothing}=nothing, io::IO=stdout, verbose::Bool=false)

Convenience function to generate and print config summary in one call.
"""
function print_config_summary(event_id::String; events_dir::String="events", db::Union{DuckDB.DB, Nothing}=nothing, io::IO=stdout, verbose::Bool=false)
    summary = generate_config_summary(event_id; events_dir=events_dir, db=db)
    print_config_summary(summary; io=io, verbose=verbose)
    return summary
end

end # module
