# Citadel Governance Hub - Testing & Validation Guide

## Executive Summary

This testing suite provides a comprehensive, end-to-end validation framework for the Citadel Governance Hub — an enterprise-grade AI gateway built on Azure API Management (APIM). The notebooks in this directory enable platform teams to onboard LLM backends, provision access contracts for different business units, test agent framework integrations, and verify PII processing capabilities — all through guided, reproducible Jupyter workflows.

The recommended execution order is:

1. **Backend Onboarding** — Register AI backends and deploy routing logic into APIM
2. **Access Contracts** — Create per-team access contracts with Key Vault and Foundry integrations
3. **Agent Frameworks** — Validate agent-based consumption of provisioned contracts
4. **PII Processing** — Test PII anonymization, deanonymization, and blocking policies

Each notebook is self-contained with initialization, deployment, testing, visualization, and cleanup stages, enabling both interactive exploration and repeatable CI/CD validation.

---

## Prerequisites

Before running any notebook, ensure the following are in place:

- **Citadel Governance Hub** deployed ([Full Deployment Guide](../guides/full-deployment-guide.md) or [Quick Deployment Guide](../guides/quick-deployment-guide.md))
- **Azure CLI** installed and authenticated (`az login`)
- **Python 3.10+** with a virtual environment activated
- **Dependencies** installed:
  ```bash
  pip install -r ../shared/requirements.txt
  ```
- **VS Code** with the Jupyter extension (recommended for running notebooks)

### Optional (per notebook)

| Capability | Required By | Details |
|---|---|---|
| Azure Key Vault | Access Contracts, Agent Frameworks | A Key Vault with secrets for LLM endpoint and API key |
| Azure AI Foundry | Access Contracts, Agent Frameworks | A Foundry account and project for connection integration |
| Azure AI Language Service | PII Processing | PII detection endpoint with managed identity access |
| Event Hub | PII Processing | For PII state saving and audit logging |

---

## Notebooks

### 1. LLM Backend Onboarding Runner

| | |
|---|---|
| **Notebook** | [`llm-backend-onboarding-runner.ipynb`](llm-backend-onboarding-runner.ipynb) |
| **Purpose** | Onboard AI backends into the Citadel Governance Hub and deploy routing logic |
| **Run this** | First — before any other notebook |

#### What It Does

This notebook automates the full lifecycle of registering LLM backends with your APIM gateway. It extracts the current backend configuration, generates a Bicep parameter file with per-model metadata (SKU, capacity, model format, version), deploys the backends and policy fragments, and verifies the deployment through multiple API formats.

#### Steps

| Step | Description |
|---|---|
| 0 | **Initialize variables** — Configure resource group, location, and backend endpoints |
| 1 | **Verify Azure CLI** — Confirm authentication and subscription context |
| 2 | **Initialize APIM Client** — Connect to the existing Governance Hub deployment |
| 3 | **Extract current backends** — Retrieve existing backend pools and routing configuration |
| 4 | **Discover managed identity** — Auto-detect the APIM user-assigned managed identity |
| 5 | **Generate parameter file** — Create a `.bicepparam` file with full backend definitions |
| 6 | **Deploy** — Run the Bicep deployment to create backends, pools, and policy fragments |
| 7 | **Verify deployment** — Confirm backends and policy fragments were created |
| 8 | **Verify GET /deployments** — Test the `get-available-models` policy fragment for Foundry integration |
| Test | **Test models** — Validate via Universal LLM API, Azure OpenAI API, Python SDK, and streaming |

#### Key Configuration

```python
governance_hub_resource_group = "REPLACE"  # Your Governance Hub resource group
location = "REPLACE"                       # e.g., "eastus", "swedencentral"

llm_backends_config = [
    {
        "backendId": "aif-citadel-primary",
        "backendType": "ai-foundry",           # 'ai-foundry' | 'azure-openai' | 'external'
        "endpoint": "https://...",
        "authScheme": "managedIdentity",        # 'managedIdentity' | 'apiKey' | 'token'
        "supportedModels": [
            { "name": "gpt-4o", "sku": "GlobalStandard", "capacity": 100, "modelFormat": "OpenAI", "modelVersion": "2024-11-20" }
        ],
        "priority": 1,
        "weight": 100
    }
]
```

#### Output

- Deployed APIM backends with circuit breaker support
- Backend pools with priority/weight-based load balancing
- `set-backend-pools` and `get-available-models` policy fragments
- Verified model routing through both API formats

---

### 2. Citadel Access Contracts Tests

| | |
|---|---|
| **Notebook** | [`citadel-access-contracts-tests.ipynb`](citadel-access-contracts-tests.ipynb) |
| **Purpose** | Create, deploy, and load-test multiple access contracts with different integration patterns |
| **Run this** | After backend onboarding is complete |

#### What It Does

This notebook provisions three distinct access contracts, each representing a different integration pattern. It generates the Bicep parameter files, deploys the contracts as APIM products with subscriptions, performs load testing, and visualizes throttling behavior and token bucket dynamics across all contracts.

#### Access Contracts Created

| Contract | Business Unit | Integration | Description |
|---|---|---|---|
| **Sales-Assistant** | Sales | Key Vault only | Secrets (endpoint + API key) resolved from Azure Key Vault |
| **HR-ChatAgent** | HR | Key Vault + Foundry | Optionally creates a Foundry project connection for agent integration |
| **Support-Bot** | Support | Direct output | No external integrations — uses direct APIM subscription output |

#### Steps

| Step | Description |
|---|---|
| 0 | **Initialize variables** — Configure resource group, Key Vault, and Foundry settings |
| 1 | **Verify Azure CLI** — Confirm authentication and subscription context |
| 2 | **Initialize APIM Client** — Discover APIs and supported models |
| 3 | **Define contracts** — Configure three access contracts with varying integration patterns |
| 4 | **Create parameter files** — Generate `.bicepparam` files with policy XML for each contract |
| 5 | **Deploy contracts** — Run Bicep deployments at subscription scope |
| 6 | **Retrieve API keys** — Extract subscription keys for each deployed product |
| 7 | **Load test** — Send concurrent API requests to each contract and record metrics |
| 8 | **Visualize results** — Compare success/throttled/error rates across contracts |
| 9 | **Token bucket analysis** — Simulate and visualize token bucket refill behavior |
| Cleanup | **Delete test products** — Optionally remove all created APIM products and subscriptions |

#### Key Configuration

```python
governance_hub_resource_group = "REPLACE"
location = "REPLACE"

# Optional integrations
use_keyvault_integration = True
keyvault_name = "REPLACE"

use_foundry_integration = True
foundry_account_name = "REPLACE"
foundry_project_name = "REPLACE"
```

#### Output

- Three deployed APIM products with subscription keys
- Key Vault secrets populated (if enabled)
- Foundry connection created (if enabled)
- Performance charts comparing all contracts
- Token bucket behavior visualization

---

### 3. Citadel Agent Frameworks Tests

| | |
|---|---|
| **Notebook** | [`citadel-agent-frameworks-tests.ipynb`](citadel-agent-frameworks-tests.ipynb) |
| **Purpose** | Validate real-world agent consumption of access contracts using three major frameworks |
| **Run this** | After access contracts are deployed (notebook 2) |

#### What It Does

This notebook instantiates three AI agents — each using a different framework and integration pattern — and runs multi-turn conversations through the Citadel gateway. It measures token consumption, retry behavior, and call reliability, then produces comparative visualizations across all three frameworks.

#### Agent Framework Matrix

| Access Contract | Agent Framework | Integration Type | Target Model |
|---|---|---|---|
| **Sales-Assistant** | Microsoft Agent Framework | Azure Key Vault (endpoint + key) | gpt-4.1 |
| **HR-ChatAgent** | Microsoft Foundry Agent SDK | Foundry Project Connection | gpt-4o |
| **Support-Bot** | LangChain | Local (direct endpoint + key) | phi-4 |

#### Steps

| Step | Description |
|---|---|
| 0 | **Initialize variables** — Configure resource group, Key Vault, Foundry, and model settings |
| 1 | **Verify Azure CLI** — Confirm authentication and subscription context |
| 2 | **Initialize APIM Client** — Discover APIs and supported models |
| 3 | **Retrieve API keys** — Fetch subscription keys for each access contract |
| 4 | **Install packages** — Install agent framework dependencies (`agent-framework`, `azure-ai-projects`, `langchain`, `langchain-openai`) |
| 5 | **Microsoft Agent Framework** — Sales conversation via Key Vault integration |
| 6 | **Foundry Agent SDK** — HR conversation via Foundry project connection |
| 7 | **LangChain** — Support conversation via direct endpoint configuration |
| 8 | **Metrics comparison** — Token consumption pie charts, calls vs. retries, retry rates |
| 9 | **Efficiency analysis** — Token efficiency and call reliability per agent |
| Cleanup | Managed by `citadel-access-contracts-tests.ipynb` |

#### Key Configuration

```python
governance_hub_resource_group = "REPLACE"

# Key Vault (for Sales-Assistant)
keyvault_name = "REPLACE"

# Foundry (for HR-ChatAgent)
foundry_account_name = "REPLACE"
foundry_project_name = "REPLACE"
foundry_connection_name = "HR-ChatAgent-DEV-LLM"

# Models per agent
sales_model_name = "gpt-4.1"
hr_model_name = "gpt-4o"
support_model_name = "phi-4"
```

#### Output

- Multi-turn conversation logs for each agent
- Token usage metrics (prompt, completion, total) per framework
- Retry rate and reliability analysis
- Comparative visualizations saved as `agent_metrics_comparison.png`

---

### 4. Citadel PII Processing Tests

| | |
|---|---|
| **Notebook** | [`citadel-pii-processing-tests.ipynb`](citadel-pii-processing-tests.ipynb) |
| **Purpose** | Verify PII anonymization, deanonymization, and blocking capabilities |
| **Run this** | After the Governance Hub is deployed with PII policy fragments |

#### What It Does

This notebook creates two specialized access contracts to test PII processing. The first contract enables PII anonymization and deanonymization with state saving (audit logging to Event Hub). The second contract enables PII blocking, which rejects any request containing detected PII. Both contracts support built-in PII categories and custom regex patterns for domain-specific identifiers.

#### Use Cases Tested

| Use Case | Mode | Behavior |
|---|---|---|
| **PII Masking** | Anonymization / Deanonymization | PII in requests is replaced with placeholders (e.g., `<Person_0>`), sent to the LLM, then restored in the response |
| **PII Blocking** | Detection + Rejection | Requests containing PII are rejected with HTTP 400 and a list of detected PII categories |

#### PII Types Covered

- Person names, email addresses, phone numbers
- Physical addresses, IBANs
- Credit card numbers (custom regex)
- Passport numbers (custom regex)
- Emirates ID (custom regex)
- Multiple PII types in a single request

#### Steps

| Step | Description |
|---|---|
| 0 | **Initialize variables** — Configure resource group, location, and Key Vault settings |
| 1 | **Verify Azure CLI** — Confirm authentication and subscription context |
| 2 | **Initialize APIM Client** — Discover APIs and supported models |
| 3.1 | **Define masking contract** — Configure PII anonymization with state saving |
| 3.2 | **Create masking policy** — Generate policy XML with anonymization, deanonymization, and regex patterns |
| 3.3 | **Deploy masking contract** — Deploy via Bicep with generated parameters |
| 3.4 | **Retrieve masking API key** — Get the subscription key for the masking product |
| 3.5 | **Test PII masking** — Send 6 test payloads with various PII types and verify deanonymization |
| 4.1 | **Define blocking contract** — Configure PII detection and blocking |
| 4.2 | **Create blocking policy** — Generate policy XML that detects PII and returns HTTP 400 |
| 4.3 | **Deploy blocking contract** — Deploy via Bicep with generated parameters |
| 4.4 | **Retrieve blocking API key** — Get the subscription key for the blocking product |
| 4.5 | **Test PII blocking** — Send 8 test payloads (5 with PII, 3 without) and verify correct blocking/allowing |
| Summary | **Results overview** — Aggregate pass/fail across both use cases |
| Cleanup | **Delete test products** — Optionally remove PII access contracts and generated files |

#### Key Configuration

```python
governance_hub_resource_group = "REPLACE"
location = "REPLACE"

# PII detection settings (configured in policy XML)
# - Confidence threshold: 0.75–0.8
# - Entity exclusions: PersonType
# - Custom regex: Credit cards, passport numbers, Emirates ID
```

#### Output

- Deployed PII masking and blocking APIM products
- Test results for 14 PII test payloads
- Validation of custom regex pattern detection
- Pass/fail summary for both anonymization and blocking modes

---

## Recommended Execution Order

```
┌─────────────────────────────────────┐
│  1. llm-backend-onboarding-runner   │  ← Onboard LLM backends & routing
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│  2. citadel-access-contracts-tests  │  ← Create access contracts & load test
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│  3. citadel-agent-frameworks-tests  │  ← Test agent frameworks (uses contracts from step 2)
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│  4. citadel-pii-processing-tests    │  ← Test PII masking & blocking (independent contracts)
└─────────────────────────────────────┘
```

> **Note:** Notebook 4 (PII Processing) creates its own access contracts and can be run independently after backend onboarding. However, it requires PII policy fragments (`pii-anonymization`, `pii-deanonymization`, `pii-state-saving`) to be deployed in the Governance Hub.

## Shared Utilities

All notebooks import shared helper modules from the [`../shared/`](../shared/) directory:

| Module | Description |
|---|---|
| `utils.py` | CLI command runner, formatted output helpers (`print_ok`, `print_error`, `print_info`) |
| `apimtools.py` | `APIMClientTool` class for APIM discovery, API key retrieval, policy fragment parsing, and backend management |

## Cleanup

Each notebook includes an optional cleanup cell at the end that removes the APIM products and subscriptions created during testing. Cleanup is controlled by a `cleanup_enabled` flag (default: `True`).

> **Important:** Cleanup does not remove Azure Key Vault secrets, Foundry connections, or LLM backend configurations. Those resources are managed separately.

## Troubleshooting

| Issue | Resolution |
|---|---|
| `az account show` fails | Run `az login` and set the correct subscription with `az account set --subscription <id>` |
| APIM Client Tool initialization fails | Verify the `governance_hub_resource_group` is correct and your identity has Reader access |
| Model not found in backend pool | Run the backend onboarding notebook to register the model |
| Key Vault access denied | Ensure your identity has `Key Vault Secrets User` role on the Key Vault |
| Foundry connection fails | Verify the Foundry account, project, and connection names are correct |
| PII detection not working | Confirm the Azure AI Language Service is deployed and the managed identity has access |
| 429 Throttled responses | Expected during load testing — the token bucket policy is working correctly |
