using TOML

struct EmailConfig
    pop3_server::String
    pop3_username::String
    pop3_password::String
    pop3_port::Int
    smtp_server::String
    smtp_port::Int
    username::String
    password::String
    from_address::String
    from_name::String
    bank_details::String
    additional_info::String
    account_name::String
    iban::String
    bic::String
    bank_name::String
    qr_message::String
    qr_enabled::Bool
    dry_run::Bool
    templates_dir::String
end

struct AppConfig
    db_path::String
    email::EmailConfig
    log_level::Symbol
end

function parse_email_config(config::Dict; templates_dir::String, dry_run::Bool)
    email_section = get(config, "email", Dict())
    smtp_section = get(config, "smtp", Dict())
    bank_section = get(config, "bank", Dict())

    pop3_server = get(email_section, "server", "")
    pop3_username = get(email_section, "username", "")
    pop3_password = get(email_section, "password", "")
    pop3_port = get(email_section, "port", 995)

    smtp_server = get(smtp_section, "server", "")
    smtp_port = get(smtp_section, "port", 587)
    username = get(smtp_section, "username", "")
    password = get(smtp_section, "password", "")
    from_address = get(smtp_section, "from_address", username)
    from_name = get(smtp_section, "from_name", "Event Registration")
    bank_details = get(smtp_section, "bank_details", "")
    additional_info = get(smtp_section, "additional_info", "")

    account_name = get(bank_section, "account_name", from_name)
    iban = replace(get(bank_section, "iban", ""), ' ' => "")
    bic = get(bank_section, "bic", "")
    bank_name = get(bank_section, "bank_name", "")
    qr_message = get(bank_section, "remittance", "")
    qr_enabled = get(bank_section, "enable_qr", true)

    return EmailConfig(
        pop3_server, pop3_username, pop3_password, pop3_port,
        smtp_server, smtp_port, username, password,
        from_address,
        from_name,
        bank_details,
        additional_info,
        account_name,
        iban,
        bic,
        bank_name,
        qr_message,
        qr_enabled,
        dry_run,
        templates_dir,
    )
end

function load_app_config(; db_path::String="events.duckdb",
                         credentials_path::String="credentials.toml",
                         templates_dir::Union{String,Nothing}=nothing,
                         dry_run::Bool=true)
    templates_dir = something(templates_dir, "templates")
    config_dict = isfile(credentials_path) ? TOML.parsefile(credentials_path) : Dict()
    email_cfg = parse_email_config(config_dict; templates_dir, dry_run)
    return AppConfig(db_path, email_cfg, :info)
end
