using 'main.bicep'

// ============================================================================
// LLM Backend Onboarding - Parameter File
// ============================================================================
// This parameter file configures LLM backends for an existing APIM instance.
// It creates backend resources, backend pools, and policy fragments for
// dynamic model-based routing.
//
// REQUIRED PARAMETERS: apim, apimManagedIdentity, llmBackendConfig
// OPTIONAL PARAMETERS: configureCircuitBreaker, deployUniversalLlmApi, universalLlmApiPath, tags
// ============================================================================

// ============================================================================
// REQUIRED: API Management (APIM) Configuration
// ============================================================================
// Specifies the target APIM instance where LLM backends will be onboarded.
// This APIM instance should already exist and have the necessary networking
// and security configurations in place.
//
// Properties:
// - subscriptionId: Azure subscription ID where APIM is deployed
// - resourceGroupName: Resource group containing the APIM instance
// - name: Name of the APIM service instance
// ============================================================================
param apim = {
  subscriptionId: '00000000-0000-0000-0000-000000000000' // Replace with your subscription ID
  resourceGroupName: 'rg-citadel-governance-hub'         // Replace with your APIM resource group
  name: 'apim-citadel-governance-hub'                    // Replace with your APIM name
}

// ============================================================================
// REQUIRED: APIM Managed Identity Configuration
// ============================================================================
// Specifies the user-assigned managed identity used by APIM for backend
// authentication. This identity must have the appropriate RBAC roles:
// - Cognitive Services OpenAI User (for Azure OpenAI backends)
// - Cognitive Services User (for AI Foundry backends)
//
// Properties:
// - subscriptionId: Azure subscription ID where the identity is deployed
// - resourceGroupName: Resource group containing the managed identity
// - name: Name of the user-assigned managed identity
// ============================================================================
param apimManagedIdentity = {
  subscriptionId: '00000000-0000-0000-0000-000000000000' // Replace with your subscription ID
  resourceGroupName: 'rg-citadel-governance-hub'         // Replace with your identity resource group
  name: 'id-apim-citadel'                                // Replace with your managed identity name
}

// ============================================================================
// REQUIRED: LLM Backend Configuration Array
// ============================================================================
// Defines all LLM backends that APIM will route requests to. Each backend
// object should have:
//
// Required Properties:
// - backendId: Unique identifier (used in APIM backend resource name)
// - backendType: 'ai-foundry' | 'azure-openai' | 'external'
// - endpoint: Base URL of the LLM service
// - authScheme: 'managedIdentity' | 'apiKey' | 'token'
// - supportedModels: Array of model objects (see below)
//
// Optional Properties (for load balancing):
// - priority: 1-5, default 1 (lower = higher priority for load balancing)
// - weight: 1-1000, default 100 (higher = more traffic share)
//
// Model Object Properties (in supportedModels array):
// - name: Model name (required) - e.g., 'gpt-4o', 'DeepSeek-R1'
// - sku: SKU name for the deployment (default: 'Standard')
// - capacity: Capacity/TPM quota (default: 100)
// - modelFormat: Model format identifier, e.g., 'OpenAI', 'DeepSeek', 'Microsoft' (default: 'OpenAI')
// - modelVersion: Version of the model (default: '1')
// - retirementDate: Retirement date in YYYY-MM-DD format (optional)
// - apiVersion: API version for OpenAI-type requests (default: '2024-02-15-preview')
// - timeout: Request timeout in seconds (default: 120)
// - inferenceApiVersion: API version for inference-type requests, e.g., '2024-05-01-preview' (optional, for non-OpenAI models)
//
// Example configurations for different scenarios are shown below.
// ============================================================================
param llmBackendConfig = [
  // ----------------------------------
  // AI Foundry Backend - Primary
  // ----------------------------------
  // This backend connects to an Azure AI Foundry project endpoint
  // Models deployed in AI Foundry use the OpenAI-compatible inference API
  {
    backendId: 'aif-citadel-primary'
    backendType: 'ai-foundry'
    endpoint: 'https://aif-RESOURCE_TOKEN-0.cognitiveservices.azure.com/' // Replace with your AI Foundry endpoint
    authScheme: 'managedIdentity'
    // Each model has its own metadata for get-available-models response
    supportedModels: [
      { name: 'gpt-4o-mini', sku: 'GlobalStandard', capacity: 100, modelFormat: 'OpenAI', modelVersion: '2024-07-18', retirementDate: '2026-09-30' }
      { name: 'gpt-4o', sku: 'GlobalStandard', capacity: 100, modelFormat: 'OpenAI', modelVersion: '2024-11-20', retirementDate: '2026-09-30' }
      { name: 'gpt-4.1', sku: 'GlobalStandard', capacity: 100, modelFormat: 'OpenAI', modelVersion: '2025-04-14', retirementDate: '2026-10-14', apiVersion: '2025-04-01-preview', timeout: 180 }
      { name: 'DeepSeek-R1', sku: 'GlobalStandard', capacity: 1, modelFormat: 'DeepSeek', modelVersion: '1', retirementDate: '2099-12-30', inferenceApiVersion: '2024-05-01-preview' }
      { name: 'Phi-4', sku: 'GlobalStandard', capacity: 1, modelFormat: 'Microsoft', modelVersion: '3', retirementDate: '2099-12-30', inferenceApiVersion: '2024-05-01-preview' }
      { name: 'text-embedding-3-large', sku: 'GlobalStandard', capacity: 100, modelFormat: 'OpenAI', modelVersion: '1', retirementDate: '2027-04-14' }
    ]
    priority: 1
    weight: 100
  }
  
  // ----------------------------------
  // AI Foundry Backend - Secondary (Different Region)
  // ----------------------------------
  // For load balancing and failover, add backends in different regions
  // Models shared with primary backend will be load balanced
  {
    backendId: 'aif-citadel-secondary'
    backendType: 'ai-foundry'
    endpoint: 'https://aif-RESOURCE_TOKEN-1.cognitiveservices.azure.com/' // Replace with your secondary AI Foundry endpoint
    authScheme: 'managedIdentity'
    supportedModels: [
      { name: 'gpt-5', sku: 'GlobalStandard', capacity: 100, modelFormat: 'OpenAI', modelVersion: '2025-08-07', retirementDate: '2027-02-05' }
      { name: 'DeepSeek-R1', sku: 'GlobalStandard', capacity: 1, modelFormat: 'DeepSeek', modelVersion: '1', retirementDate: '2099-12-30', inferenceApiVersion: '2024-05-01-preview' }
      { name: 'text-embedding-3-large', sku: 'GlobalStandard', capacity: 100, modelFormat: 'OpenAI', modelVersion: '1', retirementDate: '2027-04-14' }
    ]
    priority: 2
    weight: 50
  }

  // ----------------------------------
  // Azure OpenAI Backend (Optional)
  // ----------------------------------
  // Uncomment to add Azure OpenAI Service endpoints
  // {
  //   backendId: 'aoai-eastus-gpt4'
  //   backendType: 'azure-openai'
  //   endpoint: 'https://YOUR-AOAI-RESOURCE.openai.azure.com/'
  //   authScheme: 'managedIdentity'
  //   supportedModels: [
  //     { name: 'gpt-4', sku: 'Standard', capacity: 120, modelFormat: 'OpenAI', modelVersion: '0613' }
  //     { name: 'gpt-35-turbo', sku: 'Standard', capacity: 120, modelFormat: 'OpenAI', modelVersion: '0613' }
  //     { name: 'text-embedding-ada-002', sku: 'Standard', capacity: 120, modelFormat: 'OpenAI', modelVersion: '2' }
  //   ]
  //   priority: 1
  //   weight: 100
  // }
]

// ============================================================================
// OPTIONAL: Circuit Breaker Configuration
// ============================================================================
// Enable circuit breaker for backend resilience. When enabled, APIM will
// temporarily stop routing to backends that are experiencing failures.
//
// Recommended: true for production environments
// ============================================================================
param configureCircuitBreaker = true
