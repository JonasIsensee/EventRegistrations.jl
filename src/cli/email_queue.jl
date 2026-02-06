# Email queue management commands

"""
List pending emails in the queue. Caller must open db; run_cli opens it before calling.
"""
function cmd_list_pending_emails(db::DuckDB.DB;
    event_id::Union{String,Nothing}=nothing,
    email_type::Union{String,Nothing}=nothing,
    verbose::Bool=false)
    # Use passed verbose flag if specified, otherwise use global setting
    show_verbose = verbose || is_verbose()
    
    pending = get_pending_emails(db; event_id=event_id, email_type=email_type)

    if isempty(pending)
        @info "No pending emails"
        return 0
    end

    @info "Pending emails: $(length(pending))"

    for email in pending
        details = [
            "  ID: $(email.id) | To: $(email.email_to)",
            "  Name: $(email.first_name) $(email.last_name) | Event: $(email.event_id)",
            "  Ref: $(email.reference_number) | Reason: $(email.reason) | Remaining: €$(email.remaining)",
        ]

        if show_verbose
            push!(details, "  Subject: $(email.subject)")
            push!(details, "  --- Email Body ---")
            append!(details, ["  │ $line" for line in split(email.body_text, '\n')])
            push!(details, "  --- End Body ---")
        end

        push!(details, "-" ^ 80)
        println(join(details, "\n"))
    end

    if !show_verbose
        @info "Use -v or --verbose to see email content"
    end

    return 0
end

"""
Mark pending email(s) as sent or discarded. Caller must open db; run_cli opens it before calling.
"""
function cmd_mark_email(db::DuckDB.DB, status::String;
    id::Union{Int,Nothing}=nothing,
    all::Bool=false,
    event_id::Union{String,Nothing}=nothing,
    email_type::Union{String,Nothing}=nothing)
    if !(status in ["sent", "discarded"])
        @error "Status must be 'sent' or 'discarded'"
        return 1
    end
    if !all && id === nothing
        @error """Must specify either <id> or --all flag

Usage:
eventreg mark-email $status <id>        # Mark single email
eventreg mark-email $status --all       # Mark all pending emails"""
        return 1
    end
    if all && id !== nothing
        @error "Cannot specify both <id> and --all flag"
        return 1
    end
    if all
        pending = get_pending_emails(db; event_id=event_id, email_type=email_type)
        if isempty(pending)
            @info "No pending emails to mark"
            return 0
        end

        marked_count = 0
        for email in pending
            mark_email!(db, email.id, status; processed_by="cli")
            marked_count += 1
        end

        @info "Marked $(marked_count) emails as $(status)"
        return 0
    else
        result = DBInterface.execute(db, """
            SELECT eq.email_to, eq.status, r.first_name, r.last_name, eq.email_type
            FROM email_queue eq
            JOIN registrations r ON r.id = eq.registration_id
            WHERE eq.id = ?
        """, [id])

        rows = collect(result)
        if isempty(rows)
            @error "Email queue entry not found" id=id
            return 1
        end

        email_to, current_status, first_name, last_name, queued_type = rows[1]
        if current_status != "pending"
            @error "Email is not pending" id=id current_status=current_status
            return 1
        end

        if email_type !== nothing && queued_type != email_type
            @error "Email type mismatch" id=id queued_type=queued_type expected=email_type
            return 1
        end

        mark_email!(db, id, status; processed_by="cli")

        @info "Marked email #$(id) as $(status): $(first_name) $(last_name)"
        return 0
    end
end

"""
Send pending emails. Caller must open db; run_cli opens it before calling.
"""
function cmd_send_emails(db::DuckDB.DB;
    event_id::Union{String,Nothing}=nothing,
    id::Union{Int,Nothing}=nothing,
    credentials_path::Union{Nothing,String}=nothing,
    db_path::String="events.duckdb")
    ctx = load_app_config(; db_path, credentials_path, dry_run=false)

    # Warn if email redirection is active
    if !isempty(ctx.email.redirect_to)
        @warn "EMAIL REDIRECTION ACTIVE" redirect_to=ctx.email.redirect_to
    end

    if id !== nothing
        @verbose_info "Sending email" id=id
        success = send_queued_email!(ctx.email, db, id)
        if success
            @info "Email sent: #$(id)"
        else
            @error "Failed to send email" id=id
            return 1
        end
    else
        pending = get_pending_emails(db; event_id)
        if isempty(pending)
            @info "No pending emails"
            return 0
        end

        @verbose_info "Sending pending emails" count=length(pending)
        sent_count = 0
        error_count = 0
        for email in pending
            @verbose_info "Sending to $(email.email_to)..."
            success = send_queued_email!(ctx.email, db, email.id)
            sent_count += success
            error_count += !success
        end

        if error_count > 0
            @warn "Email sending errors: sent=$(sent_count) errors=$(error_count)"
            return 1
        else
            @info "Sent $(sent_count) email(s)"
        end
    end

    return 0
end
