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
    
    total_cost = 0.0
    total_paid = 0.0
    total_subsidies = 0.0
    total_remaining = 0.0
    count_paid = 0
    count_overpaid = 0
    count_partial = 0
    count_unpaid = 0
    count_no_config = 0
    
    # Create 30 sample rows to demonstrate scrolling
    for i in 1:30
        cost = 100.0 + i * 10
        paid = if i % 3 == 0
            cost  # Paid
        elseif i % 3 == 1
            50.0  # Partial
        else
            0.0  # Unpaid
        end
        subsidy = 0.0
        remaining = cost - paid - subsidy
        status = if i % 3 == 0
            count_paid += 1
            EventRegistrations.PrettyOutput.STATUS_PAID
        elseif i % 3 == 1
            count_partial += 1
            EventRegistrations.PrettyOutput.STATUS_PARTIAL
        else
            count_unpaid += 1
            EventRegistrations.PrettyOutput.STATUS_UNPAID
        end
        
        total_cost += cost
        total_paid += paid
        total_subsidies += subsidy
        if remaining > 0
            total_remaining += remaining
        end
        
        row = EventRegistrations.PrettyOutput.PaymentRow(
            "REF_2026_$(lpad(i, 3, '0'))",   # reference
            "Sample Name $i",                 # name
            "sample$(i)@example.com",         # email
            cost,                             # cost
            paid,                             # paid
            subsidy,                          # subsidy
            remaining,                        # remaining
            status                            # status
        )
        push!(rows, row)
    end
    
    return EventRegistrations.PrettyOutput.PaymentTableData(
        "DEMO_2026",           # event_id
        "Demo Event - Pager Test",  # event_name
        rows,                  # rows
        30,                    # total_registrations
        total_cost,            # total_cost
        total_paid,            # total_paid
        total_subsidies,       # total_subsidies
        total_remaining,       # total_remaining
        count_paid,            # count_paid
        count_overpaid,        # count_overpaid
        count_partial,         # count_partial
        count_unpaid,          # count_unpaid
        count_no_config        # count_no_config
    )
end

# Create sample registration data
function create_sample_registration_data()
    rows = EventRegistrations.PrettyOutput.RegistrationRow[]
    
    total_cost = 0.0
    total_paid = 0.0
    total_subsidies = 0.0
    total_remaining = 0.0
    count_paid = 0
    count_partial = 0
    count_unpaid = 0
    
    # Create 30 sample rows with long email addresses
    for i in 1:30
        cost = 100.0 + i * 10
        paid = if i % 3 == 0
            cost  # Paid
        elseif i % 3 == 1
            50.0  # Partial
        else
            0.0  # Unpaid
        end
        subsidy = 0.0
        remaining = cost - paid - subsidy
        status = if i % 3 == 0
            count_paid += 1
            EventRegistrations.PrettyOutput.STATUS_PAID
        elseif i % 3 == 1
            count_partial += 1
            EventRegistrations.PrettyOutput.STATUS_PARTIAL
        else
            count_unpaid += 1
            EventRegistrations.PrettyOutput.STATUS_UNPAID
        end
        
        total_cost += cost
        total_paid += paid
        total_subsidies += subsidy
        if remaining > 0
            total_remaining += remaining
        end
        
        row = EventRegistrations.PrettyOutput.RegistrationRow(
            "REF_2026_$(lpad(i, 3, '0'))",                      # reference
            "FirstName$i",                                      # first_name
            "LastName$i",                                       # last_name
            "verylongemailaddress$(i)@example-domain.com",      # email
            DateTime(2026, 1, 15, 10, 30, 0),                   # registration_date
            cost,                                               # cost
            paid,                                               # paid
            subsidy,                                            # subsidy
            remaining,                                          # remaining
            status,                                             # status
            Dict{String,Any}()                                  # fields
        )
        push!(rows, row)
    end
    
    return EventRegistrations.PrettyOutput.RegistrationTableData(
        "DEMO_2026",           # event_id
        "Demo Event - Pager Test",  # event_name
        rows,                  # rows
        30,                    # total_registrations
        total_cost,            # total_cost
        total_paid,            # total_paid
        total_subsidies,       # total_subsidies
        total_remaining,       # total_remaining
        count_paid,            # count_paid
        count_partial,         # count_partial
        count_unpaid           # count_unpaid
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

The next display will use TerminalPager.jl for interactive scrolling.
- Use arrow keys to scroll vertically and horizontally
- Press 'q' to quit the pager
- ANSI colors are preserved

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
