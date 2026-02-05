# Payment and transfer related commands

"""
Import bank transfer CSV file.
Caller must open db; run_cli opens it before calling.
"""
function cmd_import_bank_csv(db::DuckDB.DB, csv_file::String;
    delimiter::String=";",
    decimal_comma::Bool=true)
    @verbose_info "Importing bank transfers" csv_file delimiter decimal_comma
    result = import_bank_csv!(db, csv_file; delimiter=first(delimiter), decimal_comma=decimal_comma)
    
    if result.new > 0 || is_verbose()
        @info "Imported transfers" new=result.new skipped=result.skipped
    end
    return 0
end

"""
Match bank transfers to registrations.
Caller must open db; run_cli opens it before calling.
"""
function cmd_match_transfers(db::DuckDB.DB; event_id::Union{String,Nothing}=nothing)
    @verbose_info "Matching bank transfers..." event_id
    result = match_transfers!(db; event_id=event_id)
    
    if result.matched > 0 || is_verbose()
        @info "Matched transfers" matched=result.matched unmatched=length(result.unmatched)
    end
    
    if !isempty(result.unmatched)
        @verbose_info "Use 'eventreg list-unmatched' to see unmatched transfers"
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
        @info "No unmatched transfers"
    else
        println("Unmatched Transfers ($(length(unmatched))):")
        println("-" ^ 80)
        for transfer in unmatched
            id, date, amount, sender, reference = transfer
            println("  ID: $id | Date: $date | Amount: €$amount")
            println("  Sender: $sender")
            if !isempty(reference)
                println("  Reference: $reference")
            end
            println()
        end
    end
    return 0
end

"""
Manually match a transfer to a registration.
Caller must open db; run_cli opens it before calling.
"""
function cmd_manual_match(db::DuckDB.DB, transfer_id::Int, reference::String)
    @verbose_info "Matching transfer" transfer_id reference
    manual_match!(db, transfer_id, reference)
    @info "Match created" transfer_id reference
    return 0
end

"""
Grant a subsidy to a registration.
Caller must open db; run_cli opens it before calling.
"""
function cmd_grant_subsidy(db::DuckDB.DB, identifier::String, amount::Float64;
    reason::String="",
    granted_by::String="cli")
    @verbose_info "Granting subsidy" identifier amount reason
    grant_subsidy!(db, identifier, amount; reason=reason, granted_by=granted_by)
    @info "Subsidy granted" identifier amount=amount
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
