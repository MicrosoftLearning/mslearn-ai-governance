# LLM Backend Onboarding Guide

This guide explains how to onboard LLM backends (Azure OpenAI, Microsoft Foundry, or external providers) to an existing AI Hub Gateway APIM instance using the independent LLM Backend Onboarding deployment.

## Overview

The LLM Backend Onboarding deployment enables dynamic routing of LLM requests across multiple backend instances without requiring a full infrastructure deployment. It creates:

- **Backend Resources**: Individual APIM backends with circuit breakers
- **Backend Pools**: Load-balanced pools for models available on multiple backends
- **Policy Fragments**: Dynamic routing logic using C# expressions
- **Universal LLM API** (optional): A unified API supporting both OpenAI and Models Inference patterns

## Architecture

A typical onboarding includes various policy updates and backend configurations.

Below is a sample overview of relevant configurations associated with LLM onboarding:

```
┌─────────────────────────────────────────────────────────────────────┐
│                          APIM Gateway                               │
├─────────────────────────────────────────────────────────────────────┤
│  Policy Fragments                                                   │
│  ├── set-backend-pools (dynamic pool routing)                       │
│  ├── set-backend-authorization (managed identity/API key)           │
│  ├── set-target-backend-pool (load balancing)                       │
│  ├── set-llm-requested-model (model extraction)                     │
│  └── get-available-models (Foundry support)                         │
├─────────────────────────────────────────────────────────────────────┤
│  Backend Pools                                                      │
│  ├── pool-gpt-4o (multiple backends)                                │
│  └── pool-gpt-4o-mini (multiple backends)                           │
├─────────────────────────────────────────────────────────────────────┤
│  Backends                                                           │
│  ├── llm-foundry-east-us (Microsoft Foundry)                        │
│  ├── llm-foundry-west-us (Microsoft Foundry)                        │
│  └── llm-openai-sweden (Azure OpenAI)                               │
└─────────────────────────────────────────────────────────────────────┘
```

## Prerequisites

- Existing APIM instance deployed via the AI Hub Gateway Solution Accelerator
- APIM Managed Identity with appropriate permissions on target LLM backends
- At least one existing LLM backend (Azure OpenAI, Microsoft Foundry, or external)
- Azure CLI and Bicep CLI installed

>NOTE: This onboarding script does not grant any permissions to target Azure backends (like Microsoft Foundry). Ensure that APIM user managed identity has at least `Cognitive Services User` role assignment on the target backend.

## Quick Start

### 1. Copy the Parameter Template

```bash
cd bicep/infra/llm-backend-onboarding
cp main.bicepparam llm-onboarding-dev-local.bicepparam
```

### 2. Configure Your Backends

Edit the parameter file with your backend configuration:

```bicep
param llmBackendConfig = [
  {
    backendId: 'aif-citadel-primary'
    backendType: 'ai-foundry'
    endpoint: 'https://aif-kclom7nxzysjg-0.services.ai.azure.com/models'
    authScheme: 'managedIdentity'
    supportedModels: [
      { name: 'gpt-4o', sku: 'GlobalStandard', capacity: 100, modelFormat: 'OpenAI', modelVersion: '2024-11-20', retirementDate: '2026-09-30' }
      { name: 'gpt-4o-mini', sku: 'GlobalStandard', capacity: 100, modelFormat: 'OpenAI', modelVersion: '2024-07-18', retirementDate: '2026-09-30' }
      { name: 'gpt-4.1', sku: 'GlobalStandard', capacity: 100, modelFormat: 'OpenAI', modelVersion: '2025-04-14', retirementDate: '2026-10-14', apiVersion: '2025-04-01-preview', timeout: 180 }
      { name: 'DeepSeek-R1', sku: 'GlobalStandard', capacity: 1, modelFormat: 'DeepSeek', modelVersion: '1', retirementDate: '2099-12-30', inferenceApiVersion: '2024-05-01-preview' }
      { name: 'Phi-4', sku: 'GlobalStandard', capacity: 1, modelFormat: 'Microsoft', modelVersion: '3', retirementDate: '2099-12-30', inferenceApiVersion: '2024-05-01-preview' }
      { name: 'text-embedding-3-large', sku: 'GlobalStandard', capacity: 100, modelFormat: 'OpenAI', modelVersion: '1', retirementDate: '2027-04-14' }
    ]
    priority: 1
    weight: 100
  }
  {
    backendId: 'aif-citadel-secondary'
    backendType: 'ai-foundry'
    endpoint: 'https://aif-kclom7nxzysjg-1.services.ai.azure.com/models'
    authScheme: 'managedIdentity'
    supportedModels: [
      { name: 'gpt-5', sku: 'GlobalStandard', capacity: 50, modelFormat: 'OpenAI', modelVersion: '1', retirementDate: '2027-02-05' }
      { name: 'DeepSeek-R1', sku: 'GlobalStandard', capacity: 1, modelFormat: 'DeepSeek', modelVersion: '1', retirementDate: '2099-12-30', inferenceApiVersion: '2024-05-01-preview' }
      { name: 'text-embedding-3-large', sku: 'GlobalStandard', capacity: 50, modelFormat: 'OpenAI', modelVersion: '1', retirementDate: '2027-04-14' }
    ]
    priority: 2
    weight: 50
  }
]
```

### 3. Deploy

The below command deploys the LLM Backend Onboarding resources to your governance hub and with the specified parameter file `llm-onboarding-dev-local.bicepparam` and set location:

```bash
az deployment sub create --name llm-onboarding-deployment --location REPLACE --template-file main.bicep --parameters llm-onboarding-dev-local.bicepparam
```

## Configuration Reference

### Backend Configuration Object

| Property | Type | Required | Description |
|----------|------|----------|-------------|
| `backendId` | string | Yes | Unique identifier for the backend |
| `backendType` | string | Yes | Type: `ai-foundry`, `azure-openai`, or `external` |
| `endpoint` | string | Yes | Full URL to the backend service |
| `authScheme` | string | Yes | Authentication: `managedIdentity`, `apiKey`, or `token` |
| `supportedModels` | array | Yes | Array of model objects (see Model Object Properties below) |
| `priority` | int | No | Priority for load balancing (1-5, default 1, lower = higher priority) |
| `weight` | int | No | Weight for weighted round-robin (1-1000, default 100) |

### Model Object Properties

Each model in the `supportedModels` array has these properties:

| Property | Type | Required | Description |
|----------|------|----------|-------------|
| `name` | string | Yes | Model name (e.g., `gpt-4o`, `DeepSeek-R1`, `Phi-4`) |
| `sku` | string | No | SKU name for the deployment (default: `Standard`). Used in `get-available-models` response |
| `capacity` | number | No | Capacity/TPM quota (default: 100). Used in `get-available-models` response |
| `modelFormat` | string | No | Model format identifier, e.g., `OpenAI`, `DeepSeek`, `Microsoft` (default: `OpenAI`). Used in `get-available-models` response |
| `modelVersion` | string | No | Version of the model (default: `1`). Used in `get-available-models` response |
| `retirementDate` | string (date) | No | Retirement date for the model in YYYY-MM-DD format. Used in `get-available-models` response |
| `apiVersion` | string | No | API version for OpenAI-type requests (default: `2024-02-15-preview`). Used by Unified AI API for backend routing |
| `timeout` | number | No | Request timeout in seconds (default: `120`). Used by Unified AI API for per-model timeout configuration |
| `inferenceApiVersion` | string | No | API version for inference-type requests (e.g., `2024-05-01-preview`). Used by Unified AI API for non-OpenAI models |

### Backend types examples

#### Microsoft Foundry (`ai-foundry`)
```bicep
{
  backendId: 'foundry-instance'
  backendType: 'ai-foundry'
  endpoint: 'https://project.region.models.ai.azure.com'
  authScheme: 'managedIdentity'
  supportedModels: [
    { name: 'gpt-4o', sku: 'GlobalStandard', capacity: 100, modelFormat: 'OpenAI', modelVersion: '2024-11-20', retirementDate: '2026-09-30' }
    { name: 'Phi-4', sku: 'GlobalStandard', capacity: 1, modelFormat: 'Microsoft', modelVersion: '3', retirementDate: '2099-12-30', inferenceApiVersion: '2024-05-01-preview' }
  ]
}
```

#### Azure OpenAI (`azure-openai`)
```bicep
{
  backendId: 'openai-instance'
  backendType: 'azure-openai'
  endpoint: 'https://myopenai.openai.azure.com'
  authScheme: 'managedIdentity'
  supportedModels: [
    { name: 'gpt-4o', sku: 'Standard', capacity: 120, modelFormat: 'OpenAI', modelVersion: '2024-11-20' }
    { name: 'text-embedding-ada-002', sku: 'Standard', capacity: 120, modelFormat: 'OpenAI', modelVersion: '2' }
  ]
}
```

#### External Provider (`external`)
```bicep
{
  backendId: 'external-llm'
  backendType: 'external'
  endpoint: 'https://api.externalprovider.com/v1'
  authScheme: 'apiKey'
  supportedModels: [
    { name: 'custom-model', modelFormat: 'Custom', modelVersion: '1' }
  ]
}
```

### Authentication Schemes

| Scheme | Description | Use Case |
|--------|-------------|----------|
| `managedIdentity` | Azure AD token via managed identity | Azure OpenAI, Microsoft Foundry (uses APIM managed identity which must have permission) |
| `apiKey` | Static API key in named value | External providers |
| `token` | Bearer token from named value | OAuth-based services |

## Load Balancing

The deployment automatically creates backend pools for models available on multiple backends.

### Priority-Based Failover

Configure priority to create failover chains:

```bicep
[
  {
    backendId: 'primary-backend'
    priority: 1  // Primary
    weight: 100
    supportedModels: [...]
  }
  {
    backendId: 'secondary-backend'
    priority: 2  // Failover
    weight: 100
    supportedModels: [...]
  }
]
```

### Weighted Round-Robin

Configure weights for proportional distribution:

```bicep
[
  {
    backendId: 'high-capacity'
    priority: 1
    weight: 70  // 70% of traffic
    supportedModels: [...]
  }
  {
    backendId: 'standard-capacity'
    priority: 1
    weight: 30  // 30% of traffic
    supportedModels: [...]
  }
]
```

## Circuit Breaker Configuration

Each backend is configured with circuit breaker rules:

- **429 (Rate Limit)**: Trips after 3 occurrences in 10 seconds
- **5xx (Server Error)**: Trips after 3 occurrences in 10 seconds
- **Recovery**: Automatic after 10 seconds

## Validation

Use the validation notebook [llm-backend-onboarding-runner.ipynb](../validation/llm-backend-onboarding-runner.ipynb) to test your deployment:

The notebook validates:
- Backend configuration
- API connectivity
- Load balancing behavior
- Circuit breaker failover
- Multi-model routing

## Troubleshooting

### Backend Not Responding

1. Verify the endpoint URL is correct
2. Check managed identity permissions
3. Review APIM diagnostic logs

### Load Balancing Not Working

1. Ensure multiple backends support the same model
2. Verify priority and weight settings
3. Check that all backends are healthy

### Circuit Breaker Tripping

1. Review backend health and performance
2. Check for rate limiting (429 errors)
3. Verify backend capacity

## Related Documentation

- [LLM Routing Architecture](llm-routing-architecture.md)
- [Full Deployment Guide](full-deployment-guide.md)
- [Citadel Access Contracts](citadel-access-contracts.md)

## File Structure

```
bicep/infra/llm-backend-onboarding/
├── main.bicep                 # Main deployment file
├── main.bicepparam            # Parameter template
├── README.md                  # Quick reference
└── modules/
    ├── llm-backends.bicep         # Backend resources
    ├── llm-backend-pools.bicep    # Backend pool creation
    ├── llm-policy-fragments.bicep # Policy fragment generation
    ├── universal-llm-api.bicep    # Universal API definition
    └── policies/
        ├── set-backend-pools.xml
        ├── set-backend-authorization.xml
        ├── set-target-backend-pool.xml
        ├── set-llm-requested-model.xml
        └── get-available-models.xml
```
