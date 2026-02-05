# Playground commands for testing and development

"""
Sample registration email templates for playground testing.
Returns a list of (filename, content) tuples.
"""
function generate_sample_emails(event_id::String="PWE_2026_01")
    samples = Tuple{String, String}[]
    
    # Sample 1: Full registration with all options
    email1 = """From: no-reply@clubdesk.com
To: recipient@example.com
Subject: Anmeldung: $event_id
Date: $(Dates.format(Dates.now() - Dates.Day(3), "e, dd u yyyy HH:MM:SS +0100"))
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
    <tr><td class="label">Vorname</td><td>Anna</td></tr>
    <tr><td class="label">Nachname</td><td>Schmidt</td></tr>
    <tr><td class="label">E-Mail</td><td>anna.schmidt@example.de</td></tr>
    <tr><td class="label">Stimmgruppe</td><td>Violine 1</td></tr>
    <tr><td class="label">Essen</td><td>Alles</td></tr>
    <tr><td class="label">Lebensmittelunvertr&auml;glichkeiten / Allergien</td><td></td></tr>
    <tr><td class="label">&Uuml;bernachtung Freitag</td><td>Ja</td></tr>
    <tr><td class="label">&Uuml;bernachtung Samstag</td><td>Ja</td></tr>
    <tr><td class="label">Busfahrt Hinweg (10&euro;)</td><td>Ja</td></tr>
    <tr><td class="label">Busfahrt R&uuml;ckweg (10&euro;)</td><td>Ja</td></tr>
    <tr><td class="label">Wie m&ouml;chte ich &uuml;bernachten?</td><td>Mehrbettzimmer</td></tr>
    <tr><td class="label">Belegungswunsch f&uuml;r das Zimmer</td><td></td></tr>
    <tr><td class="label">Sonstiges:</td><td></td></tr>
</table>
</body>
</html>
"""
    push!(samples, ("registration_001.eml", email1))
    
    # Sample 2: Registration with different options
    email2 = """From: no-reply@clubdesk.com
To: recipient@example.com
Subject: Anmeldung: $event_id
Date: $(Dates.format(Dates.now() - Dates.Day(2), "e, dd u yyyy HH:MM:SS +0100"))
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
    <tr><td class="label">Vorname</td><td>Max</td></tr>
    <tr><td class="label">Nachname</td><td>M&uuml;ller</td></tr>
    <tr><td class="label">E-Mail</td><td>max.mueller@example.de</td></tr>
    <tr><td class="label">Stimmgruppe</td><td>Kontrabass</td></tr>
    <tr><td class="label">Essen</td><td>Vegetarisch</td></tr>
    <tr><td class="label">Lebensmittelunvertr&auml;glichkeiten / Allergien</td><td>Laktose</td></tr>
    <tr><td class="label">&Uuml;bernachtung Freitag</td><td>Nein</td></tr>
    <tr><td class="label">&Uuml;bernachtung Samstag</td><td>Ja</td></tr>
    <tr><td class="label">Busfahrt Hinweg (10&euro;)</td><td>Nein</td></tr>
    <tr><td class="label">Busfahrt R&uuml;ckweg (10&euro;)</td><td>Ja</td></tr>
    <tr><td class="label">Wie m&ouml;chte ich &uuml;bernachten?</td><td>Einzelzimmer (+10 &euro; pro Nacht)</td></tr>
    <tr><td class="label">Belegungswunsch f&uuml;r das Zimmer</td><td></td></tr>
    <tr><td class="label">Sonstiges:</td><td>Komme sp&auml;ter am Samstag</td></tr>
</table>
</body>
</html>
"""
    push!(samples, ("registration_002.eml", email2))
    
    # Sample 3: Minimal registration
    email3 = """From: no-reply@clubdesk.com
To: recipient@example.com
Subject: Anmeldung: $event_id
Date: $(Dates.format(Dates.now() - Dates.Day(1), "e, dd u yyyy HH:MM:SS +0100"))
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
    <tr><td class="label">Vorname</td><td>Lisa</td></tr>
    <tr><td class="label">Nachname</td><td>Weber</td></tr>
    <tr><td class="label">E-Mail</td><td>lisa.weber@example.de</td></tr>
    <tr><td class="label">Stimmgruppe</td><td>Viola</td></tr>
    <tr><td class="label">Essen</td><td>Alles</td></tr>
    <tr><td class="label">Lebensmittelunvertr&auml;glichkeiten / Allergien</td><td></td></tr>
    <tr><td class="label">&Uuml;bernachtung Freitag</td><td>Nein</td></tr>
    <tr><td class="label">&Uuml;bernachtung Samstag</td><td>Nein</td></tr>
    <tr><td class="label">Busfahrt Hinweg (10&euro;)</td><td>Nein</td></tr>
    <tr><td class="label">Busfahrt R&uuml;ckweg (10&euro;)</td><td>Nein</td></tr>
    <tr><td class="label">Wie m&ouml;chte ich &uuml;bernachten?</td><td></td></tr>
    <tr><td class="label">Belegungswunsch f&uuml;r das Zimmer</td><td></td></tr>
    <tr><td class="label">Sonstiges:</td><td></td></tr>
</table>
</body>
</html>
"""
    push!(samples, ("registration_003.eml", email3))
    
    return samples
end

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
    from_repl::Bool=false)
    
    # Prevent playground init from REPL mode due to DuckDB connection issues
    if from_repl
        @error """playground init cannot be run from REPL mode.
        
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
        @info "Created playground directory" directory=abs_target
    end
    
    # Change to target directory for initialization
    original_dir = pwd()
    cd(abs_target)
    
    try
        @info "Initializing playground environment..." directory=abs_target
        
        # Create directory structure
        mkpath("emails")
        mkpath("events")
        mkpath("templates")
        mkpath("bank_transfers")
        
        # Initialize database
        @info "Creating database..." path=db_path
        db = init_project(db_path, ".")
        
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
     eventreg playground receive-submissions [count]
     
  2. Process the sample emails:
     eventreg process-emails
     
  3. View registrations:
     eventreg list-registrations
     
  4. Explore other commands:
     eventreg --help
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
Generate and receive sample submission emails into the playground.

Creates sample registration email files in the emails/ directory for testing.

Usage:
  eventreg playground receive-submissions       # Generate 3 sample emails (default)
  eventreg playground receive-submissions 10    # Generate 10 sample emails
"""
function cmd_playground_receive_submissions(;
    count::Int=3,
    event_id::Union{String,Nothing}=nothing,
    emails_dir::String="emails")
    
    if !isdir(emails_dir)
        @error "Emails directory not found. Initialize playground first with: eventreg playground init" directory=emails_dir
        return 1
    end
    
    # Determine event ID
    if event_id === nothing
        # Try to find an event in the events directory
        events_path = "events"
        if isdir(events_path)
            event_configs = filter(f -> endswith(f, ".toml"), readdir(events_path))
            if !isempty(event_configs)
                # Use the first event found, removing .toml extension
                event_id = replace(event_configs[1], ".toml" => "")
            end
        end
        
        # Fallback to default
        if event_id === nothing
            event_id = "PWE_2026_01"
            @warn "No event configuration found, using default event ID" event_id=event_id
        end
    end
    
    @info "Generating sample submissions..." count=count event_id=event_id
    
    # Generate the base samples
    base_samples = generate_sample_emails(event_id)
    
    # If count is more than base samples, create variations
    samples = Tuple{String, String}[]
    names = ["Anna Schmidt", "Max Müller", "Lisa Weber", "Tim Fischer", "Sarah Klein", 
             "Jonas Berg", "Emma Schneider", "Paul Hoffmann", "Laura Bauer", "Felix Koch"]
    instruments = ["Violine 1", "Violine 2", "Viola", "Cello", "Kontrabass", "Flöte", "Oboe", "Klarinette"]
    
    for i in 1:count
        if i <= length(base_samples)
            # Use base samples
            push!(samples, base_samples[i])
        else
            # Generate variations
            name_parts = split(names[mod1(i, length(names))], " ")
            first_name = name_parts[1]
            last_name = name_parts[2]
            instrument = instruments[mod1(i, length(instruments))]
            email_addr = lowercase("$(first_name).$(last_name)@example.de")
            
            # Vary the options
            fri_night = mod(i, 2) == 0 ? "Ja" : "Nein"
            sat_night = mod(i, 3) != 0 ? "Ja" : "Nein"
            bus_there = mod(i, 2) == 0 ? "Ja" : "Nein"
            bus_back = mod(i, 3) == 0 ? "Ja" : "Nein"
            room_type = mod(i, 2) == 0 ? "Mehrbettzimmer" : "Einzelzimmer (+10 &euro; pro Nacht)"
            
            email_content = """From: no-reply@clubdesk.com
To: recipient@example.com
Subject: Anmeldung: $event_id
Date: $(Dates.format(Dates.now() - Dates.Day(count - i + 1), "e, dd u yyyy HH:MM:SS +0100"))
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
    <tr><td class="label">Vorname</td><td>$first_name</td></tr>
    <tr><td class="label">Nachname</td><td>$last_name</td></tr>
    <tr><td class="label">E-Mail</td><td>$email_addr</td></tr>
    <tr><td class="label">Stimmgruppe</td><td>$instrument</td></tr>
    <tr><td class="label">Essen</td><td>Alles</td></tr>
    <tr><td class="label">Lebensmittelunvertr&auml;glichkeiten / Allergien</td><td></td></tr>
    <tr><td class="label">&Uuml;bernachtung Freitag</td><td>$fri_night</td></tr>
    <tr><td class="label">&Uuml;bernachtung Samstag</td><td>$sat_night</td></tr>
    <tr><td class="label">Busfahrt Hinweg (10&euro;)</td><td>$bus_there</td></tr>
    <tr><td class="label">Busfahrt R&uuml;ckweg (10&euro;)</td><td>$bus_back</td></tr>
    <tr><td class="label">Wie m&ouml;chte ich &uuml;bernachten?</td><td>$room_type</td></tr>
    <tr><td class="label">Belegungswunsch f&uuml;r das Zimmer</td><td></td></tr>
    <tr><td class="label">Sonstiges:</td><td></td></tr>
</table>
</body>
</html>
"""
            filename = "registration_$(lpad(i, 3, '0')).eml"
            push!(samples, (filename, email_content))
        end
    end
    
    # Write email files
    created = 0
    for (filename, content) in samples
        filepath = joinpath(emails_dir, filename)
        write(filepath, content)
        created += 1
    end
    
    @info """
✓ Generated $created sample submission emails!

Emails saved to: $(abspath(emails_dir))

Next steps:
  1. Process the emails:
     eventreg process-emails
     
  2. View registrations:
     eventreg list-registrations
     
  3. View event overview:
     eventreg event-overview $event_id
"""
    
    return 0
end
