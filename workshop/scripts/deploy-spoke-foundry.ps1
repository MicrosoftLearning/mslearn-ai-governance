[CmdletBinding()]
param(
    [string]$SpokeResourceGroupName = $env:SPOKE_RESOURCE_GROUP_NAME,
    [string]$FoundryAccountName = $env:FOUNDRY_ACCOUNT_NAME,
    [string]$FoundryProjectName = $env:FOUNDRY_PROJECT_NAME,
    [string]$KeyVaultName = $env:KEY_VAULT_NAME,
    [string]$KeyVaultEnablePurgeProtection = $(if ($env:KEY_VAULT_ENABLE_PURGE_PROTECTION) { $env:KEY_VAULT_ENABLE_PURGE_PROTECTION } else { 'false' })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -ge 7) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$aiProjectManagerRoleId = 'eadc314b-1a2d-4efa-be10-5d325db5065e'
$keyVaultSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message"
}

function Assert-Command {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command not found: $Name"
    }
}

function Get-AzdValue {
    param(
        [string]$Name,
        [switch]$Required
    )

    $value = (& azd env get-value $Name 2>$null)
    if ($LASTEXITCODE -ne 0) {
        $value = $null
    }

    if ($Required -and [string]::IsNullOrWhiteSpace($value)) {
        throw "Required azd environment value is missing: $Name. Run azd up/provision first, then rerun this script."
    }

    return ($value | Select-Object -First 1)
}

function ConvertTo-SafeNamePart {
    param([string]$Value)
    $name = $Value.ToLowerInvariant() -replace '[^a-z0-9-]', '-' -replace '-+', '-'
    $name = $name.Trim('-')
    if ([string]::IsNullOrWhiteSpace($name)) { return 'citadel' }
    return $name
}

function ConvertTo-CompactNamePart {
    param([string]$Value)
    $name = $Value.ToLowerInvariant() -replace '[^a-z0-9]', ''
    if ([string]::IsNullOrWhiteSpace($name)) { return 'citadel' }
    return $name
}

function ConvertTo-TrimmedCliOutput {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return $null
    }

    $text = [string]($Value | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    return $text.Trim()
}

function Add-RoleAssignmentIfMissing {
    param(
        [string]$PrincipalId,
        [string]$PrincipalType,
        [string]$RoleId,
        [string]$RoleName,
        [string]$Scope
    )

    $assignmentId = (& az role assignment list `
        --assignee-object-id $PrincipalId `
        --role $RoleId `
        --scope $Scope `
        --all `
        --fill-principal-name false `
        --fill-role-definition-name false `
        --query '[0].id' `
        -o tsv 2>$null)

    if (-not [string]::IsNullOrWhiteSpace($assignmentId)) {
        Write-Host "Role assignment already exists: $RoleName"
        return
    }

    & az role assignment create `
        --assignee-object-id $PrincipalId `
        --assignee-principal-type $PrincipalType `
        --role $RoleId `
        --scope $Scope `
        --only-show-errors `
        -o none
    Write-Host "Assigned role: $RoleName"
}

Assert-Command az
Assert-Command azd

& az account show *> $null
if ($LASTEXITCODE -ne 0) {
    throw 'Azure CLI is not logged in. Run az login, then rerun this script.'
}

& az cognitiveservices account project -h *> $null
if ($LASTEXITCODE -ne 0) {
    throw 'This Azure CLI does not include az cognitiveservices account project. Update Azure CLI and rerun this script.'
}

$governanceResourceGroup = Get-AzdValue -Name 'AZURE_RESOURCE_GROUP' -Required
$location = Get-AzdValue -Name 'AZURE_LOCATION' -Required
$azdEnvName = Get-AzdValue -Name 'AZURE_ENV_NAME'
$subscriptionId = Get-AzdValue -Name 'AZURE_SUBSCRIPTION_ID'

if (-not [string]::IsNullOrWhiteSpace($subscriptionId)) {
    & az account set --subscription $subscriptionId
} else {
    $subscriptionId = ConvertTo-TrimmedCliOutput (& az account show --query id -o tsv)
}

if ([string]::IsNullOrWhiteSpace($SpokeResourceGroupName)) {
    $SpokeResourceGroupName = "$governanceResourceGroup-spoke"
}
if ([string]::IsNullOrWhiteSpace($FoundryProjectName)) {
    $FoundryProjectName = 'citadel-agents-project'
}

$seedSource = if ([string]::IsNullOrWhiteSpace($azdEnvName)) { $governanceResourceGroup } else { $azdEnvName }
$tagEnvName = if ([string]::IsNullOrWhiteSpace($azdEnvName)) { 'unknown' } else { $azdEnvName }
$nameSeed = ConvertTo-SafeNamePart $seedSource
$compactSeed = ConvertTo-CompactNamePart $seedSource
$subscriptionSuffix = ($subscriptionId -replace '-', '').Substring(0, 8)

if ([string]::IsNullOrWhiteSpace($FoundryAccountName)) {
    $FoundryAccountName = "aif-$nameSeed-$subscriptionSuffix"
    if ($FoundryAccountName.Length -gt 64) { $FoundryAccountName = $FoundryAccountName.Substring(0, 64).TrimEnd('-') }
}

if ([string]::IsNullOrWhiteSpace($KeyVaultName)) {
    $KeyVaultName = "kv$compactSeed$subscriptionSuffix"
    if ($KeyVaultName.Length -gt 24) { $KeyVaultName = $KeyVaultName.Substring(0, 24) }
}

$currentUserObjectId = (& az ad signed-in-user show --query id -o tsv 2>$null)
if ([string]::IsNullOrWhiteSpace($currentUserObjectId)) {
    throw 'Could not resolve the signed-in user object ID. This script expects an interactive user login.'
}
$currentUserObjectId = ConvertTo-TrimmedCliOutput $currentUserObjectId

Write-Step 'Creating spoke resource group'
& az group create `
    --name $SpokeResourceGroupName `
    --location $location `
    --tags "azd-env-name=$tagEnvName" 'workload=citadel-spoke' `
    -o none

Write-Step 'Creating Azure AI Foundry account'
& az cognitiveservices account show --name $FoundryAccountName --resource-group $SpokeResourceGroupName *> $null
if ($LASTEXITCODE -ne 0) {
    & az cognitiveservices account create `
        --name $FoundryAccountName `
        --resource-group $SpokeResourceGroupName `
        --location $location `
        --kind AIServices `
        --sku S0 `
        --assign-identity `
        --custom-domain $FoundryAccountName `
        --allow-project-management true `
        --yes `
        --tags "azd-env-name=$tagEnvName" 'workload=citadel-spoke' `
        -o none
} else {
    Write-Host "Foundry account already exists: $FoundryAccountName"
}

$foundryAccountId = ConvertTo-TrimmedCliOutput (& az cognitiveservices account show `
    --name $FoundryAccountName `
    --resource-group $SpokeResourceGroupName `
    --query id `
    -o tsv)

$foundryAccountPatchBody = @{
    properties = @{
        allowProjectManagement = $true
        disableLocalAuth = $true
        publicNetworkAccess = 'Enabled'
        networkAcls = @{
            defaultAction = 'Allow'
            ipRules = @()
            virtualNetworkRules = @()
        }
    }
} | ConvertTo-Json -Depth 5 -Compress

$foundryAccountPatchPath = Join-Path ([System.IO.Path]::GetTempPath()) ("foundry-account-patch-{0}.json" -f [System.Guid]::NewGuid().ToString('N'))
Set-Content -Path $foundryAccountPatchPath -Value $foundryAccountPatchBody -Encoding utf8NoBOM

try {
    & az resource patch `
        --ids $foundryAccountId `
        --api-version 2025-06-01 `
        --properties "@$foundryAccountPatchPath" `
        --only-show-errors `
        -o none
}
finally {
    Remove-Item -Path $foundryAccountPatchPath -Force -ErrorAction SilentlyContinue
}

Write-Step 'Creating Azure AI Foundry project'
& az cognitiveservices account project show `
    --name $FoundryAccountName `
    --resource-group $SpokeResourceGroupName `
    --project-name $FoundryProjectName *> $null
if ($LASTEXITCODE -ne 0) {
    & az cognitiveservices account project create `
        --name $FoundryAccountName `
        --resource-group $SpokeResourceGroupName `
        --project-name $FoundryProjectName `
        --location $location `
        --assign-identity `
        --display-name $FoundryProjectName `
        --description 'Citadel workshop project for Foundry Agents.' `
        -o none
} else {
    Write-Host "Foundry project already exists: $FoundryProjectName"
}

Write-Step 'Creating Key Vault'
& az keyvault show --name $KeyVaultName --resource-group $SpokeResourceGroupName *> $null
if ($LASTEXITCODE -ne 0) {
    $keyVaultCreateArgs = @(
        'keyvault', 'create',
        '--name', $KeyVaultName,
        '--resource-group', $SpokeResourceGroupName,
        '--location', $location,
        '--sku', 'standard',
        '--enable-rbac-authorization', 'true',
        '--public-network-access', 'Enabled',
        '--default-action', 'Allow',
        '--bypass', 'AzureServices',
        '--tags', "azd-env-name=$tagEnvName", 'workload=citadel-spoke',
        '-o', 'none'
    )
    if ([string]::Equals($KeyVaultEnablePurgeProtection, 'true', [System.StringComparison]::OrdinalIgnoreCase)) {
        $keyVaultCreateArgs += @('--enable-purge-protection', 'true')
    }
    & az @keyVaultCreateArgs
} else {
    Write-Host "Key Vault already exists: $KeyVaultName"
}

$existingKeyVaultPurgeProtection = ConvertTo-TrimmedCliOutput (& az keyvault show `
    --name $KeyVaultName `
    --resource-group $SpokeResourceGroupName `
    --query 'properties.enablePurgeProtection' `
    -o tsv)

if ($existingKeyVaultPurgeProtection -eq 'true') {
    Write-Warning 'Key Vault purge protection is enabled and cannot be disabled. Immediate purge will not be available for this vault.'
}

$keyVaultId = ConvertTo-TrimmedCliOutput (& az keyvault show `
    --name $KeyVaultName `
    --resource-group $SpokeResourceGroupName `
    --query id `
    -o tsv)

Write-Step 'Assigning RBAC roles to the signed-in user'
Add-RoleAssignmentIfMissing -PrincipalId $currentUserObjectId -PrincipalType User -RoleId $aiProjectManagerRoleId -RoleName 'Azure AI Project Manager' -Scope $foundryAccountId
Add-RoleAssignmentIfMissing -PrincipalId $currentUserObjectId -PrincipalType User -RoleId $keyVaultSecretsUserRoleId -RoleName 'Key Vault Secrets User' -Scope $keyVaultId

Write-Step 'Saving spoke resource values to azd environment'
& azd env set SPOKE_RESOURCE_GROUP $SpokeResourceGroupName *> $null
& azd env set SPOKE_AI_FOUNDRY_ACCOUNT_NAME $FoundryAccountName *> $null
& azd env set SPOKE_AI_FOUNDRY_PROJECT_NAME $FoundryProjectName *> $null
& azd env set SPOKE_KEY_VAULT_NAME $KeyVaultName *> $null

Write-Host "`nSpoke resources are ready."
Write-Host "Resource group: $SpokeResourceGroupName"
Write-Host "Foundry account: $FoundryAccountName"
Write-Host "Foundry project: $FoundryProjectName"
Write-Host "Key Vault: $KeyVaultName"
Write-Host "`nAfter deleting these resources, purge soft-deleted names with:"
Write-Host "az cognitiveservices account purge --name `"$FoundryAccountName`" --resource-group `"$SpokeResourceGroupName`" --location `"$location`""
Write-Host "az keyvault purge --name `"$KeyVaultName`" --location `"$location`""
