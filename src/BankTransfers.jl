module BankTransfers

using DBInterface: DBInterface
using Dates: Dates, Date, now, today
using DelimitedFiles: DelimitedFiles
using DuckDB: DuckDB
using JSON: JSON
using SHA: SHA


# Import from parent module
import ..EventRegistrations: with_transaction, EmailConfig

# Import from parent module's submodules
using ..ReferenceNumbers
using ..ConfirmationEmails: queue_payment_confirmation!

export import_bank_csv!, match_transfers!, get_unmatched_transfers
export manual_match!, get_payment_status, get_payment_summary
export get_payment_history, get_payment_discrepancies

"""
Log a financial transaction to the immutable ledger.
"""
function log_financial_transaction!(db::DuckDB.DB, registration_id::Integer,
                                     transaction_type::String, amount::Real;
                                     reference_id::Union{Integer,Nothing}=nothing,
                                     reference_table::Union{String,Nothing}=nothing,
                                     effective_date::Date=today(),
                                     recorded_by::String="system",
                                     notes::String="")
    with_transaction(db) do
        DBInterface.execute(db, """
            INSERT INTO financial_transactions (id, registration_id, transaction_type, amount,
                                                reference_id, reference_table, effective_date,
                                                recorded_at, recorded_by, notes)
            VALUES (nextval('transaction_id_seq'), ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [registration_id, transaction_type, amount, reference_id, reference_table,
              effective_date, now(), recorded_by, notes])
    end
end

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
    lines = readlines(csv_path)

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

    # Process data rows - wrap in transaction for atomicity (safe for nesting)
    new_count = 0
    skip_count = 0

    for line in lines[header_idx+1:end]
        # Skip empty lines
        if isempty(strip(line))
            continue
        end

        # Parse CSV line (handling quoted fields)
        fields = parse_csv_line(line, delimiter)

        if length(fields) < maximum(values(col_map))
            continue
        end

        # Extract values
        date_str = col_map[:date] > 0 ? strip(fields[col_map[:date]], '"') : ""
        amount_str = col_map[:amount] > 0 ? strip(fields[col_map[:amount]], '"') : ""
        reference = col_map[:reference] > 0 ? strip(fields[col_map[:reference]], '"') : ""
        sender_name = col_map[:sender_name] > 0 ? strip(fields[col_map[:sender_name]], '"') : ""
        sender_iban = col_map[:sender_iban] > 0 ? strip(fields[col_map[:sender_iban]], '"') : ""

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

        amount = try
            parse(Float64, amount_str)
        catch
            continue
        end

        # Only process incoming transfers (positive amounts)
        if amount <= 0
            continue
        end

        # Create hash for duplicate detection
        hash_input = "$date_str|$amount_str|$reference|$sender_name"
        transfer_hash = hash_input# bytes2hex(sha256(hash_input))

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
        :sender_iban => 0
    )

    for (i, col) in enumerate(header)
        col_lower = lowercase(col)

        if col_map[:date] == 0 &&
           (occursin("buchungstag", col_lower) || occursin("datum", col_lower) ||
            occursin("date", col_lower) || occursin("valuta", col_lower))
            col_map[:date] = i
        elseif col_map[:amount] == 0 &&
               (occursin("betrag", col_lower) || occursin("amount", col_lower) ||
                occursin("umsatz", col_lower))
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
        end
    end

    return col_map
end

"""
Parse a CSV line handling quoted fields.
"""
function parse_csv_line(line::AbstractString, delimiter::Char)
    fields = String[]
    current = ""
    in_quotes = false

    for char in line
        if char == '"'
            in_quotes = !in_quotes
        elseif char == delimiter && !in_quotes
            push!(fields, current)
            current = ""
        else
            current *= char
        end
    end
    push!(fields, current)

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
Attempt to automatically match unmatched transfers to registrations.
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
        candidates = extract_reference_candidates(something(reference_text, ""))

        match_found = false

        for (ref_candidate, confidence) in candidates
            # Look up registration
            reg_query = event_id === nothing ?
                "SELECT id, event_id, computed_cost, email FROM registrations WHERE reference_number = ?" :
                "SELECT id, event_id, computed_cost, email FROM registrations WHERE reference_number = ? AND event_id = ?"

            params = event_id === nothing ? [ref_candidate] : [ref_candidate, event_id]
            result = DBInterface.execute(db, reg_query, params)
            rows = collect(result)

            if !isempty(rows)
                reg_id = rows[1][1]
                expected_cost = rows[1][3]

                # Check amount matches (within tolerance)
                # Handle NULL cost (no cost config exists)
                amount_match = if expected_cost !== nothing
                    abs(amount - expected_cost) < 0.01
                else
                    false  # Can't verify amount if cost is not configured
                end

                final_confidence = amount_match ? confidence : confidence * 0.8
                match_type = final_confidence >= 0.8 ? "auto" : "auto_uncertain"

                # Create match
                match_id = nothing
                with_transaction(db) do
                    DBInterface.execute(db, """
                        INSERT INTO payment_matches (id, transfer_id, registration_id, match_type,
                                                    match_confidence, matched_reference, notes, created_at)
                        VALUES (nextval('match_id_seq'), ?, ?, ?, ?, ?, ?, ?)
                    """, [transfer_id, reg_id, match_type, final_confidence, ref_candidate, "", now()])

                    # Get the match ID we just inserted
                    result_id = DBInterface.execute(db, "SELECT currval('match_id_seq')")
                    match_id = first(collect(result_id))[1]
                end

                # Get transfer date for financial transaction
                transfer_date_result = DBInterface.execute(db,
                    "SELECT transfer_date FROM bank_transfers WHERE id = ?", [transfer_id])
                transfer_date = first(collect(transfer_date_result))[1]

                # Log financial transaction (payment is a credit, so positive amount)
                log_financial_transaction!(db, reg_id, "payment", amount;
                    reference_id=match_id, reference_table="payment_matches",
                    effective_date=transfer_date,
                    notes="Auto-matched payment (confidence: $(final_confidence))")

                if email_cfg !== nothing
                    try
                        queue_payment_confirmation!(email_cfg, db, reg_id, amount)
                    catch e
                        @debug "Payment confirmation not queued" exception=e
                    end
                end

                matched += 1
                match_found = true

                @info "Matched transfer" reference=ref_candidate amount=amount confidence=final_confidence
                break
            end
        end

        if !match_found
            # Try to match by sender name and amount
            name_parts = split(lowercase(something(sender_name, "")))

            if length(name_parts) >= 1
                # Look for registrations with matching name and amount
                # Use parameterized query to prevent SQL injection
                query = if event_id !== nothing
                    """
                    SELECT id, reference_number, first_name, last_name, email, computed_cost
                    FROM registrations
                    WHERE computed_cost = ? AND event_id = ?
                    """
                else
                    """
                    SELECT id, reference_number, first_name, last_name, email, computed_cost
                    FROM registrations
                    WHERE computed_cost = ?
                    """
                end
                params = event_id !== nothing ? [amount, event_id] : [amount]
                result = DBInterface.execute(db, query, params)

                for row in result
                    reg_id, ref, first_name, last_name, email, cost = row

                    # Check if name matches
                    fn_lower = lowercase(something(first_name, ""))
                    ln_lower = lowercase(something(last_name, ""))

                    name_match = any(p -> (occursin(p, fn_lower) || occursin(p, ln_lower)), name_parts)

                    if name_match
                        # Create match with lower confidence
                        match_id = nothing
                        with_transaction(db) do
                            DBInterface.execute(db, """
                                INSERT INTO payment_matches (id, transfer_id, registration_id, match_type,
                                                            match_confidence, matched_reference, notes, created_at)
                                VALUES (nextval('match_id_seq'), ?, ?, 'auto_name', 0.6, ?, 'Matched by name + amount', ?)
                            """, [transfer_id, reg_id, ref, now()])

                            # Get the match ID we just inserted
                            result_id = DBInterface.execute(db, "SELECT currval('match_id_seq')")
                            match_id = first(collect(result_id))[1]
                        end

                        # Get transfer date for financial transaction
                        transfer_date_result = DBInterface.execute(db,
                            "SELECT transfer_date FROM bank_transfers WHERE id = ?", [transfer_id])
                        transfer_date = first(collect(transfer_date_result))[1]

                        # Log financial transaction (payment is a credit, so positive amount)
                        log_financial_transaction!(db, reg_id, "payment", amount;
                            reference_id=match_id, reference_table="payment_matches",
                            effective_date=transfer_date,
                            notes="Auto-matched by name+amount (confidence: 0.6)")

                        if email_cfg !== nothing
                            try
                                queue_payment_confirmation!(email_cfg, db, reg_id, amount)
                            catch e
                                @debug "Payment confirmation not queued" exception=e
                            end
                        end

                        matched += 1
                        match_found = true
                        @info "Matched transfer by name" sender=sender_name registration="$first_name $last_name"
                        break
                    end
                end
            end
        end

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
Manually match a transfer to a registration.
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
        "SELECT id FROM payment_matches WHERE transfer_id = ?",
        [transfer_id])

    match_id = nothing
    if !isempty(collect(existing))
        # Update existing match
        match_id = first(collect(existing))[1]
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
