# EventRegistrations.jl

A complete event registration management system built in Julia for processing form submissions from emails, calculating costs, tracking payments, and sending confirmations.

## Features

- Parse registration form submissions from .eml email files
- Calculate costs based on configurable rules (accommodation, meals, transport, etc.)
- Generate unique bank-transfer-friendly reference numbers
- Import bank transfer CSVs and auto-match payments
- Track subsidies (financial help) as virtual credits
- Send confirmation and payment emails with QR codes via SMTP
- Export payment status and registration reports (terminal, CSV, XLSX, PDF, LaTeX)
- Upload exports to WebDAV (ownCloud, Nextcloud)

## Installation

### Prerequisites

- Julia 1.12 or later

### Setup

1. Clone or download the EventRegistrations.jl package:

```bash
cd /path/to/your/projects
git clone <repository-url> EventRegistrations.jl
```

2. Install dependencies:

```bash
cd EventRegistrations.jl
julia --project -e 'using Pkg; Pkg.instantiate()'
```

3. Add the CLI to your PATH (optional but recommended):

```bash
# On Linux/Mac:
sudo ln -s $(pwd)/bin/eventreg /usr/local/bin/eventreg

# Or add to your shell profile:
export PATH="$PATH:/path/to/EventRegistrations.jl/bin"
```

## Quick Start

### Initialize a New Project

Navigate to the directory where you want to store your data (database, events, emails):

```bash
cd ~/my-event-registrations
eventreg init
```

This creates:

- `events.duckdb` - Database file
- `events/` - Per-event configuration files (TOML)
- `templates/` - Email templates (Mustache)

### Process Registration Emails

1. Place your `.eml` files in an `emails/` directory
2. Run:

```bash
eventreg process-emails emails/
```

Event configuration templates are auto-generated for newly seen events.

### Configure Event Costs

1. Edit the auto-generated event config at `events/<event_id>.toml` to set aliases and cost rules

2. Sync configuration and recalculate costs:

```bash
eventreg sync-config
eventreg recalculate-costs <event-id>
```

### Import Bank Transfers

```bash
eventreg import-bank-csv bank_transfers/january.csv
eventreg match-transfers --event-id=PWE_2026_01
```

### Export Reports

```bash
eventreg export-payment-status PWE_2026_01 payment_status.csv
eventreg export-registrations PWE_2026_01 --details registrations.csv
eventreg export-combined PWE_2026_01 report.xlsx
```

### Full Workflow

Run the entire pipeline in one command:

```bash
eventreg sync --send-emails --export-combined --export-payments
```

## CLI Commands

### Project Management

- `eventreg init` - Initialize new project
- `eventreg status` - Show system status and configuration
- `eventreg event-overview <event-id>` - Show event details
- `eventreg sync` - Full sync workflow (download, process, match, queue emails)

### Email Processing

- `eventreg process-emails [folder]` - Process registration emails
- `eventreg download-emails` - Download emails from POP3 server

### Configuration

- `eventreg create-event-config <id>` - Create event config template
- `eventreg sync-config` - Sync config files to database
- `eventreg recalculate-costs <event-id>` - Recalculate costs after config changes

### Bank Transfers & Payments

- `eventreg import-bank-csv <file>` - Import bank transfers
- `eventreg match-transfers` - Match transfers to registrations
- `eventreg list-unmatched` - List unmatched transfers
- `eventreg manual-match <id> <ref>` - Manually match a transfer
- `eventreg grant-subsidy <id> <amount>` - Grant subsidy to registration
- `eventreg delete-registration <id|ref>` - Cancel a registration (soft delete); use `--yes` to skip confirmation

### Email Management

- `eventreg list-pending-emails [-v]` - List emails waiting to be sent
- `eventreg send-emails [--id=N]` - Send pending emails via SMTP
- `eventreg mark-email sent|discarded <id>` - Mark email status
- `eventreg mark-email sent|discarded --all` - Bulk mark emails

### Exports

- `eventreg export-payment-status [event-id] [output]` - Payment status report
- `eventreg export-registrations [event-id] [output]` - Registration data
- `eventreg export-combined [event-id] [output]` - Combined multi-sheet XLSX workbook
- `eventreg list-registrations [event-id]` - Quick registration listing with filters
- `eventreg edit-registrations [event-id]` - Edit registrations in external editor (TableEdit); `--event-id=`, `--name=`, `--since=` to filter; save and close editor to apply changes in one transaction

**Edit registrations (TableEdit):** Dumps filtered registrations (id, reference_number, email, first_name, last_name) to a temp tab-delimited file, opens `$EDITOR`, and on save parses/validates and applies only **modified** rows via `update_registration!` in one transaction. Validation errors (e.g. wrong column count) are reported with line number and no changes are applied.

**Runnable examples:**
```bash
# From a directory that has events.duckdb (e.g. demo_pwe):
cd /path/to/EventRegistrations.jl
./bin/eventreg edit-registrations --event-id=PWE_2026_01
# Or filter by name:
./bin/eventreg edit-registrations --event-id=PWE_2026_01 --name=Müller
# Editor opens; edit email/name, save and close; CLI reports success and DB is updated.
```
```bash
# Non-interactive example (edits file in code, then applies):
julia --project=. examples/edit_registrations_example.jl
# Or with a data dir: julia --project=. examples/edit_registrations_example.jl /path/to/data
```

All export commands support `--format=terminal|csv|xlsx|pdf|latex`, `--filter=all|unpaid|paid|problems`, and `--upload` for WebDAV.

Run `eventreg --help` for full command list and options.

## Using as a Library

You can also use EventRegistrations as a Julia library:

```julia
using EventRegistrations

# Initialize database
db = init_database("events.duckdb")

# Process emails
stats = process_email_folder!(db, "emails")

# Get registrations
registrations = get_registrations(db, "PWE_2026_01")

# Import bank transfers
import_bank_csv!(db, "transfers.csv")
match_transfers!(db; event_id="PWE_2026_01")

# Close database
DBInterface.close!(db)
```

See [CLAUDE.md](CLAUDE.md) for detailed API documentation.

## Working Directory

**Important:** The package is designed to work from any directory. The current working directory (where you run `eventreg`) should be where you want your data stored:

- Database file (`events.duckdb`)
- Event configurations (`events/`)
- Email templates (`templates/`)
- Email folders (`emails/`)
- Bank transfer files (`bank_transfers/`)
- Credentials (`credentials.toml`)

The package code can be installed anywhere - it doesn't need to be in the same location as your data.

## Testing

Run the test suite:

```bash
cd EventRegistrations.jl
julia --project -e 'using Pkg; Pkg.test()'
```

## Configuration Files

### Event Configuration (`events/<event_id>.toml`)

Each event has a unified configuration file with aliases, cost rules, and export settings:

```toml
[event]
name = "Workshop Weekend January 2026"

[aliases]
uebernachtung_fr = "Übernachtung Freitag"
uebernachtung_sa = "Übernachtung Samstag"

[costs]
base = 0.0

[[costs.rules]]
field = "uebernachtung_fr"
value = "Ja"
cost = 25.0

[costs.computed_fields.nights]
sum_of = [
    { field = "uebernachtung_fr", value = "Ja", count = 1 },
    { field = "uebernachtung_sa", value = "Ja", count = 1 },
]

[export.registration_details]
columns = [
    "reference_number",
    "email",
    "first_name",
    "last_name",
    "uebernachtung_fr",
    "uebernachtung_sa",
]
```

Entries in `[export.registration_details]` may include built-in fields (like `reference_number` or `registration_date`) or form field aliases. Aliases are resolved to actual form field names automatically. Only the listed columns are exported.

### Email Templates (`templates/*.mustache`)

Customizable Mustache email templates with placeholders:

```
Hallo {{first_name}},

vielen Dank für deine Anmeldung!

Kosten: {{cost}} Euro
Referenznummer: {{reference_number}}

Bitte überweise den Betrag mit der Referenznummer.

{{{bank_details}}}
{{{qr_block}}}
```

### Credentials (`credentials.toml`)

See `credentials.toml.example` for the format. Contains POP3, SMTP, bank details, and WebDAV credentials.

## License

See LICENSE file.

## Support

For issues and questions, please check:

- The comprehensive documentation in [CLAUDE.md](CLAUDE.md)
- Test files for usage examples
