# =============================================================================
# INTERACTIVE REPL MODE
# =============================================================================
#
# Provides an interactive REPL with LineEdit for TAB completion, history
# navigation (arrow keys), and full readline-style editing (Ctrl-A, Ctrl-E, etc.)
# when eventreg is run with no arguments and stdin is a TTY.
#
# Resources: Julia REPL uses REPL.LineEdit, REPL.History; see
# https://docs.julialang.org/en/v1/stdlib/REPL/

using REPL
using REPL.LineEdit
# Commands for TAB completion (matches CLI dispatch)
const REPL_COMMANDS = [
    "init", "sync", "process-emails", "download-emails", "generate-field-config",
    "create-event-config", "sync-config", "recalculate-costs", "list-registrations",
    "event-overview", "status", "import-bank-csv", "match-transfers", "list-unmatched",
    "manual-match", "grant-subsidy", "export-payment-status", "export-registrations",
    "export-combined", "list-pending-emails", "mark-email", "send-emails",
    "validate-config",
]

# Common options for completion
const REPL_OPTIONS = [
    "--help", "-h", "--db-path", "--config-dir", "--verbose", "--strict",
    "--dry-run", "--nonstop", "--format", "--filter", "--output", "--event-id",
    "--upload", "--send-emails", "--export-details", "--export-payments",
    "--export-combined", "--id", "--name", "--email", "--since", "--summary-only",
    "--details",
]

"""
    EventRegCompletionProvider <: LineEdit.CompletionProvider

Completion provider for eventreg commands and options.
"""
struct EventRegCompletionProvider <: LineEdit.CompletionProvider
end

function LineEdit.complete_line(c::EventRegCompletionProvider, s::LineEdit.PromptState; hint::Bool=false)
    full = LineEdit.input_string(s)
    pos = LineEdit.position(LineEdit.buffer(s))
    prefix = pos > 0 ? full[1:prevind(full, pos + 1)] : ""
    parts = split(prefix, r"\s+"; limit=2, keepempty=true)
    prefix_word = isempty(parts) ? "" : String(parts[end])
    completions = LineEdit.NamedCompletion[]

    if length(parts) == 1
        # Completing command (first word)
        for cmd in REPL_COMMANDS
            if startswith(cmd, prefix_word) && cmd != prefix_word
                push!(completions, LineEdit.NamedCompletion(cmd, cmd))
            end
        end
    end
    if length(parts) >= 2
        # Completing option or positional (after command)
        for opt in REPL_OPTIONS
            if startswith(opt, prefix_word) && opt != prefix_word
                push!(completions, LineEdit.NamedCompletion(opt, opt))
            end
        end
    end

    # Region: byte range to replace (start => end, 0-based)
    word_len = sizeof(prefix_word)
    reg = (pos - word_len) => pos
    return completions, reg, true
end

# """
#     parse_repl_line(line::AbstractString) -> Vector{String}

# Parse a REPL input line into CLI arguments (split on whitespace, respecting quotes).
# """
# function parse_repl_line(line::AbstractString)
#     line = strip(line)
#     isempty(line) && return String[]
#     args = String[]
#     current = ""
#     in_quotes = false
#     quote_char = '\0'

#     i = firstindex(line)
#     while i <= ncodeunits(line)
#         c = line[i]
#         if in_quotes
#             if c == quote_char
#                 in_quotes = false
#                 quote_char = '\0'
#             else
#                 current *= c
#             end
#         elseif c in ('"', '\'')
#             in_quotes = true
#             quote_char = c
#         elseif c in (' ', '\t')
#             if !isempty(current)
#                 push!(args, current)
#                 current = ""
#             end
#         else
#             current *= c
#         end
#         i = nextind(line, i)
#     end
#     !isempty(current) && push!(args, current)
#     return args
# end

"""
    run_repl_linedit() -> Int

Run the interactive REPL using LineEdit (TAB completion, history, arrow keys).
Requires stdin to be a TTY. Returns exit code.
"""
function run_repl_linedit()
    term = REPL.Terminals.TTYTerminal(
        get(ENV, "TERM", "dumb"),
        stdin, stdout, stderr
    )
    hascolor = REPL.Terminals.hascolor(term)
    prefix = hascolor ? Base.text_colors[:green] : ""
    suffix = hascolor ? Base.text_colors[:normal] : ""

    # Create prompt
    panel = LineEdit.Prompt(
        "eventreg> ";
        prompt_prefix = prefix,
        prompt_suffix = suffix,
        complete = EventRegCompletionProvider(),
        on_enter = s -> true,  # Always accept on Enter (single-line commands)
    )

    # History provider (in-memory for session; persistent would need HistoryFile path)
    hp = REPL.REPLHistoryProvider(Dict{Symbol, LineEdit.Prompt}(:eventreg => panel))
    REPL.history_reset_state(hp)
    panel.hist = hp

    # Search prompt for ^R reverse search
    search_prompt, skeymap = LineEdit.setup_prefix_keymap(hp, panel)

    # Keymaps: search, history, default (arrows, Ctrl-A/E, etc.), escape sequences
    panel.keymap_dict = LineEdit.keymap(Dict{Any, Any}[
        skeymap,
        LineEdit.history_keymap,
        LineEdit.default_keymap,
        LineEdit.escape_defaults,
    ])

    # Process each line
    exit_requested = Ref(false)
    last_code = Ref(0)

    panel.on_done = (s, buf, ok) -> begin
        if !ok
            LineEdit.transition(s, :abort)
            return
        end
        line = strip(String(take!(buf)))
        LineEdit.reset_state(s)

        if isempty(line)
            return
        end

        # Exit commands
        lower = lowercase(line)
        if lower in ("exit", "quit", "q")
            exit_requested[] = true
            LineEdit.transition(s, :abort)
            return
        end

        # Help
        if lower in ("help", "--help", "-h")
            println(HELP_TEXT)
            return
        end

        args = parse_repl_line(line)
        try
            last_code[] = run_cli(args)
        catch e
            if e isa InterruptException
                last_code[] = 130
            else
                @error "Error" exception=(e, catch_backtrace())
                last_code[] = 1
            end
        end
    end

    # Banner
    println("EventRegistrations REPL. Type 'help' or commands. 'exit' or Ctrl-D to quit.")
    println()

    try
        REPL.LineEdit.run_interface(
            term,
            LineEdit.ModalInterface(LineEdit.TextInterface[panel, search_prompt])
        )
    catch e
        e isa EOFError || rethrow()
    end

    return last_code[]
end

"""
    run_repl_simple() -> Int

Fallback REPL using plain readline() when stdin is not a TTY.
No TAB completion or history navigation.
"""
function run_repl_simple()
    println("EventRegistrations REPL. Type 'help' or commands. 'exit' or Ctrl-D to quit.")
    println()
    last_code = 0
    while true
        try
            print("eventreg> ")
            flush(stdout)
            line = readline(stdin)
            line === nothing && break  # EOF
            line = strip(line)
            isempty(line) && continue

            lower = lowercase(line)
            if lower in ("exit", "quit", "q")
                break
            end
            if lower in ("help", "--help", "-h")
                println(HELP_TEXT)
                continue
            end

            args = parse_repl_line(line)
            last_code = run_cli(args)
        catch e
            e isa EOFError && break
            e isa InterruptException && (last_code = 130; break)
            rethrow()
        end
    end
    return last_code
end

# """
#     run_repl() -> Int

# Run interactive REPL mode. Uses LineEdit (TAB completion, history, arrow keys)
# when stdin is a TTY; falls back to simple readline otherwise.
# Returns exit code.
# """
# function run_repl()
#     # Use LineEdit when stdin is a TTY (enables TAB completion, history, arrow keys)
#     if stdin isa Base.TTY
#         return run_repl_linedit()
#     else
#         return run_repl_simple()
#     end
# end
