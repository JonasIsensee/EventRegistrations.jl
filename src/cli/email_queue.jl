# Email queue management commands

"""
List pending emails in the queue.
With -v/--verbose flag, shows full email content.
"""
function cmd_list_pending_emails(;
    db_path::String="events.duckdb",
    event_id::Union{String,Nothing}=nothing,
    email_type::Union{String,Nothing}=nothing,
    verbose::Bool=false)
    require_database(db_path) do db
        pending = get_pending_emails(db; event_id=event_id, email_type=email_type)

        if isempty(pending)
            @info "✓ No pending emails in queue."
            return 0
        end

        @info """📧 Pending Emails ($(length(pending))):
$("=" ^ 80)"""

        for email in pending
            details = [
                "  ID: $(email.id)",
                "  To: $(email.email_to)",
                "  Name: $(email.first_name) $(email.last_name)",
                "  Event: $(email.event_id)",
                "  Reference: $(email.reference_number)",
                "  Reason: $(email.reason)",
                "  Remaining: €$(email.remaining)",
                "  Queued: $(email.queued_at)",
            ]

            if verbose
                push!(details, "  Subject: $(email.subject)")
                push!(details, "  --- Email Body ---")
                append!(details, ["  │ $line" for line in split(email.body_text, '\n')])
                push!(details, "  --- End Body ---")
            end

            push!(details, "-" ^ 80)
            @info join(details, "\n")
        end

        @info """Commands:
eventreg send-emails                 # Send all pending
eventreg send-emails --id=<id>       # Send specific email
eventreg mark-email sent <id>        # Mark as sent (without sending)
eventreg mark-email discarded <id>   # Discard single email
eventreg mark-email discarded --all  # Discard all pending emails"""

        return 0
    end
end

"""
Mark pending email(s) as sent or discarded.

Usage:
  eventreg mark-email sent <id>        # Mark single email as sent
  eventreg mark-email discarded <id>   # Discard single email
  eventreg mark-email sent --all       # Mark all pending as sent
  eventreg mark-email discarded --all  # Discard all pending
  eventreg mark-email discarded --all --event-id=<id>  # Discard for specific event
"""
function cmd_mark_email(status::String;
    db_path::String="events.duckdb",
    id::Union{Int,Nothing}=nothing,
    all::Bool=false,
    event_id::Union{String,Nothing}=nothing,
    email_type::Union{String,Nothing}=nothing)

    if !(status in ["sent", "discarded"])
        @error "Status must be 'sent' or 'discarded'"
        return 1
    end

    # Must specify either --all or an ID
    if !all && id === nothing
        @error """Must specify either <id> or --all flag

Usage:
eventreg mark-email $status <id>        # Mark single email
eventreg mark-email $status --all       # Mark all pending emails
eventreg mark-email $status --all --event-id=<id>  # For specific event
eventreg mark-email $status --all --type=<template> # Filter by email type"""
        return 1
    end

    if all && id !== nothing
        @error "Cannot specify both <id> and --all flag"
        return 1
    end

    return require_database(db_path) do db
        if all
            # Bulk operation
            pending = get_pending_emails(db; event_id=event_id, email_type=email_type)
            if isempty(pending)
                @info "✓ No pending emails to mark as $status."
                return 0
            end

            event_msg = event_id !== nothing ? " for event $event_id" : ""
            action = status == "sent" ? "mark as sent" : "discard"
            type_msg = email_type !== nothing ? " of type $email_type" : ""
            @warn "⚠ About to $action $(length(pending)) pending email(s)$event_msg$type_msg"

            marked_count = 0
            for email in pending
                mark_email!(db, email.id, status; processed_by="cli")
                marked_count += 1
            end

            action_past = status == "sent" ? "marked as sent" : "discarded"
            @info "✓ $marked_count email(s) $action_past"
            return 0
        else
            # Single email operation
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

            action = status == "sent" ? "marked as sent" : "discarded"
            @info "✓ Email to $first_name $last_name <$email_to> $action"
            return 0
        end
    end
end

"""
Send pending emails (all or by ID).
"""
function cmd_send_emails(;
    db_path::String="events.duckdb",
    event_id::Union{String,Nothing}=nothing,
    id::Union{Int,Nothing}=nothing,
    credentials_path::Union{Nothing,String}=nothing)

    ctx = load_app_config(; config_dir="config", db_path,
                            credentials_path,
                            templates_dir=joinpath("config", "templates"),
                            dry_run=false)
    require_database(db_path) do db

        if id !== nothing
            # Send specific email
            @info "Sending email" id=id
            success = send_queued_email!(ctx.email, db, id)
            if success
                @info "✓ Email sent successfully" id=id
            else
                @error "Failed to send email" id=id
                return 1
            end
        else
            # Send all pending
            pending = get_pending_emails(db; event_id)
            if isempty(pending)
                @info "✓ No pending emails to send."
                return 0
            end

            @info "Sending pending emails" count=length(pending) event_id=event_id
            sent_count = 0
            error_count = 0
            for email in pending
                @info "  Sending to $(email.email_to) ($(email.first_name) $(email.last_name))..."
                success = send_queued_email!(ctx.email, db, email.id)
                sent_count += success
                error_count += !success
            end

            summary = [
                "✓ Email sending complete!",
                "Sent: $(sent_count)",
            ]

            if error_count > 0
                push!(summary, "⚠ Errors: $(error_count)")
                @warn join(summary, "\n")
                return 1
            end

            @info join(summary, "\n")
        end

        return 0
    end
end
