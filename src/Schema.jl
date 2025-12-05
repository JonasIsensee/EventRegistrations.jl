module Schema

using DuckDB
using DBInterface

export init_database

"""
Initialize the database with all required tables.

Tables:
- events: Event definitions with cost rules
- registrations: One row per person-event (latest submission wins)
- submissions: Raw submission history (all submissions kept)
- processed_emails: Track which emails have been processed
- cost_overrides: Manual price adjustments (subsidies)
- bank_transfers: Imported bank transfer data
- payment_matches: Links transfers to registrations
"""
function init_database(db_path::AbstractString)
    db = DuckDB.DB(db_path)

    # =========================================================================
    # EVENTS TABLE
    # Stores event metadata and cost calculation rules
    # =========================================================================
    DBInterface.execute(db, """
        CREATE TABLE IF NOT EXISTS events (
            event_id VARCHAR PRIMARY KEY,
            event_name VARCHAR,
            base_cost DECIMAL(10,2) DEFAULT 0,
            cost_rules JSON,  -- JSON object mapping field patterns to costs
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
    """)

    # =========================================================================
    # REGISTRATIONS TABLE
    # One row per person-event combination (latest submission)
    # Person identified by email address
    # Note: final payable = computed_cost - subsidies - payments (calculated dynamically)
    # =========================================================================
    DBInterface.execute(db, """
        CREATE TABLE IF NOT EXISTS registrations (
            id INTEGER PRIMARY KEY,
            event_id VARCHAR NOT NULL,
            email VARCHAR NOT NULL,
            reference_number VARCHAR UNIQUE NOT NULL,
            first_name VARCHAR,
            last_name VARCHAR,
            fields JSON NOT NULL,
            computed_cost DECIMAL(10,2),  -- Cost from rules
            latest_submission_id INTEGER,
            registration_date TIMESTAMP,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            UNIQUE(event_id, email)
        )
    """)

    # =========================================================================
    # SUBMISSIONS TABLE
    # Raw history of all form submissions (for audit trail)
    # =========================================================================
    DBInterface.execute(db, """
        CREATE TABLE IF NOT EXISTS submissions (
            id INTEGER PRIMARY KEY,
            file_hash VARCHAR NOT NULL,
            event_id VARCHAR NOT NULL,
            email VARCHAR NOT NULL,
            first_name VARCHAR,
            last_name VARCHAR,
            fields JSON NOT NULL,
            email_date TIMESTAMP,
            email_from VARCHAR,
            email_subject VARCHAR,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
    """)

    # =========================================================================
    # PROCESSED EMAILS TABLE
    # Track which .eml files have been processed
    # =========================================================================
    DBInterface.execute(db, """
        CREATE TABLE IF NOT EXISTS processed_emails (
            file_hash VARCHAR PRIMARY KEY,
            filename VARCHAR NOT NULL,
            processed_at TIMESTAMP NOT NULL,
            has_submission BOOLEAN NOT NULL,
            event_id VARCHAR
        )
    """)

    # =========================================================================
    # SUBSIDIES TABLE (formerly cost_overrides)
    # Financial help / discounts - treated as virtual "credits" like payments
    # These reduce the remaining amount just like real transfers do
    # =========================================================================
    DBInterface.execute(db, """
        CREATE TABLE IF NOT EXISTS subsidies (
            id INTEGER PRIMARY KEY,
            registration_id INTEGER NOT NULL REFERENCES registrations(id),
            amount DECIMAL(10,2) NOT NULL,  -- The subsidy/discount amount (positive number)
            reason VARCHAR,
            granted_by VARCHAR,
            granted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
    """)

    # =========================================================================
    # BANK TRANSFERS TABLE
    # Imported from CSV bank statements
    # =========================================================================
    DBInterface.execute(db, """
        CREATE TABLE IF NOT EXISTS bank_transfers (
            id INTEGER PRIMARY KEY,
            transfer_hash VARCHAR UNIQUE NOT NULL,  -- Hash to detect duplicates
            transfer_date DATE NOT NULL,
            amount DECIMAL(10,2) NOT NULL,
            sender_name VARCHAR,
            sender_iban VARCHAR,
            reference_text VARCHAR,  -- The Verwendungszweck
            raw_data JSON,  -- Full row from CSV
            imported_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            source_file VARCHAR
        )
    """)

    # =========================================================================
    # PAYMENT MATCHES TABLE
    # Links bank transfers to registrations
    # Multiple transfers CAN match the same registration (partial payments, overpayments)
    # But each transfer can only be matched once
    # =========================================================================
    DBInterface.execute(db, """
        CREATE TABLE IF NOT EXISTS payment_matches (
            id INTEGER PRIMARY KEY,
            transfer_id INTEGER NOT NULL REFERENCES bank_transfers(id),
            registration_id INTEGER REFERENCES registrations(id),
            match_type VARCHAR NOT NULL,  -- 'auto', 'manual', 'unmatched'
            match_confidence DECIMAL(3,2),  -- 0.0 to 1.0
            matched_reference VARCHAR,  -- The reference number found
            notes VARCHAR,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            UNIQUE(transfer_id)  -- Each transfer matched only once, but multiple transfers per registration allowed
        )
    """)

    # =========================================================================
    # CONFIRMATION EMAILS TABLE
    # Track sent confirmation emails with resending support
    # =========================================================================
    DBInterface.execute(db, """
        CREATE TABLE IF NOT EXISTS confirmation_emails (
            id INTEGER PRIMARY KEY,
            registration_id INTEGER NOT NULL REFERENCES registrations(id),
            email_type VARCHAR NOT NULL,  -- 'confirmation_email', 'payment_confirmation', etc.
            sent_at TIMESTAMP NOT NULL,
            email_to VARCHAR NOT NULL,
            cost_at_send DECIMAL(10,2),     -- computed_cost at time of sending
            remaining_at_send DECIMAL(10,2), -- remaining balance at time of sending
            reference_sent VARCHAR,
            status VARCHAR DEFAULT 'sent',   -- 'sent', 'failed', 'pending'
            error_message VARCHAR,           -- Error details if failed
            resend_reason VARCHAR,           -- Why this email was resent (if applicable)
            supersedes_id INTEGER            -- ID of previous email this replaces (for resends)
        )
    """)

    # =========================================================================
    # CONFIG SYNC TRACKING TABLE
    # Tracks when config files were last synced to the database
    # =========================================================================
    DBInterface.execute(db, """
        CREATE TABLE IF NOT EXISTS config_sync (
            config_path VARCHAR PRIMARY KEY,
            file_mtime TIMESTAMP NOT NULL,
            synced_at TIMESTAMP NOT NULL,
            file_hash VARCHAR
        )
    """)

    # Create sequences
    for seq in ["registration_id_seq", "submission_id_seq", "subsidy_id_seq",
                "transfer_id_seq", "match_id_seq", "email_id_seq"]
        try
            DBInterface.execute(db, "CREATE SEQUENCE IF NOT EXISTS $seq START 1")
        catch; end
    end

    # Create indices
    indices = [
        "CREATE INDEX IF NOT EXISTS idx_reg_event ON registrations(event_id)",
        "CREATE INDEX IF NOT EXISTS idx_reg_email ON registrations(email)",
        "CREATE INDEX IF NOT EXISTS idx_reg_ref ON registrations(reference_number)",
        "CREATE INDEX IF NOT EXISTS idx_sub_event ON submissions(event_id)",
        "CREATE INDEX IF NOT EXISTS idx_sub_email ON submissions(email)",
        "CREATE INDEX IF NOT EXISTS idx_transfer_date ON bank_transfers(transfer_date)",
        "CREATE INDEX IF NOT EXISTS idx_transfer_ref ON bank_transfers(reference_text)",
    ]
    for idx in indices
        try
            DBInterface.execute(db, idx)
        catch; end
    end

    return db
end

end # module
