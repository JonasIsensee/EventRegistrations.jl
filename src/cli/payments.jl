# Payment and transfer related commands

"""
Import bank transfer CSV file.
Caller must open db; run_cli opens it before calling.
"""
function cmd_import_bank_csv(db::DuckDB.DB, csv_file::String;
    delimiter::String=";",
    decimal_comma::Bool=true)
    @info "Importing bank transfers" csv_file=csv_file delimiter=delimiter decimal_comma=decimal_comma
    result = import_bank_csv!(db, csv_file; delimiter=first(delimiter), decimal_comma=decimal_comma)
    summary = [
        "New transfers: $(result.new)",
        "Skipped (duplicates): $(result.skipped)",
    ]
    @info "✓ Bank transfer import complete!\n$(join(summary, "\n"))"
    return 0
end

"""
Match bank transfers to registrations.
Caller must open db; run_cli opens it before calling.
"""
function cmd_match_transfers(db::DuckDB.DB; event_id::Union{String,Nothing}=nothing)
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

"""
List unmatched bank transfers.
Caller must open db; run_cli opens it before calling.
"""
function cmd_list_unmatched(db::DuckDB.DB)
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

"""
Manually match a transfer to a registration.
Caller must open db; run_cli opens it before calling.
"""
function cmd_manual_match(db::DuckDB.DB, transfer_id::Int, reference::String)
    @info "Matching transfer to registration" transfer_id=transfer_id reference=reference
    manual_match!(db, transfer_id, reference)
    @info "✓ Match created successfully!"
    return 0
end

"""
Grant a subsidy to a registration.
Caller must open db; run_cli opens it before calling.
"""
function cmd_grant_subsidy(db::DuckDB.DB, identifier::String, amount::Float64;
    reason::String="",
    granted_by::String="cli")
    @info "Granting subsidy" identifier=identifier amount=amount reason=reason
    grant_subsidy!(db, identifier, amount; reason=reason, granted_by=granted_by)
    @info "✓ Subsidy granted successfully!"
    return 0
end

"""
Review unmatched transfers that have likely candidates (near-misses).

These are transfers where the automatic matching found a likely candidate but
didn't match because of discrepancies (e.g., wrong amount, name mismatch).

In interactive mode (default), the user can choose to match each transfer.
In non-interactive mode (--nonstop), only lists the near-misses without prompting.
"""
function cmd_review_near_misses(db::DuckDB.DB; event_id::Union{String,Nothing}=nothing,
                                 nonstop::Bool=false)
    near_misses = get_near_miss_transfers(db; event_id=event_id)
    
    if isempty(near_misses)
        @info "✓ No near-miss transfers found - all unmatched transfers have no likely candidates."
        return 0
    end
    
    @info "Found $(length(near_misses)) transfer(s) with likely candidates that weren't auto-matched."
    println()
    
    matched_count = 0
    skipped_count = 0
    
    for (idx, nm) in enumerate(near_misses)
        println("=" ^ 80)
        println("Transfer $(idx)/$(length(near_misses)) - ID: $(nm.transfer_id)")
        println("-" ^ 80)
        println("  Date:      $(nm.transfer_date)")
        println("  Amount:    $(nm.amount) €")
        println("  Sender:    $(something(nm.sender_name, "(unknown)"))")
        println("  Reference: $(something(nm.reference_text, "(none)"))")
        println()
        println("Likely candidates:")
        println()
        
        for (cidx, candidate) in enumerate(nm.candidates)
            amount_info = if candidate.amount_diff !== nothing
                diff_str = candidate.amount_diff >= 0 ? "+$(candidate.amount_diff)" : "$(candidate.amount_diff)"
                "expected $(candidate.computed_cost)€, diff: $(diff_str)€"
            else
                "no cost configured"
            end
            
            println("  [$cidx] $(candidate.reference_number) - $(candidate.first_name) $(candidate.last_name)")
            println("      Cost: $(amount_info)")
            println("      Reason: $(candidate.match_reason)")
            println("      Confidence: $(round(candidate.confidence * 100, digits=0))%")
            println()
        end
        
        if nonstop
            println("(Skipping - non-interactive mode)")
            skipped_count += 1
            continue
        end
        
        # Interactive prompt
        while true
            print("Match to candidate [1-$(length(nm.candidates))], [s]kip, [q]uit: ")
            flush(stdout)
            input = readline()
            input = strip(lowercase(input))
            
            if input == "q" || input == "quit"
                @info "Review stopped by user." matched=matched_count skipped=skipped_count remaining=length(near_misses)-idx
                return 0
            elseif input == "s" || input == "skip" || isempty(input)
                skipped_count += 1
                println("Skipped.")
                break
            else
                # Try to parse as number
                try
                    choice = parse(Int, input)
                    if choice >= 1 && choice <= length(nm.candidates)
                        candidate = nm.candidates[choice]
                        notes = "Near-miss review: $(candidate.match_reason)"
                        manual_match!(db, nm.transfer_id, candidate.reg_id; notes=notes)
                        matched_count += 1
                        @info "✓ Matched transfer $(nm.transfer_id) to $(candidate.reference_number)"
                        break
                    else
                        println("Invalid choice. Enter 1-$(length(nm.candidates)), s, or q.")
                    end
                catch
                    println("Invalid input. Enter 1-$(length(nm.candidates)), s, or q.")
                end
            end
        end
        println()
    end
    
    println("=" ^ 80)
    @info "Near-miss review complete" matched=matched_count skipped=skipped_count
    return 0
end

"""
List near-miss transfers without interactive prompts.
"""
function cmd_list_near_misses(db::DuckDB.DB; event_id::Union{String,Nothing}=nothing)
    return cmd_review_near_misses(db; event_id=event_id, nonstop=true)
end
