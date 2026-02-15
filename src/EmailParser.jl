module EmailParser

using Dates: Dates, DateTime
using SHA: SHA, sha256

export parse_eml, extract_form_submission, compute_file_hash

# HTML entity decoding map
const HTML_ENTITIES = Dict(
    "&auml;" => "ä", "&Auml;" => "Ä",
    "&ouml;" => "ö", "&Ouml;" => "Ö",
    "&uuml;" => "ü", "&Uuml;" => "Ü",
    "&szlig;" => "ß",
    "&euro;" => "€",
    "&amp;" => "&",
    "&lt;" => "<",
    "&gt;" => ">",
    "&quot;" => "\"",
    "&apos;" => "'",
    "&nbsp;" => " ",
    "&#39;" => "'",
)

"""
Decode HTML entities in a string.
"""
function decode_html_entities(s::AbstractString)
    result = s
    for (entity, char) in HTML_ENTITIES
        result = replace(result, entity => char)
    end
    # Handle numeric entities
    result = replace(result, r"&#(\d+);" => m -> string(Char(parse(Int, match(r"&#(\d+);", m).captures[1]))))
    result = replace(result, r"&#x([0-9A-Fa-f]+);" => m -> string(Char(parse(Int, match(r"&#x([0-9A-Fa-f]+);", m).captures[1], base=16))))
    return result
end

"""
Parse a single .eml file and return its components.
Handles nested MIME multipart content.
"""
function parse_eml(filepath::AbstractString)
    content = read(filepath, String)
    return parse_eml_content(content)
end

"""
Parse email content string.
"""
function parse_eml_content(content::AbstractString)
    headers = Dict{String, String}()
    body_html = ""

    # Split headers from body
    header_end = findfirst("\r\n\r\n", content)
    if header_end === nothing
        header_end = findfirst("\n\n", content)
    end

    if header_end === nothing
        return (headers=headers, body_html=body_html)
    end

    header_section = content[1:header_end.start-1]
    body_section = content[header_end.stop+1:end]

    headers = parse_headers(header_section)

    # Get content type
    content_type = get(headers, "content-type", "text/plain")

    # Parse body based on content type
    body_html = extract_html_from_body(body_section, content_type)

    return (headers=headers, body_html=body_html)
end

"""
Recursively extract HTML content from MIME body.
Handles nested multipart structures.
"""
function extract_html_from_body(body::AbstractString, content_type::AbstractString)
    # Check if multipart
    if occursin("multipart", lowercase(content_type))
        # Extract boundary
        boundary_match = match(r"boundary\s*=\s*\"?([^\";\s\r\n]+)\"?", content_type)
        if boundary_match === nothing
            return ""
        end

        boundary = boundary_match.captures[1]
        return extract_html_from_multipart(body, boundary)
    elseif occursin("text/html", lowercase(content_type))
        # Direct HTML content
        transfer_encoding = ""
        if occursin("quoted-printable", lowercase(content_type))
            return decode_quoted_printable(body)
        elseif occursin("base64", lowercase(content_type))
            return try
                String(Base.base64decode(strip(replace(body, r"[\r\n]" => ""))))
            catch
                body
            end
        else
            return body
        end
    end

    return ""
end

"""
Extract HTML from multipart content.
Recursively handles nested multipart sections.
"""
function extract_html_from_multipart(body::AbstractString, boundary::AbstractString)
    # Split by boundary
    parts = split(body, "--" * boundary)

    for part in parts
        # Skip empty parts and closing boundary
        stripped = strip(part)
        if isempty(stripped) || startswith(stripped, "--")
            continue
        end

        # Find headers/body split in this part
        part_header_end = findfirst("\r\n\r\n", part)
        if part_header_end === nothing
            part_header_end = findfirst("\n\n", part)
        end

        if part_header_end === nothing
            continue
        end

        part_headers_str = part[1:part_header_end.start-1]
        part_body = part[part_header_end.stop+1:end]

        # Parse part headers
        part_content_type = ""
        part_encoding = ""

        for line in split(part_headers_str, r"\r?\n")
            line_lower = lowercase(line)
            if startswith(line_lower, "content-type:")
                part_content_type = strip(line[14:end])
                # Handle continuation lines
            elseif startswith(line_lower, "content-transfer-encoding:")
                part_encoding = strip(lowercase(line[27:end]))
            elseif !isempty(part_content_type) && (startswith(line, " ") || startswith(line, "\t"))
                # Continuation of content-type header
                part_content_type *= " " * strip(line)
            end
        end

        # Recursively handle nested multipart
        if occursin("multipart", lowercase(part_content_type))
            nested_boundary_match = match(r"boundary\s*=\s*\"?([^\";\s\r\n]+)\"?", part_content_type)
            if nested_boundary_match !== nothing
                nested_boundary = nested_boundary_match.captures[1]
                result = extract_html_from_multipart(part_body, nested_boundary)
                if !isempty(result)
                    return result
                end
            end
        elseif occursin("text/html", lowercase(part_content_type))
            # Found HTML!
            html_content = part_body

            # Decode based on transfer encoding
            if part_encoding == "quoted-printable"
                html_content = decode_quoted_printable(html_content)
            elseif part_encoding == "base64"
                html_content = try
                    String(Base.base64decode(strip(replace(html_content, r"[\r\n]" => ""))))
                catch
                    html_content
                end
            end

            return strip(html_content)
        end
    end

    return ""
end

function parse_headers(header_section::AbstractString)
    headers = Dict{String, String}()
    current_key = ""
    current_value = ""

    for line in split(header_section, r"\r?\n")
        if isempty(line)
            continue
        elseif startswith(line, " ") || startswith(line, "\t")
            # Continuation of previous header (folded header)
            current_value *= " " * strip(line)
        else
            # Save previous header if exists
            if !isempty(current_key)
                headers[lowercase(current_key)] = decode_mime_header(strip(current_value))
            end
            # Parse new header
            colon_idx = findfirst(':', line)
            if colon_idx !== nothing
                current_key = line[1:colon_idx-1]
                current_value = line[colon_idx+1:end]
            end
        end
    end

    # Don't forget the last header
    if !isempty(current_key)
        headers[lowercase(current_key)] = decode_mime_header(strip(current_value))
    end

    return headers
end

function decode_mime_header(s::AbstractString)
    result = s
    for m in eachmatch(r"=\?([^?]+)\?[Qq]\?([^?]+)\?=", result)
        encoded = m.captures[2]
        decoded = decode_quoted_printable(replace(encoded, "_" => " "))
        result = replace(result, m.match => decoded)
    end
    for m in eachmatch(r"=\?([^?]+)\?[Bb]\?([^?]+)\?=", result)
        encoded = m.captures[2]
        decoded = try
            String(Base.base64decode(encoded))
        catch
            encoded
        end
        result = replace(result, m.match => decoded)
    end
    return result
end

function decode_quoted_printable(s::AbstractString)
    result = replace(s, r"=\r?\n" => "")
    result = replace(result, r"=([0-9A-Fa-f]{2})" => m -> string(Char(parse(Int, m[2:3], base=16))))
    return result
end

"""
Extract form submission data from HTML content.
Returns nothing if no form submission found.
"""
function extract_form_submission(html::AbstractString)
    # Look for the registration table pattern
    event_match = match(r"<th[^>]*>\s*Anmeldung:\s*([^<]+)</th>", html)

    if event_match === nothing
        return nothing
    end

    event_id = strip(decode_html_entities(event_match.captures[1]))

    # Extract all field-value pairs
    fields = Dict{String, String}()

    for m in eachmatch(r"<td[^>]*class=\"label\"[^>]*>([^<]*)</td>\s*<td[^>]*>([^<]*)</td>", html)
        field_name = strip(decode_html_entities(m.captures[1]))
        field_value = strip(decode_html_entities(m.captures[2]))

        field_name = rstrip(field_name, ':')
        field_name = strip(field_name)

        if !isempty(field_name)
            fields[field_name] = field_value
        end
    end

    if isempty(fields)
        return nothing
    end

    # Extract standard fields
    email = get(fields, "E-Mail", get(fields, "Email", ""))
    first_name = get(fields, "Vorname", "")
    last_name = get(fields, "Nachname", "")

    return (
        event_id = event_id,
        email = email,
        first_name = first_name,
        last_name = last_name,
        fields = fields
    )
end

"""
Compute a unique hash for an email file.
"""
function compute_file_hash(filepath::AbstractString)
    return bytes2hex(sha256(read(filepath)))
end

"""
Parse email date string to DateTime
"""
function parse_email_date(date_str::AbstractString)
    cleaned = replace(date_str, r"\s+[+-]\d{4}.*$" => "")
    cleaned = replace(cleaned, r"\s+\([^)]+\)$" => "")
    cleaned = strip(cleaned)

    try
        m = match(r"(\d{1,2})\s+(\w{3})\s+(\d{4})\s+(\d{2}):(\d{2}):(\d{2})", cleaned)
        if m !== nothing
            months = Dict("Jan"=>1, "Feb"=>2, "Mar"=>3, "Apr"=>4, "May"=>5, "Jun"=>6,
                         "Jul"=>7, "Aug"=>8, "Sep"=>9, "Oct"=>10, "Nov"=>11, "Dec"=>12)
            day = parse(Int, m.captures[1])
            month = months[m.captures[2]]
            year = parse(Int, m.captures[3])
            hour = parse(Int, m.captures[4])
            minute = parse(Int, m.captures[5])
            second = parse(Int, m.captures[6])
            return DateTime(year, month, day, hour, minute, second)
        end
    catch
    end

    return nothing
end

function is_valid_email(email::String)::Bool
    pattern = r"^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$"
    return occursin(pattern, email)
end

using Dates

end # module
