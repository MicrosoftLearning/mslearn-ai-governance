---
title: Citadel AI Governance Hub - Lab setup guide
layout: page
---

# Lab setup guide

Complete these steps **before** the lab day to ensure a smooth experience. When you are done, return to the [hands-on lab guide](readme.md).

> ✅ **Assumed knowledge:** This lab assumes participants have a working understanding of the Azure services used by Citadel (API Management, AI Foundry, Cosmos DB, Key Vault, Event Hub, etc.) and are comfortable using the tools listed below. You do not need to be a subject-matter expert, but Azure fundamentals are outside the scope of this lab.

## Azure Requirements

| Requirement | Details |
|-------------|---------|
| **Azure Subscription** | You need an Azure subscription where you can deploy resources at subscription scope |
| **Deployment Permissions** | Use **Owner** permissions, or **Contributor** plus **User Access Administrator**, because `azd up` creates managed identities and assigns RBAC roles |
| **Sufficient Quota** | Quota for Azure OpenAI / AI Foundry model deployments (GPT-4.1, DeepSeek-R1, etc.) in the target region |
| **Resource Providers** | Several resource providers must be registered (see [Register Azure Resource Providers](#register-azure-resource-providers)) |

<details markdown="1">
<summary><strong>Why these deployment permissions are required</strong></summary>

The deployment creates user-assigned managed identities for API Management and usage-processing workloads (`id-apim-*` and `id-logicapp-*` by default). It also enables system-assigned identities on services such as AI Foundry projects and the Logic App.

During `azd up`, Bicep assigns roles to these identities, including:

- **Cognitive Services User** and **Cognitive Services OpenAI User** for the APIM managed identity.
- **Azure Event Hubs Data Sender** for the APIM managed identity.
- **Azure Event Hubs Data Owner** and **Monitoring Reader** for the usage-processing Logic App identity.
- **Cosmos DB Built-in Data Contributor** on the Cosmos DB SQL account for usage ingestion.
- **Key Vault Secrets User** for APIM and AI Foundry identities.
- **Key Vault Certificates Officer** for AI Foundry identities.
- **Azure AI Project Manager** for the deployer on AI Foundry resources.

Creating these role assignments requires `Microsoft.Authorization/roleAssignments/write`, which is included in **Owner** or **User Access Administrator**.

</details>

## Lab Environment Requirements

You can run the lab from your local machine or from the included Devcontainer.

<details open markdown="1">
<summary><strong>Option A — Local machine</strong></summary>

| Tool | Purpose | Install Link |
|------|---------|-------------|
| **Azure CLI** (`az`) | Authenticate and manage Azure resources | [Install Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) |
| **Azure Developer CLI** (`azd`) | Deploy Citadel infrastructure | [Install azd](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd) |
| **Python 3.13+** | Run validation notebooks | [python.org](https://www.python.org/downloads/) |
| **VS Code** | Code editor and notebook runner | [code.visualstudio.com](https://code.visualstudio.com/) |
| **Git** | Clone the repository | [git-scm.com](https://git-scm.com/downloads) |

**VS Code Extensions (recommended):**
- Python
- Jupyter
- Bicep

</details>

<details markdown="1">
<summary><strong>Option B — Devcontainer</strong></summary>

Use the included [Devcontainer](../.devcontainer/devcontainer.json) for a preconfigured VS Code environment with Azure CLI, Azure Developer CLI, Python 3.13, Jupyter, Bicep, Node.js, Git, and lab dependencies.

1. Install [VS Code](https://code.visualstudio.com/), [Docker Desktop](https://www.docker.com/products/docker-desktop/), and the [Dev Containers extension](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers).
2. Open the repository root in VS Code.
3. Start Docker Desktop and wait until Docker is running.
4. Choose **Reopen in Container** when prompted, or run **Dev Containers: Reopen in Container** from the command palette.
5. After the container starts, run `az login` and `azd auth login` before provisioning or running notebooks.

</details>

## Network Requirements

- Ability to connect to the Internet and Azure services
- You can use Wi-Fi provided by the lab organizer or your own connectivity (e.g. if you are running this lab from home)

## Register Azure Resource Providers

Some Azure resource providers need to be registered before deployment. Run these commands in your terminal:

```bash
# Login to Azure
az login

# Select your subscription
az account set --subscription "<your-subscription-name-or-id>"

# Register required resource providers
az provider register --namespace Microsoft.AlertsManagement
az provider register --namespace Microsoft.ApiManagement
az provider register --namespace Microsoft.CognitiveServices
az provider register --namespace Microsoft.DocumentDB
az provider register --namespace Microsoft.EventHub
az provider register --namespace Microsoft.Insights
az provider register --namespace Microsoft.KeyVault
az provider register --namespace Microsoft.MachineLearningServices
az provider register --namespace Microsoft.ManagedIdentity
az provider register --namespace Microsoft.Network
az provider register --namespace Microsoft.OperationalInsights
az provider register --namespace Microsoft.Storage
az provider register --namespace Microsoft.Web
az provider register --namespace Microsoft.Logic
az provider register --namespace Microsoft.Cache

# Verify registration (may take a few minutes to complete)
az provider list --query "[?registrationState=='Registered'].namespace" -o table
```

## Verify Tool Installation

Run these commands to confirm all tools are installed:

```bash
az --version
azd version
python --version
git --version
code --version
```

When your prerequisites are in place, return to the [hands-on lab guide](readme.md) and continue with **Deploy Citadel to your Azure subscription**.
