/**
 * @module policy-fragments
 * @description This module creates all policy fragments for the API Management service.
 * It includes configurations for authentication, routing, usage tracking, and PII handling.
 */

// ------------------
//    PARAMETERS
// ------------------

@description('The name of the API Management service')
param apimServiceName string

@description('Enable PII Anonymization features')
param enablePIIAnonymization bool = true

@description('Enable AI Model Inference features')
param enableAIModelInference bool = true

@description('Enable Unified AI API features')
param enableUnifiedAiApi bool = true

// ------------------
//    RESOURCES
// ------------------

resource apimService 'Microsoft.ApiManagement/service@2022-08-01' existing = {
  name: apimServiceName
}

resource aadAuthPolicyFragment 'Microsoft.ApiManagement/service/policyFragments@2022-08-01' = {
  parent: apimService
  name: 'aad-auth'
  properties: {
    value: loadTextContent('./policies/frag-aad-auth.xml')
    format: 'rawxml'
  }
}

resource openAIUsagePolicyFragment 'Microsoft.ApiManagement/service/policyFragments@2022-08-01' = {
  parent: apimService
  name: 'openai-usage'
  properties: {
    value: loadTextContent('./policies/frag-openai-usage.xml')
    format: 'rawxml'
  }
}

resource openAIUsageStreamingPolicyFragment 'Microsoft.ApiManagement/service/policyFragments@2022-08-01' = {
  parent: apimService
  name: 'openai-usage-streaming'
  properties: {
    value: loadTextContent('./policies/frag-openai-usage-streaming.xml')
    format: 'rawxml'
  }
}

resource aiUsagePolicyFragment 'Microsoft.ApiManagement/service/policyFragments@2022-08-01' = {
  parent: apimService
  name: 'ai-usage'
  properties: {
    value: loadTextContent('./policies/frag-ai-usage.xml')
    format: 'rawxml'
  }
}

resource throttlingEventsPolicyFragment 'Microsoft.ApiManagement/service/policyFragments@2022-08-01' = {
  parent: apimService
  name: 'throttling-events'
  properties: {
    value: loadTextContent('./policies/frag-throttling-events.xml')
    format: 'rawxml'
  }
}

resource raiseThrottlingEventsPolicyFragment 'Microsoft.ApiManagement/service/policyFragments@2022-08-01' = {
  parent: apimService
  name: 'raise-throttling-events'
  properties: {
    value: loadTextContent('./policies/frag-raise-throttling-events.xml')
    format: 'rawxml'
  }
}

resource piiAnonymizationPolicyFragment 'Microsoft.ApiManagement/service/policyFragments@2022-08-01' = {
  parent: apimService
  name: 'pii-anonymization'
  properties: {
    value: loadTextContent('./policies/frag-pii-anonymization.xml')
    format: 'rawxml'
  }
}

resource piiDenonymizationPolicyFragment 'Microsoft.ApiManagement/service/policyFragments@2022-08-01' = {
  parent: apimService
  name: 'pii-deanonymization'
  properties: {
    value: loadTextContent('./policies/frag-pii-deanonymization.xml')
    format: 'rawxml'
  }
}

resource piiStateSavingPolicyFragment 'Microsoft.ApiManagement/service/policyFragments@2022-08-01' = if (enablePIIAnonymization) {
  parent: apimService
  name: 'pii-state-saving'
  properties: {
    value: loadTextContent('./policies/frag-pii-state-saving.xml')
    format: 'rawxml'
  }
}

resource aiFoundryCompatibilityPolicyFragment 'Microsoft.ApiManagement/service/policyFragments@2022-08-01' = if (enablePIIAnonymization) {
  parent: apimService
  name: 'ai-foundry-compatibility'
  properties: {
    value: loadTextContent('./policies/frag-ai-foundry-compatibility.xml')
    format: 'rawxml'
  }
}

resource aiFoundryDeploymentsPolicyFragment 'Microsoft.ApiManagement/service/policyFragments@2022-08-01' = if (enableAIModelInference) {
  parent: apimService
  name: 'ai-foundry-deployments'
  properties: {
    value: loadTextContent('./policies/frag-ai-foundry-deployments.xml')
    format: 'rawxml'
  }
}

// ------------------
//    UNIFIED AI API FRAGMENTS
// ------------------

resource centralCacheManagerFragment 'Microsoft.ApiManagement/service/policyFragments@2024-06-01-preview' = if (enableUnifiedAiApi) {
  parent: apimService
  name: 'central-cache-manager'
  properties: {
    description: 'Caches metadata configuration for Unified AI API performance'
    value: loadTextContent('./policies/frag-central-cache-manager.xml')
    format: 'rawxml'
  }
}

resource requestProcessorFragment 'Microsoft.ApiManagement/service/policyFragments@2024-06-01-preview' = if (enableUnifiedAiApi) {
  parent: apimService
  name: 'request-processor'
  properties: {
    description: 'Analyzes incoming Unified AI requests to extract routing context'
    value: loadTextContent('./policies/frag-request-processor.xml')
    format: 'rawxml'
  }
}

resource pathBuilderFragment 'Microsoft.ApiManagement/service/policyFragments@2024-06-01-preview' = if (enableUnifiedAiApi) {
  parent: apimService
  name: 'path-builder'
  properties: {
    description: 'Reconstructs backend URI paths for Unified AI API routing'
    value: loadTextContent('./policies/frag-path-builder.xml')
    format: 'rawxml'
  }
}

resource securityHandlerFragment 'Microsoft.ApiManagement/service/policyFragments@2024-06-01-preview' = {
  parent: apimService
  name: 'security-handler'
  properties: {
    description: 'Unified authentication handler for all AI Gateway APIs (API Key + optional JWT per-product)'
    value: loadTextContent('./policies/frag-security-handler.xml')
    format: 'rawxml'
  }
}

resource diagnosticHeadersFragment 'Microsoft.ApiManagement/service/policyFragments@2024-06-01-preview' = if (enableUnifiedAiApi) {
  parent: apimService
  name: 'diagnostic-headers'
  properties: {
    description: 'Adds UAIG-* response headers for Unified AI API debugging'
    value: loadTextContent('./policies/frag-diagnostic-headers.xml')
    format: 'rawxml'
  }
}

// ------------------
//    OUTPUTS
// ------------------

@description('The name of the AAD auth policy fragment')
output aadAuthPolicyFragmentName string = aadAuthPolicyFragment.name
@description('The name of the OpenAI usage policy fragment')
output openAIUsagePolicyFragmentName string = openAIUsagePolicyFragment.name
@description('The name of the OpenAI usage streaming policy fragment')
output openAIUsageStreamingPolicyFragmentName string = openAIUsageStreamingPolicyFragment.name
@description('The name of the AI usage policy fragment')
output aiUsagePolicyFragmentName string = aiUsagePolicyFragment.name
@description('The name of the throttling events policy fragment')
output throttlingEventsPolicyFragmentName string = throttlingEventsPolicyFragment.name
@description('The name of the PII anonymization policy fragment')
output piiAnonymizationPolicyFragmentName string = piiAnonymizationPolicyFragment.name

@description('The name of the PII deanonymization policy fragment')
output piiDenonymizationPolicyFragmentName string = piiDenonymizationPolicyFragment.name
@description('The name of the PII state saving policy fragment')
output piiStateSavingPolicyFragmentName string = enablePIIAnonymization ? piiStateSavingPolicyFragment.name : ''
@description('The name of the AI Foundry compatibility policy fragment')
output aiFoundryCompatibilityPolicyFragmentName string = enablePIIAnonymization ? aiFoundryCompatibilityPolicyFragment.name : ''
@description('The name of the AI Foundry deployments policy fragment')
output aiFoundryDeploymentsPolicyFragmentName string = enableAIModelInference ? aiFoundryDeploymentsPolicyFragment.name : ''

@description('The name of the central cache manager policy fragment')
output centralCacheManagerFragmentName string = enableUnifiedAiApi ? centralCacheManagerFragment.name : ''
@description('The name of the request processor policy fragment')
output requestProcessorFragmentName string = enableUnifiedAiApi ? requestProcessorFragment.name : ''
@description('The name of the path builder policy fragment')
output pathBuilderFragmentName string = enableUnifiedAiApi ? pathBuilderFragment.name : ''
@description('The name of the security handler policy fragment')
output securityHandlerFragmentName string = enableUnifiedAiApi ? securityHandlerFragment.name : ''
@description('The name of the diagnostic headers policy fragment')
output diagnosticHeadersFragmentName string = enableUnifiedAiApi ? diagnosticHeadersFragment.name : ''
