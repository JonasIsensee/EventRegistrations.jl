using TOML

Base.@kwdef struct EmailConfig
    pop3_server::String = ""
    pop3_username::String = ""
    pop3_password::String = ""
    pop3_port::Int = 995
    smtp_server::String = ""
    smtp_port::Int = 587
    username::String = ""
    password::String = ""
    from_address::String = ""
    from_name::String = "Event Registration"
    bank_details::String = ""
    additional_info::String = ""
    account_name::String = ""
    iban::String = ""
    bic::String = ""
    bank_name::String = ""
    qr_message::String = ""
    qr_enabled::Bool = true
    dry_run::Bool = true
    templates_dir::String = "config/templates"
end

Base.@kwdef struct AppConfig
    db_path::String = "events.duckdb"
    config_dir::String = "config"
    email::EmailConfig = EmailConfig()
    log_level::Symbol = :info
end

function select_credentials_path(credentials_path::Union{String,Nothing}, config_dir::String)
    candidates = credentials_path === nothing ? [
        "credentials.toml",
    ] : [credentials_path]

    for p in candidates
        if isfile(p)
            return p
        end
    end
    return nothing
end

function parse_email_config(config::Dict; templates_dir::String, dry_run::Bool)
    email_section = get(config, "email", Dict())
    smtp_section = get(config, "smtp", Dict())
    bank_section = get(config, "bank", Dict())

    pop3_server = get(email_section, "server", "")
    pop3_username = get(email_section, "username", "")
    pop3_password = get(email_section, "password", "")
    pop3_port = get(email_section, "port", 995)

    smtp_server = get(smtp_section, "server", pop3_server)
    smtp_port = get(smtp_section, "port", 587)
    username = get(smtp_section, "username", pop3_username)
    password = get(smtp_section, "password", pop3_password)
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

    return EmailConfig(;
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

function load_app_config(; config_dir::String="config", db_path::String="events.duckdb",
                         credentials_path::String="credentials.toml",
                         templates_dir::Union{String,Nothing}=nothing,
                         dry_run::Bool=true)
    resolved_templates_dir = templates_dir === nothing ? joinpath(config_dir, "templates") : templates_dir

    email_cfg = if isfile(credentials_path)
        parse_email_config(TOML.parsefile(credentials_path);
                           templates_dir=resolved_templates_dir,
                           dry_run)
    else
        EmailConfig(; dry_run, templates_dir=resolved_templates_dir)
    end

    return AppConfig(
        db_path,
        config_dir,
        email_cfg,
        :info,
    )
end
