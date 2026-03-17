# AI Citadel Access Contracts Policy

This guide to expand on what policies are available out of the box for use with the AI Citadel Access Contracts Bicep package, and how to customize them for each use case being onboarded.

## Available Policies Snippets

The following policy snippets can be applied as needed for the product policy access as part of the `Citadel Access Contracts`:

### Model Access Control Policy

The model access control policy restricts which LLM models a product can access. This is implemented using the `validate-model-access` policy fragment.

**Basic Usage:**

```xml
<inbound>
    <!-- Extract and validate model parameter from request -->
    <include-fragment fragment-id="set-llm-requested-model" />

    <!-- Setting allowed models variable (comma-separated list) -->
    <set-variable name="allowedModels" value="gpt-4o,deepseek-r1" />
    
    <!-- Validate model access based on allowedModels -->
    <include-fragment fragment-id="validate-model-access" />
</inbound>
```

**How It Works:**

1. The `set-llm-requested-model` fragment extracts the model from the request:
   - From request body `{"model": "gpt-4o", ...}` for Universal LLM API
   - From URL path `/deployments/{deployment-id}/...` for Azure OpenAI API
   - Returns `"non-llm-request"` for GET operations (like listing available models)

2. The `validate-model-access` fragment validates the requested model:
   - **Non-LLM requests** (GET operations): Usually reference meta data endpoints that discover allowed models
   - **Empty `allowedModels`**: All models are allowed
   - **Model not in list**: Returns 401 Unauthorized with structured JSON error

**Error Response Format:**

When access is denied, the policy returns a structured JSON error:

```json
{
    "error": {
        "message": "Access to model 'gpt-4' is not allowed for this product.",
        "type": "access_error",
        "code": "unauthorized_model_access",
        "allowed_models": "gpt-4o,deepseek-r1"
    }
}
```

**Configuration Options:**

| Variable | Description | Example |
|----------|-------------|---------|
| `allowedModels` | Comma-separated list of allowed model names (no white-space) | `"gpt-4o,deepseek-r1,Phi-4"` |

>**NOTE:** Non-LLM requests (such as GET operations for listing available models) are automatically allowed and do not require model validation. This ensures auxiliary endpoints function without needing a model parameter.

### Model Capacity Management Policy

The below policy snippet, enforces a token limit per subscription but for all models being access via this product.

```xml
<inbound>
    <!-- Capacity management - Subscription Level: allow only assigned tpm for each HR use case subscription -->
    <llm-token-limit counter-key="@(context.Subscription.Id)" 
        tokens-per-minute="300" 
        estimate-prompt-tokens="false" 
        tokens-consumed-header-name="consumed-tokens" 
        remaining-tokens-header-name="remaining-tokens" 
        token-quota="100000" 
        token-quota-period="Monthly" 
        retry-after-header-name="retry-after" />
</inbound>
```

To further control capacity management per model per subscription, you can extend the above policy snippet to include model specific token limits by leveraging the `requestedModel` variable set via the `set-llm-requested-model` fragment.

```xml
<!-- Inboud Section of the Product Policy -->
<!-- Extract and validate model parameter from request and save it to requestedModel -->
<include-fragment fragment-id="set-llm-requested-model" />

<!-- Capacity management - Subscription + Model Level: allow only assigned tpm for each model per subscription -->
<choose>
    <when condition="@((string)context.Variables["requestedModel"] == "gpt-4o")">
        <llm-token-limit 
            counter-key="@(context.Subscription.Id + "-" + context.Variables["requestedModel"])" 
            tokens-per-minute="10000" 
            estimate-prompt-tokens="false" 
            tokens-consumed-header-name="consumed-tokens" 
            remaining-tokens-header-name="remaining-tokens" 
            token-quota="100000"
            token-quota-period="Monthly"
            retry-after-header-name="retry-after" />
    </when>
    <when condition="@((string)context.Variables["requestedModel"] == "DeepSeek-R1")">
        <llm-token-limit 
            counter-key="@(context.Subscription.Id + "-" + context.Variables["requestedModel"])" 
            tokens-per-minute="2000" 
            estimate-prompt-tokens="false" 
            tokens-consumed-header-name="consumed-tokens" 
            remaining-tokens-header-name="remaining-tokens" 
            token-quota="10000"
            token-quota-period="Weekly"
            retry-after-header-name="retry-after" />
    </when>
    <otherwise>
        <!-- Default model token limit for other models -->
        <llm-token-limit 
            counter-key="@(context.Subscription.Id + "-default")" 
            tokens-per-minute="1000" 
            estimate-prompt-tokens="false" 
            tokens-consumed-header-name="consumed-tokens" 
            remaining-tokens-header-name="remaining-tokens" 
            token-quota="5000"
            token-quota-period="Monthly"
            retry-after-header-name="retry-after" />
    </otherwise>
</choose>
```

### LLM Usage Customization Policy

By default, AI Citadel Gateway is configured to collect the following data points for LLM usage tracking:
- Standard Dimensions (currently can't be modified):
  - Region
  - Service ID
  - Service Name
  - Service Type
- Citadel Added Dimensions:
    - Product Name
    - DeploymentName (based on requestedModel variable)
    - Backend ID
    - appId (looks for variable named appId, fall back to subscription ID and then to "Portal-Admin" if not found)
- Custom dimensions:
    - customDimension1 (by default looks for a variable named customDimension1)
    - customDimension2 (by default looks for a variable named customDimension2)

Standard setup is already included in the default policies, but you can customize it further by setting up the following variables in the product policy inbound section:

```xml
<!-- Map appId from x-app-id header with safe defaults -->
<set-variable name="appId" value="@{
    var requestedAppId = context.Request.Headers.GetValueOrDefault("x-app-id", null);
    if (!string.IsNullOrEmpty(requestedAppId))
    {
        return requestedAppId;
    }
    return context.Subscription?.Id ?? "Portal-Admin";
}" />

<!-- Map customDimension1 from x-enduser-id header -->
<set-variable name="customDimension1" value="@(
    context.Request.Headers.GetValueOrDefault("x-sub-agent-id", "general-agent")
)" />

<!-- Map customDimension2 from x-usecase-id header -->
<set-variable name="customDimension2" value="@(
    context.Request.Headers.GetValueOrDefault("x-enduser-id", "anonymous-enduser")
)" />

```

>NOTE: The above policy fragment assumes that the client application is passing `x-app-id`, `x-sub-agent-id` and `x-enduser-id` headers in the request. You can modify the header names as per your requirements or use different approach to set these variables.

### Semantic Cache Policy

TBD

### Configuring Alerts Policy

Collecting throttling events can help in setting up alerts in Application Insights. You can configure the following variables in the product policy outbound section to customize the throttling event details:

```xml
<on-error>
    <base />
    <!-- Raising throttling events (http 429 only) can help in setting up alerts in App Insights -->
    <!-- Set the following variables to customize the throttling event details -->
    <set-variable name="productName" value="@(context.Product?.Name?.ToString() ?? "Portal-Admin")" />
    <set-variable name="deploymentName" value="@((string)context.Variables.GetValueOrDefault<string>("requestedModel", "DefaultModel"))" />
    <set-variable name="appId" value="@((string)context.Variables.GetValueOrDefault<string>("appId", context.Subscription?.Id ?? "Portal-Admin-Sub"))" />
    <include-fragment fragment-id="raise-throttling-events" />
</on-error>
```

Based on this policy, you can configure alerts in Application Insights to monitor for high throttling events and take necessary actions.

>NOTE: Detailed guide on how to setup throttling events handling can be found in [Throttling Events Handling Guide](./throttling-events-handling.md)


### Content Safety Policy

Content safety can be enforced at a gateway level using the built-in content safety policy. You can configure the content safety policy to block or flag content based on your organization's requirements.

```xml
<inbound>
    <!-- Content Safety Policy -->
    <!-- Failure to pass content safety will result in 403 error -->
    <llm-content-safety backend-id="content-safety-backend" shield-prompt="true">
        <!-- 0 is most restrictive and can be set up-to 7 -->
        <categories output-type="EightSeverityLevels">
            <category name="Hate" threshold="3" />
            <category name="Violence" threshold="3" />
        </categories>
    </llm-content-safety>
    <!-- End of Content Safety Policy -->
</inbound>
```

### JWT Authentication Policy

JWT (JSON Web Token) authentication adds a second security layer on top of subscription API keys. When enabled for a product, clients must provide both an `api-key` header and an `Authorization: Bearer {token}` header.

JWT validation is handled by the unified `security-handler` policy fragment, which is included in **all three API endpoints** (Azure OpenAI API, Universal LLM API, and Unified AI API). The fragment validates tokens against any OAuth 2.0 / OpenID Connect identity provider configured via APIM named values (Microsoft Entra ID, Auth0, Okta, etc.).

**Prerequisites:**
- APIM named values configured: `JWT-TenantId`, `JWT-AppRegistrationId`, `JWT-Issuer`, `JWT-OpenIdConfigUrl`
- For Microsoft Entra ID: Run the `bicep/infra/entra-id-setup` module to auto-provision app registration and named values
- For other identity providers: Manually configure the APIM named values with the appropriate OpenID Connect discovery endpoint, audience, and issuer

**APIM Named Values for JWT Configuration:**

| Named Value | Description | Example (Entra ID) | Example (Auth0) |
|-------------|-------------|---------------------|-----------------|
| `JWT-OpenIdConfigUrl` | OpenID Connect discovery endpoint | `https://login.microsoftonline.com/{tenant}/v2.0/.well-known/openid-configuration` | `https://{domain}/.well-known/openid-configuration` |
| `JWT-Issuer` | Expected token issuer | `https://login.microsoftonline.com/{tenant}/v2.0` | `https://{domain}/` |
| `JWT-AppRegistrationId` | Expected audience claim | `api://{client-id}` | `https://your-api-identifier` |

**Basic Usage - Enable JWT with Gateway Defaults:**

```xml
<inbound>
    <base />
    <!-- Enable JWT requirement for this product -->
    <set-variable name="jwtRequired" value="true" />
    
    <!-- Other policies (model access, capacity, etc.) -->
</inbound>
```

**Advanced Usage - Enable JWT with Custom Identity Provider:**

Access contracts can override the gateway's default JWT settings by setting custom variables. The `security-handler` checks for these overrides first, then falls back to the APIM named values if not set.

| Variable | Description | Falls back to Named Value |
|----------|-------------|---------------------------|
| `jwtAudience` | Custom audience claim to validate | `JWT-AppRegistrationId` |
| `jwtIssuer` | Custom token issuer to validate | `JWT-Issuer` |
| `jwtOpenIdConfigUrl` | Custom OpenID Connect discovery URL | `JWT-OpenIdConfigUrl` |

```xml
<inbound>
    <base />
    <!-- Enable JWT requirement -->
    <set-variable name="jwtRequired" value="true" />
    
    <!-- Override JWT settings for a different identity provider (e.g., Auth0, Okta, separate Entra tenant) -->
    <set-variable name="jwtAudience" value="https://my-custom-api-audience" />
    <set-variable name="jwtIssuer" value="https://my-idp.example.com/" />
    <set-variable name="jwtOpenIdConfigUrl" value="https://my-idp.example.com/.well-known/openid-configuration" />
    
    <!-- Other policies (model access, capacity, etc.) -->
</inbound>
```

You can override any combination of settings — unset variables fall back to the gateway defaults:

```xml
<inbound>
    <base />
    <set-variable name="jwtRequired" value="true" />
    
    <!-- Only override audience (issuer and OpenID config use gateway defaults) -->
    <set-variable name="jwtAudience" value="api://custom-audience-for-this-product" />
</inbound>
```

**How It Works:**

1. The `security-handler` fragment (included in the API-level policy via `<base />`) detects the authentication method:
   - `api-key` — only subscription key provided
   - `jwt` — only Bearer token provided
   - `api-key-jwt` — both provided
   - `none` — neither provided

2. API key is always validated first (APIM subscription validation)

3. If `jwtRequired` is `"true"` (set by product policy), JWT validation is enforced:
   - Token is validated against the OpenID Connect configuration endpoint
   - Audience, issuer, and signature are verified
   - User identity is extracted from the `azp` claim (client credentials flow)
   - Custom overrides (`jwtAudience`, `jwtIssuer`, `jwtOpenIdConfigUrl`) are used if set, otherwise APIM named values apply

4. If a Bearer token is provided but `jwtRequired` is not set, the token is still validated (opportunistic validation)

5. This behavior is **uniform across all three API endpoints** — the same `security-handler` fragment executes regardless of whether the request arrives via Azure OpenAI, Universal LLM, or Unified AI API

**Output Variables Set by Security Handler:**

| Variable | Description | Example Values |
|----------|-------------|----------------|
| `auth-type` | Authentication method detected | `"api-key"`, `"jwt"`, `"api-key-jwt"`, `"none"` |
| `subscription-name` | APIM subscription name | `"LLM-HR-ChatAgent-DEV-SUB-01"` |
| `user-id` | User identifier (from JWT or subscription) | `"app-client-id"` or `"subscription-name"` |

**Error Responses:**

| Scenario | HTTP Status | Error Code | Message |
|----------|-------------|------------|----------|
| No API key | 401 | `unauthorized` | Access denied. A valid API key is required. |
| JWT required but missing | 401 | `jwt_required` | JWT Bearer token is required for this product. |
| Invalid JWT token | 401 | — | Access denied due to invalid or expired JWT bearer token. |
| JWT config missing | 503 | `jwt_not_configured` | JWT authentication is not configured properly on the gateway. |

**Token Acquisition (Client Credentials Flow - Entra ID):**

```http
POST https://login.microsoftonline.com/{tenant-id}/oauth2/v2.0/token
Content-Type: application/x-www-form-urlencoded

grant_type=client_credentials
&client_id={entra-app-client-id}
&client_secret={entra-app-client-secret}
&scope={audience}/.default
```

**Using JWT via Agent Access Contract Request:**

When using the `base-access-contract-request` module, enable JWT in the contract JSON:

```json
{
  "policies": {
    "jwtAuth": { "enabled": true }
  }
}
```

This automatically inserts the `<set-variable name="jwtRequired" value="true" />` snippet into the generated product policy.

**Combining JWT with Other Policies:**

JWT authentication works alongside all other access contract policies. A recommended order:

```xml
<inbound>
    <base />
    
    <!-- 1. JWT Authentication (must be first to reject unauthorized requests early) -->
    <set-variable name="jwtRequired" value="true" />
    
    <!-- 2. Model extraction and access control -->
    <include-fragment fragment-id="set-llm-requested-model" />
    <set-variable name="allowedModels" value="gpt-4o,gpt-4o-mini" />
    <include-fragment fragment-id="validate-model-access" />
    
    <!-- 3. Capacity management -->
    <llm-token-limit counter-key="@(context.Subscription.Id)" 
        tokens-per-minute="5000" 
        estimate-prompt-tokens="false" 
        token-quota="100000" 
        token-quota-period="Monthly" />
    
    <!-- 4. Content safety, PII, etc. -->
</inbound>
```

> **NOTE:** The `jwtRequired` variable must be set within the product policy inbound section (before or after `<base />`). The `security-handler` fragment reads this variable during API-level policy execution.

### PII Handling Policy

AI Citadel Gateway supports PII processing using built-in policy fragments that leverage Azure AI Language Service for detection and anonymization. This allows you to protect sensitive data when sending requests to LLM backends.

#### Available PII Policy Fragments

| Fragment | Purpose | Description |
|----------|---------|-------------|
| `pii-anonymization` | Inbound | Detects and replaces PII with placeholders before sending to backend |
| `pii-deanonymization` | Outbound | Restores original PII values in the response |
| `pii-state-saving` | Outbound | Logs PII processing activity to Event Hub for auditing |

#### Configuration Variables

The following variables can be set in your product policy to configure PII processing:

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `piiAnonymizationEnabled` | Yes | - | Set to `"true"` to enable PII anonymization |
| `piiConfidenceThreshold` | No | `"0.8"` | Minimum confidence score (0.0-1.0) for PII detection |
| `piiEntityCategoryExclusions` | No | `""` | Comma-separated list of PII categories to exclude (e.g., `"PersonType"`) |
| `piiDetectionLanguage` | No | `"en"` | Language code for detection. Use `"auto"` for multilingual content |
| `piiRegexPatterns` | No | `""` | JSON array of custom regex patterns for additional PII detection |
| `piiInputContent` | Yes | - | The content to be anonymized (typically the request body) |
| `piiStateSavingEnabled` | No | `"false"` | Set to `"true"` to enable Event Hub logging |

>**NOTE:** For a complete list of PII entity categories, see [Azure AI Language PII Entity Categories](https://learn.microsoft.com/en-us/azure/ai-services/language-service/personally-identifiable-information/concepts/entity-categories).

#### PII Anonymization/Deanonymization Setup

PII anonymization works in two phases:
1. **Inbound**: Detect and replace PII with placeholders (e.g., `<Person_0>`, `<Email_0>`)
2. **Outbound**: Restore original PII values in the LLM response

##### Inbound Configuration

```xml
<inbound>
    <!-- Enable PII Anonymization -->
    <set-variable name="piiAnonymizationEnabled" value="true" />
    
    <choose>
        <when condition="@(context.Variables.GetValueOrDefault<string>("piiAnonymizationEnabled") == "true")">
            
            <!-- Configure PII detection settings -->
            <set-variable name="piiConfidenceThreshold" value="0.8" />
            <set-variable name="piiEntityCategoryExclusions" value="PersonType" />
            <set-variable name="piiDetectionLanguage" value="en" />

            <!-- Optional: Configure custom regex patterns for additional PII detection -->
            <set-variable name="piiRegexPatterns" value="@{
                var patterns = new JArray {
                    new JObject {
                        ["pattern"] = @"\b\d{4}[- ]?\d{4}[- ]?\d{4}[- ]?\d{4}\b",
                        ["category"] = "CREDIT_CARD"
                    },
                    new JObject {
                        ["pattern"] = @"\b[A-Z]{2}\d{6}[A-Z]\b",
                        ["category"] = "PASSPORT_NUMBER"
                    }
                };
                return patterns.ToString();
            }" />
            
            <!-- Capture request body for PII processing -->
            <set-variable name="piiInputContent" value="@(context.Request.Body.As<string>(preserveContent: true))" />
            
            <!-- Apply PII anonymization -->
            <include-fragment fragment-id="pii-anonymization" />
            
            <!-- Replace request body with anonymized content -->
            <set-body>@(context.Variables.GetValueOrDefault<string>("piiAnonymizedContent"))</set-body>
        </when>
    </choose>
</inbound>
```

##### Outbound Configuration

```xml
<outbound>
    <!-- Store response body before processing -->
    <set-variable name="responseBodyContent" value="@(context.Response.Body.As<string>(preserveContent: true))" />
    
    <choose>
        <when condition="@(context.Variables.GetValueOrDefault<string>("piiAnonymizationEnabled") == "true" && 
                        context.Variables.ContainsKey("piiMappings"))">
            
            <!-- Set input for deanonymization -->
            <set-variable name="piiDeanonymizeContentInput" value="@(context.Variables.GetValueOrDefault<string>("responseBodyContent"))" />
            
            <!-- Apply PII deanonymization -->
            <include-fragment fragment-id="pii-deanonymization" />
            
            <!-- Optional: Enable PII processing audit logging to Event Hub -->
            <set-variable name="piiStateSavingEnabled" value="true" />
            <set-variable name="originalRequest" value="@(context.Variables.GetValueOrDefault<string>("piiInputContent"))" />
            <set-variable name="originalResponse" value="@(context.Variables.GetValueOrDefault<string>("responseBodyContent"))" />
            <include-fragment fragment-id="pii-state-saving" />
            
            <!-- Replace response with deanonymized content -->
            <set-body>@(context.Variables.GetValueOrDefault<string>("piiDeanonymizedContentOutput"))</set-body>
        </when>
        <otherwise>
            <!-- Pass through original response -->
            <set-body>@(context.Variables.GetValueOrDefault<string>("responseBodyContent"))</set-body>
        </otherwise>
    </choose>
</outbound>
```

#### Custom Regex Patterns

Extend Azure AI Language Service NLP detection with custom regex patterns for domain-specific PII:

```xml
<set-variable name="piiRegexPatterns" value="@{
    var patterns = new JArray {
        new JObject {
            ["pattern"] = @"\b\d{4}[- ]?\d{4}[- ]?\d{4}[- ]?\d{4}\b",
            ["category"] = "CREDIT_CARD"
        },
        new JObject {
            ["pattern"] = @"\b[A-Z]{2}\d{6}[A-Z]\b",
            ["category"] = "PASSPORT_NUMBER"
        },
        new JObject {
            ["pattern"] = @"\b\d{3}[-]?\d{4}[-]?\d{7}[-]?\d{1}\b",
            ["category"] = "NATIONAL_ID"
        },
        new JObject {
            ["pattern"] = @"\b784-\d{4}-\d{7}-\d{1}\b",
            ["category"] = "EMIRATES_ID"
        }
    };
    return patterns.ToString();
}" />
```

>**TIP:** Regex patterns are processed before calling Azure AI Language Service, allowing you to catch domain-specific patterns that NLP might miss.

#### Event Hub Logging

When `piiStateSavingEnabled` is set to `"true"`, the `pii-state-saving` fragment logs detailed PII processing information to Event Hub for auditing and compliance purposes. The logged data includes:

- Operation metadata (timestamp, API name, product, subscription)
- Processing configuration (confidence threshold, exclusions)
- Entity counts and categories detected
- PII mappings (for detailed audit trails)
- Content length metrics

>**NOTE:** For detailed implementation information and advanced scenarios, see [PII Masking Guide](../../../guides/pii-masking-apim.md).

## Examples of Applying Policies

TBD

### HR PII Support Agent Access Contract Policy

TBD

### Retail Shopping Assistant Access Contract Policy

TBD

## Extending default policies

You can extend the out-of-the-box policies by leveraging APIM extensive policy expressions and capabilities.