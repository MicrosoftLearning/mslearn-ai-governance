# LLM Routing Architecture Guide

## Overview

The AI Citadel Governance Hub provides intelligent, model-based routing to LLM backends through Azure API Management (APIM). This guide explains how requests are routed to different backend/backend pools when using either the **Universal LLM API** or **Azure OpenAI API**.

## Supported APIs

The following APIs are configured out-of-the-box for handling LLM requests:

| API | Path | Use Case |
|-----|------|----------|
| **Universal LLM API** | `/models/*` | **RECOMMENDED** OpenAI-compatible inference endpoints that supports various models |
| **Azure OpenAI API** | `/openai/deployments/{deployment-id}/*` | Azure OpenAI SDK compatibility |

Both APIs share the same underlying routing infrastructure and policy fragments.

## Approach

The routing relies on APIM Policy Fragments to implement dynamic routing logic without modifying the main API policies.

Using policy fragments allows to keep the routing logic modular and reusable across multiple APIs.

The fragments are:
- `set-llm-requested-model`: Extracts the requested model from the request path or body
- `set-backend-pools`: Loads backend pool configurations that include supported models by which backends
- `set-target-backend-pool`: Matches the requested model to a backend pool
- `set-backend-authorization`: Configures appropriate authentication for the target backend

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           Client Request                                    │
│   POST /models/chat/completions  OR  POST /openai/deployments/gpt-4o/...    │
└────────────────────────────────────┬────────────────────────────────────────┘
                                     │
                                     ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                        APIM Gateway (Inbound)                               │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │ 1. Authentication (Entra ID / API Key)                                │  │
│  │ 2. Extract Model (from body or deployment-id path)                    │  │
│  │ 3. Load Backend Pools Configuration                                   │  │
│  │ 4. Match Model → Backend Pool                                         │  │
│  │ 5. Validate RBAC (allowed pools check)                                │  │
│  │ 6. Set Authorization (Managed Identity)                               │  │
│  │ 7. Route to Backend Pool                                              │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────┬────────────────────────────────────────┘
                                     │
                                     ▼
┌────────────────────────────────────────────────────────────────────────────┐
│                         Backend Pool Selection                             │
│                                                                            │
│   ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐        │
│   │  gpt-4o-pool    │    │ deepseek-r1-pool│    │ Direct Backend  │        │
│   │  ┌───────────┐  │    │  ┌───────────┐  │    │                 │        │
│   │  │ Backend 1 │  │    │  │ Backend 1 │  │    │  Single backend │        │
│   │  │(P:1,W:100)│  │    │  │(P:1,W:100)│  │    │  for unique     │        │
│   │  └───────────┘  │    │  └───────────┘  │    │  models         │        │
│   │  ┌───────────┐  │    │  ┌───────────┐  │    │                 │        │
│   │  │ Backend 2 │  │    │  │ Backend 2 │  │    └─────────────────┘        │
│   │  │ (P:2,W:50)│  │    │  │ (P:2,W:50)│  │                               │
│   │  └───────────┘  │    │  └───────────┘  │                               │
│   └─────────────────┘    └─────────────────┘                               │
└────────────────────────────────────┬───────────────────────────────────────┘
                                     │
                                     ▼
┌────────────────────────────────────────────────────────────────────────────┐
│                          LLM Backend Targets                               │
│                                                                            │
│   ┌─────────────┐      ┌─────────────┐      ┌─────────────┐                │
│   │   Foundry   │      │ Azure OpenAI│      │  External   │                │
│   │  Endpoint   │      │  Endpoint   │      │  Provider   │                │
│   └─────────────┘      └─────────────┘      └─────────────┘                │
└────────────────────────────────────────────────────────────────────────────┘
```

## Routing Flow Details

### Step 1: Model Extraction

The `set-llm-requested-model` policy fragment extracts the model from the request:

| Source | Pattern | Example |
|--------|---------|---------|
| **GET/DELETE Request** | Any GET or DELETE operation | Returns `"non-llm-request"` (skips model extraction) |
| **URL Path Parameter** | `/deployments/{deployment-id}/...` | Azure OpenAI API (named operations) |
| **URL Path Segment** | `/openai/deployments/{model}/...` | Unified AI API (wildcard operations) |
| **Request Body** | `{"model": "gpt-4o", ...}` | Universal LLM / Inference API |

Purpose: Extracts the requested model from Azure OpenAI, Inference, or Unified AI endpoints

**Supported Patterns:**
1. **GET/DELETE Requests**: Returns `"non-llm-request"` to skip model-based routing (used for operations like listing models or deleting responses)
2. Azure OpenAI: Model from `deployment-id` path parameter (`/deployments/{deployment-id}/chat/completions`)
3. Unified AI: Model from URL path by detecting `/deployments/{model}/` segment (wildcard operations where APIM has no named path parameters)
4. Inference Endpoint: Model from request body JSON (`{"model": "model-name", ...}`)

**Output Variable:**
- requestedModel: The extracted model name, `"non-llm-request"` for GET/DELETE operations, or empty string if not found

Logic:
- GET/DELETE requests return `"non-llm-request"` (no model routing needed)
- First attempts to extract from `deployment-id` path parameter (Azure OpenAI named operations)
- If not found, scans the URL path for `/deployments/{model}/` segment (Unified AI wildcard operations)
- If not found, attempts to extract from request body `model` field (Inference pattern)
- Returns empty string if no pattern matches

### Step 2: Backend Pool Configuration

The `set-backend-pools` fragment loads all available backend pools:

**Expected Input Variables:**
- requestedModel: The model name extracted from the request payload
- defaultBackendPool: Default backend pool to use when model is not mapped (empty string = error for unmapped models)
- allowedBackendPools: Comma-separated list of allowed backend pool IDs (empty string = all pools allowed)
        
**Output Variables:**
- backendPools: JArray containing all backend pool configurations

```csharp
// Example pool configuration (auto-generated from Bicep)
var pool_0 = new JObject()
{
    { "poolName", "DeepSeek-R1-backend-pool" },
    { "poolType", "ai-foundry" },
    { "supportedModels", new JArray("DeepSeek-R1") }
};
backendPools.Add(pool_0);
// Pool: aif-citadel-primary (Type: ai-foundry)
var pool_1 = new JObject()
{
    { "poolName", "aif-citadel-primary" },
    { "poolType", "ai-foundry" },
    { "supportedModels", new JArray("gpt-4o") }
};
backendPools.Add(pool_1);
// Pool: aif-citadel-primary (Type: ai-foundry)
var pool_2 = new JObject()
{
    { "poolName", "aif-citadel-primary" },
    { "poolType", "ai-foundry" },
    { "supportedModels", new JArray("gpt-4o-mini") }
};
```

It is worth noting that:
- Each backend supporting multiple models will have multiple pool entries (one per model)
- Backends supporting the same model are grouped into a single load-balanced pool (like in `DeepSeek-R1-backend-pool` in the above example)
- This policy fragment can be gateway-region aware to support different routing pools for different regions if needed (like have a self-hosted gateway that will only route to on-premises LLMs while cloud gateway will route to cloud LLMs).
- Policy can be set to allow a default backend pool to be returned if no matching model is found.

### Step 3: Target Pool Selection

The `set-target-backend-pool` fragment matches the requested model to a backend:

**Purpose:**
- Determines which backend pool to route the request to based on the requested model and access permissions
- For non-LLM requests (GET operations), skips backend pool routing entirely
        
**Expected Input Variables:**
- requestedModel: The model name extracted from the request payload (or `"non-llm-request"` for GET operations)
- defaultBackendPool: Default backend pool to use when model is not mapped (default behavior empty string = error for unmapped models)
- allowedBackendPools: Comma-separated list of allowed backend pool IDs (empty string = all pools allowed) - This is usually set at APIM product level to restrict access to certain backend pools per use case
- backendPools: JArray containing all backend pool configurations

**Output Variables:**
- targetBackendPool: The selected backend pool name, `"non-llm-request"` for GET operations, or error code (ERROR_NO_MODEL, ERROR_NO_ALLOWED_POOLS)
- targetPoolType: The type of the selected backend pool (e.g., "azure-openai", "ai-foundry", "non-llm-request")

### Step 4: Authentication & Routing

The `set-backend-authorization` fragment configures backend-specific authentication:

**Purpose:** Configures authentication headers and URL rewriting based on backend pool type

**Expected Input Variables:**
- targetPoolType: The type of the target backend pool (e.g., "azure-openai", "ai-foundry", "non-llm-request")
- targetBackendPool: The selected backend pool name
- requestedModel: The model name extracted from the request payload

**Expected `Named Values`:**
- uami-client-id: User-assigned managed identity client ID for authentication

**Side Effects:**
- Sets Authorization header with managed identity token
- Rewrites request URL for Azure OpenAI to include deployment path
- Sets backend service to the target backend pool
- For `non-llm-request`: Skips authentication and backend routing (handled by operation-specific policy)

It is worth noting there is default implementations for Azure LLMs, but this can be extended to support external LLM providers with different authentication schemes (API keys, tokens,...).

| Backend Type | Authentication | URL Rewriting |
|--------------|----------------|---------------|
| `non-llm-request` | Skipped (operation-specific) | None |
| `ai-foundry` | APIM's Managed Identity → Cognitive Services | None |
| `azure-openai` | APIM's Managed Identity → Cognitive Services | Injects `/deployments/{model}/` |
| `external` | Backend credentials | None |

## Backend Pool Types

### Single Backend (Direct Routing)
When a model is only available on one backend, requests route directly:

```
Model: "Phi-4" → Backend: "aif-citadel-primary"
```

### Backend Pool (Load Balanced)
When multiple backends support the same model, a pool is created:

```
Model: "gpt-4o" → Pool: "gpt-4o-backend-pool"
                    ├── Backend 1 (Priority: 1, Weight: 100)
                    └── Backend 2 (Priority: 2, Weight: 50)
```

**Load Balancing Behavior:**
- **Priority**: Lower value = higher priority (1 is highest)
- **Weight**: Traffic distribution ratio among same-priority backends
- **Failover**: Automatic retry to next backend on 429/503 errors

## Circuit Breaker Protection

Each backend has circuit breaker configuration:

```bicep
circuitBreaker: {
  rules: [{
    failureCondition: {
      count: 3              // Failures before tripping
      interval: 'PT5M'      // Time window
      statusCodeRanges: [
        { min: 429, max: 429 },  // Throttling
        { min: 500, max: 503 }   // Server errors
      ]
    }
    tripDuration: 'PT1M'    // Circuit open duration
    acceptRetryAfter: true  // Honor Retry-After headers
  }]
}
```

## Retry Logic

Both APIs implement automatic retry on transient failures:

```xml
<retry count="2" interval="0" first-fast-retry="true" 
       condition="@(context.Response.StatusCode == 429 || 
                    context.Response.StatusCode >= 500)">
    <forward-request buffer-request-body="true" />
</retry>
```

## RBAC Integration

Access contracts (applied at a product level) can restrict which backend pools a client can use:

```xml
<!-- Product Policy for specific use case -->
<set-variable name="allowedBackendPools" 
              value="gpt-4o-backend-pool,aif-citadel-primary" />
```

| Scenario | Behavior |
|----------|----------|
| `requestedModel = "non-llm-request"` | Access control bypassed (GET operations) |
| `allowedBackendPools = ""` | All pools accessible |
| `allowedBackendPools = "pool1,pool2"` | Only listed pools accessible |
| Model supported but pool blocked | 403 Forbidden |

### Non-LLM Request Handling

GET operations (like listing available models) are identified as `"non-llm-request"` and bypass:
- Model validation
- Backend pool routing
- Token usage metrics collection
- Model-based access control

This allows auxiliary endpoints to function without requiring a model parameter in the request.

## Usage Metrics Collection

The `set-llm-usage` fragment emits token metrics for monitoring:

```xml
<llm-emit-token-metric namespace="llm-usage">
    <dimension name="productName" />      <!-- Use case identifier -->
    <dimension name="deploymentName" />   <!-- Model requested -->
    <dimension name="Backend ID" />       <!-- Backend that served request -->
    <dimension name="appId" />            <!-- Client identifier -->
</llm-emit-token-metric>
```

## Policy Fragments Reference

| Fragment | Purpose |
|----------|---------|
| `set-llm-requested-model` | Extracts model from request body, URL path parameter, or URL path segment |
| `set-backend-pools` | Loads backend pool configurations |
| `set-target-backend-pool` | Matches model to backend pool with RBAC |
| `set-backend-authorization` | Sets authentication and set backend to serve the request |
| `set-llm-usage` | Collects token usage metrics |

## Example Request Flows

### Universal LLM API Request

```http
POST APIM_GATEWAY/models/chat/completions
Content-Type: application/json
api-key: <subscription-key>

{
  "model": "gpt-4o",
  "messages": [{"role": "user", "content": "Hello"}]
}
```

**Flow:**
1. Extract model: `"gpt-4o"` from request body
2. Find pool: `"gpt-4o-backend-pool"` (supports gpt-4o)
3. Pool type: `"ai-foundry"`
4. Authenticate: Managed Identity token
5. Route: Forward to healthy backend in pool

### Azure OpenAI API Request

```http
POST APIM_GATEWAY/openai/deployments/gpt-4o/chat/completions?api-version=2024-02-01
Content-Type: application/json
api-key: <subscription-key>

{
  "messages": [{"role": "user", "content": "Hello"}]
}
```

**Flow:**
1. Extract model: `"gpt-4o"` from URL path parameter
2. Inject model into body: `{"model": "gpt-4o", ...}`
3. Rewrite URL: `/chat/completions` (remove deployment path)
4. Find pool: `"gpt-4o-backend-pool"`
5. Authenticate & route same as Universal LLM API

## Troubleshooting

| Error | Cause | Solution |
|-------|-------|----------|
| `400: Model could not be detected` | No model in body or URL | Include `"model"` in request body |
| `400: Model 'x' is not supported` | No backend supports model | Check backend configuration |
| `403: backend_pool_access_forbidden` | RBAC blocks pool access | Update product's `allowedBackendPools` |
| `429: Too Many Requests` | All backends throttling | Wait for retry-after or add capacity |
| `503: Backend pool unavailable` | Circuit breaker open | Wait for trip duration to expire |

## Related Guides

- [LLM Backend Onboarding](../bicep/infra/llm-backend-onboarding/README.md) - Configure backends
- [Citadel Access Contracts](citadel-access-contracts.md) - Configure use case access
