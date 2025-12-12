# Comprehensive sync workflow

"""
Comprehensive sync command that does the full workflow.
"""
function cmd_sync(;
    db_path::String="events.duckdb",
    config_dir::String="config",
    events_dir::String="events",
    emails_dir::String="emails",
    bank_dir::String="bank_transfers",
    credentials_path::Union{String,Nothing}=nothing,
    event_id::Union{String,Nothing}=nothing,
    nonstop::Bool=false)
    @info "=== EventRegistrations Sync ==="

    # Step 1: Initialize database if necessary
    db = if !isfile(db_path)
        @info "[1/9] Initializing database..." db_path=db_path
        init_project(db_path, config_dir)
    else
        @info "[1/9] Database exists" db_path=db_path
        init_database(db_path)
    end
    try
        @info "Syncing event configurations to database..." config_dir=config_dir
        sync_event_configs_to_db!(db, config_dir)
        @info "✓ Configuration synced successfully!"

        ctx = load_app_config(; config_dir, db_path, credentials_path,
                        templates_dir="templates",
                        dry_run=true)

        # Step 2: Download emails (if credentials exist)
        @info "[2/9] Checking for new emails..."
        if !isempty(ctx.email.pop3_server)
            result = download_emails!(ctx.email; emails_dir, verbose=false)
            if result.error_count == 0
                @info "Downloaded emails" new=result.new_count skipped=result.skipped_count
            else
                @warn "Downloaded with errors" new=result.new_count errors=result.error_count skipped=result.skipped_count
            end
        else
            @info "Skipping download (no credentials file found)"
        end

        # # Step 3: Process emails
        @info "[3/9] Processing emails..." emails_dir=emails_dir
        stats_ref = Ref{Any}(nothing)
        if isdir(emails_dir)
            stats = process_email_folder!(db, emails_dir; events_dir, prompt_for_new_events=false)
            stats_ref[] = stats
            @info "Email processing summary" processed=stats.processed new=stats.new_registrations updates=stats.updates
            if stats.no_cost_config > 0
                @warn "Registrations need cost configuration" count=stats.no_cost_config
            end
        else
            @info "No emails directory found" emails_dir=emails_dir
        end

        stats = stats_ref[]
        if stats !== nothing && stats.terminated
            @warn "Sync terminated by user to allow configuration edits."
            return 0
        end

        # Step 3.5: Auto-generate event configs for new events
        @info "[4/9] Checking for new events without configuration..."
        events_result = DBInterface.execute(db, """
            SELECT DISTINCT event_id FROM registrations
            ORDER BY event_id
        """)
        events_dir = "events"
        mkpath(events_dir)

        generated_count = 0
        for row in events_result
            evt_id = row[1]
            config_path = joinpath(events_dir, "$(evt_id).toml")

            if !isfile(config_path)
                @info "Generating config for new event" event_id=evt_id
                try
                    generate_event_config_template(evt_id, config_path; db=db)
                    @info "Created event config" path=config_path
                    generated_count += 1
                catch e
                    @error "Failed to generate config" event_id=evt_id error=e
                end
            end
        end

        if generated_count > 0
            @info "Generated event configs" count=generated_count note="Edit configs and re-run sync to apply cost rules"
        else
            @info "All events have configurations"
        end

        # Step 5: Check config sync and track which events changed
        @info "[5/9] Checking configuration sync..."
        unsynced = get_unsynced_configs(db, config_dir)
        if !isempty(unsynced)
            files = [file.path for file in unsynced]
            @warn "Config files need syncing" files=files
            @info "Running sync..."
            sync_event_configs_to_db!(db, config_dir)
            @info "✓ Configuration synced"
        else
            @info "✓ All configurations in sync"
        end

        # Step 6: Recalculate costs for changed events and NULL costs
        @info "[6/9] Recalculating costs..."
        recalculated = String[]

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
            @info "✓ All costs up to date"
        else
            @info "✓ Recalculated costs" events=recalculated
        end

        # Step 7: Import bank transfers
        @info "[7/9] Checking for bank transfers..." bank_dir=bank_dir
        if isdir(bank_dir)
            csv_files = filter(f -> endswith(lowercase(f), ".csv"), readdir(bank_dir))
            if !isempty(csv_files)
                @info "Found CSV files" count=length(csv_files)
                for csv_file in csv_files
                    full_path = joinpath(bank_dir, csv_file)
                    result = import_bank_csv!(db, full_path; delimiter=';', decimal_comma=true)
                    if result.new > 0
                        @info "Imported bank transfers" file=csv_file new=result.new
                    end
                end
            else
                @info "No CSV files found" bank_dir=bank_dir
            end
        else
            @info "No bank transfers directory" bank_dir=bank_dir
        end

        # Step 8: Match transfers
        @info "[8/9] Matching bank transfers..." event_id=event_id
        if event_id !== nothing
            result = match_transfers!(db; event_id=event_id)
            @info "Matching results" matched=result.matched unmatched=length(result.unmatched)
        else
            events = list_events(db)
            total_matched = 0
            for event_row in events
                evt_id = event_row[1]
                result = match_transfers!(db; event_id=evt_id)
                total_matched += result.matched
            end
            @info "Total matched across events" matched=total_matched
        end

        # Step 9: Queue emails for review (pending for manual review/sending)
        @info "[9/9] Queuing emails for pending registrations..."

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
            @info "Queued emails" total=total_queued registrations=total_registration_emails payments=total_payment_emails
        else
            @info "✓ No new emails to queue"
        end

        # Show pending email counts
        pending_counts = count_pending_emails(db)
        total_pending = sum(values(pending_counts); init=0)
        if total_pending > 0
            lines = ["📧 Pending emails: $total_pending"]
            for (evt_id, count) in pending_counts
                push!(lines, "  - $evt_id: $count")
            end
            push!(lines, "", "To manage pending emails:")
            push!(lines, "  eventreg list-pending-emails        # List all pending")
            push!(lines, "  eventreg list-pending-emails -v     # List with full content")
            push!(lines, "  eventreg send-emails                # Send all pending")
            push!(lines, "  eventreg mark-email sent <id>       # Mark as sent")
            push!(lines, "  eventreg mark-email discarded <id>  # Discard email")
            push!(lines, "  eventreg mark-email discarded --all  # Discard all pending emails")
            @info join(lines, "\n")
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
                summary = [
                    "=== Event Overview: $(overview.event_id) ===",
                    "  Registrations: $(overview.registrations)",
                    "  Fully Paid: $(overview.fully_paid)",
                    "  Partially Paid: $(overview.partially_paid)",
                    "  Unpaid: $(overview.unpaid)",
                    "  Expected: €$(overview.total_expected)",
                    "  Received: €$(overview.total_received)",
                    "  Subsidies: €$(overview.total_subsidies)",
                    "  Outstanding: €$(overview.outstanding)",
                ]
                @info join(summary, "\n")
            end
        end
        @info "=== Sync Complete ==="
    finally
        DBInterface.close!(db)
    end
    return 0
end
