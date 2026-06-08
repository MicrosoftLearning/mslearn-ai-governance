# LLM Routing Architecture Guide

## Overview

The AI Citadel Governance Hub provides intelligent, model-based routing to LLM backends through Azure API Management (APIM). This guide explains how requests are routed to different backend/backend pools when using the **Unified AI API**, **Universal LLM API**, or **Azure OpenAI API**.

## Supported APIs

The following APIs are configured out-of-the-box for handling LLM requests:

| API | Path | Use Case |
|-----|------|----------|
| **Unified AI API** | `/unified-ai/*` | **RECOMMENDED** Single wildcard endpoint supporting all API types (OpenAI, Inference, Responses, Gemini, OpenAI-Compatible) with dynamic routing |
| **Universal LLM API** | `/models/*` | OpenAI-compatible inference endpoints that supports various models |
| **Azure OpenAI API** | `/openai/deployments/{deployment-id}/*` | Azure OpenAI SDK compatibility |

The Unified AI API includes an **OpenAI-Compatible path** (`/unified-ai/v1/*`) that allows clients to use standard OpenAI SDKs without modification. See the [OpenAI-Compatible API Guide](openai-compatible-api-guide.md) for details.

The **Universal LLM API** and **Azure OpenAI API** share the same underlying routing fragments. The **Unified AI API** extends these with additional fragments for dynamic path-based routing, centralized configuration caching, and multi-API-type support.

## Approach

The routing relies on APIM Policy Fragments to implement dynamic routing logic without modifying the main API policies.

Using policy fragments allows to keep the routing logic modular and reusable across multiple APIs.

**Shared fragments** (used by all three APIs):
- `set-backend-pools`: Loads backend pool configurations that include supported models by which backends
- `set-target-backend-pool`: Matches the requested model to a backend pool (extended with `apiTypeOverrideBackend` for Unified AI)
- `set-backend-authorization`: Configures appropriate authentication for the target backend (respects `skipBackendUrlRewrite` for Unified AI)
- `set-llm-usage`: Collects token usage metrics
- `validate-model-access`: Model access control per product
- `resolve-model-alias`: Resolves a client-facing alias name (e.g. `adv-gpt`) to an actual underlying model based on `priority` or `weighted` strategy

**Shared fragment** (used by Universal LLM and Azure OpenAI only):
- `set-llm-requested-model`: Extracts the requested model from the request path or body

**Unified AI-specific fragments:**
- `metadata-config`: Centralized JSON configuration for models, API types, and timeout settings
- `central-cache-manager`: Caches and parses the metadata configuration with TTL-based expiry
- `request-processor`: Analyzes request paths to detect API type and extract model (replaces `set-llm-requested-model` for the Unified AI API)
- `security-handler`: Unified authentication (API Key + optional JWT per product)
- `path-builder`: Reconstructs backend URIs based on API type
- `set-response-headers`: Injects UAIG-* debug headers in responses (when enabled)

## Architecture Overview

### Universal LLM API / Azure OpenAI API

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
│   ┌─────────────┐      ┌─────────────┐      ┌─────────────┐      ┌───────────┐  │
│   │   Foundry   │      │ Azure OpenAI│      │   Amazon    │      │ External  │  │
│   │  Endpoint   │      │  Endpoint   │      │  Bedrock    │      │ Provider  │  │
│   └─────────────┘      └─────────────┘      └─────────────┘      └───────────┘  │
└────────────────────────────────────────────────────────────────────────────┘
```

### Unified AI API

The Unified AI API uses a wildcard catch-all (`/*`) to handle all request patterns through a single endpoint, with dynamic API-type detection and path reconstruction.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           Client Request                                    │
│  POST /unified-ai/openai/deployments/gpt-4o/chat/completions                │
│  POST /unified-ai/models/chat/completions (body: model)                     │
│  POST /unified-ai/v1beta/openai/chat/completions (Gemini)                   │
│  POST /unified-ai/openai/responses (Responses API)                          │
│  GET  /unified-ai/deployments (Model Discovery)                             │
└────────────────────────────────────┬────────────────────────────────────────┘
                                     │
                                     ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                    APIM Gateway (Unified AI Inbound)                        │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │ 1. Load Metadata Config (models, api-types, timeouts)                 │  │
│  │ 2. Cache Manager (version-keyed cache with 300s TTL)                  │  │
│  │ 3. Request Processor (detect api-type from path, extract model)       │  │
│  │ 4. Security Handler (API Key + optional JWT per product)              │  │
│  │ 5. Validate Model Access (per product allowedModels)                  │  │
│  │ 6. Load Backend Pools Configuration                   [SHARED]        │  │
│  │ 7. Match Model → Backend Pool (with api-type override)[SHARED]        │  │
│  │ 8. Set Authorization (Managed Identity)               [SHARED]        │  │
│  │ 9. Path Builder (reconstruct backend URI per api-type)                │  │
│  │ 10. Token Usage Metrics                               [SHARED]        │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────┬────────────────────────────────────────┘
                                     │
                              ┌──────┴──────┐
                              │ API Type    │
                              │ Detection   │
                              └──────┬──────┘
            ┌─────────┬──────────┬───┴───┬──────────┬────────────┬────────────┐
            ▼         ▼          ▼       ▼          ▼            ▼            ▼
       ┌─────────┐┌────────┐┌────────┐┌────────┐┌──────────┐┌──────────┐┌──────────┐
       │ openai  ││infer-  ││respon- ││respon- ││openai-v1 ││gemini-   ││bedrock   │
       │         ││ence    ││ses     ││ses-v1  ││          ││openai    ││          │
       │/openai/ ││/models/││/openai/││/openai/││/openai/  ││/v1beta/  ││/model/   │
       │deploy...││chat/.. ││respon..││v1/resp.││v1/deploy.││openai/.. ││converse  │
       └────┬────┘└───┬────┘└───┬────┘└───┬────┘└────┬─────┘└────┬─────┘└────┬─────┘
            └─────────┴─────────┴────┬────┴──────────┴────────────┴───────────┘
                                     ▼
┌────────────────────────────────────────────────────────────────────────────┐
│                         Backend Pool Selection                             │
│           (same pool infrastructure as other APIs)                         │
└────────────────────────────────────┬───────────────────────────────────────┘
                                     │
                                     ▼
┌────────────────────────────────────────────────────────────────────────────┐
│                          LLM Backend Targets                               │
│                                                                            │
│   ┌─────────────┐      ┌─────────────┐      ┌─────────────┐      ┌─────────────┐  │
│   │   Foundry   │      │ Azure OpenAI│      │   Amazon    │      │ External    │  │
│   │  Endpoint   │      │  Endpoint   │      │  Bedrock    │      │ Provider    │  │
│   └─────────────┘      └─────────────┘      └─────────────┘      └─────────────┘  │
└────────────────────────────────────────────────────────────────────────────┘
```

## Routing Flow Details

### Universal LLM API / Azure OpenAI API Flow

These two APIs use shared fragments for a straightforward model → backend pool → backend routing flow.

#### Step 1: Model Extraction (set-llm-requested-model)

The `set-llm-requested-model` policy fragment extracts the model from the request. It is also invoked by **Citadel access-contract product policies** (`bicep/infra/citadel-access-contracts/policies/default-ai-product-policy.xml`), so it must recognize **every provider's** model-location convention so that `validate-model-access` can enforce `allowedModels` regardless of which API surface the call lands on.

| Source | Pattern | Example | Used by |
|--------|---------|---------|---------|
| **GET/DELETE request** | Any GET or DELETE operation | Returns `"non-llm-request"` (skips model extraction) | All APIs |
| **`deployment-id` path parameter** | `/deployments/{deployment-id}/...` (named operation) | `/openai/deployments/gpt-4o/chat/completions` | Azure OpenAI API |
| **`/deployments/{model}/` segment** | Wildcard operation, model between `/deployments/` and next `/` | `/openai/deployments/gpt-4o/chat/completions` (Universal LLM AOAI passthrough) | Universal LLM, Unified AI `/openai/...` |
| **`/model/{modelId}/` segment** (singular) | AWS Bedrock Converse / Invoke; model between `/model/` and the LAST `/` (operation suffix); URL-decoded. Supports inference-profile ARNs containing `/` | `/unified-ai/bedrock/model/eu.amazon.nova-lite-v1:0/converse`, `/unified-ai/bedrock/model/arn%3Aaws%3Abedrock%3Aus-east-1%3A123%3Ainference-profile%2Feu.amazon.nova-lite-v1%3A0/converse` | Unified AI native Bedrock |
| **`/models/{modelId}:method` segment** (plural with `:`) | Gemini native; model between `/models/` and `:` | `/unified-ai/gemini/v1beta/models/gemini-2.5-flash:generateContent` | Unified AI native Gemini |
| **Request body `model` field** | OpenAI-compat / Anthropic Messages / Inference body | `{"model": "claude-haiku-4-5", ...}` | Universal LLM, Anthropic Messages, OpenAI-compat surfaces |

**Logic (evaluated in order, first match wins):**

1. **GET/DELETE request** → returns `"non-llm-request"` (skips model validation; Responses API id-security may later hydrate `requestedModel` from cache).
2. **`deployment-id` path parameter** (Azure OpenAI named operations).
3. **`/deployments/{model}/` segment** (Azure OpenAI wildcard, Universal LLM `/openai/deployments/...` passthrough).
4. **`/model/{modelId}/` segment** (AWS Bedrock native `/model/{id}/converse|invoke`). Model id is URL-decoded — Bedrock model ids contain `:` (e.g. `eu.amazon.nova-lite-v1:0`) which clients typically percent-encode.
5. **`/models/{modelId}:method` segment** (Gemini native `/models/{id}:generateContent|streamGenerateContent|embedContent`). Model id is URL-decoded.
6. **Request body `model` field** (OpenAI-compat including `/v1/chat/completions`, Anthropic Messages, Bedrock OpenAI-compat).

If none match, returns 400 `missing_model_parameter`.

**Why all APIs need universal extraction.** The default access-contract product policy (`bicep/infra/citadel-access-contracts/policies/default-ai-product-policy.xml`) `<include-fragment fragment-id="set-llm-requested-model" />` and then `validate-model-access` against the contract's `allowedModels` CSV. When a contract is bound to a product that exposes Universal LLM, Azure OpenAI, **and** Unified AI, the same fragment must extract the model name for OpenAI-compat (body), Azure deployments (path param), Bedrock native (`/model/{id}/`), and Gemini native (`/models/{id}:`). A missing pattern would either let unauthorized models through (extraction returns empty → 400 instead of 403) or block native paths entirely.

#### Step 1.5: Responses API ID Security (`responses-id-security` / `responses-id-cache-store`)

The OpenAI **Responses API** (`POST /responses`, `GET /responses/{response_id}`, `GET /responses/{response_id}/input_items`, `DELETE /responses/{response_id}`) is stateful: a `response_id` returned by the backend can be re-used by the client to fetch or chain (`previous_response_id`) prior outputs. To prevent **cross-subscription access** to those server-side conversations, the gateway adds a single shared pair of fragments that are wired into all three API surfaces (Azure OpenAI API, Universal LLM API, Unified AI API):

| Fragment | Stage | Responsibility |
|---|---|---|
| `responses-id-security` | inbound | Detects `/responses*` routes, resolves the `response_id` (URL path or `previous_response_id` body), looks up its owner in APIM cache, returns **403** on subscription mismatch and **404** when no cache entry exists for a GET/DELETE. For GET/DELETE it also **hydrates `requestedModel`** from the cache so model-based routing keeps working for those previously model-less operations. |
| `responses-id-cache-store` | outbound | After a successful `POST /responses`, parses the response body, extracts `id`, and writes `key=response-id-{id}` → `value=<subscriptionId>\|<requestedModel>\|<userId>` to APIM internal cache (24h TTL). |

Cache contract:

```
key   = "response-id-" + response_id
value = "<subscriptionId>|<requestedModel>|<userId>"   // userId from JWT 'azp' claim, falling back to subscription name
ttl   = 86400 seconds
```

Routing impact on `set-target-backend-pool`:

- For `POST /responses`, model-based routing is unchanged (model is in body or path).
- For `GET /responses/{id}` and `DELETE /responses/{id}`, the inbound fragment hydrates `requestedModel` from the cache, so `set-target-backend-pool` resolves the **same backend pool** that served the original `POST` — guaranteeing consistent per-conversation backend affinity without any new branches in `set-target-backend-pool` itself.
- For Unified AI, an `apiTypeOverrideBackend` may also be configured for the `responses` api-type; the override still wins, but the ownership check runs first.

Diagnostic outputs:

- `x-aihub-response-id-cached` response header echoes the just-cached id after a successful POST.
- Trace source `Responses-API-Security` logs hydration, ownership mismatches, and cache misses.

#### Step 2: Backend Pool Configuration (set-backend-pools)

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

#### Step 3: Target Pool Selection (set-target-backend-pool)

The `set-target-backend-pool` fragment matches the requested model to a backend:

**Purpose:**
- Determines which backend pool to route the request to based on the requested model and access permissions
- For non-LLM requests (GET operations), skips backend pool routing entirely
        
**Expected Input Variables:**
- requestedModel: The model name extracted from the request payload (or `"non-llm-request"` for GET operations)
- defaultBackendPool: Default backend pool to use when model is not mapped (default behavior empty string = error for unmapped models)
- allowedBackendPools: Comma-separated list of allowed backend pool IDs (empty string = all pools allowed) - This is usually set at APIM product level to restrict access to certain backend pools per use case
- compatiblePoolTypes: Comma-separated list of `poolType` values the API surface accepts (empty string = all pool types allowed). When set, pools whose `poolType` is not in the list are skipped during model matching, even if they advertise the same model name. Used by **Universal LLM API** (set to `azure-openai,ai-foundry,aws-bedrock-mantle,gemini-openai`) to enforce OpenAI-compatible routing only — preventing a `/models/chat/completions` call from accidentally landing on a native `aws-bedrock` (Converse), `gemini` (`generateContent`), or `anthropic` (Messages) pool that has no `/chat/completions` surface. Also used by the Unified AI `inference` api-type for the same reason.
- backendPools: JArray containing all backend pool configurations

**Output Variables:**
- targetBackendPool: The selected backend pool name, `"non-llm-request"` for GET operations, or error code (ERROR_NO_MODEL, ERROR_NO_ALLOWED_POOLS)
- targetPoolType: The type of the selected backend pool (e.g., "azure-openai", "ai-foundry", "non-llm-request")

> **Why the `compatiblePoolTypes` filter matters.** When the same model id is registered against both a native pool and an OpenAI-compat pool — e.g. `eu.amazon.nova-lite-v1:0` appearing on both an `aws-bedrock` (Converse) backend and an `aws-bedrock-mantle` (`/v1/chat/completions`) backend — the unfiltered first-match-wins selection can route an OpenAI-compat request to the native pool. The native pool has no `/chat/completions` rewrite branch in `set-backend-authorization`, so the unrewritten path (e.g. `/chat/completions`) reaches AWS Bedrock and produces `com.amazon.coral.service#UnknownOperationException`. Setting `compatiblePoolTypes` on the inbound API surface makes the gateway skip incompatible pools and pick the right one.

#### Step 4: Authentication & Routing (set-backend-authorization)

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
| `ai-foundry` | APIM's Managed Identity → Cognitive Services | None (or `/models/` prefix when `skipBackendUrlRewrite` is not set) |
| `azure-openai` | APIM's Managed Identity → Cognitive Services | Injects `/deployments/{model}/` (skipped when `skipBackendUrlRewrite` is set) |
| `aws-bedrock-mantle` | Native backend authorization (API key on backend resource) | Rewrites Universal LLM `/models/{op}` → `/v1/{op}` (chat/completions, responses, models) |
| `gemini-openai` | Native backend authorization (API key on backend resource) | Rewrites Universal LLM `/models/{op}` → `/v1beta/openai/{op}` (chat/completions, embeddings, models) |
| `aws-bedrock` | AWS SigV4 (IAM access keys via named values) | Path constructed as `/model/{model}/converse` by path-builder (Unified AI only) |
| `gemini` | API key (query parameter) | Path constructed by path-builder (Unified AI only) |
| `anthropic` | API key (`x-api-key` header) | Path forwarded as-is (Unified AI `/claude/...`) |
| `external` | Backend credentials | None |

> **Note:** When the Unified AI API sets `skipBackendUrlRewrite`, the `set-backend-authorization` fragment skips URL rewriting because the `path-builder` fragment handles URI construction instead.

### Unified AI API Routing Flow

The Unified AI API uses a different routing approach: instead of relying on APIM named path parameters, it uses wildcard operations (`/*`) and dynamically detects the API type from the request path. This allows a single API endpoint to serve OpenAI, Inference, Responses, and Gemini patterns.

#### Supported API Types

The `metadata-config` fragment defines the supported API types with their path patterns:

| API Type | Base Path | Path Segment | Default API Version | Use Case |
|----------|-----------|--------------|---------------------|----------|
| `openai` | `/openai` | `/deployments` | `2024-02-15-preview` | Azure OpenAI chat completions |
| `inference` | `/models` | `/models` | `2024-05-01-preview` | AI Foundry inference models |
| `responses` | `/openai/responses` | `/responses` | `2025-03-01-preview` | OpenAI Responses API |
| `responses-v1` | `/openai/v1/responses` | `/openai/v1/responses` | `v1` | OpenAI Responses API (v1) |
| `openai-v1` | `/openai/v1` | `/deployments` | `v1` | OpenAI v1 completions |
| `geminiopenai` | `/v1beta/openai` | `/v1beta/openai` | `v1beta` | Google Gemini OpenAI-compatible |
| `bedrock` | `/model` | `/model` | `bedrock-2024-04-15` | Amazon Bedrock Converse API |

Each API type can optionally define a `backend` property to override pool-based model routing and route to a specific backend directly (via `apiTypeOverrideBackend`).

#### Step 1: Metadata Configuration (metadata-config)

Loads the centralized JSON configuration containing model definitions, API type specs, cache settings, and timeout settings.

**Output Variable:**
- `metadata-config`: Raw JSON string with the full configuration

The models section is dynamically generated from `llmBackendConfig` during Bicep deployment. The API types, cache settings, and timeout settings are static definitions.

#### Step 2: Cache Management (central-cache-manager)

Parses the `metadata-config` JSON and manages caching using APIM's internal cache for performance.

**Cache Behavior:**
- Cache key: `metadata-config-v{config-version}` (e.g., `metadata-config-v1.0.0`)
- TTL: Configurable via `cache-settings.ttl-seconds` (default: 300 seconds)
- Bypass: Send `UAIG-Config-Cache-Bypass: true` header to force a cache miss

**Output Variables:**
- `config-models`: JObject — model name → backend, apiVersion, timeout
- `config-api-types`: JObject — api-type → base-path, path-segment, api-version
- `config-timeout-settings`: JObject — streaming-multiplier and other timeout settings
- `cache-operation`: `"cache-hit"` or `"cache-miss"`

#### Step 3: Request Processing (request-processor)

Analyzes the incoming request to detect the API type and extract the model. This fragment replaces `set-llm-requested-model` for the Unified AI API.

**API Type Detection:**
1. Removes the API path prefix (`/unified-ai`) from the request URL
2. Matches the remaining path against configured `base-path` patterns in `config-api-types` using **case-insensitive prefix matching (`StartsWith`)** and selects the **longest matching base-path** so nested prefixes (e.g. `/openai/v1/responses` vs `/openai/v1` vs `/openai`) always resolve to the most specific api-type independent of declaration order
3. Rejects unrecognized paths with a `403 Forbidden` response (`PathNotAllowed`). For example, `/v2/openai/chat/completions` does **not** match `/openai` and is rejected with 403

**Model Extraction** (in priority order):
1. **GET requests, and DELETE on `/responses*`**: Returns `"non-llm-request"` (operation-level policies handle these). For `/responses/{id}` GET/DELETE the model is later **hydrated from the response-id ownership cache** by `responses-id-security` so model-based routing in `set-target-backend-pool` and `path-builder` still selects the original backend.
2. **Request body**: Extracts `model` field from JSON body
3. **URL path segment**: Extracts model from path using `api-path-segment` (e.g., `/openai/deployments/{model}/...`)

> **Note**: `request-processor` no longer short-circuits GET/DELETE requests — `api-type`, `api-base-path`, `apiTypeOverrideBackend`, and `skipBackendUrlRewrite` are always populated. This is required so that `path-builder` can correctly construct backend paths such as `{api-base-path}/{response-id}` for Responses API GET/DELETE after `responses-id-security` hydrates the model.

**Output Variables:**
- `api-type`: Detected API type (e.g., `openai`, `inference`, `geminiopenai`)
- `requestedModel`: Extracted model identifier (compatible with shared fragments)
- `routing-processed-path`: Request path with API prefix removed
- `response-id`: Response ID for responses API operations
- `parsed-request-body`: Parsed JSON body for downstream use
- `selected-api-version`: API version for backend requests (model-specific or api-type default)
- `is-streaming`: Whether the request has `stream: true`
- `apiTypeOverrideBackend`: Backend override from api-type config (empty for pool-based routing)
- `skipBackendUrlRewrite`: Always `"true"` — tells `set-backend-authorization` to defer URI rewriting to `path-builder`

#### Step 4: Security Handler (security-handler)

Provides unified authentication across all API endpoints.

- **API Key**: Always required (APIM subscription validation)
- **JWT**: Optionally enforced per product via the `jwtRequired` context variable
- **App Roles**: Optionally enforced when `requiredRoles` is set in the product policy

**Output Variables:**
- `auth-type`: `"api-key"`, `"jwt"`, `"api-key-jwt"`, or `"none"`
- `user-id`: From JWT `azp` claim or subscription name
- `jwt-roles`: Comma-separated list of app roles from the JWT token

#### Steps 5–8: Shared Fragment Execution

Steps 5 through 8 use the same shared fragments as the Universal LLM and Azure OpenAI APIs:
- **validate-model-access**: Checks `allowedModels` per product. Runs against the alias name (when the request used one) so RBAC stays at the contract level.
- **set-backend-pools**: Loads the gateway's `backendPools` JArray (real pools + alias **virtual pool entries**).
- **set-target-backend-pool**: Two responsibilities now —
  1. **Alias resolution.** When `requestedModel` matches an alias virtual pool (`isAlias=true`), the fragment filters the alias members by the inbound API surface's `compatiblePoolTypes`, picks one based on `strategy` (`priority` / `weighted`), sets `is-alias`, `original-model-alias`, the resolved `requestedModel`, the picked member's `targetBackendPool` / `targetPoolType` / `targetAuthType` / `targetAuthConfigNamedValue`, and exposes `alias-fallback-members` (an ordered JArray pre-resolved with each remaining member's poolName / poolType / authType) for the retry block.
  2. **Direct model→pool match.** When the model is not an alias, the existing pool match logic runs unchanged. For Unified AI, also checks `apiTypeOverrideBackend` — when set, bypasses pool matching and routes to the specified backend directly.
- **resolve-model-alias**: Slim post-resolution body rewrite — replaces the JSON body's `model` field with `requestedModel` so backends see the real model name. No-op when `is-alias=false`.
- **set-backend-authorization**: Sets managed identity token / api-key header / SigV4 signing as appropriate, then `set-backend-service`. Skips URL rewriting because `skipBackendUrlRewrite` is set by `request-processor`.

#### Step 9: Path Builder (path-builder)

Reconstructs the backend URI from known components based on the detected API type. This ensures all requests route to valid backend endpoints.

**Path Construction by API Type:**

| API Type | Backend Path Pattern |
|----------|---------------------|
| `openai` (default) | `{api-base-path}/deployments/{model}/chat/completions` |
| `inference` | `{api-base-path}/chat/completions` |
| `geminiopenai` | `{api-base-path}/chat/completions` |
| `openai-v1` | `{api-base-path}/chat/completions` |
| `responses` / `responses-v1` | `{api-base-path}` or `{api-base-path}/{response-id}` |
| `bedrock` | `/model/{model}/converse` |

**Additional Behavior:**
- Auto-injects `api-version` query parameter for `responses` and `inference` types
- Adds `model` field to request body if not present (for `openai` type)
- Non-LLM requests (GET/DELETE) skip path building entirely (handled by operation-level policies)

#### Step 10: Response Headers (set-response-headers)

Injects `UAIG-*` debug headers into responses when `enableResponseHeaders` is set to `true` in the product policy.

| Header | Source | Description |
|--------|--------|-------------|
| `UAIG-Auth-Type` | security-handler | Authentication method used |
| `UAIG-User-Id` | security-handler | User identifier |
| `UAIG-Subscription` | security-handler | Subscription name |
| `UAIG-Model-Id` | request-processor | Requested model |
| `UAIG-API-Type` | request-processor | Detected API type |
| `UAIG-Processed-Path` | request-processor | Path after prefix removal |
| `UAIG-API-Version` | request-processor | API version sent to backend |
| `UAIG-Is-Streaming` | request-processor | Whether request is streaming |
| `UAIG-Backend` | set-target-backend-pool | Backend that served the request |
| `UAIG-Final-Path` | path-builder | Reconstructed backend path |
| `UAIG-Cache-Operation` | central-cache-manager | `cache-hit` or `cache-miss` |

### Unified AI Deployment Discovery

The Unified AI API includes named operations for model discovery that bypass the wildcard routing:

- **`GET /unified-ai/deployments`** — Lists all available models the subscription has access to (filtered by product policy)
- **`GET /unified-ai/deployments/{deployment-id}`** — Returns details for a specific model, or `404` if not found

These operations use the shared `get-available-models` fragment and are handled by operation-level policies, not the wildcard catch-all.

## Model Aliases

Model aliases let an admin expose a single client-facing name (e.g. `adv-gpt`, `multi-cloud-claude`) that the gateway resolves at runtime to one of several real underlying models — possibly spanning different cloud providers. Clients depend only on the alias, while the platform team is free to switch the underlying line-up: useful for graceful model retirements, A/B testing, and **cross-provider load balancing / fallback transparent to the client**.

### Aliases are virtual backend pools

Each entry in `modelAliases` becomes a **virtual pool entry inside the same `backendPools` JArray that real pools live in**. The runtime alias resolution and the retry-time member walk both ride on the same `set-target-backend-pool` + retry pipeline that real models use, with no special-case code paths.

| Capability | Direct model | Alias |
|---|---|---|
| Pool matching | `set-target-backend-pool` walks `backendPools` for a match on the model name. | Same fragment, but matches the alias's virtual pool entry first (entries with `isAlias=true`). |
| Strategy | Pool members use APIM-native priority/weight (real APIM Backend Pool resource). | Alias members use **policy-level** priority/weight encoded into the alias virtual pool entry. |
| Retry / fallback | APIM-native pool-level retry on 429/5xx. | Pool-level retry **plus** alias-fallback walk across remaining members on 429/5xx — supported on the Azure OpenAI API, Universal LLM API, and Unified AI API. |
| Cross-provider | A direct request to a model is locked to that model's pool. | Alias members can mix Azure OpenAI, Bedrock, Gemini, Anthropic, etc. — fallback walks across providers. |
| Compatible-pool-types filter | Applied at pool selection. | Applied at member selection, so an alias spanning native + OpenAI-compat surfaces only resolves to members compatible with the inbound surface. Members with no compatible pool are silently skipped. |
| Body / URL rewrite | Driven by the resolved poolType + operation. | Same — once a member is picked, request takes the same code paths a direct call to that real model would have taken. |

The same alias map is honored consistently across **all three LLM endpoints**:

- **Azure OpenAI API** — `/openai/deployments/{alias}/chat/completions` (alias members must be `azure-openai` or `ai-foundry` pools).
- **Universal LLM API** — `/models/chat/completions` with `"model": "{alias}"` (alias members must be OpenAI-compat-capable pool types: `azure-openai`, `ai-foundry`, `aws-bedrock-mantle`, `gemini-openai`).
- **Unified AI API** — `/unified-ai/v1/chat/completions` (OpenAI-compat surface) and the native prefixes `/unified-ai/bedrock/...`, `/unified-ai/gemini/...`, `/unified-ai/claude/...` (each restricts alias members to its own pool type).

### Resolution flow

The fragments execute in this order on every API surface:

```
1. validate-model-access      → RBAC against alias name (if used)
2. set-backend-pools           → loads `backendPools` JArray (real pools + alias virtual pools)
3. set-target-backend-pool     → ALIAS RESOLUTION + member pick + targeting variables
                                  + alias-fallback-members for retry
4. resolve-model-alias         → body rewrite (model field) when is-alias=true; no-op otherwise
5. set-backend-authorization   → header/SigV4/managed-identity per resolved poolType
6. path-builder (Unified AI)   → URL rewrite per resolved poolType + operation
backend retry                  → walks alias-fallback-members on 429/5xx (pre-stream only)
```

When the requested model is **not** an alias, step 3 falls through to its existing model→pool match logic and step 4 is a no-op — direct routing is preserved unchanged.

### Resolution Strategies

| Strategy | Behavior | Best For |
|----------|----------|----------|
| `priority` (default) | The first compatible member in `models` is always chosen. The remaining compatible members form the fallback list in order. | Production routing with a preferred primary and well-defined hot-spares. |
| `weighted` | A compatible member is picked at random with probability proportional to `weights`. The remaining compatible members form a fallback list (round-walk after the picked one). | A/B testing, controlled rollout of a new model, blended traffic across model families. |

### Cross-Model / Cross-Provider Fallback

The `<retry>` block in **all three** API policies (Azure OpenAI, Universal LLM v2, Unified AI) is alias-aware. When `is-alias` is `true`, the retry budget is extended by the size of `alias-fallback-members`. On a transient failure (429 / 5xx) from the currently selected member, the policy:

1. Increments `alias-retry-index` and reads the next entry from `alias-fallback-members`.
2. Sets `requestedModel`, `targetBackendPool`, `targetPoolType`, `targetAuthType`, `targetAuthConfigNamedValue` directly from that entry — no second pool match needed because the entry is already pre-resolved.
3. Re-runs `resolve-model-alias` (body rewrite) + `set-backend-authorization` (+ `path-builder` for Unified AI; or `rewrite-uri` for Azure OpenAI).

> **Pre-stream only.** Once the response stream has started, the body is committed and cross-model fallback is not possible.

### Compatible-pool-types filter on alias members

Each API surface advertises `compatiblePoolTypes` — a CSV of pool types it can route to (set by `request-processor` for the Unified AI API based on the matched api-type, and set inline by the Universal LLM API and Azure OpenAI API policies). The alias resolution step applies this filter to the alias's `members[]` and skips any member whose underlying pools do not match. This means:

- An alias `multi-cloud-chat` that includes `claude-haiku-4-5` (anthropic) + `gpt-4.1` (Azure OpenAI) + `openai.gpt-oss-120b` (aws-bedrock-mantle) called via **Universal LLM** (`/models/chat/completions`) considers only the Azure OpenAI and Bedrock-Mantle members — Anthropic native is filtered out because Universal LLM is OpenAI-compat-only.
- The same alias called via **Unified AI native** `/claude/v1/messages` considers only the Anthropic member.
- If the alias has no member compatible with the inbound surface, the request returns `400 alias_no_compatible_member` with the alias name, the surface's compatible CSV, and the total member count for diagnostics.

### Access Control

The `validate-model-access` fragment runs **before** `set-target-backend-pool`. The product policy's `allowedModels` therefore controls access to the **alias name** (the contract-level identifier the client sees), not the underlying real models. Granting `allowedModels = "multi-cloud-claude"` exposes only the alias.

### Diagnostics

| Source | Where to look |
|---|---|
| `original-model-alias`, `is-alias`, `alias-fallback-members` | APIM trace policy (`Set-Target-Backend-Pool` + `Alias-Fallback` sources), `UAIG-*` debug headers (Unified AI when `enableResponseHeaders` is true) |
| Resolved model | `requestedModel` variable, `UAIG-Model-Id` header, App Insights `customDimensions.deploymentName` |
| Cross-model fallback hops | `alias-retry-index` variable + per-hop `Alias-Fallback` traces (one per fallback hop on every API surface) |

### Configuration

Aliases are declared in the `modelAliases` array of the LLM Backend Onboarding `.bicepparam` file. Each onboarding deployment regenerates:

| Output | Purpose |
|---|---|
| `set-backend-pools` virtual pool entries (in the `backendPools` JArray) | Runtime alias resolution + retry-time fallback walk. **Sole source of runtime data.** |
| `get-available-models` JObject entries | First-class alias entries in `GET /deployments` responses. |
| `metadata-config` (`model-aliases` JSON section) | Informational copy in the cached config (used by tooling that introspects the cache). |

All three are regenerated on every deployment so the views stay in sync. See [LLM Backend Onboarding — Model Aliases](../bicep/infra/llm-backend-onboarding/README.md#model-aliases) for the full property reference, examples, and error-code reference.

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

The Unified AI API extends this with configurable timeouts from `metadata-config`:
- **Base timeout**: 120 seconds (or model-specific value from config)
- **Streaming multiplier**: 3x (configurable via `timeout-settings.streaming-multiplier`)
- Model-specific timeouts are defined in the `models` section of `metadata-config`

## RBAC Integration

Access contracts (applied at a product level) can restrict which backend pools a client can use:

```xml
<!-- Product Policy for specific use case -->
<se t-variable name="allowedBackendPools" 
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

### Shared Fragments (All APIs)

| Fragment | Purpose |
|----------|---------|
| `set-backend-pools` | Loads backend pool configurations |
| `set-target-backend-pool` | Matches model to backend pool with RBAC (extended with `apiTypeOverrideBackend` for Unified AI) |
| `set-backend-authorization` | Sets authentication and backend service (respects `skipBackendUrlRewrite` for Unified AI) |
| `set-llm-usage` | Collects token usage metrics |
| `validate-model-access` | Model access control per product |
| `resolve-model-alias` | Resolves a client-facing alias (e.g. `adv-gpt`) to an actual underlying model based on `priority` or `weighted` strategy. No-op when `requestedModel` is not an alias. |
| `get-available-models` | Returns filtered list of models for deployment discovery |
| `ai-foundry-compatibility` | CORS configuration for AI Foundry |
| `raise-throttling-events` | Sends throttling metrics on errors |

### Universal LLM / Azure OpenAI Only

| Fragment | Purpose |
|----------|---------|
| `set-llm-requested-model` | Extracts model from request body, URL path parameter, or URL path segment |

### Unified AI-Specific Fragments

| Fragment | Purpose |
|----------|---------|
| `metadata-config` | Centralized JSON configuration for models, API types, cache, and timeout settings |
| `central-cache-manager` | Caches and parses metadata configuration with version-keyed TTL |
| `request-processor` | Detects API type from path, extracts model, sets routing variables |
| `security-handler` | Unified authentication (API Key required + optional JWT per product) |
| `path-builder` | Reconstructs backend URI based on detected API type |
| `set-response-headers` | Injects UAIG-* debug headers when enabled |

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

### Unified AI API — OpenAI Pattern

```http
POST APIM_GATEWAY/unified-ai/openai/deployments/gpt-4o/chat/completions
Content-Type: application/json
api-key: <subscription-key>

{
  "messages": [{"role": "user", "content": "Hello"}]
}
```

**Flow:**
1. Load & cache metadata config
2. Request processor detects api-type: `"openai"` (path contains `/openai`)
3. Extract model: `"gpt-4o"` from path segment `/deployments/gpt-4o/...`
4. Security handler validates API key (JWT if required by product)
5. Find pool: `"gpt-4o-backend-pool"` (shared fragment)
6. Authenticate: Managed Identity token (shared fragment, URL rewrite skipped)
7. Path builder constructs: `/openai/deployments/gpt-4o/chat/completions`
8. Forward to backend with `api-version` query parameter

### Unified AI API — Inference Pattern (Foundry)

```http
POST APIM_GATEWAY/unified-ai/models/chat/completions
Content-Type: application/json
api-key: <subscription-key>

{
  "model": "DeepSeek-R1",
  "messages": [{"role": "user", "content": "Hello"}]
}
```

**Flow:**
1. Load & cache metadata config
2. Request processor detects api-type: `"inference"` (path contains `/models`)
3. Extract model: `"DeepSeek-R1"` from request body
4. Security handler validates API key
5. Find pool: `"DeepSeek-R1-backend-pool"` (shared fragment)
6. Authenticate: Managed Identity token
7. Path builder constructs: `/models/chat/completions`
8. Forward with `api-version=2024-05-01-preview`

### Unified AI API — Gemini Pattern

```http
POST APIM_GATEWAY/unified-ai/v1beta/openai/chat/completions
Content-Type: application/json
api-key: <subscription-key>

{
  "model": "gemini-2.0-flash",
  "messages": [{"role": "user", "content": "Hello"}]
}
```

**Flow:**
1. Load & cache metadata config
2. Request processor detects api-type: `"geminiopenai"` (path contains `/v1beta/openai`)
3. Extract model: `"gemini-2.0-flash"` from request body
4. Security handler validates API key
5. Find pool or use api-type override backend
6. Path builder constructs: `/v1beta/openai/chat/completions`
7. Forward to Gemini backend

### Unified AI API — Bedrock Pattern

```http
POST APIM_GATEWAY/unified-ai/bedrock/model/us.anthropic.claude-3-5-haiku-20241022-v1:0/converse
Content-Type: application/json
api-key: <subscription-key>

{
  "messages": [
    {
      "role": "user",
      "content": [{"text": "Hello"}]
    }
  ],
  "inferenceConfig": {
    "maxTokens": 512,
    "temperature": 0.5,
    "topP": 0.9
  }
}
```

**Flow:**
1. Load & cache metadata config
2. Request processor detects api-type: `"bedrock-native"` (path begins with `/bedrock`); reads `compatible-pool-types: 'aws-bedrock'` from the api-type config
3. Extract model: `"us.anthropic.claude-3-5-haiku-20241022-v1:0"` from the `/model/{id}/...` segment
4. Security handler validates API key
5. Pool resolver filters pools to `poolType == 'aws-bedrock'` (the `compatiblePoolTypes` filter prevents `aws-bedrock-mantle` OpenAI-compat pools from being matched even if they share the model name) and picks `"bedrock-us-east-1"`
6. Authenticate: AWS SigV4 (default) or `api-key-bearer` when the backend uses a Bedrock long-lived API key
7. Path builder strips the `/bedrock` prefix, leaving `/model/us.anthropic.claude-3-5-haiku-20241022-v1%3A0/converse`
8. Forward to Bedrock runtime endpoint

### Unified AI API — Gemini Native Pattern

```http
POST APIM_GATEWAY/unified-ai/gemini/v1beta/models/gemini-2.5-flash:generateContent
Content-Type: application/json
api-key: <subscription-key>

{
  "contents": [
    { "role": "user", "parts": [{ "text": "Hello" }] }
  ],
  "generationConfig": { "maxOutputTokens": 64 }
}
```

**Flow:**
1. Request processor detects api-type: `"gemini-native"` (path begins with `/gemini`); reads `compatible-pool-types: 'gemini'`
2. Extract model from `/models/{model}:` segment of the path
3. Pool resolver filters to `poolType == 'gemini'` and selects the matching backend
4. Auth fragment sets `x-goog-api-key` from the named value referenced by the pool's `authConfigNamedValue` (and strips any inherited `Authorization` header)
5. Path builder strips the `/gemini` prefix and forwards `/v1beta/models/gemini-2.5-flash:generateContent` unchanged
6. Forward to `generativelanguage.googleapis.com`

### Unified AI API — Anthropic Claude Native Pattern

```http
POST APIM_GATEWAY/unified-ai/claude/v1/messages
Content-Type: application/json
api-key: <subscription-key>

{
  "model": "claude-3-5-haiku-20241022",
  "max_tokens": 64,
  "messages": [{ "role": "user", "content": "Hello" }]
}
```

**Flow:**
1. Request processor detects api-type: `"claude-native"` (path begins with `/claude`); reads `compatible-pool-types: 'anthropic'`
2. Extract model from request body (`body.model` — Anthropic Messages has no model in the URL)
3. Pool resolver filters to `poolType == 'anthropic'`
4. Auth fragment sets `x-api-key` from the named value referenced by the pool's `authConfigNamedValue` plus `anthropic-version` from the `{{anthropic-version}}` named value
5. Path builder forces final path to `/v1/messages` and ensures the body's `model` field is populated from the resolved routing id
6. Forward to `api.anthropic.com`

### Pool isolation: `compatible-pool-types`

Each api-type in `frag-metadata-config.xml` can declare a `compatible-pool-types` CSV. The pool resolver in `frag-set-target-backend-pool.xml` skips any pool whose `poolType` is not in that list **before** matching on model name. This is what lets the same model id appear in two pools — for example `claude-3-5-haiku-20241022` on both an `aws-bedrock` (native Converse) pool and an `aws-bedrock-mantle` (OpenAI-compat) pool — without requiring suffix tricks: `/bedrock/...` only routes to `aws-bedrock`, `/v1/chat/completions` (api-type `openai-compat`) only routes to `ai-foundry`, `azure-openai`, `aws-bedrock-mantle`, or `gemini-openai`.

### Unified AI API — Model Discovery

```http
GET APIM_GATEWAY/unified-ai/deployments
api-key: <subscription-key>
```

**Flow:**
1. Request processor identifies as `"non-llm-request"` (GET method)
2. Operation-level policy handles the request directly
3. `get-available-models` fragment returns filtered model list based on product access
4. Returns JSON array of available deployments with model metadata

## Troubleshooting

| Error | Cause | Solution |
|-------|-------|----------|
| `400: Model could not be detected` | No model in body or URL | Include `"model"` in request body or path |
| `400: Model 'x' is not supported` | No backend supports model | Check backend configuration |
| `403: backend_pool_access_forbidden` | RBAC blocks pool access | Update product's `allowedBackendPools` |
| `403: PathNotAllowed` | Unified AI request path doesn't match any configured API type | Check `metadata-config` api-types base-paths |
| `401: product_required` | Request not associated with a product subscription | Provide a valid `api-key` header |
| `429: Too Many Requests` | All backends throttling | Wait for retry-after or add capacity |
| `503: Backend pool unavailable` | Circuit breaker open | Wait for trip duration to expire |
| `403: AWS SigV4 auth failure` | Invalid AWS credentials for Bedrock | Verify `aws-access-key`, `aws-secret-key`, and `aws-region` named values contain real credentials (not `NOT_CONFIGURED`) |
| `500: AWSCredentialsNotConfigured` | AWS named values still set to placeholder defaults | Redeploy with `awsAccessKey`, `awsSecretKey`, `awsRegion` parameters or update named values manually |

**Unified AI Debug Headers:**
When `enableResponseHeaders` is set to `true` in the product policy, response headers like `UAIG-API-Type`, `UAIG-Backend`, and `UAIG-Final-Path` help trace the routing decisions made by the gateway.

## Related Guides

- [LLM Backend Onboarding](../bicep/infra/llm-backend-onboarding/README.md) - Configure backends
- [Onboarding New API Types](unified-ai-api-type-onboarding.md) - Add new API types to the Unified AI API
- [Citadel Access Contracts](citadel-access-contracts.md) - Configure use case access
