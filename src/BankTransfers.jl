module BankTransfers

using DBInterface: DBInterface
using Dates: Dates, Date, now, today
using DuckDB: DuckDB
using JSON: JSON
using SHA: SHA
using StringEncodings

# Import from parent module
import ..EventRegistrations: with_transaction, log_financial_transaction!, EmailConfig

# Import from parent module's submodules
using ..ReferenceNumbers
using ..ConfirmationEmails: queue_payment_confirmation!

export import_bank_csv!, match_transfers!, get_unmatched_transfers
export manual_match!, get_payment_status, get_payment_summary
export get_payment_history, get_payment_discrepancies
export get_near_miss_transfers, get_uncertain_matches

"""
Import bank transfers from a CSV file.
Only adds new transfers (detects duplicates by hash).

The CSV format is auto-detected, but common German bank formats are supported.
Required columns (flexible naming):
- Date (Buchungstag, Datum, Date, Valuta)
- Amount (Betrag, Amount)
- Reference (Verwendungszweck, Reference, Beschreibung)
- Sender name (Auftraggeber, Name, Beguenstigter/Zahlungspflichtiger)
- Sender IBAN (optional)
"""
function import_bank_csv!(db::DuckDB.DB, csv_path::AbstractString;
                          delimiter::Char=';',
                          decimal_comma::Bool=true)

    filename = basename(csv_path)

    # Read CSV with flexible handling
    lines = readlines(csv_path, enc"iso8859-1")

    # Find header row (might not be first line)
    header_idx = 1
    for (i, line) in enumerate(lines)
        lower_line = lowercase(line)
        if occursin("buchungstag", lower_line) ||
           occursin("datum", lower_line) ||
           occursin("date", lower_line) ||
           occursin("betrag", lower_line)
            header_idx = i
            break
        end
    end

    # Parse header
    header = split(lines[header_idx], delimiter)
    header = [strip(h, ['"', ' ']) for h in header]

    # Map column names to indices
    col_map = detect_columns(header)

    if col_map[:date] == 0 || col_map[:amount] == 0
        error("Could not detect required columns (date, amount) in CSV")
    end

    # Process data rows
    new_count = 0
    skip_count = 0

    for line in lines[header_idx+1:end]
        # Skip empty lines
        if isempty(strip(line))
            continue
        end

        # Parse CSV line (handling quoted fields)
        fields = parse_csv_line(line, delimiter)

        # Extract values
        date_str = col_map[:date] > 0 ? strip(fields[col_map[:date]], '"') : ""
        amount_str = col_map[:amount] > 0 ? strip(fields[col_map[:amount]], '"') : ""
        reference = col_map[:reference] > 0 ? strip(fields[col_map[:reference]], '"') : ""
        sender_name = col_map[:sender_name] > 0 ? strip(fields[col_map[:sender_name]], '"') : ""
        sender_iban = col_map[:sender_iban] > 0 ? strip(fields[col_map[:sender_iban]], '"') : ""
        kundenreferenz = col_map[:kundenreferenz] > 0 ? strip(fields[col_map[:kundenreferenz]], '"') : ""

        reference = reference * " " * kundenreferenz
        # Parse date
        transfer_date = parse_date(date_str)
        if transfer_date === nothing
            continue
        end

        # Parse amount
        if decimal_comma
            amount_str = replace(amount_str, "." => "")
            amount_str = replace(amount_str, "," => ".")
        end
        amount_str = replace(amount_str, r"[^\d.-]" => "")
        amount = parse(Float64, amount_str)

        # Create hash for duplicate detection
        hash_input = "$date_str|$amount_str|$reference|$sender_name"
        transfer_hash = bytes2hex(SHA.sha256(hash_input))
        # Check if already exists
        existing = DBInterface.execute(db,
            "SELECT COUNT(*) FROM bank_transfers WHERE transfer_hash = ?",
            [transfer_hash])
        if first(collect(existing))[1] > 0
            skip_count += 1
            continue
        end

        # Store raw data
        raw_data = Dict(zip(header, fields))
        raw_json = JSON.json(raw_data)

        # Insert transfer
        with_transaction(db) do
            DBInterface.execute(db, """
                INSERT INTO bank_transfers (id, transfer_hash, transfer_date, amount,
                                            sender_name, sender_iban, reference_text,
                                            raw_data, source_file, imported_at)
                VALUES (nextval('transfer_id_seq'), ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [transfer_hash, transfer_date, amount, sender_name, sender_iban,
                reference, raw_json, filename, now()])
        end
        new_count += 1
    end  # End for loop

    @info "Imported bank transfers" new=new_count skipped=skip_count file=filename

    return (new=new_count, skipped=skip_count)
end

"""
Detect column indices from header names.
"""
function detect_columns(header::Vector)
    col_map = Dict{Symbol, Int}(
        :date => 0,
        :amount => 0,
        :reference => 0,
        :sender_name => 0,
        :sender_iban => 0,
        :kundenreferenz => 0,
    )

    for (i, col) in enumerate(header)
        col_lower = lowercase(col)

        if col_map[:date] == 0 &&
           (occursin("buchungstag", col_lower) || occursin("datum", col_lower) ||
            occursin("date", col_lower) || occursin("valuta", col_lower))
            col_map[:date] = i
        elseif (col_map[:amount] == 0 &&
               (occursin("betrag", col_lower) || occursin("amount", col_lower) ||
                occursin("umsatz", col_lower))) || "betrag"==col_lower
            col_map[:amount] = i
        elseif col_map[:reference] == 0 &&
               (occursin("verwendungszweck", col_lower) || occursin("reference", col_lower) ||
                occursin("beschreibung", col_lower))
            col_map[:reference] = i
        elseif col_map[:sender_name] == 0 &&
               (occursin("auftraggeber", col_lower) || occursin("name", col_lower) ||
                occursin("beguenstigter", col_lower) || occursin("zahlungspflichtiger", col_lower))
            col_map[:sender_name] = i
        elseif col_map[:sender_iban] == 0 &&
               (occursin("iban", col_lower) || occursin("kontonummer", col_lower))
            col_map[:sender_iban] = i
        elseif col_map[:kundenreferenz] == 0 &&
                (occursin("kundenreferenz", col_lower))
            col_map[:kundenreferenz] = i
        end
    end

    return col_map
end

"""
Parse a CSV line handling quoted fields.
"""
function parse_csv_line(line::AbstractString, delimiter::Char)
    fields = String[]
    buf = IOBuffer()
    in_quotes = false

    for char in line
        if char == '"'
            in_quotes = !in_quotes
        elseif char == delimiter && !in_quotes
            push!(fields, String(take!(buf)))
        else
            write(buf, char)
        end
    end
    push!(fields, String(take!(buf)))

    return fields
end

"""
Parse various date formats.
"""
function parse_date(date_str::AbstractString)
    date_str = strip(date_str)

    # Try different formats
    formats = [
        r"^(\d{2})\.(\d{2})\.(\d{4})$",  # DD.MM.YYYY
        r"^(\d{2})\.(\d{2})\.(\d{2})$",   # DD.MM.YY
        r"^(\d{4})-(\d{2})-(\d{2})$",     # YYYY-MM-DD
        r"^(\d{2})/(\d{2})/(\d{4})$",     # DD/MM/YYYY
    ]

    # DD.MM.YYYY
    m = match(formats[1], date_str)
    if m !== nothing
        d, mo, y = parse(Int, m.captures[1]), parse(Int, m.captures[2]), parse(Int, m.captures[3])
        return Date(y, mo, d)
    end

    # DD.MM.YY
    m = match(formats[2], date_str)
    if m !== nothing
        d, mo, y = parse(Int, m.captures[1]), parse(Int, m.captures[2]), parse(Int, m.captures[3])
        y += y > 50 ? 1900 : 2000
        return Date(y, mo, d)
    end

    # YYYY-MM-DD
    m = match(formats[3], date_str)
    if m !== nothing
        y, mo, d = parse(Int, m.captures[1]), parse(Int, m.captures[2]), parse(Int, m.captures[3])
        return Date(y, mo, d)
    end

    return nothing
end

"""
Calculate name similarity score between two names.
Returns a score from 0.0 to 1.0.
"""
function name_similarity(name1::AbstractString, name2::AbstractString)
    n1 = lowercase(strip(name1))
    n2 = lowercase(strip(name2))

    # Exact match
    if n1 == n2
        return 1.0
    end

    # Empty strings
    if isempty(n1) || isempty(n2)
        return 0.0
    end

    # One is a prefix of the other (nicknames, abbreviations)
    if startswith(n1, n2) || startswith(n2, n1)
        return 0.8
    end

    # Check if one contains the other (partial match)
    if occursin(n2, n1) || occursin(n1, n2)
        return 0.6
    end

    return 0.0
end

"""
Check if name matches between transfer and registration.
Returns (matches, confidence) tuple.

This is strict to avoid false positives like matching two people named "Amelie"
with different last names.
"""
function check_name_match(sender_name::AbstractString, reference_text::AbstractString,
                          first_name::AbstractString, last_name::AbstractString)
    # Extract name candidates from both sender name and reference text
    cleaned_sender = replace(lowercase(something(sender_name, "")), r"[^a-zäöüß\s]" => " ")
    sender_parts = split(cleaned_sender)
    reference_names = extract_name_candidates(something(reference_text, ""))

    fn_lower = lowercase(something(first_name, ""))
    ln_lower = lowercase(something(last_name, ""))

    # Scores for first and last name
    first_name_score = 0.0
    last_name_score = 0.0

    # Check sender name parts against registration names
    for part in sender_parts
        if length(part) < 2  # Skip single letters and empty
            continue
        end
        first_name_score = max(first_name_score, name_similarity(part, fn_lower))
        last_name_score = max(last_name_score, name_similarity(part, ln_lower))
    end

    # Check names extracted from reference text
    for name_candidate in reference_names
        first_name_score = max(first_name_score, name_similarity(name_candidate, fn_lower))
        last_name_score = max(last_name_score, name_similarity(name_candidate, ln_lower))
    end

    # STRICT MATCHING: Require BOTH first AND last name to match reasonably well
    # This prevents matching "Amelie Schmidt" with "Amelie Mueller" just based on first name
    if first_name_score >= 0.8 && last_name_score >= 0.8
        return (true, (first_name_score + last_name_score) / 2)
    end

    return (false, 0.0)
end

"""
Detect if there's a potential name mismatch in the reference text.
Returns true if names are found in reference text but DON'T match the registration.

This is used to identify cases where someone transfers for another person but
includes the wrong name or their own name instead of the beneficiary's name.

Example: Reference text contains "Alice Anderson" but registration is for "Bob Brown"
with reference PWE-2026-01-003. This indicates a potential problem that needs review.
"""
function has_conflicting_name(reference_text::AbstractString,
                             first_name::AbstractString, last_name::AbstractString)
    reference_names = extract_name_candidates(something(reference_text, ""))

    # If no names found in reference text, there's no conflict
    if isempty(reference_names)
        return false
    end

    fn_lower = lowercase(something(first_name, ""))
    ln_lower = lowercase(something(last_name, ""))

    # Check if ANY extracted name matches the registration
    # We need at least partial matches for both first and last name
    best_first_score = 0.0
    best_last_score = 0.0

    for name_candidate in reference_names
        best_first_score = max(best_first_score, name_similarity(name_candidate, fn_lower))
        best_last_score = max(best_last_score, name_similarity(name_candidate, ln_lower))
    end

    # If we found names but they don't match well (< 0.6 threshold), it's a conflict
    # We use 0.6 instead of 0.8 to be more lenient (substring matches count)
    has_some_first_match = best_first_score >= 0.6
    has_some_last_match = best_last_score >= 0.6

    # Conflict if names exist but neither first nor last name match reasonably
    return !has_some_first_match || !has_some_last_match
end

"""
Attempt to automatically match unmatched transfers to registrations.

Matching strategy (in order of precedence):
1. Exact reference + amount + name → auto (0.99 confidence)
2a. Exact reference + amount (no name in text) → auto (0.95 confidence)
2b. Exact reference + amount but CONFLICTING name → auto_uncertain (0.65 confidence)
3. Off-by-one reference + amount + name → auto_uncertain (0.75 confidence)
4. Exact reference + amount mismatch → warn and skip (possible typo)
5. Name match (both first AND last) + amount → auto_name (0.7 confidence)
6. Everything else → unmatched (requires manual review)

This conservative approach reduces false positives, especially when:
- People have the same first name but different last names
- Someone transfers for another person but includes wrong name in reference text
- Off-by-one typos in reference numbers
"""
function match_transfers!(db::DuckDB.DB; event_id::Union{String,Nothing}=nothing,
                          email_cfg::Union{EmailConfig,Nothing}=nothing)
    # Get unmatched transfers
    transfers = DBInterface.execute(db, """
        SELECT bt.id, bt.reference_text, bt.amount, bt.sender_name
        FROM bank_transfers bt
        LEFT JOIN payment_matches pm ON pm.transfer_id = bt.id
        WHERE pm.id IS NULL
    """)

    matched = 0
    unmatched_list = []

    # Wrap all matching operations in a transaction (safe for nesting)
    for transfer in transfers
        transfer_id, reference_text, amount, sender_name = transfer
        # Convert amount to Float64 to avoid DuckDB binding issues with FixedDecimal
        amount = Float64(amount)

        # Try to find reference number in reference text
        ref_text = something(reference_text, "")
        candidates = extract_reference_candidates(ref_text)

        match_found = false
        best_match = nothing
        best_confidence = 0.0

        # Strategy 1 & 2: Exact reference number matching
        for ref_candidate in candidates
            # Look up registration
            reg_query = event_id === nothing ?
                "SELECT id, event_id, computed_cost, first_name, last_name, email FROM registrations WHERE reference_number = ?" :
                "SELECT id, event_id, computed_cost, first_name, last_name, email FROM registrations WHERE reference_number = ? AND event_id = ?"

            params = event_id === nothing ? [ref_candidate] : [ref_candidate, event_id]
            result = DBInterface.execute(db, reg_query, params)
            rows = collect(result)

            if !isempty(rows)
                reg_id, _evt_id, expected_cost, first_name, last_name, _email = rows[1]
                expected_cost_val = expected_cost === nothing ? nothing : Float64(expected_cost)

                # Check amount matches (within tolerance) if cost is available
                amount_match = expected_cost_val === nothing ? false : abs(amount - expected_cost_val) < 0.01

                # Check if names also match (additional validation)
                name_matches, _name_score = check_name_match(
                    something(sender_name, ""), ref_text,
                    something(first_name, ""), something(last_name, "")
                )

                if amount_match
                    if name_matches
                        # Strategy 1: Reference + Amount + Name = HIGHEST confidence
                        final_confidence = 0.99
                        match_type = "auto"
                        notes = "Matched by reference + amount + name"
                    else
                        # Check if there's a conflicting name in the reference text
                        # (names found but don't match the registration)
                        has_conflict = has_conflicting_name(
                            ref_text,
                            something(first_name, ""), something(last_name, "")
                        )

                        if has_conflict
                            # Strategy 2b: Reference + Amount but CONFLICTING name
                            # This is suspicious - likely wrong reference or proxy payment error
                            # Lower confidence to require manual review
                            final_confidence = 0.65
                            match_type = "auto_uncertain"
                            notes = "Reference + amount match, but name in text doesn't match registration - needs review"
                            @warn "Potential name mismatch in transfer" reference=ref_candidate expected="$(first_name) $(last_name)" transfer_text=ref_text
                        else
                            # Strategy 2a: Reference + Amount (no name in text)
                            final_confidence = 0.95
                            match_type = "auto"
                            notes = "Matched by reference + amount (name not confirmed)"
                        end
                    end

                    if final_confidence > best_confidence
                        best_confidence = final_confidence
                        best_match = (
                            reg_id=reg_id,
                            match_type=match_type,
                            confidence=final_confidence,
                            reference=ref_candidate,
                            notes=notes
                        )
                    end
                elseif expected_cost_val === nothing && name_matches
                    # No cost configured, but strong name + reference match: allow low confidence auto
                    final_confidence = 0.70
                    match_type = "auto_uncertain"
                    notes = "Matched by reference + name (cost missing)"
                    if final_confidence > best_confidence
                        best_confidence = final_confidence
                        best_match = (
                            reg_id=reg_id,
                            match_type=match_type,
                            confidence=final_confidence,
                            reference=ref_candidate,
                            notes=notes
                        )
                    end
                else
                    # Reference found but amount doesn't match - suspicious, warn user
                    @warn "Reference found but amount mismatch - possible typo" reference=ref_candidate expected=expected_cost actual=amount
                end
            end
        end

        # Strategy 3: Off-by-one reference number detection (typos)
        # Only attempt if we didn't find an exact match
        if best_match === nothing && !isempty(candidates)
            for ref_candidate in candidates
                # Parse the reference to get event_id and number
                parsed = parse_reference_number(ref_candidate)
                if parsed !== nothing
                    event_part, num = parsed.event_id, parsed.id
                    if event_id !== nothing && event_part != event_id
                        continue  # do not cross events when caller scoped the event
                    end

                    # Check ±1 from the reference number
                    for offset in [-1, 1]
                        nearby_num = num + offset
                        if nearby_num >= 1 && nearby_num <= 999  # Valid range
                            nearby_ref = generate_reference_number(event_part, nearby_num)

                            # Look up the nearby registration
                            reg_query = event_id === nothing ?
                                "SELECT id, event_id, computed_cost, first_name, last_name, email FROM registrations WHERE reference_number = ?" :
                                "SELECT id, event_id, computed_cost, first_name, last_name, email FROM registrations WHERE reference_number = ? AND event_id = ?"

                            params = event_id === nothing ? [nearby_ref] : [nearby_ref, event_id]
                            result = DBInterface.execute(db, reg_query, params)
                            rows = collect(result)

                            if !isempty(rows)
                                reg_id, _evt_id, expected_cost, first_name, last_name, _email = rows[1]
                                expected_cost_val = expected_cost === nothing ? nothing : Float64(expected_cost)

                                # Check amount AND name match (both required for off-by-one)
                                amount_match = expected_cost_val === nothing ? false : abs(amount - expected_cost_val) < 0.01
                                name_matches, _name_score = check_name_match(
                                    something(sender_name, ""), ref_text,
                                    something(first_name, ""), something(last_name, "")
                                )

                                if amount_match && name_matches
                                    # Off-by-one with amount + name confirmation
                                    final_confidence = 0.75
                                    match_type = "auto_uncertain"
                                    notes = "Off-by-one typo detected: typed $(ref_candidate), matched $(nearby_ref) via amount+name"

                                    if final_confidence > best_confidence
                                        best_confidence = final_confidence
                                        best_match = (
                                            reg_id=reg_id,
                                            match_type=match_type,
                                            confidence=final_confidence,
                                            reference=nearby_ref,
                                            notes=notes
                                        )
                                    end

                                    @info "Detected off-by-one typo" typed=ref_candidate actual=nearby_ref name="$(first_name) $(last_name)"
                                end
                            end
                        end
                    end
                end
            end
        end

        # If we found a reference-based match (exact or off-by-one), use it
        if best_match !== nothing && best_confidence >= 0.60
            match_id = with_transaction(db) do
                DBInterface.execute(db, """
                    INSERT INTO payment_matches (id, transfer_id, registration_id, match_type,
                                                match_confidence, matched_reference, notes, created_at)
                    VALUES (nextval('match_id_seq'), ?, ?, ?, ?, ?, ?, ?)
                """, [transfer_id, best_match.reg_id, best_match.match_type,
                      best_match.confidence, best_match.reference, best_match.notes, now()])

                result_id = DBInterface.execute(db, "SELECT currval('match_id_seq')")
                first(collect(result_id))[1]
            end

            # Get transfer date for financial transaction
            transfer_date_result = DBInterface.execute(db,
                "SELECT transfer_date FROM bank_transfers WHERE id = ?", [transfer_id])
            transfer_date = first(collect(transfer_date_result))[1]

            # Log financial transaction and link back to payment_matches
            log_financial_transaction!(db, best_match.reg_id, "payment", amount;
                reference_id=match_id,
                reference_table="payment_matches",
                effective_date=transfer_date,
                notes="Auto-matched: $(best_match.notes) (confidence: $(best_match.confidence))")

            if email_cfg !== nothing
                try
                    queue_payment_confirmation!(email_cfg, db, best_match.reg_id, amount)
                catch e
                    @debug "Payment confirmation not queued" exception=e
                end
            end

            matched += 1
            match_found = true
            @info "Matched transfer" reference=best_match.reference amount=amount confidence=best_match.confidence type=best_match.match_type
        end

        # Strategy 4: Name + amount matching (only if no reference match found)
        if !match_found
            # Look for registrations in-scope, then apply amount tolerance in Julia
            query = if event_id !== nothing
                """
                SELECT id, reference_number, first_name, last_name, email, computed_cost
                FROM registrations
                WHERE event_id = ?
                """
            else
                """
                SELECT id, reference_number, first_name, last_name, email, computed_cost
                FROM registrations
                """
            end
            params = event_id !== nothing ? [event_id] : []
            result = DBInterface.execute(db, query, params)

            best_name_match = nothing
            best_name_score = 0.0

            for row in result
                reg_id, ref, first_name, last_name, _email, cost = row
                cost_val = cost === nothing ? nothing : Float64(cost)

                # Skip if cost exists but outside tolerance
                if cost_val !== nothing && abs(cost_val - amount) >= 0.01
                    continue
                end

                # Check if BOTH first and last name match
                name_matches, name_score = check_name_match(
                    something(sender_name, ""), ref_text,
                    something(first_name, ""), something(last_name, "")
                )

                if name_matches && name_score > best_name_score
                    best_name_score = name_score
                    best_name_match = (
                        reg_id=reg_id,
                        reference=ref,
                        first_name=first_name,
                        last_name=last_name,
                        confidence=name_score * 0.7  # Max 0.7 for name-only matching
                    )
                end
            end

            # Only match if we have a strong name match (both first AND last name)
            if best_name_match !== nothing && best_name_score >= 0.8
                match_id = with_transaction(db) do
                    DBInterface.execute(db, """
                        INSERT INTO payment_matches (id, transfer_id, registration_id, match_type,
                                                    match_confidence, matched_reference, notes, created_at)
                        VALUES (nextval('match_id_seq'), ?, ?, 'auto_name', ?, ?, ?, ?)
                    """, [transfer_id, best_name_match.reg_id, best_name_match.confidence,
                          best_name_match.reference, "Matched by full name (first + last) + amount", now()])

                    result_id = DBInterface.execute(db, "SELECT currval('match_id_seq')")
                    first(collect(result_id))[1]
                end

                # Get transfer date for financial transaction
                transfer_date_result = DBInterface.execute(db,
                    "SELECT transfer_date FROM bank_transfers WHERE id = ?", [transfer_id])
                transfer_date = first(collect(transfer_date_result))[1]

                # Log financial transaction
                log_financial_transaction!(db, best_name_match.reg_id, "payment", amount;
                    reference_id=match_id,
                    reference_table="payment_matches",
                    effective_date=transfer_date,
                    notes="Auto-matched by full name+amount (confidence: $(best_name_match.confidence))")

                if email_cfg !== nothing
                    try
                        queue_payment_confirmation!(email_cfg, db, best_name_match.reg_id, amount)
                    catch e
                        @debug "Payment confirmation not queued" exception=e
                    end
                end

                matched += 1
                match_found = true
                @info "Matched transfer by full name" sender=sender_name registration="$(best_name_match.first_name) $(best_name_match.last_name)" confidence=best_name_match.confidence
            end
        end

        # If still no match, add to unmatched list
        if !match_found
            push!(unmatched_list, (
                transfer_id=transfer_id,
                reference_text=reference_text,
                amount=amount,
                sender_name=sender_name
            ))
        end
    end  # End for loop
    @info "Transfer matching complete" matched=matched unmatched=length(unmatched_list)

    return (matched=matched, unmatched=unmatched_list)
end

"""
Get all unmatched transfers.
"""
function get_unmatched_transfers(db::DuckDB.DB)
    result = DBInterface.execute(db, """
        SELECT bt.id, bt.transfer_date, bt.amount, bt.sender_name, bt.reference_text
        FROM bank_transfers bt
        LEFT JOIN payment_matches pm ON pm.transfer_id = bt.id
        WHERE pm.id IS NULL
        ORDER BY bt.transfer_date DESC
    """)
    return collect(result)
end

"""
Get transfers that need manual review (low confidence matches).
"""
function get_uncertain_matches(db::DuckDB.DB; threshold::Float64=0.8)
    result = DBInterface.execute(db, """
        SELECT bt.id, bt.transfer_date, bt.amount, bt.sender_name, bt.reference_text,
               pm.matched_reference, pm.match_confidence, pm.match_type,
               r.first_name, r.last_name, r.email, r.computed_cost
        FROM payment_matches pm
        JOIN bank_transfers bt ON bt.id = pm.transfer_id
        JOIN registrations r ON r.id = pm.registration_id
        WHERE pm.match_confidence < ?
        ORDER BY pm.match_confidence ASC
    """, [threshold])
    return collect(result)
end

"""
Find unmatched transfers that have likely candidates but weren't matched automatically.

This is useful for identifying transfers where:
- A reference number was found but the amount doesn't match
- A name matches but there's no reference or amount confirmation
- The reference has a typo (off-by-one) but other criteria don't fully match

Returns a vector of named tuples with transfer info and candidate registrations:
[
    (transfer_id, transfer_date, amount, sender_name, reference_text,
     candidates=[
         (reg_id, reference_number, first_name, last_name, computed_cost,
          match_reason, amount_diff, confidence)
     ])
]

Candidates are sorted by confidence (highest first).
"""
function get_near_miss_transfers(db::DuckDB.DB; event_id::Union{String,Nothing}=nothing)
    # Get unmatched transfers
    unmatched = get_unmatched_transfers(db)
    
    near_misses = []
    
    for transfer in unmatched
        transfer_id, transfer_date, amount, sender_name, reference_text = transfer
        amount = Float64(amount)
        ref_text = something(reference_text, "")
        
        candidates = []
        seen_reg_ids = Set{Int}()  # Avoid duplicate candidates
        
        # Strategy 1: Reference number found but amount mismatch
        ref_candidates = extract_reference_candidates(ref_text)
        for ref_candidate in ref_candidates
            reg_query = event_id === nothing ?
                "SELECT id, event_id, reference_number, first_name, last_name, email, computed_cost FROM registrations WHERE reference_number = ?" :
                "SELECT id, event_id, reference_number, first_name, last_name, email, computed_cost FROM registrations WHERE reference_number = ? AND event_id = ?"
            
            params = event_id === nothing ? [ref_candidate] : [ref_candidate, event_id]
            result = DBInterface.execute(db, reg_query, params)
            rows = collect(result)
            
            for row in rows
                reg_id, _evt_id, ref_num, first_name, last_name, email, expected_cost = row
                reg_id in seen_reg_ids && continue
                push!(seen_reg_ids, reg_id)
                
                expected_cost_val = expected_cost === nothing ? nothing : Float64(expected_cost)
                amount_diff = expected_cost_val === nothing ? nothing : amount - expected_cost_val
                
                # Check name match
                name_matches, name_score = check_name_match(
                    something(sender_name, ""), ref_text,
                    something(first_name, ""), something(last_name, "")
                )
                
                # Determine match quality and reason
                if expected_cost_val !== nothing && abs(amount - expected_cost_val) < 0.01
                    # Amount matches - this should have been caught by auto-match
                    # Skip unless there was a name conflict
                    has_conflict = has_conflicting_name(ref_text, something(first_name, ""), something(last_name, ""))
                    if has_conflict
                        match_reason = "Reference + amount match, but conflicting name in text"
                        confidence = 0.80
                    else
                        continue  # Should have been auto-matched
                    end
                elseif expected_cost_val !== nothing
                    # Amount mismatch
                    if name_matches
                        match_reason = "Reference + name match, but amount differs (expected $(expected_cost_val)€, got $(amount)€)"
                        confidence = 0.75
                    else
                        match_reason = "Reference matches, but amount differs (expected $(expected_cost_val)€, got $(amount)€)"
                        confidence = 0.60
                    end
                else
                    # No cost configured
                    if name_matches
                        match_reason = "Reference + name match (no cost configured)"
                        confidence = 0.65
                    else
                        match_reason = "Reference matches (no cost configured, no name match)"
                        confidence = 0.40
                    end
                end
                
                push!(candidates, (
                    reg_id = reg_id,
                    reference_number = ref_num,
                    first_name = first_name,
                    last_name = last_name,
                    email = email,
                    computed_cost = expected_cost_val,
                    match_reason = match_reason,
                    amount_diff = amount_diff,
                    confidence = confidence
                ))
            end
        end
        
        # Strategy 2: Off-by-one reference typos
        for ref_candidate in ref_candidates
            parsed = parse_reference_number(ref_candidate)
            if parsed !== nothing
                event_part, num = parsed.event_id, parsed.id
                if event_id !== nothing && event_part != event_id
                    continue
                end
                
                for offset in [-1, 1]
                    nearby_num = num + offset
                    if nearby_num >= 1 && nearby_num <= 999
                        nearby_ref = generate_reference_number(event_part, nearby_num)
                        
                        reg_query = event_id === nothing ?
                            "SELECT id, event_id, reference_number, first_name, last_name, email, computed_cost FROM registrations WHERE reference_number = ?" :
                            "SELECT id, event_id, reference_number, first_name, last_name, email, computed_cost FROM registrations WHERE reference_number = ? AND event_id = ?"
                        
                        params = event_id === nothing ? [nearby_ref] : [nearby_ref, event_id]
                        result = DBInterface.execute(db, reg_query, params)
                        rows = collect(result)
                        
                        for row in rows
                            reg_id, _evt_id, ref_num, first_name, last_name, email, expected_cost = row
                            reg_id in seen_reg_ids && continue
                            push!(seen_reg_ids, reg_id)
                            
                            expected_cost_val = expected_cost === nothing ? nothing : Float64(expected_cost)
                            amount_diff = expected_cost_val === nothing ? nothing : amount - expected_cost_val
                            
                            name_matches, _ = check_name_match(
                                something(sender_name, ""), ref_text,
                                something(first_name, ""), something(last_name, "")
                            )
                            
                            amount_match = expected_cost_val !== nothing && abs(amount - expected_cost_val) < 0.01
                            
                            if amount_match && name_matches
                                # This should have been auto-matched as off-by-one
                                continue
                            elseif amount_match
                                match_reason = "Off-by-one typo ($(ref_candidate) → $(nearby_ref)), amount matches"
                                confidence = 0.70
                            elseif name_matches
                                match_reason = "Off-by-one typo ($(ref_candidate) → $(nearby_ref)), name matches"
                                confidence = 0.55
                            else
                                match_reason = "Off-by-one typo ($(ref_candidate) → $(nearby_ref)), partial match"
                                confidence = 0.35
                            end
                            
                            push!(candidates, (
                                reg_id = reg_id,
                                reference_number = ref_num,
                                first_name = first_name,
                                last_name = last_name,
                                email = email,
                                computed_cost = expected_cost_val,
                                match_reason = match_reason,
                                amount_diff = amount_diff,
                                confidence = confidence
                            ))
                        end
                    end
                end
            end
        end
        
        # Strategy 3: Name-only matching (for transfers without valid references)
        if isempty(candidates) && !isempty(something(sender_name, ""))
            # Look for registrations where name matches
            query = if event_id !== nothing
                """
                SELECT id, reference_number, first_name, last_name, email, computed_cost
                FROM registrations
                WHERE event_id = ?
                """
            else
                """
                SELECT id, reference_number, first_name, last_name, email, computed_cost
                FROM registrations
                """
            end
            params = event_id !== nothing ? [event_id] : []
            result = DBInterface.execute(db, query, params)
            
            for row in result
                reg_id, ref_num, first_name, last_name, email, cost = row
                reg_id in seen_reg_ids && continue
                
                cost_val = cost === nothing ? nothing : Float64(cost)
                
                name_matches, name_score = check_name_match(
                    something(sender_name, ""), ref_text,
                    something(first_name, ""), something(last_name, "")
                )
                
                if name_matches
                    push!(seen_reg_ids, reg_id)
                    amount_diff = cost_val === nothing ? nothing : amount - cost_val
                    amount_match = cost_val !== nothing && abs(amount - cost_val) < 0.01
                    
                    if amount_match
                        # Should have been auto-matched by name
                        continue
                    elseif cost_val !== nothing
                        match_reason = "Name matches ($(first_name) $(last_name)), but amount differs (expected $(cost_val)€, got $(amount)€)"
                        confidence = 0.50
                    else
                        match_reason = "Name matches ($(first_name) $(last_name)), no cost configured"
                        confidence = 0.45
                    end
                    
                    push!(candidates, (
                        reg_id = reg_id,
                        reference_number = ref_num,
                        first_name = first_name,
                        last_name = last_name,
                        email = email,
                        computed_cost = cost_val,
                        match_reason = match_reason,
                        amount_diff = amount_diff,
                        confidence = confidence
                    ))
                end
            end
        end
        
        # Only include transfers that have at least one candidate
        if !isempty(candidates)
            # Sort candidates by confidence (highest first)
            sort!(candidates, by=c -> -c.confidence)
            
            push!(near_misses, (
                transfer_id = transfer_id,
                transfer_date = transfer_date,
                amount = amount,
                sender_name = sender_name,
                reference_text = reference_text,
                candidates = candidates
            ))
        end
    end
    
    return near_misses
end

"""
Manually match a transfer to a registration.

When re-matching an already-matched transfer to a different registration,
this function reverses the old financial transaction and creates a new one.
"""
function manual_match!(db::DuckDB.DB, transfer_id::Integer, registration_id::Integer;
                       notes::String="", transfer_date::Union{Date,Nothing}=nothing,
                       email_cfg::Union{EmailConfig,Nothing}=nothing)
    # Get transfer details for financial transaction logging
    transfer_result = DBInterface.execute(db,
        "SELECT transfer_date, amount FROM bank_transfers WHERE id = ?",
        [transfer_id])
    transfer_row = first(collect(transfer_result))
    transfer_date, amount = transfer_row[1], Float64(transfer_row[2])

    # Check if already matched
    existing = DBInterface.execute(db,
        "SELECT id, registration_id FROM payment_matches WHERE transfer_id = ?",
        [transfer_id])
    existing_rows = collect(existing)

    match_id = nothing
    old_registration_id = nothing

    if !isempty(existing_rows)
        # This transfer is already matched - handle re-matching
        match_id = existing_rows[1][1]
        old_registration_id = existing_rows[1][2]

        # Only process if actually changing the registration
        if old_registration_id != registration_id
            @info "Re-matching transfer from registration $old_registration_id to $registration_id" transfer_id=transfer_id

            # Reverse the old financial transaction
            log_financial_transaction!(db, old_registration_id, "adjustment", -amount;
                reference_id=match_id, reference_table="payment_matches",
                effective_date=transfer_date,
                recorded_by="manual",
                notes="Reversal: transfer re-matched from reg $old_registration_id to $registration_id")
        end

        # Update existing match
        with_transaction(db) do
            DBInterface.execute(db, """
                UPDATE payment_matches
                SET registration_id = ?, match_type = 'manual', match_confidence = 1.0, notes = ?
                WHERE transfer_id = ?
            """, [registration_id, notes, transfer_id])
        end
    else
        # Create new match
        # Get registration reference
        reg_result = DBInterface.execute(db,
            "SELECT reference_number FROM registrations WHERE id = ?",
            [registration_id])
        ref = first(collect(reg_result))[1]
        with_transaction(db) do
            DBInterface.execute(db, """
                INSERT INTO payment_matches (id, transfer_id, registration_id, match_type,
                                            match_confidence, matched_reference, notes, created_at)
                VALUES (nextval('match_id_seq'), ?, ?, 'manual', 1.0, ?, ?, ?)
            """, [transfer_id, registration_id, ref, notes, now()])

            # Get the match ID we just inserted
            result_id = DBInterface.execute(db, "SELECT currval('match_id_seq')")
            match_id = first(collect(result_id))[1]
        end
    end

    # Log financial transaction (payment is a credit, so positive amount)
    log_financial_transaction!(db, registration_id, "payment", amount;
        reference_id=match_id, reference_table="payment_matches",
        effective_date=transfer_date,
        recorded_by="manual",
        notes="Manual match: $(notes)")

    # Queue payment confirmation email (if email system is available)
        if email_cfg !== nothing
            try
                queue_payment_confirmation!(email_cfg, db, registration_id, amount)
            catch e
                @debug "Payment confirmation not queued" exception=e
            end
        end

    @info "Manual match created" transfer_id=transfer_id registration_id=registration_id
end

"""
Match by reference number string.
"""
function manual_match!(db::DuckDB.DB, transfer_id::Integer, reference::AbstractString;
                       notes::String="")
    reg_result = DBInterface.execute(db,
        "SELECT id FROM registrations WHERE reference_number = ?",
        [uppercase(strip(reference))])
    rows = collect(reg_result)

    if isempty(rows)
        error("Registration not found for reference: $reference")
    end

    manual_match!(db, transfer_id, rows[1][1]; notes=notes)
end

"""
Get payment status for all registrations in an event.
Shows total paid (sum of all matched transfers), subsidies, and remaining amount.
remaining = computed_cost - payments - subsidies
"""
function get_payment_status(db::DuckDB.DB, event_id::AbstractString)
    result = DBInterface.execute(db, """
        SELECT
            r.reference_number,
            r.first_name,
            r.last_name,
            r.email,
            r.computed_cost,
            COALESCE(payments.total_paid, 0) as total_paid,
            COALESCE(subs.total_subsidy, 0) as total_subsidy,
            COALESCE(payments.total_paid, 0) + COALESCE(subs.total_subsidy, 0) as total_credits,
            r.computed_cost - COALESCE(payments.total_paid, 0) - COALESCE(subs.total_subsidy, 0) as remaining,
            CASE
                WHEN COALESCE(payments.total_paid, 0) + COALESCE(subs.total_subsidy, 0) >= r.computed_cost THEN 'Paid'
                WHEN COALESCE(payments.total_paid, 0) + COALESCE(subs.total_subsidy, 0) > 0 THEN 'Partial'
                ELSE 'Unpaid'
            END as status,
            payments.payment_count,
            payments.last_payment_date
        FROM registrations r
        LEFT JOIN (
            SELECT
                pm.registration_id,
                SUM(bt.amount) as total_paid,
                COUNT(*) as payment_count,
                MAX(bt.transfer_date) as last_payment_date
            FROM payment_matches pm
            JOIN bank_transfers bt ON bt.id = pm.transfer_id
            WHERE pm.registration_id IS NOT NULL
            GROUP BY pm.registration_id
        ) payments ON payments.registration_id = r.id
        LEFT JOIN (
            SELECT registration_id, SUM(amount) as total_subsidy
            FROM subsidies
            GROUP BY registration_id
        ) subs ON subs.registration_id = r.id
        WHERE r.event_id = ?
        ORDER BY r.last_name, r.first_name
    """, [event_id])
    return collect(result)
end

"""
Get payment history (all transfers) for a specific registration.
"""
function get_payment_history(db::DuckDB.DB, registration_id::Integer)
    result = DBInterface.execute(db, """
        SELECT
            bt.id as transfer_id,
            bt.transfer_date,
            bt.amount,
            bt.sender_name,
            bt.reference_text,
            pm.match_type,
            pm.match_confidence,
            pm.created_at as matched_at
        FROM payment_matches pm
        JOIN bank_transfers bt ON bt.id = pm.transfer_id
        WHERE pm.registration_id = ?
        ORDER BY bt.transfer_date
    """, [registration_id])
    return collect(result)
end

"""
Get payment history by reference number.
"""
function get_payment_history(db::DuckDB.DB, reference::AbstractString)
    reg_result = DBInterface.execute(db,
        "SELECT id FROM registrations WHERE reference_number = ?",
        [uppercase(strip(reference))])
    rows = collect(reg_result)

    if isempty(rows)
        return []
    end

    return get_payment_history(db, rows[1][1])
end

"""
Get summary statistics for an event.
Includes both payments and subsidies as credits.
"""
function get_payment_summary(db::DuckDB.DB, event_id::AbstractString)
    result = DBInterface.execute(db, """
        WITH credit_totals AS (
            SELECT
                r.id as registration_id,
                r.computed_cost,
                COALESCE(SUM(bt.amount), 0) as total_paid,
                COALESCE(sub.total_subsidy, 0) as total_subsidy
            FROM registrations r
            LEFT JOIN payment_matches pm ON pm.registration_id = r.id AND pm.registration_id IS NOT NULL
            LEFT JOIN bank_transfers bt ON bt.id = pm.transfer_id
            LEFT JOIN (
                SELECT registration_id, SUM(amount) as total_subsidy
                FROM subsidies
                GROUP BY registration_id
            ) sub ON sub.registration_id = r.id
            WHERE r.event_id = ?
            GROUP BY r.id, r.computed_cost, sub.total_subsidy
        )
        SELECT
            COUNT(*) as total_registrations,
            SUM(computed_cost) as total_expected,
            SUM(total_paid) as total_received,
            SUM(total_subsidy) as total_subsidies,
            SUM(total_paid + total_subsidy) as total_credits,
            SUM(CASE WHEN total_paid + total_subsidy >= computed_cost THEN 1 ELSE 0 END) as fully_paid_count,
            SUM(CASE WHEN total_paid + total_subsidy > 0 AND total_paid + total_subsidy < computed_cost THEN 1 ELSE 0 END) as partial_paid_count,
            SUM(CASE WHEN total_paid + total_subsidy = 0 THEN 1 ELSE 0 END) as unpaid_count,
            SUM(CASE WHEN total_paid + total_subsidy > computed_cost THEN total_paid + total_subsidy - computed_cost ELSE 0 END) as total_overpaid,
            SUM(CASE WHEN total_paid + total_subsidy < computed_cost THEN computed_cost - total_paid - total_subsidy ELSE 0 END) as total_outstanding
        FROM credit_totals
    """, [event_id])

    row = first(collect(result))
    return (
        total_registrations = something(row[1], 0),
        total_expected = something(row[2], 0.0),
        total_received = something(row[3], 0.0),
        total_subsidies = something(row[4], 0.0),
        total_credits = something(row[5], 0.0),
        fully_paid_count = something(row[6], 0),
        partial_paid_count = something(row[7], 0),
        unpaid_count = something(row[8], 0),
        total_overpaid = something(row[9], 0.0),
        total_outstanding = something(row[10], 0.0)
    )
end

"""
Get registrations with payment discrepancies (over/underpaid).
"""
function get_payment_discrepancies(db::DuckDB.DB, event_id::AbstractString)
    result = DBInterface.execute(db, """
        SELECT
            r.reference_number,
            r.first_name,
            r.last_name,
            r.email,
            r.computed_cost,
            COALESCE(SUM(bt.amount), 0) + COALESCE(sub.total_subsidy, 0) as total_credits,
            COALESCE(SUM(bt.amount), 0) + COALESCE(sub.total_subsidy, 0) - r.computed_cost as difference
        FROM registrations r
        LEFT JOIN payment_matches pm ON pm.registration_id = r.id AND pm.registration_id IS NOT NULL
        LEFT JOIN bank_transfers bt ON bt.id = pm.transfer_id
        LEFT JOIN (
            SELECT registration_id, SUM(amount) as total_subsidy
            FROM subsidies
            GROUP BY registration_id
        ) sub ON sub.registration_id = r.id
        WHERE r.event_id = ?
        GROUP BY r.id, r.reference_number, r.first_name, r.last_name, r.email, r.computed_cost, sub.total_subsidy
        HAVING COALESCE(SUM(bt.amount), 0) + COALESCE(sub.total_subsidy, 0) != r.computed_cost
           AND COALESCE(SUM(bt.amount), 0) + COALESCE(sub.total_subsidy, 0) > 0
        ORDER BY difference DESC
    """, [event_id])
    return collect(result)
end

end # module
