#!/bin/bash
set -euo pipefail

echo "Setting up Julia environment for GitHub Copilot agents..."

# Install juliaup if not already installed
if ! command -v juliaup &> /dev/null; then
    echo "Installing juliaup..."
    curl -fsSL https://install.julialang.org | sh -s -- -y
    export PATH="$HOME/.juliaup/bin:$PATH"
fi

# Add juliaup to PATH for future sessions
if [ -d "$HOME/.juliaup/bin" ]; then
    export PATH="$HOME/.juliaup/bin:$PATH"
fi

# Install Julia v1.12
echo "Installing Julia v1.12..."
juliaup add 1.12
juliaup default 1.12

# Verify installation
echo "Verifying Julia installation..."
julia --version

echo "Julia setup complete!"
