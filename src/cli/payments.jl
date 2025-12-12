# Payment and transfer related commands

"""
Import bank transfer CSV file.
"""
function cmd_import_bank_csv(csv_file::String;
    db_path::String="events.duckdb",
    delimiter::String=";",
    decimal_comma::Bool=true)

    return with_cli_logger() do
        if !isfile(csv_file)
            @error "CSV file not found" csv_file=csv_file
            return 1
        end

        return require_database(db_path) do db
            @info "Importing bank transfers" csv_file=csv_file delimiter=delimiter decimal_comma=decimal_comma
            result = import_bank_csv!(db, csv_file; delimiter=first(delimiter), decimal_comma=decimal_comma)

            summary = [
                "New transfers: $(result.new)",
                "Skipped (duplicates): $(result.skipped)",
            ]

            @info "✓ Bank transfer import complete!\n$(join(summary, "\n"))"
            return 0
        end
    end
end

"""
Match bank transfers to registrations.
"""
function cmd_match_transfers(;
    event_id::Union{String,Nothing}=nothing,
    db_path::String="events.duckdb")

    return with_cli_logger() do
        return require_database(db_path) do db
            @info "Matching bank transfers to registrations..." event_id=event_id
            result = match_transfers!(db; event_id=event_id)

            summary = [
                "Matched: $(result.matched)",
                "Unmatched: $(length(result.unmatched))",
            ]

            if !isempty(result.unmatched)
                push!(summary, "To manually match unmatched transfers:\n  eventreg list-unmatched\n  eventreg manual-match <transfer_id> <reference>")
                @warn "⚠ Matching complete with unmatched transfers\n$(join(summary, "\n"))"
            else
                @info "✓ Matching complete!\n$(join(summary, "\n"))"
            end
            return 0
        end
    end
end

"""
List unmatched bank transfers.
"""
function cmd_list_unmatched(; db_path::String="events.duckdb")
    return with_cli_logger() do
        return require_database(db_path) do db
            unmatched = get_unmatched_transfers(db)

            if isempty(unmatched)
                @info "✓ No unmatched transfers!"
            else
                rows = String[]
                push!(rows, "Unmatched Transfers:")
                push!(rows, "-" ^ 80)
                for transfer in unmatched
                    id, date, amount, sender, reference = transfer
                    push!(rows, "  ID: $id")
                    push!(rows, "  Date: $date")
                    push!(rows, "  Amount: $amount €")
                    push!(rows, "  Sender: $sender")
                    push!(rows, "  Reference: $reference")
                    push!(rows, "")
                end
                @info join(rows, "\n")
            end
            return 0
        end
    end
end

"""
Manually match a transfer to a registration.
"""
function cmd_manual_match(transfer_id::Int, reference::String;
    db_path::String="events.duckdb")

    return with_cli_logger() do
        return require_database(db_path) do db
            @info "Matching transfer to registration" transfer_id=transfer_id reference=reference
            manual_match!(db, transfer_id, reference)

            @info "✓ Match created successfully!"
            return 0
        end
    end
end

"""
Grant a subsidy to a registration.
"""
function cmd_grant_subsidy(identifier::String, amount::Float64;
    reason::String="",
    granted_by::String="cli",
    db_path::String="events.duckdb")

    return with_cli_logger() do
        return require_database(db_path) do db
            @info "Granting subsidy" identifier=identifier amount=amount reason=reason
            grant_subsidy!(db, identifier, amount; reason=reason, granted_by=granted_by)

            @info "✓ Subsidy granted successfully!"
            return 0
        end
    end
end
