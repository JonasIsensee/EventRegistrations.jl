# =============================================================================
# Configuration Management CLI Commands
# =============================================================================

"""
Set email redirect address in credentials.toml for testing purposes.
All emails will be redirected to this address instead of actual recipients.

Note: Only accepts standard ASCII email addresses. Internationalized domain
names (IDN) and non-ASCII characters are not supported.
"""
function cmd_set_email_redirect(email::String; credentials_path::String="credentials.toml")
    # First, explicitly reject dangerous characters that could enable SMTP header injection
    # This includes newlines (\r\n), null bytes (\0), and tabs (which are excluded by the regex)
    if occursin(r"[\r\n\t\0]", email)
        @error "Email address contains dangerous characters (newline, tab, or null byte)" email=email
        return 1
    end
    
    # Validate email format with strict pattern to prevent SMTP injection
    # Allows only safe ASCII characters in local and domain parts
    # Note: TLD must be at least 2 characters (excludes rare single-char TLDs)
    # Note: Internationalized email addresses (IDN/EAI) are not supported
    if !occursin(r"^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$", email)
        @error "Invalid email address format" email=email
        return 1
    end

    # Load or create credentials file
    config_dict = isfile(credentials_path) ? TOML.parsefile(credentials_path) : Dict()
    
    # Ensure smtp section exists
    if !haskey(config_dict, "smtp")
        config_dict["smtp"] = Dict()
    end
    
    # Set redirect_to
    config_dict["smtp"]["redirect_to"] = email
    
    # Write back to file
    try
        open(credentials_path, "w") do io
            TOML.print(io, config_dict)
        end
        @info "Email redirect set: $(email) ($(credentials_path))"
        @warn "ALL emails will now be sent to $email instead of actual recipients"
        return 0
    catch e
        @error "Failed to write credentials file" exception=(e, catch_backtrace())
        return 1
    end
end

"""
Clear email redirect address from credentials.toml.
Emails will be sent to actual recipients.
"""
function cmd_clear_email_redirect(; credentials_path::String="credentials.toml")
    if !isfile(credentials_path)
        @warn "Credentials file does not exist: $(credentials_path)"
        return 0
    end

    # Load credentials file
    config_dict = TOML.parsefile(credentials_path)
    
    # Check if redirect is set
    if !haskey(config_dict, "smtp") || !haskey(config_dict["smtp"], "redirect_to")
        @info "Email redirect was not set"
        return 0
    end
    
    # Remove redirect_to
    delete!(config_dict["smtp"], "redirect_to")
    
    # Write back to file
    try
        open(credentials_path, "w") do io
            TOML.print(io, config_dict)
        end
        @info "Email redirect cleared ($(credentials_path))"
        @info "Emails will now be sent to actual recipients"
        return 0
    catch e
        @error "Failed to write credentials file" exception=(e, catch_backtrace())
        return 1
    end
end

"""
Show current email redirect setting from credentials.toml.
"""
function cmd_get_email_redirect(; credentials_path::String="credentials.toml")
    if !isfile(credentials_path)
        @info "No credentials file found: $(credentials_path)"
        @info "Email redirect: not set"
        return 0
    end

    # Load credentials file
    config_dict = TOML.parsefile(credentials_path)
    
    # Check for redirect setting
    if haskey(config_dict, "smtp") && haskey(config_dict["smtp"], "redirect_to")
        redirect_to = config_dict["smtp"]["redirect_to"]
        # Empty string is treated as "not set" (allows manual clearing in TOML)
        if !isempty(redirect_to)
            @info "Email redirect ACTIVE: $(redirect_to)"
            @warn "ALL emails are being sent to $redirect_to instead of actual recipients"
        else
            @info "Email redirect: not set"
        end
    else
        @info "Email redirect: not set"
    end
    
    return 0
end

# =============================================================================
# Event Config Editing Command
# =============================================================================

"""
Format an EventConfig for display as a summary.
"""
function format_event_config_summary(cfg::Config.EventConfig)
    lines = String[]
    
    push!(lines, "")
    push!(lines, "=" ^ 60)
    push!(lines, "Event Configuration Summary")
    push!(lines, "=" ^ 60)
    push!(lines, "")
    push!(lines, "  Event ID:    $(cfg.event_id)")
    push!(lines, "  Event Name:  $(cfg.name)")
    push!(lines, "  Config Path: $(cfg.config_path)")
    push!(lines, "")
    push!(lines, "Cost Configuration:")
    push!(lines, "  Base cost:       $(cfg.base_cost)")
    push!(lines, "  Cost rules:      $(length(cfg.rules))")
    push!(lines, "  Computed fields: $(length(cfg.computed_fields))")
    
    if !isempty(cfg.aliases)
        push!(lines, "  Field aliases:   $(length(cfg.aliases))")
    end
    
    # Show first few cost rules
    if !isempty(cfg.rules)
        push!(lines, "")
        push!(lines, "Cost Rules Preview:")
        for (i, rule) in enumerate(cfg.rules)
            i > 5 && (push!(lines, "  ... and $(length(cfg.rules) - 5) more rules"); break)
            field = get(rule, "field", "?")
            cost = get(rule, "cost", 0.0)
            if haskey(rule, "value")
                push!(lines, "  [$i] $(field) = \"$(rule["value"])\" → $(cost)")
            elseif haskey(rule, "pattern")
                push!(lines, "  [$i] $(field) ~ /$(rule["pattern"])/ → $(cost)")
            end
        end
    end
    
    # Show export configuration if present
    if cfg.export_registration_columns !== nothing
        push!(lines, "")
        push!(lines, "Export Configuration:")
        push!(lines, "  Registration columns: $(length(cfg.export_registration_columns))")
    end
    
    push!(lines, "")
    push!(lines, "=" ^ 60)
    
    return join(lines, "\n")
end

"""
Open the user's preferred editor for a file.
Returns the editor exit code.
"""
function open_editor(filepath::String)
    editor = get(ENV, "EDITOR", get(ENV, "VISUAL", ""))
    
    if isempty(editor)
        # Try common editors
        for candidate in ["nano", "vim", "vi", "notepad"]
            if Sys.which(candidate) !== nothing
                editor = candidate
                break
            end
        end
    end
    
    if isempty(editor)
        error("No editor found. Set the EDITOR environment variable.")
    end
    
    # Run editor interactively
    cmd = `$editor $filepath`
    return run(cmd).exitcode
end

"""
Prompt user for a yes/no/edit response.
Returns :yes, :no, or :edit
"""
function prompt_yes_no_edit(prompt::String; default::Symbol=:no)
    default_str = default == :yes ? "Y/n/e" : (default == :edit ? "y/n/E" : "y/N/e")
    print(prompt, " [$default_str]: ")
    flush(stdout)
    
    response = lowercase(strip(readline()))
    
    if isempty(response)
        return default
    elseif response in ["y", "yes"]
        return :yes
    elseif response in ["n", "no"]
        return :no
    elseif response in ["e", "edit"]
        return :edit
    else
        return default
    end
end

"""
Format a TOML.ParserError into a helpful error message with line/column info.
"""
function format_toml_error(e::TOML.ParserError, filepath::String)
    lines = String[]
    
    # Build error description
    error_type = string(e.type)
    push!(lines, "TOML syntax error: $error_type")
    push!(lines, "  File: $filepath")
    push!(lines, "  Line: $(e.line), Column: $(e.column)")
    
    # Show the problematic line if we can read the file
    if isfile(filepath)
        try
            file_lines = readlines(filepath)
            if 1 <= e.line <= length(file_lines)
                problematic_line = file_lines[e.line]
                push!(lines, "")
                push!(lines, "  $(e.line) | $problematic_line")
                # Add a caret pointing to the column
                if e.column > 0
                    spaces = " " ^ (length(string(e.line)) + 3 + e.column - 1)
                    push!(lines, "$spaces^")
                end
            end
        catch
            # Ignore errors reading the file
        end
    end
    
    # Add hint about the data if available
    if e.data !== nothing && !isempty(string(e.data))
        push!(lines, "")
        push!(lines, "  Near: $(e.data)")
    end
    
    return join(lines, "\n")
end

"""
Try to parse a TOML file and load it as an EventConfig.
Returns (success::Bool, config_or_error)
"""
function try_parse_event_config(filepath::String, event_id::String)
    try
        # First, try to parse as TOML
        config_dict = TOML.parsefile(filepath)
        
        # Create a temporary directory structure to use load_event_config
        # We need to write the file to a temp location with the right name
        temp_dir = mktempdir()
        temp_config_path = joinpath(temp_dir, "$(event_id).toml")
        cp(filepath, temp_config_path)
        
        # Try to load as EventConfig
        cfg = Config.load_event_config(event_id, temp_dir)
        
        # Clean up
        rm(temp_dir; recursive=true)
        
        if cfg === nothing
            return (false, "Failed to parse event configuration structure")
        end
        
        return (true, cfg)
    catch e
        if e isa TOML.ParserError
            return (false, format_toml_error(e, filepath))
        else
            return (false, "Parse error: $(sprint(showerror, e))")
        end
    end
end

"""
Edit an event configuration file interactively.

Opens the config file in the user's preferred editor (via \$EDITOR).
On save, validates the config and shows a summary. If invalid, offers
to re-edit or discard. If valid, offers to accept (overwrite original)
and optionally sync to database.

# Arguments
- `event_id`: The event ID whose config to edit

# Keyword Arguments
- `events_dir`: Directory containing event config files (default: "events")
- `db`: Optional database connection for syncing after edit

# Returns
- 0 on success, 1 on error
"""
function cmd_edit_event_config(event_id::String;
        events_dir::String="events",
        db::Union{DuckDB.DB, Nothing}=nothing)
    
    # Check if config file exists
    config_path = joinpath(events_dir, "$(event_id).toml")
    
    if !isfile(config_path)
        @error "Event config not found" path=config_path
        @info "Use 'eventreg create-event-config $(event_id)' to create a new config"
        return 1
    end
    
    # Create a temporary copy for editing
    temp_file = tempname() * ".toml"
    cp(config_path, temp_file)
    
    try
        while true
            # Open editor
            @info "Opening editor for event config: $(event_id)"
            editor_code = open_editor(temp_file)
            
            if editor_code != 0
                @warn "Editor exited with non-zero status" code=editor_code
            end
            
            # Check if file was modified (or just always parse)
            original_content = read(config_path, String)
            edited_content = read(temp_file, String)
            
            if original_content == edited_content
                @info "No changes detected"
                return 0
            end
            
            # Try to parse the edited config
            success, result = try_parse_event_config(temp_file, event_id)
            
            if !success
                # Parse failed - offer to re-edit or discard
                println()
                println("❌ Configuration Error:")
                println("   $(result)")
                println()
                
                response = prompt_yes_no_edit("Re-edit the file?"; default=:edit)
                
                if response == :edit
                    continue  # Loop back to editor
                else
                    @info "Discarding changes"
                    return 0
                end
            end
            
            # Parse succeeded - show summary
            cfg = result
            println(format_event_config_summary(cfg))
            
            # Ask to accept changes
            response = prompt_yes_no_edit("Accept changes and overwrite original config?"; default=:no)
            
            if response == :edit
                continue  # Loop back to editor
            elseif response == :no
                @info "Discarding changes"
                return 0
            end
            
            # Accept: overwrite original file
            cp(temp_file, config_path; force=true)
            @info "Config saved: $(config_path)"
            
            # Ask to sync if we have a database connection
            if db !== nothing
                sync_response = prompt_user_bool("Sync config to database and recalculate costs?"; default=true)
                
                if sync_response
                    @info "Syncing configuration..."
                    sync_event_configs_to_db!(db, events_dir)
                    recalculate_costs!(db, event_id; events_dir=events_dir)
                    @info "Config synced and costs recalculated"
                end
            else
                @info "Run 'eventreg sync-config && eventreg recalculate-costs $(event_id)' to apply changes"
            end
            
            return 0
        end
    finally
        # Clean up temp file
        isfile(temp_file) && rm(temp_file)
    end
end
