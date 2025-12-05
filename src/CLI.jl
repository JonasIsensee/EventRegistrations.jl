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

    println("\n✓ Project initialized successfully!")
    println("\nNext steps:")
    println("  1. Place .eml files in an 'emails' directory")
    println("  2. Run: eventreg process-emails")
    println("  3. Run: eventreg generate-field-config")
    fields_path = joinpath(config_dir, "fields.toml")
    println("  4. Edit $fields_path")
    println("  5. Create event config: eventreg create-event-config <EVENT_ID>")
    return 0
end

"""
Process registration emails from a folder.
"""
function cmd_process_emails(email_folder::String="emails"; db_path::String="events.duckdb")
    if !isdir(email_folder)
        println("❌ Error: Email folder not found: $email_folder")
        return 1
    end

    return with_database(db_path) do db
        println("Processing emails from: $email_folder")
        stats = process_email_folder!(db, email_folder)

        println("\n✓ Email processing complete!")
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
Generate field configuration from existing data.
"""
function cmd_generate_field_config(;
    db_path::String="events.duckdb",
    config_dir::String="config",
    output::String=joinpath("config", "fields.toml"))

    return with_database(db_path) do db
        println("Generating field configuration...")
        generate_field_config(db, output)

        println("\n✓ Field configuration generated: $output")
        println("\nPlease edit the file to customize field aliases.")
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
            # Also load any global aliases as fallback
            load_field_aliases(config_dir)

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

    if !isfile(db_path)
        println("❌ Database not found: $db_path")
        println("Run 'eventreg init' first.")
        return 1
    end

    return with_database(db_path) do db
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
1. Global field aliases from config/fields.toml (if present)
2. Event-specific aliases from config/events/{event_id}.toml [aliases] sections
3. Cost rules from event config files
"""
function cmd_sync_config(;
    db_path::String="events.duckdb",
    config_dir::String="config",
    no_backup::Bool=false)

    # Create backup before sync
    if !no_backup && isfile(db_path)
        println("Creating backup before sync...")
        backup_path = backup_database(db_path; suffix="before-sync")
        if backup_path !== nothing
            println("  Backup: $backup_path")
        end
    end

    return with_database(db_path) do db
        # Load global field aliases (if present, for backward compatibility)
        fields_path = joinpath(config_dir, "fields.toml")
        if isfile(fields_path)
            println("Loading global field aliases from: $fields_path")
            load_field_aliases(config_dir)
        end

        println("Syncing event configurations to database...")
        println("  (Event-specific aliases from [aliases] sections take precedence)")
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
    return with_database(db_path) do db
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
    return with_database(db_path) do db
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
    return with_database(db_path) do db
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
    return with_database(db_path) do db
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
    if isfile(db_path)
        println("  Status: ✓ Exists")
        println("  Size: $(round(stat(db_path).size / 1024 / 1024, digits=2)) MB")

        # Connect to get stats - use with_database for safety
        with_database(db_path) do db
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
        println("  Status: ❌ Not found (run 'eventreg init' to create)")
    end
    println()

    # Configuration
    println("Configuration:")
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
    if isfile(db_path)
        println("Events in Database:")
        with_database(db_path) do db
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
    return with_database(db_path) do db
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
    dry_run_emails="true",
    event_id::Union{String,Nothing}=nothing)
    dry_run_emails = parse(Bool, dry_run_emails)
    println("=== EventRegistrations Sync ===\n")

    # Step 1: Initialize database if necessary
    if !isfile(db_path)
        println("[1/10] Initializing database...")
        db = init_project(db_path, config_dir)
        DBInterface.close!(db)
    else
        println("[1/10] Database exists: $db_path")
    end

    # Step 2: Download emails (if credentials exist)
    println("\n[2/10] Checking for new emails...")
    if isfile(credentials_path) || isfile("credentials.toml") || isfile("config/credentials.toml")
        result = download_emails!(
            credentials_path=credentials_path,
            emails_dir=emails_dir,
            verbose=false
        )
        if result.error_count == 0
            println("  Downloaded: $(result.new_count) new, $(result.skipped_count) already local")
        else
            println("  ⚠ Downloaded with errors: $(result.new_count) new, $(result.error_count) errors")
        end
    else
        println("  Skipping (no credentials file found)")
    end

    # Step 3: Process emails
    println("\n[3/10] Processing emails...")
    with_database(db_path) do db
        if isdir(emails_dir)
            stats = process_email_folder!(db, emails_dir)
            println("  Processed: $(stats.processed), New: $(stats.new_registrations), Updates: $(stats.updates)")
            if stats.no_cost_config > 0
                println("  ⚠ $(stats.no_cost_config) registrations need cost configuration")
            end
        else
            println("  No emails directory found")
        end
    end

    # Step 4: Check config sync
    println("\n[4/10] Checking configuration sync...")
    with_database(db_path) do db
        unsynced = get_unsynced_configs(db, config_dir)
        if !isempty(unsynced)
            println("  ⚠ $(length(unsynced)) config files need syncing:")
            for file in unsynced
                println("    - $file")
            end
            println("  Running sync...")
            sync_event_configs_to_db!(db, config_dir)
            println("  ✓ Configuration synced")
        else
            println("  ✓ All configurations in sync")
        end
    end

    # Step 5-6: Recalculate costs if needed
    println("\n[5/10] Checking cost calculations...")
    with_database(db_path) do db
        # Get events
        events = list_events(db)
        needs_recalc = false

        for event_row in events
            evt_id = event_row[1]

            # Check if event has registrations without costs but has config
            check = DBInterface.execute(db, """
                SELECT COUNT(*)
                FROM registrations r
                JOIN events e ON e.event_id = r.event_id
                WHERE r.event_id = ? AND r.computed_cost IS NULL AND e.cost_rules IS NOT NULL
            """, [evt_id])
            count = first(collect(check))[1]

            if count > 0
                println("  Recalculating costs for $evt_id ($count registrations)...")
                recalculate_costs!(db, evt_id)
                needs_recalc = true
            end
        end

        if !needs_recalc
            println("  ✓ All costs up to date")
        end
    end

    # Step 7: Import bank transfers
    println("\n[6/10] Checking for bank transfers...")
    if isdir(bank_dir)
        csv_files = filter(f -> endswith(lowercase(f), ".csv"), readdir(bank_dir))
        if !isempty(csv_files)
            println("  Found $(length(csv_files)) CSV files")
            with_database(db_path) do db
                for csv_file in csv_files
                    full_path = joinpath(bank_dir, csv_file)
                    result = import_bank_csv!(db, full_path; delimiter=';', decimal_comma=true)
                    if result.new > 0
                        println("    $csv_file: $(result.new) new transfers")
                    end
                end
            end
        else
            println("  No CSV files found in $bank_dir")
        end
    else
        println("  No bank transfers directory ($bank_dir)")
    end

    # Step 8: Match transfers
    println("\n[7/10] Matching bank transfers...")
    with_database(db_path) do db
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
    end

    # Step 9: Load email configuration
    println("\n[8/10] Loading email configuration...")
    if isfile(credentials_path)
        success = load_email_config_from_file!(credentials_path; dry_run=dry_run_emails)
        if success
            println("  ✓ Email configuration loaded (dry_run=$(dry_run_emails))")
        else
            println("  ⚠ Failed to load email configuration")
        end
    else
        println("  No email credentials found - emails will be skipped")
    end

    # Step 10: Send/resend emails
    println("\n[9/10] Checking for emails to send...")
    with_database(db_path) do db
        target_events = if event_id !== nothing
            [event_id]
        else
            [row[1] for row in list_events(db)]
        end

        total_sent = 0
        for evt_id in target_events
            # Check for changed balances
            result = resend_changed_balances!(db, evt_id; template_name="payment_reminder", dry_run=dry_run_emails)
            total_sent += result.sent
        end

        if total_sent > 0
            println("  $(dry_run_emails ? "Would send" : "Sent") $total_sent emails")
        else
            println("  ✓ No emails need to be sent")
        end
    end

    # Step 11: Summary
    println("\n[10/10] Generating summary...")
    with_database(db_path) do db
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
    end

    println("\n=== Sync Complete ===\n")
    return 0
end

"""
Create a backup of the database.
"""
function cmd_backup(; db_path::String="events.duckdb", suffix::String="manual")
    println("Creating backup of database: $db_path")

    backup_path = backup_database(db_path; suffix=suffix)

    if backup_path !== nothing
        println("✓ Backup created: $backup_path")
        return 0
    else
        println("❌ Failed to create backup")
        return 1
    end
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

    return with_database(db_path) do db
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

    return with_database(db_path) do db
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
    return with_database(db_path) do db
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

    return with_database(db_path) do db
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

    return with_database(db_path) do db
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

    return with_database(db_path) do db
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

    return with_database(db_path) do db
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

    return with_database(db_path) do db
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
# MAIN CLI ENTRY POINT
# =============================================================================

const HELP_TEXT = """
EventRegistrations CLI - Event registration management system

USAGE:
  eventreg <command> [arguments] [options]

COMMANDS:
  init                           Initialize new project
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

EXAMPLES:
  eventreg init
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
                # Convert to appropriate type and ensure it's a String, not SubString
                options[Symbol(replace(key, "-" => "_"))] = String(val)
            else
                # Boolean flag
                options[Symbol(replace(arg[3:end], "-" => "_"))] = true
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
        # Validation and maintenance commands
        elseif command == "validate-config"
            event_id = length(positional) >= 1 ? positional[1] : nothing
            return cmd_validate_config(event_id; options...)
        elseif command == "verify-database"
            return cmd_verify_database(; options...)
        elseif command == "sync"
            return cmd_sync(; options...)
        elseif command == "backup"
            return cmd_backup(; options...)
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
