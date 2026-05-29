#!/bin/bash
set -e

echo "=== Citadel Workshop — Post-Create Setup ==="

# Install Azure Developer CLI
echo "Installing Azure Developer CLI (azd)..."
curl -fsSL https://aka.ms/install-azd.sh | bash

# Install workshop Python dependencies using uv
echo "Installing Python dependencies from workshop/pyproject.toml..."
cd workshop
uv sync
cd ..

# Verify tool versions
echo ""
echo "=== Environment verification ==="
echo "Python:  $(python --version)"
echo "az CLI:  $(az --version 2>&1 | head -1)"
echo "azd:     $(azd version)"
echo "dotnet:  $(dotnet --version)"
echo "node:    $(node --version)"
echo "git:     $(git --version)"
echo ""
echo "=== Setup complete. Run 'az login' and 'azd auth login' to authenticate. ==="
