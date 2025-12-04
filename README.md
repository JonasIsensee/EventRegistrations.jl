# EventRegistrations.jl

A complete event registration management system built in Julia for processing form submissions from emails, calculating costs, tracking payments, and sending confirmations.

## Features

- 📧 Parse registration form submissions from .eml email files
- 💰 Calculate costs based on configurable rules (accommodation, bus, surcharges)
- 🔢 Generate unique bank-transfer-friendly reference numbers
- 🏦 Import bank transfer CSVs and auto-match payments
- 💸 Track subsidies (financial help) as virtual credits
- ✉️ Send confirmation emails with payment details
- 📊 Export payment status and registration reports

## Installation

### Prerequisites

- Julia 1.12 or later

### Setup

1. Clone or download the EventRegistrations.jl package:
```bash
cd /path/to/your/projects
git clone <repository-url> EventRegistrations.jl
# or download and extract the package
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

Navigate to the directory where you want to store your data (database, config, emails):

```bash
cd ~/my-event-registrations
eventreg init
```

This creates:
- `events.duckdb` - Database file
- `config/` - Configuration directory
  - `fields.toml` - Field name aliases
  - `events/` - Per-event cost rules
  - `templates/` - Email templates

### Process Registration Emails

1. Place your `.eml` files in an `emails/` directory
2. Run:
```bash
eventreg process-emails emails/
```

### Configure Event Costs

1. Generate field configuration from processed emails:
```bash
eventreg generate-field-config
```

2. Edit `config/fields.toml` to customize field aliases

3. Create event configuration:
```bash
eventreg create-event-config PWE_2026_01 --name="Workshop Weekend January 2026"
```

4. Edit `config/events/PWE_2026_01.toml` to set cost rules

5. Sync configuration to database:
```bash
eventreg sync-config
```

### Import Bank Transfers

```bash
eventreg import-bank-csv bank_transfers/january.csv
eventreg match-transfers --event-id=PWE_2026_01
```

### Export Reports

```bash
eventreg export-payment-status PWE_2026_01 payment_status.csv
eventreg export-registrations PWE_2026_01 registrations.csv
```

## CLI Commands

### Project Management
- `eventreg init` - Initialize new project
- `eventreg list-events` - List all events
- `eventreg event-overview <event-id>` - Show event details

### Email Processing
- `eventreg process-emails [folder]` - Process registration emails
- `eventreg generate-field-config` - Generate field configuration

### Configuration
- `eventreg create-event-config <id>` - Create event config template
- `eventreg sync-config` - Sync config files to database

### Bank Transfers
- `eventreg import-bank-csv <file>` - Import bank transfers
- `eventreg match-transfers` - Match transfers to registrations
- `eventreg list-unmatched` - List unmatched transfers
- `eventreg manual-match <id> <ref>` - Manually match a transfer

### Subsidies
- `eventreg grant-subsidy <id> <amount>` - Grant subsidy to registration

### Reports
- `eventreg export-payment-status <event-id> <output>` - Export payment report
- `eventreg export-registrations <event-id> <output>` - Export registration data

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

# Export reports
export_payment_status_csv(db, "PWE_2026_01", "payment_status.csv")

# Close database
DBInterface.close!(db)
```

See the [CLAUDE.md](../registration_software/CLAUDE.md) file for detailed API documentation.

## Working Directory

**Important:** The package is designed to work from any directory. The current working directory (where you run `eventreg`) should be where you want your data stored:

- Database file (`events.duckdb`)
- Configuration directory (`config/`)
- Email folders (`emails/`)
- Bank transfer files (`bank_transfers/`)

The package code can be installed anywhere - it doesn't need to be in the same location as your data.

## Testing

Run the test suite:

```bash
cd EventRegistrations.jl
julia --project test/runtests.jl
```

Or using Julia's test runner:

```bash
julia --project -e 'using Pkg; Pkg.test()'
```

## Configuration Files

### Field Aliases (`config/fields.toml`)

Maps short names to actual form field names:

```toml
[aliases]
uebernachtung_fr = "Übernachtung Freitag"
uebernachtung_sa = "Übernachtung Samstag"
busfahrt_hin = "Busfahrt Hinweg (10€)"
```

### Event Cost Rules (`config/events/<event_id>.toml`)

Defines pricing logic:

```toml
event_id = "PWE_2026_01"
event_name = "Workshop Weekend January 2026"
base_cost = 0.0

[[rules]]
field = "uebernachtung_fr"
value = "Ja"
cost = 25.0

[[rules]]
field = "busfahrt_hin"
value = "Ja"
cost = 10.0
```

### Email Templates (`config/templates/*.txt`)

Customizable email templates with placeholders:

```
Hallo {first_name},

vielen Dank für deine Anmeldung!

Kosten: {cost} €
Referenznummer: {reference_number}

Bitte überweise den Betrag mit der Referenznummer.
```

## License

See LICENSE file.

## Support

For issues and questions, please check:
- The comprehensive documentation in CLAUDE.md
- Example workflows in the registration_software/ directory
- Test files for usage examples
