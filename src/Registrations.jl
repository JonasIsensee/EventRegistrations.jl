module Registrations

using DuckDB
using DBInterface
using JSON
using Dates

# Import from parent module
import ..EventRegistrations: with_transaction

# Import from parent module's submodules
using ..EmailParser
using ..ReferenceNumbers
using ..Config: generate_event_config_template, get_config_dir, get_registration_detail_columns
using ..CostCalculator

export process_email_folder!, get_registrations, export_registrations
export RegistrationDetailTable, get_registration_detail_table
export grant_subsidy!, get_subsidies, revoke_subsidy!, grant_subsidies_batch!
export get_registration_by_reference, recalculate_costs!

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
Interactively offer to create configuration files for newly detected events.

Returns a NamedTuple indicating whether processing should continue and which
configuration files were created.
"""
function handle_new_event_prompts!(db::DuckDB.DB, events::Vector{String}, config_dir::AbstractString)
    mkpath(joinpath(config_dir, "events"))
    created_configs = Dict{String,String}()

    for event_id in events
        println("\n⚠ New event detected without cost configuration: $event_id")
        create_config = prompt_user_bool("Create configuration for $event_id now?"; default=true)
        if create_config
            config_path = joinpath(config_dir, "events", "$(event_id).toml")
            try
                generate_event_config_template(event_id, config_path; db=db, config_dir=config_dir)
                println("  ✓ Created event configuration at $config_path")
                created_configs[event_id] = config_path
            catch err
                println("  ✗ Failed to create configuration for $event_id: $(sprint(showerror, err))")
            end
        end
    end

    if !isempty(created_configs)
        println("\nPlease review and edit the generated configuration file(s) before continuing.")
    end

    continue_sync = prompt_user_bool("Continue processing after updating configuration?"; default=false)
    return (continue_sync=continue_sync, created_configs=created_configs)
end

"""
Process all .eml files in a folder.
Handles resubmissions by updating existing registrations while preserving reference numbers.
Reports newly detected event IDs and suggests configuration generation.
When `prompt_for_new_events=true`, interactively offers to scaffold missing
event configuration files and may return `terminated=true` if the user chooses
to pause processing.
"""
function process_email_folder!(db::DuckDB.DB, folder_path::AbstractString;
                               config_dir::Union{Nothing,String}=nothing,
                               prompt_for_new_events::Bool=false)
    eml_files = filter(f -> endswith(lowercase(f), ".eml"), readdir(folder_path, join=true))

    # Track event IDs found in this batch
    detected_event_ids = Set{String}()
    events_without_config = Set{String}()
    resubmissions = Vector{Tuple{String,String,String}}()  # (email, event_id, reference)

    stats = (processed=0, submissions=0, new_registrations=0, updates=0, skipped=0, no_cost_config=0)
    terminated = false

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
        if prompt_for_new_events
            println("\nInteractive setup assistance is available now.")
        else
            println("\nTo configure costs for these events:")
            for event_id in sort(collect(events_without_config))
                println("\n  Event: $event_id")
                println("    1. Generate field config (if not done): eventreg generate-field-config")
                println("    2. Create event config: eventreg create-event-config $event_id")
                println("    3. Edit config/events/$event_id.toml to set cost rules")
                println("    4. Sync to database: eventreg sync-config")
                println("    5. Recalculate costs: eventreg recalculate-costs $event_id")
            end
        end
        println("="^80)
    end

    if prompt_for_new_events && !isempty(events_without_config)
        effective_config_dir = config_dir === nothing ? get_config_dir() : config_dir
        sorted_events = sort(collect(events_without_config))
        prompt_result = handle_new_event_prompts!(db, sorted_events, effective_config_dir)
        if !prompt_result.continue_sync
            terminated = true
        end
        for event_id in keys(prompt_result.created_configs)
            if event_id in events_without_config
                delete!(events_without_config, event_id)
            end
        end
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

    return merge(stats, (
        events_without_config = sort(collect(events_without_config)),
        terminated = terminated,
    ))
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

    # Wrap all database modifications in a transaction (safe for nesting)
    # Record that we processed this email
    with_transaction(db) do
        DBInterface.execute(db, """
            INSERT INTO processed_emails (file_hash, filename, processed_at, has_submission, event_id)
            VALUES (?, ?, ?, ?, ?)
        """, [file_hash, filename, now(), has_submission,
                has_submission ? submission.event_id : nothing])
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
        WHERE event_id = ? AND email = ?
    """, [submission.event_id, submission.email])
    existing_rows = collect(existing)

    # Calculate cost (returns nothing if no cost config exists)
    computed_cost = calculate_cost(db, submission.event_id, submission.fields)

    # Get cost rules hash for versioning
    cost_rules_hash = nothing
    cost_computed_at = nothing
    if computed_cost !== nothing
        rules_result = DBInterface.execute(db,
            "SELECT cost_rules FROM events WHERE event_id = ?",
            [submission.event_id])
        rules_rows = collect(rules_result)
        if !isempty(rules_rows) && rules_rows[1][1] !== nothing
            cost_rules_hash = string(hash(rules_rows[1][1]))
            cost_computed_at = now()
        end
    end

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
Collect all unique field names used by registrations in an event.
"""
function get_registration_field_names(db::DuckDB.DB, event_id::AbstractString)
    field_result = DBInterface.execute(db, """
        SELECT DISTINCT json_keys(fields) as keys
        FROM registrations
        WHERE event_id = ?
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
                                       config_dir::Union{Nothing,String}=nothing)
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

    cfg_dir = config_dir === nothing ? get_config_dir() : config_dir
    preferred_columns = try
        get_registration_detail_columns(event_id, cfg_dir)
    catch err
        @warn "Failed to load registration detail column order" event_id=event_id config_dir=cfg_dir exception=err
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

    # Get cost rules hash for versioning
    cost_rules_hash = nothing
    rules_result = DBInterface.execute(db,
        "SELECT cost_rules FROM events WHERE event_id = ?",
        [event_id])
    rules_rows = collect(rules_result)
    if !isempty(rules_rows) && rules_rows[1][1] !== nothing
        cost_rules_hash = string(hash(rules_rows[1][1]))
    end
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

end # module Registrations
