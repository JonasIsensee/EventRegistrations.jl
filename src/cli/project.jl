# Project initialization and status commands

"""
Initialize a new project in the current directory.
"""
function cmd_init(; db_path::String="events.duckdb", config_dir::String="config")
    @info "Initializing EventRegistrations project..." db_path=db_path config_dir=config_dir

    db = init_project(db_path, config_dir)
    DBInterface.close!(db)
    return 0
end

"""
Show system status and configuration summary.
"""
function cmd_status(; db_path::String="events.duckdb", config_dir::String="config")
    header = [
        "EventRegistrations System Status",
        "=" ^ 80,
        "",
        "Working Directory:",
        "  Current: $(pwd())",
        "",
        "Database:",
        "  Path: $db_path",
    ]

    db_exists = isfile(db_path)

    if db_exists
        push!(header, "  Status: ✓ Exists")
        push!(header, "  Size: $(round(stat(db_path).size / 1024 / 1024, digits=2)) MB")

        require_database(db_path) do db
            # Count emails processed
            result = DBInterface.execute(db, "SELECT COUNT(*) FROM processed_emails")
            email_count = first(collect(result))[1]
            push!(header, "  Emails processed: $email_count")

            # Count submissions
            result = DBInterface.execute(db, "SELECT COUNT(*) FROM submissions")
            submission_count = first(collect(result))[1]
            push!(header, "  Total submissions: $submission_count")

            # Count registrations
            result = DBInterface.execute(db, "SELECT COUNT(*) FROM registrations")
            registration_count = first(collect(result))[1]
            push!(header, "  Active registrations: $registration_count")
        end
    else
        push!(header, "  Status: ❌ Not found (run 'eventreg init' or 'eventreg sync' to create)")
    end

    # Configuration
    push!(header, "", "Configuration:")
    push!(header, "  Config directory: $config_dir")
    if isdir(config_dir)
        push!(header, "  Status: ✓ Exists")

        # Check fields.toml
        fields_path = joinpath(config_dir, "fields.toml")
        if isfile(fields_path)
            push!(header, "  Fields config: ✓ $fields_path")
        else
            push!(header, "  Fields config: ❌ Not found (run 'eventreg generate-field-config')")
        end

        # Check events directory
        events_dir = joinpath(config_dir, "events")
        if isdir(events_dir)
            event_configs = filter(f -> endswith(f, ".toml"), readdir(events_dir))
            push!(header, "  Event configs: $(length(event_configs)) files in $events_dir")
            for config_file in event_configs
                push!(header, "    - $(config_file)")
            end
        else
            push!(header, "  Events directory: ❌ Not found")
        end

        # Check templates directory
        templates_dir = joinpath(config_dir, "templates")
        if isdir(templates_dir)
            template_files = filter(f -> endswith(f, ".mustache"), readdir(templates_dir))
            push!(header, "  Templates: $(length(template_files)) files in $templates_dir")
        else
            push!(header, "  Templates directory: ❌ Not found")
        end
    else
        push!(header, "  Status: ❌ Not found (run 'eventreg init' to create)")
    end

    @info join(header, "\n")

    # Config sync summary (requires DB)
    if db_exists
        require_database(db_path) do db
            statuses = Config.get_all_config_sync_status(db, config_dir)
            if isempty(statuses)
                @info "Config sync: No config files found" config_dir=config_dir
            else
                unsynced = filter(s -> s.needs_sync, statuses)
                if isempty(unsynced)
                    @info "Config sync: ✓ All configs in sync"
                else
                    rel_paths = [replace(s.path, pwd() * "/" => "") for s in unsynced]
                    @warn "Config sync: files need syncing" files=rel_paths
                end
            end
        end
    end

    # Validation summary (lightweight)
    if db_exists && isdir(config_dir)
        require_database(db_path) do db
            event_rows = collect(DBInterface.execute(db, "SELECT event_id FROM events"))
            if isempty(event_rows)
                @info "Config validation: No events to validate"
            else
                missing = 0
                invalid = 0
                warnings = 0
                for row in event_rows
                    eid = row[1]
                    cfg = Config.load_event_config(eid, config_dir)
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
        end
    end

    # Events in database
    if db_exists
        require_database(db_path) do db
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
        end
    end

    return 0
end
