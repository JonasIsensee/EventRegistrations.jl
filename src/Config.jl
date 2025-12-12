module Config

using TOML
using DuckDB
using DBInterface
using JSON
using Dates
using SHA

# Import from parent module
import ..EventRegistrations: with_transaction

export load_field_aliases, generate_field_config, resolve_field_name
export load_event_config, load_event_aliases, generate_event_config_template
export get_config_dir, ensure_config_dirs
export check_config_sync, get_unsynced_configs, record_config_sync
export ConfigSyncStatus
export get_registration_detail_columns

# Default config directory (can be overridden)
const CONFIG_DIR = Ref{String}("config")

# Current event ID for scoped alias resolution
const CURRENT_EVENT_ID = Ref{Union{String,Nothing}}(nothing)

# Event-specific alias cache: event_id -> Dict(alias -> actual)
const EVENT_ALIASES = Dict{String, Dict{String, String}}()
const EVENT_REVERSE_ALIASES = Dict{String, Dict{String, String}}()

"""
Get the current config directory.
"""
get_config_dir() = CONFIG_DIR[]

"""
Set the config directory.
"""
function set_config_dir!(path::AbstractString)
    CONFIG_DIR[] = path
end

"""
Ensure config directories exist.
"""
function ensure_config_dirs(base_dir::AbstractString=CONFIG_DIR[])
    mkpath(base_dir)
    mkpath(joinpath(base_dir, "events"))
    mkpath(joinpath(base_dir, "templates"))
    return base_dir
end

# =============================================================================
# FIELD ALIASES
# =============================================================================

# In-memory cache for field aliases
const FIELD_ALIASES = Dict{String, String}()
const REVERSE_ALIASES = Dict{String, String}()

"""
Load field aliases (DEPRECATED - now uses event-specific aliases only).
This function is kept for backward compatibility but does nothing.
Field aliases are now defined in event-specific config files only.
"""
function load_field_aliases(config_dir::AbstractString=CONFIG_DIR[])
    # Clear global caches - we only use event-specific aliases now
    empty!(FIELD_ALIASES)
    empty!(REVERSE_ALIASES)
    return Dict{String, String}()
end

"""
Resolve a field name - if it's an alias, return the actual name.
If it's already an actual name, return it unchanged.
"""
function resolve_field_name(name::AbstractString)
    # First check if it's an alias
    if haskey(FIELD_ALIASES, name)
        return FIELD_ALIASES[name]
    end
    # Otherwise return as-is (might be the actual field name)
    return name
end

"""
Get alias for a field name (reverse lookup).
Returns the alias if one exists, otherwise the original name.
"""
function get_field_alias(actual_name::AbstractString)
    return get(REVERSE_ALIASES, actual_name, actual_name)
end

"""
Load event-specific field aliases from an event config file.
Event configs can have their own [aliases] section that takes precedence over global aliases.
Returns Dict mapping alias -> actual field name for that event.
"""
function load_event_aliases(event_id::AbstractString, config_dir::AbstractString=CONFIG_DIR[])
    path = joinpath(config_dir, "events", "$event_id.toml")

    if !isfile(path)
        return Dict{String, String}()
    end

    config = TOML.parsefile(path)
    aliases = get(config, "aliases", Dict())

    # Convert to proper types
    event_aliases = Dict{String, String}()
    reverse_aliases = Dict{String, String}()

    for (alias, actual) in aliases
        event_aliases[string(alias)] = string(actual)
        reverse_aliases[string(actual)] = string(alias)
    end

    # Cache for this event
    EVENT_ALIASES[event_id] = event_aliases
    EVENT_REVERSE_ALIASES[event_id] = reverse_aliases

    return event_aliases
end

"""
Set the current event context for alias resolution.
This allows resolve_field_name and get_field_alias to use event-specific aliases.
"""
function set_current_event!(event_id::Union{String,Nothing})
    CURRENT_EVENT_ID[] = event_id
end

"""
Clear the current event context.
"""
function clear_current_event!()
    CURRENT_EVENT_ID[] = nothing
end

"""
Resolve a field name for a specific event.
Checks event-specific aliases first, then falls back to global aliases.
"""
function resolve_field_name(name::AbstractString, event_id::AbstractString)
    # First check event-specific aliases
    if haskey(EVENT_ALIASES, event_id)
        event_aliases = EVENT_ALIASES[event_id]
        if haskey(event_aliases, name)
            return event_aliases[name]
        end
    end
    # Fall back to global aliases
    if haskey(FIELD_ALIASES, name)
        return FIELD_ALIASES[name]
    end
    # Return as-is
    return name
end

"""
Get alias for a field name for a specific event (reverse lookup).
Checks event-specific reverse aliases first, then falls back to global.
"""
function get_field_alias(actual_name::AbstractString, event_id::AbstractString)
    # First check event-specific reverse aliases
    if haskey(EVENT_REVERSE_ALIASES, event_id)
        event_reverse = EVENT_REVERSE_ALIASES[event_id]
        if haskey(event_reverse, actual_name)
            return event_reverse[actual_name]
        end
    end
    # Fall back to global
    return get(REVERSE_ALIASES, actual_name, actual_name)
end

"""
Generate a fields.toml config file from existing submissions.
Scans all unique field names and creates a template with suggested aliases.
"""
function generate_field_config(db::DuckDB.DB, output_path::AbstractString;
                                event_id::Union{String,Nothing}=nothing)
    # Get all unique field names
    query = event_id === nothing ?
        "SELECT DISTINCT json_keys(fields) FROM registrations" :
        "SELECT DISTINCT json_keys(fields) FROM registrations WHERE event_id = ?"

    params = event_id === nothing ? [] : [event_id]
    result = DBInterface.execute(db, query, params)

    all_fields = Set{String}()
    for row in result
        if row[1] !== nothing
            for field in row[1]
                push!(all_fields, field)
            end
        end
    end

    fields = sort(collect(all_fields))

    # Generate suggested aliases
    lines = String[]
    push!(lines, "# Field Aliases Configuration")
    push!(lines, "# Maps short, easy-to-use aliases to actual field names from form submissions")
    push!(lines, "#")
    push!(lines, "# Usage in cost rules: use the alias (left side) instead of the full field name")
    push!(lines, "# Edit the aliases (left side) to your preference")
    push!(lines, "")
    push!(lines, "[aliases]")

    for field in fields
        alias = generate_alias_suggestion(field)
        # Escape the actual field name if it contains special chars
        escaped_field = escape_toml_string(field)
        push!(lines, "$alias = $escaped_field")
    end

    content = join(lines, "\n")
    write(output_path, content)

    @info "Generated field config" path=output_path fields=length(fields)
    return fields
end

"""
Generate a suggested alias from a field name.
"""
function generate_alias_suggestion(field::AbstractString)
    # Common mappings
    mappings = Dict(
        "Vorname" => "vorname",
        "Nachname" => "nachname",
        "E-Mail" => "email",
        "Stimmgruppe" => "stimme",
        "Essen" => "essen",
    )

    if haskey(mappings, field)
        return mappings[field]
    end

    # Generate from field name
    alias = lowercase(field)

    # Replace German umlauts
    alias = replace(alias, "ä" => "ae")
    alias = replace(alias, "ö" => "oe")
    alias = replace(alias, "ü" => "ue")
    alias = replace(alias, "ß" => "ss")

    # Remove special chars, keep only alphanumeric and spaces
    alias = replace(alias, r"[^\w\s]" => "")

    # Replace spaces with underscores
    alias = replace(alias, r"\s+" => "_")

    # Truncate if too long
    if length(alias) > 20
        alias = alias[1:20]
    end

    # Remove trailing underscores
    alias = rstrip(alias, '_')

    return alias
end

"""
Escape a string for TOML format.
"""
function escape_toml_string(s::AbstractString)
    # If it contains special chars, use quoted string
    if occursin(r"[\"'\n\r\t\\]", s) || occursin(r"^\s|\s$", s)
        escaped = replace(s, "\\" => "\\\\")
        escaped = replace(escaped, "\"" => "\\\"")
        escaped = replace(escaped, "\n" => "\\n")
        escaped = replace(escaped, "\r" => "\\r")
        escaped = replace(escaped, "\t" => "\\t")
        return "\"$escaped\""
    else
        return "\"$s\""
    end
end

# =============================================================================
# EVENT CONFIGURATION
# =============================================================================

"""
Load event configuration from config/events/{event_id}.toml

This function:
1. Loads event-specific field aliases from the event config
2. Converts cost rules, resolving all field aliases to actual field names
"""
function load_event_config(event_id::AbstractString, config_dir::AbstractString=CONFIG_DIR[])
    path = joinpath(config_dir, "events", "$event_id.toml")

    if !isfile(path)
        return nothing
    end

    config = TOML.parsefile(path)

    # Load event-specific aliases first (these take precedence)
    # This populates EVENT_ALIASES[event_id]
    load_event_aliases(event_id, config_dir)

    # Helper to resolve alias for this event specifically
    resolve_alias = name -> resolve_field_name(name, event_id)

    # Convert TOML structure to the format expected by CostCalculator
    result = Dict{String, Any}()

    # Event metadata
    if haskey(config, "event")
        result["event_name"] = get(config["event"], "name", event_id)
    end

    # Cost rules
    if haskey(config, "costs")
        costs = config["costs"]
        result["base"] = get(costs, "base", 0.0)

        # Convert rules, resolving field aliases
        if haskey(costs, "rules")
            rules = []
            for rule in costs["rules"]
                new_rule = Dict{String, Any}()
                for (k, v) in rule
                    if k == "field"
                        # Resolve alias to actual field name (event-specific first)
                        new_rule[k] = resolve_alias(v)
                    else
                        new_rule[k] = v
                    end
                end
                push!(rules, new_rule)
            end
            result["rules"] = rules
        end

        # Convert computed_fields, resolving aliases
        if haskey(costs, "computed_fields")
            computed = Dict{String, Any}()
            for (name, definition) in costs["computed_fields"]
                if isa(definition, Dict) && haskey(definition, "sum_of")
                    items = []
                    for item in definition["sum_of"]
                        new_item = Dict{String, Any}()
                        for (k, v) in item
                            if k == "field"
                                new_item[k] = resolve_alias(v)
                            else
                                new_item[k] = v
                            end
                        end
                        push!(items, new_item)
                    end
                    computed[name] = Dict("sum_of" => items)
                end
            end
            result["computed_fields"] = computed
        end
    end

    return result
end

"""
Return ordered columns for registration detail exports as defined in the
event configuration.

Looks for `[export.registration_details]` with a `columns` array. Entries are
matched against known base columns, then resolved via event aliases to actual
field names. Unknown entries are returned as-is to allow future extension.
"""
function get_registration_detail_columns(event_id::AbstractString,
                                          config_dir::AbstractString=CONFIG_DIR[])
    path = joinpath(config_dir, "events", "$event_id.toml")

    if !isfile(path)
        return nothing
    end

    # Ensure event aliases are loaded for this event (used for resolution)
    try
        load_event_aliases(event_id, config_dir)
    catch err
        @warn "Failed to load event aliases for registration detail columns" event_id=event_id exception=err
    end

    config = TOML.parsefile(path)
    export_section = get(config, "export", nothing)

    if !(export_section isa AbstractDict)
        return nothing
    end

    details = get(export_section, "registration_details", nothing)
    if !(details isa AbstractDict)
        return nothing
    end

    columns = get(details, "columns", nothing)
    if !(columns isa AbstractVector)
        return nothing
    end

    base_columns = Set([
        "id",
        "reference_number",
        "first_name",
        "last_name",
        "email",
        "computed_cost",
        "registration_date",
    ])

    ordered = String[]
    seen = Set{String}()

    for raw_entry in columns
        if !(raw_entry isa AbstractString)
            continue
        end

        entry = strip(String(raw_entry))
        if isempty(entry)
            continue
        end

        resolved = if entry in base_columns
            entry
        else
            try
                resolve_field_name(entry, event_id)
            catch
                entry
            end
        end

        if !(resolved in seen)
            push!(ordered, resolved)
            push!(seen, resolved)
        end
    end

    return isempty(ordered) ? nothing : ordered
end

"""
Generate a template event config file with UNIFIED aliases and cost rules.

This creates a single configuration file for the event that includes:
1. [event] - Event metadata
2. [aliases] - Field name aliases (event-specific, consistent with cost rules)
3. [costs] - Cost calculation rules using the defined aliases

If a database connection is provided, generates a template based on actual data.
Otherwise, generates a generic placeholder template.
"""
function generate_event_config_template(event_id::AbstractString,
                                         output_path::AbstractString;
                                         event_name::String="",
                                         db::Union{DuckDB.DB,Nothing}=nothing,
                                         config_dir::AbstractString=CONFIG_DIR[])
    # Try to load existing global field aliases (for suggestions)
    load_field_aliases(config_dir)

    # If we have a database, get actual fields for this event
    actual_fields = String[]
    field_values = Dict{String, Set{String}}()  # field -> unique values seen

    if db !== nothing
        # Get all unique field names from registrations for this event
        result = DBInterface.execute(db,
            "SELECT DISTINCT json_keys(fields) FROM registrations WHERE event_id = ?",
            [event_id])

        for row in result
            if row[1] !== nothing
                for field in row[1]
                    push!(actual_fields, field)
                end
            end
        end
        actual_fields = sort(unique(actual_fields))

        # Also get sample values for each field to help with rule creation
        if !isempty(actual_fields)
            for field in actual_fields
                result = DBInterface.execute(db, """
                    SELECT DISTINCT json_extract_string(fields, ?) as val
                    FROM registrations
                    WHERE event_id = ? AND json_extract_string(fields, ?) IS NOT NULL
                    LIMIT 10
                """, [field, event_id, field])

                values = Set{String}()
                for row in result
                    if row[1] !== nothing
                        push!(values, row[1])
                    end
                end
                field_values[field] = values
            end
        end
    end

    # Generate aliases for all fields - use CONSISTENT naming
    field_to_alias = Dict{String, String}()
    for field in actual_fields
        # Check if there's already a global alias defined
        existing_alias = get_field_alias(field)
        if existing_alias != field
            field_to_alias[field] = existing_alias
        else
            # Generate a new alias
            field_to_alias[field] = generate_alias_suggestion(field)
        end
    end

            alias_to_field = Dict{String, String}()
            for (field, alias) in field_to_alias
                alias_to_field[alias] = field
            end

    # Build the template
    lines = String[]

    push!(lines, "# Event Configuration: $event_id")
    push!(lines, "# Generated on $(Dates.format(Dates.now(), "yyyy-mm-dd HH:MM"))")
    push!(lines, "#")
    push!(lines, "# This is a UNIFIED event configuration file containing:")
    push!(lines, "#   - [aliases]: Field name mappings (short name → actual form field)")
    push!(lines, "#   - [costs]: Cost calculation rules using the aliases defined above")
    push!(lines, "#")
    push!(lines, "# After editing, run: eventreg sync-config && eventreg recalculate-costs $event_id")
    push!(lines, "")

    # Event section
    push!(lines, "[event]")
    push!(lines, "name = \"$(isempty(event_name) ? event_id : event_name)\"")
    push!(lines, "")

    # ==========================================================================
    # ALIASES SECTION
    # ==========================================================================
    push!(lines, "# ═══════════════════════════════════════════════════════════════════════════════")
    push!(lines, "# FIELD ALIASES")
    push!(lines, "# Maps short, easy-to-use names to actual field names from form submissions.")
    push!(lines, "# Use these aliases (left side) in the cost rules below.")
    push!(lines, "# ═══════════════════════════════════════════════════════════════════════════════")
    push!(lines, "")
    push!(lines, "[aliases]")

    if !isempty(actual_fields)
        for field in actual_fields
            alias = field_to_alias[field]
            values = get(field_values, field, Set{String}())

            # Add comment showing sample values
            if !isempty(values)
                values_list = sort(collect(values))
                if length(values_list) <= 3
                    values_preview = join(values_list, ", ")
                else
                    values_preview = join(values_list[1:3], ", ") * ", ..."
                end
                push!(lines, "# Values: $values_preview")
            end

            escaped_field = escape_toml_string(field)
            push!(lines, "$alias = $escaped_field")
            push!(lines, "")
        end
    else
        push!(lines, "# No registrations found yet - add aliases after processing emails")
        push!(lines, "# Example:")
        push!(lines, "# vorname = \"Vorname\"")
        push!(lines, "# nachname = \"Nachname\"")
        push!(lines, "# email = \"E-Mail\"")
        push!(lines, "")
    end

    # ==========================================================================
    # COSTS SECTION
    # ==========================================================================
    push!(lines, "# ═══════════════════════════════════════════════════════════════════════════════")
    push!(lines, "# COST RULES")
    push!(lines, "# Define how costs are calculated for each registration.")
    push!(lines, "# Use the alias names defined above (not the full field names).")
    push!(lines, "# ═══════════════════════════════════════════════════════════════════════════════")
    push!(lines, "")
    push!(lines, "# [costs]")
    push!(lines, "# Base cost that everyone pays")
    push!(lines, "# base = 0.0")
    push!(lines, "")

    if !isempty(actual_fields)
        push!(lines, "# Cost rules - each rule adds to the total when conditions match")
        push!(lines, "# Uncomment and modify as needed")
        push!(lines, "")

        # Generate example rules for fields that look like yes/no questions
        example_count = 0
        for field in actual_fields
            values = get(field_values, field, Set{String}())
            alias = field_to_alias[field]

            # Check if it looks like a yes/no field
            if "Ja" in values || "ja" in values || "Yes" in values || "yes" in values
                if example_count > 0
                    push!(lines, "")
                end
                push!(lines, "# [[costs.rules]]")
                push!(lines, "# field = \"$alias\"  # → $(escape_toml_string(field))")
                push!(lines, "# value = \"Ja\"")
                push!(lines, "# cost = 0.0")
                example_count += 1
                if example_count >= 5
                    break
                end
            end
        end

        if example_count == 0
            # If no yes/no fields found, generate a generic example
            first_alias = isempty(actual_fields) ? "field_name" : field_to_alias[actual_fields[1]]
            push!(lines, "# [[costs.rules]]")
            push!(lines, "# field = \"$first_alias\"")
            push!(lines, "# value = \"value_to_match\"")
            push!(lines, "# cost = 0.0")
        end
    else
        push!(lines, "# Example rule format:")
        push!(lines, "# [[costs.rules]]")
        push!(lines, "# field = \"alias_name\"  # Use an alias from the [aliases] section")
        push!(lines, "# value = \"Ja\"         # or use pattern = \"regex\" for partial match")
        push!(lines, "# cost = 25.0")
    end

    push!(lines, "")
    push!(lines, "# ───────────────────────────────────────────────────────────────────────────────")
    push!(lines, "# ADVANCED: Computed fields for multipliers")
    push!(lines, "# ───────────────────────────────────────────────────────────────────────────────")
    push!(lines, "#")
    push!(lines, "# Use computed fields to create multipliers, e.g., for per-night costs:")
    push!(lines, "#")
    push!(lines, "# [costs.computed_fields.nights]")
    push!(lines, "# sum_of = [")

    # Try to find actual overnight fields from the data for better examples
    overnight_examples_added = false
    for field in actual_fields
        alias = field_to_alias[field]
        if occursin(r"uebernachtung|übernachtung|overnight|nacht"i, field) ||
           occursin(r"uebernachtung|overnight|nacht"i, alias)
            values = get(field_values, field, Set{String}())
            if "Ja" in values || "ja" in values
                push!(lines, "#     { field = \"$alias\", value = \"Ja\", count = 1 },")
                overnight_examples_added = true
            end
        end
    end

    if !overnight_examples_added
        push!(lines, "#     { field = \"uebernachtung_fr\", value = \"Ja\", count = 1 },")
        push!(lines, "#     { field = \"uebernachtung_sa\", value = \"Ja\", count = 1 },")
    end

    push!(lines, "# ]")
    push!(lines, "#")
    push!(lines, "# Then use in a rule with multiply_by:")
    push!(lines, "# [[costs.rules]]")
    push!(lines, "# field = \"zimmer\"")
    push!(lines, "# pattern = \"Einzelzimmer\"")
    push!(lines, "# cost = 10.0")
    push!(lines, "# multiply_by = \"nights\"  # 10€ per night for single room")

    push!(lines, "")
    push!(lines, "# ───────────────────────────────────────────────────────────────────────────────")
    push!(lines, "# ADVANCED: Bundled options (conditional rules)")
    push!(lines, "# ───────────────────────────────────────────────────────────────────────────────")
    push!(lines, "#")
    push!(lines, "# Use 'unless' and 'only_if' to create conditional cost rules:")
    push!(lines, "#")
    push!(lines, "# EXAMPLE: Overnight stay includes meals, but meals can be booked separately")
    push!(lines, "#")
    push!(lines, "# # Overnight includes meals (50€ total)")
    push!(lines, "# [[costs.rules]]")
    push!(lines, "# field = \"uebernachtung_fr\"")
    push!(lines, "# value = \"Ja\"")
    push!(lines, "# cost = 50.0")
    push!(lines, "#")
    push!(lines, "# # Dinner charged separately (15€) UNLESS staying overnight")
    push!(lines, "# [[costs.rules]]")
    push!(lines, "# field = \"abendessen_fr\"")
    push!(lines, "# value = \"Ja\"")
    push!(lines, "# cost = 15.0")
    push!(lines, "# unless = { field = \"uebernachtung_fr\", value = \"Ja\" }")
    push!(lines, "#")
    push!(lines, "# # Breakfast (10€) UNLESS staying overnight Friday OR Saturday")
    push!(lines, "# [[costs.rules]]")
    push!(lines, "# field = \"fruehstueck_sa\"")
    push!(lines, "# value = \"Ja\"")
    push!(lines, "# cost = 10.0")
    push!(lines, "# unless = [")
    push!(lines, "#     { field = \"uebernachtung_fr\", value = \"Ja\" },")
    push!(lines, "#     { field = \"uebernachtung_sa\", value = \"Ja\" }")
    push!(lines, "# ]")
    push!(lines, "#")
    push!(lines, "# EXAMPLE: Discount only for specific groups")
    push!(lines, "#")
    push!(lines, "# # Student discount ONLY IF both student AND member")
    push!(lines, "# [[costs.rules]]")
    push!(lines, "# field = \"rabatt_student\"")
    push!(lines, "# value = \"Ja\"")
    push!(lines, "# cost = -10.0")
    push!(lines, "# only_if = [")
    push!(lines, "#     { field = \"student\", value = \"Ja\" },")
    push!(lines, "#     { field = \"mitglied\", value = \"Ja\" }")
    push!(lines, "# ]")
    push!(lines, "#")
    push!(lines, "# Both 'unless' and 'only_if' support:")
    push!(lines, "#   - Single condition: unless = { field = \"X\", value = \"Y\" }")
    push!(lines, "#   - Multiple conditions: unless = [{ ... }, { ... }]")
    push!(lines, "#   - Pattern matching: unless = { field = \"X\", pattern = \"regex\" }")
    push!(lines, "#")
    push!(lines, "# Logic:")
    push!(lines, "#   - 'unless': Skip rule if ANY condition matches (OR logic)")
    push!(lines, "#   - 'only_if': Skip rule unless ALL conditions match (AND logic)")

    # ==========================================================================
    # REGISTRATION DETAIL EXPORT (COLUMN ORDER)
    # ==========================================================================
    push!(lines, "")
    push!(lines, "# ═══════════════════════════════════════════════════════════════════════════════")
    push!(lines, "# REGISTRATION DETAIL EXPORT")
    push!(lines, "# Controls the column order for 'eventreg export-registration-details'.")
    push!(lines, "# Only the columns listed here are exported; add or remove entries as needed.")
    push!(lines, "# Form field aliases are resolved automatically to actual field names.")
    push!(lines, "# ═══════════════════════════════════════════════════════════════════════════════")
    push!(lines, "")

    detail_priority = [
        "reference_number",
        "first_name",
        "last_name",
        "email",
        "registration_date",
        "computed_cost",
    ]

    seen_columns = Set{String}()
    detail_columns = String[]

    for col in detail_priority
        if !(col in seen_columns)
            push!(detail_columns, col)
            push!(seen_columns, col)
        end
    end

    for field in actual_fields
        alias = field_to_alias[field]
        if !(alias in seen_columns)
            push!(detail_columns, alias)
            push!(seen_columns, alias)
        end
    end

    push!(lines, "[export.registration_details]")
    push!(lines, "columns = [")

    if isempty(actual_fields)
        push!(lines, "    # Add additional field aliases below once registrations are available")
    end

    for (idx, col) in enumerate(detail_columns)
        is_last = idx == length(detail_columns)
        suffix = is_last ? "" : ","
        comment = haskey(alias_to_field, col) ? "  # → $(alias_to_field[col])" : ""
        push!(lines, "    \"$col\"$suffix$comment")
    end

    push!(lines, "]")

    content = join(lines, "\n") * "\n"
    write(output_path, content)

    @info "Generated unified event config" path=output_path event_id=event_id fields=length(actual_fields)

    return actual_fields
end

"""
Load all event configs from config/events/ directory.
"""
function load_all_event_configs(config_dir::AbstractString=CONFIG_DIR[])
    events_dir = joinpath(config_dir, "events")

    if !isdir(events_dir)
        return Dict{String, Any}()
    end

    configs = Dict{String, Any}()

    for file in readdir(events_dir)
        if endswith(file, ".toml")
            event_id = file[1:end-5]  # Remove .toml extension
            config = load_event_config(event_id, config_dir)
            if config !== nothing
                configs[event_id] = config
            end
        end
    end

    return configs
end

"""
Sync event configs from TOML files to database.
"""
function sync_event_configs_to_db!(db::DuckDB.DB, config_dir::AbstractString=CONFIG_DIR[])
    # Load event configs (event-specific aliases only)
    configs = load_all_event_configs(config_dir)
    for (event_id, config) in configs
        event_name = get(config, "event_name", nothing)
        if isnothing(event_name)
            println("Why is event name notnhing?")
            continue
        end
        base_cost = get(config, "base", 0.0)

        # Check if costs are actually configured (not just commented out)
        # Only store cost_rules if the config contains actual cost data
        has_costs = haskey(config, "base") || haskey(config, "rules") || haskey(config, "computed_fields")

        if has_costs
            # Remove event_name from rules dict
            rules = copy(config)
            delete!(rules, "event_name")
            rules_json = JSON.json(rules)
            rules_json = replace(rules_json, "€" => "\\u20AC")

            with_transaction(db) do
                DBInterface.execute(db,
                """
                    INSERT INTO events (event_id, event_name, base_cost, cost_rules)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT (event_id) DO UPDATE SET
                        event_name = COALESCE(EXCLUDED.event_name, events.event_name),
                        base_cost = EXCLUDED.base_cost,
                        cost_rules = EXCLUDED.cost_rules
                """
                , [event_id, event_name, base_cost, rules_json])
            end
        else
            # No costs configured - store NULL for cost_rules
            with_transaction(db) do
                DBInterface.execute(db,
                """
                    INSERT INTO events (event_id, event_name, base_cost, cost_rules)
                    VALUES (?, ?, ?, NULL)
                    ON CONFLICT (event_id) DO UPDATE SET
                        event_name = COALESCE(EXCLUDED.event_name, events.event_name),
                        base_cost = EXCLUDED.base_cost,
                        cost_rules = NULL
                """
                , [event_id, event_name, base_cost])
            end
        end

        # Record event config sync
        event_config_path = joinpath(config_dir, "events", "$event_id.toml")
        if isfile(event_config_path)
            record_config_sync(db, event_config_path)
        end
    end  # End for loop

    println("Synced $(length(configs)) event configs to database")
end

# =============================================================================
# CONFIG SYNC TRACKING
# =============================================================================

"""
Status of a config file's sync state.
"""
struct ConfigSyncStatus
    path::String
    file_mtime::DateTime
    synced_at::Union{DateTime,Nothing}
    is_synced::Bool
    needs_sync::Bool
end

"""
Compute file hash for config file.
"""
function compute_file_hash(filepath::AbstractString)
    return bytes2hex(sha256(read(filepath)))
end

"""
Get the modification time of a file as DateTime.
"""
function get_file_mtime(filepath::AbstractString)::DateTime
    return unix2datetime(stat(filepath).mtime)
end

"""
Record that a config file has been synced.
Stores the file hash and optionally a snapshot of the config content.
"""
function record_config_sync(db::DuckDB.DB, config_path::AbstractString)
    file_hash = compute_file_hash(config_path)
    now_ts = Dates.now()

    # Read and store config snapshot (for audit trail)
    config_content = try
        read(config_path, String)
    catch
        nothing
    end

    with_transaction(db) do
        DBInterface.execute(db, """
            INSERT INTO config_sync (config_path, file_hash, config_snapshot, synced_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT (config_path) DO UPDATE SET
                file_hash = EXCLUDED.file_hash,
                config_snapshot = EXCLUDED.config_snapshot,
                synced_at = EXCLUDED.synced_at
        """, [config_path, file_hash, config_content, now_ts])
    end
end

"""
Check if a config file needs syncing.
Returns ConfigSyncStatus with details.
"""
function check_config_sync(db::DuckDB.DB, config_path::AbstractString)::ConfigSyncStatus
    if !isfile(config_path)
        return ConfigSyncStatus(config_path, DateTime(0), nothing, false, false)
    end

    file_mtime = get_file_mtime(config_path)

    result = DBInterface.execute(db,
        "SELECT synced_at, file_hash FROM config_sync WHERE config_path = ?",
        [config_path])
    rows = collect(result)

    if isempty(rows)
        # Never synced
        return ConfigSyncStatus(config_path, file_mtime, nothing, false, true)
    end

    synced_at, stored_hash = rows[1]
    current_hash = compute_file_hash(config_path)

    # Check if file has changed since last sync (comparing hashes is more reliable)
    is_synced = current_hash == stored_hash
    needs_sync = !is_synced

    return ConfigSyncStatus(config_path, file_mtime, synced_at, is_synced, needs_sync)
end

"""
Get list of all config files that need syncing.
Checks all event configs (fields.toml is deprecated).
"""
function get_unsynced_configs(db::DuckDB.DB, config_dir::AbstractString=CONFIG_DIR[])::Vector{ConfigSyncStatus}
    unsynced = ConfigSyncStatus[]

    # Check all event configs
    events_dir = joinpath(config_dir, "events")
    if isdir(events_dir)
        for file in readdir(events_dir)
            if endswith(file, ".toml")
                event_path = joinpath(events_dir, file)
                status = check_config_sync(db, event_path)
                if status.needs_sync
                    push!(unsynced, status)
                end
            end
        end
    end

    return unsynced
end

"""
Get sync status for all config files.
Returns a vector of (path, synced, needs_sync) tuples.
"""
function get_all_config_sync_status(db::DuckDB.DB, config_dir::AbstractString=CONFIG_DIR[])
    statuses = ConfigSyncStatus[]

    # Check all event configs (fields.toml is deprecated)
    events_dir = joinpath(config_dir, "events")
    if isdir(events_dir)
        for file in readdir(events_dir)
            if endswith(file, ".toml")
                event_path = joinpath(events_dir, file)
                push!(statuses, check_config_sync(db, event_path))
            end
        end
    end

    return statuses
end

end # module
