PrettyOutput module for EventRegistrations

Provides beautiful colored table output for payment status and registration data.
Supports terminal output with colors and PDF export via LaTeX.
"""
module PrettyOutput

using Crayons: Crayons, @crayon_str
using DBInterface: DBInterface
using Dates: Dates, Date, DateTime
using DuckDB: DuckDB
using JSON: JSON
using PrettyTables: PrettyTables, LatexCell, LatexHighlighter, TextHighlighter,
                    pretty_table
using TableExport: ExportConfig, SheetConfig, SheetData, export_tables, ColumnConfig
using Printf: Printf, @sprintf

# For PDF export
import tectonic_jll

export PaymentStatus, PaymentTableData, PaymentRow
export STATUS_PAID, STATUS_OVERPAID, STATUS_PARTIAL, STATUS_UNPAID, STATUS_NO_CONFIG
export status_display
export get_payment_table_data, print_payment_table, export_payment_pdf, export_payment_csv, export_payment_xlsx
export PaymentFilter, filter_payments
export generate_latex_document
export RegistrationTableData, RegistrationRow, RegistrationFilter
export get_registration_table_data, print_registration_table
export export_registration_pdf, export_registration_csv, export_registration_xlsx
export generate_registration_latex_document, print_summary

# =============================================================================
# DATA STRUCTURES
# =============================================================================

"""
Payment status enum for categorizing registrations.
"""
@enum PaymentStatus begin
    STATUS_PAID        # Fully paid (payments + subsidies >= cost)
    STATUS_OVERPAID    # Paid more than required
    STATUS_PARTIAL     # Some payment received but not complete
    STATUS_UNPAID      # No payment received
    STATUS_NO_CONFIG   # Cost not yet calculated (no config)
end

"""
Single row of payment table data.
"""
struct PaymentRow
    reference::String
    name::String
    email::String
    cost::Union{Float64,Nothing}
    paid::Float64
    subsidy::Float64
    remaining::Float64
    status::PaymentStatus
end

"""
Complete payment table with summary statistics.
"""
struct PaymentTableData
    event_id::String
    event_name::Union{String,Nothing}
    rows::Vector{PaymentRow}
    total_registrations::Int
    total_cost::Float64
    total_paid::Float64
    total_subsidies::Float64
    total_remaining::Float64
    count_paid::Int
    count_overpaid::Int
    count_partial::Int
    count_unpaid::Int
    count_no_config::Int
end

"""
Filter options for payment table.
"""
struct PaymentFilter
    unpaid_only::Bool
    problems_only::Bool      # Unpaid, partial, or overpaid
    paid_only::Bool
    no_config_only::Bool
    min_remaining::Union{Float64,Nothing}
    max_remaining::Union{Float64,Nothing}

    function PaymentFilter(;
        unpaid_only::Bool=false,
        problems_only::Bool=false,
        paid_only::Bool=false,
        no_config_only::Bool=false,
        min_remaining::Union{Float64,Nothing}=nothing,
        max_remaining::Union{Float64,Nothing}=nothing
    )
        new(unpaid_only, problems_only, paid_only, no_config_only, min_remaining, max_remaining)
    end
end

"""
Single row of registration table data.
"""
struct RegistrationRow
    reference::String
    first_name::String
    last_name::String
    email::String
    registration_date::Union{DateTime,Nothing}
    cost::Union{Float64,Nothing}
    paid::Float64
    subsidy::Float64
    remaining::Float64
    status::PaymentStatus
    fields::AbstractDict{String,Any}
end

"""
Complete registration table with summary statistics.
"""
struct RegistrationTableData
    event_id::String
    event_name::Union{String,Nothing}
    rows::Vector{RegistrationRow}
    total_registrations::Int
    total_cost::Float64
    total_paid::Float64
    total_subsidies::Float64
    total_remaining::Float64
    count_paid::Int
    count_partial::Int
    count_unpaid::Int
end

"""
Filter options for registration table.
"""
struct RegistrationFilter
    unpaid_only::Bool
    problems_only::Bool
    paid_only::Bool
    name_pattern::Union{String,Nothing}
    email_pattern::Union{String,Nothing}
    since::Union{Date,Nothing}

    function RegistrationFilter(;
        unpaid_only::Bool=false,
        problems_only::Bool=false,
        paid_only::Bool=false,
        name_pattern::Union{String,Nothing}=nothing,
        email_pattern::Union{String,Nothing}=nothing,
        since::Union{Date,Nothing}=nothing
    )
        new(unpaid_only, problems_only, paid_only, name_pattern, email_pattern, since)
    end
end

# =============================================================================
# DATA RETRIEVAL
# =============================================================================

"""
Get payment table data from database.
"""
function get_payment_table_data(db::DuckDB.DB, event_id::String)::PaymentTableData
    # Get event name
    event_result = DBInterface.execute(db,
        "SELECT event_name FROM events WHERE event_id = ?", [event_id])
    event_rows = collect(event_result)
    event_name = isempty(event_rows) ? nothing : event_rows[1][1]

    # Get payment data
    result = DBInterface.execute(db, """
        SELECT
            r.reference_number,
            r.first_name || ' ' || r.last_name as name,
            r.email,
            r.computed_cost,
            COALESCE(payments.total, 0) as paid,
            COALESCE(subsidies.total, 0) as subsidy
        FROM registrations r
        LEFT JOIN (
            SELECT pm.registration_id, SUM(bt.amount) as total
            FROM payment_matches pm
            JOIN bank_transfers bt ON bt.id = pm.transfer_id
            WHERE pm.registration_id IS NOT NULL
            GROUP BY pm.registration_id
        ) payments ON payments.registration_id = r.id
        LEFT JOIN (
            SELECT registration_id, SUM(amount) as total
            FROM subsidies
            GROUP BY registration_id
        ) subsidies ON subsidies.registration_id = r.id
        WHERE r.event_id = ? AND r.deleted_at IS NULL
        ORDER BY r.last_name, r.first_name
    """, [event_id])

    rows = PaymentRow[]
    total_cost = 0.0
    total_paid = 0.0
    total_subsidies = 0.0
    total_remaining = 0.0
    count_paid = 0
    count_overpaid = 0
    count_partial = 0
    count_unpaid = 0
    count_no_config = 0

    for row in collect(result)
        ref, name, email, cost, paid, subsidy = row

        # Calculate remaining and status
        if cost === nothing || cost === missing
            remaining = 0.0
            status = STATUS_NO_CONFIG
            count_no_config += 1
        else
            cost_val = Float64(cost)
            paid_val = Float64(something(paid, 0))
            subsidy_val = Float64(something(subsidy, 0))
            credits = paid_val + subsidy_val
            remaining = cost_val - credits

            total_cost += cost_val
            total_paid += paid_val
            total_subsidies += subsidy_val

            if remaining <= 0 && credits > cost_val
                status = STATUS_OVERPAID
                count_overpaid += 1
                total_remaining += remaining  # negative for overpaid
            elseif remaining <= 0
                status = STATUS_PAID
                count_paid += 1
            elseif credits > 0
                status = STATUS_PARTIAL
                count_partial += 1
                total_remaining += remaining
            else
                status = STATUS_UNPAID
                count_unpaid += 1
                total_remaining += remaining
            end
        end

        push!(rows, PaymentRow(
            ref,
            something(name, ""),
            something(email, ""),
            (cost === nothing || cost === missing) ? nothing : Float64(cost),
            Float64(something(paid, 0)),
            Float64(something(subsidy, 0)),
            remaining,
            status
        ))
    end

    return PaymentTableData(
        event_id,
        event_name,
        rows,
        length(rows),
        total_cost,
        total_paid,
        total_subsidies,
        total_remaining,
        count_paid,
        count_overpaid,
        count_partial,
        count_unpaid,
        count_no_config
    )
end

"""
Filter payment rows based on filter criteria.
"""
function filter_payments(data::PaymentTableData, pfilter::PaymentFilter)::Vector{PaymentRow}
    rows = data.rows

    if pfilter.unpaid_only
        rows = Base.filter(r -> r.status == STATUS_UNPAID, rows)
    end

    if pfilter.problems_only
        rows = Base.filter(r -> r.status in (STATUS_UNPAID, STATUS_PARTIAL, STATUS_OVERPAID), rows)
    end

    if pfilter.paid_only
        rows = Base.filter(r -> r.status == STATUS_PAID, rows)
    end

    if pfilter.no_config_only
        rows = Base.filter(r -> r.status == STATUS_NO_CONFIG, rows)
    end

    if pfilter.min_remaining !== nothing
        rows = Base.filter(r -> r.remaining >= pfilter.min_remaining, rows)
    end

    if pfilter.max_remaining !== nothing
        rows = Base.filter(r -> r.remaining <= pfilter.max_remaining, rows)
    end

    return collect(rows)
end

# =============================================================================
# TERMINAL OUTPUT (COLORED)
# =============================================================================

# Color definitions
const COLOR_PAID = crayon"green bold"
const COLOR_OVERPAID = crayon"yellow bold"
const COLOR_PARTIAL = crayon"yellow"
const COLOR_UNPAID = crayon"red bold"
const COLOR_NO_CONFIG = crayon"dark_gray"
const COLOR_HEADER = crayon"cyan bold"
const COLOR_MONEY = crayon"white"
const COLOR_NEGATIVE = crayon"red"
const COLOR_POSITIVE = crayon"green"

"""
Get status display string with symbol.
"""
function status_display(status::PaymentStatus)
    if status == STATUS_PAID
        return "✓ Paid"
    elseif status == STATUS_OVERPAID
        return "⚠ Over"
    elseif status == STATUS_PARTIAL
        return "◐ Partial"
    elseif status == STATUS_UNPAID
        return "✗ Unpaid"
    else
        return "? No Config"
    end
end

"""
Get crayon for status.
"""
function status_crayon(status::PaymentStatus)
    if status == STATUS_PAID
        return COLOR_PAID
    elseif status == STATUS_OVERPAID
        return COLOR_OVERPAID
    elseif status == STATUS_PARTIAL
        return COLOR_PARTIAL
    elseif status == STATUS_UNPAID
        return COLOR_UNPAID
    else
        return COLOR_NO_CONFIG
    end
end

"""
Format money value for display.
"""
function format_money(value::Float64; show_sign::Bool=false)
    if show_sign && value > 0
        return @sprintf("+%.2f €", value)
    elseif show_sign && value < 0
        return @sprintf("%.2f €", value)
    else
        return @sprintf("%.2f €", value)
    end
end

function format_money(value::Nothing; kwargs...)
    return "—"
end

"""
Print a beautiful colored payment table to the terminal.
"""
function print_payment_table(data::PaymentTableData;
                             filter::PaymentFilter=PaymentFilter(),
                             io::IO=stdout)
    rows_to_show = filter_payments(data, filter)

    if isempty(rows_to_show)
        println(io, "No registrations match the filter criteria.")
        return
    end

    # Build table data
    table_data = Matrix{Any}(undef, length(rows_to_show), 7)

    for (i, row) in enumerate(rows_to_show)
        table_data[i, 1] = row.reference
        table_data[i, 2] = row.name
        table_data[i, 3] = format_money(row.cost)
        table_data[i, 4] = format_money(row.paid)
        table_data[i, 5] = row.subsidy > 0 ? format_money(row.subsidy) : "—"
        table_data[i, 6] = row.status == STATUS_NO_CONFIG ? "—" : format_money(row.remaining)
        table_data[i, 7] = status_display(row.status)
    end

    # Create highlighters for colored status column
    hl_paid = TextHighlighter(
        (tbl, i, j) -> j == 7 && rows_to_show[i].status == STATUS_PAID,
        COLOR_PAID
    )
    hl_overpaid = TextHighlighter(
        (tbl, i, j) -> j == 7 && rows_to_show[i].status == STATUS_OVERPAID,
        COLOR_OVERPAID
    )
    hl_partial = TextHighlighter(
        (tbl, i, j) -> j == 7 && rows_to_show[i].status == STATUS_PARTIAL,
        COLOR_PARTIAL
    )
    hl_unpaid = TextHighlighter(
        (tbl, i, j) -> j == 7 && rows_to_show[i].status == STATUS_UNPAID,
        COLOR_UNPAID
    )
    hl_noconfig = TextHighlighter(
        (tbl, i, j) -> j == 7 && rows_to_show[i].status == STATUS_NO_CONFIG,
        COLOR_NO_CONFIG
    )

    # Highlight remaining column based on value
    hl_remaining_negative = TextHighlighter(
        (tbl, i, j) -> j == 6 && rows_to_show[i].remaining < 0,
        COLOR_NEGATIVE
    )
    hl_remaining_positive = TextHighlighter(
        (tbl, i, j) -> j == 6 && rows_to_show[i].remaining > 0 && rows_to_show[i].status != STATUS_NO_CONFIG,
        COLOR_UNPAID
    )

    # Print title
    title_str = "Payment Status: $(data.event_id)"
    if data.event_name !== nothing
        title_str *= " - $(data.event_name)"
    end

    println(io)
    println(io, COLOR_HEADER(title_str))
    println(io, COLOR_HEADER("=" ^ length(title_str)))
    println(io)

    # Print table with PrettyTables 3.x API
    pretty_table(io, table_data;
        column_labels = ["Reference", "Name", "Cost", "Paid", "Subsidy", "Remaining", "Status"],
        alignment = [:l, :l, :r, :r, :r, :r, :l],
        highlighters = [hl_paid, hl_overpaid, hl_partial, hl_unpaid, hl_noconfig,
                       hl_remaining_negative, hl_remaining_positive],
        maximum_number_of_columns = -1,
        maximum_number_of_rows = -1,
        vertical_crop_mode = :none
    )

    # Print summary
    println(io)
    print_summary(data; io=io)
end

"""
Print summary statistics.
"""
function print_summary(data::PaymentTableData; io::IO=stdout)
    println(io, COLOR_HEADER("Summary"))
    println(io, "─" ^ 60)

    # Payment counts
    print(io, "Registrations: $(data.total_registrations)  │  ")
    print(io, COLOR_PAID("✓ Paid: $(data.count_paid)"))
    print(io, "  ")
    if data.count_partial > 0
        print(io, COLOR_PARTIAL("◐ Partial: $(data.count_partial)"))
        print(io, "  ")
    end
    if data.count_unpaid > 0
        print(io, COLOR_UNPAID("✗ Unpaid: $(data.count_unpaid)"))
    end
    println(io)

    # Financial summary
    println(io)
    println(io, "Financial Summary:")
    println(io, "  Total Expected:    $(format_money(data.total_cost))")
    println(io, "  Total Received:    $(format_money(data.total_paid))")
    if data.total_subsidies > 0
        println(io, "  Total Subsidies:   $(format_money(data.total_subsidies))")
    end

    remaining = data.total_cost - data.total_paid - data.total_subsidies
    if remaining > 0
        println(io, COLOR_UNPAID("  Outstanding:       $(format_money(remaining))"))
    else
        println(io, COLOR_PAID("  Outstanding:       $(format_money(0.0))"))
    end
    println(io)
end

# =============================================================================
# REGISTRATION TABLE DATA
# =============================================================================

"""
Get registration table data from database.
"""
function get_registration_table_data(db::DuckDB.DB, event_id::String)::RegistrationTableData
    # Get event name
    event_result = DBInterface.execute(db,
        "SELECT event_name FROM events WHERE event_id = ?", [event_id])
    event_rows = collect(event_result)
    event_name = isempty(event_rows) ? nothing : event_rows[1][1]

    # Get registration data with payment info
    result = DBInterface.execute(db, """
        SELECT
            r.reference_number,
            r.first_name,
            r.last_name,
            r.email,
            r.registration_date,
            r.computed_cost,
            r.fields,
            COALESCE(payments.total, 0) as paid,
            COALESCE(subsidies.total, 0) as subsidy
        FROM registrations r
        LEFT JOIN (
            SELECT pm.registration_id, SUM(bt.amount) as total
            FROM payment_matches pm
            JOIN bank_transfers bt ON bt.id = pm.transfer_id
            WHERE pm.registration_id IS NOT NULL
            GROUP BY pm.registration_id
        ) payments ON payments.registration_id = r.id
        LEFT JOIN (
            SELECT registration_id, SUM(amount) as total
            FROM subsidies
            GROUP BY registration_id
        ) subsidies ON subsidies.registration_id = r.id
        WHERE r.event_id = ? AND r.deleted_at IS NULL
        ORDER BY r.last_name, r.first_name
    """, [event_id])

    rows = RegistrationRow[]
    total_cost = 0.0
    total_paid = 0.0
    total_subsidies = 0.0
    total_remaining = 0.0
    count_paid = 0
    count_partial = 0
    count_unpaid = 0

    for row in collect(result)
        ref, first_name, last_name, email, reg_date, cost, fields_json, paid, subsidy = row

        # Parse fields JSON
        fields = try
            if fields_json !== nothing
                JSON.parse(fields_json)
            else
                Dict{String,Any}()
            end
        catch
            Dict{String,Any}()
        end

        # Calculate remaining and status
        if cost === nothing || cost === missing
            remaining = 0.0
            status = STATUS_NO_CONFIG
        else
            cost_val = Float64(cost)
            paid_val = Float64(something(paid, 0))
            subsidy_val = Float64(something(subsidy, 0))
            credits = paid_val + subsidy_val
            remaining = cost_val - credits

            total_cost += cost_val
            total_paid += paid_val
            total_subsidies += subsidy_val

            if remaining <= 0
                status = STATUS_PAID
                count_paid += 1
            elseif credits > 0
                status = STATUS_PARTIAL
                count_partial += 1
                total_remaining += remaining
            else
                status = STATUS_UNPAID
                count_unpaid += 1
                total_remaining += remaining
            end
        end

        push!(rows, RegistrationRow(
            ref,
            something(first_name, ""),
            something(last_name, ""),
            something(email, ""),
            reg_date,
            (cost === nothing || cost === missing) ? nothing : Float64(cost),
            Float64(something(paid, 0)),
            Float64(something(subsidy, 0)),
            remaining,
            status,
            fields
        ))
    end

    return RegistrationTableData(
        event_id,
        event_name,
        rows,
        length(rows),
        total_cost,
        total_paid,
        total_subsidies,
        total_remaining,
        count_paid,
        count_partial,
        count_unpaid
    )
end

"""
Filter registration rows based on filter criteria.
"""
function filter_registrations(data::RegistrationTableData, rfilter::RegistrationFilter)::Vector{RegistrationRow}
    rows = data.rows

    if rfilter.unpaid_only
        rows = Base.filter(r -> r.status == STATUS_UNPAID, rows)
    end

    if rfilter.problems_only
        rows = Base.filter(r -> r.status in (STATUS_UNPAID, STATUS_PARTIAL), rows)
    end

    if rfilter.paid_only
        rows = Base.filter(r -> r.status == STATUS_PAID, rows)
    end

    if rfilter.name_pattern !== nothing
        pattern = Regex(rfilter.name_pattern, "i")
        rows = Base.filter(r -> occursin(pattern, r.first_name * " " * r.last_name), rows)
    end

    if rfilter.email_pattern !== nothing
        pattern = Regex(rfilter.email_pattern, "i")
        rows = Base.filter(r -> occursin(pattern, r.email), rows)
    end

    if rfilter.since !== nothing
        rows = Base.filter(r -> r.registration_date !== nothing && Date(r.registration_date) >= rfilter.since, rows)
    end

    return collect(rows)
end

"""
Print a beautiful colored registration table to the terminal.
"""
function print_registration_table(data::RegistrationTableData;
                                   filter::RegistrationFilter=RegistrationFilter(),
                                   io::IO=stdout)
    rows_to_show = filter_registrations(data, filter)

    if isempty(rows_to_show)
        println(io, "No registrations match the filter criteria.")
        return
    end

    # Build table data
    table_data = Matrix{Any}(undef, length(rows_to_show), 7)

    for (i, row) in enumerate(rows_to_show)
        table_data[i, 1] = row.reference
        table_data[i, 2] = row.last_name * ", " * row.first_name
        table_data[i, 3] = length(row.email) > 30 ? row.email[1:27] * "..." : row.email
        table_data[i, 4] = row.registration_date !== nothing ? Dates.format(row.registration_date, "yyyy-mm-dd") : "—"
        table_data[i, 5] = format_money(row.cost)
        table_data[i, 6] = row.status == STATUS_NO_CONFIG ? "—" : format_money(row.remaining)
        table_data[i, 7] = status_display(row.status)
    end

    # Create highlighters for colored status column
    hl_paid = TextHighlighter(
        (tbl, i, j) -> j == 7 && rows_to_show[i].status == STATUS_PAID,
        COLOR_PAID
    )
    hl_partial = TextHighlighter(
        (tbl, i, j) -> j == 7 && rows_to_show[i].status == STATUS_PARTIAL,
        COLOR_PARTIAL
    )
    hl_unpaid = TextHighlighter(
        (tbl, i, j) -> j == 7 && rows_to_show[i].status == STATUS_UNPAID,
        COLOR_UNPAID
    )
    hl_noconfig = TextHighlighter(
        (tbl, i, j) -> j == 7 && rows_to_show[i].status == STATUS_NO_CONFIG,
        COLOR_NO_CONFIG
    )

    # Highlight remaining column based on value
    hl_remaining_positive = TextHighlighter(
        (tbl, i, j) -> j == 6 && rows_to_show[i].remaining > 0 && rows_to_show[i].status != STATUS_NO_CONFIG,
        COLOR_UNPAID
    )

    # Print title
    title_str = "Registrations: $(data.event_id)"
    if data.event_name !== nothing
        title_str *= " - $(data.event_name)"
    end

    println(io)
    println(io, COLOR_HEADER(title_str))
    println(io, COLOR_HEADER("=" ^ length(title_str)))
    println(io)

    # Print table with PrettyTables
    pretty_table(io, table_data;
        column_labels = ["Reference", "Name", "Email", "Registered", "Cost", "Remaining", "Status"],
        alignment = [:l, :l, :l, :l, :r, :r, :l],
        highlighters = [hl_paid, hl_partial, hl_unpaid, hl_noconfig, hl_remaining_positive],
        maximum_number_of_columns = -1,
        maximum_number_of_rows = -1,
        vertical_crop_mode = :none
    )

    # Print summary
    println(io)
    print_registration_summary(data; io=io)
end

"""
Print registration summary statistics.
"""
function print_registration_summary(data::RegistrationTableData; io::IO=stdout)
    println(io, COLOR_HEADER("Summary"))
    println(io, "─" ^ 60)

    # Registration counts
    print(io, "Registrations: $(data.total_registrations)  │  ")
    print(io, COLOR_PAID("✓ Paid: $(data.count_paid)"))
    print(io, "  ")
    if data.count_partial > 0
        print(io, COLOR_PARTIAL("◐ Partial: $(data.count_partial)"))
        print(io, "  ")
    end
    if data.count_unpaid > 0
        print(io, COLOR_UNPAID("✗ Unpaid: $(data.count_unpaid)"))
    end
    println(io)

    # Financial summary
    println(io)
    println(io, "Financial Summary:")
    println(io, "  Total Expected:    $(format_money(data.total_cost))")
    println(io, "  Total Received:    $(format_money(data.total_paid))")
    if data.total_subsidies > 0
        println(io, "  Total Subsidies:   $(format_money(data.total_subsidies))")
    end

    if data.total_remaining > 0
        println(io, COLOR_UNPAID("  Outstanding:       $(format_money(data.total_remaining))"))
    else
        println(io, COLOR_PAID("  Outstanding:       $(format_money(0.0))"))
    end
    println(io)
end

"""
Generate LaTeX document for registration report.
"""
function generate_registration_latex_document(data::RegistrationTableData;
                                               filter::RegistrationFilter=RegistrationFilter())::String
    rows_to_show = filter_registrations(data, filter)

    title = "Registration Report"
    subtitle = data.event_name !== nothing ? data.event_name : data.event_id
    date_str = Dates.format(Dates.now(), "d. U yyyy, HH:MM")

    if isempty(rows_to_show)
        table_latex = "\\textit{No registrations match the filter criteria.}"
    else
        # Build table data
        table_data = Matrix{Any}(undef, length(rows_to_show), 6)

        for (i, row) in enumerate(rows_to_show)
            table_data[i, 1] = escape_latex(row.reference)
            table_data[i, 2] = escape_latex(row.last_name * ", " * row.first_name)
            table_data[i, 3] = escape_latex(row.email)
            table_data[i, 4] = row.registration_date !== nothing ? Dates.format(row.registration_date, "yyyy-mm-dd") : "—"
            table_data[i, 5] = row.cost === nothing ? "—" : @sprintf("%.2f", row.cost)
            table_data[i, 6] = LatexCell(latex_status(row.status))
        end

        # Create highlighters for LaTeX colors
        hl_paid = LatexHighlighter(
            (tbl, i, j) -> j == 6 && rows_to_show[i].status == STATUS_PAID,
            ["color{PaidGreen}", "bfseries"]
        )
        hl_partial = LatexHighlighter(
            (tbl, i, j) -> j == 6 && rows_to_show[i].status == STATUS_PARTIAL,
            ["color{WarningOrange}"]
        )
        hl_unpaid = LatexHighlighter(
            (tbl, i, j) -> j == 6 && rows_to_show[i].status == STATUS_UNPAID,
            ["color{UnpaidRed}", "bfseries"]
        )

        col_labels = [
            "Reference",
            "Name",
            "Email",
            "Registered",
            LatexCell(raw"Cost (\euro)"),
            "Status"
        ]

        io = IOBuffer()
        pretty_table(io, table_data;
            backend = :latex,
            column_labels = col_labels,
            alignment = [:l, :l, :l, :l, :r, :l],
            highlighters = [hl_paid, hl_partial, hl_unpaid]
        )
        table_latex = String(take!(io))
    end

    # Summary data
    summary = """
    \\begin{tabular}{lr}
    \\textbf{Total Registrations} & $(data.total_registrations) \\\\
    \\textcolor{PaidGreen}{\\textbf{Fully Paid}} & $(data.count_paid) \\\\
    \\textcolor{WarningOrange}{Partial Payment} & $(data.count_partial) \\\\
    \\textcolor{UnpaidRed}{\\textbf{Unpaid}} & $(data.count_unpaid) \\\\
    \\midrule
    \\textbf{Total Expected} & $(format_money_plain(data.total_cost)) \\\\
    \\textbf{Total Received} & $(format_money_plain(data.total_paid)) \\\\
    \\textbf{Outstanding} & $(format_money_plain(data.total_remaining)) \\\\
    \\end{tabular}
    """

    doc = """
    \\documentclass[a4paper,11pt]{article}
    \\usepackage[utf8]{inputenc}
    \\usepackage[T1]{fontenc}
    \\usepackage[margin=1.5cm,landscape]{geometry}
    \\usepackage{booktabs}
    \\usepackage{xcolor}
    \\usepackage{longtable}
    \\usepackage{array}
    \\usepackage{amssymb}
    \\usepackage{eurosym}
    \\usepackage{textcomp}

    % Define custom colors
    \\definecolor{PaidGreen}{RGB}{34, 139, 34}
    \\definecolor{UnpaidRed}{RGB}{178, 34, 34}
    \\definecolor{WarningOrange}{RGB}{255, 140, 0}

    \\title{$title}
    \\author{$(escape_latex(subtitle))}
    \\date{Generated: $date_str}

    \\begin{document}

    \\maketitle

    \\section*{Summary}
    $summary

    \\section*{Registrations}
    $table_latex

    \\end{document}
    """

    return doc
end

"""
Export registration table to PDF.
"""
function export_registration_pdf(data::RegistrationTableData, output_path::String;
                                  filter::RegistrationFilter=RegistrationFilter())
    latex_doc = generate_registration_latex_document(data; filter=filter)

    mktempdir() do dir
        texfile = joinpath(dir, "registration_report.tex")

        # Write LaTeX file
        write(texfile, latex_doc)

        # Compile with tectonic
        tectonic_jll.tectonic() do bin
            run(`$bin --chatter=minimal $texfile`)
        end

        # Copy PDF to output
        pdffile = joinpath(dir, "registration_report.pdf")
        if isfile(pdffile)
            cp(pdffile, output_path; force=true)
            @info "PDF exported" path=output_path
        else
            error("PDF generation failed")
        end
    end

    return output_path
end

"""
Export registration table to CSV.
"""
function export_registration_csv(data::RegistrationTableData, output_path::String;
                                  filter::RegistrationFilter=RegistrationFilter())
    rows_to_show = filter_registrations(data, filter)

    open(output_path, "w") do io
        # Header
        println(io, "Reference,FirstName,LastName,Email,RegistrationDate,Cost,Paid,Subsidy,Remaining,Status")

        for row in rows_to_show
            cost_str = row.cost === nothing ? "" : @sprintf("%.2f", row.cost)
            date_str = row.registration_date !== nothing ? Dates.format(row.registration_date, "yyyy-mm-dd") : ""
            println(io, join([
                "\"$(row.reference)\"",
                "\"$(row.first_name)\"",
                "\"$(row.last_name)\"",
                "\"$(row.email)\"",
                "\"$date_str\"",
                cost_str,
                @sprintf("%.2f", row.paid),
                @sprintf("%.2f", row.subsidy),
                @sprintf("%.2f", row.remaining),
                "\"$(status_display(row.status))\""
            ], ","))
        end
    end

    @info "CSV exported" path=output_path rows=length(rows_to_show)
    return output_path
end

# =============================================================================
# PDF EXPORT (via LaTeX)
# =============================================================================

"""
Generate LaTeX code for payment table.
"""
function generate_latex_table(data::PaymentTableData;
                              filter::PaymentFilter=PaymentFilter())::String
    rows_to_show = filter_payments(data, filter)

    if isempty(rows_to_show)
        return "\\textit{No registrations match the filter criteria.}"
    end

    # Build table data matrix - use LatexCell to prevent escaping of LaTeX commands
    table_data = Matrix{Any}(undef, length(rows_to_show), 7)

    for (i, row) in enumerate(rows_to_show)
        table_data[i, 1] = escape_latex(row.reference)
        table_data[i, 2] = escape_latex(row.name)
        table_data[i, 3] = row.cost === nothing ? "—" : @sprintf("%.2f", row.cost)
        table_data[i, 4] = @sprintf("%.2f", row.paid)
        table_data[i, 5] = row.subsidy > 0 ? @sprintf("%.2f", row.subsidy) : "—"
        table_data[i, 6] = row.status == STATUS_NO_CONFIG ? "—" : @sprintf("%.2f", row.remaining)
        # Use LatexCell to prevent escaping of LaTeX commands in status
        table_data[i, 7] = LatexCell(latex_status(row.status))
    end

    # Create highlighters for LaTeX colors
    hl_paid = LatexHighlighter(
        (tbl, i, j) -> j == 7 && rows_to_show[i].status == STATUS_PAID,
        ["color{PaidGreen}", "bfseries"]
    )
    hl_overpaid = LatexHighlighter(
        (tbl, i, j) -> j == 7 && rows_to_show[i].status == STATUS_OVERPAID,
        ["color{WarningOrange}", "bfseries"]
    )
    hl_partial = LatexHighlighter(
        (tbl, i, j) -> j == 7 && rows_to_show[i].status == STATUS_PARTIAL,
        ["color{WarningOrange}"]
    )
    hl_unpaid = LatexHighlighter(
        (tbl, i, j) -> j == 7 && rows_to_show[i].status == STATUS_UNPAID,
        ["color{UnpaidRed}", "bfseries"]
    )
    hl_noconfig = LatexHighlighter(
        (tbl, i, j) -> j == 7 && rows_to_show[i].status == STATUS_NO_CONFIG,
        ["color{gray}"]
    )

    # Remaining column highlighting
    hl_remaining_bad = LatexHighlighter(
        (tbl, i, j) -> j == 6 && rows_to_show[i].remaining > 0 && rows_to_show[i].status != STATUS_NO_CONFIG,
        ["color{UnpaidRed}"]
    )
    hl_remaining_over = LatexHighlighter(
        (tbl, i, j) -> j == 6 && rows_to_show[i].remaining < 0,
        ["color{WarningOrange}"]
    )

    # Column labels with Euro symbol (use LatexCell to prevent escaping)
    col_labels = [
        "Reference",
        "Name",
        LatexCell(raw"Cost (\euro)"),
        LatexCell(raw"Paid (\euro)"),
        LatexCell(raw"Subsidy (\euro)"),
        LatexCell(raw"Remaining (\euro)"),
        "Status"
    ]

    # Generate LaTeX using PrettyTables
    io = IOBuffer()
    pretty_table(io, table_data;
        backend = :latex,
        column_labels = col_labels,
        alignment = [:l, :l, :r, :r, :r, :r, :l],
        highlighters = [hl_paid, hl_overpaid, hl_partial, hl_unpaid, hl_noconfig,
                       hl_remaining_bad, hl_remaining_over]
    )

    return String(take!(io))
end

"""
Get LaTeX status string.
"""
function latex_status(status::PaymentStatus)
    if status == STATUS_PAID
        return "\\checkmark{} Paid"
    elseif status == STATUS_OVERPAID
        return "! Over"
    elseif status == STATUS_PARTIAL
        return "\\textbullet{} Partial"
    elseif status == STATUS_UNPAID
        return "\\texttimes{} Unpaid"
    else
        return "? No Config"
    end
end

"""
Escape special LaTeX characters.
"""
function escape_latex(s::AbstractString)
    s = replace(s, "\\" => "\\textbackslash{}")
    s = replace(s, "&" => "\\&")
    s = replace(s, "%" => "\\%")
    s = replace(s, "\$" => "\\\$")
    s = replace(s, "#" => "\\#")
    s = replace(s, "_" => "\\_")
    s = replace(s, "{" => "\\{")
    s = replace(s, "}" => "\\}")
    s = replace(s, "~" => "\\textasciitilde{}")
    s = replace(s, "^" => "\\textasciicircum{}")
    return s
end

"""
Generate complete LaTeX document for payment report.
"""
function generate_latex_document(data::PaymentTableData;
                                 filter::PaymentFilter=PaymentFilter())::String
    title = "Payment Status Report"
    subtitle = data.event_name !== nothing ? data.event_name : data.event_id
    date_str = Dates.format(Dates.now(), "d. U yyyy, HH:MM")

    table_latex = generate_latex_table(data; filter=filter)

    # Summary data
    summary = """
    \\begin{tabular}{lr}
    \\textbf{Total Registrations} & $(data.total_registrations) \\\\
    \\textcolor{PaidGreen}{\\textbf{Fully Paid}} & $(data.count_paid) \\\\
    \\textcolor{WarningOrange}{Partial Payment} & $(data.count_partial) \\\\
    \\textcolor{UnpaidRed}{\\textbf{Unpaid}} & $(data.count_unpaid) \\\\
    \\textcolor{WarningOrange}{Overpaid} & $(data.count_overpaid) \\\\
    \\textcolor{gray}{No Config} & $(data.count_no_config) \\\\
    \\midrule
    \\textbf{Total Expected} & $(format_money_plain(data.total_cost)) \\\\
    \\textbf{Total Received} & $(format_money_plain(data.total_paid)) \\\\
    \\textbf{Total Subsidies} & $(format_money_plain(data.total_subsidies)) \\\\
    \\textbf{Outstanding} & $(format_money_plain(data.total_remaining)) \\\\
    \\end{tabular}
    """

    doc = """
    \\documentclass[a4paper,11pt]{article}
    \\usepackage[utf8]{inputenc}
    \\usepackage[T1]{fontenc}
    \\usepackage[margin=1.5cm,landscape]{geometry}
    \\usepackage{booktabs}
    \\usepackage{xcolor}
    \\usepackage{longtable}
    \\usepackage{array}
    \\usepackage{amssymb}
    \\usepackage{eurosym}
    \\usepackage{textcomp}

    % Define custom colors
    \\definecolor{PaidGreen}{RGB}{34, 139, 34}
    \\definecolor{UnpaidRed}{RGB}{178, 34, 34}
    \\definecolor{WarningOrange}{RGB}{255, 140, 0}

    \\title{$title}
    \\author{$(escape_latex(subtitle))}
    \\date{Generated: $date_str}

    \\begin{document}

    \\maketitle

    \\section*{Summary}
    $summary

    \\section*{Payment Details}
    $table_latex

    \\end{document}
    """

    return doc
end

"""
Format money without currency symbol for LaTeX.
"""
function format_money_plain(value::Float64)
    return @sprintf("%.2f \\euro", value)
end

"""
Export payment table to PDF.
Requires tectonic to be available.
"""
function export_payment_pdf(data::PaymentTableData, output_path::String;
                            filter::PaymentFilter=PaymentFilter())
    latex_doc = generate_latex_document(data; filter=filter)

    mktempdir() do dir
        texfile = joinpath(dir, "payment_report.tex")

        # Write LaTeX file
        write(texfile, latex_doc)

        # Compile with tectonic
        tectonic_jll.tectonic() do bin
            run(`$bin --chatter=minimal $texfile`)
        end

        # Copy PDF to output
        pdffile = joinpath(dir, "payment_report.pdf")
        if isfile(pdffile)
            cp(pdffile, output_path; force=true)
            @info "PDF exported" path=output_path
        else
            error("PDF generation failed")
        end
    end

    return output_path
end

# =============================================================================
# XLSX EXPORT (via TableExport)
# =============================================================================

function payment_sheet_data(data::PaymentTableData; filter::PaymentFilter=PaymentFilter())
    rows_to_show = filter_payments(data, filter)

    headers = [
        "Reference",
        "Name",
        "Email",
        "Cost",
        "Paid",
        "Subsidy",
        "Remaining",
        "Status"
    ]

    rows = Vector{Vector{Any}}(undef, length(rows_to_show))
    for (idx, row) in enumerate(rows_to_show)
        cost_str = row.cost === nothing ? "" : @sprintf("%.2f", row.cost)
        rows[idx] = [
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

    return SheetData(headers=headers, rows=rows), length(rows_to_show)
end

function payment_summary_sheet(data::PaymentTableData)
    headers = ["Metric", "Value"]
    rows = Vector{Vector{Any}}()
    push!(rows, ["Registrations", data.total_registrations])
    push!(rows, ["Paid", data.count_paid])
    push!(rows, ["Partial", data.count_partial])
    push!(rows, ["Unpaid", data.count_unpaid])
    push!(rows, ["Overpaid", data.count_overpaid])
    push!(rows, ["No Config", data.count_no_config])
    push!(rows, ["Total Expected", @sprintf("%.2f", data.total_cost)])
    push!(rows, ["Total Paid", @sprintf("%.2f", data.total_paid)])
    push!(rows, ["Total Subsidies", @sprintf("%.2f", data.total_subsidies)])
    push!(rows, ["Outstanding", @sprintf("%.2f", data.total_remaining)])

    SheetData(headers=headers, rows=rows)
end

function export_payment_xlsx(data::PaymentTableData, output_path::String;
                             filter::PaymentFilter=PaymentFilter())
    payment_data, row_count = payment_sheet_data(data; filter=filter)
    subtitle = data.event_name === nothing ? data.event_id : "$(data.event_id) - $(data.event_name)"

    # Configure columns with smart formatting
    status_col = ColumnConfig(
        header="Status",
        width=12.0,
        center_content=true
    )
    # Add color-coding for payment status
    push!(status_col.format_rules, Dict{Symbol, Any}(
        :contains => "Paid",
        :bg_color => 0xC6EFCE  # Green for paid
    ))
    push!(status_col.format_rules, Dict{Symbol, Any}(
        :contains => "Unpaid",
        :bg_color => 0xFFC7CE  # Red for unpaid
    ))
    push!(status_col.format_rules, Dict{Symbol, Any}(
        :contains => "Over",
        :bg_color => 0xFFEB9C  # Yellow for overpaid
    ))

    sheets = SheetConfig[
        SheetConfig(
            name="Payments",
            title="Payment Status",
            subtitle="$subtitle | Generated: {date}",
            source=payment_data,
            columns=[status_col]
        ),
        SheetConfig(
            name="Summary",
            source=payment_summary_sheet(data),
            freeze_header=false,
            autofilter=false,
        )
    ]

    export_tables(ExportConfig(output_path=output_path, sheets=sheets))
    @info "XLSX exported" path=output_path rows=row_count
    return output_path
end

function registration_sheet_data(data::RegistrationTableData; filter::RegistrationFilter=RegistrationFilter())
    rows_to_show = filter_registrations(data, filter)

    headers = [
        "Reference",
        "Name",
        "Email",
        "Registered",
        "Cost",
        "Paid",
        "Subsidy",
        "Remaining",
        "Status"
    ]

    rows = Vector{Vector{Any}}(undef, length(rows_to_show))
    for (idx, row) in enumerate(rows_to_show)
        date_str = row.registration_date !== nothing ? Dates.format(row.registration_date, "yyyy-mm-dd") : ""
        cost_str = row.cost === nothing ? "" : @sprintf("%.2f", row.cost)
        rows[idx] = [
            row.reference,
            row.last_name * ", " * row.first_name,
            row.email,
            date_str,
            cost_str,
            @sprintf("%.2f", row.paid),
            @sprintf("%.2f", row.subsidy),
            row.status == STATUS_NO_CONFIG ? "" : @sprintf("%.2f", row.remaining),
            status_display(row.status)
        ]
    end

    return SheetData(headers=headers, rows=rows), length(rows_to_show)
end

function registration_summary_sheet(data::RegistrationTableData)
    headers = ["Metric", "Value"]
    rows = Vector{Vector{Any}}()
    push!(rows, ["Registrations", data.total_registrations])
    push!(rows, ["Paid", data.count_paid])
    push!(rows, ["Partial", data.count_partial])
    push!(rows, ["Unpaid", data.count_unpaid])
    push!(rows, ["Total Expected", @sprintf("%.2f", data.total_cost)])
    push!(rows, ["Total Paid", @sprintf("%.2f", data.total_paid)])
    push!(rows, ["Total Subsidies", @sprintf("%.2f", data.total_subsidies)])
    push!(rows, ["Outstanding", @sprintf("%.2f", data.total_remaining)])

    SheetData(headers=headers, rows=rows)
end

function export_registration_xlsx(data::RegistrationTableData, output_path::String;
                                  filter::RegistrationFilter=RegistrationFilter())
    reg_data, row_count = registration_sheet_data(data; filter=filter)
    subtitle = data.event_name === nothing ? data.event_id : "$(data.event_id) - $(data.event_name)"

    sheets = SheetConfig[
        SheetConfig(
            name="Registrations",
            title="Registrations",
            subtitle="$subtitle | Generated: {date}",
            source=reg_data,
        ),
        SheetConfig(
            name="Summary",
            source=registration_summary_sheet(data),
            freeze_header=false,
            autofilter=false,
        )
    ]

    export_tables(ExportConfig(output_path=output_path, sheets=sheets))
    @info "XLSX exported" path=output_path rows=row_count
    return output_path
end

# =============================================================================
# CSV EXPORT
# =============================================================================

"""
Export payment table to CSV.
"""
function export_payment_csv(data::PaymentTableData, output_path::String;
                            filter::PaymentFilter=PaymentFilter())
    rows_to_show = filter_payments(data, filter)

    open(output_path, "w") do io
        # Header
        println(io, "Reference,Name,Email,Cost,Paid,Subsidy,Remaining,Status")

        for row in rows_to_show
            cost_str = row.cost === nothing ? "" : @sprintf("%.2f", row.cost)
            println(io, join([
                "\"$(row.reference)\"",
                "\"$(row.name)\"",
                "\"$(row.email)\"",
                cost_str,
                @sprintf("%.2f", row.paid),
                @sprintf("%.2f", row.subsidy),
                @sprintf("%.2f", row.remaining),
                "\"$(status_display(row.status))\""
            ], ","))
        end
    end

    @info "CSV exported" path=output_path rows=length(rows_to_show)
    return output_path
end

end # module
