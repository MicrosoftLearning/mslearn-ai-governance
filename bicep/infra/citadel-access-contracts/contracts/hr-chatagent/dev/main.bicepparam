using '../../../main.bicep'

// ============================================================================
// HR Chat Agent - Key Vault + Foundry (if enabled) - Generated from Notebook
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

param useTargetAzureKeyVault = true

param useCase = {
  businessUnit: 'HR'
  useCaseName: 'ChatAgent'
  environment: 'DEV'
}

param apiNameMapping = {
  LLM: ['universal-llm-api', 'azure-openai-api', 'unified-ai-api']
}

param services = [
  {
    code: 'LLM'
    endpointSecretName: 'HR-LLM-ENDPOINT'
    apiKeySecretName: 'HR-LLM-KEY'
    policyXml: loadTextContent('ai-product-policy.xml')
  }
]

param productTerms = 'Access Contract created from testing notebook - HR Chat Agent - Key Vault + Foundry (if enabled)'

// Azure AI Foundry Integration
param useTargetFoundry = true

param foundry = {
  subscriptionId: 'd2e7f84f-2790-4baa-9520-59ae8169ed0d'
  resourceGroupName: 'rg-citadel-agent-spoke-03'
  accountName: 'aif-citadel-agent-spoke-03'
  projectName: 'proj-citadel-agent-spoke-03'
}

param foundryConfig = {
  connectionNamePrefix: ''
  deploymentInPath: 'false'
  isSharedToAll: false
  inferenceAPIVersion: ''
  deploymentAPIVersion: ''
  staticModels: []
  listModelsEndpoint: ''
  getModelEndpoint: ''
  deploymentProvider: ''
  customHeaders: {}
  authConfig: {}
}

