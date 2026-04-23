using '../../../main.bicep'

// ============================================================================
// Support Bot - Direct output (no Key Vault nor Foundry connection integration) - Generated from Notebook
// ============================================================================

param apim = {
  subscriptionId: 'd2e7f84f-2790-4baa-9520-59ae8169ed0d'
  resourceGroupName: 'rg-ai-hub-citadel-dev-57'
  name: 'apim-dmdxocmlhenr4'
}

param keyVault = {
  subscriptionId: 'd2e7f84f-2790-4baa-9520-59ae8169ed0d'
  resourceGroupName: 'rg-citadel-agent-spoke-03'
  name: 'kv-agent-spoke-03'
}

param useTargetAzureKeyVault = false

param useCase = {
  businessUnit: 'Support'
  useCaseName: 'Bot'
  environment: 'DEV'
}

param apiNameMapping = {
  LLM: ['universal-llm-api', 'azure-openai-api', 'unified-ai-api']
}

param services = [
  {
    code: 'LLM'
    endpointSecretName: 'SUPPORT-LLM-ENDPOINT'
    apiKeySecretName: 'SUPPORT-LLM-KEY'
    policyXml: loadTextContent('ai-product-policy.xml')
  }
]

param productTerms = 'Access Contract created from testing notebook - Support Bot - Direct output (no Key Vault nor Foundry connection integration)'

// Azure AI Foundry Integration (disabled)
param useTargetFoundry = false

param foundry = {
  subscriptionId: '00000000-0000-0000-0000-000000000000'
  resourceGroupName: 'placeholder'
  accountName: 'placeholder'
  projectName: 'placeholder'
}

