module Templates

export load_template, get_template_path, list_templates
export render_template, ensure_default_templates

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
    "confirmation_email" => """
Liebe/r {first_name},

vielen Dank für deine Anmeldung zum {event_name}!

Hier sind deine Anmeldedaten:

Referenznummer: {reference_number}
Zu zahlen: {cost} €

Bitte überweise den Betrag auf folgendes Konto:
{bank_details}

Verwendungszweck: {reference_number}

WICHTIG: Bitte gib unbedingt die Referenznummer als Verwendungszweck an,
damit wir deine Zahlung zuordnen können.

{additional_info}

Bei Fragen kannst du dich gerne an uns wenden.

Viele Grüße,
{sender_name}
""",

    "payment_reminder" => """
Liebe/r {first_name},

wir möchten dich freundlich daran erinnern, dass die Zahlung für {event_name} 
noch aussteht.

Referenznummer: {reference_number}
Offener Betrag: {remaining} €

Bitte überweise den Betrag auf folgendes Konto:
{bank_details}

Verwendungszweck: {reference_number}

Falls du bereits überwiesen hast, ignoriere bitte diese Nachricht.
Es kann einige Tage dauern, bis die Zahlung bei uns eingeht.

Bei Fragen kannst du dich gerne an uns wenden.

Viele Grüße,
{sender_name}
""",

    "payment_confirmation" => """
Liebe/r {first_name},

vielen Dank! Wir haben deine Zahlung für {event_name} erhalten.

Referenznummer: {reference_number}
Bezahlt: {amount_paid} €

Wir freuen uns auf dich!

Viele Grüße,
{sender_name}
""",

    "subsidy_notification" => """
Liebe/r {first_name},

gute Nachrichten! Dir wurde ein Zuschuss für {event_name} gewährt.

Referenznummer: {reference_number}
Zuschuss: {subsidy_amount} €
Grund: {subsidy_reason}

Dein neuer zu zahlender Betrag: {remaining} €

Bitte überweise den verbleibenden Betrag auf folgendes Konto:
{bank_details}

Verwendungszweck: {reference_number}

Bei Fragen kannst du dich gerne an uns wenden.

Viele Grüße,
{sender_name}
""",

    "registration_update" => """
Liebe/r {first_name},

wir haben deine aktualisierte Anmeldung für {event_name} erhalten.

Referenznummer: {reference_number} (unverändert)
Neuer Betrag: {cost} €

{cost_change_note}

Bei Fragen kannst du dich gerne an uns wenden.

Viele Grüße,
{sender_name}
""",
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
            "cost", "bank_details", "additional_info", "sender_name"
        ],
        "payment_reminder" => [
            "first_name", "last_name", "event_name", "reference_number",
            "remaining", "bank_details", "sender_name"
        ],
        "payment_confirmation" => [
            "first_name", "last_name", "event_name", "reference_number",
            "amount_paid", "sender_name"
        ],
        "subsidy_notification" => [
            "first_name", "last_name", "event_name", "reference_number",
            "subsidy_amount", "subsidy_reason", "remaining", "bank_details", "sender_name"
        ],
        "registration_update" => [
            "first_name", "last_name", "event_name", "reference_number",
            "cost", "cost_change_note", "sender_name"
        ],
    )
    
    return get(placeholders, template_type, String[])
end

end # module
