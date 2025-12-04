module ConfirmationEmails

using DuckDB
using DBInterface
using Dates

# Import from parent module's submodule
using ..Templates

export send_confirmation_email!, send_pending_confirmations!, generate_email_content
export get_unsent_confirmations, preview_email, export_emails_to_files
export configure!, EmailConfig

"""
Configuration for email sending.
"""
mutable struct EmailConfig
    smtp_server::String
    smtp_port::Int
    username::String
    password::String
    from_address::String
    from_name::String
    bank_details::String
    additional_info::String
    dry_run::Bool  # If true, don't actually send emails
end

# Default config (needs to be configured before use)
const CONFIG = EmailConfig(
    "",     # smtp_server
    587,    # smtp_port
    "",     # username
    "",     # password
    "",     # from_address
    "",     # from_name
    "",     # bank_details
    "",     # additional_info
    true    # dry_run
)

"""
Configure email settings.
"""
function configure!(;
    smtp_server::String="",
    smtp_port::Int=587,
    username::String="",
    password::String="",
    from_address::String="",
    from_name::String="",
    bank_details::String="",
    additional_info::String="",
    dry_run::Bool=true
)
    CONFIG.smtp_server = smtp_server
    CONFIG.smtp_port = smtp_port
    CONFIG.username = username
    CONFIG.password = password
    CONFIG.from_address = from_address
    CONFIG.from_name = from_name
    CONFIG.bank_details = bank_details
    CONFIG.additional_info = additional_info
    CONFIG.dry_run = dry_run
end

"""
Format a number as currency string.
"""
function format_currency(amount::Real)
    return string(round(amount, digits=2))
end

"""
Generate email content from external template file.
Falls back to creating default templates if they don't exist.
"""
function generate_email_content(;
    template_name::String="confirmation_email",
    first_name::String="",
    last_name::String="",
    event_name::String="",
    reference_number::String="",
    cost::Real=0.0,
    remaining::Real=0.0,
    subsidy_amount::Real=0.0,
    subsidy_reason::String="",
    amount_paid::Real=0.0,
    cost_change_note::String="",
    extra_vars::Dict{String,String}=Dict{String,String}()
)
    # Try to load external template
    template = load_template(template_name)

    if template === nothing
        # Ensure default templates exist and try again
        ensure_default_templates()
        template = load_template(template_name)
    end

    if template === nothing
        error("Template not found: $template_name")
    end

    # Build variables dict
    vars = Dict{String, Any}(
        "first_name" => first_name,
        "last_name" => last_name,
        "event_name" => event_name,
        "reference_number" => reference_number,
        "cost" => format_currency(cost),
        "remaining" => format_currency(remaining),
        "subsidy_amount" => format_currency(subsidy_amount),
        "subsidy_reason" => subsidy_reason,
        "amount_paid" => format_currency(amount_paid),
        "cost_change_note" => cost_change_note,
        "bank_details" => CONFIG.bank_details,
        "additional_info" => CONFIG.additional_info,
        "sender_name" => CONFIG.from_name,
    )

    # Merge extra variables
    merge!(vars, extra_vars)

    return render_template(template, vars)
end

"""
Preview email content for a registration.
"""
function preview_email(db::DuckDB.DB, registration_id::Integer;
                       template_name::String="confirmation_email")
    result = DBInterface.execute(db, """
        SELECT r.first_name, r.last_name, r.email, r.reference_number, r.computed_cost,
               COALESCE(e.event_name, r.event_id) as event_name,
               COALESCE(sub.total_subsidy, 0) as total_subsidy
        FROM registrations r
        LEFT JOIN events e ON e.event_id = r.event_id
        LEFT JOIN (
            SELECT registration_id, SUM(amount) as total_subsidy
            FROM subsidies
            GROUP BY registration_id
        ) sub ON sub.registration_id = r.id
        WHERE r.id = ?
    """, [registration_id])

    rows = collect(result)
    if isempty(rows)
        error("Registration not found: $registration_id")
    end

    row = rows[1]
    computed_cost = something(row[5], 0.0)
    total_subsidy = something(row[7], 0.0)
    effective_cost = computed_cost - total_subsidy  # What they actually need to pay

    content = generate_email_content(
        template_name = template_name,
        first_name = something(row[1], ""),
        last_name = something(row[2], ""),
        event_name = something(row[6], "Event"),
        reference_number = row[4],
        cost = effective_cost,
        remaining = effective_cost,
        subsidy_amount = total_subsidy
    )

    return (
        to = row[3],
        subject = "Anmeldebestätigung: $(row[6]) - $(row[4])",
        body = content
    )
end

"""
Send confirmation email for a single registration.
Returns true if successful (or in dry_run mode).
"""
function send_confirmation_email!(db::DuckDB.DB, registration_id::Integer;
                                   force::Bool=false,
                                   template_name::String="confirmation_email")
    # Check if already sent (unless force)
    if !force
        existing = DBInterface.execute(db, """
            SELECT id FROM confirmation_emails
            WHERE registration_id = ? AND status = 'sent'
        """, [registration_id])
        if !isempty(collect(existing))
            @info "Email already sent for registration" registration_id=registration_id
            return false
        end
    end

    # Get registration details
    email_preview = preview_email(db, registration_id; template_name=template_name)

    # Get registration's effective cost (computed_cost - subsidies)
    cost_result = DBInterface.execute(db, """
        SELECT r.computed_cost - COALESCE(sub.total_subsidy, 0) as effective_cost,
               r.reference_number
        FROM registrations r
        LEFT JOIN (
            SELECT registration_id, SUM(amount) as total_subsidy
            FROM subsidies
            GROUP BY registration_id
        ) sub ON sub.registration_id = r.id
        WHERE r.id = ?
    """, [registration_id])
    cost_row = first(collect(cost_result))
    effective_cost = cost_row[1]
    reference = cost_row[2]

    success = false

    if CONFIG.dry_run
        @info "DRY RUN - Would send email" to=email_preview.to subject=email_preview.subject
        println("\n--- EMAIL PREVIEW ---")
        println("To: $(email_preview.to)")
        println("Subject: $(email_preview.subject)")
        println("---")
        println(email_preview.body)
        println("--- END PREVIEW ---\n")
        success = true
    else
        # Actually send email using system mail or SMTP
        success = send_via_smtp(
            email_preview.to,
            email_preview.subject,
            email_preview.body
        )
    end

    if success
        # Record that we sent the email
        DBInterface.execute(db, """
            INSERT INTO confirmation_emails (id, registration_id, sent_at, email_to,
                                             cost_sent, reference_sent, status)
            VALUES (nextval('email_id_seq'), ?, ?, ?, ?, ?, 'sent')
        """, [registration_id, now(), email_preview.to, effective_cost, reference])

        @info "Confirmation email sent" registration_id=registration_id to=email_preview.to
    end

    return success
end

"""
Send confirmation emails for all registrations that haven't received one.
"""
function send_pending_confirmations!(db::DuckDB.DB, event_id::AbstractString;
                                      template_name::String="confirmation_email")
    # Find registrations without sent confirmations
    result = DBInterface.execute(db, """
        SELECT r.id
        FROM registrations r
        LEFT JOIN confirmation_emails ce ON ce.registration_id = r.id AND ce.status = 'sent'
        WHERE r.event_id = ? AND ce.id IS NULL
    """, [event_id])

    pending = collect(result)
    sent = 0
    failed = 0

    for row in pending
        if send_confirmation_email!(db, row[1]; template_name=template_name)
            sent += 1
        else
            failed += 1
        end
    end

    @info "Sent pending confirmations" event_id=event_id sent=sent failed=failed
    return (sent=sent, failed=failed)
end

"""
Get list of registrations that haven't received confirmation emails.
"""
function get_unsent_confirmations(db::DuckDB.DB, event_id::AbstractString)
    result = DBInterface.execute(db, """
        SELECT r.id, r.reference_number, r.first_name, r.last_name, r.email,
               r.computed_cost - COALESCE(sub.total_subsidy, 0) as effective_cost
        FROM registrations r
        LEFT JOIN confirmation_emails ce ON ce.registration_id = r.id AND ce.status = 'sent'
        LEFT JOIN (
            SELECT registration_id, SUM(amount) as total_subsidy
            FROM subsidies
            GROUP BY registration_id
        ) sub ON sub.registration_id = r.id
        WHERE r.event_id = ? AND ce.id IS NULL
        ORDER BY r.registration_date
    """, [event_id])
    return collect(result)
end

"""
Send email via SMTP.
Requires SMTPClient.jl or similar package.
"""
function send_via_smtp(to::String, subject::String, body::String)
    if isempty(CONFIG.smtp_server)
        @error "SMTP server not configured"
        return false
    end

    # This is a placeholder - actual implementation would use SMTPClient.jl
    try
        mail_content = """
From: $(CONFIG.from_name) <$(CONFIG.from_address)>
To: $to
Subject: $subject
Content-Type: text/plain; charset=UTF-8

$body
"""
        @warn "SMTP sending not fully implemented - using placeholder"
        return false

    catch e
        @error "Failed to send email" exception=e
        return false
    end
end

"""
Export email content to files for manual sending.
Useful when SMTP is not available.
"""
function export_emails_to_files(db::DuckDB.DB, event_id::AbstractString, output_dir::String;
                                 template_name::String="confirmation_email")
    mkpath(output_dir)

    registrations = DBInterface.execute(db, """
        SELECT r.id, r.reference_number, r.email
        FROM registrations r
        LEFT JOIN confirmation_emails ce ON ce.registration_id = r.id AND ce.status = 'sent'
        WHERE r.event_id = ? AND ce.id IS NULL
    """, [event_id])

    count = 0
    for row in registrations
        reg_id, reference, email_addr = row
        preview = preview_email(db, reg_id; template_name=template_name)

        # Create email file
        filename = joinpath(output_dir, "$(reference)_$(replace(email_addr, '@' => "_at_")).txt")

        open(filename, "w") do f
            write(f, "TO: $(preview.to)\n")
            write(f, "SUBJECT: $(preview.subject)\n")
            write(f, "---\n")
            write(f, preview.body)
        end

        count += 1
    end

    @info "Exported email files" count=count directory=output_dir
    return count
end

end # module
