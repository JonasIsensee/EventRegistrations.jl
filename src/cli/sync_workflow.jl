# Comprehensive sync workflow

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
            cfg = Config.load_event_config(evt_id, config_dir)
            if cfg === nothing
                continue
            end

            check = DBInterface.execute(db, """
                SELECT COUNT(*)
                FROM registrations r
                WHERE r.event_id = ?
                  AND (r.computed_cost IS NULL OR r.cost_rules_hash IS NULL OR r.cost_rules_hash <> ?)
            """, [evt_id, cfg.config_hash])
            if collect(check)[1][1] > 0
                recalculate_costs!(db, evt_id; config_dir=config_dir)
                push!(recalculated, evt_id)
            end
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

        ctx = load_app_config(; config_dir=config_dir, db_path=db_path,
                               credentials_path=credentials_path,
                               templates_dir=joinpath(config_dir, "templates"),
                               dry_run=true)
        println("  ✓ Loaded email configuration (dry-run)")

        target_events = [row[1] for row in list_events(db)]

        total_registration_emails = 0
        total_payment_emails = 0
        for evt_id in target_events
            result = queue_pending_emails!(ctx.email, db, evt_id)
            total_registration_emails += result.registration_emails
            total_payment_emails += result.payment_emails
        end

        total_queued = total_registration_emails + total_payment_emails
        if total_queued > 0
            println("  ✓ Queued $total_queued email(s)")
            if total_registration_emails > 0
                println("    - Registration confirmations (no payment): $total_registration_emails")
            end
            if total_payment_emails > 0
                println("    - Payment requests: $total_payment_emails")
            end
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
            println("    eventreg mark-email sent <id>       # Mark as sent")
            println("    eventreg mark-email discarded <id>  # Discard email")
            println("    eventreg mark-email discarded --all  # Discard all pending emails")
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
