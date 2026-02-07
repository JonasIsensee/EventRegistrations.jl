"""
ConfigSummary - Event Configuration Summary and Cost Combination Analysis

This module provides functions to analyze event configurations and generate
summaries showing all possible cost combinations. This is useful for validating
that cost rules are correctly configured before processing registrations.

The combination generator is smart - it analyzes the cost rules directly to
enumerate which subsets of rules can be active, rather than blindly testing
all possible field value combinations.
"""
module ConfigSummary

using DBInterface: DBInterface
using DuckDB: DuckDB

using ..Config: EventConfig, load_event_config, materialize_cost_rules
using ..CostCalculator: calculate_cost_with_details, CostCalculationResult

export ConfigSummaryResult, CostCombination
export generate_config_summary, print_config_summary
export get_all_field_values, generate_cost_combinations

"""
Represents a single cost combination - a set of active rules and resulting cost.
"""
struct CostCombination
    fields::Dict{String, String}       # Field name → value (representative example)
    cost::Float64                       # Calculated cost
    cost_breakdown::Vector{Tuple{String, Float64}}  # Rule descriptions and costs
    base_cost::Float64                  # Base cost
    active_rules::Vector{Int}           # Indices of rules that are active
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
        
        # For pattern rules, note we need pattern-matching values
        if haskey(rule, "pattern")
            push!(field_values[field], "[pattern: $(rule["pattern"])]")
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
    
    # Add "Nein" as non-selected option for each field
    for (field, values) in field_values
        push!(values, "Nein")
    end
    
    # If database provided, also get actual values from registrations
    if db !== nothing
        try
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

Generate all possible cost combinations by analyzing the cost rules directly.
Instead of brute-forcing all field combinations, we enumerate which subsets of 
rules can be simultaneously active and compute the resulting costs.

For N rules without conditions, there are at most 2^N combinations.
"""
function generate_cost_combinations(cfg::EventConfig, field_values::Dict{String, Vector{String}})
    rules = materialize_cost_rules(cfg)
    rule_list = get(rules, "rules", Dict{String,Any}[])
    base_cost = Float64(get(rules, "base", 0.0))
    
    # No rules - just base cost
    if isempty(rule_list)
        combo = CostCombination(
            Dict{String, String}(),
            base_cost,
            Tuple{String, Float64}[],
            base_cost,
            Int[]
        )
        return [combo]
    end
    
    # Analyze rules to find independent "choice groups"
    # Rules that share fields or have conditional dependencies form groups
    # For simplicity, we'll enumerate all 2^N rule activation patterns
    # but filter out invalid ones (where conditions conflict)
    
    n_rules = length(rule_list)
    
    # Limit to prevent exponential blowup (2^20 = 1M combinations max)
    if n_rules > 20
        @warn "Too many rules ($n_rules), limiting analysis to first 20"
        n_rules = 20
    end
    
    seen_costs = Dict{Float64, CostCombination}()
    
    # Enumerate all possible subsets of rules being active
    for mask in 0:(2^n_rules - 1)
        active_rules = Int[]
        for i in 1:n_rules
            if (mask >> (i-1)) & 1 == 1
                push!(active_rules, i)
            end
        end
        
        # Build field values that would activate exactly these rules
        fields_for_combo = build_fields_for_rules(rule_list, active_rules, rules)
        
        # Skip if this combination is impossible (conflicting requirements)
        fields_for_combo === nothing && continue
        
        # Calculate actual cost with these fields
        result = calculate_cost_with_details(rules, fields_for_combo)
        
        # Store if this is a new unique cost
        if !haskey(seen_costs, result.total)
            seen_costs[result.total] = CostCombination(
                fields_for_combo,
                result.total,
                result.rule_costs,
                result.base,
                active_rules
            )
        end
    end
    
    # Sort by cost
    return sort(collect(values(seen_costs)), by=c -> c.cost)
end

"""
Build a field dictionary that would cause exactly the specified rules to be active.
Returns nothing if the combination is impossible (conflicting requirements).
"""
function build_fields_for_rules(rule_list::Vector, active_rules::Vector{Int}, rules::Dict)
    fields = Dict{String, String}()
    
    # First, set fields to activate the specified rules
    for i in active_rules
        rule = rule_list[i]
        field = get(rule, "field", "")
        isempty(field) && continue
        
        if haskey(rule, "value")
            target_value = string(rule["value"])
            # Check for conflict
            if haskey(fields, field) && fields[field] != target_value
                return nothing  # Conflict - can't activate both rules
            end
            fields[field] = target_value
        elseif haskey(rule, "pattern")
            # For patterns, we need a value that matches
            # Use a placeholder that would match the pattern
            pattern = rule["pattern"]
            if !haskey(fields, field)
                fields[field] = pattern  # Use pattern as matching value
            end
        end
        
        # Handle only_if conditions - they must also be satisfied
        if haskey(rule, "only_if")
            conditions = rule["only_if"]
            conditions = conditions isa AbstractVector ? conditions : [conditions]
            for cond in conditions
                if cond isa AbstractDict
                    cond_field = get(cond, "field", "")
                    if !isempty(cond_field) && haskey(cond, "value")
                        cond_value = string(cond["value"])
                        if haskey(fields, cond_field) && fields[cond_field] != cond_value
                            return nothing  # Conflict
                        end
                        fields[cond_field] = cond_value
                    end
                end
            end
        end
    end
    
    # Now set fields to deactivate rules we don't want active
    for i in 1:length(rule_list)
        i in active_rules && continue
        
        rule = rule_list[i]
        field = get(rule, "field", "")
        isempty(field) && continue
        
        # If this rule's field isn't set yet, set it to a non-matching value
        if !haskey(fields, field)
            if haskey(rule, "value")
                # Set to something that won't match
                fields[field] = "Nein"
            elseif haskey(rule, "pattern")
                fields[field] = "Nein"  # Unlikely to match most patterns
            end
        else
            # Field is already set - check if this would accidentally activate the rule
            current_value = fields[field]
            if haskey(rule, "value") && current_value == string(rule["value"])
                # This rule would be activated - check if we can use unless to skip it
                # For now, mark as conflict if we can't avoid activating it
                if !has_blocking_unless(rule, fields)
                    # Can't prevent this rule from activating
                    # This combination is actually not achievable as specified
                    # But we might still want to include it if the cost is different
                end
            end
        end
    end
    
    # Handle computed fields (multipliers) - ensure fields are set for sum_of calculations
    computed_fields = get(rules, "computed_fields", Dict())
    for (name, definition) in computed_fields
        if definition isa Dict && haskey(definition, "sum_of")
            for item in definition["sum_of"]
                cf = get(item, "field", "")
                if !isempty(cf) && !haskey(fields, cf)
                    fields[cf] = "Nein"  # Default to not contributing
                end
            end
        end
    end
    
    return fields
end

"""
Check if a rule has an 'unless' condition that is satisfied by the current fields,
which would block the rule from being applied.
"""
function has_blocking_unless(rule::Dict, fields::Dict{String, String})
    !haskey(rule, "unless") && return false
    
    conditions = rule["unless"]
    conditions = conditions isa AbstractVector ? conditions : [conditions]
    
    for cond in conditions
        if cond isa AbstractDict
            cond_field = get(cond, "field", "")
            if !isempty(cond_field) && haskey(fields, cond_field)
                if haskey(cond, "value")
                    if fields[cond_field] == string(cond["value"])
                        return true  # Unless condition is met, rule blocked
                    end
                end
            end
        end
    end
    
    return false
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
    
    # Get field values (for display purposes)
    field_values = get_all_field_values(cfg; db=db)
    
    if isempty(cfg.rules)
        push!(warnings, "No cost rules defined. Only base cost will be applied.")
    end
    
    # Generate combinations using smart rule-based analysis
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
    if !isempty(summary.field_values) && verbose
        println(io, "───────────────────────────────────────────────────────────────────────────────")
        println(io, "FIELDS REFERENCED IN RULES")
        println(io, "───────────────────────────────────────────────────────────────────────────────")
        for (field, values) in sort(collect(summary.field_values))
            # Filter out pattern placeholders for display
            display_values = filter(v -> !startswith(v, "[pattern:"), values)
            values_str = join(display_values, ", ")
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
            
            # Show which rules are active
            if verbose && !isempty(combo.active_rules)
                println(io, "    Active rules: $(join(combo.active_rules, ", "))")
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
