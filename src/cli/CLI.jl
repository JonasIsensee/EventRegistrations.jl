# =============================================================================
# CLI COMMAND FUNCTIONS
# =============================================================================
#
# This file contains CLI command handlers that are included directly into
# the EventRegistrations module. Submodule functions are accessed via qualified
# names (e.g., get_registration_table_data).

using Dates: Date, @dateformat_str
using JSON
using PrettyTables: pretty_table

include("project.jl")
include("emails.jl")
include("config_commands.jl")
include("registrations.jl")
include("sync_workflow.jl")
include("payments.jl")
include("exports.jl")
include("email_queue.jl")

const HELP_TEXT = """
EventRegistrations CLI - Event registration management system

USAGE:
  eventreg <command> [arguments] [options]

COMMANDS:
  init                           Initialize new project
  sync                           Full sync workflow (download, process, match, queue emails)
  process-emails [folder]        Process registration emails
  generate-field-config          Generate field configuration
  create-event-config <id>       Create event config template
  sync-config                    Sync config files to database
  recalculate-costs <event-id>   Recalculate costs after config changes
  list-registrations [event-id]  List registrations with filters
  event-overview <event-id>      Show event details
  status                         Show system status and configuration

VALIDATION & MAINTENANCE:
  verify-database                Check database integrity

PAYMENTS:
  import-bank-csv <file>         Import bank transfers
  match-transfers                Match transfers to registrations
  list-unmatched                 List unmatched transfers
  manual-match <id> <ref>        Manually match a transfer
  grant-subsidy <id> <amount>    Grant subsidy to registration

EMAIL MANAGEMENT:
  list-pending-emails            List emails waiting to be sent
    --verbose, -v                Show full email content
    --event-id=<id>              Filter by event
  mark-email <status> <id>       Mark email as 'sent' or 'discarded'
  mark-email <status> --all      Mark all pending emails (useful after cost config changes)
    --event-id=<id>              Filter by event for bulk operations
  send-emails                    Send all pending emails via SMTP
    --id=<id>                    Send specific email by ID
    --event-id=<id>              Send only emails for specific event
EXPORTS:
  export-payment-status [event-id] [output]  Payment status with color highlighting
    --format=<fmt>               Output: terminal, pdf, latex, csv
    --filter=<filter>            Filter: all, unpaid, problems, paid, no-config
    --summary-only               Show only totals, not individual rows
  export-registrations [event-id] [output]   Export/print registration data
    --format=<fmt>               Output: terminal, pdf, latex, csv
        --filter=<filter>            Filter: all, unpaid, problems, paid
        --details                    Include all registration fields (terminal/csv)
                # Column order via config/events/<event>.toml [export.registration_details]
  list-registrations [event-id]  Quick registration listing with filters
    --filter=<filter>            Filter: all, unpaid, problems, paid
    --name=<pattern>             Filter by name (regex pattern)
    --email=<pattern>            Filter by email (regex pattern)
    --since=<date>               Only registrations since date (yyyy-mm-dd)

COMMON OPTIONS:
  --db-path=<path>              Database file (default: events.duckdb)
  --config-dir=<path>           Config directory (default: config)
  --verbose                     Show detailed output
  --strict                      Fail on warnings (for validate-config, recalculate-costs)
  --dry-run                     Preview changes without applying (for recalculate-costs)
  --check-sync                  Warn if config files need syncing
  --nonstop                     Disable interactive prompts (auto-continue)

EXAMPLES:
  eventreg init
  eventreg sync                                            # full workflow
  eventreg process-emails emails/
  eventreg status
  eventreg check-sync                                      # check config sync status
  eventreg validate-config PWE_2026_01 --verbose
  eventreg recalculate-costs PWE_2026_01 --dry-run --check-sync
  eventreg backup
  eventreg import-bank-csv bank_transfers/january.csv
  eventreg match-transfers --event-id=PWE_2026_01
  eventreg list-registrations --filter=unpaid              # list unpaid registrations
  eventreg list-registrations --name="Müller"              # filter by name
  eventreg list-registrations --since=2025-01-01           # registrations since date
  eventreg list-pending-emails                             # list pending emails
  eventreg list-pending-emails -v                          # with full content
  eventreg send-emails                                     # send all pending
  eventreg mark-email sent 42                              # mark single email as sent (without sending)
  eventreg mark-email discarded 42                         # discard single email
  eventreg mark-email sent --all                           # mark all as sent without sending
  eventreg mark-email discarded --all                      # discard all pending
  eventreg mark-email discarded --all --event-id=PWE_2026_01  # discard for specific event
  eventreg mark-all-as-sent PWE_2026_01 --all              # mark all as sent (after DB reset)
  eventreg export-payment-status                           # colored terminal output
  eventreg export-payment-status --filter=unpaid           # show only unpaid
  eventreg export-payment-status --summary-only            # show only totals
  eventreg export-payment-status PWE_2026_01 report.pdf    # export to PDF
  eventreg export-registrations report.pdf                 # export registrations to PDF
  eventreg export-registration-details PWE_2026_01 details.csv
  eventreg export-payment-status --format=latex            # generate LaTeX

Run 'eventreg <command> --help' for more information on a command.
"""

"""
Main CLI dispatcher function.
"""
function run_cli(args::Vector{String})
    if isempty(args) || args[1] in ["--help", "-h", "help"]
        println(HELP_TEXT)
        return 0
    end

    command = args[1]
    cmd_args = args[2:end]

    # Parse arguments
    positional = String[]
    options = Dict{Symbol, Any}()

    for arg in cmd_args
        if startswith(arg, "--")
            if contains(arg, "=")
                key, val = split(arg[3:end], "=", limit=2)
                options[Symbol(replace(key, "-" => "_"))] = string(val)
            else
                # Boolean flag
                options[Symbol(replace(arg[3:end], "-" => "_"))] = true
            end
        elseif startswith(arg, "-") && length(arg) == 2
            # Short flags (e.g., -v for verbose)
            flag = arg[2]
            if flag == 'v'
                options[:verbose] = true
            elseif flag == 'n'
                options[:dry_run] = true
            else
                push!(positional, arg)
            end
        else
            push!(positional, arg)
        end
    end

    # Dispatch to command
    try
        if command == "init"
            return cmd_init(; options...)
        elseif command == "process-emails"
            email_folder = isempty(positional) ? "emails" : positional[1]
            return cmd_process_emails(email_folder; options...)
        elseif command == "download-emails"
            return cmd_download_emails(; options...)
        elseif command == "generate-field-config"
            return cmd_generate_field_config(; options...)
        elseif command == "create-event-config"
            if isempty(positional)
                println("❌ Error: event-id required")
                return 1
            end
            return cmd_create_event_config(positional[1]; options...)
        elseif command == "sync-config"
            return cmd_sync_config(; options...)
        elseif command == "recalculate-costs"
            if isempty(positional)
                println("❌ Error: event-id required")
                return 1
            end
            return cmd_recalculate_costs(positional[1]; options...)
        elseif command == "list-registrations"
            event_id = length(positional) >= 1 ? positional[1] : nothing
            return cmd_list_registrations(event_id; options...)
        elseif command == "event-overview"
            if isempty(positional)
                println("❌ Error: event-id required")
                return 1
            end
            return cmd_event_overview(positional[1]; options...)
        elseif command == "status"
            return cmd_status(; options...)
        elseif command == "import-bank-csv"
            if isempty(positional)
                println("❌ Error: csv-file required")
                return 1
            end
            return cmd_import_bank_csv(positional[1]; options...)
        elseif command == "match-transfers"
            return cmd_match_transfers(; options...)
        elseif command == "list-unmatched"
            return cmd_list_unmatched(; options...)
        elseif command == "manual-match"
            if length(positional) < 2
                println("❌ Error: transfer-id and reference required")
                return 1
            end
            transfer_id = parse(Int, positional[1])
            return cmd_manual_match(transfer_id, positional[2]; options...)
        elseif command == "grant-subsidy"
            if length(positional) < 2
                println("❌ Error: identifier and amount required")
                return 1
            end
            amount = parse(Float64, positional[2])
            return cmd_grant_subsidy(positional[1], amount; options...)
        elseif command == "export-payment-status"
            event_id = length(positional) >= 1 ? positional[1] : nothing
            output = length(positional) >= 2 ? positional[2] : nothing
            return cmd_export_payment_status(event_id, output; options...)
        elseif command == "export-registrations"
            event_id = length(positional) >= 1 ? positional[1] : nothing
            output = length(positional) >= 2 ? positional[2] : nothing
            return cmd_export_registrations(event_id, output; options...)
        # Email queue management commands
        elseif command == "list-pending-emails"
            return cmd_list_pending_emails(; options...)
        elseif command == "mark-email"
            if isempty(positional)
                println("❌ Error: status required")
                println("Usage:")
                println("  eventreg mark-email <sent|discarded> <id>")
                println("  eventreg mark-email <sent|discarded> --all")
                return 1
            end
            status = positional[1]
            # Check if ID was provided as positional or via --id option
            id_val = length(positional) >= 2 ? parse(Int, positional[2]) : get(options, :id, nothing)
            if id_val !== nothing
                options[:id] = id_val
            end
            return cmd_mark_email(status; options...)
        elseif command == "send-emails"
            # Check if --id was provided
            id_val = get(options, :id, nothing)
            if id_val !== nothing
                options[:id] = parse(Int, id_val)
            end
            return cmd_send_emails(; options...)
        # Validation and maintenance commands
        elseif command == "sync"
            return cmd_sync(; options...)
        else
            println("❌ Error: Unknown command: $command")
            println("\nRun 'eventreg --help' for usage information.")
            return 1
        end
    catch e
        println("❌ Error: $e")
        if isa(e, InterruptException)
            return 130
        end
        # Print stack trace for debugging
        for (exc, bt) in Base.catch_stack()
            showerror(stdout, exc, bt)
            println()
        end
        return 1
    end
end
