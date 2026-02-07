# CLI COMMAND FUNCTIONS
# =============================================================================
#
# This file contains CLI command handlers that are included directly into
# the EventRegistrations module. Submodule functions are accessed via qualified
# names (e.g., get_registration_table_data).

using Logging
using Dates: Date, @dateformat_str
using JSON
using PrettyTables: pretty_table
using REPL
using REPL.LineEdit

with_cli_logger(f::Function; io::IO=stdout) = with_logger(ConsoleLogger(io)) do
    f()
end

"""
Return a short one-line message for an exception, suitable for CLI/REPL output.
Avoids stacktraces; use for user-facing error reporting.
"""
function cli_error_message(e)
    if e isa InterruptException
        return ""  # caller handles separately (exit 130)
    end
    msg = something(
        try
            sprint(showerror, e; context=:compact => true)
        catch
            string(e)
        end,
        string(e),
    )
    # First line only, strip trailing newline; cap length for readability
    line = split(msg, '\n'; limit=2)[1]
    line = strip(line)
    return isempty(line) ? "command failed" : line
end

"""Print a short error to stderr (no stacktrace). Prefix with 'eventreg:' for CLI consistency."""
function cli_print_error(e; prefix::String="eventreg: ")
    msg = cli_error_message(e)
    isempty(msg) && return
    println(stderr, prefix, msg)
end

"""Print a one-line validation/usage error to stderr (no stacktrace)."""
function cli_err(msg::AbstractString)
    println(stderr, "eventreg: ", msg)
end

parse_subcommand_options(::Bool) = Dict{Symbol, Any}()
"""
Parse sub-command option strings like "--format=csv --filter=unpaid" into a Dict.
Returns empty dict for empty/whitespace-only strings.
"""
function parse_subcommand_options(args_str::String)
    options = Dict{Symbol, Any}()
    isempty(strip(args_str)) && return options

    # Split on whitespace, preserving quoted strings
    parts = String[]
    buf = IOBuffer()
    in_quotes = false

    for char in args_str
        if char == '"'
            in_quotes = !in_quotes
        elseif char == ' ' && !in_quotes
            s = String(take!(buf))
            if !isempty(s)
                push!(parts, s)
            end
        else
            write(buf, char)
        end
    end
    s = String(take!(buf))
    !isempty(s) && push!(parts, s)

    # Parse each part as an option
    for part in parts
        if startswith(part, "--")
            if contains(part, "=")
                key, val = split(part[3:end], "=", limit=2)
                options[Symbol(replace(key, "-" => "_"))] = string(val)
            else
                # Boolean flag
                options[Symbol(replace(part[3:end], "-" => "_"))] = true
            end
        elseif startswith(part, "-") && length(part) == 2
            # Short flag
            flag = part[2]
            if flag == 'v'
                options[:verbose] = true
            else
                @warn "Unknown short flag in subcommand options" flag=part
            end
        else
            @warn "Ignoring positional argument in subcommand options" arg=part
        end
    end

    return options
end

include("Verbosity.jl")
include("project.jl")
include("emails.jl")
include("registrations.jl")
include("sync_workflow.jl")
include("payments.jl")
include("exports.jl")
include("email_queue.jl")
include("config.jl")
include("playground.jl")
include("repl.jl")

const HELP_TEXT = """
EventRegistrations CLI - Event registration management system

USAGE:
  eventreg                    # REPL mode (single DB connection; type exit or Ctrl-D to quit)
  eventreg <command> [arguments] [options]

COMMANDS:
  init                           Initialize new project
  sync                           Full sync workflow (download, process, match, queue emails)
    --send-emails[="opts"]       Send queued emails after sync (optional: pass sub-options)
    --export-details[="opts"]    Export registration details after sync (optional: pass sub-options)
    --export-payments[="opts"]   Export payment status after sync (optional: pass sub-options)
    --export-combined[="opts"]   Export combined workbook after sync (optional: pass sub-options)
  process-emails [folder]        Process registration emails
  generate-field-config          Generate field configuration
  create-event-config <id>       Create event config template
  sync-config                    Sync config files to database
  recalculate-costs <event-id>   Recalculate costs after config changes
  list-registrations [event-id]  List registrations with filters
  delete-registration <id|ref>  Cancel a registration (soft delete)
    --event-id=<id>              Require registration to belong to this event
    --yes                        Skip confirmation prompt
  edit-registrations [event-id]  Edit registrations in external editor (TableEdit)
    --event-id=<id>              Event to edit (required if not default)
    --name=<pattern>             Filter by name (regex)
    --since=<date>               Only registrations since date (yyyy-mm-dd)
  delete-registration <ref>      Mark a registration as deleted (soft delete)
  restore-registration <ref>     Restore a deleted registration
  list-deleted-registrations [event-id]  List all deleted registrations for an event
  event-overview <event-id>      Show event details
  status                         Show system status and configuration

PAYMENTS:
  import-bank-csv <file>         Import bank transfers
  match-transfers                Match transfers to registrations
  list-unmatched                 List unmatched transfers
  review-near-misses             Review transfers with likely candidates (interactive)
    --event-id=<id>              Filter by event
    --nonstop                    List only, don't prompt for matching
  manual-match <id> <ref>        Manually match a transfer
  grant-subsidy <id> <amount>    Grant subsidy to registration
  delete-registration <id|ref>   Cancel registration (soft delete; use --yes to skip prompt)

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

CONFIGURATION:
  set-email-redirect <email>     Redirect ALL emails to test address (for testing)
  get-email-redirect             Show current email redirect setting
  clear-email-redirect           Remove email redirect (send to actual recipients)
EXPORTS:
  export-payment-status [event-id] [output]  Payment status with color highlighting
    --format=<fmt>               Output: terminal, pdf, latex, csv, xlsx
    --filter=<filter>            Filter: all, unpaid, problems, paid, no-config
    --summary-only               Show only totals, not individual rows
    --pager                      Display output in scrollable pager (terminal only)
    --upload                     Upload exported file to WebDAV (requires credentials.toml)
  export-registrations [event-id] [output]   Export/print registration data
    --format=<fmt>               Output: terminal, pdf, latex, csv, xlsx
    --filter=<filter>            Filter: all, unpaid, problems, paid
    --details                    Include all registration fields (terminal/csv/xlsx)
    --pager                      Display output in scrollable pager (terminal only)
    --upload                     Upload exported file to WebDAV (requires credentials.toml)
    # Column order via config/events/<event>.toml [export.registration_details]
  export-combined [event-id] [output]        Export combined multi-sheet XLSX workbook
    --output=<path>              Output file path (overrides config)
    --upload                     Upload exported file to WebDAV (requires credentials.toml)
    # Configuration via config/events/<event>.toml [export.combined]
  list-registrations [event-id]  Quick registration listing with filters
    --filter=<filter>            Filter: all, unpaid, problems, paid
    --name=<pattern>             Filter by name (regex pattern)
    --email=<pattern>            Filter by email (regex pattern)
    --since=<date>               Only registrations since date (yyyy-mm-dd)
    --pager                      Display output in scrollable pager
  edit-registrations [event-id]   Edit registrations in external editor
    --event-id=<id>              Event to edit
    --name=<pattern>             Filter by name (regex)
    --since=<date>               Only registrations since date (yyyy-mm-dd)

PLAYGROUND (Testing & Development):
  playground init [name]           Initialize playground environment
    --force                        Initialize even if directory is not empty
  playground receive-submissions [count]  Generate sample submission emails
    --event-id=<id>              Use specific event ID for samples

COMMON OPTIONS:
  --db-path=<path>              Database file (default: events.duckdb)
  --config-dir=<path>           Config directory (default: config)
  --verbose                     Show detailed output
  --strict                      Fail on warnings (for validate-config, recalculate-costs)
  --dry-run                     Preview changes without applying (for recalculate-costs)
  --nonstop                     Disable interactive prompts (auto-continue)

EXAMPLES:
  eventreg init
  eventreg sync                                            # full workflow
  eventreg sync --send-emails --export-combined            # sync + send + export workbook
  eventreg sync --export-details --export-payments --export-combined  # all exports
  eventreg sync --send-emails="--event-id=PWE_2026_01"    # send only for specific event
  eventreg sync --export-combined="--output=report.xlsx"  # custom output file
  eventreg sync --export-payments="--format=csv --filter=unpaid"  # custom export options
  eventreg sync --export-combined="--upload"              # export and upload to WebDAV
  eventreg process-emails emails/
  eventreg status
  eventreg validate-config PWE_2026_01 --verbose
  eventreg recalculate-costs PWE_2026_01 --dry-run --check-sync
  eventreg import-bank-csv bank_transfers/january.csv
  eventreg match-transfers --event-id=PWE_2026_01
  eventreg list-registrations --filter=unpaid              # list unpaid registrations
  eventreg list-registrations --name="Mustermann"         # filter by name
  eventreg list-registrations --since=2025-01-01           # registrations since date
  eventreg list-registrations --pager                      # scrollable pager with full emails
  eventreg list-pending-emails                             # list pending emails
  eventreg list-pending-emails -v                          # with full content
  eventreg send-emails                                     # send all pending
  eventreg mark-email sent 42                              # mark single email as sent (without sending)
  eventreg mark-email discarded 42                         # discard single email
  eventreg mark-email sent --all                           # mark all as sent without sending
  eventreg mark-email discarded --all                      # discard all pending
  eventreg mark-email discarded --all --event-id=PWE_2026_01  # discard for specific event
  eventreg export-payment-status                           # colored terminal output
  eventreg export-payment-status --filter=unpaid           # show only unpaid
  eventreg export-payment-status --pager                   # scrollable pager view
  eventreg export-payment-status --summary-only            # show only totals
  eventreg export-payment-status PWE_2026_01 report.pdf    # export to PDF
  eventreg export-payment-status --format=latex            # generate LaTeX
  eventreg export-payment-status --format=csv --upload     # export CSV and upload to WebDAV
  eventreg export-registrations report.pdf                 # export registrations to PDF
  eventreg export-registrations --pager                    # scrollable pager view
  eventreg export-registrations --format=xlsx --upload     # export XLSX and upload
  eventreg export-combined                                 # export most recent event
  eventreg export-combined PWE_2026_01                     # export specific event
  eventreg export-combined PWE_2026_01 custom_report.xlsx  # custom output file
  eventreg export-combined --upload                        # export and upload to WebDAV
  eventreg playground init                                 # create playground in current dir
  eventreg playground init mytest                          # create playground in ./mytest
  eventreg playground receive-submissions                  # generate 3 sample emails
  eventreg playground receive-submissions 10               # generate 10 sample emails

REPL MODE:
  Run eventreg with no arguments to enter REPL mode. The database is connected
  once at startup and reused for every command. Type the same command line as you
  would after eventreg (e.g. list-registrations --filter=unpaid, grant-subsidy PWE_2026_01_042 25).
  Type exit or quit, or press Ctrl-D to quit.

Run 'eventreg <command> --help' for more information on a command.
"""

"""
Parse argv into command name, positional args, and options dict.
Shared by run_cli and REPL so we open the DB in one place.
"""
function parse_cli_args(args::Vector{String})
    if isempty(args)
        return "", String[], Dict{Symbol, Any}()
    end
    command = args[1]
    cmd_args = args[2:end]
    positional = String[]
    options = Dict{Symbol, Any}()
    for arg in cmd_args
        if startswith(arg, "--")
            if contains(arg, "=")
                key, val = split(arg[3:end], "=", limit=2)
                options[Symbol(replace(key, "-" => "_"))] = string(val)
            else
                options[Symbol(replace(arg[3:end], "-" => "_"))] = true
            end
        elseif startswith(arg, "-") && length(arg) == 2
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
    return command, positional, options
end

"""
Dispatch to the appropriate cmd_*(db, ...). Caller owns db (opens/closes).
Commands that need no DB (init, download-emails) are handled by run_cli before opening db.
"""
function dispatch_to_command(db::DuckDB.DB, command::String, positional::Vector{String}, options::Dict{Symbol,Any};
    db_path::String="events.duckdb",
    events_dir::String="events",
    credentials_path::String="credentials.toml",
    from_repl::Bool=false)
    # Set global verbosity flag based on command-line options
    set_verbose!(get(options, :verbose, false))
    
    try
        if command == "init"
            return cmd_init(; db_path=db_path)
        elseif command == "process-emails"
            email_folder = isempty(positional) ? "emails" : positional[1]
            return cmd_process_emails(db, email_folder; nonstop=get(options, :nonstop, false))
        elseif command == "download-emails"
            return cmd_download_emails(; options...)
        elseif command == "generate-field-config"
            return cmd_generate_field_config(db; event_id=get(options, :event_id, nothing), output=get(options, :output, nothing), events_dir=events_dir)
        elseif command == "create-event-config"
            isempty(positional) && (cli_err("event-id required"); return 1)
            return cmd_create_event_config(db, positional[1]; events_dir=events_dir)
        elseif command == "sync-config"
            return cmd_sync_config(db; events_dir=events_dir)
        elseif command == "recalculate-costs"
            isempty(positional) && (cli_err("event-id required"); return 1)
            return cmd_recalculate_costs(db, positional[1]; events_dir=events_dir, strict=get(options, :strict, false), dry_run=get(options, :dry_run, false))
        elseif command == "list-registrations"
            event_id = length(positional) >= 1 ? positional[1] : nothing
            return cmd_list_registrations(db, event_id; filter=get(options, :filter, "all"), name=get(options, :name, nothing), email=get(options, :email, nothing), since=get(options, :since, nothing), pager=get(options, :pager, false))
        elseif command == "edit-registrations"
            event_id = get(options, :event_id, length(positional) >= 1 ? positional[1] : nothing)
            return cmd_edit_registrations(db; event_id=event_id, name=get(options, :name, nothing), since=get(options, :since, nothing), spawn_editor=true)
        elseif command == "event-overview"
            isempty(positional) && (cli_err("event-id required"); return 1)
            return cmd_event_overview(db, positional[1])
        elseif command == "status"
            return cmd_status(db; db_path=db_path)
        elseif command == "import-bank-csv"
            isempty(positional) && (cli_err("csv-file required"); return 1)
            return cmd_import_bank_csv(db, positional[1]; delimiter=get(options, :delimiter, ";"), decimal_comma=get(options, :decimal_comma, true))
        elseif command == "match-transfers"
            return cmd_match_transfers(db; event_id=get(options, :event_id, nothing))
        elseif command == "list-unmatched"
            return cmd_list_unmatched(db)
        elseif command == "review-near-misses"
            return cmd_review_near_misses(db; event_id=get(options, :event_id, nothing), nonstop=get(options, :nonstop, false))
        elseif command == "manual-match"
            length(positional) < 2 && (cli_err("transfer-id and reference required"); return 1)
            return cmd_manual_match(db, parse(Int, positional[1]), positional[2])
        elseif command == "grant-subsidy"
            length(positional) < 2 && (cli_err("identifier and amount required"); return 1)
            return cmd_grant_subsidy(db, positional[1], parse(Float64, positional[2]); reason=get(options, :reason, ""), granted_by=get(options, :granted_by, "cli"))
        elseif command == "delete-registration"
            isempty(positional) && (cli_err("identifier (id or reference) required"); return 1)
            return cmd_delete_registration(db, positional[1]; event_id=get(options, :event_id, nothing), yes=get(options, :yes, false))
        elseif command == "soft-delete-registration"
            isempty(positional) && (cli_err("reference number required"); return 1)
            return cmd_soft_delete_registration(db, positional[1])
        elseif command == "restore-registration"
            isempty(positional) && (cli_err("reference number required"); return 1)
            return cmd_restore_registration(db, positional[1])
        elseif command == "list-deleted-registrations"
            event_id = length(positional) >= 1 ? positional[1] : nothing
            return cmd_list_deleted_registrations(db, event_id)
        elseif command == "export-payment-status"
            event_id = length(positional) >= 1 ? positional[1] : nothing
            output = length(positional) >= 2 ? positional[2] : get(options, :output, nothing)
            return cmd_export_payment_status(db, event_id, output; format=get(options, :format, "terminal"), filter=get(options, :filter, "all"), summary_only=get(options, :summary_only, false), upload=get(options, :upload, false), credentials_path=credentials_path, db_path=db_path, pager=get(options, :pager, false))
        elseif command == "export-registrations"
            event_id = length(positional) >= 1 ? positional[1] : nothing
            output = length(positional) >= 2 ? positional[2] : get(options, :output, nothing)
            return cmd_export_registrations(db, event_id, output; format=get(options, :format, "terminal"), filter=get(options, :filter, "all"), details=get(options, :details, false), events_dir=events_dir, upload=get(options, :upload, false), credentials_path=credentials_path, db_path=db_path, pager=get(options, :pager, false))
        elseif command == "export-combined"
            event_id = length(positional) >= 1 ? positional[1] : nothing
            output = length(positional) >= 2 ? positional[2] : get(options, :output, nothing)
            return cmd_export_combined(db, event_id, output; events_dir=events_dir, upload=get(options, :upload, false), credentials_path=credentials_path, db_path=db_path)
        elseif command == "list-pending-emails"
            return cmd_list_pending_emails(db; event_id=get(options, :event_id, nothing), email_type=get(options, :email_type, nothing), verbose=get(options, :verbose, false))
        elseif command == "mark-email"
            isempty(positional) && (cli_err("status required"); return 1)
            status = positional[1]
            id_val = length(positional) >= 2 ? parse(Int, positional[2]) : get(options, :id, nothing)
            id_val isa AbstractString && (id_val = parse(Int, id_val))
            return cmd_mark_email(db, status; id=id_val, all=get(options, :all, false), event_id=get(options, :event_id, nothing), email_type=get(options, :email_type, nothing))
        elseif command == "send-emails"
            id_val = get(options, :id, nothing)
            id_val isa AbstractString && (id_val = parse(Int, id_val))
            return cmd_send_emails(db; event_id=get(options, :event_id, nothing), id=id_val, credentials_path=credentials_path, db_path=db_path)
        elseif command == "sync"
            return cmd_sync(db; db_path=db_path, events_dir=events_dir, emails_dir="emails", bank_dir="bank_transfers", credentials_path=credentials_path, event_id=get(options, :event_id, nothing), send_emails=get(options, :send_emails, false), export_details=get(options, :export_details, false), export_payments=get(options, :export_payments, false), export_combined=get(options, :export_combined, false))
        elseif command == "playground"
            # Playground commands are subcommands
            subcommand = length(positional) >= 1 ? positional[1] : nothing
            if subcommand === nothing
                cli_err("Playground subcommand required. Available: init, receive-submissions")
                return 1
            elseif subcommand == "init"
                playground_name = length(positional) >= 2 ? positional[2] : nothing
                return cmd_playground_init(; playground_name=playground_name, db_path=db_path, events_dir=events_dir, force=get(options, :force, false), from_repl=from_repl)
            elseif subcommand == "receive-submissions"
                count = length(positional) >= 2 ? parse(Int, positional[2]) : 3
                return cmd_playground_receive_submissions(; count=count, event_id=get(options, :event_id, nothing), emails_dir="emails")
            else
                cli_err("Unknown playground subcommand '$subcommand'. Available: init, receive-submissions")
                return 1
            end
        else
            cli_err("Unknown command '$command'. Run 'eventreg --help' or type help for usage.")
            return 1
        end
    catch e
        if e isa InterruptException
            return 130
        end
        cli_print_error(e)
        return 1
    end
end

"""
Main CLI entry: open DB once (except for init/download-emails), then dispatch.
"""
function run_cli(args::Vector{String})
    try
        return with_cli_logger() do
            if isempty(args)
                return run_repl()
            end
            if args[1] in ["--help", "-h", "help"]
                @info HELP_TEXT
                return 0
            end
            command, positional, options = parse_cli_args(args)
            db_path = get(options, :db_path, "events.duckdb")
            events_dir = get(options, :events_dir, "events")
            credentials_path = get(options, :credentials_path, "credentials.toml")
            # Commands that don't need a DB connection
            if command == "init"
                return cmd_init(; db_path=db_path)
            end
            if command == "download-emails"
                return cmd_download_emails(; options...)
            end
            # Configuration commands don't need a DB connection
        if command == "set-email-redirect"
            isempty(positional) && (cli_err("email address required"); return 1)
            return cmd_set_email_redirect(positional[1]; credentials_path)
            end
            if command == "get-email-redirect"
                return cmd_get_email_redirect(; credentials_path)
            end
            if command == "clear-email-redirect"
                return cmd_clear_email_redirect(; credentials_path)
            end
            if command == "playground"
                # playground init doesn't need a DB connection (it creates one)
                # but receive-submissions needs to check if we're in a playground
                subcommand = length(positional) >= 1 ? positional[1] : nothing
                if subcommand == "init"
                    playground_name = length(positional) >= 2 ? positional[2] : nothing
                    return cmd_playground_init(; playground_name=playground_name, db_path=db_path, events_dir=events_dir, force=get(options, :force, false))
                end
                # For other playground subcommands, fall through to regular DB handling
            end
            # Sync can create the DB; all other commands require it to exist
            if command == "sync"
                db = !isfile(db_path) ? init_project(db_path) : init_database(db_path)
            else
                if !isfile(db_path)
                    cli_print_error(ErrorException("Database not found: $db_path. Run 'eventreg init' or 'eventreg sync' first."))
                    return 1
                end
                db = init_database(db_path)
            end
            try
                return dispatch_to_command(db, command, positional, options; db_path=db_path, events_dir=events_dir, credentials_path=credentials_path)
            finally
                DBInterface.close!(db)
            end
        end
    catch e
        if e isa InterruptException
            return 130
        end
        cli_print_error(e)
        return 1
    end
end

# =============================================================================
# REPL: parse a single line into CLI-style args (respects quotes, --key=value)
# =============================================================================

"""
Parse a REPL input line into a vector of arguments equivalent to CLI argv.
Respects double and single quotes; supports --key=value and boolean flags.
"""
function parse_repl_line(line::AbstractString)
    line = strip(line)
    isempty(line) && return String[]
    args = String[]
    buf = IOBuffer()
    in_double = false
    in_single = false
    for c in line
        if in_double
            if c == '"'
                push!(args, String(take!(buf)))
                in_double = false
            else
                write(buf, c)
            end
        elseif in_single
            if c == '\''
                push!(args, String(take!(buf)))
                in_single = false
            else
                write(buf, c)
            end
        elseif c in (' ', '\t')
            s = String(take!(buf))
            !isempty(s) && push!(args, s)
        elseif c == '"'
            in_double = true
        elseif c == '\''
            in_single = true
        else
            write(buf, c)
        end
    end
    s = String(take!(buf))
    !isempty(s) && push!(args, s)
    return args
end

# =============================================================================
# REPL entry: single DB connection, read-eval-print loop
# =============================================================================

const REPL_PROMPT = "eventreg> "
const REPL_BANNER = """
EventRegistrations REPL — database connected. Same commands as CLI (without the eventreg prefix).
  list-registrations, grant-subsidy <ref> <amount>, exit, etc. Type help for full usage.
"""

# Available commands for completion (must match dispatch_to_command)
const REPL_COMMANDS = [
    "init", "sync", "process-emails", "download-emails", "generate-field-config",
    "create-event-config", "sync-config", "recalculate-costs", "list-registrations",
    "edit-registrations", "event-overview", "status", "import-bank-csv", "match-transfers",
    "list-unmatched", "review-near-misses", "manual-match", "grant-subsidy",
    "delete-registration", "restore-registration", "list-deleted-registrations",
    "export-payment-status", "export-registrations", "export-combined",
    "list-pending-emails", "mark-email", "send-emails", "validate-config",
    "set-email-redirect", "get-email-redirect", "clear-email-redirect",
    "playground", "help", "exit", "quit"
]

# Common options for completion
const REPL_OPTIONS = [
    "--db-path=", "--config-dir=", "--verbose", "--strict", "--dry-run", "--nonstop",
    "--format=", "--filter=", "--event-id=", "--name=", "--email=", "--since=",
    "--output=", "--details", "--summary-only", "--upload", "--yes", "--id=",
    "--all", "--email-type=", "--delimiter=", "--decimal-comma", "--reason=",
    "--granted-by=", "--send-emails", "--export-details", "--export-payments",
    "--export-combined"
]

# Filter values for completion
const REPL_FILTER_VALUES = ["all", "unpaid", "problems", "paid", "no-config"]
const REPL_FORMAT_VALUES = ["terminal", "pdf", "latex", "csv", "xlsx"]

"""
Custom completion provider for the eventreg REPL.
Provides completion for commands, options, and option values.
Returns a tuple of (completions, should_complete, prefix).
"""
function eventreg_complete(s::LineEdit.PromptState)
    input = String(take!(copy(LineEdit.buffer(s))))
    words = split(input, r"\s+"; keepempty=true)

    # If input is empty or just whitespace, return all commands
    if isempty(strip(input)) || (length(words) == 1 && isempty(strip(words[1])))
        completions = REPL.Completion[REPL.Completion(cmd, cmd, "") for cmd in REPL_COMMANDS]
        return completions, true, ""
    end

    last_word = isempty(words) ? "" : words[end]
    prev_word = length(words) >= 2 ? words[end-1] : ""

    # Complete commands if we're at the start or after whitespace
    if length(words) == 1 && !startswith(last_word, "--")
        matches = filter(cmd -> startswith(cmd, last_word), REPL_COMMANDS)
        completions = REPL.Completion[REPL.Completion(cmd, cmd, "") for cmd in matches]
        return completions, true, last_word
    end

    # Complete options
    if startswith(last_word, "--")
        # Check if this is an option that needs a value
        if prev_word == "--format" || startswith(prev_word, "--format=")
            # Extract value after = if present
            value_part = contains(last_word, "=") ? last_word[findfirst("=", last_word)[1]+1:end] : ""
            matches = filter(fmt -> startswith(fmt, value_part), REPL_FORMAT_VALUES)
            completions = REPL.Completion[REPL.Completion("--format=$fmt", "--format=$fmt", "") for fmt in matches]
            return completions, true, last_word
        elseif prev_word == "--filter" || startswith(prev_word, "--filter=")
            value_part = contains(last_word, "=") ? last_word[findfirst("=", last_word)[1]+1:end] : ""
            matches = filter(flt -> startswith(flt, value_part), REPL_FILTER_VALUES)
            completions = REPL.Completion[REPL.Completion("--filter=$flt", "--filter=$flt", "") for flt in matches]
            return completions, true, last_word
        else
            # Complete option names
            matches = filter(opt -> startswith(opt, last_word), REPL_OPTIONS)
            completions = REPL.Completion[REPL.Completion(opt, opt, "") for opt in matches]
            return completions, true, last_word
        end
    end

    # If we're after an option that takes a value, suggest values
    if prev_word == "--format" || startswith(prev_word, "--format=")
        matches = filter(fmt -> startswith(fmt, last_word), REPL_FORMAT_VALUES)
        completions = REPL.Completion[REPL.Completion(fmt, fmt, "") for fmt in matches]
        return completions, true, last_word
    elseif prev_word == "--filter" || startswith(prev_word, "--filter=")
        matches = filter(flt -> startswith(flt, last_word), REPL_FILTER_VALUES)
        completions = REPL.Completion[REPL.Completion(flt, flt, "") for flt in matches]
        return completions, true, last_word
    end

    return REPL.Completion[], false, ""
end

"""
Check if input is complete (for multi-line support). Currently always true.
(Previously used by ReplMaker; kept for potential future use.)
"""
function eventreg_is_complete(s::LineEdit.MIState)
    input = String(take!(copy(LineEdit.buffer(s))))
    # For now, we treat each line as complete
    # Could be enhanced to support multi-line commands in the future
    return true
end

"""
Parser function - returns input as-is. (Previously used by ReplMaker; kept for compatibility.)
"""
function eventreg_parser(input::String)
    return input
end

"""Commands that can run without a database connection."""
const NO_DB_COMMANDS = ["init", "sync", "playground", "help", "exit", "quit", "q"]

"""Check if a command requires a database connection."""
function command_requires_db(command::String, positional::Vector{String})
    command in ["help", "exit", "quit", "q"] && return false
    command == "init" && return false
    command == "sync" && return false
    # playground init doesn't need DB, but other playground subcommands do
    if command == "playground"
        subcommand = isempty(positional) ? nothing : positional[1]
        return subcommand != "init"
    end
    return true
end

"""
Print the database missing warning with colored output.
"""
function print_db_missing_warning(db_path::String)
    printstyled("┌ ", color=:yellow, bold=true)
    printstyled("Warning: ", color=:yellow, bold=true)
    println("Database not found: $db_path")
    printstyled("│ ", color=:yellow)
    println("Most commands are unavailable until the database is initialized.")
    printstyled("│ ", color=:yellow)
    println("Available commands: init, sync, playground init")
    printstyled("│ ", color=:yellow)
    println()
    printstyled("│ ", color=:yellow)
    printstyled("Run ", color=:yellow)
    printstyled("init", color=:cyan, bold=true)
    printstyled(" or ", color=:yellow)
    printstyled("sync", color=:cyan, bold=true)
    printstyled(" to create the database.\n", color=:yellow)
    printstyled("└\n", color=:yellow, bold=true)
end

const REPL_BANNER_NO_DB = """
EventRegistrations REPL — database not connected. Run 'init' or 'sync' to create it.
  Type 'help' for usage, or 'exit' / Ctrl-D to quit.
"""

"""
Run the interactive REPL using LineEdit (no ReplMaker).
- TAB completion for commands and options (EventRegCompletionProvider)
- History navigation with arrow keys
- Ctrl-D to exit

Uses the same pattern as run_repl_linedit in repl.jl: one Prompt, one run_interface,
on_done parses and dispatches with a single DB connection. ReplMaker was removed
because it is designed for "parse then eval as Julia"; we only parse CLI lines and
dispatch to our own commands, so plain LineEdit is the right fit.

When the database doesn't exist, the REPL starts in a limited mode where only
init, sync, and playground init commands are available. Once the database is
created, the full REPL experience becomes available.
"""
function run_repl(; db_path::String="events.duckdb")
    db_path = get(ENV, "EVENTREG_DB_PATH", db_path)
    
    # Track database connection state
    db_exists = isfile(db_path)
    db_ref = Ref{Union{DuckDB.DB, Nothing}}(nothing)
    
    # Show appropriate banner based on DB state
    if db_exists
        db_ref[] = init_database(db_path)
        println(REPL_BANNER)
    else
        print_db_missing_warning(db_path)
        println(REPL_BANNER_NO_DB)
    end
    
    try
        term = REPL.Terminals.TTYTerminal(get(ENV, "TERM", "dumb"), stdin, stdout, stderr)
        hascolor = REPL.Terminals.hascolor(term)
        prefix = hascolor ? Base.text_colors[:blue] : ""
        suffix = hascolor ? Base.text_colors[:normal] : ""

        panel = LineEdit.Prompt(
            REPL_PROMPT;
            prompt_prefix = prefix,
            prompt_suffix = suffix,
            complete = EventRegCompletionProvider(),
            on_enter = s -> true,
        )

        # History: same setup as run_repl_linedit so arrow-up/down work
        hp = REPL.REPLHistoryProvider(Dict{Symbol, LineEdit.Prompt}(:eventreg => panel))
        REPL.history_reset_state(hp)
        panel.hist = hp

        search_prompt, skeymap = LineEdit.setup_prefix_keymap(hp, panel)
        panel.keymap_dict = LineEdit.keymap(Dict{Any, Any}[
            skeymap,
            LineEdit.history_keymap,
            LineEdit.default_keymap,
            LineEdit.escape_defaults,
        ])

        exit_requested = Ref(false)

        panel.on_done = (s, buf, ok) -> begin
            if !ok
                LineEdit.transition(s, :abort)
                exit_requested[] = true
                return
            end
            line = strip(String(take!(buf)))
            LineEdit.reset_state(s)

            isempty(line) && return

            if lowercase(line) in ("exit", "quit", "q")
                exit_requested[] = true
                LineEdit.transition(s, :abort)
                return
            end

            if line in ("help", "--help", "-h")
                println(HELP_TEXT)
                flush(stdout)
                return
            end

            args = parse_repl_line(line)
            isempty(args) && return
            command, positional, options = parse_cli_args(args)
            if command in ["--help", "-h", "help"]
                println(HELP_TEXT)
                flush(stdout)
                return
            end

            # Check if this command requires a database connection
            if db_ref[] === nothing && command_requires_db(command, positional)
                printstyled("Error: ", color=:red, bold=true)
                println("Command '$command' requires a database connection.")
                printstyled("Run ", color=:yellow)
                printstyled("init", color=:cyan, bold=true)
                printstyled(" or ", color=:yellow)
                printstyled("sync", color=:cyan, bold=true)
                printstyled(" first to create the database.\n", color=:yellow)
                flush(stdout)
                return
            end

            try
                with_cli_logger() do
                    # For commands that don't need DB, pass a dummy or handle specially
                    if command == "init"
                        cmd_init(; db_path=db_path)
                    elseif command == "sync" && db_ref[] === nothing
                        # sync can create the DB
                        db = init_project(db_path)
                        db_ref[] = db
                        dispatch_to_command(db_ref[], command, positional, options; 
                            db_path=db_path, events_dir="events", 
                            credentials_path="credentials.toml", from_repl=true)
                    elseif command == "playground" && !isempty(positional) && positional[1] == "init"
                        cmd_playground_init(; 
                            playground_name=length(positional) >= 2 ? positional[2] : nothing,
                            db_path=db_path, events_dir="events", 
                            force=get(options, :force, false), from_repl=true)
                    else
                        dispatch_to_command(db_ref[], command, positional, options; 
                            db_path=db_path, events_dir="events", 
                            credentials_path="credentials.toml", from_repl=true)
                    end
                end
                flush(stdout)
                flush(stderr)
                
                # After init/sync/playground init, connect to the database if we haven't yet
                if command in ["init", "sync"] || (command == "playground" && !isempty(positional) && positional[1] == "init")
                    if db_ref[] !== nothing
                        DBInterface.close!(db_ref[])
                    end
                    if isfile(db_path)
                        db_ref[] = init_database(db_path)
                        println()
                        printstyled("✓ ", color=:green, bold=true)
                        println("Database connected. All commands are now available.")
                        println()
                    end
                end
            catch e
                if e isa InterruptException
                    rethrow(e)
                end
                cli_print_error(e)
                flush(stderr)
            end
        end

        try
            LineEdit.run_interface(
                term,
                LineEdit.ModalInterface(LineEdit.TextInterface[panel, search_prompt])
            )
        catch e
            e isa EOFError || rethrow()
        end
    finally
        if db_ref[] !== nothing
            DBInterface.close!(db_ref[])
        end
    end
    return 0
end
