# Project initialization and status commands

"""
Initialize a new project in the current directory.
Does not take a db handle; creates and closes the database. In REPL mode,
running init will close the current connection and re-open after re-initializing.
"""
function cmd_init(; db_path::String="events.duckdb")
    @info "Initializing EventRegistrations project..." db_path=db_path

    db = init_project(db_path)
    DBInterface.close!(db)
    return 0
end

"""
Generate field configuration from existing submissions.
"""
function cmd_generate_field_config(db::DuckDB.DB;
    event_id::Union{String,Nothing}=nothing,
    output::Union{String,Nothing}=nothing,
    events_dir::String="events")
    output_path = output !== nothing ? output : "fields.toml"
    generate_field_config(db, output_path; event_id=event_id)
    return 0
end

"""
Create event config template for an event.
"""
function cmd_create_event_config(db::DuckDB.DB, event_id::String;
    events_dir::String="events")
    output_path = joinpath(events_dir, "$event_id.toml")
    mkpath(events_dir)
    generate_event_config_template(event_id, output_path; db=db)
    @info "Created event config" path=output_path
    return 0
end

"""
Sync event config files to database.
"""
function cmd_sync_config(db::DuckDB.DB; events_dir::String="events")
    updated = sync_event_configs_to_db!(db, events_dir)
    @info "Synced event configs to database" updated=length(updated)
    return 0
end

"""
Recalculate costs for an event after config changes.
"""
function cmd_recalculate_costs(db::DuckDB.DB, event_id::String;
    events_dir::String="events",
    strict::Bool=false,
    dry_run::Bool=false)
    recalculate_costs!(db, event_id; events_dir=events_dir, strict=strict, dry_run=dry_run)
    @info "Recalculated costs" event_id=event_id
    return 0
end

"""
Show system status and configuration summary.
Caller must open db; run_cli opens it before calling.
"""
function cmd_status(db::DuckDB.DB; db_path::String="events.duckdb")
    events_dir = "events"
    header = [
        "EventRegistrations System Status",
        "=" ^ 80,
        "",
        "Working Directory:",
        "  Current: $(pwd())",
        "",
        "Database:",
        "  Path: $db_path",
        "  Status: ✓ Exists",
        "  Size: $(round(stat(db_path).size / 1024 / 1024, digits=2)) MB",
    ]
    result = DBInterface.execute(db, "SELECT COUNT(*) FROM processed_emails")
    email_count = first(collect(result))[1]
    push!(header, "  Emails processed: $email_count")
    result = DBInterface.execute(db, "SELECT COUNT(*) FROM submissions")
    submission_count = first(collect(result))[1]
    push!(header, "  Total submissions: $submission_count")
    result = DBInterface.execute(db, "SELECT COUNT(*) FROM registrations")
    registration_count = first(collect(result))[1]
    push!(header, "  Active registrations: $registration_count")

    push!(header, "", "Configuration:")
    if isdir(events_dir)
        event_configs = filter(f -> endswith(f, ".toml"), readdir(events_dir))
        push!(header, "  Event configs: $(length(event_configs)) files in $events_dir")
        for config_file in event_configs
            push!(header, "    - $(config_file)")
        end
    else
        push!(header, "  Events directory: ❌ Not found")
    end
    templates_dir = "templates"
    if isdir(templates_dir)
        template_files = filter(f -> endswith(f, ".mustache"), readdir(templates_dir))
        push!(header, "  Templates: $(length(template_files)) files in $templates_dir")
    else
        push!(header, "  Templates directory: ❌ Not found")
    end
    @info join(header, "\n")

    event_rows = collect(DBInterface.execute(db, "SELECT event_id FROM events"))
    if isempty(event_rows)
        @info "Config validation: No events to validate"
    else
        missing = 0
        invalid = 0
        warnings = 0
        for row in event_rows
            eid = row[1]
            cfg = Config.load_event_config(eid, events_dir)
            if cfg === nothing
                missing += 1
                continue
            end
            rules = Config.materialize_cost_rules(cfg)
            result = validate_cost_config(rules, eid, db; strict=false)
            warnings += length(result.warnings)
            invalid += result.valid ? 0 : 1
        end
        if missing == 0 && invalid == 0 && warnings == 0
            @info "Config validation: ✓ All event configs valid"
        else
            @warn "Config validation summary" missing=missing invalid=invalid warnings=warnings
        end
    end

    result = DBInterface.execute(db, """
        SELECT e.event_id,
                COALESCE(e.event_name, e.event_id) as name,
                COUNT(r.id) as reg_count
        FROM events e
        LEFT JOIN registrations r ON r.event_id = e.event_id
        GROUP BY e.event_id, name
        ORDER BY e.event_id
    """)
    events = collect(result)
    if isempty(events)
        @info "Events in Database: none"
    else
        lines = ["Events in Database:"]
        for row in events
            eid, name, reg_count = row
            push!(lines, "  - $eid : $name (registrations: $reg_count)")
        end
        @info join(lines, "\n")
    end
    return 0
end
