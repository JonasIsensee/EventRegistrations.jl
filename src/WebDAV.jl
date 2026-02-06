"""
WebDAV module for uploading files to WebDAV servers (ownCloud, Nextcloud, etc.)
"""
module WebDAV

using HTTP
using Base64
using Logging

export upload_via_webdav

"""
    upload_via_webdav(local_path::String, remote_path::String;
                      server_url::String, username::String, password::String) -> Int

Upload a file to a WebDAV server using HTTP PUT with Basic authentication.

# Arguments
- `local_path::String`: Path to the local file to upload
- `remote_path::String`: Remote path on the WebDAV server (relative to server_url)
- `server_url::String`: Base URL of the WebDAV server (e.g., "https://cloud.example.com/remote.php/webdav")
- `username::String`: WebDAV username for authentication
- `password::String`: WebDAV password for authentication

# Returns
- `0` on success
- `1` on failure

# Example
```julia
result = upload_via_webdav(
    "payment_status.xlsx",
    "share/payment_status.xlsx";
    server_url = "https://owncloud.example.com/remote.php/webdav",
    username = "user",
    password = "your-password"
)
```

# Notes
- Uses Basic authentication (credentials are Base64 encoded)
- Overwrites existing files at the remote path
- Returns error status but does not throw exceptions
"""
function upload_via_webdav(
    local_path::String,
    remote_path::String;
    server_url::String,
    username::String,
    password::String
)::Int
    # Validate inputs
    if !isfile(local_path)
        @error "Local file not found" local_path=local_path
        return 1
    end

    if isempty(server_url) || isempty(username) || isempty(password)
        @error "WebDAV credentials incomplete" has_url=!isempty(server_url) has_username=!isempty(username) has_password=!isempty(password)
        return 1
    end

    try
        # Normalize URLs: strip trailing slash from server_url
        normalized_server = rstrip(server_url, '/')

        # Construct full URL (ensure remote_path doesn't start with /)
        normalized_remote = lstrip(remote_path, '/')
        full_url = "$normalized_server/$normalized_remote"

        # Construct Basic Auth header
        auth_string = base64encode("$username:$password")

        # Read file content
        content = read(local_path)

        @info "Uploading to WebDAV" local_file=local_path remote_path=remote_path size_bytes=length(content) full_url

        # Perform HTTP PUT request
        response = HTTP.put(
            full_url,
            [
                "Authorization" => "Basic $auth_string",
                "Content-Type" => "application/octet-stream"
            ],
            content
        )

        # Check response status
        if 200 <= response.status < 300
            @info "✓ WebDAV upload successful" url=full_url status=response.status
            return 0
        else
            @error "WebDAV upload failed with HTTP error" url=full_url status=response.status
            return 1
        end

    catch e
        @error "WebDAV upload failed with exception" local_path=local_path exception=(e, catch_backtrace())
        return 1
    end
end

end # module WebDAV
