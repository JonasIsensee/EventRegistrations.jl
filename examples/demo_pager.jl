#!/usr/bin/env julia
"""
Manual demonstration of pager functionality

This script demonstrates the pager feature with sample data.
Run this script to see the pager in action.

Usage:
    julia --project examples/demo_pager.jl
"""

# Add the project to the load path
push!(LOAD_PATH, joinpath(@__DIR__, ".."))

using EventRegistrations
using Dates

# Create sample payment data
function create_sample_payment_data()
    rows = EventRegistrations.PrettyOutput.PaymentRow[]
    
    # Create 30 sample rows to demonstrate scrolling
    for i in 1:30
        row = EventRegistrations.PrettyOutput.PaymentRow(
            "REF_2026_$(lpad(i, 3, '0'))",
            "Sample Name $i",
            100.0 + i * 10,
            if i % 3 == 0
                100.0 + i * 10  # Paid
            elseif i % 3 == 1
                50.0  # Partial
            else
                0.0  # Unpaid
            end,
            0.0,  # subsidy
            if i % 3 == 0
                EventRegistrations.PrettyOutput.STATUS_PAID
            elseif i % 3 == 1
                EventRegistrations.PrettyOutput.STATUS_PARTIAL
            else
                EventRegistrations.PrettyOutput.STATUS_UNPAID
            end,
            if i % 3 == 0
                0.0
            elseif i % 3 == 1
                50.0 + i * 10
            else
                100.0 + i * 10
            end
        )
        push!(rows, row)
    end
    
    return EventRegistrations.PrettyOutput.PaymentTableData(
        "DEMO_2026",
        "Demo Event - Pager Test",
        rows,
        30,
        3500.0,
        1500.0,
        0.0,
        2000.0
    )
end

# Create sample registration data
function create_sample_registration_data()
    rows = EventRegistrations.PrettyOutput.RegistrationRow[]
    
    # Create 30 sample rows with long email addresses
    for i in 1:30
        row = EventRegistrations.PrettyOutput.RegistrationRow(
            "REF_2026_$(lpad(i, 3, '0'))",
            "LastName$i",
            "FirstName$i",
            "verylongemailaddress$(i)@example-domain.com",
            DateTime(2026, 1, 15, 10, 30, 0),
            100.0 + i * 10,
            if i % 3 == 0
                EventRegistrations.PrettyOutput.STATUS_PAID
            elseif i % 3 == 1
                EventRegistrations.PrettyOutput.STATUS_PARTIAL
            else
                EventRegistrations.PrettyOutput.STATUS_UNPAID
            end,
            if i % 3 == 0
                0.0
            elseif i % 3 == 1
                50.0 + i * 10
            else
                100.0 + i * 10
            end
        )
        push!(rows, row)
    end
    
    return EventRegistrations.PrettyOutput.RegistrationTableData(
        "DEMO_2026",
        "Demo Event - Pager Test",
        rows,
        30
    )
end

println("""
================================================================================
PAGER DEMONSTRATION
================================================================================

This demonstration shows the new pager functionality for table display.

We'll show:
1. Normal output (no pager) with truncated emails
2. Normal output (no pager) with full emails
3. Paged output with full emails and horizontal scrolling

Press Enter to continue between demonstrations...
================================================================================
""")

println("\n--- 1. Normal Payment Table (no pager) ---\n")
payment_data = create_sample_payment_data()
EventRegistrations.PrettyOutput.print_payment_table(payment_data; pager=false)

println("\n\nPress Enter to see registration table with TRUNCATED emails (default)...")
readline()

println("\n--- 2. Registration Table - Truncated Emails (no pager) ---\n")
reg_data = create_sample_registration_data()
EventRegistrations.PrettyOutput.print_registration_table(reg_data; pager=false, truncate_email=true)

println("\n\nPress Enter to see registration table with FULL emails (no pager)...")
readline()

println("\n--- 3. Registration Table - Full Emails (no pager) ---\n")
EventRegistrations.PrettyOutput.print_registration_table(reg_data; pager=false, truncate_email=false)

println("\n\nPress Enter to see paged output with scrolling...")
readline()

println("""

--- 4. Paged Output (with scrolling) ---

The next display will open in the 'less' pager.
- Use arrow keys or j/k to scroll vertically
- Use arrow keys or h/l to scroll horizontally
- Press 'q' to quit the pager

Press Enter to open the pager...
""")
readline()

# This will open in the pager - user can scroll both vertically and horizontally
EventRegistrations.PrettyOutput.print_registration_table(reg_data; pager=true)

println("\n✓ Pager demonstration complete!")
println("""
================================================================================
USAGE IN CLI:

  eventreg list-registrations --pager
  eventreg export-payment-status --pager
  eventreg export-registrations --pager

The pager automatically shows full email addresses (no truncation) and
supports both vertical and horizontal scrolling.
================================================================================
""")
