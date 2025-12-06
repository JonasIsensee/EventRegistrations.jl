# =============================================================================
# CLI COMMAND FUNCTIONS
# =============================================================================
#
# This file contains CLI command handlers that are included directly into
# the EventRegistrations module. Submodule functions are accessed via qualified
# names (e.g., get_registration_table_data).

using Dates: Date, @dateformat_str

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
Process registration emails from a folder.
"""
function cmd_process_emails(email_folder::String="emails";
                            db_path::String="events.duckdb",
                            nonstop::Bool=false)
    if !isdir(email_folder)
        println("❌ Error: Email folder not found: $email_folder")
        return 1
    end

    return require_database(db_path) do db
        println("Processing emails from: $email_folder")
    stats = process_email_folder!(db, email_folder;
                      prompt_for_new_events=!nonstop)

        if stats.terminated
            println("\n⚠ Processing halted by user request to edit configuration.")
        else
            println("\n✓ Email processing complete!")
        end
        println("  Processed: $(stats.processed)")
        println("  Submissions: $(stats.submissions)")
        println("  New registrations: $(stats.new_registrations)")
        println("  Updates: $(stats.updates)")
        println("  Skipped: $(stats.skipped)")
        if stats.no_cost_config > 0
            println("  ⚠ Registrations without cost config: $(stats.no_cost_config)")
        end
        return 0
    end
end

"""
Download emails from POP3 server.
"""
function cmd_download_emails(;
    credentials_path::String="config/email_credentials.toml",
    emails_dir::String="emails",
    config_dir::String="config")

    # Check if credentials file exists, if not check alternative locations
    if !isfile(credentials_path)
        alternative_paths = [
            joinpath(config_dir, "credentials.toml"),
            "credentials.toml",
            "email_credentials.toml"
        ]

        found = false
        for alt_path in alternative_paths
            if isfile(alt_path)
                credentials_path = alt_path
                found = true
                break
            end
        end

        if !found
            println("❌ Error: Credentials file not found!")
            println("\nSearched locations:")
            println("  - config/email_credentials.toml")
            println("  - config/credentials.toml")
            println("  - credentials.toml")
            println("  - email_credentials.toml")
            println("\nCreate a credentials file with the following format:")
            println("""
            [email]
            server = "mail.example.com"
            username = "user@example.com"
            password = "yourpassword"
            port = 995  # optional, defaults to 995
            """)
            return 1
        end
    end

    println("Downloading emails from POP3 server...")
    println("  Credentials: $credentials_path")
    println("  Download to: $emails_dir")

    result = download_emails!(
        credentials_path=credentials_path,
        emails_dir=emails_dir,
        verbose=true
    )

    if result.error_count > 0
        println("\n⚠ Download completed with errors!")
        println("  New emails: $(result.new_count)")
        println("  Already downloaded: $(result.skipped_count)")
        println("  Errors: $(result.error_count)")
        println("  Total on server: $(result.total_on_server)")
        return 1
    else
        println("\n✓ Email download complete!")
        println("  New emails: $(result.new_count)")
        println("  Already downloaded: $(result.skipped_count)")
        println("  Total on server: $(result.total_on_server)")
        return 0
    end
end

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
        with_database(db_path) do db
            fields = generate_event_config_template(event_id, output_path;
                                                    event_name=name,
                                                    db=db,
                                                    config_dir=config_dir)
            if !isempty(fields)
                println("  Found $(length(fields)) fields from existing registrations")
                println("  Generated aliases and example cost rules for each field")
            end
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
Check if config files need syncing to database.
"""
function cmd_check_sync(;
    db_path::String="events.duckdb",
    config_dir::String="config")

    return require_database(db_path) do db
        statuses = Config.get_all_config_sync_status(db, config_dir)

        if isempty(statuses)
            println("No config files found in $config_dir")
            return 0
        end

        has_unsynced = false
        println("\nConfig Sync Status:")
        println("=" ^ 70)

        for status in statuses
            rel_path = replace(status.path, pwd() * "/" => "")
            if status.needs_sync
                has_unsynced = true
                if status.synced_at === nothing
                    println("  ⚠ $rel_path")
                    println("      Never synced")
                else
                    println("  ⚠ $rel_path")
                    println("      Modified since last sync ($(Dates.format(status.synced_at, "yyyy-mm-dd HH:MM")))")
                end
            else
                println("  ✓ $rel_path")
                println("      Synced: $(Dates.format(status.synced_at, "yyyy-mm-dd HH:MM"))")
            end
        end

        println()
        if has_unsynced
            println("⚠ Some config files need syncing!")
            println("Run: eventreg sync-config")
            return 1
        else
            println("✓ All config files are in sync.")
            return 0
        end
    end
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

        result = recalculate_costs!(db, event_id; strict=strict, dry_run=dry_run, verbose=verbose)

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

"""
List all events with statistics.
"""
function cmd_list_events(; db_path::String="events.duckdb")
    return require_database(db_path) do db
        events = list_events(db)

        if isempty(events)
            println("No events found in database.")
        else
            println("\nEvents:")
            println("-" ^ 80)
            for event in events
                event_id, event_name, reg_count, total_expected, paid_count = event
                println("  $event_id: $event_name")
                println("    Registrations: $reg_count")
                println("    Total expected: $(something(total_expected, 0)) €")
                println("    Payments received: $paid_count")
                println()
            end
        end
        return 0
    end
end

"""
List registrations with optional filtering.
Provides a quick view of registrations with payment status.
"""
function cmd_list_registrations(event_id::Union{String,Nothing}=nothing;
                                 db_path::String="events.duckdb",
                                 filter::String="all",
                                 name::Union{String,Nothing}=nothing,
                                 email::Union{String,Nothing}=nothing,
                                 since::Union{String,Nothing}=nothing)
    return require_database(db_path) do db
        # Default to most recent event if not specified
        local_event_id = event_id
        if local_event_id === nothing
            local_event_id = get_most_recent_event(db)
            if local_event_id === nothing
                println("❌ Error: No events with registrations found")
                return 1
            end
            println("Using most recent event: $local_event_id")
        end

        # Parse since date if provided
        since_date = if since !== nothing
            try
                Date(since, dateformat"yyyy-mm-dd")
            catch
                println("❌ Error: Invalid date format for --since. Use yyyy-mm-dd")
                return 1
            end
        else
            nothing
        end

        # Build filter from options
        reg_filter = RegistrationFilter(
            unpaid_only = filter == "unpaid",
            problems_only = filter == "problems",
            paid_only = filter == "paid",
            name_pattern = name,
            email_pattern = email,
            since = since_date
        )

        # Get registration data
        table_data = get_registration_table_data(db, local_event_id)

        if table_data.total_registrations == 0
            println("No registrations found for event: $local_event_id")
            return 0
        end

        # Print colored table
        print_registration_table(table_data; filter=reg_filter)
        return 0
    end
end

"""
Show detailed overview for an event.
"""
function cmd_event_overview(event_id::String; db_path::String="events.duckdb")
    return require_database(db_path) do db
        overview = event_overview(db, event_id)

        if overview === nothing
            println("❌ Event not found: $event_id")
            return 1
        end

        println("\nEvent: $(overview.event_name)")
        println("ID: $(overview.event_id)")
        println("-" ^ 80)
        println("  Total registrations: $(overview.registrations)")
        println("  Fully paid: $(overview.fully_paid)")
        println("  Partially paid: $(overview.partially_paid)")
        println("  Unpaid: $(overview.unpaid)")
        println()
        println("  Total expected: $(overview.total_expected) €")
        println("  Total received (payments): $(overview.total_received) €")
        println("  Total subsidies: $(overview.total_subsidies) €")
        println("  Total credits: $(overview.total_credits) €")
        println("  Outstanding: $(overview.outstanding) €")
        return 0
    end
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
            template_files = filter(f -> endswith(f, ".txt"), readdir(templates_dir))
            println("  Templates: $(length(template_files)) files in $templates_dir")
        else
            println("  Templates directory: ❌ Not found")
        end
    else
        println("  Status: ❌ Not found (run 'eventreg init' to create)")
    end
    println()

    # Events in database
    if db_exists
        require_database(db_path) do db
            println("Events in Database:")
            result = DBInterface.execute(db, """
                SELECT
                    e.event_id,
                    e.event_name,
                    COUNT(r.id) as reg_count,
                    e.base_cost,
                    CASE WHEN e.cost_rules IS NOT NULL THEN '✓' ELSE '❌' END as has_rules
                FROM events e
                LEFT JOIN registrations r ON r.event_id = e.event_id
                GROUP BY e.event_id, e.event_name, e.base_cost, e.cost_rules
                ORDER BY e.event_id
            """)

            events = collect(result)
            if isempty(events)
                println("  No events found")
            else
                println("-" ^ 80)
                for event in events
                    event_id, event_name, reg_count, base_cost, has_rules = event
                    println("  $event_id: $event_name")
                    println("    Registrations: $reg_count")
                    println("    Base cost: $(something(base_cost, 0)) €")
                    println("    Cost rules: $has_rules")
                    println()
                end
            end
        end
    end

    return 0
end

# =============================================================================
# VALIDATION AND DATABASE MANAGEMENT COMMANDS
# =============================================================================

"""
Validate event cost configuration against actual registration data.
"""
function cmd_validate_config(event_id::Union{String,Nothing}=nothing;
                             db_path::String="events.duckdb",
                             config_dir::String="config",
                             strict::Bool=false,
                             verbose::Bool=false)
    return require_database(db_path) do db
        println("Validating configuration...")
        println()

        # Load field aliases first
        load_field_aliases(config_dir)

        # Get events to validate
        if event_id !== nothing
            event_ids = [event_id]
        else
            result = DBInterface.execute(db, "SELECT event_id FROM events")
            event_ids = [row[1] for row in collect(result)]
        end

        if isempty(event_ids)
            println("No events found to validate.")
            return 0
        end

        all_valid = true
        total_warnings = 0

        for eid in event_ids
            println("Validating event: $eid")
            println("-" ^ 60)

            # Get cost rules
            rules = get_cost_rules(db, eid)
            if rules === nothing
                println("  ⚠ No cost configuration found")
                println()
                continue
            end

            # Validate using the Validation module
            validation_result = validate_cost_config(rules, eid, db; strict=strict)

            if !validation_result.valid
                all_valid = false
            end
            total_warnings += length(validation_result.warnings)

            # Print results
            println(format_validation_result(validation_result; verbose=verbose))
            println()
        end

        # Summary
        println("=" ^ 60)
        if all_valid && total_warnings == 0
            println("✅ All configurations valid!")
        elseif all_valid
            println("✅ Configurations valid with $total_warnings warning(s)")
        else
            println("❌ Configuration validation failed")
            return 1
        end

        return 0
    end
end

"""
Verify database integrity.
"""
function cmd_verify_database(; db_path::String="events.duckdb", verbose::Bool=false)
    println("Verifying database: $db_path")
    println()

    result = verify_database(db_path)

    # Print detailed results
    r = result.results

    println("Checks:")
    println("  File exists:      $(r["file_exists"] ? "✓" : "❌")")
    println("  File readable:    $(r["file_readable"] ? "✓" : "❌")")
    println("  Connection OK:    $(r["connection_ok"] ? "✓" : "❌")")
    println("  Tables exist:     $(r["tables_exist"] ? "✓" : "❌")")
    println("  Integrity OK:     $(r["integrity_ok"] ? "✓" : "❌")")
    println()

    if !isempty(r["errors"])
        println("❌ Errors:")
        for err in r["errors"]
            println("  • $err")
        end
        println()
    end

    if !isempty(r["warnings"])
        println("⚠️  Warnings:")
        for warn in r["warnings"]
            println("  • $warn")
        end
        println()
    end

    if result.valid
        println("✅ Database verification passed")
    else
        println("❌ Database verification failed")
        return 1
    end

    return 0
end

"""
Comprehensive sync command that does the full workflow.
"""
function cmd_sync(;
    db_path::String="events.duckdb",
    config_dir::String="config",
    emails_dir::String="emails",
    bank_dir::String="bank_transfers",
    credentials_path::String="config/email_credentials.toml",
    event_id::Union{String,Nothing}=nothing,
    nonstop::Bool=false)
    println("=== EventRegistrations Sync ===\n")


    # Step 1: Initialize database if necessary
    db = if !isfile(db_path)
        println("[1/9] Initializing database...")
        init_project(db_path, config_dir)
    else
        println("[1/9] Database exists: $db_path")
        init_database(db_path)
    end
    try
        println("Syncing event configurations to database...")
        sync_event_configs_to_db!(db, config_dir)
        println("\n✓ Configuration synced successfully!")

        # Step 2: Download emails (if credentials exist)
        println("\n[2/9] Checking for new emails...")
        if isfile(credentials_path) || isfile("credentials.toml") || isfile("config/credentials.toml")
            result = download_emails!(; credentials_path, emails_dir, verbose=false)
            if result.error_count == 0
                println("  Downloaded: $(result.new_count) new, $(result.skipped_count) already local")
            else
                println("  ⚠ Downloaded with errors: $(result.new_count) new, $(result.error_count) errors")
            end
        else
            println("  Skipping (no credentials file found)")
        end

        # # Step 3: Process emails
        println("\n[3/9] Processing emails...")
        stats_ref = Ref{Any}(nothing)
        if isdir(emails_dir)
            stats = process_email_folder!(db, emails_dir;
                                          config_dir=config_dir,
                                          prompt_for_new_events=!nonstop)
            stats_ref[] = stats
            println("  Processed: $(stats.processed), New: $(stats.new_registrations), Updates: $(stats.updates)")
            if stats.no_cost_config > 0
                println("  ⚠ $(stats.no_cost_config) registrations need cost configuration")
            end
        else
            println("  No emails directory found")
        end

        stats = stats_ref[]
        if stats !== nothing && stats.terminated
            println("\nSync terminated by user to allow configuration edits.")
            return 0
        end

        # Step 3.5: Auto-generate event configs for new events
        println("\n[4/9] Checking for new events without configuration...")
        # Get all events from registrations
        events_result = DBInterface.execute(db, """
            SELECT DISTINCT event_id FROM registrations
            ORDER BY event_id
        """)
        events_dir_path = joinpath(config_dir, "events")
        mkpath(events_dir_path)

        generated_count = 0
        for row in events_result
            evt_id = row[1]
            config_path = joinpath(events_dir_path, "$(evt_id).toml")

            if !isfile(config_path)
                println("  • Generating config for new event: $evt_id")
                try
                    generate_event_config_template(evt_id, config_path; db=db, config_dir=config_dir)
                    println("    ✓ Created: $config_path")
                    generated_count += 1
                catch e
                    println("    ✗ Failed to generate config: $e")
                end
            end
        end

        if generated_count > 0
            println("  ✓ Generated $(generated_count) event config(s)")
            println("  → Edit the config files and re-run sync to apply cost rules")
        else
            println("  ✓ All events have configurations")
        end

        # Step 5: Check config sync and track which events changed
        println("\n[5/9] Checking configuration sync...")
        unsynced = get_unsynced_configs(db, config_dir)
        if !isempty(unsynced)
            println("  ⚠ $(length(unsynced)) config files need syncing:")
            for file in unsynced
                println("    - $(file.path)")
            end
            println("  Running sync...")
            sync_event_configs_to_db!(db, config_dir)
            println("  ✓ Configuration synced")
        else
            println("  ✓ All configurations in sync")
        end

        # Step 6: Recalculate costs for changed events and NULL costs
        println("\n[6/9] Recalculating costs...")
        recalculated = String[]

        # Then check for other events with NULL costs but existing config
        events = list_events(db)
        for event_row in events
            evt_id = event_row[1]

            # Check if event has registrations without costs but has config
            check = DBInterface.execute(db, """
                SELECT COUNT(*)
                FROM registrations r
                JOIN events e ON e.event_id = r.event_id
                WHERE r.event_id = ? AND e.cost_rules IS NOT NULL
            """, [evt_id]) # AND r.computed_cost IS NULL

            recalculate_costs!(db, evt_id)
            push!(recalculated, evt_id)
        end

        if isempty(recalculated)
            println("  ✓ All costs up to date")
        else
            println("  ✓ Recalculated costs for $(length(recalculated)) event(s)")
        end
        # Step 7: Import bank transfers
        println("\n[7/9] Checking for bank transfers...")
        if isdir(bank_dir)
            csv_files = filter(f -> endswith(lowercase(f), ".csv"), readdir(bank_dir))
            if !isempty(csv_files)
                println("  Found $(length(csv_files)) CSV files")
                for csv_file in csv_files
                    full_path = joinpath(bank_dir, csv_file)
                    result = import_bank_csv!(db, full_path; delimiter=';', decimal_comma=true)
                    if result.new > 0
                        println("    $csv_file: $(result.new) new transfers")
                    end
                end
            else
                println("  No CSV files found in $bank_dir")
            end
        else
            println("  No bank transfers directory ($bank_dir)")
        end

        # Step 8: Match transfers
        println("\n[8/9] Matching bank transfers...")
        if event_id !== nothing
            result = match_transfers!(db; event_id=event_id)
            println("  Matched: $(result.matched), Unmatched: $(length(result.unmatched))")
        else
            # Match for all events
            events = list_events(db)
            total_matched = 0
            for event_row in events
                evt_id = event_row[1]
                result = match_transfers!(db; event_id=evt_id)
                total_matched += result.matched
            end
            println("  Total matched: $total_matched")
        end

        # Step 9: Queue emails for review (pending for manual review/sending)
        println("\n[9/9] Queuing emails for pending registrations...")
        target_events = [row[1] for row in list_events(db)]

        total_queued = 0
        for evt_id in target_events
            queued = queue_pending_emails!(db, evt_id; template_name="confirmation_email")
            total_queued += queued
        end

        if total_queued > 0
            println("  ✓ Queued $total_queued email(s)")
        else
            println("  ✓ No new emails to queue")
        end

        # Show pending email counts
        pending_counts = count_pending_emails(db)
        total_pending = sum(values(pending_counts); init=0)
        if total_pending > 0
            println("\n  📧 Pending emails: $total_pending")
            for (evt_id, count) in pending_counts
                println("    - $evt_id: $count")
            end
            println("\n  To manage pending emails:")
            println("    eventreg list-pending-emails        # List all pending")
            println("    eventreg list-pending-emails -v     # List with full content")
            println("    eventreg send-emails                # Send all pending")
            println("    eventreg mark-email <id> sent       # Mark as sent")
            println("    eventreg mark-email <id> discarded  # Discard email")
        end

        # Summary
        target_event = if event_id !== nothing
            event_id
        else
            get_most_recent_event(db)
        end

        if target_event !== nothing
            overview = event_overview(db, target_event)
            if overview !== nothing
                println("\n=== Event Overview: $(overview.event_id) ===")
                println("  Registrations: $(overview.registrations)")
                println("  Fully Paid: $(overview.fully_paid)")
                println("  Partially Paid: $(overview.partially_paid)")
                println("  Unpaid: $(overview.unpaid)")
                println("  Expected: €$(overview.total_expected)")
                println("  Received: €$(overview.total_received)")
                println("  Subsidies: €$(overview.total_subsidies)")
                println("  Outstanding: €$(overview.outstanding)")
            end
        end
        println("\n=== Sync Complete ===\n")
    finally
        DBInterface.close!(db)
    end
    return 0
end

"""
Import bank transfer CSV file.
"""
function cmd_import_bank_csv(csv_file::String;
    db_path::String="events.duckdb",
    delimiter::String=";",
    decimal_comma::Bool=true)

    if !isfile(csv_file)
        println("❌ Error: CSV file not found: $csv_file")
        return 1
    end

    return require_database(db_path) do db
        println("Importing bank transfers from: $csv_file")
        result = import_bank_csv!(db, csv_file; delimiter=first(delimiter), decimal_comma=decimal_comma)

        println("\n✓ Bank transfer import complete!")
        println("  New transfers: $(result.new)")
        println("  Skipped (duplicates): $(result.skipped)")
        return 0
    end
end

"""
Match bank transfers to registrations.
"""
function cmd_match_transfers(;
    event_id::Union{String,Nothing}=nothing,
    db_path::String="events.duckdb")

    return require_database(db_path) do db
        println("Matching bank transfers to registrations...")
        result = match_transfers!(db; event_id=event_id)

        println("\n✓ Matching complete!")
        println("  Matched: $(result.matched)")
        println("  Unmatched: $(length(result.unmatched))")

        if !isempty(result.unmatched)
            println("\nTo manually match unmatched transfers:")
            println("  eventreg list-unmatched")
            println("  eventreg manual-match <transfer_id> <reference>")
        end
        return 0
    end
end

"""
List unmatched bank transfers.
"""
function cmd_list_unmatched(; db_path::String="events.duckdb")
    return require_database(db_path) do db
        unmatched = get_unmatched_transfers(db)

        if isempty(unmatched)
            println("✓ No unmatched transfers!")
        else
            println("\nUnmatched Transfers:")
            println("-" ^ 80)
            for transfer in unmatched
                id, date, amount, sender, reference = transfer
                println("  ID: $id")
                println("  Date: $date")
                println("  Amount: $amount €")
                println("  Sender: $sender")
                println("  Reference: $reference")
                println()
            end
        end
        return 0
    end
end

"""
Manually match a transfer to a registration.
"""
function cmd_manual_match(transfer_id::Int, reference::String;
    db_path::String="events.duckdb")

    return require_database(db_path) do db
        println("Matching transfer $transfer_id to registration $reference...")
        manual_match!(db, transfer_id, reference)

        println("✓ Match created successfully!")
        return 0
    end
end

"""
Grant a subsidy to a registration.
"""
function cmd_grant_subsidy(identifier::String, amount::Float64;
    reason::String="",
    granted_by::String="cli",
    db_path::String="events.duckdb")

    return require_database(db_path) do db
        println("Granting subsidy of $amount € to $identifier...")
        grant_subsidy!(db, identifier, amount; reason=reason, granted_by=granted_by)

        println("✓ Subsidy granted successfully!")
        return 0
    end
end

"""
Export payment status report with pretty colored output.

Options:
  --format=<fmt>     Output format: terminal (default), pdf, latex, csv
  --filter=<filter>  Filter: all (default), unpaid, problems, paid, no-config
"""
function cmd_export_payment_status(event_id::Union{String,Nothing}=nothing,
                                     output_pos::Union{String,Nothing}=nothing;
                                     db_path::String="events.duckdb",
                                     format::String="terminal",
                                     filter::String="all",
                                     summary_only::Bool=false,
                                     output::Union{String,Nothing}=nothing)

    # Allow output to be passed as positional or keyword argument
    actual_output = output_pos !== nothing ? output_pos : output

    return require_database(db_path) do db
        # Default to most recent event if not specified
        local_event_id = event_id
        if local_event_id === nothing
            local_event_id = get_most_recent_event(db)
            if local_event_id === nothing
                println("❌ Error: No events with registrations found")
                return 1
            end
            println("Using most recent event: $local_event_id")
        end

        # Build filter from option
        payment_filter = if filter == "unpaid"
            PaymentFilter(unpaid_only=true)
        elseif filter == "problems"
            PaymentFilter(problems_only=true)
        elseif filter == "paid"
            PaymentFilter(paid_only=true)
        elseif filter == "no-config"
            PaymentFilter(no_config_only=true)
        else
            PaymentFilter()  # all
        end

        # Get payment data from database
        table_data = get_payment_table_data(db, local_event_id)

        if table_data.total_registrations == 0
            println("No registrations found for event: $local_event_id")
            return 0
        end

        # Handle summary-only mode
        if summary_only
            # Print title
            title_str = "Payment Status: $(table_data.event_id)"
            if table_data.event_name !== nothing
                title_str *= " - $(table_data.event_name)"
            end
            println()
            println(title_str)
            println("=" ^ length(title_str))
            println()
            print_summary(table_data)
            return 0
        end

        # Determine output format and destination
        output_format = format
        if actual_output !== nothing && output_format == "terminal"
            # Infer format from file extension
            ext = lowercase(splitext(actual_output)[2])
            if ext == ".pdf"
                output_format = "pdf"
            elseif ext == ".tex"
                output_format = "latex"
            elseif ext == ".csv"
                output_format = "csv"
            end
        end

        if output_format == "terminal" || (actual_output === nothing && output_format == "terminal")
            # Print colored table to terminal (filter applied inside)
            print_payment_table(table_data; filter=payment_filter)
        elseif output_format == "pdf"
            output_path = actual_output === nothing ? "payment_status_$(local_event_id).pdf" : actual_output
            println("Generating PDF: $output_path...")
            export_payment_pdf(table_data, output_path; filter=payment_filter)
            println("✓ PDF exported to: $output_path")
        elseif output_format == "latex"
            output_path = actual_output === nothing ? "payment_status_$(local_event_id).tex" : actual_output
            println("Generating LaTeX: $output_path...")
            # Export LaTeX uses table data and generates string
            latex_content = generate_latex_document(table_data; filter=payment_filter)
            open(output_path, "w") do f
                write(f, latex_content)
            end
            println("✓ LaTeX exported to: $output_path")
        elseif output_format == "csv"
            output_path = actual_output === nothing ? "payment_status_$(local_event_id).csv" : actual_output
            println("Exporting CSV: $output_path...")
            export_payment_csv(table_data, output_path; filter=payment_filter)
            println("✓ CSV exported to: $output_path")
        else
            println("❌ Error: Unknown format: $output_format")
            println("Supported formats: terminal, pdf, latex, csv")
            return 1
        end
        return 0
    end
end

"""
Export full registration data.
"""
function cmd_export_registrations(event_id::Union{String,Nothing}=nothing,
                                   output_pos::Union{String,Nothing}=nothing;
                                   db_path::String="events.duckdb",
                                   format::String="terminal",
                                   filter::String="all",
                                   output::Union{String,Nothing}=nothing)

    # Allow output to be passed as positional or keyword argument
    actual_output = output_pos !== nothing ? output_pos : output

    return require_database(db_path) do db
        # Default to most recent event if not specified
        local_event_id = event_id
        if local_event_id === nothing
            local_event_id = get_most_recent_event(db)
            if local_event_id === nothing
                println("❌ Error: No events with registrations found")
                return 1
            end
            println("Using most recent event: $local_event_id")
        end

        # Build filter from option
        reg_filter = if filter == "unpaid"
            RegistrationFilter(unpaid_only=true)
        elseif filter == "problems"
            RegistrationFilter(problems_only=true)
        elseif filter == "paid"
            RegistrationFilter(paid_only=true)
        else
            RegistrationFilter()  # all
        end

        # Get registration data from database
        table_data = get_registration_table_data(db, local_event_id)

        if table_data.total_registrations == 0
            println("No registrations found for event: $local_event_id")
            return 0
        end

        # Determine output format and destination
        output_format = format
        if actual_output !== nothing && output_format == "terminal"
            # Infer format from file extension
            ext = lowercase(splitext(actual_output)[2])
            if ext == ".pdf"
                output_format = "pdf"
            elseif ext == ".tex"
                output_format = "latex"
            elseif ext == ".csv"
                output_format = "csv"
            end
        end

        if output_format == "terminal" || (actual_output === nothing && output_format == "terminal")
            # Print colored table to terminal
            print_registration_table(table_data; filter=reg_filter)
        elseif output_format == "pdf"
            output_path = actual_output === nothing ? "registrations_$(local_event_id).pdf" : actual_output
            println("Generating PDF: $output_path...")
            export_registration_pdf(table_data, output_path; filter=reg_filter)
            println("✓ PDF exported to: $output_path")
        elseif output_format == "latex"
            output_path = actual_output === nothing ? "registrations_$(local_event_id).tex" : actual_output
            println("Generating LaTeX: $output_path...")
            latex_content = generate_registration_latex_document(table_data; filter=reg_filter)
            open(output_path, "w") do f
                write(f, latex_content)
            end
            println("✓ LaTeX exported to: $output_path")
        elseif output_format == "csv"
            output_path = actual_output === nothing ? "registrations_$(local_event_id).csv" : actual_output
            println("Exporting CSV: $output_path...")
            export_registration_csv(table_data, output_path; filter=reg_filter)
            println("✓ CSV exported to: $output_path")
        else
            println("❌ Error: Unknown format: $output_format")
            println("Supported formats: terminal, pdf, latex, csv")
            return 1
        end
        return 0
    end
end

"""
Export confirmation emails to text files.
Useful when SMTP is not available for sending emails directly.
"""
function cmd_export_emails(event_id::Union{String,Nothing}=nothing,
                           output_dir::String="emails_export";
                           db_path::String="events.duckdb",
                           template::String="confirmation_email")

    return require_database(db_path) do db
        # Default to most recent event if not specified
        local_event_id = event_id
        if local_event_id === nothing
            local_event_id = get_most_recent_event(db)
            if local_event_id === nothing
                println("❌ Error: No events with registrations found")
                return 1
            end
            println("Using most recent event: $local_event_id")
        end

        println("Exporting emails for $local_event_id to $output_dir...")
        count = export_emails_to_files(db, local_event_id, output_dir; template_name=template)

        println("✓ Exported $count email files to: $output_dir")
        return 0
    end
end

# =============================================================================
# EMAIL QUEUE MANAGEMENT COMMANDS
# =============================================================================

"""
List pending emails in the queue.
With -v/--verbose flag, shows full email content.
"""
function cmd_list_pending_emails(;
    db_path::String="events.duckdb",
    event_id::Union{String,Nothing}=nothing,
    verbose::Bool=false)

    return require_database(db_path) do db
        pending = get_pending_emails(db; event_id=event_id)

        if isempty(pending)
            println("✓ No pending emails in queue.")
            return 0
        end

        println("\n📧 Pending Emails ($(length(pending))):")
        println("=" ^ 80)

        for email in pending
            println("\n  ID: $(email.id)")
            println("  To: $(email.email_to)")
            println("  Name: $(email.first_name) $(email.last_name)")
            println("  Event: $(email.event_id)")
            println("  Reference: $(email.reference_number)")
            println("  Reason: $(email.reason)")
            println("  Remaining: €$(email.remaining)")
            println("  Queued: $(email.queued_at)")

            if verbose
                println("\n  Subject: $(email.subject)")
                println("\n  --- Email Body ---")
                # Indent the body for readability
                for line in split(email.body_text, '\n')
                    println("  │ $line")
                end
                println("  --- End Body ---")
            end
            println("-" ^ 80)
        end

        println("\nCommands:")
        println("  eventreg send-emails                 # Send all pending")
        println("  eventreg send-emails --id=<id>       # Send specific email")
        println("  eventreg mark-email <id> sent        # Mark as sent (without sending)")
        println("  eventreg mark-email <id> discarded   # Discard email")

        return 0
    end
end

"""
Mark a pending email as sent or discarded.
"""
function cmd_mark_email(queue_id::Int, status::String;
    db_path::String="events.duckdb")

    if !(status in ["sent", "discarded"])
        println("❌ Error: Status must be 'sent' or 'discarded'")
        return 1
    end

    return require_database(db_path) do db
        # Verify email exists and is pending
        result = DBInterface.execute(db, """
            SELECT eq.email_to, eq.status, r.first_name, r.last_name
            FROM email_queue eq
            JOIN registrations r ON r.id = eq.registration_id
            WHERE eq.id = ?
        """, [queue_id])

        rows = collect(result)
        if isempty(rows)
            println("❌ Error: Email queue entry not found: $queue_id")
            return 1
        end

        email_to, current_status, first_name, last_name = rows[1]
        if current_status != "pending"
            println("❌ Error: Email is not pending (current status: $current_status)")
            return 1
        end

        mark_email!(db, queue_id, status; processed_by="cli")

        action = status == "sent" ? "marked as sent" : "discarded"
        println("✓ Email to $first_name $last_name <$email_to> $action")
        return 0
    end
end

"""
Send pending emails (all or by ID).
"""
function cmd_send_emails(;
    db_path::String="events.duckdb",
    event_id::Union{String,Nothing}=nothing,
    id::Union{Int,Nothing}=nothing,
    credentials_path::String="config/email_credentials.toml")

    return require_database(db_path) do db
        # Load email configuration
        cred_paths = [credentials_path, "credentials.toml", "config/credentials.toml"]
        cred_found = findfirst(isfile, cred_paths)

        if cred_found === nothing
            println("❌ Error: No email credentials found!")
            println("Create a credentials file with SMTP settings.")
            return 1
        end

        actual_cred_path = cred_paths[cred_found]
        println("Loading email configuration from: $actual_cred_path")
        success = load_email_config_from_file!(actual_cred_path; dry_run=false)

        if !success
            println("❌ Error: Failed to load email configuration")
            return 1
        end

        if id !== nothing
            # Send specific email
            println("Sending email ID $id...")
            success = send_queued_email!(db, id)
            if success
                println("✓ Email sent successfully!")
            else
                println("❌ Failed to send email")
                return 1
            end
        else
            # Send all pending
            pending = get_pending_emails(db; event_id=event_id)
            if isempty(pending)
                println("✓ No pending emails to send.")
                return 0
            end

            println("Sending $(length(pending)) pending email(s)...")
            result = send_all_pending_emails!(db; event_id=event_id)

            println("\n✓ Email sending complete!")
            println("  Sent: $(result.sent)")
            if result.errors > 0
                println("  ⚠ Errors: $(result.errors)")
                return 1
            end
        end

        return 0
    end
end

# =============================================================================
# MAIN CLI ENTRY POINT
# =============================================================================

const HELP_TEXT = """
EventRegistrations CLI - Event registration management system

USAGE:
  eventreg <command> [arguments] [options]

COMMANDS:
  init                           Initialize new project
  sync                           Full sync workflow (download, process, match, queue emails)
  process-emails [folder]        Process registration emails
  generate-field-config          Generate field configuration
  create-event-config <id>       Create event config template
  sync-config                    Sync config files to database
  check-sync                     Check if config files need syncing
  recalculate-costs <event-id>   Recalculate costs after config changes
  list-events                    List all events
  list-registrations [event-id]  List registrations with filters
  event-overview <event-id>      Show event details
  status                         Show system status and configuration

VALIDATION & MAINTENANCE:
  validate-config [event-id]     Validate cost rules against actual data
  verify-database                Check database integrity
  backup                         Create timestamped database backup

PAYMENTS:
  import-bank-csv <file>         Import bank transfers
  match-transfers                Match transfers to registrations
  list-unmatched                 List unmatched transfers
  manual-match <id> <ref>        Manually match a transfer
  grant-subsidy <id> <amount>    Grant subsidy to registration

EMAIL MANAGEMENT:
  list-pending-emails            List emails waiting to be sent
    --verbose, -v                Show full email content
    --event-id=<id>              Filter by event
  mark-email <id> <status>       Mark email as 'sent' or 'discarded'
  send-emails                    Send all pending emails via SMTP
    --id=<id>                    Send specific email by ID
    --event-id=<id>              Send only emails for specific event

EXPORTS:
  export-payment-status [event-id] [output]  Payment status with color highlighting
    --format=<fmt>               Output: terminal, pdf, latex, csv
    --filter=<filter>            Filter: all, unpaid, problems, paid, no-config
    --summary-only               Show only totals, not individual rows
  export-registrations [event-id] [output]   Export/print registration data
    --format=<fmt>               Output: terminal, pdf, latex, csv
    --filter=<filter>            Filter: all, unpaid, problems, paid
  list-registrations [event-id]  Quick registration listing with filters
    --filter=<filter>            Filter: all, unpaid, problems, paid
    --name=<pattern>             Filter by name (regex pattern)
    --email=<pattern>            Filter by email (regex pattern)
    --since=<date>               Only registrations since date (yyyy-mm-dd)
  export-emails [event-id] [output-dir]      Export confirmation emails to files

COMMON OPTIONS:
  --db-path=<path>              Database file (default: events.duckdb)
  --config-dir=<path>           Config directory (default: config)
  --verbose                     Show detailed output
  --strict                      Fail on warnings (for validate-config, recalculate-costs)
  --dry-run                     Preview changes without applying (for recalculate-costs)
  --check-sync                  Warn if config files need syncing
  --nonstop                     Disable interactive prompts (auto-continue)

EXAMPLES:
  eventreg init
  eventreg sync                                            # full workflow
  eventreg process-emails emails/
  eventreg status
  eventreg check-sync                                      # check config sync status
  eventreg validate-config PWE_2026_01 --verbose
  eventreg recalculate-costs PWE_2026_01 --dry-run --check-sync
  eventreg backup
  eventreg import-bank-csv bank_transfers/january.csv
  eventreg match-transfers --event-id=PWE_2026_01
  eventreg list-registrations --filter=unpaid              # list unpaid registrations
  eventreg list-registrations --name="Müller"              # filter by name
  eventreg list-registrations --since=2025-01-01           # registrations since date
  eventreg list-pending-emails                             # list pending emails
  eventreg list-pending-emails -v                          # with full content
  eventreg send-emails                                     # send all pending
  eventreg mark-email 42 discarded                         # discard email
  eventreg export-payment-status                           # colored terminal output
  eventreg export-payment-status --filter=unpaid           # show only unpaid
  eventreg export-payment-status --summary-only            # show only totals
  eventreg export-payment-status PWE_2026_01 report.pdf    # export to PDF
  eventreg export-registrations report.pdf                 # export registrations to PDF
  eventreg export-payment-status --format=latex            # generate LaTeX

Run 'eventreg <command> --help' for more information on a command.
"""

"""
Main CLI dispatcher function.
"""
function run_cli(args::Vector{String})
    if isempty(args) || args[1] in ["--help", "-h", "help"]
        println(HELP_TEXT)
        return 0
    end

    command = args[1]
    cmd_args = args[2:end]

    # Parse arguments
    positional = String[]
    options = Dict{Symbol, Any}()

    for arg in cmd_args
        if startswith(arg, "--")
            if contains(arg, "=")
                key, val = split(arg[3:end], "=", limit=2)
                options[Symbol(replace(key, "-" => "_"))] = string(val)
            else
                # Boolean flag
                options[Symbol(replace(arg[3:end], "-" => "_"))] = true
            end
        elseif startswith(arg, "-") && length(arg) == 2
            # Short flags (e.g., -v for verbose)
            flag = arg[2]
            if flag == 'v'
                options[:verbose] = true
            elseif flag == 'n'
                options[:dry_run] = true
            else
                push!(positional, arg)
            end
        else
            push!(positional, arg)
        end
    end

    # Dispatch to command
    try
        if command == "init"
            return cmd_init(; options...)
        elseif command == "process-emails"
            email_folder = isempty(positional) ? "emails" : positional[1]
            return cmd_process_emails(email_folder; options...)
        elseif command == "download-emails"
            return cmd_download_emails(; options...)
        elseif command == "generate-field-config"
            return cmd_generate_field_config(; options...)
        elseif command == "create-event-config"
            if isempty(positional)
                println("❌ Error: event-id required")
                return 1
            end
            return cmd_create_event_config(positional[1]; options...)
        elseif command == "sync-config"
            return cmd_sync_config(; options...)
        elseif command == "check-sync"
            return cmd_check_sync(; options...)
        elseif command == "recalculate-costs"
            if isempty(positional)
                println("❌ Error: event-id required")
                return 1
            end
            return cmd_recalculate_costs(positional[1]; options...)
        elseif command == "list-events"
            return cmd_list_events(; options...)
        elseif command == "list-registrations"
            event_id = length(positional) >= 1 ? positional[1] : nothing
            return cmd_list_registrations(event_id; options...)
        elseif command == "event-overview"
            if isempty(positional)
                println("❌ Error: event-id required")
                return 1
            end
            return cmd_event_overview(positional[1]; options...)
        elseif command == "status"
            return cmd_status(; options...)
        elseif command == "import-bank-csv"
            if isempty(positional)
                println("❌ Error: csv-file required")
                return 1
            end
            return cmd_import_bank_csv(positional[1]; options...)
        elseif command == "match-transfers"
            return cmd_match_transfers(; options...)
        elseif command == "list-unmatched"
            return cmd_list_unmatched(; options...)
        elseif command == "manual-match"
            if length(positional) < 2
                println("❌ Error: transfer-id and reference required")
                return 1
            end
            transfer_id = parse(Int, positional[1])
            return cmd_manual_match(transfer_id, positional[2]; options...)
        elseif command == "grant-subsidy"
            if length(positional) < 2
                println("❌ Error: identifier and amount required")
                return 1
            end
            amount = parse(Float64, positional[2])
            return cmd_grant_subsidy(positional[1], amount; options...)
        elseif command == "export-payment-status"
            event_id = length(positional) >= 1 ? positional[1] : nothing
            output = length(positional) >= 2 ? positional[2] : nothing
            return cmd_export_payment_status(event_id, output; options...)
        elseif command == "export-registrations"
            event_id = length(positional) >= 1 ? positional[1] : nothing
            output = length(positional) >= 2 ? positional[2] : nothing
            return cmd_export_registrations(event_id, output; options...)
        elseif command == "export-emails"
            event_id = length(positional) >= 1 ? positional[1] : nothing
            output_dir = length(positional) >= 2 ? positional[2] : "emails_export"
            return cmd_export_emails(event_id, output_dir; options...)
        # Email queue management commands
        elseif command == "list-pending-emails"
            return cmd_list_pending_emails(; options...)
        elseif command == "mark-email"
            if length(positional) < 2
                println("❌ Error: queue-id and status required")
                println("Usage: eventreg mark-email <id> <sent|discarded>")
                return 1
            end
            queue_id = parse(Int, positional[1])
            return cmd_mark_email(queue_id, positional[2]; options...)
        elseif command == "send-emails"
            # Check if --id was provided
            id_val = get(options, :id, nothing)
            if id_val !== nothing
                options[:id] = parse(Int, id_val)
            end
            return cmd_send_emails(; options...)
        # Validation and maintenance commands
        elseif command == "validate-config"
            event_id = length(positional) >= 1 ? positional[1] : nothing
            return cmd_validate_config(event_id; options...)
        elseif command == "sync"
            return cmd_sync(; options...)
        else
            println("❌ Error: Unknown command: $command")
            println("\nRun 'eventreg --help' for usage information.")
            return 1
        end
    catch e
        println("❌ Error: $e")
        if isa(e, InterruptException)
            return 130
        end
        # Print stack trace for debugging
        for (exc, bt) in Base.catch_stack()
            showerror(stdout, exc, bt)
            println()
        end
        return 1
    end
end
