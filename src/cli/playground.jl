# Playground commands for testing and development

using TOML
using Random: randperm

# =============================================================================
# COMMON GERMAN NAMES FOR REALISTIC TEST DATA
# =============================================================================

const GERMAN_FIRST_NAMES = [
    # Female names
    "Anna", "Emma", "Mia", "Sophie", "Marie", "Lena", "Leonie", "Lea",
    "Hannah", "Laura", "Julia", "Lisa", "Sarah", "Lara", "Katharina",
    "Christina", "Nicole", "Stefanie", "Sandra", "Sabine", "Claudia",
    "Petra", "Monika", "Andrea", "Birgit", "Susanne", "Martina", "Karin",
    "Elisabeth", "Maria", "Anja", "Melanie", "Heike", "Michaela", "Silke",
    "Daniela", "Tanja", "Franziska", "Johanna", "Amelie", "Charlotte",
    # Male names
    "Max", "Paul", "Leon", "Felix", "Jonas", "Tim", "Lukas", "Jan",
    "Niklas", "Moritz", "Julian", "Alexander", "Philipp", "Simon", "David",
    "Michael", "Thomas", "Andreas", "Stefan", "Christian", "Markus", "Martin",
    "Daniel", "Peter", "Frank", "Wolfgang", "Klaus", "Jürgen", "Werner",
    "Dieter", "Hans", "Uwe", "Bernd", "Matthias", "Ralf", "Jochen",
    "Sebastian", "Tobias", "Benjamin", "Florian", "Patrick", "Oliver", "Robert"
]

const GERMAN_LAST_NAMES = [
    "Müller", "Schmidt", "Schneider", "Fischer", "Weber", "Meyer", "Wagner",
    "Becker", "Schulz", "Hoffmann", "Schäfer", "Koch", "Bauer", "Richter",
    "Klein", "Wolf", "Schröder", "Neumann", "Schwarz", "Zimmermann", "Braun",
    "Krüger", "Hofmann", "Hartmann", "Lange", "Schmitt", "Werner", "Schmitz",
    "Krause", "Meier", "Lehmann", "Schmid", "Schulze", "Maier", "Köhler",
    "Herrmann", "König", "Walter", "Mayer", "Huber", "Kaiser", "Fuchs",
    "Peters", "Lang", "Scholz", "Möller", "Weiß", "Jung", "Hahn", "Schubert",
    "Vogel", "Friedrich", "Keller", "Günther", "Frank", "Berger", "Winkler",
    "Roth", "Beck", "Lorenz", "Baumann", "Franke", "Albrecht", "Schuster",
    "Simon", "Ludwig", "Böhm", "Winter", "Kraus", "Martin", "Schumacher",
    "Krämer", "Vogt", "Stein", "Jäger", "Otto", "Sommer", "Groß", "Seidel",
    "Heinrich", "Brandt", "Haas", "Schreiber", "Graf", "Schulte", "Dietrich",
    "Ziegler", "Kuhn", "Kühn", "Pohl", "Engel", "Horn", "Busch", "Bergmann",
    "Thomas", "Voigt", "Sauer", "Arnold", "Wolff", "Pfeiffer"
]

# =============================================================================
# FIELD VALUE OPTIONS FOR DIFFERENT EVENT TYPES
# =============================================================================

const VOICE_PARTS = [
    "Sopran", "Alt", "Tenor", "Bass", "Bariton",
    "Violine 1", "Violine 2", "Viola", "Cello", "Kontrabass",
    "Flöte", "Oboe", "Klarinette", "Fagott",
    "Horn", "Trompete", "Posaune", "Tuba",
    "Schlagzeug", "Klavier", "Harfe"
]

const FOOD_OPTIONS = ["Alles", "Vegetarisch", "Vegan"]
const YES_NO_OPTIONS = ["Ja", "Nein"]
const ROOM_OPTIONS = ["Mehrbettzimmer", "Einzelzimmer (+10 € pro Nacht)"]

const ALLERGIES = [
    "",  # No allergies (most common)
    "", "", "", "", "", "",  # Weighted toward no allergies
    "Laktose", "Gluten", "Nüsse", "Erdnüsse", 
    "Keine Nüsse", "Soja", "Sellerie"
]

const MISC_NOTES = [
    "",  # No notes (most common)
    "", "", "", "", "", "", "", "", "",  # Weighted toward no notes
    "Komme später am Samstag",
    "Muss früher abreisen",
    "Benötige Fahrstuhl",
    "Kann beim Aufbau helfen",
    "Bringe Notenständer mit",
    "Erste Teilnahme"
]

# =============================================================================
# FIELD GENERATORS
# =============================================================================

"""
Generate a random field value based on the field name and available values.
Uses heuristics to determine appropriate values based on field name patterns.
"""
function generate_field_value(field_name::String; config_values::Union{Vector,Nothing}=nothing)
    field_lower = lowercase(field_name)
    
    # If we have config-defined values, use them
    if config_values !== nothing && !isempty(config_values)
        # Filter out empty values for weighted random selection
        non_empty = filter(v -> !isempty(strip(string(v))), config_values)
        if !isempty(non_empty)
            # For optional fields (like allergies, notes), sometimes return empty
            if occursin(r"sonstiges|allerg|bemerkung|anmerkung|wunsch"i, field_lower)
                return rand() < 0.7 ? "" : string(rand(non_empty))
            end
            return string(rand(config_values))
        end
    end
    
    # Fallback to heuristic-based generation
    if occursin(r"stimmgruppe|stimme|instrument"i, field_lower)
        return rand(VOICE_PARTS)
    elseif occursin(r"essen|verpflegung|mahlzeit"i, field_lower)
        return rand(FOOD_OPTIONS)
    elseif occursin(r"übernachtung|uebernachtung|nacht"i, field_lower)
        return rand(YES_NO_OPTIONS)
    elseif occursin(r"busfahrt|bus|transfer|shuttle"i, field_lower)
        return rand(YES_NO_OPTIONS)
    elseif occursin(r"zimmer|room|unterkunft"i, field_lower)
        return rand(ROOM_OPTIONS)
    elseif occursin(r"allerg|unverträg"i, field_lower)
        return rand(ALLERGIES)
    elseif occursin(r"sonstiges|bemerkung|anmerkung|hinweis"i, field_lower)
        return rand(MISC_NOTES)
    elseif occursin(r"belegung|zimmer.*wunsch"i, field_lower)
        # Room preference - usually empty or a name
        return rand() < 0.7 ? "" : "Mit $(rand(GERMAN_FIRST_NAMES))"
    else
        # For unknown fields, return "Ja" for yes/no-like fields, empty otherwise
        if occursin(r"\bja\b|\bnein\b|yes|no|\?"i, field_lower)
            return rand(YES_NO_OPTIONS)
        end
        return ""
    end
end

"""
Parse event configuration TOML file and extract field information.
Returns a dict mapping field names to their possible values (if any were found in comments).
"""
function parse_event_config_fields(event_id::String; events_dir::String="events")
    config_path = joinpath(events_dir, "$event_id.toml")
    if !isfile(config_path)
        return Dict{String, Any}()
    end
    
    config = TOML.parsefile(config_path)
    
    # Extract field information from aliases section
    fields = Dict{String, Any}()
    
    if haskey(config, "aliases")
        for (alias, actual_name) in config["aliases"]
            fields[string(actual_name)] = Dict{String, Any}(
                "alias" => string(alias),
                "actual_name" => string(actual_name)
            )
        end
    end
    
    # Extract cost rule fields to understand what fields are important
    if haskey(config, "costs") && haskey(config["costs"], "rules")
        for rule in config["costs"]["rules"]
            if haskey(rule, "field")
                field_alias = string(rule["field"])
                # Find the actual field name from aliases
                if haskey(config, "aliases") && haskey(config["aliases"], field_alias)
                    actual_name = string(config["aliases"][field_alias])
                    if !haskey(fields, actual_name)
                        fields[actual_name] = Dict{String, Any}("alias" => field_alias, "actual_name" => actual_name)
                    end
                    # If the rule has a value, note it as a valid option
                    if haskey(rule, "value")
                        if !haskey(fields[actual_name], "values")
                            fields[actual_name]["values"] = String[]
                        end
                        push!(fields[actual_name]["values"], string(rule["value"]))
                    end
                end
            end
        end
    end
    
    return fields
end

"""
Generate field values for a registration based on event configuration.
Returns a Dict of field_name => value for use in email generation.
"""
function generate_registration_fields(event_id::String; events_dir::String="events")
    config_fields = parse_event_config_fields(event_id; events_dir=events_dir)
    
    fields = Dict{String, String}()
    
    # Standard fields that are always present
    standard_fields = [
        "Stimmgruppe",
        "Essen",
        "Lebensmittelunverträglichkeiten / Allergien",
        "Übernachtung Freitag",
        "Übernachtung Samstag",
        "Busfahrt Hinweg (10€)",
        "Busfahrt Rückweg (10€)",
        "Wie möchte ich übernachten?",
        "Belegungswunsch für das Zimmer",
        "Sonstiges:"
    ]
    
    # Merge with config-discovered fields
    all_fields = Set(standard_fields)
    for (field_name, _) in config_fields
        push!(all_fields, field_name)
    end
    
    for field_name in all_fields
        config_values = nothing
        if haskey(config_fields, field_name) && haskey(config_fields[field_name], "values")
            config_values = config_fields[field_name]["values"]
        end
        fields[field_name] = generate_field_value(field_name; config_values=config_values)
    end
    
    return fields
end

# =============================================================================
# EMAIL GENERATION
# =============================================================================

"""
HTML-encode special characters for email content.
"""
function html_encode(s::String)
    s = replace(s, "&" => "&amp;")
    s = replace(s, "<" => "&lt;")
    s = replace(s, ">" => "&gt;")
    s = replace(s, "\"" => "&quot;")
    s = replace(s, "ä" => "&auml;")
    s = replace(s, "ö" => "&ouml;")
    s = replace(s, "ü" => "&uuml;")
    s = replace(s, "Ä" => "&Auml;")
    s = replace(s, "Ö" => "&Ouml;")
    s = replace(s, "Ü" => "&Uuml;")
    s = replace(s, "ß" => "&szlig;")
    s = replace(s, "€" => "&euro;")
    return s
end

"""
Generate a single registration email with random data.
Returns (filename, content, metadata) where metadata contains first_name, last_name, email for tracking.
"""
function generate_registration_email(event_id::String, index::Int; events_dir::String="events")
    # Generate unique person data
    first_name = rand(GERMAN_FIRST_NAMES)
    last_name = rand(GERMAN_LAST_NAMES)
    email_addr = lowercase("$(first_name).$(last_name).$(index)@example.com")
    
    # Generate registration fields
    fields = generate_registration_fields(event_id; events_dir=events_dir)
    
    # Build HTML table rows
    rows = String[]
    push!(rows, "<tr><td class=\"label\">Vorname</td><td>$(html_encode(first_name))</td></tr>")
    push!(rows, "<tr><td class=\"label\">Nachname</td><td>$(html_encode(last_name))</td></tr>")
    push!(rows, "<tr><td class=\"label\">E-Mail</td><td>$(html_encode(email_addr))</td></tr>")
    
    for (field_name, value) in fields
        push!(rows, "<tr><td class=\"label\">$(html_encode(field_name))</td><td>$(html_encode(value))</td></tr>")
    end
    
    email_content = """From: no-reply@form-service.example.com
To: recipient@example.com
Subject: Anmeldung: $event_id
Date: $(Dates.format(Dates.now() - Dates.Day(rand(1:30)), "e, dd u yyyy HH:MM:SS +0100"))
MIME-Version: 1.0
Content-Type: text/html; charset=UTF-8

<!DOCTYPE html>
<html>
<head>
    <style type="text/css">
        table { font-family: Arial, sans-serif; font-size: 10pt; }
        td, th { border: 1px solid #BBBBBB; padding: 5px 15px 5px 5px; vertical-align: top; }
        .label { font-weight: bold; }
        th { background-color: #f0f0f0; }
    </style>
</head>
<body>
<table style="border-collapse:collapse;">
    <tr><th colspan="2">Anmeldung: $event_id</th></tr>
    $(join(rows, "\n    "))
</table>
</body>
</html>
"""
    
    filename = "registration_$(event_id)_$(lpad(index, 4, '0')).eml"
    metadata = (
        first_name = first_name,
        last_name = last_name,
        email = email_addr,
        event_id = event_id,
        fields = fields
    )
    
    return (filename, email_content, metadata)
end

"""
Sample registration email templates for playground testing.
Returns a list of (filename, content) tuples.
"""
function generate_sample_emails(event_id::String="PWE_2026_01"; events_dir::String="events")
    samples = Tuple{String, String}[]
    
    for i in 1:3
        filename, content, _ = generate_registration_email(event_id, i; events_dir=events_dir)
        push!(samples, (filename, content))
    end
    
    return samples
end

# =============================================================================
# BANK TRANSFER GENERATION
# =============================================================================

"""
Generate a bank transfer CSV file with payments for existing registrations.
Creates transfers that match a specified percentage of registrations.

Arguments:
- db: Database connection
- output_path: Path to write the CSV file
- event_id: Optional event ID to filter registrations (nothing = all events)
- payment_rate: Fraction of registrations that should have matching payments (default 0.7)
- include_partial: Whether to include some partial payments (default true)
- include_overpay: Whether to include some overpayments (default false)

Returns the number of transfers generated.
"""
function generate_bank_transfers_csv(db::DuckDB.DB, output_path::String;
    event_id::Union{String,Nothing}=nothing,
    payment_rate::Float64=0.7,
    include_partial::Bool=true,
    include_overpay::Bool=false)
    
    # Get registrations with computed costs
    query = if event_id !== nothing
        """
        SELECT r.id, r.reference_number, r.first_name, r.last_name, r.computed_cost, r.event_id
        FROM registrations r
        WHERE r.event_id = ? AND r.deleted_at IS NULL AND r.computed_cost IS NOT NULL AND r.computed_cost > 0
        ORDER BY r.id
        """
    else
        """
        SELECT r.id, r.reference_number, r.first_name, r.last_name, r.computed_cost, r.event_id
        FROM registrations r
        WHERE r.deleted_at IS NULL AND r.computed_cost IS NOT NULL AND r.computed_cost > 0
        ORDER BY r.id
        """
    end
    
    params = event_id !== nothing ? [event_id] : []
    result = DBInterface.execute(db, query, params)
    registrations = collect(result)
    
    if isempty(registrations)
        @warn "No registrations with computed costs found for bank transfer generation"
        return 0
    end
    
    # Select registrations that will have payments
    num_to_pay = max(1, round(Int, length(registrations) * payment_rate))
    paying_registrations = registrations[randperm(length(registrations))[1:num_to_pay]]
    
    # Generate transfers
    transfers = []
    
    for reg in paying_registrations
        reg_id, ref_num, first_name, last_name, computed_cost, reg_event_id = reg
        cost = Float64(computed_cost)
        
        # Determine payment amount
        amount = cost
        if include_partial && rand() < 0.15
            # 15% chance of partial payment
            amount = round(cost * rand(0.5:0.1:0.9), digits=2)
        elseif include_overpay && rand() < 0.05
            # 5% chance of overpayment
            amount = round(cost * rand(1.01:0.01:1.2), digits=2)
        end
        
        # Generate transfer date (within last 30 days)
        transfer_date = Dates.today() - Dates.Day(rand(1:30))
        
        # Generate reference text variations
        ref_style = rand(1:4)
        reference_text = if ref_style == 1
            # Standard format with reference number
            ref_num
        elseif ref_style == 2
            # With event name
            "$(ref_num) Teilnahme"
        elseif ref_style == 3
            # With name and reference
            "$(first_name) $(last_name) $(ref_num)"
        else
            # Just name (harder to match automatically)
            "$(first_name) $(last_name) Event"
        end
        
        # Generate sender name
        sender_name = if rand() < 0.85
            # Usually the same person
            "$(first_name) $(last_name)"
        else
            # Sometimes a different person pays (spouse, parent, etc.)
            "$(rand(GERMAN_FIRST_NAMES)) $(last_name)"
        end
        
        # Generate fake IBAN
        sender_iban = "DE" * lpad(rand(10:99), 2, '0') * join([rand('0':'9') for _ in 1:18])
        
        push!(transfers, (
            transfer_date = transfer_date,
            amount = amount,
            sender_name = sender_name,
            sender_iban = sender_iban,
            reference_text = reference_text
        ))
    end
    
    # Add some unmatched transfers (noise)
    num_noise = max(1, round(Int, length(transfers) * 0.1))
    for _ in 1:num_noise
        transfer_date = Dates.today() - Dates.Day(rand(1:30))
        amount = round(rand(20.0:5.0:200.0), digits=2)
        sender_name = "$(rand(GERMAN_FIRST_NAMES)) $(rand(GERMAN_LAST_NAMES))"
        sender_iban = "DE" * lpad(rand(10:99), 2, '0') * join([rand('0':'9') for _ in 1:18])
        reference_text = rand([
            "Überweisung",
            "Zahlung",
            "Beitrag $(Dates.year(transfer_date))",
            "$(rand(GERMAN_FIRST_NAMES)) Mitgliedsbeitrag"
        ])
        
        push!(transfers, (
            transfer_date = transfer_date,
            amount = amount,
            sender_name = sender_name,
            sender_iban = sender_iban,
            reference_text = reference_text
        ))
    end
    
    # Shuffle and write CSV
    transfers = transfers[randperm(length(transfers))]
    
    lines = String[]
    push!(lines, "\"Auftragskonto\";\"Buchungstag\";\"Valutadatum\";\"Buchungstext\";\"Verwendungszweck\";\"Beguenstigter/Zahlungspflichtiger\";\"Kontonummer/IBAN\";\"BIC (SWIFT-Code)\";\"Betrag\";\"Waehrung\";\"Info\"")
    
    for t in transfers
        date_str = Dates.format(t.transfer_date, "dd.mm.yy")
        # Format amount with German decimal comma
        amount_str = replace(string(round(t.amount, digits=2)), "." => ",")
        
        line = "\"DE99123456789012345678\";\"$(date_str)\";\"$(date_str)\";\"GUTSCHR. UEBERWEISUNG\";\"$(t.reference_text)\";\"$(t.sender_name)\";\"$(t.sender_iban)\";\"DEUTDEFFXXX\";\"$(amount_str)\";\"EUR\";\"Umsatz gebucht\""
        push!(lines, line)
    end
    
    write(output_path, join(lines, "\n") * "\n")
    
    @info "Generated $(length(transfers)) bank transfers ($(num_to_pay) matching registrations, $(num_noise) noise)"
    
    return length(transfers)
end

# =============================================================================
# CLI COMMANDS
# =============================================================================

"""
Initialize a playground environment for testing.

Creates a complete playground environment with:
- Database and folder structure
- Sample event configuration
- Sample submission emails
- Email templates

Usage:
  eventreg playground init              # Initialize in current directory (if empty)
  eventreg playground init mytest       # Create new playground in ./mytest directory
"""
function cmd_playground_init(;
    playground_name::Union{String,Nothing}=nothing,
    db_path::String="events.duckdb",
    events_dir::String="events",
    force::Bool=false,
    from_repl::Bool=false,
    repl_has_db::Bool=true)
    
    # Prevent playground init from REPL mode when a database is already connected
    # However, allow it when REPL started without a database (limited mode)
    if from_repl && repl_has_db
        @error """playground init cannot be run from REPL mode when a database is connected.
        
DuckDB does not support switching between different database connections reliably.
Running 'playground init' from REPL would create a new database but the REPL
would remain connected to the current database, causing confusion.

Please exit the REPL (type 'exit' or press Ctrl-D) and run the command from the shell:
  eventreg playground init [name]

Then you can start a new REPL session in the playground directory if desired."""
        return 1
    end
    
    # Determine target directory
    target_dir = playground_name === nothing ? "." : playground_name
    abs_target = abspath(target_dir)
    
    # Check if directory exists and is not empty
    if isdir(abs_target)
        contents = readdir(abs_target)
        # Filter out hidden files for the emptiness check
        visible_contents = filter(f -> !startswith(f, "."), contents)
        if !isempty(visible_contents) && !force
            @error "Target directory is not empty. Use --force to initialize anyway, or provide a different playground name." directory=abs_target contents=visible_contents
            return 1
        end
    else
        # Create the directory if it doesn't exist
        mkpath(abs_target)
        @info "Created playground directory: $(abs_target)"
    end
    
    # Change to target directory for initialization
    original_dir = pwd()
    cd(abs_target)
    
    try
        @info "Initializing playground environment: $(abs_target)"
        
        # Create directory structure
        mkpath("emails")
        mkpath("events")
        mkpath("templates")
        mkpath("bank_transfers")
        
        # Initialize database
        @info "Creating database: $(db_path)"
        db = init_project(db_path, ".")
        
        # Mark this database as a playground
        set_setting!(db, "is_playground", "true")
        
        # Generate sample event config if events directory is empty
        event_configs = filter(f -> endswith(f, ".toml"), readdir(events_dir))
        if isempty(event_configs)
            @info "Creating sample event configuration..."
            sample_event_id = "PWE_2026_01"
            generate_event_config_template(sample_event_id, joinpath(events_dir, "$sample_event_id.toml"); db=db)
            
            # Sync the config to database
            sync_event_configs_to_db!(db, events_dir)
        end
        
        # Create sample credentials file
        cred_example_path = joinpath(original_dir, "credentials.toml.example")
        if isfile(cred_example_path)
            cp(cred_example_path, "credentials.toml.example", force=true)
            @info "Copied credentials.toml.example template"
        end
        
        DBInterface.close!(db)
        
        @info """
✓ Playground environment initialized successfully!

Directory structure:
  $(abs_target)/
    ├── events.duckdb          # Database
    ├── events/                # Event configurations
    ├── emails/                # Email submissions
    ├── templates/             # Email templates
    └── bank_transfers/        # Bank transfer CSVs

Next steps:
  1. Generate sample submissions:
     eventreg playground generate-registrations [count]
     
  2. Process the sample emails:
     eventreg process-emails
     
  3. Generate bank transfers:
     eventreg playground generate-bank-transfers
     
  4. View registrations:
     eventreg list-registrations
"""
        
        return 0
    catch e
        @error "Failed to initialize playground" exception=(e, catch_backtrace())
        return 1
    finally
        cd(original_dir)
    end
end

"""
List available events in the events directory.
Returns a list of event IDs.
"""
function list_available_events(events_dir::String="events")
    if !isdir(events_dir)
        return String[]
    end
    
    events = String[]
    for file in readdir(events_dir)
        if endswith(file, ".toml")
            push!(events, replace(file, ".toml" => ""))
        end
    end
    
    return events
end

"""
Generate and receive sample submission emails into the playground.

Creates sample registration email files in the emails/ directory for testing.
Now supports arbitrary counts and multiple events.

Usage:
  eventreg playground generate-registrations         # Generate 10 sample emails (default)
  eventreg playground generate-registrations 50      # Generate 50 sample emails
  eventreg playground generate-registrations 100 --event-id=PWE_2026_01  # For specific event
  eventreg playground generate-registrations 100 --all-events  # Distribute across all events
"""
function cmd_playground_receive_submissions(;
    count::Int=10,
    event_id::Union{String,Nothing}=nothing,
    all_events::Bool=false,
    emails_dir::String="emails",
    events_dir::String="events")
    
    if !isdir(emails_dir)
        @error "Emails directory not found. Initialize playground first with: eventreg playground init" directory=emails_dir
        return 1
    end
    
    # Determine event ID(s) to use
    target_events = String[]
    
    if all_events
        target_events = list_available_events(events_dir)
        if isempty(target_events)
            @warn "No event configurations found in $events_dir, using default event ID"
            target_events = ["PWE_2026_01"]
        end
    elseif event_id !== nothing
        target_events = [event_id]
    else
        # Try to find an event in the events directory
        available = list_available_events(events_dir)
        if !isempty(available)
            target_events = [available[1]]
        else
            target_events = ["PWE_2026_01"]
            @warn "No event configuration found, using default event ID" event_id=target_events[1]
        end
    end
    
    @info "Generating $(count) sample submission(s) for event(s): $(join(target_events, ", "))"
    
    # Generate emails distributed across events
    created = 0
    
    for i in 1:count
        # Select event (round-robin if multiple)
        evt = target_events[mod1(i, length(target_events))]
        
        filename, content, metadata = generate_registration_email(evt, i; events_dir=events_dir)
        
        filepath = joinpath(emails_dir, filename)
        write(filepath, content)
        created += 1
    end
    
    evt_list = length(target_events) == 1 ? target_events[1] : "$(length(target_events)) events"
    
    @info """
✓ Generated $created sample submission emails for $(evt_list)!

Emails saved to: $(abspath(emails_dir))

Next steps:
  1. Process the emails:
     eventreg process-emails
     
  2. Recalculate costs (if event config has cost rules):
     eventreg recalculate-costs $(target_events[1])
     
  3. Generate matching bank transfers:
     eventreg playground generate-bank-transfers
     
  4. View registrations:
     eventreg list-registrations
"""
    
    return 0
end

"""
Generate bank transfer CSV file with payments for existing registrations.

Creates a bank transfer CSV file that includes:
- Payments for a configurable percentage of existing registrations
- Various reference formats (to test matching algorithms)
- Some partial payments (optional)
- Some unrelated transfers (noise)

Usage:
  eventreg playground generate-bank-transfers                    # Default: 70% of registrations
  eventreg playground generate-bank-transfers --payment-rate=0.9 # 90% of registrations
  eventreg playground generate-bank-transfers --event-id=PWE_2026_01  # Specific event only
  eventreg playground generate-bank-transfers --output=transfers.csv  # Custom output file
"""
function cmd_playground_generate_bank_transfers(db::DuckDB.DB;
    event_id::Union{String,Nothing}=nothing,
    output::Union{String,Nothing}=nothing,
    payment_rate::Float64=0.7,
    include_partial::Bool=true,
    bank_dir::String="bank_transfers")
    
    if !isdir(bank_dir)
        mkpath(bank_dir)
    end
    
    # Determine output path
    output_path = if output !== nothing
        output
    else
        timestamp = Dates.format(Dates.now(), "yyyymmdd_HHMMSS")
        joinpath(bank_dir, "transfers_$(timestamp).csv")
    end
    
    # Generate transfers
    num_generated = generate_bank_transfers_csv(db, output_path;
        event_id=event_id,
        payment_rate=payment_rate,
        include_partial=include_partial)
    
    if num_generated == 0
        @warn "No transfers generated. Make sure there are registrations with computed costs."
        @info """
To generate transfers:
  1. First generate and process registration emails:
     eventreg playground generate-registrations
     eventreg process-emails
     
  2. Make sure event config has cost rules and recalculate:
     eventreg recalculate-costs <event-id>
     
  3. Then generate transfers:
     eventreg playground generate-bank-transfers
"""
        return 1
    end
    
    @info """
✓ Generated bank transfer CSV: $(abspath(output_path))

Transfers include:
- $(round(Int, payment_rate * 100))% of registrations with matching payments
- Various reference number formats (for testing matching)
$(include_partial ? "- Some partial payments" : "")
- Some unrelated transfers (noise)

Next steps:
  1. Import the transfers:
     eventreg import-bank-csv $(output_path)
     
  2. Match transfers to registrations:
     eventreg match-transfers
     
  3. View payment status:
     eventreg export-payment-status
"""
    
    return 0
end
