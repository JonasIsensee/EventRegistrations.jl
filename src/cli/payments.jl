# Payment and transfer related commands

"""
Import bank transfer CSV file.
"""
function cmd_import_bank_csv(csv_file::String;
    db_path::String="events.duckdb",
    delimiter::String=";",
    decimal_comma::Bool=true)

    if !isfile(csv_file)
        println("❌ Error: CSV file not found: $csv_file")
        return 1
    end

    return require_database(db_path) do db
        println("Importing bank transfers from: $csv_file")
        result = import_bank_csv!(db, csv_file; delimiter=first(delimiter), decimal_comma=decimal_comma)

        println("\n✓ Bank transfer import complete!")
        println("  New transfers: $(result.new)")
        println("  Skipped (duplicates): $(result.skipped)")
        return 0
    end
end

"""
Match bank transfers to registrations.
"""
function cmd_match_transfers(;
    event_id::Union{String,Nothing}=nothing,
    db_path::String="events.duckdb")

    return require_database(db_path) do db
        println("Matching bank transfers to registrations...")
        result = match_transfers!(db; event_id=event_id)

        println("\n✓ Matching complete!")
        println("  Matched: $(result.matched)")
        println("  Unmatched: $(length(result.unmatched))")

        if !isempty(result.unmatched)
            println("\nTo manually match unmatched transfers:")
            println("  eventreg list-unmatched")
            println("  eventreg manual-match <transfer_id> <reference>")
        end
        return 0
    end
end

"""
List unmatched bank transfers.
"""
function cmd_list_unmatched(; db_path::String="events.duckdb")
    return require_database(db_path) do db
        unmatched = get_unmatched_transfers(db)

        if isempty(unmatched)
            println("✓ No unmatched transfers!")
        else
            println("\nUnmatched Transfers:")
            println("-" ^ 80)
            for transfer in unmatched
                id, date, amount, sender, reference = transfer
                println("  ID: $id")
                println("  Date: $date")
                println("  Amount: $amount €")
                println("  Sender: $sender")
                println("  Reference: $reference")
                println()
            end
        end
        return 0
    end
end

"""
Manually match a transfer to a registration.
"""
function cmd_manual_match(transfer_id::Int, reference::String;
    db_path::String="events.duckdb")

    return require_database(db_path) do db
        println("Matching transfer $transfer_id to registration $reference...")
        manual_match!(db, transfer_id, reference)

        println("✓ Match created successfully!")
        return 0
    end
end

"""
Grant a subsidy to a registration.
"""
function cmd_grant_subsidy(identifier::String, amount::Float64;
    reason::String="",
    granted_by::String="cli",
    db_path::String="events.duckdb")

    return require_database(db_path) do db
        println("Granting subsidy of $amount € to $identifier...")
        grant_subsidy!(db, identifier, amount; reason=reason, granted_by=granted_by)

        println("✓ Subsidy granted successfully!")
        return 0
    end
end
