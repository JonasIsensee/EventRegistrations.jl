# Export commands and helpers

"""
Export payment status report with pretty colored output.

Options:
  --format=<fmt>     Output format: terminal (default), pdf, latex, csv
  --filter=<filter>  Filter: all (default), unpaid, problems, paid, no-config
"""
function cmd_export_payment_status(event_id::Union{String,Nothing}=nothing,
                                     output_pos::Union{String,Nothing}=nothing;
                                     db_path::String="events.duckdb",
                                     format::String="terminal",
                                     filter::String="all",
                                     summary_only::Bool=false,
                                     output::Union{String,Nothing}=nothing)

    # Allow output to be passed as positional or keyword argument
    actual_output = output_pos !== nothing ? output_pos : output

    return require_database(db_path) do db
        # Default to most recent event if not specified
        local_event_id = event_id
        if local_event_id === nothing
            local_event_id = get_most_recent_event(db)
            if local_event_id === nothing
                @error "No events with registrations found"
                return 1
            end
            @info "Using most recent event" event_id=local_event_id
        end

        # Build filter from option
        payment_filter = if filter == "unpaid"
            PaymentFilter(unpaid_only=true)
        elseif filter == "problems"
            PaymentFilter(problems_only=true)
        elseif filter == "paid"
            PaymentFilter(paid_only=true)
        elseif filter == "no-config"
            PaymentFilter(no_config_only=true)
        else
            PaymentFilter()  # all
        end

        # Get payment data from database
        table_data = get_payment_table_data(db, local_event_id)

        if table_data.total_registrations == 0
            @info "No registrations found for event" event_id=local_event_id
            return 0
        end

        # Handle summary-only mode
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

        # Determine output format and destination
        output_format = format
        if actual_output !== nothing && output_format == "terminal"
            # Infer format from file extension
            ext = lowercase(splitext(actual_output)[2])
            if ext == ".pdf"
                output_format = "pdf"
            elseif ext == ".tex"
                output_format = "latex"
            elseif ext == ".csv"
                output_format = "csv"
            end
        end

        if output_format == "terminal" || (actual_output === nothing && output_format == "terminal")
            print_payment_table(table_data; filter=payment_filter)
        elseif output_format == "pdf"
            output_path = actual_output === nothing ? "payment_status_$(local_event_id).pdf" : actual_output
            @info "Generating PDF" output_path=output_path
            export_payment_pdf(table_data, output_path; filter=payment_filter)
            @info "✓ PDF exported" output_path=output_path
        elseif output_format == "latex"
            output_path = actual_output === nothing ? "payment_status_$(local_event_id).tex" : actual_output
            @info "Generating LaTeX" output_path=output_path
            latex_content = generate_latex_document(table_data; filter=payment_filter)
            open(output_path, "w") do f
                write(f, latex_content)
            end
            @info "✓ LaTeX exported" output_path=output_path
        elseif output_format == "csv"
            output_path = actual_output === nothing ? "payment_status_$(local_event_id).csv" : actual_output
            @info "Exporting CSV" output_path=output_path
            export_payment_csv(table_data, output_path; filter=payment_filter)
            @info "✓ CSV exported" output_path=output_path
        else
            @error "Unknown format" format=output_format supported=["terminal", "pdf", "latex", "csv"]
            return 1
        end
        return 0
    end
end

"""
Export full registration data.
"""
function cmd_export_registrations(event_id::Union{String,Nothing}=nothing,
                                   output_pos::Union{String,Nothing}=nothing;
                                   db_path::String="events.duckdb",
                                   format::String="terminal",
                                   filter::String="all",
                                   output::Union{String,Nothing}=nothing,
                                   details::Bool=false,
                                   events_dir::String="events")

    # Allow output to be passed as positional or keyword argument
    actual_output = output_pos !== nothing ? output_pos : output

    return require_database(db_path) do db
        # Default to most recent event if not specified
        local_event_id = event_id
        if local_event_id === nothing
            local_event_id = get_most_recent_event(db)
            if local_event_id === nothing
                @error "No events with registrations found"
                return 1
            end
            @info "Using most recent event" event_id=local_event_id
        end

        # Build filter from option (summary view only)
        reg_filter = if filter == "unpaid"
            RegistrationFilter(unpaid_only=true)
        elseif filter == "problems"
            RegistrationFilter(problems_only=true)
        elseif filter == "paid"
            RegistrationFilter(paid_only=true)
        else
            RegistrationFilter()  # all
        end

        # Determine output format and destination
        output_format = format
        if actual_output !== nothing && output_format == "terminal"
            ext = lowercase(splitext(actual_output)[2])
            if ext == ".pdf"
                output_format = "pdf"
            elseif ext == ".tex"
                output_format = "latex"
            elseif ext == ".csv"
                output_format = "csv"
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
            else
                @error "Unsupported format for details view" format=output_format supported=["terminal", "csv"]
                return 1
            end
            return 0
        end

        # Summary view
        table_data = get_registration_table_data(db, local_event_id)

        if table_data.total_registrations == 0
            @info "No registrations found for event" event_id=local_event_id
            return 0
        end

        if output_format == "terminal" || (actual_output === nothing && output_format == "terminal")
            print_registration_table(table_data; filter=reg_filter)
        elseif output_format == "pdf"
            output_path = actual_output === nothing ? "registrations_$(local_event_id).pdf" : actual_output
            @info "Generating PDF" output_path=output_path
            export_registration_pdf(table_data, output_path; filter=reg_filter)
            @info "✓ PDF exported" output_path=output_path
        elseif output_format == "latex"
            output_path = actual_output === nothing ? "registrations_$(local_event_id).tex" : actual_output
            @info "Generating LaTeX" output_path=output_path
            latex_content = generate_registration_latex_document(table_data; filter=reg_filter)
            open(output_path, "w") do f
                write(f, latex_content)
            end
            @info "✓ LaTeX exported" output_path=output_path
        elseif output_format == "csv"
            output_path = actual_output === nothing ? "registrations_$(local_event_id).csv" : actual_output
            @info "Exporting CSV" output_path=output_path
            export_registration_csv(table_data, output_path; filter=reg_filter)
            @info "✓ CSV exported" output_path=output_path
        else
            @error "Unknown format" format=output_format supported=["terminal", "pdf", "latex", "csv"]
            return 1
        end
        return 0
    end
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
        maximum_number_of_rows = -1
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
