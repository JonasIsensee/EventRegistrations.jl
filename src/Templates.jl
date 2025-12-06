module Templates

export load_template, get_template_path, list_templates
export render_template, ensure_default_templates, escape_html

# Default templates directory
const TEMPLATES_DIR = Ref{String}("config/templates")

"""
Get the current templates directory.
"""
get_templates_dir() = TEMPLATES_DIR[]

"""
Set the templates directory.
"""
function set_templates_dir!(path::AbstractString)
    TEMPLATES_DIR[] = path
end

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
Get full path to a template file.
"""
function get_template_path(name::AbstractString)
    # Add .txt extension if not present
    filename = endswith(name, ".txt") ? name : "$name.txt"
    return joinpath(TEMPLATES_DIR[], filename)
end

"""
Load a template from file.
Returns the template content as a string, or nothing if not found.
"""
function load_template(name::AbstractString)
    path = get_template_path(name)

    if !isfile(path)
        @warn "Template not found" name=name path=path
        return nothing
    end

    return read(path, String)
end

"""
List all available templates.
"""
function list_templates()
    dir = TEMPLATES_DIR[]
    if !isdir(dir)
        return String[]
    end

    return [splitext(f)[1] for f in readdir(dir) if endswith(f, ".txt")]
end

"""
Render a template by replacing placeholders with values.

Placeholders are in the format {name} and are replaced with corresponding
values from the `vars` dictionary.

Example:
    render_template("Hello {name}!", Dict("name" => "World"))
    # Returns: "Hello World!"
"""
function render_template(template::AbstractString, vars::Dict)
    result = template

    for (key, value) in vars
        placeholder = "{$key}"
        result = replace(result, placeholder => string(value))
    end

    return result
end

"""
Load and render a template in one call.
"""
function load_and_render(name::AbstractString, vars::Dict)
    template = load_template(name)
    if template === nothing
        return nothing
    end
    return render_template(template, vars)
end

# =============================================================================
# DEFAULT TEMPLATES
# =============================================================================

const DEFAULT_TEMPLATES = Dict(
        "confirmation_email" => """<!DOCTYPE html>
<html lang=\"de\">
<head>
<meta charset=\"UTF-8\">
<title>Anmeldebestätigung</title>
</head>
<body style=\"font-family: Arial, sans-serif; color: #1f2933; background-color: #ffffff; line-height: 1.6; margin: 0; padding: 0;\">
    <div style=\"padding: 24px;\">
        <p>Liebe*r {first_name},</p>
        <p>vielen Dank für deine Anmeldung zum <strong>{event_name}</strong>!</p>
        <p>Bitte überweise deine Teilnahmegebühr zeitnah und vor Beginn des Probenwochenendes. Deine Übersicht:</p>
        <div style=\"margin: 16px 0; padding: 16px; border: 1px solid #d2d6dc; border-radius: 8px; background-color: #f8fafc;\">
            <p style=\"margin: 0;\">Referenznummer: <strong>{reference_number}</strong></p>
            <p style=\"margin: 8px 0 0;\">Teilnahmebeitrag: <strong>{cost} €</strong></p>
            <p style=\"margin: 8px 0 0;\">Offener Betrag: <strong>{remaining} €</strong></p>
        </div>
        {qr_block}
        <div style=\"margin: 24px 0;\">
            <h3 style=\"margin-bottom: 8px; font-size: 18px;\">Bankverbindung</h3>
            <p style=\"margin: 0; white-space: pre-line;\">{bank_details}</p>
        </div>
        {registration_fields}
        <div style=\"margin: 24px 0;\">
            <p style=\"margin-bottom: 8px;\">Hinweis: Du könntest diese E-Mail erneut erhalten, wenn eine der folgenden Situationen eintritt:</p>
            <ul style=\"margin: 0 0 0 20px; padding: 0;\">
                <li style=\"margin-bottom: 4px;\">du deine Anmeldung aktualisierst,</li>
                <li style=\"margin-bottom: 4px;\">wir die Kostenkalkulation anpassen müssen,</li>
                <li style=\"margin-bottom: 4px;\">wir eine (Teil-)Zahlung verbuchen,</li>
                <li style=\"margin-bottom: 4px;\">oder wir nach angemessener Zeit noch keinen Zahlungseingang sehen.</li>
            </ul>
        </div>
        {additional_info}
        <p style=\"margin-top: 32px;\">Viele Grüße,<br>{sender_name}</p>
    </div>
</body>
</html>
""",

        "payment_confirmation" => """
Liebe/r {first_name},

vielen Dank! Wir haben deine Zahlung erhalten.

Referenznummer: {reference_number}
Bezahlt: {amount_paid} €

Wir freuen uns auf dich!

Viele Grüße,
{sender_name}
"""
)

"""
Ensure default template files exist.
Creates any missing template files with default content.
"""
function ensure_default_templates(templates_dir::AbstractString=TEMPLATES_DIR[])
    mkpath(templates_dir)

    created = String[]

    for (name, content) in DEFAULT_TEMPLATES
        path = joinpath(templates_dir, "$name.txt")
        if !isfile(path)
            write(path, content)
            push!(created, name)
        end
    end

    if !isempty(created)
        @info "Created default templates" templates=created directory=templates_dir
    end

    return created
end

"""
Reset a template to its default content.
"""
function reset_template_to_default(name::AbstractString)
    if !haskey(DEFAULT_TEMPLATES, name)
        error("No default template for: $name")
    end

    path = get_template_path(name)
    write(path, DEFAULT_TEMPLATES[name])
    @info "Reset template to default" name=name
end

"""
Get the list of available placeholders for a template type.
"""
function get_template_placeholders(template_type::AbstractString)
    placeholders = Dict(
        "confirmation_email" => [
            "first_name", "last_name", "event_name", "reference_number",
            "cost", "remaining", "registration_fields", "bank_details",
            "qr_block", "additional_info", "sender_name"
        ],
        "payment_confirmation" => [
            "first_name", "last_name", "event_name", "reference_number",
            "amount_paid", "sender_name"
        ],
    )

    return get(placeholders, template_type, String[])
end

"""
Format registration fields as a nice list for email display.
Takes a Dict of field names and values, returns formatted string.

Optionally filter out fields that should be excluded (like internal IDs).
"""
function format_registration_fields(fields::Dict;
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

end # module
