using '../../../main.bicep'

// ============================================================================
// Unified AI API Test Contract - Generated from Notebook
// ============================================================================

param apim = {
  subscriptionId: '00000000-0000-0000-0000-000000000000'
  resourceGroupName: 'REPLACE'
  name: 'apim-REPLACE'
}

param keyVault = {
  subscriptionId: '00000000-0000-0000-0000-000000000000'
  resourceGroupName: 'placeholder'
  name: 'placeholder'
}

param useTargetAzureKeyVault = false

param useCase = {
  businessUnit: 'Testing'
  useCaseName: 'UnifiedAI'
  environment: 'DEV'
}

param apiNameMapping = {
  LLM: ['unified-ai-api']
}

param services = [
  {
    code: 'LLM'
    endpointSecretName: 'UNIFIED-AI-TEST-ENDPOINT'
    apiKeySecretName: 'UNIFIED-AI-TEST-KEY'
    policyXml: loadTextContent('ai-product-policy.xml')
  }
]

param productTerms = 'Unified AI API test contract - generated from validation notebook'

// Azure AI Foundry Integration (disabled)
param useTargetFoundry = false

param foundry = {
  subscriptionId: '00000000-0000-0000-0000-000000000000'
  resourceGroupName: 'placeholder'
  accountName: 'placeholder'
  projectName: 'placeholder'
}
