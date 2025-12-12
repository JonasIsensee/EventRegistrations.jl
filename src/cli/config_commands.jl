# Configuration-related CLI commands

"""
Create a new event configuration template.

Creates a UNIFIED config file containing both:
- Field aliases (maps short names to actual form field names)
- Cost rules (uses the defined aliases for consistency)
"""
function cmd_create_event_config(event_id::String;
    name::String=event_id,
    config_dir::String="config",
    db_path::String="events.duckdb")

    output_path = joinpath(config_dir, "events", "$event_id.toml")

    # Ensure events directory exists
    mkpath(joinpath(config_dir, "events"))

    println("Creating unified event configuration (aliases + cost rules)...")

    # Try to use database for smart template generation
    if isfile(db_path)
        db = init_database(db_path)
        try
            fields = generate_event_config_template(event_id, output_path;
                                                    event_name=name,
                                                    db=db,
                                                    config_dir=config_dir)
            if !isempty(fields)
                println("  Found $(length(fields)) fields from existing registrations")
                println("  Generated aliases and example cost rules for each field")
            end
        finally
            DBInterface.close!(db)
        end
    else
        # Fallback to generic template
        generate_event_config_template(event_id, output_path; event_name=name, config_dir=config_dir)
    end

    println("\n✓ Event configuration created: $output_path")
    println("\nThe file contains:")
    println("  [aliases] - Field name mappings (edit short names as desired)")
    println("  [costs]   - Cost rules using the defined aliases")
    println("\nNext steps:")
    println("  1. Edit the aliases in [aliases] section (optional)")
    println("  2. Add/uncomment cost rules in [costs] section")
    println("  3. Run: eventreg sync-config")
    println("  4. Run: eventreg recalculate-costs $event_id")

    return 0
end

"""
Sync configuration files to database.
Creates a backup before making changes.

This loads:
1. Event-specific aliases from config/events/{event_id}.toml [aliases] sections
2. Cost rules from event config files
"""
function cmd_sync_config(;
    db_path::String="events.duckdb",
    config_dir::String="config",
    )

    return require_database(db_path) do db
        println("Syncing event configurations to database...")
        sync_event_configs_to_db!(db, config_dir)

        println("\n✓ Configuration synced successfully!")
        return 0
    end
end

"""
Recalculate costs for all registrations in an event.
"""
function cmd_recalculate_costs(event_id::String;
                               db_path::String="events.duckdb",
                               config_dir::String="config",
                               strict::Bool=false,
                               dry_run::Bool=false,
                               verbose::Bool=false,
                               check_sync::Bool=false)
    return require_database(db_path) do db
        # Check for unsynced configs if requested
        if check_sync
            unsynced = Config.get_unsynced_configs(db, config_dir)
            if !isempty(unsynced)
                println("⚠ Warning: The following config files have been modified but not synced:")
                for status in unsynced
                    rel_path = replace(status.path, pwd() * "/" => "")
                    println("    • $rel_path")
                end
                println()
                println("You may be using stale configuration!")
                println("Run 'eventreg sync-config' first, or remove --check-sync to proceed anyway.")
                return 1
            end
        end

        println("Recalculating costs for $event_id...")

        if dry_run
            println("(DRY RUN - no changes will be applied)")
        end

        result = recalculate_costs!(db, event_id; config_dir=config_dir,
                         strict=strict, dry_run=dry_run, verbose=verbose)

        if result.success
            if dry_run
                println("✓ Would update $(result.would_update) registration(s)")
            else
                println("✓ Updated $(result.updated) registration(s)")
            end
            if result.warnings > 0
                println("⚠ $(result.warnings) warning(s) - review output above")
            end
        end
        return 0
    end
end
