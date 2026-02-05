# Email processing commands

"""
Process registration emails from a folder.
Caller must open db; run_cli opens it before calling.
"""
function cmd_process_emails(db::DuckDB.DB, email_folder::String="emails";
    nonstop::Bool=false)
    if !isdir(email_folder)
        @error "Email folder not found" email_folder=email_folder
        return 1
    end
    @verbose_info "Processing emails" folder=email_folder
    stats = process_email_folder!(db, email_folder; prompt_for_new_events=false)

    # Show concise summary
    if stats.new_registrations > 0 || stats.updates > 0 || is_verbose()
        @info "Processed emails" new=stats.new_registrations updates=stats.updates
    end
    
    if is_verbose()
        summary = [
            "Processed: $(stats.processed)",
            "Submissions: $(stats.submissions)",
            "Skipped: $(stats.skipped)",
        ]
        @info join(summary, "\n")
    end

    if stats.no_cost_config > 0
        @warn "Registrations without cost config" count=stats.no_cost_config
    end
    return 0
end

"""
Download emails from POP3 server.
"""
function cmd_download_emails(;
    credentials_path::Union{Nothing,String}="credentials.toml",
    emails_dir::String="emails")

    ctx = load_app_config(; credentials_path)


    if isempty(ctx.email.pop3_server)
        @error """POP3 server not configured!

Ensure your credentials file (credentials.toml) contains:
[email]
server = "mail.example.com"
username = "user@example.com"
password = "your-password"
port = 995  # optional, defaults to 995"""
        return 1
    end

    @verbose_info "Downloading emails from POP3 server..." download_to=emails_dir
    result = download_emails!(ctx.email; emails_dir, verbose=is_verbose())

    if result.new_count > 0 || is_verbose()
        @info "Downloaded emails" new=result.new_count
    end
    
    if is_verbose()
        summary = [
            "Already downloaded: $(result.skipped_count)",
            "Total on server: $(result.total_on_server)",
        ]
        @info join(summary, "\n")
    end

    if result.error_count > 0
        @warn "Download errors" new=result.new_count errors=result.error_count
        return 1
    end
    
    return 0
end
