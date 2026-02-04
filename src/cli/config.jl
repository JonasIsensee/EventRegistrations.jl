# =============================================================================
# Configuration Management CLI Commands
# =============================================================================

"""
Set email redirect address in credentials.toml for testing purposes.
All emails will be redirected to this address instead of actual recipients.
"""
function cmd_set_email_redirect(email::String; credentials_path::String="credentials.toml")
    # Validate email format with strict pattern to prevent SMTP injection
    # Allows only safe characters in local and domain parts
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
        @info "Email redirect set successfully" redirect_to=email credentials_path=credentials_path
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
        @warn "Credentials file does not exist" credentials_path=credentials_path
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
        @info "Email redirect cleared successfully" credentials_path=credentials_path
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
        @info "No credentials file found" credentials_path=credentials_path
        @info "Email redirect: not set"
        return 0
    end

    # Load credentials file
    config_dict = TOML.parsefile(credentials_path)
    
    # Check for redirect setting
    if haskey(config_dict, "smtp") && haskey(config_dict["smtp"], "redirect_to")
        redirect_to = config_dict["smtp"]["redirect_to"]
        if !isempty(redirect_to)
            @info "Email redirect: ACTIVE" redirect_to=redirect_to
            @warn "ALL emails are being sent to $redirect_to instead of actual recipients"
        else
            @info "Email redirect: not set"
        end
    else
        @info "Email redirect: not set"
    end
    
    return 0
end
