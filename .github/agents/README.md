# GitHub Copilot Agents Configuration

This directory contains the configuration for GitHub Copilot agents working with this Julia project.

## Configuration Files

- `config.yml`: Main configuration file that defines the setup and firewall rules
- `setup.sh`: Shell script for automated Julia environment setup

## Setup

The configuration automatically:

1. **Installs juliaup**: The Julia version manager that allows easy installation and switching between Julia versions
2. **Installs Julia v1.12**: The version required by this project (as specified in `Project.toml`)
3. **Configures firewall**: Allows access to `julialang.org` and related domains for package downloads

## Firewall Configuration

The following domains are whitelisted:
- `julialang.org` - Main Julia website
- `*.julialang.org` - All Julia subdomains
- `pkg.julialang.org` - Julia package registry

Allowed ports: 80 (HTTP) and 443 (HTTPS)

## Manual Setup

If you need to run the setup manually:

```bash
bash .github/agents/setup.sh
```

## Environment Variables

The following environment variables are set:
- `JULIA_VERSION`: Set to "1.12"
- `JULIAUP_BIN`: Points to the juliaup binary directory

## Requirements

- `curl`: For downloading juliaup installer
- Internet access to `julialang.org`
