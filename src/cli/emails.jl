# Email processing commands

"""
Process registration emails from a folder.
"""
function cmd_process_emails(email_folder::String="emails";
                            db_path::String="events.duckdb",
                            nonstop::Bool=false)
    return with_cli_logger() do
        if !isdir(email_folder)
            @error "Email folder not found" email_folder=email_folder
            return 1
        end

        return require_database(db_path) do db
            @info "Processing emails" folder=email_folder
            stats = process_email_folder!(db, email_folder;
                              prompt_for_new_events=!nonstop)

            if stats.terminated
                @warn "⚠ Processing halted by user request to edit configuration."
            else
                @info "✓ Email processing complete!"
            end

            summary = [
                "Processed: $(stats.processed)",
                "Submissions: $(stats.submissions)",
                "New registrations: $(stats.new_registrations)",
                "Updates: $(stats.updates)",
                "Skipped: $(stats.skipped)",
            ]

            @info join(summary, "\n")

            if stats.no_cost_config > 0
                @warn "Registrations without cost config" count=stats.no_cost_config
            end
            return 0
        end
    end
end

"""
Download emails from POP3 server.
"""
function cmd_download_emails(;
    credentials_path::String="config/email_credentials.toml",
    emails_dir::String="emails",
    config_dir::String="config")

    return with_cli_logger() do
        # Check if credentials file exists, if not check alternative locations
        if !isfile(credentials_path)
            alternative_paths = [
                joinpath(config_dir, "credentials.toml"),
                "credentials.toml",
                "email_credentials.toml"
            ]

            found = false
            for alt_path in alternative_paths
                if isfile(alt_path)
                    credentials_path = alt_path
                    found = true
                    break
                end
            end

            if !found
                @error """Credentials file not found!

Searched locations:
  - config/email_credentials.toml
  - config/credentials.toml
  - credentials.toml
  - email_credentials.toml

Create a credentials file with the following format:
[email]
server = "mail.example.com"
username = "user@example.com"
password = "yourpassword"
port = 995  # optional, defaults to 995"""
                return 1
            end
        end

        @info "Downloading emails from POP3 server..." credentials_path=credentials_path download_to=emails_dir

        result = download_emails!(
            credentials_path=credentials_path,
            emails_dir=emails_dir,
            verbose=true
        )

        summary = [
            "New emails: $(result.new_count)",
            "Already downloaded: $(result.skipped_count)",
            "Total on server: $(result.total_on_server)",
        ]

        if result.error_count > 0
            push!(summary, "Errors: $(result.error_count)")
            @warn "⚠ Download completed with errors!\n$(join(summary, "\n"))"
            return 1
        else
            @info "✓ Email download complete!\n$(join(summary, "\n"))"
            return 0
        end
    end
end
