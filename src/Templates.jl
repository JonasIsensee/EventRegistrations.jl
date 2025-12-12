module Templates

using Mustache

export load_template, get_template_path, list_templates
export render_template, ensure_default_templates, escape_html

# Default templates directory (user editable)
const TEMPLATES_DIR = Ref{String}("config/templates")

# Packaged default templates (read-only) used to seed missing user templates
const PACKAGE_TEMPLATES_DIR = normpath(joinpath(@__DIR__, "..", "config", "templates"))

# Default template names we manage
const DEFAULT_TEMPLATE_FILES = [
    "registration_confirmation",
    "confirmation_email",
    "payment_confirmation",
]

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
    # Respect explicit extensions
    if !isempty(splitext(name)[2])
        return joinpath(TEMPLATES_DIR[], name)
    end

    # Use Mustache templates only
    return joinpath(TEMPLATES_DIR[], "$name.mustache")
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

    names = String[]
    for f in readdir(dir)
        if endswith(f, ".mustache")
            push!(names, splitext(f)[1])
        end
    end
    return names
end

"""
Render a template by replacing placeholders with values.

Placeholders are in the format {name} and are replaced with corresponding
values from the `vars` dictionary.

Example:
    render_template("Hello {name}!", Dict("name" => "World"))
    # Returns: "Hello World!"
"""
function render_template(template::AbstractString, vars::AbstractDict)
    # Mustache escapes HTML by default for double-brace placeholders;
    # use triple braces in templates for pre-escaped HTML fragments.
    return Mustache.render(template, vars)
end

"""
Load and render a template in one call.
"""
function load_and_render(name::AbstractString, vars::AbstractDict)
    template = load_template(name)
    if template === nothing
        return nothing
    end
    return render_template(template, vars)
end

# =============================================================================
# DEFAULT TEMPLATES
# =============================================================================

"""
Ensure default template files exist by copying packaged defaults into the
configured templates directory if they are missing. Packaged defaults live in
`config/templates` alongside the source code; users are expected to edit the
copies in their configured template directory.
"""
function ensure_default_templates(templates_dir::AbstractString=TEMPLATES_DIR[])
    mkpath(templates_dir)

    created = String[]

    for name in DEFAULT_TEMPLATE_FILES
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
Get the list of available placeholders for a template type.
"""
function get_template_placeholders(template_type::AbstractString)
    placeholders = Dict(
        "registration_confirmation" => [
            "first_name", "last_name", "event_name", "reference_number",
            "registration_fields", "additional_info", "sender_name"
        ],
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

end # module
