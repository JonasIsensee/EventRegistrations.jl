module Config

using DBInterface: DBInterface
using Dates: Dates, DateTime, unix2datetime
using DuckDB: DuckDB
using JSON: JSON
using SHA: SHA, sha256
using TOML: TOML

# Import from parent module
import ..EventRegistrations: with_transaction

export DEFAULT_CONFIG_DIR, EventConfig, load_event_config
export materialize_cost_rules, get_registration_detail_columns
export generate_field_config, generate_event_config_template
export check_config_sync, get_unsynced_configs, record_config_sync
export ConfigSyncStatus

const DEFAULT_CONFIG_DIR = "config"

struct EventConfig
    event_id::String
    name::String
    config_path::String
    config_hash::String
    aliases::Dict{String,String}
    reverse_aliases::Dict{String,String}
    base_cost::Float64
    rules::Vector{Dict{String,Any}}
    computed_fields::Dict{String,Any}
    export_registration_columns::Union{Nothing,Vector{String}}
end

# =============================================================================
# FIELD ALIAS UTILITIES
# =============================================================================


get_field_alias(actual_name::AbstractString) = actual_name

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

const REGISTRATION_BASE_COLUMNS = Set([
    "id",
    "reference_number",
    "first_name",
    "last_name",
    "email",
    "computed_cost",
    "registration_date",
])

resolve_alias(name::AbstractString, aliases::Dict{String,String}) = get(aliases, name, name)

function parse_aliases(config::Dict)
    aliases = Dict{String,String}()
    reverse = Dict{String,String}()
    raw_aliases = get(config, "aliases", Dict())
    for (alias, actual) in raw_aliases
        a = string(alias)
        act = string(actual)
        aliases[a] = act
        reverse[act] = a
    end
    return aliases, reverse
end

function parse_rules(costs::Dict, aliases::Dict{String,String})
    rules = Vector{Dict{String,Any}}()
    if haskey(costs, "rules")
        for rule in costs["rules"]
            new_rule = Dict{String,Any}()
            for (k, v) in rule
                if k == "field"
                    new_rule[k] = resolve_alias(string(v), aliases)
                elseif k == "unless" || k =="only_if"
                    if v isa Dict && haskey(v, "field")
                        v["field"] = resolve_alias(string(v["field"]), aliases)
                    end
                    new_rule[k] = v
                else
                    new_rule[k] = v
                end
            end
            push!(rules, new_rule)
        end
    end
    return rules
end

function parse_computed_fields(costs::Dict, aliases::Dict{String,String})
    computed_fields = Dict{String,Any}()
    if haskey(costs, "computed_fields")
        for (name, definition) in costs["computed_fields"]
            if isa(definition, Dict) && haskey(definition, "sum_of")
                items = Vector{Dict{String,Any}}()
                for item in definition["sum_of"]
                    new_item = Dict{String,Any}()
                    for (k, v) in item
                        if k == "field"
                            new_item[k] = resolve_alias(string(v), aliases)
                        else
                            new_item[k] = v
                        end
                    end
                    push!(items, new_item)
                end
                computed_fields[string(name)] = Dict("sum_of" => items)
            end
        end
    end
    return computed_fields
end

function parse_registration_detail_columns(config::Dict, aliases::Dict{String,String})
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

        resolved = entry in REGISTRATION_BASE_COLUMNS ? entry : resolve_alias(entry, aliases)

        if !(resolved in seen)
            push!(ordered, resolved)
            push!(seen, resolved)
        end
    end

    return isempty(ordered) ? nothing : ordered
end

"""
Load event configuration from config/events/{event_id}.toml into a typed EventConfig.
"""
function load_event_config(event_id::AbstractString, events_dir::AbstractString="events")
    path = joinpath(events_dir, "$event_id.toml")
    !isfile(path) && return nothing

    config = TOML.parsefile(path)
    aliases, reverse_aliases = parse_aliases(config)
    costs = get(config, "costs", Dict())

    base_cost = Float64(get(costs, "base", 0.0))
    rules = parse_rules(costs, aliases)
    computed_fields = parse_computed_fields(costs, aliases)
    export_columns = parse_registration_detail_columns(config, aliases)

    event_name = get(get(config, "event", Dict()), "name", event_id) |> string
    cfg_hash = compute_file_hash(path)

    return EventConfig(event_id, event_name, path, cfg_hash,
        aliases, reverse_aliases, base_cost, rules, computed_fields, export_columns)
end

function materialize_cost_rules(cfg::EventConfig)
    return Dict(
        "base" => cfg.base_cost,
        "rules" => cfg.rules,
        "computed_fields" => cfg.computed_fields,
    )
end

function get_registration_detail_columns(event_id::AbstractString,
                                          events_dir::AbstractString="events")
    cfg = load_event_config(event_id, events_dir)
    return isnothing(cfg) ? nothing : cfg.export_registration_columns
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
                                        )

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
Sync event configs from TOML files to database (metadata only).
Stores event id, name, base cost, and records config hash for change detection.
"""
function sync_event_configs_to_db!(db::DuckDB.DB, events_dir::AbstractString="events")
    # Check all event configs
    synced = String[]
    isdir(events_dir) || return synced

    for file in readdir(events_dir)
        !endswith(file, ".toml") && continue
        event_id = splitext(file)[1]
        status = check_config_sync(db, joinpath(events_dir, file))
        status.needs_sync || continue
        cfg = load_event_config(event_id, events_dir)
        with_transaction(db) do
            DBInterface.execute(db,
            """
                INSERT INTO events (event_id, event_name)
                VALUES (?, ?)
                ON CONFLICT (event_id) DO UPDATE SET
                    event_name = COALESCE(EXCLUDED.event_name, events.event_name),
            """
            , [cfg.event_id, cfg.name])
        end
        record_config_sync(db, cfg.config_path)
        push!(synced, cfg.event_id)
    end
    @info "Synced $(length(synced)) event configs to database"
    return synced
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
function get_unsynced_configs(db::DuckDB.DB, events_dir::AbstractString="events")::Vector{ConfigSyncStatus}
    unsynced = ConfigSyncStatus[]
    # Check all event configs
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
function get_all_config_sync_status(db::DuckDB.DB, config_dir::AbstractString=DEFAULT_CONFIG_DIR)
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
