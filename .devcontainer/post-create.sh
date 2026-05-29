#!/bin/bash
set -e

echo "=== Citadel Workshop — Post-Create Setup ==="

# Install Azure Developer CLI
# Run the installer as root so it doesn't emit "Permission denied" /
# "requires elevated permission" warnings while it self-escalates to write
# into /opt/microsoft and /usr/local/bin.
echo "Installing Azure Developer CLI (azd)..."
curl -fsSL https://aka.ms/install-azd.sh | sudo bash

# On Debian trixie the devcontainer azure-cli feature falls back to the distro
# python3-azure-cli package, which is broken under Python 3.13 (monitor module
# ord() error, missing azure.mgmt.rdbms.mysql_flexibleservers, etc.). Detect
# and replace it with Microsoft's official build pinned to the bookworm repo.
if dpkg -l python3-azure-cli >/dev/null 2>&1; then
    echo "Replacing distro python3-azure-cli with Microsoft official azure-cli..."
    sudo apt-get remove -y azure-cli python3-azure-cli python3-azure-cli-core python3-azure-cli-telemetry || true
    sudo apt-get install -y ca-certificates curl apt-transport-https lsb-release gnupg
    sudo mkdir -p /etc/apt/keyrings
    curl -sLS https://packages.microsoft.com/keys/microsoft.asc | \
        gpg --dearmor | sudo tee /etc/apt/keyrings/microsoft.gpg > /dev/null
    sudo chmod go+r /etc/apt/keyrings/microsoft.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ bookworm main" | \
        sudo tee /etc/apt/sources.list.d/azure-cli.list > /dev/null
    sudo apt-get update
    sudo apt-get install -y azure-cli
fi

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
