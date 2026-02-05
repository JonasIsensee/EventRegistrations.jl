# Comprehensive sync workflow

"""
Comprehensive sync command that does the full workflow.
Caller must open db; run_cli opens it before calling (or creates it for sync).
"""
function cmd_sync(db::DuckDB.DB;
    db_path::String="events.duckdb",
    events_dir::String="events",
    emails_dir::String="emails",
    bank_dir::String="bank_transfers",
    credentials_path::String="credentials.toml",
    event_id::Union{String,Nothing}=nothing,
    send_emails::Union{Bool,String}=false,
    export_details::Union{Bool,String}=false,
    export_payments::Union{Bool,String}=false,
    export_combined::Union{Bool,String}=false)
    
    # Step 1: Sync event configurations
    @verbose_info "[1/7] Syncing event configurations..." events_dir
    updated_events = sync_event_configs_to_db!(db, events_dir)
    if !isempty(updated_events) || is_verbose()
        @info "Synced configs" updated=length(updated_events)
    end

    ctx = load_app_config(; db_path, credentials_path,
                    templates_dir="templates",
                    dry_run=true)

    # Step 2: Download emails (if credentials exist)
    @verbose_info "[2/7] Checking for new emails..."
    if !isempty(ctx.email.pop3_server)
        result = download_emails!(ctx.email; emails_dir, verbose=false)
        if result.new_count > 0 || is_verbose()
            if result.error_count == 0
                @info "Downloaded emails" new=result.new_count
            else
                @warn "Downloaded with errors" new=result.new_count errors=result.error_count
            end
        end
    else
        @verbose_info "No POP3 credentials configured"
    end

    # Step 3: Process emails
    @verbose_info "[3/7] Processing emails..." emails_dir
    stats = process_email_folder!(db, emails_dir; events_dir)
    sync_event_configs_to_db!(db, events_dir)
    
    if stats.new_registrations > 0 || stats.updates > 0 || is_verbose()
        @info "Processed emails" new=stats.new_registrations updates=stats.updates
    end

    # Step 4: Recalculate costs for changed events and NULL costs
    @verbose_info "[4/7] Recalculating costs..."
    recalc_count = 0
    events = list_events(db)
    for event_row in events
        evt_id = event_row[1]
        evt_id in updated_events || continue
        cfg = Config.load_event_config(evt_id, events_dir)
        isnothing(cfg) && continue

        check = DBInterface.execute(db, """
            SELECT COUNT(*)
            FROM registrations r
            WHERE r.event_id = ? AND r.deleted_at IS NULL
                AND (r.computed_cost IS NULL OR r.cost_rules_hash IS NULL OR r.cost_rules_hash <> ?)
        """, [evt_id, cfg.config_hash])
        if collect(check)[1][1] > 0
            recalculate_costs!(db, evt_id; events_dir)
            recalc_count += 1
        end
    end
    if recalc_count > 0 || is_verbose()
        @info "Recalculated costs" events=recalc_count
    end


    # Step 5: Import bank transfers
    @verbose_info "[5/7] Importing bank transfers..." bank_dir
    import_count = 0
    if isdir(bank_dir)
        csv_files = filter(f -> endswith(lowercase(f), ".csv"), readdir(bank_dir))
        if !isempty(csv_files)
            for csv_file in csv_files
                full_path = joinpath(bank_dir, csv_file)
                result = import_bank_csv!(db, full_path; delimiter=';', decimal_comma=true)
                if result.new > 0
                    @verbose_info "Imported transfers" file=csv_file new=result.new
                    import_count += result.new
                end
            end
        end
    end
    if import_count > 0 || is_verbose()
        @info "Imported bank transfers" new=import_count
    end

    # Step 6: Match transfers
    @verbose_info "[6/7] Matching bank transfers..."
    if event_id !== nothing
        result = match_transfers!(db; event_id, email_cfg=ctx.email)
        if result.matched > 0 || is_verbose()
            @info "Matched transfers" matched=result.matched
        end
    else
        events = list_events(db)
        total_matched = 0
        for event_row in events
            evt_id = event_row[1]
            result = match_transfers!(db; event_id=evt_id, email_cfg=ctx.email)
            total_matched += result.matched
        end
        if total_matched > 0 || is_verbose()
            @info "Matched transfers" matched=total_matched
        end
    end

    # Step 7: Queue emails for review (pending for manual review/sending)
    @verbose_info "[7/7] Queuing emails..."

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
        @info "Queued emails" total=total_queued
    elseif is_verbose()
        @info "No new emails to queue"
    end

    # Show pending email counts only in verbose mode
    if is_verbose()
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
            @info join(lines, "\n")
        end
    end

    # Summary - show only if verbose or we have activity
    target_event = if event_id !== nothing
        event_id
    else
        get_most_recent_event(db)
    end

    if target_event !== nothing && is_verbose()
        overview = event_overview(db, target_event)
        if overview !== nothing
            summary = [
                "=== Event Overview: $(overview.event_id) ===",
                "  Registrations: $(overview.registrations)",
                "  Fully Paid: $(overview.fully_paid)",
                "  Unpaid: $(overview.unpaid)",
                "  Outstanding: €$(overview.outstanding)",
            ]
            @info join(summary, "\n")
        end
    end
    # Optional: Send emails (if requested)
    if send_emails !== false
        @verbose_info "Sending queued emails..."
        send_opts = parse_subcommand_options(send_emails)

        # Determine which emails to send
        target_event = get(send_opts, :event_id, nothing)
        ctx = load_app_config(; db_path, credentials_path, dry_run=false)


        # Send all pending (optionally filtered by event)
        pending = get_pending_emails(db; event_id=target_event)
        if isempty(pending)
            @verbose_info "No pending emails to send"
        else
            sent_count = 0
            error_count = 0
            for email in pending
                @verbose_info "Sending to $(email.email_to)..."
                success = send_queued_email!(ctx.email, db, email.id)
                sent_count += success
                error_count += !success
            end

            if error_count > 0
                @warn "Email sending errors" sent=sent_count errors=error_count
            else
                @info "Sent emails" sent=sent_count
            end
        end
    end

    # Optional: Export registration details
    if export_details !== false
        @verbose_info "Exporting registration details..."
        export_opts = parse_subcommand_options(export_details)
        upload = get(export_opts, :upload, false)

        # Determine target event
        target_event = get(export_opts, :event_id, event_id)
        target_event = @something target_event get_most_recent_event(db)

        if target_event === nothing
            @warn "No events found, skipping export"
        else
            # Get options with defaults
            export_format = get(export_opts, :format, "csv")
            output_file = get(export_opts, :output, "registration_details_$(target_event).csv")

            detail_table = get_registration_detail_table(db, target_event; events_dir)
            if isempty(detail_table.rows)
                @verbose_info "No registrations for event" event_id=target_event
            else
                if export_format == "csv"
                    export_registration_detail_csv(detail_table, output_file)
                    @info "Exported details" output=output_file

                    # Upload if requested
                    if upload
                        upload_export_to_webdav(ctx, output_file)
                    end
                elseif export_format == "terminal"
                    print_registration_detail_table(detail_table)
                else
                    @warn "Unsupported format" format=export_format
                end
            end
        end
    end

    # Optional: Export payment status (if requested)
    if export_payments !== false
        @verbose_info "Exporting payment status..."
        payment_opts = parse_subcommand_options(export_payments)
        upload = get(payment_opts, :upload, false)

        # Determine target event
        target_event = get(payment_opts, :event_id, event_id)
        target_event = @something target_event get_most_recent_event(db)

        if target_event === nothing
            @warn "No events found, skipping export"
        else
            # Get options with defaults
            export_format = get(payment_opts, :format, "csv")
            output_file = get(payment_opts, :output, "payment_status_$(target_event).csv")
            filter_type = get(payment_opts, :filter, "all")
            summary_only = get(payment_opts, :summary_only, false)

            # Build filter
            payment_filter = if filter_type == "unpaid"
                PaymentFilter(unpaid_only=true)
            elseif filter_type == "problems"
                PaymentFilter(problems_only=true)
            elseif filter_type == "paid"
                PaymentFilter(paid_only=true)
            elseif filter_type == "no-config"
                PaymentFilter(no_config_only=true)
            else
                PaymentFilter()  # all
            end

            table_data = get_payment_table_data(db, target_event)

            if table_data.total_registrations == 0
                @verbose_info "No registrations for event" event_id=target_event
            else
                if summary_only
                    print_summary(table_data)
                elseif export_format == "csv"
                    export_payment_csv(table_data, output_file; filter=payment_filter)
                    @info "Exported payments" output=output_file

                    # Upload if requested
                    if upload
                        upload_export_to_webdav(ctx, output_file)
                    end
                elseif export_format == "terminal"
                    print_payment_table(table_data; filter=payment_filter)
                elseif export_format == "pdf"
                    export_payment_pdf(table_data, output_file; filter=payment_filter)
                    @info "Exported PDF" output=output_file

                    # Upload if requested
                    if upload
                        upload_export_to_webdav(ctx, output_file)
                    end
                else
                    @warn "Unsupported format" format=export_format
                end
            end
        end
    end

    # Optional: Export combined workbook (if requested)
    if export_combined !== false
        @verbose_info "Exporting combined workbook..."
        combined_opts = parse_subcommand_options(export_combined)
        upload = get(combined_opts, :upload, false)

        # Determine target event
        target_event = get(combined_opts, :event_id, event_id)
        target_event = @something target_event get_most_recent_event(db)

        if target_event === nothing
            @warn "No events found, skipping export"
        else
            # Load event config to get export settings
            cfg = Config.load_event_config(target_event, events_dir)

            # Determine output path
            output_file = if haskey(combined_opts, :output)
                combined_opts[:output]
            elseif cfg !== nothing && cfg.export_combined_config !== nothing && cfg.export_combined_config.filename !== nothing
                cfg.export_combined_config.filename
            else
                "combined_export_$(target_event).xlsx"
            end

            result = export_combined_xlsx(db, target_event, output_file; events_dir)

            if result == 0
                @info "Exported workbook" output=output_file

                # Upload if requested
                if upload
                    upload_export_to_webdav(ctx, output_file)
                end
            else
                @warn "Export failed" exit_code=result
            end
        end
    end

    @info "Sync complete"
    return 0
end
