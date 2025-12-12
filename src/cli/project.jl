# Project initialization and status commands

"""
Initialize a new project in the current directory.
"""
function cmd_init(; db_path::String="events.duckdb", config_dir::String="config")
    println("Initializing EventRegistrations project...")
    println("  Database: $db_path")
    println("  Config: $config_dir")

    db = init_project(db_path, config_dir)
    DBInterface.close!(db)
    return 0
end

"""
Show system status and configuration summary.
"""
function cmd_status(; db_path::String="events.duckdb", config_dir::String="config")
    println("EventRegistrations System Status")
    println("=" ^ 80)
    println()

    # Working directory
    println("Working Directory:")
    println("  Current: $(pwd())")
    println()

    # Database
    println("Database:")
    println("  Path: $db_path")

    db_exists = isfile(db_path)
    if db_exists
        println("  Status: ✓ Exists")
        println("  Size: $(round(stat(db_path).size / 1024 / 1024, digits=2)) MB")

        require_database(db_path) do db
            # Count emails processed
            result = DBInterface.execute(db, "SELECT COUNT(*) FROM processed_emails")
            email_count = first(collect(result))[1]
            println("  Emails processed: $email_count")

            # Count submissions
            result = DBInterface.execute(db, "SELECT COUNT(*) FROM submissions")
            submission_count = first(collect(result))[1]
            println("  Total submissions: $submission_count")

            # Count registrations
            result = DBInterface.execute(db, "SELECT COUNT(*) FROM registrations")
            registration_count = first(collect(result))[1]
            println("  Active registrations: $registration_count")
        end
    else
        println("  Status: ❌ Not found (run 'eventreg init' or 'eventreg sync' to create)")
    end

    # Configuration
    println("\nConfiguration:")
    println("  Config directory: $config_dir")
    if isdir(config_dir)
        println("  Status: ✓ Exists")

        # Check fields.toml
        fields_path = joinpath(config_dir, "fields.toml")
        if isfile(fields_path)
            println("  Fields config: ✓ $fields_path")
        else
            println("  Fields config: ❌ Not found (run 'eventreg generate-field-config')")
        end

        # Check events directory
        events_dir = joinpath(config_dir, "events")
        if isdir(events_dir)
            event_configs = filter(f -> endswith(f, ".toml"), readdir(events_dir))
            println("  Event configs: $(length(event_configs)) files in $events_dir")
            for config_file in event_configs
                println("    - $(config_file)")
            end
        else
            println("  Events directory: ❌ Not found")
        end

        # Check templates directory
        templates_dir = joinpath(config_dir, "templates")
        if isdir(templates_dir)
            template_files = filter(f -> endswith(f, ".mustache"), readdir(templates_dir))
            println("  Templates: $(length(template_files)) files in $templates_dir")
        else
            println("  Templates directory: ❌ Not found")
        end
    else
        println("  Status: ❌ Not found (run 'eventreg init' to create)")
    end
    println()

    # Config sync summary (requires DB)
    if db_exists
        require_database(db_path) do db
            statuses = Config.get_all_config_sync_status(db, config_dir)
            if isempty(statuses)
                println("Config sync: No config files found in $config_dir")
            else
                unsynced = filter(s -> s.needs_sync, statuses)
                if isempty(unsynced)
                    println("Config sync: ✓ All configs in sync")
                else
                    println("Config sync: ⚠ $(length(unsynced)) file(s) need syncing")
                    for s in unsynced
                        rel = replace(s.path, pwd() * "/" => "")
                        println("  - $rel")
                    end
                end
            end
        end
        println()
    end

    # Validation summary (lightweight)
    if db_exists && isdir(config_dir)
        require_database(db_path) do db
            load_field_aliases(config_dir)
            event_rows = collect(DBInterface.execute(db, "SELECT event_id FROM events"))
            if isempty(event_rows)
                println("Config validation: No events to validate")
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
                    println("Config validation: ✓ All event configs valid")
                else
                    println("Config validation summary:")
                    println("  Missing configs: $missing")
                    println("  Invalid configs: $invalid")
                    println("  Warnings: $warnings")
                end
            end
        end
        println()
    end

    # Events in database
    if db_exists
        require_database(db_path) do db
            println("Events in Database:")
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
                println("  No events found")
            else
                for row in events
                    eid, name, reg_count = row
                    println("  - $eid : $name (registrations: $reg_count)")
                end
            end
        end
    end

    return 0
end
