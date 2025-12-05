module ReferenceNumbers

export generate_reference_number, parse_reference_number, extract_reference_candidates

"""
Generate a unique reference number for a person-event combination.

Format: <event_id>_<XXX> where:
- event_id is the full event ID (unchanged)
- XXX is a unique 3-digit number based on registration ID

Example: PWE_2026_01_001

The reference number is:
- Human-readable and unambiguous
- Unique per registration
- Deterministic given registration_id (so resubmissions keep same ref)
"""
function generate_reference_number(event_id::AbstractString, registration_id::Integer)
    # Use the full event_id as-is (no transformation)
    # Format: EVENT_ID_NNN (3-digit zero-padded registration ID)
    return "$(event_id)_$(lpad(registration_id, 3, '0'))"
end

"""
Parse a reference number back to its components.
Returns (event_id, id) or nothing if invalid.

New format: EVENT_ID_XXX (e.g., PWE_2026_01_001)
"""
function parse_reference_number(ref::AbstractString)
    # Match the pattern: anything followed by underscore and 3 digits
    # e.g., "PWE_2026_01_001" -> event_id="PWE_2026_01", id=1
    m = match(r"^(.+)_(\d{3})$", strip(ref))
    if m === nothing
        return nothing
    end

    event_id = m.captures[1]
    id = parse(Int, m.captures[2])

    return (event_id=event_id, id=id)
end

"""
Find reference number in a text string (e.g., bank transfer reference).
Returns the first matching reference number or nothing.

New format: EVENT_ID_XXX (e.g., PWE_2026_01_001)
Handles variations like spaces or dashes instead of underscores.
"""
function find_reference_in_text(text::AbstractString)
    # Look for patterns like ABC_2026_01_123 or ABC-2026-01-123 or "ABC 2026 01 123"
    # Match: alphanumeric sequence with separators, ending with 3 digits
    text_upper = uppercase(strip(text))

    # Pattern 1: With underscores (standard format)
    m = match(r"([A-Z][A-Z0-9_]+)_(\d{3})\b", text_upper)
    if m !== nothing
        return "$(m.captures[1])_$(m.captures[2])"
    end

    # Pattern 2: With dashes (normalize to underscores)
    m = match(r"([A-Z][A-Z0-9\-]+)-(\d{3})\b", text_upper)
    if m !== nothing
        prefix = replace(m.captures[1], "-" => "_")
        return "$(prefix)_$(m.captures[2])"
    end

    # Pattern 3: With spaces (normalize to underscores)
    m = match(r"([A-Z][A-Z0-9\s]+)\s(\d{3})\b", text_upper)
    if m !== nothing
        prefix = replace(strip(m.captures[1]), r"\s+" => "_")
        return "$(prefix)_$(m.captures[2])"
    end

    return nothing
end

"""
Extract potential reference numbers from bank transfer text.
Returns a list of candidates with confidence scores.

New format: EVENT_ID_XXX (e.g., PWE_2026_01_001)
Handles variations with dashes, spaces, or underscores as separators.
"""
function extract_reference_candidates(text::AbstractString)
    candidates = Tuple{String, Float64}[]
    text_upper = uppercase(text)

    # Pattern 1: Standard format with underscores EVENT_ID_NNN (high confidence)
    # Matches: PWE_2026_01_001, ABC_2024_123, etc.
    for m in eachmatch(r"([A-Z][A-Z0-9_]+)_(\d{3})\b", text_upper)
        ref = "$(m.captures[1])_$(m.captures[2])"
        push!(candidates, (ref, 0.95))
    end

    # Pattern 2: Format with dashes instead of underscores (medium-high confidence)
    # Matches: PWE-2026-01-001, normalize to PWE_2026_01_001
    for m in eachmatch(r"([A-Z][A-Z0-9\-]+)-(\d{3})\b", text_upper)
        prefix = replace(m.captures[1], "-" => "_")
        ref = "$(prefix)_$(m.captures[2])"
        if ref ∉ first.(candidates)
            push!(candidates, (ref, 0.85))
        end
    end

    # Pattern 3: Format with mixed separators (medium confidence)
    # Matches: "PWE 2026 01 001" -> PWE_2026_01_001
    for m in eachmatch(r"([A-Z][A-Z0-9\s\-_]+)\s+(\d{3})\b", text_upper)
        prefix = replace(m.captures[1], r"[\s\-]" => "_")
        prefix = replace(prefix, r"_+" => "_")  # Collapse multiple underscores
        prefix = rstrip(prefix, '_')  # Remove trailing underscore
        ref = "$(prefix)_$(m.captures[2])"
        if ref ∉ first.(candidates)
            push!(candidates, (ref, 0.75))
        end
    end

    # Sort by confidence
    sort!(candidates, by=x->x[2], rev=true)

    return candidates
end

end # module
