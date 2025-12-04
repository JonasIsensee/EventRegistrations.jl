module Validation

using DuckDB
using DBInterface
using JSON

export ValidationResult, ValidationError, ValidationWarning
export validate_registration, validate_cost_config, validate_field_aliases
export format_validation_result

"""
Represents a single validation issue (error or warning).
"""
struct ValidationIssue
    code::Symbol        # Machine-readable error code
    message::String     # Human-readable message
    context::Dict{String,Any}  # Additional context (field names, values, etc.)
end

"""
Result of a validation operation.
Contains errors (blocking), warnings (non-blocking), and info messages.
"""
struct ValidationResult
    valid::Bool
    errors::Vector{ValidationIssue}
    warnings::Vector{ValidationIssue}
    info::Vector{String}
end

# Convenience constructors
ValidationResult() = ValidationResult(true, ValidationIssue[], ValidationIssue[], String[])
ValidationResult(valid::Bool) = ValidationResult(valid, ValidationIssue[], ValidationIssue[], String[])

"""
Create a validation issue.
"""
function make_error(code::Symbol, message::String; context::Dict{String,Any}=Dict{String,Any}())
    return ValidationIssue(code, message, context)
end

function make_warning(code::Symbol, message::String; context::Dict{String,Any}=Dict{String,Any}())
    return ValidationIssue(code, message, context)
end

"""
Merge multiple validation results into one.
"""
function merge_results(results::Vector{ValidationResult})
    errors = ValidationIssue[]
    warnings = ValidationIssue[]
    info = String[]

    for r in results
        append!(errors, r.errors)
        append!(warnings, r.warnings)
        append!(info, r.info)
    end

    return ValidationResult(isempty(errors), errors, warnings, info)
end

"""
Format a validation result for display.
"""
function format_validation_result(result::ValidationResult; verbose::Bool=false)
    lines = String[]

    if !isempty(result.errors)
        push!(lines, "❌ ERRORS ($(length(result.errors))):")
        for err in result.errors
            push!(lines, "  • $(err.message)")
            if verbose && !isempty(err.context)
                for (k, v) in err.context
                    push!(lines, "      $k: $v")
                end
            end
        end
    end

    if !isempty(result.warnings)
        push!(lines, "⚠️  WARNINGS ($(length(result.warnings))):")
        for warn in result.warnings
            push!(lines, "  • $(warn.message)")
            if verbose && !isempty(warn.context)
                for (k, v) in warn.context
                    push!(lines, "      $k: $v")
                end
            end
        end
    end

    if verbose && !isempty(result.info)
        push!(lines, "ℹ️  INFO:")
        for i in result.info
            push!(lines, "  • $i")
        end
    end

    if result.valid && isempty(result.warnings)
        push!(lines, "✅ Validation passed")
    elseif result.valid
        push!(lines, "✅ Validation passed with warnings")
    else
        push!(lines, "❌ Validation failed")
    end

    return join(lines, "\n")
end

# =============================================================================
# REGISTRATION VALIDATION
# =============================================================================

"""
Validate a registration's fields before database insertion.
"""
function validate_registration(fields::Dict{String,String}, event_id::String;
                               db::Union{DuckDB.DB,Nothing}=nothing,
                               required_fields::Vector{String}=["email"])
    errors = ValidationIssue[]
    warnings = ValidationIssue[]
    info = String[]

    # Check required fields
    for field in required_fields
        # Check both exact match and common variations
        found = false
        for (k, v) in fields
            if lowercase(k) == lowercase(field) || k == field
                if isempty(strip(v))
                    push!(errors, make_error(:missing_required,
                        "Required field '$field' is empty",
                        context=Dict{String,Any}("field" => field)))
                else
                    found = true
                end
                break
            end
        end

        if !found
            push!(errors, make_error(:missing_required,
                "Required field '$field' not found in submission",
                context=Dict{String,Any}("field" => field, "available_fields" => collect(keys(fields)))))
        end
    end

    # Validate email format if present
    email_value = nothing
    for (k, v) in fields
        if lowercase(k) in ["email", "e-mail", "e_mail"]
            email_value = v
            break
        end
    end

    if email_value !== nothing && !isempty(email_value)
        if !occursin(r"^[^@\s]+@[^@\s]+\.[^@\s]+$", email_value)
            push!(errors, make_error(:invalid_email,
                "Invalid email format: '$email_value'",
                context=Dict{String,Any}("email" => email_value)))
        end
    end

    # Check if event has cost configuration (warning only)
    if db !== nothing
        config_result = DBInterface.execute(db,
            "SELECT event_id, cost_rules FROM events WHERE event_id = ?",
            [event_id])
        rows = collect(config_result)

        if isempty(rows)
            push!(warnings, make_warning(:no_event_config,
                "No cost configuration exists for event '$event_id' - cost will be NULL",
                context=Dict{String,Any}("event_id" => event_id)))
        elseif rows[1][2] === nothing || rows[1][2] == ""
            push!(warnings, make_warning(:empty_cost_rules,
                "Event '$event_id' has no cost rules defined - only base cost will apply",
                context=Dict{String,Any}("event_id" => event_id)))
        end
    end

    push!(info, "Validated $(length(fields)) fields")

    return ValidationResult(isempty(errors), errors, warnings, info)
end

# =============================================================================
# COST CONFIG VALIDATION
# =============================================================================

"""
Validate cost configuration rules against actual registration data.
This ensures rules reference fields that actually exist.
"""
function validate_cost_config(rules::Dict, event_id::String, db::DuckDB.DB;
                              strict::Bool=false)
    errors = ValidationIssue[]
    warnings = ValidationIssue[]
    info = String[]

    # Get actual fields from existing registrations
    actual_fields = get_event_field_names(db, event_id)

    if isempty(actual_fields)
        push!(warnings, make_warning(:no_registrations,
            "No registrations found for event '$event_id' - cannot validate field references",
            context=Dict{String,Any}("event_id" => event_id)))
        push!(info, "Skipping field validation (no registrations to compare against)")
    end

    # Validate base cost
    base = get(rules, "base", 0.0)
    if base < 0
        push!(errors, make_error(:negative_base_cost,
            "Base cost cannot be negative: $base",
            context=Dict{String,Any}("base" => base)))
    end

    # Track which fields are referenced
    referenced_fields = Set{String}()

    # Validate rules array
    if haskey(rules, "rules")
        for (i, rule) in enumerate(rules["rules"])
            rule_errors = validate_single_rule(rule, i, actual_fields, referenced_fields, strict)
            append!(errors, rule_errors.errors)
            append!(warnings, rule_errors.warnings)
        end
    end

    # Validate computed_fields
    if haskey(rules, "computed_fields")
        for (name, definition) in rules["computed_fields"]
            if haskey(definition, "sum_of")
                for (j, item) in enumerate(definition["sum_of"])
                    field = get(item, "field", "")
                    if isempty(field)
                        push!(errors, make_error(:missing_field_in_computed,
                            "Computed field '$name' item #$j is missing 'field' property",
                            context=Dict{String,Any}("computed_field" => name, "item_index" => j)))
                    else
                        push!(referenced_fields, field)
                        if !isempty(actual_fields) && !(field in actual_fields)
                            issue = make_warning(:computed_field_not_found,
                                "Computed field '$name' references unknown field: '$field'",
                                context=Dict{String,Any}("computed_field" => name, "field" => field,
                                    "available_fields" => collect(actual_fields)))
                            if strict
                                push!(errors, ValidationIssue(:computed_field_not_found, issue.message, issue.context))
                            else
                                push!(warnings, issue)
                            end
                        end
                    end

                    if !haskey(item, "value")
                        push!(errors, make_error(:missing_value_in_computed,
                            "Computed field '$name' item #$j is missing 'value' property",
                            context=Dict{String,Any}("computed_field" => name, "item_index" => j)))
                    end
                end
            end
        end
    end

    # Check for multiply_by references to non-existent computed fields
    computed_field_names = Set(keys(get(rules, "computed_fields", Dict())))
    for (i, rule) in enumerate(get(rules, "rules", []))
        if haskey(rule, "multiply_by")
            multiplier = rule["multiply_by"]
            if !(multiplier in computed_field_names)
                push!(errors, make_error(:invalid_multiplier,
                    "Rule #$i references non-existent computed field: '$multiplier'",
                    context=Dict{String,Any}("rule_index" => i, "multiplier" => multiplier,
                        "available_computed" => collect(computed_field_names))))
            end
        end
    end

    push!(info, "Validated $(length(get(rules, "rules", []))) cost rules")
    push!(info, "Referenced $(length(referenced_fields)) unique fields")

    return ValidationResult(isempty(errors), errors, warnings, info)
end

"""
Validate a single cost rule.
"""
function validate_single_rule(rule::Dict, index::Int, actual_fields::Set{String},
                              referenced_fields::Set{String}, strict::Bool)
    errors = ValidationIssue[]
    warnings = ValidationIssue[]

    # Check required 'field' property
    if !haskey(rule, "field")
        push!(errors, make_error(:missing_rule_field,
            "Rule #$index is missing required 'field' property",
            context=Dict{String,Any}("rule_index" => index, "rule" => rule)))
        return ValidationResult(false, errors, warnings, String[])
    end

    field = rule["field"]
    push!(referenced_fields, field)

    # Check if field exists in registrations
    if !isempty(actual_fields) && !(field in actual_fields)
        issue_context = Dict{String,Any}(
            "rule_index" => index,
            "field" => field,
            "available_fields" => collect(actual_fields)
        )

        if strict
            push!(errors, make_error(:field_not_found,
                "Rule #$index references unknown field: '$field'",
                context=issue_context))
        else
            push!(warnings, make_warning(:field_not_found,
                "Rule #$index references field '$field' which was not found in any registration",
                context=issue_context))
        end
    end

    # Check that either 'value' or 'pattern' is specified
    if !haskey(rule, "value") && !haskey(rule, "pattern")
        push!(errors, make_error(:missing_match_condition,
            "Rule #$index must specify either 'value' (exact match) or 'pattern' (regex)",
            context=Dict{String,Any}("rule_index" => index, "field" => field)))
    end

    # Check that 'cost' is specified and valid
    if !haskey(rule, "cost")
        push!(errors, make_error(:missing_cost,
            "Rule #$index is missing required 'cost' property",
            context=Dict{String,Any}("rule_index" => index, "field" => field)))
    elseif !isa(rule["cost"], Number)
        push!(errors, make_error(:invalid_cost_type,
            "Rule #$index 'cost' must be a number, got: $(typeof(rule["cost"]))",
            context=Dict{String,Any}("rule_index" => index, "cost" => rule["cost"])))
    end

    # Validate regex pattern if present
    if haskey(rule, "pattern")
        pattern = rule["pattern"]
        try
            Regex(pattern)
        catch e
            push!(errors, make_error(:invalid_regex,
                "Rule #$index has invalid regex pattern: '$pattern'",
                context=Dict{String,Any}("rule_index" => index, "pattern" => pattern, "error" => string(e))))
        end
    end

    return ValidationResult(isempty(errors), errors, warnings, String[])
end

"""
Get all unique field names from registrations for an event.
"""
function get_event_field_names(db::DuckDB.DB, event_id::String)::Set{String}
    result = DBInterface.execute(db,
        "SELECT DISTINCT json_keys(fields) FROM registrations WHERE event_id = ?",
        [event_id])

    all_fields = Set{String}()
    for row in result
        if row[1] !== nothing
            for field in row[1]
                push!(all_fields, field)
            end
        end
    end

    return all_fields
end

"""
Get all unique field names across all registrations.
"""
function get_all_field_names(db::DuckDB.DB)::Set{String}
    result = DBInterface.execute(db,
        "SELECT DISTINCT json_keys(fields) FROM registrations")

    all_fields = Set{String}()
    for row in result
        if row[1] !== nothing
            for field in row[1]
                push!(all_fields, field)
            end
        end
    end

    return all_fields
end

# =============================================================================
# FIELD ALIAS VALIDATION
# =============================================================================

"""
Validate field aliases against actual registration data.
Ensures aliases map to fields that actually exist.
"""
function validate_field_aliases(aliases::Dict{String,String}, db::DuckDB.DB)
    errors = ValidationIssue[]
    warnings = ValidationIssue[]
    info = String[]

    actual_fields = get_all_field_names(db)

    if isempty(actual_fields)
        push!(warnings, make_warning(:no_registrations,
            "No registrations found - cannot validate field aliases",
            context=Dict{String,Any}()))
        return ValidationResult(true, errors, warnings, info)
    end

    # Check each alias
    matched_count = 0
    for (alias, actual_name) in aliases
        if actual_name in actual_fields
            matched_count += 1
        else
            push!(warnings, make_warning(:alias_field_not_found,
                "Alias '$alias' maps to field '$actual_name' which doesn't exist in registrations",
                context=Dict{String,Any}("alias" => alias, "target_field" => actual_name)))
        end
    end

    # Check for fields without aliases
    aliased_fields = Set(values(aliases))
    unaliased = setdiff(actual_fields, aliased_fields)

    if !isempty(unaliased)
        push!(info, "$(length(unaliased)) field(s) have no alias defined")
        for field in unaliased
            push!(info, "  - No alias for: $field")
        end
    end

    push!(info, "Validated $(length(aliases)) aliases, $matched_count matched existing fields")

    return ValidationResult(isempty(errors), errors, warnings, info)
end

end # module
