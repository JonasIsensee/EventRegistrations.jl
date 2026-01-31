# Registration listing commands

const EDIT_REGISTRATIONS_KEY_COLUMNS = ["id"]
const EDIT_REGISTRATIONS_REQUIRED_COLUMNS = ["id", "reference_number", "email", "first_name", "last_name"]
const EDIT_REGISTRATIONS_COLUMN_TYPES = Dict("id" => Int)

"""
Edit registrations in an external editor (TableEdit.jl).
Queries DB for matching registrations, dumps to a temp file, opens the editor;
on save, parses and validates, then applies changes (update_registration!) in one transaction.
"""
function cmd_edit_registrations(; event_id::Union{String,Nothing}=nothing,
                                 name::Union{String,Nothing}=nothing,
                                 since::Union{String,Nothing}=nothing,
                                 db_path::String="events.duckdb",
                                 spawn_editor::Bool=true)
    return require_database(db_path) do db
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
Provides a quick view of registrations with payment status.
"""
function cmd_list_registrations(event_id::Union{String,Nothing}=nothing;
                                 db_path::String="events.duckdb",
                                 filter::String="all",
                                 name::Union{String,Nothing}=nothing,
                                 email::Union{String,Nothing}=nothing,
                                 since::Union{String,Nothing}=nothing)
    return require_database(db_path) do db
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
end

"""
Show detailed overview for an event.
"""
function cmd_event_overview(event_id::String; db_path::String="events.duckdb")
    return require_database(db_path) do db
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
end
