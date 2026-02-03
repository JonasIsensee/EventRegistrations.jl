# Registration listing commands

const EDIT_REGISTRATIONS_KEY_COLUMNS = ["id"]
const EDIT_REGISTRATIONS_REQUIRED_COLUMNS = ["id", "reference_number", "email", "first_name", "last_name"]
const EDIT_REGISTRATIONS_COLUMN_TYPES = Dict("id" => Int)

"""
Edit registrations in an external editor (TableEdit.jl).
Caller must open db; run_cli opens it before calling.
"""
function cmd_edit_registrations(db::DuckDB.DB; event_id::Union{String,Nothing}=nothing,
        name::Union{String,Nothing}=nothing,
        since::Union{String,Nothing}=nothing,
        spawn_editor::Bool=true)
    local_event_id = event_id
    if local_event_id === nothing
        local_event_id = get_most_recent_event(db)
        if local_event_id === nothing
            @error "No events with registrations found; specify --event-id"
            return 1
        end
        @info "Using most recent event" event_id=local_event_id
    end

    columns, rows = get_registrations_for_edit(db, local_event_id; name=name, since=since)
    if isempty(rows)
        @info "No registrations match the filter" event_id=local_event_id name=name since=since
        return 0
    end

    table = (columns, rows)
    if !spawn_editor
        # Test-friendly: return (path, finish_and_apply) so caller can edit file and call callback with an open db
        (path, finish_fn) = TableEdit.edit_table(
            table;
            key_columns = EDIT_REGISTRATIONS_KEY_COLUMNS,
            required_columns = EDIT_REGISTRATIONS_REQUIRED_COLUMNS,
            column_types = EDIT_REGISTRATIONS_COLUMN_TYPES,
            original_table = table,
            return_mode = :diff,
            spawn_editor = false,
            header_comment_lines = ["Edit registration fields below. Save and close to apply. Do not remove or reorder rows."],
        )
        # Callback takes db so caller can pass an open connection (require_database closes db on return)
        finish_and_apply(open_db) = _apply_edit_result(open_db, finish_fn)
        return (path, finish_and_apply)
    end

    ok, result, errors = TableEdit.edit_table(
        table;
        key_columns = EDIT_REGISTRATIONS_KEY_COLUMNS,
        required_columns = EDIT_REGISTRATIONS_REQUIRED_COLUMNS,
        column_types = EDIT_REGISTRATIONS_COLUMN_TYPES,
        original_table = table,
        return_mode = :diff,
        spawn_editor = true,
        header_comment_lines = ["Edit registration fields below. Save and close to apply. Do not remove or reorder rows."],
    )

    code, _ = _apply_edit_result(db, ok, result, errors)
    return code
end

"""
Internal: parse result from finish_fn() or (ok, result, errors), apply updates if valid, return (exit_code, applied_count).
When called with (db, finish_fn), runs finish_fn() and then applies; when called with (db, ok, result, errors), applies directly.
"""
function _apply_edit_result(db, finish_fn::Function)
    ok, result, errors = finish_fn()
    return _apply_edit_result(db, ok, result, errors)
end

function _apply_edit_result(db, ok, result, errors)
    if !ok
        @error "Validation failed; no changes applied"
        for e in errors
            col_str = isa(e.column, Int) ? "column $(e.column)" : string(e.column)
            @error "Line $(e.line) ($col_str): $(e.message)"
        end
        return (1, 0)
    end
    diff = result
    if isempty(diff.modified)
        @info "No changes detected"
        return (0, 0)
    end
    with_transaction(db) do
        for (_old, new_row) in diff.modified
            reg_id = new_row.id isa Integer ? new_row.id : parse(Int, string(new_row.id))
            update_registration!(db, reg_id;
                email = string(new_row.email),
                first_name = string(new_row.first_name),
                last_name = string(new_row.last_name))
        end
    end
    @info "Updated $(length(diff.modified)) registration(s)"
    return (0, length(diff.modified))
end

"""
List registrations with optional filtering.
Caller must open db; run_cli opens it before calling.
"""
function cmd_list_registrations(db::DuckDB.DB, event_id::Union{String,Nothing}=nothing;
        filter::String="all",
        name::Union{String,Nothing}=nothing,
        email::Union{String,Nothing}=nothing,
        since::Union{String,Nothing}=nothing)
    # Default to most recent event if not specified
    local_event_id = event_id
    if local_event_id === nothing
        local_event_id = get_most_recent_event(db)
        if local_event_id === nothing
            @error "No events with registrations found"
            return 1
        end
        @info "Using most recent event" event_id=local_event_id
    end

    # Parse since date if provided
    since_date = if since !== nothing
        try
            Date(since, dateformat"yyyy-mm-dd")
        catch
            @error "Invalid date format for --since. Use yyyy-mm-dd" since=since
            return 1
        end
    else
        nothing
    end

    # Build filter from options
    reg_filter = RegistrationFilter(
        unpaid_only = filter == "unpaid",
        problems_only = filter == "problems",
        paid_only = filter == "paid",
        name_pattern = name,
        email_pattern = email,
        since = since_date
    )

    # Get registration data
    table_data = get_registration_table_data(db, local_event_id)

    if table_data.total_registrations == 0
        @info "No registrations found for event" event_id=local_event_id
        return 0
    end

    # Print colored table
    print_registration_table(table_data; filter=reg_filter)
    return 0
end

"""
Resolve identifier (numeric id or reference number) to (reg_id, reference_number, event_id) for display.
Returns nothing if not found.
"""
function _resolve_registration_for_display(db::DuckDB.DB, identifier::AbstractString)
    id_str = strip(identifier)
    # Try numeric id first
    try
        reg_id = parse(Int, id_str)
        result = DBInterface.execute(db, """
            SELECT id, reference_number, event_id FROM registrations WHERE id = ?
        """, [reg_id])
        rows = collect(result)
        isempty(rows) && return nothing
        r = rows[1]
        return (reg_id=r[1], reference_number=string(r[2]), event_id=string(r[3]))
    catch
        nothing
    end
    # Try reference number
    reg = get_registration_by_reference(db, uppercase(id_str))
    reg === nothing && return nothing
    return (reg_id=reg[1], reference_number=string(reg[3]), event_id=string(reg[2]))
end

"""
Delete (cancel) a registration by id or reference number.
Soft delete: sets status to 'cancelled'. Prompts for confirmation unless --yes.
Caller must open db; run_cli opens it before calling.
"""
function cmd_delete_registration(db::DuckDB.DB, identifier::String;
        event_id::Union{String,Nothing}=nothing,
        yes::Bool=false)
    resolved = _resolve_registration_for_display(db, identifier)
    if resolved === nothing
        @error "Registration not found" identifier=identifier
        return 1
    end
    if event_id !== nothing && resolved.event_id != event_id
        @error "Registration does not belong to event" identifier=identifier resolved_event=resolved.event_id expected_event=event_id
        return 1
    end
    if !yes
        ok = prompt_user_bool("Cancel registration $(resolved.reference_number) (event $(resolved.event_id))? "; default=false)
        if !ok
            @info "Aborted."
            return 0
        end
    end
    try
        cancel_registration!(db, resolved.reg_id)
        @info "✓ Registration cancelled" reference=resolved.reference_number
        return 0
    catch e
        @error "Failed to cancel registration" exception=(e, catch_backtrace())
        return 1
    end
end

"""
Show detailed overview for an event.
Caller must open db; run_cli opens it before calling.
"""
function cmd_event_overview(db::DuckDB.DB, event_id::String)
    overview = event_overview(db, event_id)

    if overview === nothing
        @error "Event not found" event_id=event_id
        return 1
    end

    lines = [
        "Event: $(overview.event_name)",
        "ID: $(overview.event_id)",
        "-" ^ 80,
        "  Total registrations: $(overview.registrations)",
        "  Fully paid: $(overview.fully_paid)",
        "  Partially paid: $(overview.partially_paid)",
        "  Unpaid: $(overview.unpaid)",
        "",
        "  Total expected: $(overview.total_expected) €",
        "  Total received (payments): $(overview.total_received) €",
        "  Total subsidies: $(overview.total_subsidies) €",
        "  Total credits: $(overview.total_credits) €",
        "  Outstanding: $(overview.outstanding) €",
    ]
    @info join(lines, "\n")
    return 0
end

"""
Mark a registration as deleted (soft delete).
Caller must open db; run_cli opens it before calling.
"""
function cmd_soft_delete_registration(db::DuckDB.DB, reference::String)
    try
        delete_registration!(db, reference)
        @info "✓ Registration deleted" reference=reference
        return 0
    catch e
        @error "Failed to delete registration" reference=reference exception=e
        return 1
    end
end

"""
Restore a deleted registration.
Caller must open db; run_cli opens it before calling.
"""
function cmd_restore_registration(db::DuckDB.DB, reference::String)
    try
        restore_registration!(db, reference)
        @info "✓ Registration restored" reference=reference
        return 0
    catch e
        @error "Failed to restore registration" reference=reference exception=e
        return 1
    end
end

"""
List all deleted registrations for an event.
Caller must open db; run_cli opens it before calling.
"""
function cmd_list_deleted_registrations(db::DuckDB.DB, event_id::Union{String,Nothing}=nothing)
        # Default to most recent event if not specified
        local_event_id = event_id
        if local_event_id === nothing
            local_event_id = get_most_recent_event(db)
            if local_event_id === nothing
                @error "No events with registrations found"
                return 1
            end
            @info "Using most recent event" event_id=local_event_id
        end

        deleted = get_deleted_registrations(db, local_event_id)
        
        if isempty(deleted)
            @info "No deleted registrations found for event" event_id=local_event_id
            return 0
        end

        println()
        println("Deleted Registrations: $local_event_id")
        println("=" ^ 80)
        println()
        
        # Print table header
        println(lpad("Reference", 15), " | ", 
                lpad("Name", 30), " | ",
                lpad("Email", 30), " | ",
                lpad("Deleted At", 20))
        println("-" ^ 80)
        
        for reg in deleted
            id, email, ref, first_name, last_name, fields, cost, reg_date, deleted_at = reg
            name = string(something(first_name, ""), " ", something(last_name, ""))
            deleted_str = deleted_at === nothing ? "" : string(deleted_at)
            println(lpad(string(ref), 15), " | ",
                    lpad(name, 30), " | ",
                    lpad(string(email), 30), " | ",
                    lpad(deleted_str, 20))
        end
        
        println()
        println("Total: $(length(deleted)) deleted registration(s)")
        return 0
    end
end
