# Export commands and helpers
using TableExport: ExportConfig, SheetConfig, SheetData, ColumnConfig, export_tables
using Printf: @sprintf
using Dates: Dates

"""
Upload an exported file to WebDAV server if credentials are configured.

This function handles WebDAV uploads for export commands with the --upload flag.
It validates credentials, filters file types, and gracefully handles errors.

# Arguments
- `ctx::AppConfig`: Application configuration containing WebDAV credentials
- `local_file::String`: Path to the local file to upload

# Behavior
- Only uploads .xlsx, .csv, and .pdf files (filters out terminal output and .tex files)
- Constructs remote path from `ctx.email.webdav_remote_path` + filename
- Logs success with @info or failure with @warn
- Always succeeds (doesn't throw exceptions or propagate errors)
- Skips upload if WebDAV credentials are missing

# Returns
Nothing (void function)

# Example
```julia
ctx = load_app_config(; credentials_path="credentials.toml")
upload_export_to_webdav(ctx, "payment_status_PWE_2026_01.xlsx")
```
"""
function upload_export_to_webdav(ctx::AppConfig, local_file::String)
    # Check if file exists
    if !isfile(local_file)
        @warn "Cannot upload: file not found" local_file=local_file
        return
    end

    # Filter by file extension (only upload .xlsx, .csv, .pdf)
    ext = lowercase(splitext(local_file)[2])
    if ext ∉ [".xlsx", ".csv", ".pdf"]
        @info "Skipping WebDAV upload for non-supported format" file=local_file extension=ext
        return
    end

    # Validate WebDAV credentials
    if isempty(ctx.email.webdav_url)
        @info "WebDAV upload skipped: no URL configured"
        return
    end

    if isempty(ctx.email.webdav_username) || isempty(ctx.email.webdav_password)
        @warn "WebDAV upload skipped: incomplete credentials (missing username or password)"
        return
    end

    # Construct remote path
    filename = basename(local_file)
    remote_path = if isempty(ctx.email.webdav_remote_path)
        filename
    else
        # Ensure remote_path ends with / for proper joining
        base = rstrip(ctx.email.webdav_remote_path, '/')
        "$base/$filename"
    end

    # Attempt upload
    try
        result = upload_via_webdav(
            local_file,
            remote_path;
            server_url = ctx.email.webdav_url,
            username = ctx.email.webdav_username,
            password = ctx.email.webdav_password
        )

        if result == 0
            @info "✓ File uploaded to WebDAV" local_file=local_file remote_path=remote_path
        else
            @warn "WebDAV upload failed (see earlier error messages)" local_file=local_file
        end
    catch e
        @warn "WebDAV upload failed with exception" local_file=local_file exception=(e, catch_backtrace())
    end

    # Always return successfully (upload failures don't fail exports)
    return
end

"""
Export payment status report. Caller must open db; run_cli opens it before calling.
"""
function cmd_export_payment_status(db::DuckDB.DB,
    event_id::Union{String,Nothing}=nothing,
    actual_output::Union{String,Nothing}=nothing;
    format::String="terminal",
    filter::String="all",
    summary_only::Bool=false,
    upload::Bool=false,
    credentials_path::String="credentials.toml",
    db_path::String="events.duckdb",
    pager::Bool=false)
    local_event_id = event_id
    if local_event_id === nothing
        local_event_id = get_most_recent_event(db)
        if local_event_id === nothing
            @error "No events with registrations found"
            return 1
        end
        @info "Using most recent event" event_id=local_event_id
    end

    payment_filter = if filter == "unpaid"
        PaymentFilter(unpaid_only=true)
    elseif filter == "problems"
        PaymentFilter(problems_only=true)
    elseif filter == "paid"
        PaymentFilter(paid_only=true)
    elseif filter == "no-config"
        PaymentFilter(no_config_only=true)
    else
        PaymentFilter()
    end

    table_data = get_payment_table_data(db, local_event_id)
    if table_data.total_registrations == 0
        @info "No registrations found for event" event_id=local_event_id
        return 0
    end

    if summary_only
        title_str = "Payment Status: $(table_data.event_id)"
        if table_data.event_name !== nothing
            title_str *= " - $(table_data.event_name)"
        end
        @info """$title_str
$("=" ^ length(title_str))"""
        print_summary(table_data)
        return 0
    end

    output_format = format
    if actual_output !== nothing && output_format == "terminal"
        ext = lowercase(splitext(actual_output)[2])
        if ext == ".pdf"
            output_format = "pdf"
        elseif ext == ".tex"
            output_format = "latex"
        elseif ext == ".csv"
            output_format = "csv"
        elseif ext == ".xlsx"
            output_format = "xlsx"
        end
    end

    if output_format == "terminal" || (actual_output === nothing && output_format == "terminal")
        print_payment_table(table_data; filter=payment_filter, pager=pager)
    elseif output_format == "pdf"
        output_path = actual_output === nothing ? "payment_status_$(local_event_id).pdf" : actual_output
        @info "Generating PDF" output_path=output_path
        export_payment_pdf(table_data, output_path; filter=payment_filter)
        @info "✓ PDF exported" output_path=output_path
        if upload
            ctx = load_app_config(; db_path, credentials_path)
            upload_export_to_webdav(ctx, output_path)
        end
    elseif output_format == "latex"
        output_path = actual_output === nothing ? "payment_status_$(local_event_id).tex" : actual_output
        @info "Generating LaTeX" output_path=output_path
        latex_content = generate_latex_document(table_data; filter=payment_filter)
        open(output_path, "w") do f
            write(f, latex_content)
        end
        @info "✓ LaTeX exported" output_path=output_path
    elseif output_format == "xlsx"
        output_path = actual_output === nothing ? "payment_status_$(local_event_id).xlsx" : actual_output
        @info "Exporting XLSX" output_path=output_path
        export_payment_xlsx(table_data, output_path; filter=payment_filter)
        @info "✓ XLSX exported" output_path=output_path
        if upload
            ctx = load_app_config(; db_path, credentials_path)
            upload_export_to_webdav(ctx, output_path)
        end
    elseif output_format == "csv"
        output_path = actual_output === nothing ? "payment_status_$(local_event_id).csv" : actual_output
        @info "Exporting CSV" output_path=output_path
        export_payment_csv(table_data, output_path; filter=payment_filter)
        @info "✓ CSV exported" output_path=output_path
        if upload
            ctx = load_app_config(; db_path, credentials_path)
            upload_export_to_webdav(ctx, output_path)
        end
    else
        @error "Unknown format" format=output_format supported=["terminal", "pdf", "latex", "xlsx", "csv"]
        return 1
    end
    return 0
end

"""
Export registrations report with optional filters and formats.
Caller must open db; run_cli opens it before calling.
"""
function cmd_export_registrations(db::DuckDB.DB,
    event_id::Union{String,Nothing}=nothing,
    actual_output::Union{String,Nothing}=nothing;
    format::String="terminal",
    filter::String="all",
    details::Bool=false,
    events_dir::String="events",
    upload::Bool=false,
    credentials_path::String="credentials.toml",
    db_path::String="events.duckdb",
    pager::Bool=false)
    local_event_id = event_id
    if local_event_id === nothing
        local_event_id = get_most_recent_event(db)
        if local_event_id === nothing
            @error "No events with registrations found"
            return 1
        end
        @info "Using most recent event" event_id=local_event_id
    end

    reg_filter = if filter == "unpaid"
        RegistrationFilter(unpaid_only=true)
    elseif filter == "problems"
        RegistrationFilter(problems_only=true)
    elseif filter == "paid"
        RegistrationFilter(paid_only=true)
    else
        RegistrationFilter()
    end

    output_format = format
    if actual_output !== nothing && output_format == "terminal"
        ext = lowercase(splitext(actual_output)[2])
        if ext == ".pdf"
            output_format = "pdf"
        elseif ext == ".tex"
            output_format = "latex"
        elseif ext == ".csv"
            output_format = "csv"
        elseif ext == ".xlsx"
            output_format = "xlsx"
        end
    end

    if details
        detail_table = get_registration_detail_table(db, local_event_id; events_dir)
        if isempty(detail_table.rows)
            @info "No registrations found for event" event_id=local_event_id
            return 0
        end
        if output_format == "terminal"
            print_registration_detail_table(detail_table)
        elseif output_format == "csv"
            output_path = actual_output === nothing ? "registration_details_$(local_event_id).csv" : actual_output
            export_registration_detail_csv(detail_table, output_path)
            if upload
                ctx = load_app_config(; db_path, credentials_path)
                upload_export_to_webdav(ctx, output_path)
            end
        elseif output_format == "xlsx"
            output_path = actual_output === nothing ? "registration_details_$(local_event_id).xlsx" : actual_output
            export_registration_detail_xlsx(detail_table, output_path)
            if upload
                ctx = load_app_config(; db_path, credentials_path)
                upload_export_to_webdav(ctx, output_path)
            end
        else
            @error "Unsupported format for details view" format=output_format supported=["terminal", "csv", "xlsx"]
            return 1
        end
        return 0
    end

    table_data = get_registration_table_data(db, local_event_id)
    if table_data.total_registrations == 0
        @info "No registrations found for event" event_id=local_event_id
        return 0
    end

    if output_format == "terminal" || (actual_output === nothing && output_format == "terminal")
        print_registration_table(table_data; filter=reg_filter, pager=pager)
    elseif output_format == "pdf"
        output_path = actual_output === nothing ? "registrations_$(local_event_id).pdf" : actual_output
        @info "Generating PDF" output_path=output_path
        export_registration_pdf(table_data, output_path; filter=reg_filter)
        @info "✓ PDF exported" output_path=output_path
        if upload
            ctx = load_app_config(; db_path, credentials_path)
            upload_export_to_webdav(ctx, output_path)
        end
    elseif output_format == "latex"
        output_path = actual_output === nothing ? "registrations_$(local_event_id).tex" : actual_output
        @info "Generating LaTeX" output_path=output_path
        latex_content = generate_registration_latex_document(table_data; filter=reg_filter)
        open(output_path, "w") do f
            write(f, latex_content)
        end
        @info "✓ LaTeX exported" output_path=output_path
    elseif output_format == "xlsx"
        output_path = actual_output === nothing ? "registrations_$(local_event_id).xlsx" : actual_output
        @info "Exporting XLSX" output_path=output_path
        export_registration_xlsx(table_data, output_path; filter=reg_filter)
        @info "✓ XLSX exported" output_path=output_path
        if upload
            ctx = load_app_config(; db_path, credentials_path)
            upload_export_to_webdav(ctx, output_path)
        end
    elseif output_format == "csv"
        output_path = actual_output === nothing ? "registrations_$(local_event_id).csv" : actual_output
        @info "Exporting CSV" output_path=output_path
        export_registration_csv(table_data, output_path; filter=reg_filter)
        @info "✓ CSV exported" output_path=output_path
        if upload
            ctx = load_app_config(; db_path, credentials_path)
            upload_export_to_webdav(ctx, output_path)
        end
    else
        @error "Unknown format" format=output_format supported=["terminal", "pdf", "latex", "xlsx", "csv"]
        return 1
    end
    return 0
end

function format_detail_display_value(value)
    if value === nothing || value === missing
        return "—"
    elseif value isa AbstractDict || value isa AbstractVector
        return JSON.json(value)
    else
        return string(value)
    end
end

function format_detail_csv_value(value)
    if value === nothing || value === missing
        return ""
    elseif value isa AbstractDict || value isa AbstractVector
        return JSON.json(value)
    else
        return string(value)
    end
end

csv_escape(value::AbstractString) = "\"" * replace(value, "\"" => "\"\"") * "\""

function print_registration_detail_table(table::RegistrationDetailTable; io::IO=stdout)
    row_count = length(table.rows)
    col_count = length(table.columns)
    data_matrix = Matrix{String}(undef, row_count, col_count)

    for (i, row) in enumerate(table.rows)
        for (j, cell) in enumerate(row)
            data_matrix[i, j] = format_detail_display_value(cell)
        end
    end

    title = "Registration Details: $(table.event_id)"
    if table.event_name !== nothing
        title *= " - $(table.event_name)"
    end

    println(io)
    println(io, title)
    println(io, "=" ^ length(title))
    println(io)

    alignments = fill(:l, col_count)
    pretty_table(io, data_matrix;
        column_labels = table.columns,
        alignment = alignments,
        maximum_number_of_columns = -1,
        maximum_number_of_rows = -1,
        vertical_crop_mode = :none
    )

    println(io)
    println(io, "Rows: $row_count")
end

function export_registration_detail_csv(table::RegistrationDetailTable, output_path::String)
    open(output_path, "w") do io
        header = [csv_escape(col) for col in table.columns]
        println(io, join(header, ","))

        for row in table.rows
            formatted = [csv_escape(format_detail_csv_value(cell)) for cell in row]
            println(io, join(formatted, ","))
        end
    end

    @info "✓ Registration details exported" output_path=output_path
    return output_path
end

"""
Get matched bank transfer data for an event.
Returns data for registrations that have at least one matched transfer.
"""
function get_matched_transfers_data(db::DuckDB.DB, event_id::String)
    result = DBInterface.execute(db, """
        SELECT
            r.reference_number,
            r.first_name || ' ' || r.last_name as full_name,
            r.email,
            bt.transfer_date,
            bt.amount,
            bt.sender_name,
            bt.sender_iban,
            bt.reference_text,
            pm.match_type,
            pm.match_confidence,
            pm.matched_reference
        FROM registrations r
        JOIN payment_matches pm ON pm.registration_id = r.id
        JOIN bank_transfers bt ON bt.id = pm.transfer_id
        WHERE r.event_id = ? AND r.deleted_at IS NULL
        ORDER BY r.reference_number, bt.transfer_date
    """, [event_id])

    headers = [
        "Reference",
        "Name",
        "Email",
        "Transfer Date",
        "Amount",
        "Sender Name",
        "Sender IBAN",
        "Reference Text",
        "Match Type",
        "Confidence",
        "Matched Ref"
    ]

    rows = Vector{Vector{Any}}()
    for row in collect(result)
        ref_num, name, email, trans_date, amount, sender, iban, ref_text, match_type, confidence, matched_ref = row

        push!(rows, [
            something(ref_num, ""),
            something(name, ""),
            something(email, ""),
            something(trans_date, "") isa String ? trans_date : Dates.format(trans_date, "yyyy-mm-dd"),
            @sprintf("%.2f", Float64(something(amount, 0))),
            something(sender, ""),
            something(iban, ""),
            something(ref_text, ""),
            something(match_type, ""),
            something(confidence, "") == "" ? "" : @sprintf("%.0f%%", Float64(confidence) * 100),
            something(matched_ref, "")
        ])
    end

    return SheetData(headers=headers, rows=rows), length(rows)
end

"""
Export combined multi-sheet XLSX with both registration details and payment status.
Similar to the old export_config approach.
"""
function export_combined_xlsx(db::DuckDB.DB, event_id::String, output_path::String;
                              events_dir::String="events")
    # Get registration details
    detail_table = get_registration_detail_table(db, event_id; events_dir)
    if isempty(detail_table.rows)
        @warn "No registrations found for event" event_id=event_id
        return 1
    end

    # Get payment status
    payment_data = get_payment_table_data(db, event_id)

    subtitle = detail_table.event_name === nothing ? event_id : "$(event_id) - $(detail_table.event_name)"

    # Build registration sheet with smart formatting
    reg_rows = [[format_detail_csv_value(cell) for cell in row] for row in detail_table.rows]
    reg_column_configs = ColumnConfig[]

    for (idx, header) in enumerate(detail_table.columns)
        col_config = ColumnConfig(index=idx)

        # Apply smart display headers for common long field names
        if occursin("Übernachtung", header)
            col_config.display_header = replace(header, r"Übernachtung\s+" => "", r"\s*\(.*?\)" => "")
            col_config.rotate_header = true
            col_config.center_content = true
        elseif occursin(r"(Frühstück|Mittagessen|Abendessen)", header)
            col_config.display_header = replace(header, r"\s*\(.*?\)" => "")
            col_config.rotate_header = true
            col_config.center_content = true
        elseif occursin(r"(Lebensmittel|Allergie)", header)
            col_config.display_header = "Allergien"
        elseif occursin(r"^Sonstiges", header)
            col_config.display_header = "Sonstiges"
        end

        # Detect boolean fields and apply coloring
        if length(reg_rows) > 0
            sample_values = [row[idx] for row in reg_rows[1:min(10, length(reg_rows))] if idx <= length(row)]
            is_boolean = all(v -> v in ["", "Ja", "Nein", "Yes", "No"], sample_values)

            if is_boolean
                col_config.center_content = true
                col_config.rotate_header = true
                col_config.width = 4.0
                push!(col_config.format_rules, Dict{Symbol, Any}(
                    :values => ["Ja", "Yes"],
                    :bg_color => 0xC6EFCE
                ))
                push!(col_config.format_rules, Dict{Symbol, Any}(
                    :values => ["Nein", "No"],
                    :bg_color => 0xFFC7CE
                ))
            end
        end

        push!(reg_column_configs, col_config)
    end

    # Build payment sheet with smart formatting
    pay_rows_to_show = filter_payments(payment_data, PaymentFilter())
    pay_headers = ["Reference", "Name", "Email", "Cost", "Paid", "Subsidy", "Remaining", "Status"]
    pay_rows = Vector{Vector{Any}}(undef, length(pay_rows_to_show))
    for (idx, row) in enumerate(pay_rows_to_show)
        cost_str = row.cost === nothing ? "" : @sprintf("%.2f", row.cost)
        pay_rows[idx] = [
            row.reference,
            row.name,
            row.email,
            cost_str,
            @sprintf("%.2f", row.paid),
            @sprintf("%.2f", row.subsidy),
            row.status == STATUS_NO_CONFIG ? "" : @sprintf("%.2f", row.remaining),
            status_display(row.status)
        ]
    end
    pay_data = SheetData(headers=pay_headers, rows=pay_rows)
    pay_count = length(pay_rows_to_show)

    status_col = ColumnConfig(
        header="Status",
        width=12.0,
        center_content=true
    )
    push!(status_col.format_rules, Dict{Symbol, Any}(:contains => "✓ Paid", :bg_color => 0xC6EFCE))
    push!(status_col.format_rules, Dict{Symbol, Any}(:contains => "Unpaid", :bg_color => 0xFFC7CE))
    push!(status_col.format_rules, Dict{Symbol, Any}(:contains => "Over", :bg_color => 0xFFEB9C))

    # Get matched transfers data
    transfers_data, transfers_count = get_matched_transfers_data(db, event_id)

    # Format match type column with colors
    match_type_col = ColumnConfig(
        header="Match Type",
        center_content=true,
        width=12.0
    )
    push!(match_type_col.format_rules, Dict{Symbol, Any}(:value => "auto", :bg_color => 0xC6EFCE))  # Green for auto
    push!(match_type_col.format_rules, Dict{Symbol, Any}(:value => "manual", :bg_color => 0xFFEB9C))  # Yellow for manual
    push!(match_type_col.format_rules, Dict{Symbol, Any}(:contains => "uncertain", :bg_color => 0xFFC7CE))  # Red for uncertain

    # Create multi-sheet workbook
    sheets = SheetConfig[
        SheetConfig(
            name="Registration",
            title="Registration Details",
            subtitle="$subtitle | Generated: {date}",
            source=SheetData(headers=detail_table.columns, rows=reg_rows),
            columns=reg_column_configs
        ),
        SheetConfig(
            name="Payment",
            title="Payment Status",
            subtitle="$subtitle | Generated: {date}",
            source=pay_data,
            columns=[status_col]
        ),
        SheetConfig(
            name="Matched Transfers",
            title="Matched Bank Transfers",
            subtitle="$subtitle | Transfers: $transfers_count | Generated: {date}",
            source=transfers_data,
            columns=[match_type_col]
        )
    ]

    export_tables(ExportConfig(output_path=output_path, sheets=sheets))
    @info "✓ Combined XLSX exported" output_path=output_path registration_rows=length(reg_rows) payment_rows=pay_count transfers=transfers_count
    return 0
end

"""
Export combined multi-sheet XLSX workbook. Caller must open db; run_cli opens it before calling.
"""
function cmd_export_combined(db::DuckDB.DB,
    event_id::Union{String,Nothing}=nothing,
    actual_output::Union{String,Nothing}=nothing;
    events_dir::String="events",
    upload::Bool=false,
    credentials_path::String="credentials.toml",
    db_path::String="events.duckdb")
    local_event_id = event_id
    if local_event_id === nothing
        local_event_id = get_most_recent_event(db)
        if local_event_id === nothing
            @error "No events with registrations found"
            return 1
        end
        @info "Using most recent event" event_id=local_event_id
    end

    cfg = Config.load_event_config(local_event_id, events_dir)
    output_path = if actual_output !== nothing
        actual_output
    elseif cfg !== nothing && cfg.export_combined_config !== nothing && cfg.export_combined_config.filename !== nothing
        cfg.export_combined_config.filename
    else
        "combined_export_$(local_event_id).xlsx"
    end

    @info "Exporting combined workbook" event_id=local_event_id output_path=output_path
    result = export_combined_xlsx(db, local_event_id, output_path; events_dir)

    if result == 0
        @info "✓ Combined export complete" output_path=output_path
        if upload
            ctx = load_app_config(; db_path, credentials_path)
            upload_export_to_webdav(ctx, output_path)
        end
    end
    return result
end

function export_registration_detail_xlsx(table::RegistrationDetailTable, output_path::String)
    rows = [[format_detail_csv_value(cell) for cell in row] for row in table.rows]
    subtitle = table.event_name === nothing ? table.event_id : "$(table.event_id) - $(table.event_name)"

    # Build column configurations with smart formatting
    column_configs = ColumnConfig[]
    for (idx, header) in enumerate(table.columns)
        col_config = ColumnConfig(index=idx)

        # Apply smart display headers for common long field names
        if occursin("Übernachtung", header)
            # Shorten overnight stay fields
            col_config.display_header = replace(header, r"Übernachtung\s+" => "", r"\s*\(.*?\)" => "")
            col_config.rotate_header = true
            col_config.center_content = true
        elseif occursin(r"(Frühstück|Mittagessen|Abendessen)", header)
            # Shorten meal fields
            col_config.display_header = replace(header, r"\s*\(.*?\)" => "")
            col_config.rotate_header = true
            col_config.center_content = true
        elseif occursin(r"(Lebensmittel|Allergie)", header)
            # Keep allergy fields readable
            col_config.display_header = "Allergien"
        elseif occursin(r"^Sonstiges", header)
            col_config.display_header = "Sonstiges"
        end

        # Detect boolean fields and apply coloring
        if length(rows) > 0
            sample_values = [row[idx] for row in rows[1:min(10, length(rows))] if idx <= length(row)]
            is_boolean = all(v -> v in ["", "Ja", "Nein", "Yes", "No"], sample_values)

            if is_boolean
                col_config.center_content = true
                col_config.rotate_header = true
                col_config.width = 4.0
                # Add green/red coloring for Ja/Nein
                push!(col_config.format_rules, Dict{Symbol, Any}(
                    :values => ["Ja", "Yes"],
                    :bg_color => 0xC6EFCE  # Light green
                ))
                push!(col_config.format_rules, Dict{Symbol, Any}(
                    :values => ["Nein", "No"],
                    :bg_color => 0xFFC7CE  # Light red
                ))
            end
        end

        push!(column_configs, col_config)
    end

    sheet = SheetConfig(
        name="Registrations",
        title="Registration Details",
        subtitle="$subtitle | Generated: {date}",
        source=SheetData(headers=table.columns, rows=rows),
        columns=column_configs
    )

    export_tables(ExportConfig(output_path=output_path, sheets=[sheet]))
    @info "✓ Registration details exported" output_path=output_path
    return output_path
end
