# =============================================================================
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

with_cli_logger(f::Function; io::IO=stdout) = with_logger(ConsoleLogger(io)) do
    f()
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

include("project.jl")
include("emails.jl")
include("registrations.jl")
include("sync_workflow.jl")
include("payments.jl")
include("exports.jl")
include("email_queue.jl")

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
EXPORTS:
  export-payment-status [event-id] [output]  Payment status with color highlighting
    --format=<fmt>               Output: terminal, pdf, latex, csv, xlsx
    --filter=<filter>            Filter: all, unpaid, problems, paid, no-config
    --summary-only               Show only totals, not individual rows
    --upload                     Upload exported file to WebDAV (requires credentials.toml)
  export-registrations [event-id] [output]   Export/print registration data
    --format=<fmt>               Output: terminal, pdf, latex, csv, xlsx
    --filter=<filter>            Filter: all, unpaid, problems, paid
    --details                    Include all registration fields (terminal/csv/xlsx)
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
  edit-registrations [event-id]   Edit registrations in external editor
    --event-id=<id>              Event to edit
    --name=<pattern>             Filter by name (regex)
    --since=<date>               Only registrations since date (yyyy-mm-dd)

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
  eventreg export-payment-status                           # colored terminal output
  eventreg export-payment-status --filter=unpaid           # show only unpaid
  eventreg export-payment-status --summary-only            # show only totals
  eventreg export-payment-status PWE_2026_01 report.pdf    # export to PDF
  eventreg export-payment-status --format=latex            # generate LaTeX
  eventreg export-payment-status --format=csv --upload     # export CSV and upload to WebDAV
  eventreg export-registrations report.pdf                 # export registrations to PDF
  eventreg export-registrations --format=xlsx --upload     # export XLSX and upload
  eventreg export-combined                                 # export most recent event
  eventreg export-combined PWE_2026_01                     # export specific event
  eventreg export-combined PWE_2026_01 custom_report.xlsx  # custom output file
  eventreg export-combined --upload                        # export and upload to WebDAV

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
    credentials_path::String="credentials.toml")
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
            isempty(positional) && (@error "event-id required"; return 1)
            return cmd_create_event_config(db, positional[1]; events_dir=events_dir)
        elseif command == "sync-config"
            return cmd_sync_config(db; events_dir=events_dir)
        elseif command == "recalculate-costs"
            isempty(positional) && (@error "event-id required"; return 1)
            return cmd_recalculate_costs(db, positional[1]; events_dir=events_dir, strict=get(options, :strict, false), dry_run=get(options, :dry_run, false))
        elseif command == "list-registrations"
            event_id = length(positional) >= 1 ? positional[1] : nothing
            return cmd_list_registrations(db, event_id; filter=get(options, :filter, "all"), name=get(options, :name, nothing), email=get(options, :email, nothing), since=get(options, :since, nothing))
        elseif command == "edit-registrations"
            event_id = get(options, :event_id, length(positional) >= 1 ? positional[1] : nothing)
            return cmd_edit_registrations(db; event_id=event_id, name=get(options, :name, nothing), since=get(options, :since, nothing), spawn_editor=true)
        elseif command == "event-overview"
            isempty(positional) && (@error "event-id required"; return 1)
            return cmd_event_overview(db, positional[1])
        elseif command == "status"
            return cmd_status(db; db_path=db_path)
        elseif command == "import-bank-csv"
            isempty(positional) && (@error "csv-file required"; return 1)
            return cmd_import_bank_csv(db, positional[1]; delimiter=get(options, :delimiter, ";"), decimal_comma=get(options, :decimal_comma, true))
        elseif command == "match-transfers"
            return cmd_match_transfers(db; event_id=get(options, :event_id, nothing))
        elseif command == "list-unmatched"
            return cmd_list_unmatched(db)
        elseif command == "review-near-misses"
            return cmd_review_near_misses(db; event_id=get(options, :event_id, nothing), nonstop=get(options, :nonstop, false))
        elseif command == "manual-match"
            length(positional) < 2 && (@error "transfer-id and reference required"; return 1)
            return cmd_manual_match(db, parse(Int, positional[1]), positional[2])
        elseif command == "grant-subsidy"
            length(positional) < 2 && (@error "identifier and amount required"; return 1)
            return cmd_grant_subsidy(db, positional[1], parse(Float64, positional[2]); reason=get(options, :reason, ""), granted_by=get(options, :granted_by, "cli"))
        elseif command == "delete-registration"
            isempty(positional) && (@error "identifier (id or reference) required"; return 1)
            return cmd_delete_registration(db, positional[1]; event_id=get(options, :event_id, nothing), yes=get(options, :yes, false))
        elseif command == "export-payment-status"
            event_id = length(positional) >= 1 ? positional[1] : nothing
            output = length(positional) >= 2 ? positional[2] : get(options, :output, nothing)
            return cmd_export_payment_status(db, event_id, output; format=get(options, :format, "terminal"), filter=get(options, :filter, "all"), summary_only=get(options, :summary_only, false), upload=get(options, :upload, false), credentials_path=credentials_path, db_path=db_path)
        elseif command == "export-registrations"
            event_id = length(positional) >= 1 ? positional[1] : nothing
            output = length(positional) >= 2 ? positional[2] : get(options, :output, nothing)
            return cmd_export_registrations(db, event_id, output; format=get(options, :format, "terminal"), filter=get(options, :filter, "all"), details=get(options, :details, false), events_dir=events_dir, upload=get(options, :upload, false), credentials_path=credentials_path, db_path=db_path)
        elseif command == "export-combined"
            event_id = length(positional) >= 1 ? positional[1] : nothing
            output = length(positional) >= 2 ? positional[2] : get(options, :output, nothing)
            return cmd_export_combined(db, event_id, output; events_dir=events_dir, upload=get(options, :upload, false), credentials_path=credentials_path, db_path=db_path)
        elseif command == "list-pending-emails"
            return cmd_list_pending_emails(db; event_id=get(options, :event_id, nothing), email_type=get(options, :email_type, nothing), verbose=get(options, :verbose, false))
        elseif command == "mark-email"
            isempty(positional) && (@error "status required"; return 1)
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
        else
            @error "Unknown command" command=command
            @info "Run 'eventreg --help' or type help for usage."
            return 1
        end
    catch e
        @error "Unhandled error" exception=(e, catch_backtrace())
        return isa(e, InterruptException) ? 130 : 1
    end
end

"""
Main CLI entry: open DB once (except for init/download-emails), then dispatch.
"""
function run_cli(args::Vector{String})
    return with_cli_logger() do
        command, positional, options = parse_cli_args(args)
        if isempty(command) || command in ["--help", "-h", "help"]
            @info HELP_TEXT
            return 0
        end
        db_path = get(options, :db_path, "events.duckdb")
        # Commands that don't need a DB connection
        if command == "init"
            return cmd_init(; db_path=db_path)
        end
        if command == "download-emails"
            return cmd_download_emails(; options...)
        end
        # Sync can create the DB; all other commands require it to exist
        if command == "sync"
            db = !isfile(db_path) ? init_project(db_path) : init_database(db_path)
        else
            if !isfile(db_path)
                error("Database not found: $db_path\n\n" *
                      "Run one of the following to create it:\n" *
                      "  eventreg init        # Initialize new project\n" *
                      "  eventreg sync        # Full sync (also creates DB if missing)")
            end
            db = init_database(db_path)
        end
        try
            return dispatch_to_command(db, command, positional, options; db_path=db_path, events_dir="events", credentials_path="credentials.toml")
        finally
            DBInterface.close!(db)
        end
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

"""
Run the interactive REPL. Resolves db_path (default events.duckdb in cwd),
ensures the database exists, opens it once, then runs a read loop dispatching
each line via dispatch_to_command. Type exit or quit, or Ctrl-D to quit.
After 'init', the connection is closed and re-opened to use the new project.
"""
function run_repl(; db_path::String="events.duckdb")
    db_path = get(ENV, "EVENTREG_DB_PATH", db_path)
    if !isfile(db_path)
        @error "Database not found: $db_path" hint="Run 'eventreg init' or 'eventreg sync' first (outside REPL)."
        return 1
    end
    db = init_database(db_path)
    try
        println(REPL_BANNER)
        while true
            print(REPL_PROMPT)
            flush(stdout)
            line = readline()
            if line === nothing || isempty(strip(line))
                break
            end
            strip(line) in ("exit", "quit") && break
            args = parse_repl_line(line)
            isempty(args) && continue
            command, positional, options = parse_cli_args(args)
            if command in ["--help", "-h", "help"]
                @info HELP_TEXT
                continue
            end
            code = with_cli_logger() do
                dispatch_to_command(db, command, positional, options; db_path=db_path, events_dir="events", credentials_path="credentials.toml")
            end
            if command == "init"
                DBInterface.close!(db)
                db = init_database(db_path)
            end
        end
    finally
        DBInterface.close!(db)
    end
    return 0
end
