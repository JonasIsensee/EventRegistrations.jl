module Registrations

using DuckDB
using DBInterface
using JSON
using Dates

# Import from parent module's submodules
using ..EmailParser
using ..ReferenceNumbers
using ..CostCalculator

export process_email_folder!, get_registrations, export_registrations
export grant_subsidy!, get_subsidies, revoke_subsidy!, grant_subsidies_batch!
export get_registration_by_reference, recalculate_costs!

"""
Process all .eml files in a folder.
Handles resubmissions by updating existing registrations while preserving reference numbers.
Reports newly detected event IDs and suggests configuration generation.
"""
function process_email_folder!(db::DuckDB.DB, folder_path::AbstractString)
    eml_files = filter(f -> endswith(lowercase(f), ".eml"), readdir(folder_path, join=true))

    # Track event IDs found in this batch
    detected_event_ids = Set{String}()
    events_without_config = Set{String}()
    resubmissions = Vector{Tuple{String,String,String}}()  # (email, event_id, reference)

    stats = (processed=0, submissions=0, new_registrations=0, updates=0, skipped=0, no_cost_config=0)

    for filepath in eml_files
        try
            # Parse email to detect event_id before processing
            parsed = EmailParser.parse_eml(filepath)
            submission = EmailParser.extract_form_submission(parsed.body_html)

            if submission !== nothing
                push!(detected_event_ids, submission.event_id)

                # Check if event has cost config
                config_result = DBInterface.execute(db,
                    "SELECT event_id FROM events WHERE event_id = ?",
                    [submission.event_id])
                if isempty(collect(config_result))
                    push!(events_without_config, submission.event_id)
                end
            end

            result = process_single_email!(db, filepath)

            # Track resubmissions
            if result.is_update && submission !== nothing
                # Get the reference number for this registration
                ref_result = DBInterface.execute(db,
                    "SELECT reference_number FROM registrations WHERE event_id = ? AND email = ?",
                    [submission.event_id, submission.email])
                ref_rows = collect(ref_result)
                if !isempty(ref_rows)
                    push!(resubmissions, (submission.email, submission.event_id, ref_rows[1][1]))
                end
            end

            stats = (
                processed = stats.processed + 1,
                submissions = stats.submissions + (result.has_submission ? 1 : 0),
                new_registrations = stats.new_registrations + (result.is_new ? 1 : 0),
                updates = stats.updates + (result.is_update ? 1 : 0),
                skipped = stats.skipped + (result.skipped ? 1 : 0),
                no_cost_config = stats.no_cost_config + (result.no_cost_config ? 1 : 0)
            )
        catch e
            @warn "Error processing email" filepath exception=e
        end
    end

    # Report detected events
    if !isempty(detected_event_ids)
        println("\n" * "="^80)
        println("DETECTED EVENT IDs:")
        for event_id in sort(collect(detected_event_ids))
            has_config = event_id ∉ events_without_config
            status = has_config ? "✓ (has cost config)" : "⚠ (NO cost config)"
            println("  - $event_id $status")
        end
    end

    # Suggest config generation for events without config
    if !isempty(events_without_config)
        println("\n" * "="^80)
        println("⚠ WARNING: $(length(events_without_config)) event(s) have NO cost configuration!")
        println("Costs are set to NULL until configuration is created.")
        println("\nTo configure costs for these events:")
        for event_id in sort(collect(events_without_config))
            println("\n  Event: $event_id")
            println("    1. Generate field config (if not done): eventreg generate-field-config")
            println("    2. Create event config: eventreg create-event-config $event_id")
            println("    3. Edit config/events/$event_id.toml to set cost rules")
            println("    4. Sync to database: eventreg sync-config")
            println("    5. Recalculate costs: eventreg recalculate-costs $event_id")
        end
        println("="^80)
    end

    # Report resubmissions (updated registrations)
    if !isempty(resubmissions)
        println("\n" * "="^80)
        println("ℹ RESUBMISSIONS DETECTED ($(length(resubmissions)) registration(s) updated):")
        println()
        println("The following people submitted new forms, updating their previous registration.")
        println("Reference numbers were preserved to maintain payment matching.")
        println()
        for (email, event_id, reference) in resubmissions
            println("  • $email (Event: $event_id, Ref: $reference)")
        end
        println("\nNote: If you need to manually override automatic matching (e.g., for")
        println("different email addresses from the same person), you can:")
        println("  1. Check registration details: eventreg event-overview $([r[2] for r in resubmissions][1])")
        println("  2. Manually match payments: eventreg manual-match <transfer_id> <reference>")
        println("="^80)
    end

    return stats
end

"""
Process a single email file.
"""
function process_single_email!(db::DuckDB.DB, filepath::AbstractString)
    file_hash = compute_file_hash(filepath)
    filename = basename(filepath)

    # Check if already processed
    result = DBInterface.execute(db,
        "SELECT COUNT(*) FROM processed_emails WHERE file_hash = ?",
        [file_hash])
    if first(collect(result))[1] > 0
        return (has_submission=false, is_new=false, is_update=false, skipped=true, no_cost_config=false)
    end

    # Parse the email
    parsed = parse_eml(filepath)
    submission = extract_form_submission(parsed.body_html)

    has_submission = submission !== nothing
    is_new = false
    is_update = false
    no_cost_config = false

    # Record that we processed this email
    DBInterface.execute(db, """
        INSERT INTO processed_emails (file_hash, filename, processed_at, has_submission, event_id)
        VALUES (?, ?, ?, ?, ?)
    """, [file_hash, filename, now(), has_submission,
          has_submission ? submission.event_id : nothing])

    if has_submission
        # Parse email date
        email_date = haskey(parsed.headers, "date") ?
            EmailParser.parse_email_date(parsed.headers["date"]) : now()

        # Store raw submission
        fields_json = JSON.json(submission.fields)

        DBInterface.execute(db, """
            INSERT INTO submissions (id, file_hash, event_id, email, first_name, last_name,
                                     fields, email_date, email_from, email_subject, created_at)
            VALUES (nextval('submission_id_seq'), ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [file_hash, submission.event_id, submission.email,
              submission.first_name, submission.last_name, fields_json,
              email_date, get(parsed.headers, "from", nothing),
              get(parsed.headers, "subject", nothing), now()])

        # Get the submission ID we just inserted
        sub_result = DBInterface.execute(db,
            "SELECT currval('submission_id_seq')")
        submission_id = first(collect(sub_result))[1]

        # Check for existing registration (resubmission case)
        existing = DBInterface.execute(db, """
            SELECT id, reference_number FROM registrations
            WHERE event_id = ? AND email = ?
        """, [submission.event_id, submission.email])
        existing_rows = collect(existing)

        # Calculate cost (returns nothing if no cost config exists)
        computed_cost = calculate_cost(db, submission.event_id, submission.fields)

        if isempty(existing_rows)
            # New registration
            DBInterface.execute(db, """
                INSERT INTO registrations (id, event_id, email, reference_number,
                                           first_name, last_name, fields, computed_cost,
                                           latest_submission_id, registration_date, updated_at)
                VALUES (nextval('registration_id_seq'), ?, ?, 'TEMP', ?, ?, ?, ?, ?, ?, ?)
            """, [submission.event_id, submission.email,
                  submission.first_name, submission.last_name, fields_json,
                  computed_cost, submission_id, email_date, now()])

            # Get the registration ID and generate reference number
            reg_result = DBInterface.execute(db, "SELECT currval('registration_id_seq')")
            reg_id = first(collect(reg_result))[1]

            ref_number = generate_reference_number(submission.event_id, reg_id)

            DBInterface.execute(db, """
                UPDATE registrations SET reference_number = ? WHERE id = ?
            """, [ref_number, reg_id])

            is_new = true
            if computed_cost === nothing
                no_cost_config = true
                @warn "New registration - NO COST CONFIG" event=submission.event_id email=submission.email reference=ref_number
            else
                @info "New registration" event=submission.event_id email=submission.email reference=ref_number cost=computed_cost
            end
        else
            # Update existing registration (keep reference number!)
            reg_id = existing_rows[1][1]
            ref_number = existing_rows[1][2]

            DBInterface.execute(db, """
                UPDATE registrations SET
                    first_name = ?,
                    last_name = ?,
                    fields = ?,
                    computed_cost = ?,
                    latest_submission_id = ?,
                    updated_at = ?
                WHERE id = ?
            """, [submission.first_name, submission.last_name, fields_json,
                  computed_cost, submission_id, now(), reg_id])

            is_update = true
            if computed_cost === nothing
                no_cost_config = true
                @warn "Updated registration (resubmission) - NO COST CONFIG" event=submission.event_id email=submission.email reference=ref_number
            else
                @info "Updated registration (resubmission)" event=submission.event_id email=submission.email reference=ref_number cost=computed_cost
            end
        end
    end

    return (has_submission=has_submission, is_new=is_new, is_update=is_update, skipped=false, no_cost_config=no_cost_config)
end

"""
Get all registrations for an event.
"""
function get_registrations(db::DuckDB.DB, event_id::AbstractString)
    result = DBInterface.execute(db, """
        SELECT id, email, reference_number, first_name, last_name,
               fields, computed_cost, registration_date
        FROM registrations
        WHERE event_id = ?
        ORDER BY registration_date
    """, [event_id])
    return collect(result)
end

"""
Get a registration by reference number.
"""
function get_registration_by_reference(db::DuckDB.DB, reference::AbstractString)
    result = DBInterface.execute(db, """
        SELECT r.id, r.event_id, r.email, r.reference_number, r.first_name, r.last_name,
               r.fields, r.computed_cost, r.registration_date
        FROM registrations r
        WHERE r.reference_number = ?
    """, [uppercase(strip(reference))])
    rows = collect(result)
    return isempty(rows) ? nothing : rows[1]
end

"""
Export registrations to a table format with specified fields.
If fields is nothing, exports all fields.
Payment status now includes subsidies as credits alongside real payments.
"""
function export_registrations(db::DuckDB.DB, event_id::AbstractString;
                               fields::Union{Vector{String}, Nothing}=nothing,
                               include_payment_status::Bool=false)
    # Get all unique fields if not specified
    if fields === nothing
        field_result = DBInterface.execute(db, """
            SELECT DISTINCT json_keys(fields) as keys FROM registrations WHERE event_id = ?
        """, [event_id])

        all_fields = Set{String}()
        for row in field_result
            if row[1] !== nothing
                for f in row[1]
                    push!(all_fields, f)
                end
            end
        end
        fields = sort(collect(all_fields))
    end

    # Build query with dynamic field extraction
    field_extracts = join(["json_extract_string(r.fields, '\$.$f') as \"$f\"" for f in fields], ", ")

    payment_join = ""
    payment_select = ""
    if include_payment_status
        payment_select = """,
            COALESCE(pt.total_paid, 0) as total_paid,
            COALESCE(sub.total_subsidy, 0) as total_subsidy,
            COALESCE(pt.total_paid, 0) + COALESCE(sub.total_subsidy, 0) as total_credits,
            r.computed_cost - COALESCE(pt.total_paid, 0) - COALESCE(sub.total_subsidy, 0) as remaining,
            CASE
                WHEN COALESCE(pt.total_paid, 0) + COALESCE(sub.total_subsidy, 0) >= r.computed_cost THEN 'Paid'
                WHEN COALESCE(pt.total_paid, 0) + COALESCE(sub.total_subsidy, 0) > 0 THEN 'Partial'
                ELSE 'Unpaid'
            END as payment_status,
            pt.payment_count,
            pt.last_payment_date"""
        payment_join = """
            LEFT JOIN (
                SELECT
                    pm.registration_id,
                    SUM(bt.amount) as total_paid,
                    COUNT(*) as payment_count,
                    MAX(bt.transfer_date) as last_payment_date
                FROM payment_matches pm
                JOIN bank_transfers bt ON bt.id = pm.transfer_id
                WHERE pm.match_type != 'unmatched'
                GROUP BY pm.registration_id
            ) pt ON pt.registration_id = r.id
            LEFT JOIN (
                SELECT registration_id, SUM(amount) as total_subsidy
                FROM subsidies
                GROUP BY registration_id
            ) sub ON sub.registration_id = r.id"""
    end

    query = """
        SELECT r.id, r.reference_number, r.email, r.first_name, r.last_name,
               r.computed_cost, r.registration_date,
               $field_extracts
               $payment_select
        FROM registrations r
        $payment_join
        WHERE r.event_id = ?
        ORDER BY r.last_name, r.first_name
    """

    result = DBInterface.execute(db, query, [event_id])
    return collect(result)
end

"""
Grant a subsidy (financial help) to a registration.
The subsidy amount is treated as a credit, reducing the remaining amount to pay.
Multiple subsidies can be granted and they stack.
"""
function grant_subsidy!(db::DuckDB.DB, registration_id::Integer,
                        amount::Real; reason::String="", granted_by::String="")
    # Insert subsidy record
    DBInterface.execute(db, """
        INSERT INTO subsidies (id, registration_id, amount, reason, granted_by, granted_at)
        VALUES (nextval('subsidy_id_seq'), ?, ?, ?, ?, ?)
    """, [registration_id, amount, reason, granted_by, now()])

    @info "Granted subsidy" registration_id=registration_id amount=amount reason=reason
end

"""
Grant subsidy by reference number.
"""
function grant_subsidy!(db::DuckDB.DB, reference::AbstractString,
                        amount::Real; reason::String="", granted_by::String="")
    reg = get_registration_by_reference(db, reference)
    if reg === nothing
        error("Registration not found for reference: $reference")
    end
    grant_subsidy!(db, reg[1], amount; reason=reason, granted_by=granted_by)
end

"""
Get all subsidies for a registration.
"""
function get_subsidies(db::DuckDB.DB, registration_id::Integer)
    result = DBInterface.execute(db, """
        SELECT id, amount, reason, granted_by, granted_at
        FROM subsidies
        WHERE registration_id = ?
        ORDER BY granted_at
    """, [registration_id])
    return collect(result)
end

"""
Get subsidies by reference number.
"""
function get_subsidies(db::DuckDB.DB, reference::AbstractString)
    reg = get_registration_by_reference(db, reference)
    if reg === nothing
        return []
    end
    return get_subsidies(db, reg[1])
end

"""
Revoke (delete) a specific subsidy by its ID.
"""
function revoke_subsidy!(db::DuckDB.DB, subsidy_id::Integer)
    DBInterface.execute(db, "DELETE FROM subsidies WHERE id = ?", [subsidy_id])
    @info "Revoked subsidy" subsidy_id=subsidy_id
end

"""
Batch grant subsidies from a list.
Format: [(reference_or_email, amount, reason), ...]
"""
function grant_subsidies_batch!(db::DuckDB.DB, subsidies::Vector; granted_by::String="")
    for subsidy in subsidies
        ref_or_email, amount = subsidy[1], subsidy[2]
        reason = length(subsidy) >= 3 ? subsidy[3] : ""

        # Try by reference first, then by email
        reg = get_registration_by_reference(db, ref_or_email)
        if reg === nothing
            # Try by email
            result = DBInterface.execute(db, """
                SELECT id FROM registrations WHERE email = ?
            """, [ref_or_email])
            rows = collect(result)
            if !isempty(rows)
                grant_subsidy!(db, rows[1][1], amount; reason=reason, granted_by=granted_by)
            else
                @warn "Could not find registration" identifier=ref_or_email
            end
        else
            grant_subsidy!(db, reg[1], amount; reason=reason, granted_by=granted_by)
        end
    end
end

"""
Recalculate all costs for an event (e.g., after updating cost rules).
Subsidies are unaffected - they remain as separate credits.

Returns detailed results including any warnings from cost calculation.
Use `strict=true` to fail on any validation errors instead of just warning.
Use `dry_run=true` to preview changes without applying them.
"""
function recalculate_costs!(db::DuckDB.DB, event_id::AbstractString;
                            strict::Bool=false, dry_run::Bool=false, verbose::Bool=false)
    registrations = get_registrations(db, event_id)

    if isempty(registrations)
        @warn "No registrations found for event" event_id=event_id
        return (success=true, updated=0, warnings=0, details=[])
    end

    # Get cost rules
    rules = CostCalculator.get_cost_rules(db, event_id)
    if rules === nothing
        error("No cost configuration found for event: $event_id")
    end

    # Pre-calculate all costs and collect warnings
    updates = []
    all_warnings = []
    registration_warnings = Dict{String, Vector{String}}()

    for reg in registrations
        reg_id = reg[1]
        reference = reg[3]
        fields = convert(Dict{String, String}, JSON.parse(reg[6]))

        # Use the detailed calculation
        result = CostCalculator.calculate_cost_with_details(rules, fields)

        push!(updates, (id=reg_id, reference=reference, old_cost=reg[7], new_cost=result.total, result=result))

        if !isempty(result.warnings)
            registration_warnings[reference] = result.warnings
            for w in result.warnings
                push!(all_warnings, (reference, w))
            end
        end
    end

    # Report warnings
    if !isempty(all_warnings)
        println("\n⚠️  WARNINGS during cost calculation ($(length(all_warnings)) issues):")
        println()

        # Group by registration
        for (ref, warnings) in registration_warnings
            println("  Registration $ref:")
            for w in warnings
                println("    • $w")
            end
        end
        println()

        if strict
            error("Strict mode: aborting due to $(length(all_warnings)) warning(s)")
        end
    end

    if verbose
        println("\nCost calculation details:")
        for upd in updates
            old_str = upd.old_cost === nothing ? "NULL" : string(upd.old_cost)
            change = upd.old_cost === nothing ? "new" :
                     upd.new_cost == upd.old_cost ? "unchanged" :
                     upd.new_cost > upd.old_cost ? "+$(upd.new_cost - upd.old_cost)" :
                     "$(upd.new_cost - upd.old_cost)"
            println("  $(upd.reference): $old_str → $(upd.new_cost) ($change)")

            # Show cost breakdown if there are matched rules
            if !isempty(upd.result.rule_costs)
                println("    Base: $(upd.result.base)")
                for (desc, cost) in upd.result.rule_costs
                    println("    + $cost ($desc)")
                end
            end
        end
        println()
    end

    if dry_run
        println("ℹ️  DRY RUN - no changes applied")
        return (success=true, updated=0, would_update=length(updates),
                warnings=length(all_warnings), details=updates)
    end

    # Apply all updates
    for upd in updates
        DBInterface.execute(db, """
            UPDATE registrations SET computed_cost = ?, updated_at = ?
            WHERE id = ?
        """, [upd.new_cost, now(), upd.id])
    end

    @info "Recalculated costs for event" event_id=event_id count=length(registrations) warnings=length(all_warnings)

    return (success=true, updated=length(updates), warnings=length(all_warnings), details=updates)
end

end # module
