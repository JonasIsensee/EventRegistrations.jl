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
    @info "Syncing event configurations to database..." events_dir
        updated_events = sync_event_configs_to_db!(db, events_dir)

        ctx = load_app_config(; db_path, credentials_path,
                        templates_dir="templates",
                        dry_run=true)

        # Step 2: Download emails (if credentials exist)
        @info "[2/7] Checking for new emails..."
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

        # Step 3: Process emails
        @info "[3/7] Processing emails..." emails_dir=emails_dir
        process_email_folder!(db, emails_dir; events_dir)
        sync_event_configs_to_db!(db, events_dir)

        # Step 4: Recalculate costs for changed events and NULL costs
        @info "[4/7] Recalculating costs..."

        events = list_events(db)
        for event_row in events
            evt_id = event_row[1]
            evt_id in updated_events || continue
            cfg = Config.load_event_config(evt_id, events_dir)
            isnothing(cfg) && continue

            check = DBInterface.execute(db, """
                SELECT COUNT(*)
                FROM registrations r
                WHERE r.event_id = ?
                    AND (r.computed_cost IS NULL OR r.cost_rules_hash IS NULL OR r.cost_rules_hash <> ?)
            """, [evt_id, cfg.config_hash])
            if collect(check)[1][1] > 0
                recalculate_costs!(db, evt_id; events_dir)
            end
        end


        # Step 5: Import bank transfers
        @info "[5/7] Checking for bank transfers..." bank_dir=bank_dir
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

        # Step 6: Match transfers
        @info "[6/7] Matching bank transfers..." event_id=event_id
        if event_id !== nothing
            result = match_transfers!(db; event_id, email_cfg=ctx.email)
            @info "Matching results" matched=result.matched unmatched=length(result.unmatched)
        else
            events = list_events(db)
            total_matched = 0
            for event_row in events
                evt_id = event_row[1]
                result = match_transfers!(db; event_id=evt_id, email_cfg=ctx.email)
                total_matched += result.matched
            end
            @info "Total matched across events" matched=total_matched
        end

        # Step 7: Queue emails for review (pending for manual review/sending)
        @info "[7/7] Queuing emails for pending registrations..."

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
        # Optional: Send emails (if requested)
        if send_emails !== false
            @info "Sending queued emails..."
            send_opts = parse_subcommand_options(send_emails)

            # Determine which emails to send
            target_event = get(send_opts, :event_id, nothing)
            ctx = load_app_config(; db_path, credentials_path, dry_run=false)


            # Send all pending (optionally filtered by event)
            pending = get_pending_emails(db; event_id=target_event)
            if isempty(pending)
                @info "✓ No pending emails to send."
            else
                @info "Sending pending emails" count=length(pending) event_id=target_event
                sent_count = 0
                error_count = 0
                for email in pending
                    @info "  Sending to $(email.email_to) ($(email.first_name) $(email.last_name))..."
                    success = send_queued_email!(ctx.email, db, email.id)
                    sent_count += success
                    error_count += !success
                end

                if error_count > 0
                    @warn "Email sending complete with errors" sent=sent_count errors=error_count
                else
                    @info "✓ All emails sent successfully" sent=sent_count
                end
            end
        end

        # Optional: Export registration details
        if export_details !== false
            @info "Exporting registration details..."
            export_opts = parse_subcommand_options(export_details)
            upload = get(export_opts, :upload, false)

            # Determine target event
            target_event = get(export_opts, :event_id, event_id)
            target_event = @something target_event get_most_recent_event(db)

            if target_event === nothing
                @warn "No events with registrations found, skipping export"
            else
                # Get options with defaults
                export_format = get(export_opts, :format, "csv")
                output_file = get(export_opts, :output, "registration_details_$(target_event).csv")

                detail_table = get_registration_detail_table(db, target_event; events_dir)
                if isempty(detail_table.rows)
                    @info "No registrations found for event" event_id=target_event
                else
                    if export_format == "csv"
                        export_registration_detail_csv(detail_table, output_file)
                        @info "✓ Registration details exported" output_path=output_file rows=length(detail_table.rows)

                        # Upload if requested
                        if upload
                            upload_export_to_webdav(ctx, output_file)
                        end
                    elseif export_format == "terminal"
                        print_registration_detail_table(detail_table)
                    else
                        @warn "Unsupported format for details export" format=export_format supported=["csv", "terminal"]
                    end
                end
            end
        end

        # Optional: Export payment status (if requested)
        if export_payments !== false
            @info "Exporting payment status..."
            payment_opts = parse_subcommand_options(export_payments)
            upload = get(payment_opts, :upload, false)

            # Determine target event
            target_event = get(payment_opts, :event_id, event_id)
            target_event = @something target_event get_most_recent_event(db)

            if target_event === nothing
                @warn "No events with registrations found, skipping export"
            else
                # Get options with defaults
                export_format = get(payment_opts, :format, "csv")
                output_file = get(payment_opts, :output, "payment_status_$(target_event).csv")
                filter_type = get(payment_opts, :filter, "all")
                summary_only = get(payment_opts, :summary_only, false)

                @info "Exporting payment status" event_id=target_event format=export_format output=output_file filter=filter_type

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
                    @info "No registrations found for event" event_id=target_event
                else
                    if summary_only
                        print_summary(table_data)
                    elseif export_format == "csv"
                        export_payment_csv(table_data, output_file; filter=payment_filter)
                        @info "✓ Payment status exported" output_path=output_file

                        # Upload if requested
                        if upload
                            upload_export_to_webdav(ctx, output_file)
                        end
                    elseif export_format == "terminal"
                        print_payment_table(table_data; filter=payment_filter)
                    elseif export_format == "pdf"
                        export_payment_pdf(table_data, output_file; filter=payment_filter)
                        @info "✓ Payment status PDF exported" output_path=output_file

                        # Upload if requested
                        if upload
                            upload_export_to_webdav(ctx, output_file)
                        end
                    else
                        @warn "Unsupported format for payment export" format=export_format supported=["csv", "terminal", "pdf"]
                    end
                end
            end
        end

        # Optional: Export combined workbook (if requested)
        if export_combined !== false
            @info "Exporting combined workbook..."
            combined_opts = parse_subcommand_options(export_combined)
            upload = get(combined_opts, :upload, false)

            # Determine target event
            target_event = get(combined_opts, :event_id, event_id)
            target_event = @something target_event get_most_recent_event(db)

            if target_event === nothing
                @warn "No events with registrations found, skipping export"
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

                @info "Exporting combined workbook" event_id=target_event output_path=output_file

                result = export_combined_xlsx(db, target_event, output_file; events_dir)

                if result == 0
                    @info "✓ Combined workbook exported" output_path=output_file

                    # Upload if requested
                    if upload
                        upload_export_to_webdav(ctx, output_file)
                    end
                else
                    @warn "Combined export failed" exit_code=result
                end
            end
        end

        @info "=== Sync Complete ==="
    return 0
end
