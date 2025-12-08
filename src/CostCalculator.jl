module CostCalculator

using JSON
using DuckDB
using DBInterface
export calculate_cost, calculate_cost_with_details, set_event_cost_rules, get_cost_rules
export CostCalculationResult

"""
Cost rules are stored as JSON in the events table.

Example cost_rules JSON:
{
    "base": 50.0,
    "rules": [
        {"field": "Übernachtung Freitag", "value": "Ja", "cost": 25.0},
        {"field": "Übernachtung Samstag", "value": "Ja", "cost": 25.0},
        {"field": "Busfahrt Hinweg (10€)", "value": "Ja", "cost": 10.0},
        {"field": "Busfahrt Rückweg (10€)", "value": "Ja", "cost": 10.0},
        {"field": "Wie möchte ich übernachten?", "pattern": "Einzelzimmer", "cost": 10.0, "multiply_by": "nights"},
    ],
    "computed_fields": {
        "nights": {
            "sum_of": [
                {"field": "Übernachtung Freitag", "value": "Ja", "count": 1},
                {"field": "Übernachtung Samstag", "value": "Ja", "count": 1}
            ]
        }
    }
}
"""

# =============================================================================
# COST CALCULATION RESULT
# =============================================================================

"""
Detailed result from cost calculation, including warnings and matched rules.
This enables transparent cost calculation where users can see exactly what happened.
"""
struct CostCalculationResult
    total::Float64
    base::Float64
    rule_costs::Vector{Tuple{String, Float64}}  # (rule description, cost added)
    matched_rules::Vector{Int}                  # Indices of rules that matched
    unmatched_fields::Vector{String}            # Fields referenced in rules but not found in data
    warnings::Vector{String}                    # Human-readable warnings

    function CostCalculationResult(total::Float64, base::Float64,
                                   rule_costs::Vector{Tuple{String, Float64}},
                                   matched_rules::Vector{Int},
                                   unmatched_fields::Vector{String},
                                   warnings::Vector{String})
        new(total, base, rule_costs, matched_rules, unmatched_fields, warnings)
    end
end

# Simplified constructor for backward compatibility
CostCalculationResult(total::Float64) = CostCalculationResult(
    total, total, Tuple{String,Float64}[], Int[], String[], String[]
)

"""
Format a CostCalculationResult for display.
"""
function format_cost_result(result::CostCalculationResult)
    lines = String[]
    push!(lines, "Cost Breakdown:")
    push!(lines, "  Base cost: $(result.base)")

    if !isempty(result.rule_costs)
        for (desc, cost) in result.rule_costs
            push!(lines, "  + $cost  ($desc)")
        end
    end

    push!(lines, "  ─────────")
    push!(lines, "  Total: $(result.total)")

    if !isempty(result.warnings)
        push!(lines, "")
        push!(lines, "⚠️  Warnings:")
        for w in result.warnings
            push!(lines, "  • $w")
        end
    end

    return join(lines, "\n")
end

# =============================================================================
# COST CALCULATION FUNCTIONS
# =============================================================================

"""
Calculate cost for a registration based on event rules.
Returns nothing if no cost configuration exists (allows deferrable cost calculation).
"""
function calculate_cost(db::DuckDB.DB, event_id::AbstractString, fields::Dict{String, String})
    # Get cost rules for this event
    result = DBInterface.execute(db,
        "SELECT base_cost, cost_rules FROM events WHERE event_id = ?",
        [event_id])

    rows = collect(result)
    if isempty(rows)
        # No event config exists - cost calculation should be deferred
        return nothing
    end

    base_cost = something(rows[1][1], 0.0)
    rules_json = rows[1][2]

    if rules_json === nothing || rules_json == ""
        # Event exists but no rules defined - use base cost only
        return Float64(base_cost)
    end

    rules = JSON.parse(rules_json)

    # Use the Dict-based calculation
    return calculate_cost(rules, fields)
end

"""
Calculate cost without database (using rules directly).
Returns just the total cost (backward compatible).
"""
function calculate_cost(rules::AbstractDict, fields::Dict{String, String})
    result = calculate_cost_with_details(rules, fields)
    return result.total
end

"""
Calculate cost with full details and warnings.
This is the main calculation function that tracks everything.
"""
function calculate_cost_with_details(rules::AbstractDict, fields::Dict{String, String})::CostCalculationResult
    base = Float64(get(rules, "base", 0.0))
    total = base
    rule_costs = Tuple{String, Float64}[]
    matched_rules = Int[]
    unmatched_fields = String[]
    warnings = String[]

    available_field_names = Set(keys(fields))

    # Compute any computed fields first (like "nights")
    computed = Dict{String, Any}()
    if haskey(rules, "computed_fields")
        for (name, definition) in rules["computed_fields"]
            if haskey(definition, "sum_of")
                sum_val = 0
                for item in definition["sum_of"]
                    field_name = item["field"]
                    expected_value = get(item, "value", "")

                    # Track unmatched fields
                    if !haskey(fields, field_name)
                        if !(field_name in unmatched_fields)
                            push!(unmatched_fields, field_name)
                            push!(warnings, "Computed field '$name' references missing field: '$field_name'")
                        end
                        continue
                    end

                    if fields[field_name] == expected_value
                        sum_val += get(item, "count", 1)
                    end
                end
                computed[name] = sum_val
            end
        end
    end

    # Apply rules
    if haskey(rules, "rules")
        for (i, rule) in enumerate(rules["rules"])
            field_name = get(rule, "field", "")

            if isempty(field_name)
                push!(warnings, "Rule #$i has no 'field' property - skipping")
                continue
            end

            # Check if field exists
            if !haskey(fields, field_name)
                if !(field_name in unmatched_fields)
                    push!(unmatched_fields, field_name)
                    push!(warnings, "Rule #$i: Field '$field_name' not found in registration data")
                end
                continue  # Skip this rule - can't match what doesn't exist
            end

            actual_value = fields[field_name]

            # Check for match (exact value or pattern)
            matches = false
            match_description = ""

            if haskey(rule, "pattern")
                # Pattern match (regex)
                try
                    matches = occursin(Regex(rule["pattern"]), actual_value)
                    match_description = "'$field_name' matches pattern '$(rule["pattern"])'"
                catch e
                    push!(warnings, "Rule #$i: Invalid regex pattern '$(rule["pattern"])': $e")
                    continue
                end
            elseif haskey(rule, "value")
                # Exact match
                matches = (actual_value == rule["value"])
                match_description = "'$field_name' = '$(rule["value"])'"
            else
                push!(warnings, "Rule #$i: No 'value' or 'pattern' specified - skipping")
                continue
            end

            if matches
                cost = Float64(get(rule, "cost", 0.0))

                # Handle multipliers
                if haskey(rule, "multiply_by")
                    multiplier_name = rule["multiply_by"]
                    if haskey(computed, multiplier_name)
                        multiplier = computed[multiplier_name]
                        cost *= multiplier
                        match_description *= " × $multiplier_name ($multiplier)"
                    else
                        push!(warnings, "Rule #$i: multiply_by '$multiplier_name' not found in computed_fields")
                    end
                end

                total += cost
                push!(matched_rules, i)
                push!(rule_costs, (match_description, cost))
            end
        end
    end

    return CostCalculationResult(total, base, rule_costs, matched_rules, unmatched_fields, warnings)
end

"""
Set or update cost rules for an event.
"""
function set_event_cost_rules(db::DuckDB.DB, event_id::AbstractString;
                               event_name::Union{String,Nothing}=nothing,
                               base_cost::Real=0.0,
                               rules::Union{Dict,Nothing}=nothing)
    rules_json = rules === nothing ? nothing : JSON.json(rules)

    # Upsert the event
    DBInterface.execute(db, """
            INSERT INTO events (event_id, event_name, base_cost, cost_rules)
            VALUES (?, ?, ?, ?)
            ON CONFLICT (event_id) DO UPDATE SET
                event_name = COALESCE(EXCLUDED.event_name, events.event_name),
                base_cost = EXCLUDED.base_cost,
                cost_rules = EXCLUDED.cost_rules
        """, [event_id, event_name, base_cost, rules_json])
end

"""
Get cost rules for an event.
"""
function get_cost_rules(db::DuckDB.DB, event_id::AbstractString)
    result = DBInterface.execute(db,
        "SELECT base_cost, cost_rules FROM events WHERE event_id = ?",
        [event_id])

    rows = collect(result)
    if isempty(rows)
        return nothing
    end

    base_cost = something(rows[1][1], 0.0)
    rules_json = rows[1][2]

    if rules_json === nothing || rules_json == ""
        return Dict("base" => base_cost, "rules" => [])
    end

    return JSON.parse(rules_json)
end

"""
Create a default cost rule template for a typical event.
"""
function create_default_rules_template()
    return Dict(
        "base" => 0.0,
        "rules" => [
            Dict("field" => "Übernachtung Freitag", "value" => "Ja", "cost" => 25.0),
            Dict("field" => "Übernachtung Samstag", "value" => "Ja", "cost" => 25.0),
            Dict("field" => "Busfahrt Hinweg (10€)", "value" => "Ja", "cost" => 10.0),
            Dict("field" => "Busfahrt Rückweg (10€)", "value" => "Ja", "cost" => 10.0),
            Dict("field" => "Wie möchte ich übernachten?", "pattern" => "Einzelzimmer", "cost" => 10.0, "multiply_by" => "nights"),
        ],
        "computed_fields" => Dict(
            "nights" => Dict(
                "sum_of" => [
                    Dict("field" => "Übernachtung Freitag", "value" => "Ja", "count" => 1),
                    Dict("field" => "Übernachtung Samstag", "value" => "Ja", "count" => 1),
                ]
            )
        )
    )
end

end # module
