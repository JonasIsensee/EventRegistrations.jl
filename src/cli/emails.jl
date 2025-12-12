# Email processing commands

"""
Process registration emails from a folder.
"""
function cmd_process_emails(email_folder::String="emails";
                            db_path::String="events.duckdb",
                            nonstop::Bool=false)
    if !isdir(email_folder)
        println("❌ Error: Email folder not found: $email_folder")
        return 1
    end

    return require_database(db_path) do db
        println("Processing emails from: $email_folder")
    stats = process_email_folder!(db, email_folder;
                      prompt_for_new_events=!nonstop)

        if stats.terminated
            println("\n⚠ Processing halted by user request to edit configuration.")
        else
            println("\n✓ Email processing complete!")
        end
        println("  Processed: $(stats.processed)")
        println("  Submissions: $(stats.submissions)")
        println("  New registrations: $(stats.new_registrations)")
        println("  Updates: $(stats.updates)")
        println("  Skipped: $(stats.skipped)")
        if stats.no_cost_config > 0
            println("  ⚠ Registrations without cost config: $(stats.no_cost_config)")
        end
        return 0
    end
end

"""
Download emails from POP3 server.
"""
function cmd_download_emails(;
    credentials_path::String="config/email_credentials.toml",
    emails_dir::String="emails",
    config_dir::String="config")

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
            println("❌ Error: Credentials file not found!")
            println("\nSearched locations:")
            println("  - config/email_credentials.toml")
            println("  - config/credentials.toml")
            println("  - credentials.toml")
            println("  - email_credentials.toml")
            println("\nCreate a credentials file with the following format:")
            println("""
            [email]
            server = "mail.example.com"
            username = "user@example.com"
            password = "yourpassword"
            port = 995  # optional, defaults to 995
            """)
            return 1
        end
    end

    println("Downloading emails from POP3 server...")
    println("  Credentials: $credentials_path")
    println("  Download to: $emails_dir")

    result = download_emails!(
        credentials_path=credentials_path,
        emails_dir=emails_dir,
        verbose=true
    )

    if result.error_count > 0
        println("\n⚠ Download completed with errors!")
        println("  New emails: $(result.new_count)")
        println("  Already downloaded: $(result.skipped_count)")
        println("  Errors: $(result.error_count)")
        println("  Total on server: $(result.total_on_server)")
        return 1
    else
        println("\n✓ Email download complete!")
        println("  New emails: $(result.new_count)")
        println("  Already downloaded: $(result.skipped_count)")
        println("  Total on server: $(result.total_on_server)")
        return 0
    end
end
