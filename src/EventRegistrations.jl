"""
EventRegistrations.jl - Complete event registration management system

Features:
1. Parse form submissions from .eml email files
2. Handle resubmissions gracefully (preserve reference numbers)
3. Calculate costs based on configurable rules (TOML config files)
4. Generate unique reference numbers for bank transfers
5. Send confirmation emails with payment details (external templates)
6. Import bank transfer CSVs and match payments
7. Export registration and payment status tables

Configuration Files:
- events/*.toml     - Per-event cost rules
- templates/*.mustache   - Email templates
"""
module EventRegistrations

using DBInterface: DBInterface
using Dates: Dates, @dateformat_str
using DuckDB: DuckDB
using JSON: JSON
using Logging: Logging, ConsoleLogger, with_logger
using PrecompileTools: PrecompileTools, @compile_workload, @setup_workload
using TOML: TOML

# =============================================================================
# DATABASE HELPER FUNCTIONS
# =============================================================================

"""
    require_database(f, db_path::AbstractString)

Execute function `f` with a database connection, but ONLY if the database
already exists. If the database doesn't exist, throws an error with a helpful
message suggesting to run 'eventreg init' or 'eventreg sync'.

Use this for commands that should not create a new database.
"""
function require_database(f::Function, db_path::AbstractString)
    if !isfile(db_path)
        error("Database not found: $db_path\n\n" *
              "Run one of the following to create it:\n" *
              "  eventreg init        # Initialize new project\n" *
              "  eventreg sync        # Full sync (also creates DB if missing)")
    end
    db = init_database(db_path)
    try
        return f(db)
    finally
        DBInterface.close!(db)
    end
end

export require_database

"""
    with_transaction(f, db::DuckDB.DB)

Execute function `f` within a database transaction.
Commits on success, rolls back on error.

This ensures atomic operations - either all changes succeed or none do.

# Example
```julia
with_transaction(db) do
    # Multiple database operations
    # If any fail, all are rolled back
end
```
"""
function with_transaction(f::Function, db::DuckDB.DB)
    DBInterface.execute(db, "BEGIN TRANSACTION")
    try
        result = f()
        DBInterface.execute(db, "COMMIT")
        return result
    catch e
        try
            DBInterface.execute(db, "ROLLBACK")
        catch rollback_error
            @error "Failed to rollback transaction" exception=rollback_error
        end
        rethrow(e)
    end
end
export with_transaction


# Include all submodules
include("Schema.jl")
include("Config.jl")
include("AppConfig.jl")
include("EmailParser.jl")
include("EmailDownload.jl")
include("ReferenceNumbers.jl")
include("CostCalculator.jl")
include("Validation.jl")
include("Registrations.jl")
include("ConfirmationEmails.jl")
include("BankTransfers.jl")
include("PrettyOutput.jl")

# Re-export from Schema
using .Schema: init_database
export init_database

# Re-export from Validation
using .Validation: ValidationResult, validate_cost_config
using .Validation: validate_field_aliases, format_validation_result
export ValidationResult, validate_cost_config
export validate_field_aliases, format_validation_result

# Re-export CostCalculationResult
using .CostCalculator: CostCalculationResult, calculate_cost_with_details
export CostCalculationResult, calculate_cost_with_details

# Re-export from PrettyOutput - payment types and functions
using .PrettyOutput: PaymentStatus, PaymentTableData, PaymentFilter, PaymentRow
using .PrettyOutput: get_payment_table_data, print_payment_table
using .PrettyOutput: export_payment_pdf, export_payment_csv, filter_payments
using .PrettyOutput: generate_latex_document, print_summary
export PaymentStatus, PaymentTableData, PaymentFilter, PaymentRow
export get_payment_table_data, print_payment_table
export export_payment_pdf, export_payment_csv, filter_payments
export generate_latex_document, print_summary

# Re-export from PrettyOutput - registration types and functions
using .PrettyOutput: RegistrationRow, RegistrationTableData, RegistrationFilter
using .PrettyOutput: get_registration_table_data, print_registration_table
using .PrettyOutput: export_registration_pdf, export_registration_csv
using .PrettyOutput: filter_registrations, generate_registration_latex_document
export RegistrationRow, RegistrationTableData, RegistrationFilter
export get_registration_table_data, print_registration_table
export export_registration_pdf, export_registration_csv
export filter_registrations, generate_registration_latex_document

# Re-export from Config for sync tracking
using .Config: ConfigSyncStatus, check_config_sync, get_unsynced_configs
using .Config: get_all_config_sync_status
export ConfigSyncStatus, check_config_sync, get_unsynced_configs
export get_all_config_sync_status

# Re-export from Config
using .Config: DEFAULT_CONFIG_DIR, EventConfig, load_event_config, load_all_event_configs
using .Config: materialize_cost_rules, generate_field_config, generate_event_config_template, sync_event_configs_to_db!
using .Config: ensure_config_dirs, get_registration_detail_columns
export DEFAULT_CONFIG_DIR, EventConfig, load_event_config, load_all_event_configs
export materialize_cost_rules, generate_field_config, sync_event_configs_to_db!
export ensure_config_dirs, get_registration_detail_columns

# Re-export AppConfig types/functions (now included directly)
export AppConfig, EmailConfig, load_app_config

# Re-export from CostCalculator
using .CostCalculator: calculate_cost
export calculate_cost

# Re-export from Registrations
using .Registrations: process_email_folder!, get_registrations
using .Registrations: RegistrationDetailTable, get_registration_detail_table
using .Registrations: grant_subsidy!, get_subsidies, revoke_subsidy!, grant_subsidies_batch!
using .Registrations: get_registration_by_reference, recalculate_costs!
export process_email_folder!, get_registrations
export RegistrationDetailTable, get_registration_detail_table
export grant_subsidy!, get_subsidies, revoke_subsidy!, grant_subsidies_batch!
export get_registration_by_reference, recalculate_costs!

# Re-export from BankTransfers
using .BankTransfers: import_bank_csv!, match_transfers!, get_unmatched_transfers
using .BankTransfers: manual_match!, get_payment_status, get_payment_summary
using .BankTransfers: get_payment_history, get_payment_discrepancies
export import_bank_csv!, match_transfers!, get_unmatched_transfers
export manual_match!, get_payment_status, get_payment_summary
export get_payment_history, get_payment_discrepancies

# Re-export from ConfirmationEmails
using .ConfirmationEmails: preview_email
using .ConfirmationEmails: queue_email!, queue_pending_emails!, get_pending_emails
using .ConfirmationEmails: queue_payment_confirmation!
using .ConfirmationEmails: count_pending_emails, mark_email!, send_queued_email!

export preview_email
export queue_email!, queue_pending_emails!, get_pending_emails
export queue_payment_confirmation!
export count_pending_emails, mark_email!, send_queued_email!
using .EmailDownload: download_emails!

# ============================================================================
# HIGH-LEVEL CONVENIENCE FUNCTIONS
# ============================================================================

"""
Get all events in the database with summary statistics.
"""
function list_events(db::DuckDB.DB)
    result = DBInterface.execute(db, """
        SELECT
            e.event_id,
            e.event_name,
            COUNT(r.id) as registration_count,
            SUM(r.computed_cost) as total_expected,
            COUNT(pm.id) as paid_count
        FROM events e
        LEFT JOIN registrations r ON r.event_id = e.event_id
        LEFT JOIN payment_matches pm ON pm.registration_id = r.id
        GROUP BY e.event_id, e.event_name
        ORDER BY e.event_id
    """)
    return collect(result)
end
export list_events

"""
Get the most recent event ID based on registration dates.
Returns nothing if no events with registrations exist.
"""
function get_most_recent_event(db::DuckDB.DB)
    result = DBInterface.execute(db, """
        SELECT event_id
        FROM registrations
        ORDER BY registration_date DESC
        LIMIT 1
    """)
    rows = collect(result)
    return isempty(rows) ? nothing : rows[1][1]
end
export get_most_recent_event

"""
Get a complete overview for an event.
"""
function event_overview(db::DuckDB.DB, event_id::AbstractString)
    # Basic info
    event_result = DBInterface.execute(db,
        "SELECT event_id, event_name FROM events WHERE event_id = ?",
        [event_id])
    event_rows = collect(event_result)

    if isempty(event_rows)
        @warn "Event not found" event_id=event_id
        return nothing
    end

    # Registration count
    reg_count = first(collect(DBInterface.execute(db,
        "SELECT COUNT(*) FROM registrations WHERE event_id = ?",
        [event_id])))[1]

    # Payment summary
    summary = get_payment_summary(db, event_id)

    return (
        event_id = event_rows[1][1],
        event_name = event_rows[1][2],
        registrations = reg_count,
        fully_paid = summary.fully_paid_count,
        partially_paid = summary.partial_paid_count,
        unpaid = summary.unpaid_count,
        total_expected = summary.total_expected,
        total_received = summary.total_received,
        total_subsidies = summary.total_subsidies,
        total_credits = summary.total_credits,
        outstanding = summary.total_outstanding
    )
end
export event_overview

"""
Interactive helper to resolve unmatched transfers.
"""
function resolve_unmatched_interactive(db::DuckDB.DB)
    unmatched = get_unmatched_transfers(db)

    if isempty(unmatched)
        println("No unmatched transfers!")
        return
    end

    println("\n=== UNMATCHED TRANSFERS ===")
    println("Found $(length(unmatched)) unmatched transfers.\n")

    for (i, transfer) in enumerate(unmatched)
        id, date, amount, sender, reference = transfer

        println("[$i] Transfer ID: $id")
        println("    Date: $date")
        println("    Amount: $amount €")
        println("    Sender: $sender")
        println("    Reference: $reference")
        println()

        # Try to find potential matches
        println("    Potential matches:")

        # By amount
        potential = DBInterface.execute(db, """
            SELECT id, reference_number, first_name, last_name, email, computed_cost
            FROM registrations
            WHERE ABS(computed_cost - ?) < 1.0
            LIMIT 5
        """, [amount])

        for (j, p) in enumerate(potential)
            pid, pref, pfn, pln, pemail, pcost = p
            println("      [$j] $pref: $pfn $pln ($pemail) - $pcost €")
        end

        println()
    end

    println("\nTo match: manual_match!(db, transfer_id, \"REFERENCE-NUMBER\")")
end
export resolve_unmatched_interactive

"""
Grant subsidies from a CSV file.
Format: CSV with columns: identifier (email or reference), amount, reason
"""
function grant_subsidies_from_csv!(db::DuckDB.DB, csv_path::AbstractString;
                                    granted_by::String="csv_import")
    lines = readlines(csv_path)

    # Skip header
    start_idx = 1
    if occursin("identifier", lowercase(lines[1])) || occursin("email", lowercase(lines[1])) ||
       occursin("referenz", lowercase(lines[1]))
        start_idx = 2
    end

    count = 0
    for line in lines[start_idx:end]
        parts = split(line, [',', ';'])
        if length(parts) >= 2
            identifier = strip(parts[1], '"')
            amount = parse(Float64, replace(strip(parts[2], '"'), "," => "."))
            reason = length(parts) >= 3 ? strip(parts[3], '"') : ""

            try
                grant_subsidy!(db, identifier, amount; reason=reason, granted_by=granted_by)
                count += 1
            catch e
                @warn "Failed to grant subsidy" identifier=identifier exception=e
            end
        end
    end

    @info "Granted subsidies from CSV" count=count file=csv_path
    return count
end
export grant_subsidies_from_csv!

# =============================================================================
# PROJECT SETUP
# =============================================================================

"""
Set up the project directory structure with config files.
Creates:
- config/events/ directory (for event-specific configs)
- config/templates/ directory with default templates
"""
function setup_project!(config_dir::AbstractString="config")
    ensure_config_dirs(config_dir)

    # Create default templates in the configured directory
    templates_dir = joinpath(config_dir, "templates")
    ConfirmationEmails.ensure_default_templates(templates_dir)
    return config_dir
end
export setup_project!

"""
Initialize everything: database, config, and sync.
Convenience function for quick setup.
"""
function init_project(db_path::AbstractString, config_dir::AbstractString="config")
    # Set up directories
    setup_project!(config_dir)

    # Initialize database
    db = init_database(db_path)

    return db
end
export init_project

# =============================================================================
# CLI INTERFACE
# =============================================================================

# Include CLI functions directly into EventRegistrations module
# This must be after all other modules are loaded so their exports are available
include("cli/CLI.jl")
export run_cli

"""
    main(args::Vector{String}=ARGS)

Main CLI entry point. This function dispatches to the appropriate CLI command.

Can be called in two ways:
1. From bin/eventreg script (development): `./bin/eventreg <command>`
2. Directly: `julia --project -e 'using EventRegistrations; EventRegistrations.main(ARGS)' -- <command>`

For a permanent installation, you can:
- Add bin/eventreg to your PATH
- Create a shell alias: `alias eventreg='/path/to/EventRegistrations.jl/bin/eventreg'`
- Use Julia's App system with `@main` macro (requires Julia 1.11+)

The `@main` macro support has been removed for now due to compatibility issues.
Use the bin/eventreg wrapper script which provides the same functionality.
"""
main(ARGS) = run_cli(ARGS)
export main

using PrecompileTools
@setup_workload begin
    cd(joinpath(@__DIR__,"..", "testingfolder"))
    @compile_workload begin
        # inside here, put a "toy example" of everything you want to be fast
        cmd_sync(;
            export_details="--format=csv",
            export_payments="--format=csv")
    end
end


end # module
