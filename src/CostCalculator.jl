module CostCalculator

using JSON
using DuckDB
using DBInterface
using ..Config: EventConfig, materialize_cost_rules
export calculate_cost, calculate_cost_with_details
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
# CONDITIONAL RULE EVALUATION
# =============================================================================

"""
Check if a single condition matches the registration data.
Conditions use the same field/value/pattern syntax as rules.

Returns true if the condition matches, false otherwise.
"""
function check_condition(condition::AbstractDict, fields::AbstractDict{String, String})
    field_name = get(condition, "field", "")

    # If field doesn't exist, condition cannot match
    if !haskey(fields, field_name)
        return false
    end

    actual_value = fields[field_name]

    # Check for exact value match
    if haskey(condition, "value")
        return actual_value == condition["value"]
    end

    # Check for pattern match
    if haskey(condition, "pattern")
        try
            return occursin(Regex(condition["pattern"]), actual_value)
        catch e
            @warn "Invalid regex pattern in condition: $(condition["pattern"])" exception=e
            return false
        end
    end

    # No value or pattern specified
    return false
end

"""
Determine if a rule should be skipped based on unless/only_if conditions.

- `unless`: Skip rule if ANY condition matches (OR logic)
  - "Charge for X unless staying overnight OR full board booked"
- `only_if`: Skip rule unless ALL conditions match (AND logic)
  - "Apply discount only if early registration AND member"

Returns true if the rule should be skipped, false if it should be applied.
"""
function should_skip_rule(rule::AbstractDict, fields::AbstractDict{String, String})
    # Check 'unless' conditions (OR logic - skip if ANY matches)
    if haskey(rule, "unless")
        unless_conditions = rule["unless"]
        # Handle both single dict and array of dicts
        conditions = unless_conditions isa AbstractVector ? unless_conditions : [unless_conditions]

        for condition in conditions
            if check_condition(condition, fields)
                return true  # Skip this rule
            end
        end
    end

    # Check 'only_if' conditions (AND logic - skip if ANY doesn't match)
    if haskey(rule, "only_if")
        only_if_conditions = rule["only_if"]
        conditions = only_if_conditions isa AbstractVector ? only_if_conditions : [only_if_conditions]

        for condition in conditions
            if !check_condition(condition, fields)
                return true  # Skip this rule
            end
        end
    end

    return false  # Don't skip
end

# =============================================================================
# COST CALCULATION FUNCTIONS
# =============================================================================

"""
Calculate cost using a parsed EventConfig. Returns nothing if no rules exist.
"""
function calculate_cost(cfg::EventConfig, fields::AbstractDict{String, String})
    rules = materialize_cost_rules(cfg)
    return calculate_cost(rules, fields)
end

"""
Calculate cost without database (using rules directly).
Returns just the total cost (backward compatible).
"""
function calculate_cost(rules::AbstractDict, fields::AbstractDict{String, String})
    result = calculate_cost_with_details(rules, fields)
    return result.total
end

"""
Calculate cost with full details and warnings.
This is the main calculation function that tracks everything.
"""
function calculate_cost_with_details(rules::AbstractDict, fields::AbstractDict{String, String})::CostCalculationResult
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

            # Check unless/only_if conditions (bundled options)
            if should_skip_rule(rule, fields)
                continue  # Skip this rule due to conditional logic
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
