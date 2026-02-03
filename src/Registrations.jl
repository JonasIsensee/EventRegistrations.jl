module Registrations

using DBInterface: DBInterface
using Dates: Dates, Date, now, today, @dateformat_str
using DuckDB: DuckDB
using JSON: JSON

# Import from parent module
import ..EventRegistrations: with_transaction, log_financial_transaction!

# Import from parent module's submodules
using ..EmailParser
using ..ReferenceNumbers
using ..Config: generate_event_config_template,
                 load_event_config, materialize_cost_rules, get_registration_detail_columns,
                 sync_event_configs_to_db!
using ..CostCalculator

export process_email_folder!, get_registrations
export RegistrationDetailTable, get_registration_detail_table
export grant_subsidy!, get_subsidies, revoke_subsidy!, grant_subsidies_batch!
export get_registration_by_reference, recalculate_costs!
export get_registrations_for_edit, update_registration!
export cancel_registration!
export delete_registration!, restore_registration!
export get_deleted_registrations, get_registration_by_reference_including_deleted

"""
Prompt the user for a yes/no decision and return `true` for yes, `false` for no.

If the standard input stream is not interactive, or an EOF is encountered, the
provided default is used (`false` when no default is supplied).
"""
function prompt_user_bool(question::AbstractString; default::Union{Bool,Nothing}=nothing)
    suffix = default === nothing ? " [y/n]: " : default ? " [Y/n]: " : " [y/N]: "
    prompt = question * suffix

    while true
        print(prompt)
        flush(stdout)
        try
            response = readline(stdin)
        catch _
            return default === nothing ? false : default
        end

        response = strip(response)

        if isempty(response)
            if default !== nothing
                return default
            else
                println("Please respond with y or n.")
                continue
            end
        end

        response_lower = lowercase(response)
        if response_lower in ("y", "yes")
            return true
        elseif response_lower in ("n", "no")
            return false
        else
            println("Please respond with y or n.")
        end
    end
end

"""
Process all .eml files in a folder.
Handles resubmissions by updating existing registrations while preserving reference numbers.
Reports newly detected event IDs and auto-creates missing event configs by default, loading
them into the database for immediate use.
When `prompt_for_new_events=true`, interactively offers to scaffold missing
event configuration files and may return `terminated=true` if the user chooses
to pause processing.
"""
function process_email_folder!(db::DuckDB.DB, folder_path::AbstractString;
                               events_dir::Union{Nothing,String}="events",
                               prompt_for_new_events::Bool=false,)
    eml_files = filter(f -> endswith(lowercase(f), ".eml"), readdir(folder_path, join=true))

    mkpath(events_dir)
    # Track event IDs found in this batch

    stats = (processed=0, submissions=0, new_registrations=0, updates=0, skipped=0, no_cost_config=0)

    for filepath in eml_files
        result = process_single_email!(db, filepath; events_dir)

        stats = (
            processed = stats.processed + 1,
            submissions = stats.submissions + (result.has_submission ? 1 : 0),
            new_registrations = stats.new_registrations + (result.is_new ? 1 : 0),
            updates = stats.updates + (result.is_update ? 1 : 0),
            skipped = stats.skipped + (result.skipped ? 1 : 0),
            no_cost_config = stats.no_cost_config + (result.no_cost_config ? 1 : 0)
        )
    end
    return stats
end

"""
Process a single email file.
"""
function process_single_email!(db::DuckDB.DB, filepath::AbstractString; events_dir::AbstractString="events")
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

    event_id = isnothing(submission) ? nothing : get(submission, :event_id, nothing)
    has_submission = submission !== nothing
    is_new = false
    is_update = false
    no_cost_config = false

    # Wrap all database modifications in a transaction (safe for nesting)
    # Record that we processed this email
    with_transaction(db) do
        DBInterface.execute(db, """
            INSERT INTO processed_emails (file_hash, filename, processed_at, has_submission, event_id)
            VALUES (?, ?, ?, ?, ?)
        """, [file_hash, filename, now(), has_submission, event_id])
    end

    if !has_submission
        return (; has_submission, is_new, is_update, skipped=true, no_cost_config)
    end
    if !(EmailParser.is_valid_email(submission.email))
        @warn """
        Detected registration with invalid email:
        Vorname: $(submission.first_name)
        Nachname: $(submission.last_name)
        E-Mail: $(submission.email)
        """
        return (; has_submission, is_new, is_update, skipped=true, no_cost_config)
    end

    # Parse email date
    email_date = haskey(parsed.headers, "date") ?
        EmailParser.parse_email_date(parsed.headers["date"]) : now()



    # Store raw submission
    fields_json = JSON.json(submission.fields)
    with_transaction(db) do
        DBInterface.execute(db, """
            INSERT INTO submissions (id, file_hash, event_id, email, first_name, last_name,
                                        fields, email_date, email_from, email_subject, created_at)
            VALUES (nextval('submission_id_seq'), ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [file_hash, submission.event_id, submission.email,
                submission.first_name, submission.last_name, fields_json,
                email_date, get(parsed.headers, "from", nothing),
                get(parsed.headers, "subject", nothing), now()])
    end

    # Get the submission ID we just inserted
    sub_result = DBInterface.execute(db,
        "SELECT currval('submission_id_seq')")
    submission_id = first(collect(sub_result))[1]

    # Check for existing registration (resubmission case)
    existing = DBInterface.execute(db, """
        SELECT id, reference_number FROM registrations
        WHERE event_id = ? AND email = ? AND deleted_at IS NULL
    """, [submission.event_id, submission.email])
    existing_rows = collect(existing)

    cfg = load_event_config(submission.event_id, events_dir)
    if isnothing(cfg)
        config_path = joinpath(events_dir, "$(submission.event_id).toml")
        generate_event_config_template(submission.event_id, config_path; db)
        cfg = load_event_config(submission.event_id, events_dir)
        @info "Auto-created event configuration" event_id=submission.event_id path=config_path
        @assert !isnothing(cfg) "Automatic config creation failed"
    end
    # Calculate cost (returns nothing if no cost config exists)
    computed_cost = calculate_cost(cfg, submission.fields)

    # Use config file hash for versioning
    cost_rules_hash = cfg.config_hash
    cost_computed_at = now()

    if isempty(existing_rows)
        # New registration
        with_transaction(db) do
            DBInterface.execute(db, """
                INSERT INTO registrations (id, event_id, email, reference_number,
                                            first_name, last_name, fields, computed_cost,
                                            cost_rules_hash, cost_computed_at,
                                            latest_submission_id, registration_date, updated_at,
                                            status, valid_from)
                VALUES (nextval('registration_id_seq'), ?, ?, 'TEMP', ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?)
            """, [submission.event_id, submission.email,
                    submission.first_name, submission.last_name, fields_json,
                    computed_cost, cost_rules_hash, cost_computed_at,
                    submission_id, email_date, now(), now()])
        end

        # Get the registration ID and generate reference number
        reg_result = DBInterface.execute(db, "SELECT currval('registration_id_seq')")
        reg_id = first(collect(reg_result))[1]

        ref_number = generate_reference_number(submission.event_id, reg_id)
        with_transaction(db) do
            DBInterface.execute(db, """
                UPDATE registrations SET reference_number = ? WHERE id = ?
            """, [ref_number, reg_id])
        end

        # Log financial transaction for the charge (if cost was computed)
        if computed_cost !== nothing
            log_financial_transaction!(db, reg_id, "charge", -computed_cost;
                reference_id=reg_id, reference_table="registrations",
                effective_date=Date(email_date),
                notes="Initial registration charge")
        end

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
        with_transaction(db) do
            DBInterface.execute(db, """
                UPDATE registrations SET
                    first_name = ?,
                    last_name = ?,
                    fields = ?,
                    computed_cost = ?,
                    cost_rules_hash = ?,
                    cost_computed_at = ?,
                    latest_submission_id = ?,
                    updated_at = ?
                WHERE id = ?
            """, [submission.first_name, submission.last_name, fields_json,
                    computed_cost, cost_rules_hash, cost_computed_at,
                    submission_id, now(), reg_id])
        end

        is_update = true
        if computed_cost === nothing
            no_cost_config = true
            @warn "Updated registration (resubmission) - NO COST CONFIG" event=submission.event_id email=submission.email reference=ref_number
        else
            @info "Updated registration (resubmission)" event=submission.event_id email=submission.email reference=ref_number cost=computed_cost
        end
    end

    return (has_submission=has_submission, is_new=is_new, is_update=is_update, skipped=false, no_cost_config=no_cost_config, event_id)
end
# Columns and row type used for table-editing (id, reference_number, email, first_name, last_name)
const EDIT_COLUMNS = ["id", "reference_number", "email", "first_name", "last_name"]

"""
    get_registrations_for_edit(db, event_id; name=nothing, since=nothing) -> (columns, rows)

Return a table suitable for TableEdit: (columns::Vector{String}, rows::Vector{NamedTuple})
with columns id, reference_number, email, first_name, last_name. Rows are filtered by
optional name pattern (regex on first_name/last_name) and since date (registration_date >= since).
Used by edit-registrations CLI to dump data for the editor.
"""
function get_registrations_for_edit(db::DuckDB.DB, event_id::AbstractString;
                                    name::Union{String,Nothing}=nothing,
                                    since::Union{String,Date,Nothing}=nothing)
    since_date = if since === nothing
        nothing
    elseif since isa Date
        since
    else
        try
            Date(since, dateformat"yyyy-mm-dd")
        catch
            nothing
        end
    end

    result = DBInterface.execute(db, """
        SELECT id, reference_number, email, first_name, last_name, registration_date
        FROM registrations
        WHERE event_id = ? AND deleted_at IS NULL
        ORDER BY last_name, first_name
    """, [event_id])

    rows = []
    for row in result
        id_, ref, email, first_name, last_name, reg_date = row
        if name !== nothing
            pattern = Regex(name, "i")
            full_name = string(something(first_name, ""), " ", something(last_name, ""))
            occursin(pattern, full_name) || continue
        end
        if since_date !== nothing && (reg_date === nothing || reg_date === missing)
            continue
        end
        if since_date !== nothing && reg_date !== nothing && !(reg_date isa Missing)
            Date(reg_date) >= since_date || continue
        end
        # Use string(id) so TableEdit diff keys match parsed rows (parsed id is string)
        push!(rows, (
            id = string(id_),
            reference_number = string(something(ref, "")),
            email = string(something(email, "")),
            first_name = string(something(first_name, "")),
            last_name = string(something(last_name, "")),
        ))
    end

    return (EDIT_COLUMNS, rows)
end

"""
    update_registration!(db, registration_id; email=nothing, first_name=nothing, last_name=nothing)

Update editable fields of a registration. Only non-nothing keyword arguments are applied.
Used after table-editing to apply user changes in a single transaction with other updates.
"""
function update_registration!(db::DuckDB.DB, registration_id::Integer;
                              email::Union{String,Nothing}=nothing,
                              first_name::Union{String,Nothing}=nothing,
                              last_name::Union{String,Nothing}=nothing)
    updates = String[]
    params = Any[]
    if email !== nothing
        push!(updates, "email = ?")
        push!(params, email)
    end
    if first_name !== nothing
        push!(updates, "first_name = ?")
        push!(params, first_name)
    end
    if last_name !== nothing
        push!(updates, "last_name = ?")
        push!(params, last_name)
    end
    isempty(updates) && return
    push!(params, now())
    push!(updates, "updated_at = ?")
    push!(params, registration_id)
    DBInterface.execute(db, "UPDATE registrations SET " * join(updates, ", ") * " WHERE id = ?", params)
    return
end

"""
Get all registrations for an event (excluding deleted ones).
"""
function get_registrations(db::DuckDB.DB, event_id::AbstractString)
    result = DBInterface.execute(db, """
        SELECT id, email, reference_number, first_name, last_name,
               fields, computed_cost, registration_date
        FROM registrations
        WHERE event_id = ? AND deleted_at IS NULL
        ORDER BY registration_date
    """, [event_id])
    return collect(result)
end

"""
Collect all unique field names used by registrations in an event.
"""
function get_registration_field_names(db::DuckDB.DB, event_id::AbstractString)
    field_result = DBInterface.execute(db, """
        SELECT DISTINCT json_keys(fields) as keys
        FROM registrations
        WHERE event_id = ? AND deleted_at IS NULL
    """, [event_id])

    all_fields = Set{String}()
    for row in field_result
        keys = row[1]
        if keys === nothing
            continue
        end
        for key in keys
            push!(all_fields, string(key))
        end
    end

    return sort!(collect(all_fields))
end

"""
Resolve an identifier (numeric id or reference number) to a registration id.
Returns the registration id or nothing if not found.
"""
function resolve_registration_identifier(db::DuckDB.DB, identifier::AbstractString)
    id_str = strip(identifier)
    # Try numeric id first
    try
        reg_id = parse(Int, id_str)
        result = DBInterface.execute(db, "SELECT id FROM registrations WHERE id = ?", [reg_id])
        rows = collect(result)
        return isempty(rows) ? nothing : reg_id
    catch
        # Not a number; try reference number
    end
    reg = get_registration_by_reference(db, uppercase(id_str))
    return reg === nothing ? nothing : reg[1]
end

"""
Get a registration by reference number.
"""
function get_registration_by_reference(db::DuckDB.DB, reference::AbstractString)
    result = DBInterface.execute(db, """
        SELECT r.id, r.event_id, r.email, r.reference_number, r.first_name, r.last_name,
               r.fields, r.computed_cost, r.registration_date
        FROM registrations r
        WHERE r.reference_number = ? AND r.deleted_at IS NULL
    """, [uppercase(strip(reference))])
    rows = collect(result)
    return isempty(rows) ? nothing : rows[1]
end

struct RegistrationDetailTable
    event_id::String
    event_name::Union{String,Nothing}
    columns::Vector{String}
    rows::Vector{Vector{Any}}
end

"""
Build a tabular view of all registration details for an event.
"""
function get_registration_detail_table(db::DuckDB.DB, event_id::AbstractString;
                                       events_dir::Union{Nothing,String}=nothing)
    event_result = DBInterface.execute(db,
        "SELECT event_name FROM events WHERE event_id = ?",
        [event_id])
    event_rows = collect(event_result)
    event_name = isempty(event_rows) ? nothing : event_rows[1][1]

    registrations = get_registrations(db, event_id)
    fields = get_registration_field_names(db, event_id)

    base_columns = [
        "id",
        "reference_number",
        "first_name",
        "last_name",
        "email",
        "computed_cost",
        "registration_date",
    ]

    preferred_columns = try
        get_registration_detail_columns(event_id, events_dir)
    catch err
        @warn "Failed to load registration detail column order" event_id=event_id events_dir=events_dir exception=err
        nothing
    end

    columns = String[]
    seen = Set{String}()

    function maybe_add_column!(col::String)
        if !(col in seen)
            push!(columns, col)
            push!(seen, col)
        end
    end

    if preferred_columns !== nothing
        for col in preferred_columns
            maybe_add_column!(col)
        end
    else
        for col in base_columns
            maybe_add_column!(col)
        end

        for col in fields
            maybe_add_column!(col)
        end
    end

    rows = Vector{Vector{Any}}(undef, length(registrations))

    for (idx, reg) in enumerate(registrations)
        parsed_fields = Dict{String,Any}()
        raw_fields = reg[6]
        if raw_fields !== nothing
            try
                parsed = JSON.parse(raw_fields)
                if parsed isa AbstractDict
                    for (k, v) in parsed
                        parsed_fields[string(k)] = v
                    end
                end
            catch
                # fall back to empty dict on parse errors
            end
        end

        base_map = Dict{String,Any}(
            "id" => reg[1],
            "reference_number" => reg[3],
            "first_name" => reg[4],
            "last_name" => reg[5],
            "email" => reg[2],
            "computed_cost" => reg[7],
            "registration_date" => reg[8],
        )

        row = Vector{Any}(undef, length(columns))
        for (col_idx, col_name) in enumerate(columns)
            if haskey(base_map, col_name)
                row[col_idx] = base_map[col_name]
            else
                row[col_idx] = get(parsed_fields, col_name, nothing)
            end
        end

        rows[idx] = row
    end

    return RegistrationDetailTable(event_id, event_name, columns, rows)
end

"""
Grant a subsidy (financial help) to a registration.
The subsidy amount is treated as a credit, reducing the remaining amount to pay.
Multiple subsidies can be granted and they stack.
"""
function grant_subsidy!(db::DuckDB.DB, registration_id::Integer,
                        amount::Real; reason::String="", granted_by::String="")
    # Insert subsidy record
    subsidy_id = nothing
    with_transaction(db) do
        DBInterface.execute(db, """
            INSERT INTO subsidies (id, registration_id, amount, reason, granted_by, granted_at)
            VALUES (nextval('subsidy_id_seq'), ?, ?, ?, ?, ?)
        """, [registration_id, amount, reason, granted_by, now()])

        # Get the subsidy ID we just inserted
        result = DBInterface.execute(db, "SELECT currval('subsidy_id_seq')")
        subsidy_id = first(collect(result))[1]
    end

    # Log financial transaction (subsidy is a credit, so positive amount)
    log_financial_transaction!(db, registration_id, "subsidy", amount;
        reference_id=subsidy_id, reference_table="subsidies",
        recorded_by=granted_by, notes=reason)

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
Cancel a registration (soft delete: set status = 'cancelled').
Payments, subsidies, and ledger rows remain; the registration is no longer active.
Uses with_transaction for consistency.
"""
function cancel_registration!(db::DuckDB.DB, registration_id::Integer)
    with_transaction(db) do
        result = DBInterface.execute(db, """
            UPDATE registrations SET status = 'cancelled', updated_at = ?
            WHERE id = ?
        """, [now(), registration_id])
        # DuckDB execute returns a result; check that a row was updated if needed
    end
    @info "Cancelled registration" registration_id=registration_id
end

"""
Cancel a registration by identifier (numeric id or reference number).
"""
function cancel_registration!(db::DuckDB.DB, identifier::AbstractString)
    reg_id = resolve_registration_identifier(db, identifier)
    if reg_id === nothing
        error("Registration not found for identifier: $identifier")
    end
    cancel_registration!(db, reg_id)
end

"""
Recalculate all costs for an event (e.g., after updating cost rules).
Subsidies are unaffected - they remain as separate credits.

Returns detailed results including any warnings from cost calculation.
Use `strict=true` to fail on any validation errors instead of just warning.
Use `dry_run=true` to preview changes without applying them.
"""
function recalculate_costs!(db::DuckDB.DB, event_id::AbstractString;
                            events_dir::AbstractString="events",
                            strict::Bool=false, dry_run::Bool=false, verbose::Bool=false)
    registrations = get_registrations(db, event_id)

    if isempty(registrations)
        @warn "No registrations found for event" event_id=event_id
        return (success=true, updated=0, warnings=0, details=[])
    end

    cfg = load_event_config(event_id, events_dir)
    if cfg === nothing
        error("No cost configuration file found for event: $event_id")
    end

    rules = materialize_cost_rules(cfg)
    cost_rules_hash = cfg.config_hash
    cost_computed_at = now()

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

    # Apply all updates in a transaction (safe for nesting)
    for upd in updates
        with_transaction(db) do
            DBInterface.execute(db, """
                UPDATE registrations SET computed_cost = ?, cost_rules_hash = ?,
                                        cost_computed_at = ?, updated_at = ?
                WHERE id = ?
            """, [upd.new_cost, cost_rules_hash, cost_computed_at, now(), upd.id])
        end
    end

    @info "Recalculated costs for event" event_id=event_id count=length(registrations) warnings=length(all_warnings)

    return (success=true, updated=length(updates), warnings=length(all_warnings), details=updates)
end

"""
Mark a registration as deleted (soft delete).
"""
function delete_registration!(db::DuckDB.DB, registration_id::Integer)
    with_transaction(db) do
        DBInterface.execute(db, """
            UPDATE registrations SET deleted_at = ? WHERE id = ?
        """, [now(), registration_id])
    end
    @info "Marked registration as deleted" registration_id=registration_id
end

"""
Mark a registration as deleted by reference number.
"""
function delete_registration!(db::DuckDB.DB, reference::AbstractString)
    reg = get_registration_by_reference(db, reference)
    if reg === nothing
        error("Registration not found for reference: $reference")
    end
    delete_registration!(db, reg[1])
end

"""
Restore a deleted registration (un-delete).
"""
function restore_registration!(db::DuckDB.DB, registration_id::Integer)
    with_transaction(db) do
        DBInterface.execute(db, """
            UPDATE registrations SET deleted_at = NULL WHERE id = ?
        """, [registration_id])
    end
    @info "Restored registration" registration_id=registration_id
end

"""
Restore a deleted registration by reference number.
"""
function restore_registration!(db::DuckDB.DB, reference::AbstractString)
    reg = get_registration_by_reference_including_deleted(db, reference)
    if reg === nothing
        error("Registration not found for reference: $reference")
    end
    restore_registration!(db, reg[1])
end

"""
Get a registration by reference number, including deleted ones.
"""
function get_registration_by_reference_including_deleted(db::DuckDB.DB, reference::AbstractString)
    result = DBInterface.execute(db, """
        SELECT r.id, r.event_id, r.email, r.reference_number, r.first_name, r.last_name,
               r.fields, r.computed_cost, r.registration_date, r.deleted_at
        FROM registrations r
        WHERE r.reference_number = ?
    """, [uppercase(strip(reference))])
    rows = collect(result)
    return isempty(rows) ? nothing : rows[1]
end

"""
Get all deleted registrations for an event.
"""
function get_deleted_registrations(db::DuckDB.DB, event_id::AbstractString)
    result = DBInterface.execute(db, """
        SELECT id, email, reference_number, first_name, last_name,
               fields, computed_cost, registration_date, deleted_at
        FROM registrations
        WHERE event_id = ? AND deleted_at IS NOT NULL
        ORDER BY deleted_at DESC
    """, [event_id])
    return collect(result)
end

end # module Registrations
