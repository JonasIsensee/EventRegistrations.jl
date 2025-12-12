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

    return require_database(db_path) do db
        pending = get_pending_emails(db; event_id=event_id, email_type=email_type)

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
        println("  eventreg mark-email sent <id>        # Mark as sent (without sending)")
        println("  eventreg mark-email discarded <id>   # Discard single email")
        println("  eventreg mark-email discarded --all  # Discard all pending emails")

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
        println("❌ Error: Status must be 'sent' or 'discarded'")
        return 1
    end

    # Must specify either --all or an ID
    if !all && id === nothing
        println("❌ Error: Must specify either <id> or --all flag")
        println("\nUsage:")
        println("  eventreg mark-email $status <id>        # Mark single email")
        println("  eventreg mark-email $status --all       # Mark all pending emails")
        println("  eventreg mark-email $status --all --event-id=<id>  # For specific event")
        println("  eventreg mark-email $status --all --type=<template> # Filter by email type")
        return 1
    end

    if all && id !== nothing
        println("❌ Error: Cannot specify both <id> and --all flag")
        return 1
    end

    return require_database(db_path) do db
        if all
            # Bulk operation
            pending = get_pending_emails(db; event_id=event_id, email_type=email_type)
            if isempty(pending)
                println("✓ No pending emails to mark as $status.")
                return 0
            end

            event_msg = event_id !== nothing ? " for event $event_id" : ""
            action = status == "sent" ? "mark as sent" : "discard"
            type_msg = email_type !== nothing ? " of type $email_type" : ""
            println("⚠ About to $action $(length(pending)) pending email(s)$event_msg$type_msg")

            marked_count = 0
            for email in pending
                mark_email!(db, email.id, status; processed_by="cli")
                marked_count += 1
            end

            action_past = status == "sent" ? "marked as sent" : "discarded"
            println("✓ $marked_count email(s) $action_past")
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
                println("❌ Error: Email queue entry not found: $id")
                return 1
            end

            email_to, current_status, first_name, last_name, queued_type = rows[1]
            if current_status != "pending"
                println("❌ Error: Email is not pending (current status: $current_status)")
                return 1
            end

            if email_type !== nothing && queued_type != email_type
                println("❌ Error: Email type mismatch (queued as $queued_type)")
                return 1
            end

            mark_email!(db, id, status; processed_by="cli")

            action = status == "sent" ? "marked as sent" : "discarded"
            println("✓ Email to $first_name $last_name <$email_to> $action")
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
    credentials_path::String="config/email_credentials.toml")

    return require_database(db_path) do db
        ctx = load_app_config(; config_dir="config", db_path=db_path,
                               credentials_path=credentials_path,
                               templates_dir=joinpath("config", "templates"),
                               dry_run=false)

        if id !== nothing
            # Send specific email
            println("Sending email ID $id...")
            success = send_queued_email!(ctx.email, db, id)
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
            result = send_all_pending_emails!(ctx.email, db; event_id=event_id)

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
