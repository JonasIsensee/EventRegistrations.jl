# Registration listing commands

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
