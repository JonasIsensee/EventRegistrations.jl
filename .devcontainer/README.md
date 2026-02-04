# Dev Container Configuration

This directory contains the configuration for GitHub Codespaces and VS Code Dev Containers.

## What's included

When you start a new Codespace or open this repository in a Dev Container, the following will be automatically set up:

- **juliaup**: The Julia version manager
- **Julia v1.12**: The required Julia version for this project
- **Project dependencies**: All Julia packages specified in `Project.toml` will be installed
- **VS Code Julia extension**: For enhanced Julia development experience

## Setup Process

1. The container is built using Ubuntu 22.04 as the base image
2. Common utilities (including zsh and oh-my-zsh) are installed
3. The `setup.sh` script runs to install juliaup and Julia v1.12
4. Project dependencies are installed with `Pkg.instantiate()`

## Usage

### GitHub Codespaces

Simply create a new Codespace from this repository, and everything will be set up automatically.

### VS Code Dev Containers

1. Install the "Dev Containers" extension in VS Code
2. Open this repository
3. Click "Reopen in Container" when prompted (or use the Command Palette: "Dev Containers: Reopen in Container")

## Customization

- `devcontainer.json`: Main configuration file
- `setup.sh`: Script that runs after the container is created to install Julia and dependencies

## Troubleshooting

If Julia is not found after setup:
- Try opening a new terminal
- Check that `$HOME/.juliaup/bin` is in your PATH
- Run `source ~/.bashrc` to reload your shell configuration
