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
    
    return samples
end

"""Placeholder - complete version requires full file from API"""
function cmd_playground_init(;kwargs...)
    error("Not fully implemented - rebasing in progress")
end

function cmd_playground_receive_submissions(;kwargs...)
    error("Not fully implemented - rebasing in progress")
end
