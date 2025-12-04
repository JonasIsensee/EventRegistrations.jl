module ReferenceNumbers

export generate_reference_number, parse_reference_number, extract_reference_candidates

"""
Generate a unique reference number for a person-event combination.

Format: EVT-XXX where:
- EVT is derived from event_id (first 3-4 chars, alphanumeric only)
- XXX is a unique 3-digit number based on registration ID

Example: PWE26-042

The reference number is:
- Human-readable and easy to type for bank transfers
- Unique per registration
- Deterministic given registration_id (so resubmissions keep same ref)
"""
function generate_reference_number(event_id::AbstractString, registration_id::Integer)
    # Extract alphanumeric prefix from event_id
    # e.g., "PWE_2026_01" -> "PWE26"
    clean_id = replace(event_id, r"[^A-Za-z0-9]" => "")

    # Take first 3-5 chars, prioritizing letters and significant digits
    prefix = if length(clean_id) >= 5
        uppercase(clean_id[1:5])
    else
        uppercase(clean_id)
    end

    # Ensure minimum length
    if length(prefix) < 3
        prefix = rpad(prefix, 3, 'X')
    end

    # Format: PREFIX-NNN (3-digit zero-padded registration ID)
    return "$(prefix)-$(lpad(registration_id, 3, '0'))"
end

"""
Parse a reference number back to its components.
Returns (prefix, id) or nothing if invalid.
"""
function parse_reference_number(ref::AbstractString)
    m = match(r"^([A-Z0-9]+)-(\d+)$", uppercase(strip(ref)))
    if m === nothing
        return nothing
    end
    
    prefix = m.captures[1]
    id = parse(Int, m.captures[2])
    
    return (prefix=prefix, id=id)
end

"""
Find reference number in a text string (e.g., bank transfer reference).
Returns the first matching reference number or nothing.
"""
function find_reference_in_text(text::AbstractString)
    # Look for patterns like ABC-123 or ABC123 (3-digit format)
    m = match(r"([A-Z]{2,5}\d{0,2})-?(\d{3,4})", uppercase(text))
    if m !== nothing
        prefix = m.captures[1]
        num = m.captures[2]
        return "$(prefix)-$(lpad(num, 3, '0'))"
    end
    return nothing
end

"""
Extract potential reference numbers from bank transfer text.
Returns a list of candidates with confidence scores.
"""
function extract_reference_candidates(text::AbstractString)
    candidates = Tuple{String, Float64}[]
    text_upper = uppercase(text)

    # Pattern 1: Exact format PREFIX-NNN (high confidence)
    for m in eachmatch(r"([A-Z]{3,5}\d{0,2})-(\d{3})", text_upper)
        ref = "$(m.captures[1])-$(m.captures[2])"
        push!(candidates, (ref, 0.95))
    end

    # Pattern 2: Without dash PREFIX NNN (medium-high confidence)
    for m in eachmatch(r"([A-Z]{3,5}\d{0,2})\s+(\d{3})", text_upper)
        ref = "$(m.captures[1])-$(m.captures[2])"
        if ref ∉ first.(candidates)
            push!(candidates, (ref, 0.85))
        end
    end

    # Pattern 3: Concatenated PREFIXNNN (medium confidence)
    for m in eachmatch(r"([A-Z]{3,5})(\d{3,4})", text_upper)
        prefix = m.captures[1]
        num = m.captures[2][1:min(3, length(m.captures[2]))]
        ref = "$(prefix)-$(lpad(num, 3, '0'))"
        if ref ∉ first.(candidates)
            push!(candidates, (ref, 0.70))
        end
    end

    # Sort by confidence
    sort!(candidates, by=x->x[2], rev=true)

    return candidates
end

end # module
