module EmailDownload

using Dates: Dates
using TOML: TOML

export download_emails!

"""
Get list of messages with their unique IDs using POP3 UIDL command.
Returns a vector of (message_num, uid) tuples.
"""
function list_message_uids(ctx)
    url = "pop3s://$(ctx.pop3_server):$(ctx.pop3_port)"
    # Use UIDL command to get unique IDs
    cmd = `curl -s -u $(ctx.pop3_username):$(ctx.pop3_password) --request UIDL $url`

    output = try
        read(cmd, String)
    catch e
        @error "Failed to connect to POP3 server" server=ctv.pop3_server error=e
        return Tuple{Int, String}[]
    end

    messages = Tuple{Int, String}[]
    for line in split(output, '\n')
        m = match(r"^(\d+)\s+(\S+)", strip(line))
        if m !== nothing
            push!(messages, (parse(Int, m[1]), m[2]))
        end
    end
    return messages
end

"""
Download a specific email by message number.
"""
function download_email(ctx, message_num)
    url = "pop3s://$(ctx.pop3_server):$(ctx.pop3_port)/$(message_num)"
    cmd = `curl -s -u $(ctx.pop3_username):$(ctx.pop3_password) $url`

    output = try
        read(cmd, String)
    catch e
        @error "Failed to download email" message_num=message_num error=e
        return nothing
    end

    return output
end

"""
Get set of already downloaded UIDs by reading filenames in emails folder.
Emails are saved as: emails/<uid>.eml
"""
function get_downloaded_uids(emails_dir::AbstractString)
    if !isdir(emails_dir)
        return Set{String}()
    end

    uids = Set{String}()
    for filename in readdir(emails_dir)
        if endswith(filename, ".eml")
            uid = replace(filename, ".eml" => "")
            push!(uids, uid)
        end
    end
    return uids
end

"""
Sanitize UID for use as filename (remove/replace problematic characters).
"""
function sanitize_uid(uid::AbstractString)
    # Replace characters that might cause filesystem issues
    return replace(uid, r"[/\\:*?\"<>|]" => "_")
end

"""
Download new emails from POP3 server.
Returns a named tuple with statistics about the download.

# Returns
Named tuple: (new_count, skipped_count, error_count, total_on_server)
"""
function download_emails!(ctx; emails_dir::AbstractString="emails", verbose::Bool=true)
    # Create emails directory if it doesn't exist
    mkpath(emails_dir)

    # Get already downloaded UIDs
    downloaded_uids = get_downloaded_uids(emails_dir)
    verbose && println("Found $(length(downloaded_uids)) previously downloaded emails")

    # Get current message list from server
    verbose && println("Connecting to $(ctx.pop3_server)...")
    server_messages = list_message_uids(ctx)

    if isempty(server_messages)
        @warn "No messages found on server or connection failed"
        return (new_count=0, skipped_count=0, error_count=1, total_on_server=0)
    end

    verbose && println("Found $(length(server_messages)) messages on server")

    # Find new messages
    new_messages = filter(msg -> msg[2] ∉ downloaded_uids, server_messages)
    verbose && println("$(length(new_messages)) new messages to download")

    # Download new messages
    error_count = 0
    for (i, (msg_num, uid)) in enumerate(new_messages)
        verbose && println("Downloading message $i/$(length(new_messages)) (UID: $uid)...")

        email_content = download_email(ctx, msg_num)

        if email_content === nothing
            error_count += 1
            continue
        end

        # Save to file
        safe_uid = sanitize_uid(uid)
        filepath = joinpath(emails_dir, "$(safe_uid).eml")

        try
            write(filepath, email_content)
            verbose && println("  Saved to $filepath ($(length(email_content)) bytes)")
        catch e
            @error "Failed to save email" filepath=filepath error=e
            error_count += 1
        end
    end

    verbose && println("Email download complete!")

    return (
        new_count = length(new_messages) - error_count,
        skipped_count = length(downloaded_uids),
        error_count = error_count,
        total_on_server = length(server_messages)
    )
end

end # module
