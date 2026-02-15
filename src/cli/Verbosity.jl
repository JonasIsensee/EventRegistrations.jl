# Verbosity management for CLI output
#
# This module provides a central verbosity flag that can be checked by any
# CLI command to determine whether to show detailed or concise output.

"""
Global verbosity state for the CLI. Controls how much detail is shown in output.

- `false` (default): Concise output suitable for REPL and scripts
- `true`: Detailed output with progress messages and field-by-field info
"""
const VERBOSE = Ref(false)

"""
    set_verbose!(state::Bool)

Set the global verbosity level for CLI output.
"""
function set_verbose!(state::Bool)
    VERBOSE[] = state
    return nothing
end

"""
    is_verbose()

Check if verbose output is enabled.
"""
is_verbose() = VERBOSE[]

"""
    verbose_info(msg; kwargs...)

Print an @info message only if verbose mode is enabled.
Use this for detailed progress messages that aren't needed in concise mode.
"""
macro verbose_info(msg, kwargs...)
    quote
        if is_verbose()
            @info $(esc(msg)) $(map(esc, kwargs)...)
        end
    end
end

"""
    concise_info(msg; kwargs...)

Print a concise @info message. This is shown regardless of verbosity setting.
Use this for important information that should always be displayed.
"""
macro concise_info(msg, kwargs...)
    quote
        @info $(esc(msg)) $(map(esc, kwargs)...)
    end
end
