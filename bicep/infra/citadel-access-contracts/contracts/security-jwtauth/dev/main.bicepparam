using '../../../main.bicep'

// ============================================================================
// Security JWT Auth - Enforced JWT + API Key across all endpoints - Generated from JWT Authentication Testing Notebook
// ============================================================================

param apim = {
  subscriptionId: 'REPLACE'
  resourceGroupName: 'REPLACE'
  name: 'REPLACE'
}

param keyVault = {
  subscriptionId: 'REPLACE'
  resourceGroupName: 'REPLACE'
  name: 'REPLACE'
}

param useTargetAzureKeyVault = false

param useCase = {
  businessUnit: 'Security'
  useCaseName: 'JwtAuth'
  environment: 'DEV'
}

param apiNameMapping = {
  LLM: ['universal-llm-api', 'azure-openai-api', 'unified-ai-api']
}

param services = [
  {
    code: 'LLM'
    endpointSecretName: 'SEC-JWT-LLM-ENDPOINT'
    apiKeySecretName: 'SEC-JWT-LLM-KEY'
    policyXml: loadTextContent('ai-product-policy.xml')
  }
]

param productTerms = 'JWT Authentication Access Contract - Security JWT Auth - Enforced JWT + API Key across all endpoints'

// Azure AI Foundry Integration (disabled)
param useTargetFoundry = false

param foundry = {
  subscriptionId: '00000000-0000-0000-0000-000000000000'
  resourceGroupName: 'placeholder'
  accountName: 'placeholder'
  projectName: 'placeholder'
}
