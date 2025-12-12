module ConfirmationEmails

using DuckDB
using DBInterface
using Dates
using JSON
using SMTPClient
using Base64: base64encode
using ColorTypes: Gray, N0f8
using PNGFiles
using QRCode
using Printf: @sprintf
using Random: randstring
using Mustache

# Bring EmailConfig from parent module
using ..EventRegistrations: EmailConfig


export generate_email_content
export preview_email
export ensure_default_templates

export load_template
export ensure_default_templates, escape_html

"""
Escape a string for safe inclusion in HTML content.
"""
function escape_html(text::AbstractString)
    return replace(text,
        "&" => "&amp;",
        "<" => "&lt;",
        ">" => "&gt;",
        '"' => "&quot;"
    )
end

escape_html(value) = escape_html(string(value))
escape_html(::Nothing) = ""

"""
Load a template from file.
Returns the template content as a string, or nothing if not found.
"""
function load_template(cfg, name::AbstractString)
    path = joinpath(cfg.templates_dir, name*".mustache")

    if !isfile(path)
        @error "Template not found" name=name path=path
        return nothing
    end

    return read(path, String)
end

# =============================================================================
# DEFAULT TEMPLATES
# =============================================================================

"""
Format registration fields as a nice list for email display.
Takes a Dict of field names and values, returns formatted string.

Optionally filter out fields that should be excluded (like internal IDs).
"""
function format_registration_fields(fields::AbstractDict;
                                     exclude::Vector{String}=String[],
                                     max_width::Int=40)
    if isempty(fields)
        return ""
    end

    # Common fields to exclude from display
    default_exclude = ["Vorname", "Nachname", "E-Mail", "Email", "First Name", "Last Name"]
    all_exclude = vcat(default_exclude, exclude)

    entries = String[]

    for key in sort(collect(keys(fields)))
        if key ∈ all_exclude
            continue
        end

        raw_value = string(fields[key])
        if isempty(strip(raw_value))
            continue
        end

        clean_value = replace(raw_value, r"\s*\n\s*" => ", ")
        escaped_key = escape_html(key)
        escaped_value = escape_html(clean_value)
        push!(entries, "<li style=\"margin: 4px 0;\"><strong>$(escaped_key):</strong> $(escaped_value)</li>")
    end

    if isempty(entries)
        return ""
    end

    return """
<div style="margin: 24px 0;">
  <h3 style="margin-bottom: 8px; font-size: 18px;">Deine Angaben</h3>
  <ul style="margin: 0 0 0 20px; padding: 0;">
    $(join(entries, "\n    "))
  </ul>
</div>
"""
end

export format_registration_fields

const PACKAGE_TEMPLATES_DIR = normpath(joinpath(@__DIR__, "..", "config", "templates"))

render_template(template::AbstractString, vars::AbstractDict) = Mustache.render(template, vars)

function ensure_default_templates(templates_dir::AbstractString)
    mkpath(templates_dir)

    created = String[]
    for name in ["registration_confirmation", "confirmation_email", "payment_confirmation"]
        dest = joinpath(templates_dir, "$name.mustache")
        if !isfile(dest)
            src = joinpath(PACKAGE_TEMPLATES_DIR, "$name.mustache")
            if isfile(src)
                cp(src, dest; force=true)
                push!(created, name)
            else
                @warn "Packaged default template missing" name=name src=src
            end
        end
    end

    if !isempty(created)
        @info "Created default templates" templates=created directory=templates_dir
    end
    return created
end

"""
Format registration fields as HTML list.
"""
function format_registration_fields(fields::AbstractDict;
                                     exclude::Vector{String}=String[],
                                     max_width::Int=40)
    if isempty(fields)
        return ""
    end

    default_exclude = ["Vorname", "Nachname", "E-Mail", "Email", "First Name", "Last Name"]
    all_exclude = vcat(default_exclude, exclude)

    entries = String[]

    for key in sort(collect(keys(fields)))
        if key ∈ all_exclude
            continue
        end

        raw_value = string(fields[key])
        if isempty(strip(raw_value))
            continue
        end

        clean_value = replace(raw_value, r"\s*\n\s*" => ", ")
        escaped_key = escape_html(key)
        escaped_value = escape_html(clean_value)
        push!(entries, "<li style=\"margin: 4px 0;\"><strong>$(escaped_key):</strong> $(escaped_value)</li>")
    end

    if isempty(entries)
        return ""
    end

    return """
<div style="margin: 24px 0;">
  <h3 style="margin-bottom: 8px; font-size: 18px;">Deine Angaben</h3>
  <ul style="margin: 0 0 0 20px; padding: 0;">
    $(join(entries, "\n    "))
  </ul>
</div>
"""
end

struct EmailAttachment
    filename::String
    content_type::String
    content::Vector{UInt8}
    disposition::String
end

"""Email configuration is provided via `EmailConfig`; no globals are mutated here."""

"""
Format a number as currency string.
"""
function format_currency(amount::Real)
    formatted = @sprintf("%.2f", float(amount))
    return replace(formatted, "." => ",")
end

"""
Format an IBAN for human-readable output (groups of four characters).
"""
function format_iban(iban::AbstractString)
    clean = replace(uppercase(strip(iban)), ' ' => "")
    return join([clean[i:min(i+3, end)] for i in 1:4:length(clean)], " ")
end

"""
Prepare bank details text for a specific reference number.
Replaces placeholders and falls back to structured data when needed.
"""
function prepare_bank_details(cfg::EmailConfig, reference_number::String)
    details = strip(cfg.bank_details)

    if isempty(details)
        parts = String[]
        if !isempty(cfg.account_name)
            push!(parts, cfg.account_name)
        elseif !isempty(cfg.from_name)
            push!(parts, cfg.from_name)
        end

        if !isempty(cfg.bank_name)
            push!(parts, cfg.bank_name)
        end

        if !isempty(cfg.iban)
            push!(parts, "IBAN: $(format_iban(cfg.iban))")
        end

        if !isempty(cfg.bic)
            push!(parts, "BIC: $(uppercase(cfg.bic))")
        end

        details = join(parts, "\n")
    end

    return replace(details, "[Ihre Referenznummer]" => reference_number, "{reference}" => reference_number)
end

"""
Collapse sequences of more than two blank lines to two blank lines.
"""
collapse_blank_lines(text::AbstractString) = replace(text, r"\n{3,}" => "\n\n")

"""
Sanitize a string for safe filename usage.
"""
function sanitize_filename(name::AbstractString)
    sanitized = replace(name, r"[^A-Za-z0-9._-]" => "-")
    return isempty(sanitized) ? "attachment" : sanitized
end

"""
Wrap base64 output to RFC-compliant line lengths.
"""
function wrap_base64(bytes::Vector{UInt8}; line_length::Int=76)
    encoded = base64encode(bytes)
    return join([encoded[i:min(i + line_length - 1, end)] for i in 1:line_length:length(encoded)], "\r\n")
end

"""
Convert a numeric value (possibly Missing or nothing) to Float64.
"""
function to_float(value)
    if value === nothing || value isa Missing
        return 0.0
    end
    return Float64(float(value))
end

"""
Generate EPC/SEPA payment QR payload string.
"""
function generate_sepa_qr_payload(; amount::Float64, reference::String, recipient::String, iban::String,
                                  bic::String="", remittance::String="")
    clean_iban = replace(uppercase(strip(iban)), ' ' => "")
    @assert !isempty(clean_iban) "IBAN is required for QR generation"
    formatted_amount = @sprintf("%.2f", amount)
    lines = String[
        "BCD",
        "001",
        "1",
        "SCT",
        uppercase(strip(bic)),
        strip(recipient)[1:min(end, 100)],
        clean_iban,
        "EUR" * formatted_amount,
        "",
        reference[1:min(end, 35)],
        remittance[1:min(end, 70)]
    ]
    return join(lines, "\n")
end

"""
Render a QR code payload to PNG bytes suitable for email attachment.
"""
function qr_payload_to_png(payload::String)
    matrix = Matrix(qrcode(payload))
    # true => black, false => white
    inverted = 1 .- Float32.(matrix)
    img = Gray{N0f8}.(inverted)
    io = IOBuffer()
    PNGFiles.save(io, img)
    return take!(io)
end

"""
Generate a payment QR HTML block if configuration allows it.
"""
function maybe_generate_payment_qr(cfg::EmailConfig, amount::Float64, reference::String)
    if !cfg.qr_enabled
        @debug "QR code disabled in configuration" reference=reference
        return nothing
    end

    if amount ≤ 0.0
        @debug "QR code not generated: amount is zero or negative" reference=reference amount=amount
        return nothing
    end

    if isempty(cfg.iban)
        @warn "QR code not generated: IBAN not configured" reference=reference
        return nothing
    end

    if isempty(cfg.account_name)
        @warn "QR code not generated: account_name not configured" reference=reference
        return nothing
    end

    try
        payload = generate_sepa_qr_payload(
            amount = amount,
            reference = string(strip(reference)),
            recipient = cfg.account_name,
            iban = cfg.iban,
            bic = cfg.bic,
            remittance = isempty(cfg.qr_message) ? cfg.bank_name : cfg.qr_message
        )

        png_bytes = qr_payload_to_png(payload)
        encoded = base64encode(png_bytes)
        hint_amount = replace(@sprintf("%.2f", amount), "." => ",")

        # QR code sizing: min-width ensures scannability (~4cm at 96dpi),
        # width provides comfortable default (~5cm), max-width prevents excessive size
        html = """
<div style="margin: 24px 0; text-align: center;">
  <h3 style="margin-bottom: 12px; font-size: 18px;">Bezahlen per QR-Code</h3>
  <img src="data:image/png;base64,$encoded" alt="SEPA QR-Code" style="min-width: 160px; width: 200px; max-width: 280px; height: auto; image-rendering: pixelated;" />
  <p style="margin-top: 12px; font-size: 14px; color: #4a5568;">Scanne den QR-Code mit deiner Banking-App.<br>Betrag (€$hint_amount) und Verwendungszweck werden automatisch übernommen.</p>
</div>
"""

        return strip(html)
    catch e
        @warn "Failed to create payment QR" exception=e reference=reference
        return nothing
    end
end

"""
Generate email content from external template file.
Falls back to creating default templates if they don't exist.
"""
function generate_email_content(cfg::EmailConfig;
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
    registration_fields::AbstractDict=Dict(),
    extra_vars::AbstractDict{String,String}=Dict{String,String}()
)
    ensure_default_templates(cfg.templates_dir)
    template = load_template(cfg, template_name)

    if template === nothing
        error("Template not found: $template_name")
    end

    fields_html = strip(format_registration_fields(registration_fields))

    bank_details_text = prepare_bank_details(cfg, reference_number)
    bank_details_html = isempty(strip(bank_details_text)) ? "" : replace(escape_html(bank_details_text), "\n" => "<br>")

    fallback_info = isempty(strip(cfg.additional_info)) ? "Bei Fragen erreichst du uns unter $(cfg.from_address)." : cfg.additional_info
    info_html = isempty(strip(fallback_info)) ? "" : "<p style=\"margin: 24px 0;\">$(replace(escape_html(fallback_info), "\n" => "<br>"))</p>"

    vars = Dict{String, Any}(
        "first_name" => something(first_name, ""),
        "last_name" => something(last_name, ""),
        "event_name" => something(event_name, ""),
        "reference_number" => reference_number,
        "cost" => format_currency(cost),
        "remaining" => format_currency(remaining),
        "subsidy_amount" => format_currency(subsidy_amount),
        "subsidy_reason" => something(subsidy_reason, ""),
        "amount_paid" => format_currency(amount_paid),
        "cost_change_note" => something(cost_change_note, ""),
        "registration_fields" => fields_html,
        "bank_details" => bank_details_html,
        "additional_info" => info_html,
        "sender_name" => cfg.from_name,
    )

    qr_html = maybe_generate_payment_qr(cfg, to_float(remaining), reference_number)
    vars["qr_block"] = qr_html === nothing ? "" : qr_html

    merge!(vars, extra_vars)

    return render_template(template, vars)
end

"""
Preview email content for a registration.
"""
function preview_email(cfg::EmailConfig, db::DuckDB.DB, registration_id::Integer;
                       template_name::String="confirmation_email",
                       extra_vars::AbstractDict{String,String}=Dict{String,String}())
    result = DBInterface.execute(db, """
        SELECT r.first_name, r.last_name, r.email, r.reference_number, r.computed_cost,
               COALESCE(e.event_name, r.event_id) as event_name,
               COALESCE(sub.total_subsidy, 0) as total_subsidy,
               COALESCE(pay.total_paid, 0) as total_paid,
               r.fields
        FROM registrations r
        LEFT JOIN events e ON e.event_id = r.event_id
        LEFT JOIN (
            SELECT registration_id, SUM(amount) as total_subsidy
            FROM subsidies
            GROUP BY registration_id
        ) sub ON sub.registration_id = r.id
        LEFT JOIN (
            SELECT pm.registration_id, SUM(bt.amount) as total_paid
            FROM payment_matches pm
            JOIN bank_transfers bt ON bt.id = pm.transfer_id
            WHERE pm.registration_id IS NOT NULL
            GROUP BY pm.registration_id
        ) pay ON pay.registration_id = r.id
        WHERE r.id = ?
    """, [registration_id])

    rows = collect(result)
    if isempty(rows)
        error("Registration not found: $registration_id")
    end

    row = rows[1]
    computed_cost = to_float(something(row[5], 0.0))
    total_subsidy = to_float(something(row[7], 0.0))
    total_paid = to_float(something(row[8], 0.0))
    effective_cost = max(computed_cost - total_subsidy, 0.0)
    remaining_amount = max(effective_cost - total_paid, 0.0)

    # Parse fields JSON
    fields_json = row[9]
    registration_fields = if fields_json !== nothing && !isempty(fields_json)
        try
            JSON.parse(fields_json)
        catch
            Dict()
        end
    else
        Dict()
    end

    content = generate_email_content(cfg;
        template_name = template_name,
        first_name = something(row[1], ""),
        last_name = something(row[2], ""),
        event_name = something(row[6], "Event"),
        reference_number = row[4],
        cost = effective_cost,
        remaining = remaining_amount,
        subsidy_amount = total_subsidy,
        amount_paid = total_paid,
        registration_fields = registration_fields,
        extra_vars = extra_vars
    )

    return (
        to = row[3],
        subject = "Anmeldebestätigung: $(row[6]) - $(row[4])",
        body = content
    )
end

"""
Encode a string using RFC 2047 for email headers (e.g., Subject line).
Handles non-ASCII characters properly.
"""
function encode_mime_header(text::String)
    # Check if encoding is needed (contains non-ASCII)
    if all(c -> UInt8(c) < 128, text)
        return text  # Pure ASCII, no encoding needed
    end

    # Use base64 encoding for UTF-8 text
    # Format: =?UTF-8?B?<base64>?=
    encoded = base64encode(text)
    return "=?UTF-8?B?$(encoded)?="
end

"""
Normalize line endings to CRLF as required by SMTP (RFC 5322).
"""
function ensure_crlf(text::AbstractString)
    normalized = replace(text, "\r\n" => "\n")
    normalized = replace(normalized, '\r' => '\n')
    normalized = replace(normalized, "\n" => "\r\n")
    return occursin(r"\r\n$", normalized) ? normalized : string(normalized, "\r\n")
end

"""
Send email via SMTP.
Requires SMTPClient.jl or similar package.
"""
function send_via_smtp(cfg::EmailConfig, to::String, subject::String, body::String; attachments::Vector{EmailAttachment}=EmailAttachment[])
    if isempty(cfg.smtp_server)
        @error "SMTP server not configured"
        return false
    end

    try
        println("\n[SMTP DEBUG] Preparing to send email...")
        println("  Server: $(cfg.smtp_server):$(cfg.smtp_port)")
        println("  From: $(cfg.from_name) <$(cfg.from_address)>")
        println("  To: $to")
        println("  Subject: $subject")
        println("  Body length: $(length(body)) characters")

        # Prepare email message
        from_email = cfg.from_address
        from_name = cfg.from_name

        # Encode subject line for non-ASCII characters (RFC 2047)
        encoded_subject = encode_mime_header(subject)
        encoded_from_name = encode_mime_header(from_name)

        header_lines = [
            "From: $(encoded_from_name) <$(from_email)>",
            "To: $(to)",
            "Subject: $(encoded_subject)",
            "MIME-Version: 1.0"
        ]

        message_body = ""

        if isempty(attachments)
            push!(header_lines, "Content-Type: text/html; charset=UTF-8")
            push!(header_lines, "Content-Transfer-Encoding: 8bit")
            message_body = join(header_lines, "\n") * "\n\n" * body
        else
            boundary = "----=EventRegBoundary$(randstring(12))"
            push!(header_lines, "Content-Type: multipart/mixed; boundary=\"$(boundary)\"")

            parts = String[]
            push!(parts, "--$boundary")
            push!(parts, "Content-Type: text/html; charset=UTF-8")
            push!(parts, "Content-Transfer-Encoding: 8bit")
            push!(parts, "")
            push!(parts, body)

            for att in attachments
                push!(parts, "--$boundary")
                push!(parts, "Content-Type: $(att.content_type); name=\"$(att.filename)\"")
                push!(parts, "Content-Disposition: $(att.disposition); filename=\"$(att.filename)\"")
                push!(parts, "Content-Transfer-Encoding: base64")
                push!(parts, "")
                push!(parts, wrap_base64(att.content))
            end

            push!(parts, "--$boundary--")

            message_body = join(header_lines, "\n") * "\n\n" * join(parts, "\n")
        end

        email_body = ensure_crlf(message_body)

        println("  [SMTP DEBUG] Connecting to SMTP server...")

        # Send using SMTPClient
        use_ssl = cfg.smtp_port == 465 || cfg.smtp_port == 587
        opt = SendOptions(
            isSSL = use_ssl,
            username = cfg.username,
            passwd = cfg.password
        )

        url = "smtp://$(cfg.smtp_server):$(cfg.smtp_port)"

        println("  [SMTP DEBUG] URL: $url")
        println("  [SMTP DEBUG] Username: $(cfg.username)")
        println("  [SMTP DEBUG] SSL: $(use_ssl)")

        # Send the email
        resp = send(
            url,
            [to],
            from_email,
            IOBuffer(email_body),
            opt
        )

        println("  [SMTP DEBUG] Response: $resp")

        if resp.code == 250 || resp.code == 0  # 250 = success, 0 = success in some versions
            println("  [SMTP DEBUG] ✓ Email sent successfully!")
            @info "Email sent successfully" to=to subject=subject
            return true
        else
            println("  [SMTP DEBUG] Failed to send to $to")
            println("  [SMTP DEBUG] ✗ SMTP error code: $(resp.code)")
            println("  [SMTP DEBUG] Error message: $(resp.message)")
            @error "SMTP error" code=resp.code message=resp.message
            return false
        end

    catch e
        println("  [SMTP DEBUG] ✗ Exception occurred:")
        println("  [SMTP DEBUG] $(typeof(e)): $e")
        @error "Failed to send email" exception=e
        # Print stack trace for debugging
        for (exc, bt) in Base.catch_stack()
            showerror(stdout, exc, bt)
            println()
        end
        return false
    end
end


# =============================================================================
# EMAIL QUEUE MANAGEMENT
# =============================================================================

"""
Get all pending emails from the queue.
Returns array of named tuples with queue entry details.
Supports optional filtering by event and email_type.
"""
function get_pending_emails(db::DuckDB.DB;
                            event_id::Union{String,Nothing}=nothing,
                            email_type::Union{String,Nothing}=nothing)
    query = """
        SELECT eq.id, eq.registration_id, eq.email_to, eq.subject, eq.body_text,
               eq.cost_at_queue, eq.remaining_at_queue, eq.reference_number,
               eq.queue_reason, eq.queued_at, r.event_id, r.first_name, r.last_name,
               eq.email_type
        FROM email_queue eq
        JOIN registrations r ON r.id = eq.registration_id
        WHERE eq.status = 'pending'
    """

    params = Any[]
    if event_id !== nothing
        query *= """
        AND r.event_id = ?
        """
        push!(params, event_id)
    end
    if email_type !== nothing
        query *= """
        AND eq.email_type = ?
        """
        push!(params, email_type)
    end

    query *= """
        ORDER BY eq.queued_at ASC
    """

    result = isempty(params) ? DBInterface.execute(db, query) : DBInterface.execute(db, query, params)

    return [(
        id = row[1],
        registration_id = row[2],
        email_to = row[3],
        subject = row[4],
        body_text = row[5],
        cost = row[6],
        remaining = row[7],
        reference_number = row[8],
        reason = row[9],
        queued_at = row[10],
        event_id = row[11],
        first_name = row[12],
        last_name = row[13],
        email_type = row[14]
    ) for row in result]
end

export get_pending_emails

"""
Queue an email for later sending.
Returns the queue entry ID, or nothing if email was already queued with same content.
"""
function queue_email!(cfg::EmailConfig, db::DuckDB.DB, registration_id::Integer;
                      template_name::String="confirmation_email",
                      reason::String="balance_changed")
    # Get registration data
    reg_result = DBInterface.execute(db, """
        SELECT r.email, r.reference_number, r.computed_cost,
               COALESCE(r.computed_cost, 0) -
               COALESCE((SELECT SUM(amount) FROM subsidies WHERE registration_id = r.id), 0) -
               COALESCE((SELECT SUM(bt.amount) FROM bank_transfers bt
                         JOIN payment_matches pm ON pm.transfer_id = bt.id
                         WHERE pm.registration_id = r.id), 0) as remaining
        FROM registrations r
        WHERE r.id = ?
    """, [registration_id])

    reg_rows = collect(reg_result)
    if isempty(reg_rows)
        @warn "Registration not found" registration_id=registration_id
        return nothing
    end

    email_to, reference_number, computed_cost, remaining = reg_rows[1]

    # Convert to Float64 to avoid DuckDB binding issues with FixedDecimal
    # Handle NULL/missing values safely
    computed_cost_f = (computed_cost === nothing || ismissing(computed_cost)) ? nothing : Float64(computed_cost)
    remaining_f = (remaining === nothing || ismissing(remaining)) ? 0.0 : Float64(remaining)

    # Check if there's already a pending email with same content
    existing = DBInterface.execute(db, """
        SELECT id FROM email_queue
        WHERE registration_id = ?
          AND email_type = ?
          AND status = 'pending'
          AND remaining_at_queue = ?
    """, [registration_id, template_name, remaining_f])

    if !isempty(collect(existing))
        @info "Email already queued with same balance" registration_id=registration_id remaining=remaining_f
        return nothing
    end

    # Generate email content
    preview = preview_email(cfg, db, registration_id; template_name=template_name)

    # Insert into queue
    DBInterface.execute(db, """
        INSERT INTO email_queue (
            id, registration_id, email_type, email_to, subject, body_text,
            cost_at_queue, remaining_at_queue, reference_number, queue_reason,
            status, queued_at
        ) VALUES (
            nextval('email_queue_id_seq'), ?, ?, ?, ?, ?,
            ?, ?, ?, ?,
            'pending', CURRENT_TIMESTAMP
        )
    """, [registration_id, template_name, email_to, preview.subject, preview.body,
          computed_cost_f, remaining_f, reference_number, reason])

    # Get the inserted ID
    result = DBInterface.execute(db, "SELECT currval('email_queue_id_seq')")
    queue_id = first(collect(result))[1]

    @info "Email queued" queue_id=queue_id registration_id=registration_id email_to=email_to reason=reason

    return queue_id
end

export queue_email!

"""
Queue a payment confirmation email after a payment match is created.
Returns the queue entry ID, or nothing if unable to queue.

This should be called after a payment is matched to a registration.
The payment_confirmation template will be used.
"""
function queue_payment_confirmation!(cfg::EmailConfig, db::DuckDB.DB, registration_id::Integer, amount_paid::Real)
    # Get registration data
    reg_result = DBInterface.execute(db, """
        SELECT r.email, r.reference_number, r.first_name, r.event_id,
               COALESCE(e.event_name, r.event_id) as event_name
        FROM registrations r
        LEFT JOIN events e ON e.event_id = r.event_id
        WHERE r.id = ?
    """, [registration_id])

    reg_rows = collect(reg_result)
    if isempty(reg_rows)
        @warn "Registration not found for payment confirmation" registration_id=registration_id
        return nothing
    end

    email_to, reference_number, first_name, event_id, event_name = reg_rows[1]

    # Convert amount to Float64
    amount_f = Float64(amount_paid)

    # Check for duplicate pending payment confirmation with same amount
    # (avoid sending duplicate payment confirmations for the same payment)
    existing = DBInterface.execute(db, """
        SELECT id FROM email_queue
        WHERE registration_id = ?
          AND email_type = 'payment_confirmation'
          AND status = 'pending'
          AND cost_at_queue = ?
          AND queued_at > (CURRENT_TIMESTAMP::TIMESTAMP - INTERVAL 1 MINUTE)

    """, [registration_id, amount_f])

    if !isempty(collect(existing))
        @info "Payment confirmation already queued recently" registration_id=registration_id amount=amount_f
        return nothing
    end

    # Generate email content using payment_confirmation template
    ensure_default_templates(cfg.templates_dir)
    template = load_template(cfg, "payment_confirmation")

    if template === nothing
        @error "Payment confirmation template not found"
        return nothing
    end

    # Prepare template variables
    vars = Dict{String, Any}(
        "first_name" => something(first_name, ""),
        "event_name" => something(event_name, event_id),
        "reference_number" => reference_number,
        "amount_paid" => format_currency(amount_f),
        "sender_name" => cfg.from_name
    )

    body_text = render_template(template, vars)
    subject = "Zahlungsbestätigung: $(event_name) - $(reference_number)"

    # Insert into queue
    DBInterface.execute(db, """
        INSERT INTO email_queue (
            id, registration_id, email_type, email_to, subject, body_text,
            cost_at_queue, remaining_at_queue, reference_number, queue_reason,
            status, queued_at
        ) VALUES (
            nextval('email_queue_id_seq'), ?, ?, ?, ?, ?,
            ?, NULL, ?, ?,
            'pending', CURRENT_TIMESTAMP
        )
    """, [registration_id, "payment_confirmation", email_to, subject, body_text,
          amount_f, reference_number, "payment_received"])

    # Get the inserted ID
    result = DBInterface.execute(db, "SELECT currval('email_queue_id_seq')")
    queue_id = first(collect(result))[1]

    @info "Payment confirmation queued" queue_id=queue_id registration_id=registration_id amount=amount_f

    return queue_id
end

export queue_payment_confirmation!

"""
Intelligently queue emails for all registrations that need them.
Automatically chooses the appropriate template:
- registration_confirmation: when computed_cost is NULL (no payment info yet)
- confirmation_email: when computed_cost is set (payment request)

Sends emails for ALL registrations (even fully paid) on:
- First time (never sent)
- When computed_cost changes (not just balance changes)

Returns (registration_emails_queued, payment_emails_queued).
"""
function queue_pending_emails!(cfg::EmailConfig, db::DuckDB.DB, event_id::AbstractString)
    # Get all registrations with their email status
    result = DBInterface.execute(db, """
        WITH latest_registration_emails AS (
            SELECT
                ce.registration_id,
                ce.sent_at,
                ROW_NUMBER() OVER (PARTITION BY ce.registration_id ORDER BY ce.sent_at DESC) as rn
            FROM confirmation_emails ce
            JOIN registrations r ON r.id = ce.registration_id
            WHERE r.event_id = ?
              AND ce.email_type = 'registration_confirmation'
              AND ce.status = 'sent'
        ),
        latest_payment_emails AS (
            SELECT
                ce.registration_id,
                ce.cost_at_send,
                ce.sent_at,
                ROW_NUMBER() OVER (PARTITION BY ce.registration_id ORDER BY ce.sent_at DESC) as rn
            FROM confirmation_emails ce
            JOIN registrations r ON r.id = ce.registration_id
            WHERE r.event_id = ?
              AND ce.email_type = 'confirmation_email'
              AND ce.status = 'sent'
        )
        SELECT
            r.id as registration_id,
            r.computed_cost,
            lre.registration_id IS NOT NULL as has_registration_email,
            lpe.registration_id IS NOT NULL as has_payment_email,
            lpe.cost_at_send as last_sent_cost
        FROM registrations r
        LEFT JOIN latest_registration_emails lre ON lre.registration_id = r.id AND lre.rn = 1
        LEFT JOIN latest_payment_emails lpe ON lpe.registration_id = r.id AND lpe.rn = 1
        WHERE r.event_id = ?
    """, [event_id, event_id, event_id])

    registration_count = 0
    payment_count = 0

    for row in collect(result)
        registration_id = row[1]
        computed_cost = row[2]
        has_registration_email = row[3]
        has_payment_email = row[4]
        last_sent_cost = row[5]

        # Convert database booleans to Julia booleans (handle missing)
        has_reg_email = something(has_registration_email, false)
        has_pay_email = something(has_payment_email, false)

        # If computed_cost is NULL, send registration_confirmation if not already sent
        if computed_cost === nothing || ismissing(computed_cost)
            if !has_reg_email
                queue_id = queue_email!(cfg, db, registration_id;
                                       template_name="registration_confirmation",
                                       reason="initial")
                if queue_id !== nothing
                    registration_count += 1
                end
            end
        else
            # computed_cost is set, send confirmation_email (payment request)
            # Send if: never sent OR cost changed (even if fully paid!)
            should_send = false
            reason = "initial"

            if !has_pay_email
                # First time - always send (even if fully paid)
                should_send = true
                reason = "initial"
            elseif !ismissing(computed_cost) && computed_cost !== nothing &&
                   !ismissing(last_sent_cost) && last_sent_cost !== nothing
                # Check if COST changed (not balance - ignore payments/subsidies)
                # Use small epsilon for floating point comparison
                if abs(Float64(computed_cost) - Float64(last_sent_cost)) > 0.01
                    should_send = true
                    reason = "cost_changed"
                end
            end

            # Send regardless of payment status (even if fully paid)
            if should_send
                queue_id = queue_email!(cfg, db, registration_id;
                                       template_name="confirmation_email",
                                       reason=reason)
                if queue_id !== nothing
                    payment_count += 1
                end
            end
        end
    end

    return (registration_emails=registration_count, payment_emails=payment_count)
end

export queue_pending_emails!

"""
Get count of pending emails by event.
Returns dict of event_id => count.
"""
function count_pending_emails(db::DuckDB.DB)
    result = DBInterface.execute(db, """
        SELECT r.event_id, COUNT(*) as cnt
        FROM email_queue eq
        JOIN registrations r ON r.id = eq.registration_id
        WHERE eq.status = 'pending'
        GROUP BY r.event_id
    """)

    return Dict(row[1] => row[2] for row in result)
end

export count_pending_emails

"""
Mark a queued email as sent or discarded.
"""
function mark_email!(db::DuckDB.DB, queue_id::Integer, status::String;
                     processed_by::String="manual",
                     error_message::Union{String,Nothing}=nothing)
    if !(status in ["sent", "discarded"])
        error("Invalid status: $status. Must be 'sent' or 'discarded'.")
    end

    # Update queue entry
    if error_message !== nothing
        DBInterface.execute(db, """
            UPDATE email_queue
            SET status = ?, processed_at = CURRENT_TIMESTAMP, processed_by = ?, error_message = ?
            WHERE id = ?
        """, [status, processed_by, error_message, queue_id])
    else
        DBInterface.execute(db, """
            UPDATE email_queue
            SET status = ?, processed_at = CURRENT_TIMESTAMP, processed_by = ?
            WHERE id = ?
        """, [status, processed_by, queue_id])
    end

    # If marked as sent, also record in confirmation_emails for tracking
    if status == "sent"
        queue_entry = DBInterface.execute(db, """
            SELECT registration_id, email_type, email_to, cost_at_queue, remaining_at_queue, reference_number, queue_reason
            FROM email_queue WHERE id = ?
        """, [queue_id])

        rows = collect(queue_entry)
        if !isempty(rows)
            reg_id, email_type, email_to, cost, remaining, reference, reason = rows[1]
            # Handle NULL values (e.g., for payment confirmations where remaining is not tracked)
            cost_f = (isnothing(cost) || ismissing(cost)) ? 0.0 : Float64(cost)
            remaining_f = (isnothing(remaining) || ismissing(remaining)) ? 0.0 : Float64(remaining)
            DBInterface.execute(db, """
                INSERT INTO confirmation_emails (
                    id, registration_id, email_type, sent_at, email_to,
                    cost_at_send, remaining_at_send, reference_sent, status, resend_reason
                ) VALUES (
                    nextval('email_id_seq'), ?, ?, CURRENT_TIMESTAMP, ?,
                    ?, ?, ?, 'sent', ?
                )
            """, [reg_id, email_type, email_to, cost_f, remaining_f, reference, reason])
        end
    end

    @info "Email queue entry updated" queue_id=queue_id status=status processed_by=processed_by
end

export mark_email!

"""
Send a queued email and update its status.
Returns true if sent successfully.
"""
function send_queued_email!(cfg::EmailConfig, db::DuckDB.DB, queue_id::Integer)
    # Get queue entry
    result = DBInterface.execute(db, """
        SELECT eq.email_to, eq.subject, eq.body_text, eq.registration_id,
               eq.cost_at_queue, eq.remaining_at_queue, eq.reference_number
        FROM email_queue eq
        WHERE eq.id = ? AND eq.status = 'pending'
    """, [queue_id])

    rows = collect(result)
    if isempty(rows)
        @warn "Queue entry not found or not pending" queue_id=queue_id
        return false
    end

    email_to, subject, body_text, reg_id, cost, remaining, reference = rows[1]

    # Check if dry_run mode
    if cfg.dry_run
        println("  [DRY RUN] Would send email to: $email_to")
        println("  [DRY RUN] Subject: $subject")
        mark_email!(db, queue_id, "sent"; processed_by="dry_run")
        return true
    end

    # Actually send the email
    success = send_via_smtp(cfg, email_to, subject, body_text)

    if success
        mark_email!(db, queue_id, "sent"; processed_by="smtp")
        return true
    else
        mark_email!(db, queue_id, "pending"; processed_by="smtp_failed",
                   error_message="SMTP send failed")
        return false
    end
end

export send_queued_email!

"""
Send all pending emails in the queue.
Returns (sent_count, error_count).
"""
function send_all_pending_emails!(cfg::EmailConfig, db::DuckDB.DB; event_id::Union{String,Nothing}=nothing)
    pending = get_pending_emails(db; event_id=event_id)

    sent_count = 0
    error_count = 0

    for email in pending
        println("  Sending to $(email.email_to) ($(email.first_name) $(email.last_name))...")
        success = send_queued_email!(cfg, db, email.id)
        if success
            sent_count += 1
        else
            error_count += 1
        end
    end

    return (sent=sent_count, errors=error_count)
end

export send_all_pending_emails!


end # module
