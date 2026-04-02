/*
 * @module llm-policy-fragments
 * @description Generates APIM policy fragments with backend pool configurations
 * 
 * This module creates policy fragments that contain the dynamically generated
 * backend pool configurations based on the LLM backend setup. These fragments
 * are used by the Universal LLM API policy to route requests appropriately.
 */

// ------------------
//    PARAMETERS
// ------------------

@description('Name of the API Management service')
param apimServiceName string

@description('Policy fragment configuration from backend pools module')
param policyFragmentConfig object

@description('User-assigned managed identity client ID for authentication')
param managedIdentityClientId string

@description('LLM backend configuration with model metadata for available models response')
param llmBackendConfig array = []

// ------------------
//    VARIABLES
// ------------------

// Combine backend pools and direct backends for unified routing
var allPools = union(policyFragmentConfig.backendPools, policyFragmentConfig.directBackends)

// Generate C# code for each backend pool with unique variable names
var backendPoolsArray = [for (pool, index) in allPools: replace(replace(replace(replace('// Pool: POOLNAME (Type: POOLTYPE)\nvar pool_INDEX = new JObject()\n{\n    { "poolName", "POOLNAME" },\n    { "poolType", "POOLTYPE" },\n    { "supportedModels", new JArray(MODELS) }\n};\nbackendPools.Add(pool_INDEX);', 'POOLNAME', pool.poolName), 'POOLTYPE', pool.poolType), 'INDEX', string(index)), 'MODELS', join(map(pool.supportedModels, (model) => '"${model}"'), ', '))]

var backendPoolsCode = join(backendPoolsArray, '\n')

// Load policy fragment templates
var setBackendPoolsFragmentTemplate = loadTextContent('./policies/frag-set-backend-pools.xml')
var setBackendAuthorizationFragmentXml = loadTextContent('./policies/frag-set-backend-authorization.xml')
var setTargetBackendPoolFragmentXml = loadTextContent('./policies/frag-set-target-backend-pool.xml')
var setLlmRequestedModelFragmentXml = loadTextContent('./policies/frag-set-llm-requested-model.xml')
var setLlmUsageFragmentXml = loadTextContent('./policies/frag-set-llm-usage.xml')
var getAvailableModelsFragmentTemplate = loadTextContent('./policies/frag-get-available-models.xml')

// Inject generated backend pools code into template
var updatedSetBackendPoolsFragmentXml = replace(setBackendPoolsFragmentTemplate, '//{backendPoolsCode}', backendPoolsCode)

// Generate model deployments code using reduce to flatten models from all backends
// Each backend generates code for all its supported models (now with per-model metadata)
// supportedModels is now an array of objects: { name, sku?, capacity?, modelFormat?, modelVersion?, retirementDate? }
var modelDeploymentsCodeResult = reduce(llmBackendConfig, { code: '', index: 0 }, (acc, config) => 
  reduce(config.supportedModels, acc, (modelAcc, model) => {
    code: '${modelAcc.code}\n// Model: ${model.name} from backend: ${config.backendId}\nvar deployment_${modelAcc.index} = new JObject()\n{\n    { "id", "${config.backendId}" },\n    { "type", "${config.backendType}" },\n    { "name", "${model.name}" },\n    { "sku", new JObject() { { "name", "${model.?sku ?? 'Standard'}" }, { "capacity", ${model.?capacity ?? 100} } } },\n    { "properties", new JObject() {\n        { "model", new JObject() { { "format", "${model.?modelFormat ?? 'OpenAI'}" }, { "name", "${model.name}" }, { "version", "${model.?modelVersion ?? '1'}" } } },\n        { "capabilities", new JObject() { { "chatCompletion", "true" } } },\n        { "provisioningState", "Succeeded" }${!empty(model.?retirementDate) ? ',\n        { "retirementDate", "${model.retirementDate}" }' : ''}\n    }}\n};\nmodelDeployments.Add(deployment_${modelAcc.index});'
    index: modelAcc.index + 1
  })
)

var modelDeploymentsCode = modelDeploymentsCodeResult.code

// Inject generated model deployments code into available models template
var updatedGetAvailableModelsFragmentXml = replace(getAvailableModelsFragmentTemplate, '//{modelDeploymentsCode}', modelDeploymentsCode)

// Generate metadata-config fragment for the Unified AI API
// Maps each model to its backend pool/direct backend + apiVersion + timeout + inferenceApiVersion
var metadataModelsResult = reduce(llmBackendConfig, { code: '', seenModels: [] }, (acc, config) =>
  reduce(config.supportedModels, acc, (modelAcc, model) => {
    code: contains(modelAcc.seenModels, model.name) ? modelAcc.code : '${modelAcc.code}${length(modelAcc.seenModels) > 0 ? ',\n' : ''}\t\t\t\'${model.name}\': {\n\t\t\t\t\'backend\': \'${reduce(allPools, '', (poolAcc, pool) => contains(pool.supportedModels, model.name) ? pool.poolName : poolAcc)}\',\n\t\t\t\t\'apiVersion\': \'${model.?apiVersion ?? '2024-02-15-preview'}\',\n\t\t\t\t\'timeout\': ${model.?timeout ?? 120}${!empty(model.?inferenceApiVersion) ? ',\n\t\t\t\t\'inferenceApiVersion\': \'${model.inferenceApiVersion}\'' : ''}\n\t\t\t}'
    seenModels: contains(modelAcc.seenModels, model.name) ? modelAcc.seenModels : union(modelAcc.seenModels, [model.name])
  })
)
var metadataModelsCode = metadataModelsResult.code
var metadataConfigFragmentXml = loadTextContent('./policies/frag-metadata-config.xml')
var updatedMetadataConfigFragmentXml = replace(metadataConfigFragmentXml, '//{modelsConfigCode}', metadataModelsCode)

// ------------------
//    RESOURCES
// ------------------

resource apimService 'Microsoft.ApiManagement/service@2024-06-01-preview' existing = {
  name: apimServiceName
}

// Named value for managed identity client ID
resource uamiClientIdNamedValue 'Microsoft.ApiManagement/service/namedValues@2024-06-01-preview' = {
  name: 'uami-client-id'
  parent: apimService
  properties: {
    displayName: 'uami-client-id'
    value: managedIdentityClientId
    secret: false
  }
}

// Policy Fragment: Set Backend Pools
resource setBackendPoolsFragment 'Microsoft.ApiManagement/service/policyFragments@2024-06-01-preview' = {
  name: 'set-backend-pools'
  parent: apimService
  properties: {
    description: 'Dynamically generated backend pool configurations for LLM routing'
    format: 'rawxml'
    value: updatedSetBackendPoolsFragmentXml
  }
}

// Policy Fragment: Set Backend Authorization
resource setBackendAuthorizationFragment 'Microsoft.ApiManagement/service/policyFragments@2024-06-01-preview' = {
  name: 'set-backend-authorization'
  parent: apimService
  properties: {
    description: 'Authentication and routing configuration for different LLM backend types'
    format: 'rawxml'
    value: setBackendAuthorizationFragmentXml
  }
}

// Policy Fragment: Set Target Backend Pool
resource setTargetBackendPoolFragment 'Microsoft.ApiManagement/service/policyFragments@2024-06-01-preview' = {
  name: 'set-target-backend-pool'
  parent: apimService
  properties: {
    description: 'Determines the target backend pool for LLM requests'
    format: 'rawxml'
    value: setTargetBackendPoolFragmentXml
  }
}

// Policy Fragment: Set LLM Requested Model
resource setLlmRequestedModelFragment 'Microsoft.ApiManagement/service/policyFragments@2024-06-01-preview' = {
  name: 'set-llm-requested-model'
  parent: apimService
  properties: {
    description: 'Extracts the requested model from deployment-id (Azure OpenAI) or request body (Inference)'
    format: 'rawxml'
    value: setLlmRequestedModelFragmentXml
  }
}

// Policy Fragment: Set LLM Usage
resource setLlmUsageFragment 'Microsoft.ApiManagement/service/policyFragments@2024-06-01-preview' = {
  name: 'set-llm-usage'
  parent: apimService
  properties: {
    description: 'Collects usage metrics for LLM requests'
    format: 'rawxml'
    value: setLlmUsageFragmentXml
  }
}

// Policy Fragment: Get Available Models
resource getAvailableModelsFragment 'Microsoft.ApiManagement/service/policyFragments@2024-06-01-preview' = {
  name: 'get-available-models'
  parent: apimService
  properties: {
    description: 'Returns a JSON response listing all available model deployments with their capabilities'
    format: 'rawxml'
    value: updatedGetAvailableModelsFragmentXml
  }
}

// Policy Fragment: Metadata Configuration
// Provides centralized configuration for the Unified AI API with dynamically generated model mappings
resource metadataConfigFragment 'Microsoft.ApiManagement/service/policyFragments@2024-06-01-preview' = {
  name: 'metadata-config'
  parent: apimService
  properties: {
    description: 'Dynamically generated metadata configuration for Unified AI API routing'
    format: 'rawxml'
    value: updatedMetadataConfigFragmentXml
  }
}

// ------------------
//    OUTPUTS
// ------------------

@description('Name of the set-backend-pools fragment')
output setBackendPoolsFragmentName string = setBackendPoolsFragment.name

@description('Name of the set-backend-authorization fragment')
output setBackendAuthorizationFragmentName string = setBackendAuthorizationFragment.name

@description('Name of the set-target-backend-pool fragment')
output setTargetBackendPoolFragmentName string = setTargetBackendPoolFragment.name

@description('Name of the get-available-models fragment')
output getAvailableModelsFragmentName string = getAvailableModelsFragment.name

@description('Name of the metadata-config fragment')
output metadataConfigFragmentName string = metadataConfigFragment.name

@description('Generated backend pools configuration code')
output backendPoolsCode string = backendPoolsCode
