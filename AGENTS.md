# EventRegistrations.jl - AI Agent Documentation

## Project Overview

EventRegistrations.jl is a **complete event registration management system** written in Julia (1.12+). It handles the full workflow from email-based form submissions to payment tracking and confirmation emails.

**Core Purpose**: Automate event registration processing for organizations that use email forms (e.g., ClubDesk), enabling:
- Email parsing and registration database management
- Flexible cost calculation with configuration-driven rules
- Bank transfer import and automatic payment matching
- Email confirmation system with QR codes
- Multi-format exports (CSV, XLSX, PDF, LaTeX)

**Key Statistics**:
- ~10,600 lines of code
- 14 core modules + 9 CLI modules
- DuckDB database backend
- Full CLI interface + Julia library API

---

## Architecture Overview

### Module Structure

```
EventRegistrations.jl (main module)
├── Schema.jl              - Database schema & initialization
├── Config.jl              - Event configuration (TOML) management
├── AppConfig.jl           - Application-wide config (credentials)
├── EmailParser.jl         - Parse .eml files & extract form data
├── EmailDownload.jl       - POP3 email download
├── ReferenceNumbers.jl    - Generate unique bank-friendly IDs
├── CostCalculator.jl      - Rule-based cost calculation engine
├── Validation.jl          - Config & data validation
├── Registrations.jl       - Registration CRUD operations
├── ConfirmationEmails.jl  - Email queue & SMTP sending
├── BankTransfers.jl       - CSV import & payment matching
├── PrettyOutput.jl        - Table formatting & exports
├── WebDAV.jl              - File upload to Nextcloud/ownCloud
└── cli/                   - Command-line interface
    ├── CLI.jl             - Main CLI dispatcher
    ├── project.jl         - init, status, overview
    ├── emails.jl          - Email processing commands
    ├── config.jl          - Config sync commands
    ├── payments.jl        - Bank transfer & payment commands
    ├── exports.jl         - Export commands
    ├── registrations.jl   - Registration management
    ├── email_queue.jl     - Email queue commands
    ├── repl.jl            - Interactive REPL mode
    └── sync_workflow.jl   - Integrated sync workflow
```

### Data Flow

```
1. Email Submission
   .eml files → EmailParser → submissions table → registrations table
   
2. Cost Calculation
   Registration + Event Config (TOML) → CostCalculator → computed_cost
   
3. Payment Processing
   Bank CSV → BankTransfers → bank_transfers table
                           → match_transfers! → payment_matches table
   
4. Email Confirmations
   Registration → ConfirmationEmails → confirmation_emails queue → SMTP
   
5. Exports
   Registrations + Payments → PrettyOutput → CSV/XLSX/PDF/LaTeX → WebDAV
```

---

## Database Schema

**Backend**: DuckDB (SQLite-compatible, columnar, faster analytics)

### Core Tables

#### `events`
```sql
event_id VARCHAR PRIMARY KEY
event_name VARCHAR
created_at TIMESTAMP
```

#### `registrations`
```sql
id INTEGER PRIMARY KEY
event_id VARCHAR NOT NULL
email VARCHAR NOT NULL (person identifier)
reference_number VARCHAR UNIQUE (e.g., "ABC-1234-XY")
first_name, last_name VARCHAR
fields JSON (raw form data)
computed_cost DECIMAL(10,2)
cost_rules_hash VARCHAR (for cache invalidation)
cost_computed_at TIMESTAMP
latest_submission_id INTEGER
registration_date TIMESTAMP
status VARCHAR (pending|confirmed|paid|cancelled|refunded)
deleted_at TIMESTAMP (soft delete)
UNIQUE(event_id, email) -- one registration per person-event
```

#### `submissions`
```sql
id INTEGER PRIMARY KEY
file_hash VARCHAR (detect duplicates)
event_id, email VARCHAR
first_name, last_name VARCHAR
fields JSON
email_date, email_from, email_subject VARCHAR
created_at TIMESTAMP
```

#### `bank_transfers`
```sql
id INTEGER PRIMARY KEY
file_hash VARCHAR UNIQUE
transfer_date DATE
amount DECIMAL(10,2)
sender_name, sender_iban VARCHAR
reference VARCHAR (free-text from transfer)
source_filename VARCHAR
created_at TIMESTAMP
```

#### `payment_matches`
```sql
id INTEGER PRIMARY KEY
registration_id INTEGER (FK → registrations.id)
transfer_id INTEGER (FK → bank_transfers.id)
matched_amount DECIMAL(10,2)
matched_at TIMESTAMP
matched_by VARCHAR (auto|manual)
confidence FLOAT (0.0-1.0)
```

#### `subsidies`
```sql
id INTEGER PRIMARY KEY
registration_id INTEGER
amount DECIMAL(10,2) (positive = discount)
granted_by, notes VARCHAR
granted_at TIMESTAMP
revoked_at TIMESTAMP (NULL = active)
```

#### `confirmation_emails`
```sql
id INTEGER PRIMARY KEY
registration_id INTEGER
email_type VARCHAR (registration|payment|reminder)
template_name VARCHAR
status VARCHAR (pending|sent|failed|discarded)
scheduled_at, sent_at TIMESTAMP
recipient_address, subject, html_body TEXT
```

#### `financial_transactions`
Immutable ledger for all financial events (cost changes, subsidies, refunds).

---

## Configuration Files

### 1. Event Configuration (`events/<event_id>.toml`)

**Purpose**: Define cost rules, field aliases, and export settings per event.

**Structure**:
```toml
[event]
name = "Workshop Weekend January 2026"

# Map friendly names → actual form field names
[aliases]
uebernachtung_fr = "Übernachtung Freitag"
uebernachtung_sa = "Übernachtung Samstag"

# Cost calculation rules
[costs]
base = 50.0  # Everyone pays base

[[costs.rules]]
field = "uebernachtung_fr"  # Use alias
value = "Ja"
cost = 25.0

[[costs.rules]]
field = "zimmer"
pattern = "Einzelzimmer"  # Regex match
cost = 10.0
multiply_by = "nights"    # Use computed field

# Computed fields (for multipliers)
[costs.computed_fields.nights]
sum_of = [
    { field = "uebernachtung_fr", value = "Ja", count = 1 },
    { field = "uebernachtung_sa", value = "Ja", count = 1 },
]

# Export configuration
[export.registration_details]
columns = ["reference_number", "email", "first_name", "last_name", "uebernachtung_fr"]
```

**Key Features**:
- **Aliases**: Simplify field names (form fields are often long German strings)
- **Rules**: Match field values (exact or regex) and apply costs
- **Computed fields**: Create multipliers (e.g., nights = sum of overnight choices)
- **Conditional rules**: `unless`, `only_if` for bundled options
- **Export columns**: Control which fields appear in exports

**Workflow**:
1. Process emails → auto-generates event config template
2. Edit `events/<event_id>.toml` with cost rules
3. Run `eventreg sync-config` to load into database
4. Run `eventreg recalculate-costs <event-id>` to apply

### 2. Application Configuration (`credentials.toml`)

**Purpose**: Email, SMTP, bank details, WebDAV credentials.

**Never commit this file!** Use `credentials.toml.example` as template.

**Sections**:
- `[email]`: POP3 server for downloading emails
- `[smtp]`: SMTP for sending confirmations
- `[bank]`: IBAN, BIC for QR codes
- `[webdav]`: Nextcloud/ownCloud upload

### 3. Email Templates (`templates/*.mustache`)

**Purpose**: Customizable email content with placeholders.

**Templates**:
- `registration_confirmation.mustache` - Initial confirmation
- `payment_confirmation.mustache` - After payment detected
- `confirmation_email.mustache` - Generic template

**Variables**: `{{first_name}}`, `{{cost}}`, `{{reference_number}}`, `{{{qr_block}}}` (unescaped HTML)

---

## CLI Commands

### Working Directory Pattern

**Critical**: The CLI operates on the **current working directory**, not the package installation directory. Data files live where you run `eventreg`:

```bash
cd ~/my-event-data/     # Your data directory
eventreg init           # Creates events.duckdb, events/, templates/
eventreg status         # Reads from current directory
```

**Directory Structure**:
```
~/my-event-data/
├── events.duckdb          # Database
├── events/                # Event configs (.toml)
├── templates/             # Email templates (.mustache)
├── credentials.toml       # Secrets (git-ignored)
├── emails/                # .eml files to process
├── bank_transfers/        # CSV files
└── exports/               # Generated reports
```

### Command Reference

#### Project Setup
```bash
eventreg init                          # Initialize new project
eventreg status                        # Show config & stats
eventreg event-overview <event-id>     # Event details
```

#### Email Processing
```bash
eventreg download-emails               # POP3 download → emails/
eventreg process-emails [folder]       # Parse .eml files
```

#### Configuration
```bash
eventreg create-event-config <id>      # Generate template
eventreg sync-config                   # Load TOML → database
eventreg recalculate-costs <event-id>  # Apply new rules
```

#### Payments
```bash
eventreg import-bank-csv <file>        # Import CSV
eventreg match-transfers [--event-id]  # Auto-match by reference
eventreg list-unmatched                # Show unmatched transfers
eventreg manual-match <id> <ref>       # Manual match
eventreg grant-subsidy <id> <amount>   # Financial assistance
```

#### Email Queue
```bash
eventreg list-pending-emails [-v]      # Show queue
eventreg send-emails [--id=N]          # Send via SMTP
eventreg mark-email sent|discarded <id>
```

#### Exports
```bash
eventreg export-payment-status [event-id] [output]
eventreg export-registrations [event-id] [output] [--details]
eventreg export-combined [event-id] [output]  # Multi-sheet XLSX
eventreg list-registrations [event-id]        # Terminal output

# Options: --format=terminal|csv|xlsx|pdf|latex
#          --filter=all|unpaid|paid|problems
#          --upload  (WebDAV)
```

#### Registration Management
```bash
eventreg edit-registrations [--event-id] [--name]  # Interactive editing
eventreg delete-registration <id|ref> [--yes]      # Soft delete
```

#### Full Workflow
```bash
eventreg sync  # Complete pipeline:
               # 1. Download emails (if configured)
               # 2. Process emails
               # 3. Match transfers
               # 4. Queue confirmation emails
               # Optional: --send-emails --export-combined --export-payments
```

### REPL Mode

```bash
eventreg  # No arguments → interactive mode

# Commands in REPL:
repl> status
repl> process-emails emails/
repl> list-registrations PWE_2026_01
repl> exit
```

Single database connection, faster for multiple commands.

---

## Library API

### Basic Usage

```julia
using EventRegistrations
using DBInterface

# Initialize
db = init_database("events.duckdb")

# Process emails
stats = process_email_folder!(db, "emails/")
println("New registrations: $(stats.new_registrations)")

# Get registrations
regs = get_registrations(db, "PWE_2026_01")

# Import payments
import_bank_csv!(db, "transfers.csv")
match_transfers!(db; event_id="PWE_2026_01")

# Queue emails
queue_pending_emails!(db, app_config, "PWE_2026_01")

# Cleanup
DBInterface.close!(db)
```

### Key Functions

#### Registrations
```julia
process_email_folder!(db, folder; events_dir="events")
get_registrations(db, event_id) → Vector{NamedTuple}
get_registration_by_reference(db, ref) → NamedTuple
recalculate_costs!(db, event_id)
update_registration!(db, id; email=..., first_name=...)
delete_registration!(db, id_or_ref) # Soft delete
```

#### Cost Calculation
```julia
calculate_cost(db, event_id, fields::Dict) → Float64
calculate_cost_with_details(db, event_id, fields) → CostCalculationResult

# CostCalculationResult fields:
# - total, base
# - rule_costs::Vector{Tuple{String, Float64}}
# - matched_rules, unmatched_fields, warnings
```

#### Payments
```julia
import_bank_csv!(db, path; delimiter=';', decimal_comma=true)
match_transfers!(db; event_id, auto_match_threshold=0.95)
manual_match!(db, transfer_id, reference_number)
grant_subsidy!(db, registration_id, amount; notes="")
get_payment_status(db, registration_id) → NamedTuple
get_payment_summary(db, event_id) → NamedTuple
```

#### Email Queue
```julia
queue_email!(db, registration_id, template_name, email_type)
queue_pending_emails!(db, app_config, event_id)
send_queued_email!(db, app_config, email_id)
mark_email!(db, email_id, status) # "sent" or "discarded"
```

#### Exports
```julia
export_payment_csv(db, event_id, output_path)
export_registration_xlsx(db, event_id, output_path; details=true)
export_payment_pdf(db, event_id, output_path)
upload_via_webdav(app_config, local_path, remote_filename)
```

#### Configuration
```julia
load_event_config(event_id; config_dir="events") → EventConfig
sync_event_configs_to_db!(db; config_dir="events")
check_config_sync(db, event_id) → ConfigSyncStatus
```

---

## Testing

### Test Infrastructure

**Location**: `test/runtests.jl`

**Approach**:
- Creates temporary database (`mktempdir()`)
- Generates synthetic .eml files
- Tests all major workflows end-to-end

### ⚠️ IMPORTANT: Running Tests Locally

**You have Julia installed locally!** Always run tests directly using Julia commands rather than attempting to trigger GitHub workflows:

**Run Tests Locally** ✅:
```bash
# Run the full test suite
julia --project -e 'using Pkg; Pkg.test()'

# Or run tests with more verbose output
julia --project test/runtests.jl
```

**DO NOT trigger GitHub workflows** ❌:
- GitHub workflow dispatch attempts will fail
- You cannot trigger workflows via API or `gh` commands
- CI workflows run automatically on push/PR - no manual triggering needed

**Why run locally?**
- Immediate feedback (no waiting for CI queue)
- Full control over test execution
- Access to detailed error messages and stack traces
- Can run specific test subsets or add debugging output

**Key Test Scenarios**:
1. Email parsing (ClubDesk HTML format)
2. Duplicate detection (file hashing)
3. Resubmission handling (preserve reference numbers)
4. Cost calculation (base + rules + computed fields)
5. Bank CSV parsing (German formats, various encodings)
6. Payment matching (exact, fuzzy, case-insensitive)
7. Email templating (Mustache variables)

### Test Data

**Test events**: `test/events/PWE_2026_01.toml`, `Sommerkonzert_2024.toml`

**Example workflow**:
```julia
using Test, EventRegistrations

@testset "Registration workflow" begin
    db = init_database(":memory:")  # In-memory DB
    
    # Process emails
    stats = process_email_folder!(db, "test/emails")
    @test stats.new_registrations > 0
    
    # Check cost calculation
    regs = get_registrations(db, "PWE_2026_01")
    @test regs[1].computed_cost > 0
    
    DBInterface.close!(db)
end
```

---

## Common Tasks & Patterns

### Task 1: Adding a New Cost Rule

1. Edit `events/PWE_2026_01.toml`:
   ```toml
   [[costs.rules]]
   field = "tshirt"
   value = "Ja"
   cost = 15.0
   ```

2. Sync and recalculate:
   ```bash
   eventreg sync-config
   eventreg recalculate-costs PWE_2026_01
   ```

3. Verify:
   ```bash
   eventreg list-registrations PWE_2026_01
   ```

### Task 2: Processing New Emails

```bash
# 1. Download (if using POP3)
eventreg download-emails

# 2. Process
eventreg process-emails emails/

# 3. Queue confirmations
eventreg sync --send-emails
```

### Task 3: Handling Unmatched Payments

```bash
# 1. List unmatched
eventreg list-unmatched

# 2. Find potential matches (CLI shows suggestions)
eventreg list-registrations PWE_2026_01 --filter=unpaid

# 3. Manual match
eventreg manual-match <transfer_id> ABC-1234-XY
```

### Task 4: Granting Financial Assistance

```julia
db = init_database("events.duckdb")

# Grant 50€ subsidy
grant_subsidy!(db, registration_id, 50.0; 
               notes="Reduced rate for student")

# Queue payment confirmation (if now fully paid)
queue_payment_confirmation!(db, app_config, registration_id)

DBInterface.close!(db)
```

### Task 5: Bulk Editing Registrations

```bash
# Interactive editing with $EDITOR
eventreg edit-registrations --event-id=PWE_2026_01 --name=Müller

# Editor opens with tab-delimited data:
# id  reference_number  email           first_name  last_name
# 42  ABC-1234-XY       old@email.com   Max         Müller

# Edit, save, close → changes applied in transaction
```

### Task 6: Generating Reports for Event

```bash
# Combined multi-sheet workbook
eventreg export-combined PWE_2026_01 report.xlsx --upload

# Payment status PDF
eventreg export-payment-status PWE_2026_01 --format=pdf --upload

# Registration details CSV
eventreg export-registrations PWE_2026_01 --details --format=csv
```

---

## Development Guidelines

### Code Style

- **Julia 1.12+** required
- **Modules**: Each file is a module (e.g., `module BankTransfers`)
- **Exports**: Explicit exports, re-exported in main module
- **Naming**:
  - Functions: `snake_case` with `!` for mutating (e.g., `import_bank_csv!`)
  - Types: `PascalCase` (e.g., `EventConfig`, `CostCalculationResult`)
  - Constants: `UPPER_SNAKE_CASE`
- **Documentation**: Docstrings with examples
- **Error handling**: Clear error messages with actionable hints

### Transaction Pattern

**Always use transactions for multi-step operations**:

```julia
using EventRegistrations: with_transaction

with_transaction(db) do
    # Multiple DB operations
    # If any fail, all are rolled back
    update_registration!(db, id1; status="paid")
    log_financial_transaction!(db, id1, "payment", 100.0)
end
```

### Database Queries

**Use parameterized queries** (SQL injection protection):

```julia
# Good ✓
DBInterface.execute(db, 
    "SELECT * FROM registrations WHERE email = ?", 
    [email])

# Bad ✗
DBInterface.execute(db, 
    "SELECT * FROM registrations WHERE email = '$email'")
```

### CLI Development

**Add new command**:

1. Create function in appropriate `src/cli/*.jl` file
2. Add to dispatcher in `src/cli/CLI.jl`:
   ```julia
   "my-command" => cmd_my_command
   ```
3. Add help text

**CLI pattern**:
```julia
function cmd_my_command(args::Vector{String})
    # Parse args
    db = init_database("events.duckdb")
    try
        # Do work
        return 0  # Success
    catch e
        @error "Command failed" exception=e
        return 1  # Error
    finally
        DBInterface.close!(db)
    end
end
```

### Adding New Cost Rule Types

1. Update `Config.jl` → `materialize_cost_rules()` to handle new structure
2. Update `CostCalculator.jl` → `calculate_cost_with_details()` to apply rule
3. Add validation in `Validation.jl`
4. Update event config examples
5. Add tests

### Performance Tips

- **DuckDB** is fast for analytics but transactions are serialized
- **Batch operations**: Use transactions to group related changes
- **Indexes**: DuckDB auto-indexes primary keys and unique constraints
- **JSON fields**: Use `json_extract_string()` for queries; avoid frequent parsing

---

## Key Design Decisions

### 1. Email as Person Identifier

**Why**: Simplest unique identifier for self-service registration. Allows people to update their registration by resubmitting with the same email.

**Implication**: Email changes require manual intervention (delete old, create new).

### 2. Reference Numbers

**Format**: `ABC-1234-XY` (3 letters, 4 digits, 2 letters)

**Why**: 
- Bank-transfer-friendly (easy to type, memorable)
- Collision-resistant (26³ × 10⁴ × 26² ≈ 457M combinations)
- Human-readable (avoid confusing characters)

### 3. Soft Deletes

**Pattern**: `deleted_at TIMESTAMP` (NULL = active)

**Why**: Preserve financial audit trail, allow "undo", maintain referential integrity.

**Implication**: Always filter with `WHERE deleted_at IS NULL` in queries.

### 4. Immutable Financial Ledger

**Table**: `financial_transactions` (append-only)

**Why**: Audit compliance, debugging payment discrepancies, undo support.

**Implication**: Never DELETE/UPDATE financial records; add compensating entries.

### 5. Configuration in TOML vs. Database

**TOML**: Cost rules, aliases, export settings (version-controlled, human-editable)

**Database**: Materialized rules + hash (fast lookups, cache invalidation)

**Sync**: `sync-config` command loads TOML → JSON → database.

### 6. CLI Working Directory Pattern

**Why**: Separates code from data. One package installation serves multiple event projects.

**Implication**: Users must `cd` to data directory before running commands.

---

## Troubleshooting

### Problem: "Database not found: events.duckdb"

**Cause**: Running command in wrong directory.

**Fix**: 
```bash
cd /path/to/your/data
eventreg status
```

Or initialize:
```bash
eventreg init
```

### Problem: "No cost configuration for event_id"

**Cause**: Event config not synced to database.

**Fix**:
```bash
eventreg sync-config
eventreg recalculate-costs <event-id>
```

### Problem: Payments not matching automatically

**Cause**: Reference number not in transfer reference field, or typos.

**Debug**:
```bash
eventreg list-unmatched                    # Show transfers
eventreg list-registrations <event-id> --filter=unpaid  # Show registrations
eventreg manual-match <transfer-id> <reference-number>
```

### Problem: Duplicate email processing

**Cause**: File renamed or moved (hash changes).

**Prevention**: EmailParser hashes file *content*, but filename changes in different folders confuse it.

**Fix**: Delete duplicates from `processed_emails` table if needed.

### Problem: Email sending fails

**Cause**: SMTP credentials, network, or template syntax.

**Debug**:
```julia
using EventRegistrations

db = init_database("events.duckdb")
app_config = load_app_config("credentials.toml")

# Preview email (doesn't send)
reg = get_registrations(db, "PWE_2026_01")[1]
email_html = preview_email(db, app_config, reg, "registration_confirmation")
println(email_html)
```

---

## File Locations Reference

### Package Files (Read-Only)
```
EventRegistrations.jl/
├── src/              # Source code
├── templates/        # Default email templates (copied on init)
├── test/             # Test suite
├── bin/eventreg      # CLI launcher script
└── Project.toml      # Dependencies
```

### Data Files (Per-Project, User-Managed)
```
~/my-event-data/
├── events.duckdb           # SQLite database
├── credentials.toml        # Secrets (git-ignored!)
├── events/                 # Event configs
│   ├── PWE_2026_01.toml
│   └── Sommerkonzert_2024.toml
├── templates/              # Email templates (customizable)
│   ├── registration_confirmation.mustache
│   └── payment_confirmation.mustache
├── emails/                 # Downloaded .eml files
├── bank_transfers/         # CSV files
└── exports/                # Generated reports
```

---

## Dependencies Overview

**Database**: DuckDB.jl (columnar, fast analytics, SQLite-compatible)

**Email**:
- SMTPClient.jl (sending)
- StringEncodings.jl (ISO-8859-1 handling for German umlauts)

**Exports**:
- PrettyTables.jl (terminal tables)
- TableExport.jl (XLSX, PDF via LaTeX)
- tectonic_jll.jl (LaTeX compiler)

**Utilities**:
- TOML.jl (config parsing)
- JSON.jl (fields storage)
- Mustache.jl (email templates)
- QRCode.jl (payment QR codes)
- HTTP.jl (WebDAV uploads)
- Crayons.jl (colored output)

**Development**:
- PrecompileTools.jl (faster startup). See **docs/PRECOMPILE_TTFX.md** for precompile/TTFX diagnostics, SnoopCompile workflow, and worst-offender improvement options.
- TableEdit.jl (interactive editing)
- REPL/LineEdit (custom REPL; no ReplMaker)

---

## Security Considerations

1. **Never commit `credentials.toml`** - Already in `.gitignore`
2. **SQL Injection**: All queries use parameterized statements
3. **Email Redirect**: Use `smtp.redirect_to` in credentials for testing (all emails go to one address)
4. **Soft Deletes**: Deleted registrations still in DB (GDPR compliance may require hard deletes)
5. **File Permissions**: Database and credentials should be `chmod 600` in production

---

## Performance Characteristics

**Fast**:
- Email processing: ~100 emails/second (I/O bound)
- Cost calculation: ~10,000 registrations/second
- Database queries: DuckDB columnar format optimized for analytics
- Bank CSV import: ~5,000 rows/second

**Slow**:
- PDF export: LaTeX compilation (~5 seconds/document)
- Email sending: SMTP network latency (~1 email/second)

**Scalability**:
- Tested with: 1,000+ registrations, 500+ bank transfers
- Database size: ~1 MB per 100 registrations
- Bottleneck: SMTP sending for bulk emails

---

## Future Extension Points

Based on the architecture, here's where to extend functionality:

1. **New Export Formats**: Add to `PrettyOutput.jl` (e.g., HTML, Excel with formatting)
2. **New Email Providers**: Add parsers to `EmailParser.jl` (currently ClubDesk-focused)
3. **Webhooks**: Add `WebhookNotifications.jl` module
4. **Multi-Currency**: Extend `CostCalculator.jl` and database schema
5. **Refunds**: Add to `BankTransfers.jl`, log in `financial_transactions`
6. **Attendance Tracking**: New table + module (who showed up vs. registered)
7. **Capacity Limits**: Add constraints to event config
8. **Discounts/Coupons**: Extend cost rules with coupon codes

---

## Quick Reference: One-Liner Solutions

```bash
# Show all registrations with payment status
eventreg export-payment-status PWE_2026_01 --format=terminal

# Find someone by name
eventreg list-registrations PWE_2026_01 --name=Schmidt

# Grant subsidy via CLI (use library for batch)
eventreg grant-subsidy <id> 50.0

# Export everything to Nextcloud
eventreg export-combined PWE_2026_01 report.xlsx --upload

# Delete a registration
eventreg delete-registration ABC-1234-XY

# Recalculate all costs after config change
eventreg recalculate-costs PWE_2026_01

# Full sync workflow (download → process → match → email → export)
eventreg sync --send-emails --export-combined --export-payments

# Check what emails would be sent (dry-run)
eventreg list-pending-emails -v
```

---

## Summary for AI Agents

**What this system does**: End-to-end event registration management via email forms.

**Key workflows**:
1. Email → Database (parse, dedupe, cost calc)
2. Bank CSV → Payment matching (auto + manual)
3. Database → Emails (confirmations with QR codes)
4. Database → Reports (multi-format exports)

**Best practices**:
- Always use transactions for multi-step changes
- Sync config before recalculating costs
- Test email templates with `preview_email()` before sending
- Use `--upload` flag for WebDAV exports
- Soft delete (don't hard delete) for audit trail

**Common pitfalls**:
- Running CLI from wrong directory (no `events.duckdb`)
- Forgetting to `sync-config` after editing TOML
- Not filtering `deleted_at IS NULL` in custom queries
- Hardcoding credentials (use `credentials.toml`)

**Architecture patterns**:
- Modules communicate via parent module imports
- CLI functions are thin wrappers around library API
- Database is single source of truth (TOML synced to DB)
- Immutable ledger for financial transactions

This system is production-ready for small-to-medium events (hundreds of registrations). For thousands of concurrent users, consider adding a web frontend and queueing system for emails.
