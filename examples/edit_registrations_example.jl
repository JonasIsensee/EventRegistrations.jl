#!/usr/bin/env julia
# =============================================================================
# Edit-Registrations (TableEdit) — Runnable Example
# =============================================================================
#
# This script demonstrates the edit-registrations flow without opening an
# interactive editor: it uses spawn_editor=false, edits the temp file in code,
# then applies the changes. Run from EventRegistrations.jl with the project
# activated.
#
# Usage:
#   cd EventRegistrations.jl
#   julia --project=. examples/edit_registrations_example.jl
#
# Or with a data directory that has events.duckdb and registrations:
#   julia --project=. examples/edit_registrations_example.jl /path/to/data
# =============================================================================

using EventRegistrations
using DBInterface

function main()
    # Use test/assets (copy to temp first) or first argument
    if length(ARGS) >= 1
        data_dir = ARGS[1]
        db_path = joinpath(data_dir, "events.duckdb")
    else
        # Create a temporary directory with test assets
        assets_dir = joinpath(@__DIR__, "..", "test", "assets")
        if !isdir(assets_dir)
            println("Assets directory not found: $assets_dir")
            println("Pass a directory that has events.duckdb as an argument")
            return 1
        end
        
        data_dir = mktempdir()
        println("Created temporary data directory: $data_dir")
        
        # Copy test assets to temp directory
        cp(joinpath(assets_dir, "events"), joinpath(data_dir, "events"), force=true)
        cp(joinpath(assets_dir, "emails"), joinpath(data_dir, "emails"), force=true)
        cp(joinpath(assets_dir, "bank_transfers"), joinpath(data_dir, "bank_transfers"), force=true)
        cp(joinpath(assets_dir, "templates"), joinpath(data_dir, "templates"), force=true)
        if isfile(joinpath(assets_dir, "credentials.toml"))
            cp(joinpath(assets_dir, "credentials.toml"), joinpath(data_dir, "credentials.toml"), force=true)
        end
        
        db_path = joinpath(data_dir, "events.duckdb")
        
        # Initialize the database for this example
        db = EventRegistrations.init_database(db_path)
        try
            # Setup event configuration
            EventRegistrations.sync_event_configs_to_db!(db, joinpath(data_dir, "events"))
            # Process some emails to have data
            EventRegistrations.process_email_folder!(db, joinpath(data_dir, "emails"))
        finally
            DBInterface.close!(db)
        end
    end

    if !isfile(db_path)
        println("Database not found: $db_path")
        println("Pass a directory that has events.duckdb as an argument")
        return 1
    end

    println("Edit-registrations example (spawn_editor=false)")
    println("Data dir: ", data_dir)
    println("DB: ", db_path)
    println()

    # Call edit-registrations with spawn_editor=false → (path, finish_and_apply)
    db = EventRegistrations.init_database(db_path)
    try
        result = EventRegistrations.cmd_edit_registrations(db;
            event_id = "PWE_2026_01",
            spawn_editor = false,
        )
    finally
        DBInterface.close!(db)
    end

    if !(result isa Tuple)
        println("Unexpected result (no path returned): ", result)
        return 1
    end

    path, finish_and_apply = result
    println("Temp file: ", path)
    println("Content (first 5 lines):")
    for (i, line) in enumerate(eachline(path))
        i > 5 && break
        println("  ", line)
    end
    println("  ...")
    println()

    # Open DB again (require_database closed it) so we can call finish_and_apply(db)
    db = EventRegistrations.init_database(db_path)
    try
        # Simulate an edit: change first data row's email to example-edited@test.de
        content = read(path, String)
        lines = split(content, '\n')
        # Find first data row (after comment/header/separator)
        header_idx = 0
        for (i, line) in enumerate(lines)
            stripped = strip(line)
            if !startswith(stripped, "#") && !isempty(stripped)
                header_idx = i
                break
            end
        end
        first_data_idx = header_idx + 2
        if first_data_idx <= length(lines)
            parts = split(lines[first_data_idx], '\t')
            if length(parts) >= 3
                old_email = parts[3]
                parts[3] = "example-edited@test.de"
                lines[first_data_idx] = join(parts, '\t')
                write(path, join(lines, '\n'))
                println("Simulated edit: email \"", old_email, "\" → \"example-edited@test.de\"")
            end
        end

        # Parse and apply
        code, n = finish_and_apply(db)
        println()
        if code == 0
            println("Applied ", n, " registration update(s).")
            # Verify
            r = DBInterface.execute(db, "SELECT id, email FROM registrations WHERE email = ?",
                ["example-edited@test.de"]) |> collect
            if !isempty(r)
                println("DB now has: id=", r[1][1], " email=", r[1][2])
            end
        else
            println("Apply failed (exit code ", code, ").")
        end
    finally
        DBInterface.close!(db)
    end

    return 0
end

exit(main())
