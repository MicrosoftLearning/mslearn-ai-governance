[CmdletBinding()]
param(
    [string]$ResourceGroupName = $env:HR_MCP_RESOURCE_GROUP,
    [string]$AcrName = $env:HR_MCP_ACR_NAME,
    [string]$ContainerAppName = $env:HR_MCP_CONTAINER_APP_NAME,
    [string]$AcaEnvironmentName = $env:HR_MCP_ACA_ENVIRONMENT_NAME,
    [string]$PrivateContainerAppName = $env:HR_MCP_PRIVATE_CONTAINER_APP_NAME,
    [string]$PrivateAcaEnvironmentName = $env:HR_MCP_PRIVATE_ACA_ENVIRONMENT_NAME,
    [string]$LogAnalyticsWorkspaceName = $env:HR_MCP_LOG_ANALYTICS_NAME,
    [string]$AppInsightsName = $env:HR_MCP_APP_INSIGHTS_NAME,
    [string]$ApiClientId = $env:HR_MCP_API_CLIENT_ID,
    [string]$PublicClientId = $env:HR_MCP_PUBLIC_CLIENT_ID,
    [string]$CitadelResourceGroup = $env:HR_MCP_CITADEL_RESOURCE_GROUP,
    [string]$CitadelVnetName = $env:HR_MCP_CITADEL_VNET_NAME,
    [string]$AcaSubnetName = $(if ($env:HR_MCP_ACA_SUBNET_NAME) { $env:HR_MCP_ACA_SUBNET_NAME } else { 'snet-mcp' }),
    [string]$AcaSubnetPrefix = $env:HR_MCP_ACA_SUBNET_PREFIX,
    [int]$AcaSubnetPrefixLength = $(if ($env:HR_MCP_ACA_SUBNET_PREFIX_LENGTH) { [int]$env:HR_MCP_ACA_SUBNET_PREFIX_LENGTH } else { 26 }),
    [string]$AcaSubnetId = $env:HR_MCP_ACA_SUBNET_ID,
    [string]$ScopeName = $(if ($env:HR_MCP_SCOPE_NAME) { $env:HR_MCP_SCOPE_NAME } else { 'Mcp.Access' }),
    [string]$AppRoleValue = $(if ($env:HR_MCP_APP_ROLE_VALUE) { $env:HR_MCP_APP_ROLE_VALUE } else { 'Mcp.Invoke' })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$env:PYTHONWARNINGS = if ($env:PYTHONWARNINGS) { "$($env:PYTHONWARNINGS),ignore" } else { 'ignore' }
$env:AZURE_CORE_ONLY_SHOW_ERRORS = if ($env:AZURE_CORE_ONLY_SHOW_ERRORS) { $env:AZURE_CORE_ONLY_SHOW_ERRORS } else { 'True' }
if ($PSVersionTable.PSVersion.Major -ge 7) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'
$azureCliClientId = '04b07795-8ddb-461a-bbee-02f9e1bf7b46'
$securityControlTag = 'SecurityControl=Ignore'

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
    param([string]$Name)
    $value = (& azd env get-value $Name 2>$null)
    if ($LASTEXITCODE -ne 0) { return $null }
    return ConvertTo-TrimmedCliOutput $value
}

function ConvertTo-TrimmedCliOutput {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $null }
    $text = [string]($Value | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text.Trim()
}

function Get-FirstNonEmpty {
    param([AllowNull()][string[]]$Values)
    foreach ($value in $Values) {
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
    }
    return $null
}

function ConvertTo-SafeNamePart {
    param([string]$Value)
    $name = $Value.ToLowerInvariant() -replace '[^a-z0-9-]', '-' -replace '-+', '-'
    $name = $name.Trim('-')
    if ([string]::IsNullOrWhiteSpace($name)) { return 'hr-mcp' }
    return $name
}

function ConvertTo-CompactNamePart {
    param([string]$Value)
    $name = $Value.ToLowerInvariant() -replace '[^a-z0-9]', ''
    if ([string]::IsNullOrWhiteSpace($name)) { return 'hrmcp' }
    return $name
}

function Invoke-NativeCommandQuietly {
    param([scriptblock]$Command)
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $Command *> $null
        return $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Add-RoleAssignmentIfMissing {
    param(
        [string]$PrincipalId,
        [string]$PrincipalType,
        [string]$RoleId,
        [string]$RoleName,
        [string]$Scope
    )

    $assignmentId = $null
    try {
        $assignmentId = (& az role assignment list `
            --scope $Scope `
            --fill-principal-name false `
            --fill-role-definition-name false `
            --query "[?principalId=='$PrincipalId' && contains(roleDefinitionId, '$RoleId')].id | [0]" `
            -o tsv 2>$null)
    } catch { $assignmentId = $null }

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

function Wait-RoleAssignment {
    param(
        [string]$PrincipalId,
        [string]$RoleId,
        [string]$Scope,
        [string]$RoleName,
        [int]$MaxRetries = 5,
        [int]$SleepSeconds = 30
    )

    for ($i = 1; $i -le $MaxRetries; $i++) {
        $role = (& az role assignment list `
            --scope $Scope `
            --fill-principal-name false `
            --fill-role-definition-name false `
            --query "[?principalId=='$PrincipalId' && contains(roleDefinitionId, '$RoleId')].id | [0]" `
            -o tsv 2>$null)
        if (-not [string]::IsNullOrWhiteSpace($role)) {
            Write-Host "$RoleName role assignment is visible."
            return
        }
        Write-Host "$RoleName role assignment not visible yet (attempt $i/$MaxRetries); waiting ${SleepSeconds}s..."
        Start-Sleep -Seconds $SleepSeconds
    }

    Write-Warning "$RoleName role assignment did not become visible after waiting. Continuing because role assignment creation succeeded; if image pull fails, wait a few minutes and rerun the script."
}

function Find-AppObjectIdByDisplayName {
    param([string]$DisplayName)
    $objectId = (& az ad app list `
        --display-name $DisplayName `
        --query 'length(@) == `1` && [0].id || `MULTIPLE_OR_NONE`' `
        -o tsv 2>$null)
    return ConvertTo-TrimmedCliOutput $objectId
}

function Get-AppClientIdFromObjectId {
    param([string]$ObjectId)
    return ConvertTo-TrimmedCliOutput (& az ad app show --id $ObjectId --query appId -o tsv)
}

function Ensure-SingleAppByDisplayName {
    param([string]$DisplayName)
    $objectId = Find-AppObjectIdByDisplayName -DisplayName $DisplayName
    if ($objectId -eq 'MULTIPLE_OR_NONE') {
        $count = ConvertTo-TrimmedCliOutput (& az ad app list --display-name $DisplayName --query 'length(@)' -o tsv 2>$null)
        if ($count -eq '0') {
            $createdId = (& az ad app create `
                --display-name $DisplayName `
                --sign-in-audience AzureADMyOrg `
                --query id `
                -o tsv)
            if ($LASTEXITCODE -ne 0) { throw "Could not create app registration '$DisplayName'. You may need Application Developer permissions." }
            return ConvertTo-TrimmedCliOutput $createdId
        }
        throw "Multiple app registrations named '$DisplayName' exist. Set HR_MCP_API_CLIENT_ID or HR_MCP_PUBLIC_CLIENT_ID to disambiguate."
    }
    return $objectId
}

function Update-GraphApplication {
    param(
        [string]$ObjectId,
        [string]$Body
    )
    & az rest `
        --method PATCH `
        --uri "https://graph.microsoft.com/v1.0/applications/$ObjectId" `
        --headers 'Content-Type=application/json' `
        --body $Body `
        --only-show-errors `
        -o none
    if ($LASTEXITCODE -ne 0) {
        throw "Could not update Entra app registration $ObjectId. Ensure Microsoft Graph Application.ReadWrite.All or Application Developer permissions are available."
    }
}

function Ensure-ApiAppRegistration {
    param(
        [string]$DisplayName,
        [AllowNull()][string]$RequestedClientId,
        [string]$ScopeValue,
        [string]$RoleValue
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedClientId)) {
        $objectId = ConvertTo-TrimmedCliOutput (& az ad app show --id $RequestedClientId --query id -o tsv 2>$null)
        if ([string]::IsNullOrWhiteSpace($objectId)) { throw "HR_MCP_API_CLIENT_ID '$RequestedClientId' was not found." }
    } else {
        $objectId = Ensure-SingleAppByDisplayName -DisplayName $DisplayName
    }

    $clientId = Get-AppClientIdFromObjectId -ObjectId $objectId
    $appIdUri = "api://$clientId"
    $existingScopeId = ConvertTo-TrimmedCliOutput (& az ad app show --id $clientId --query "api.oauth2PermissionScopes[?value=='$ScopeValue'].id | [0]" -o tsv 2>$null)
    $scopeId = if ([string]::IsNullOrWhiteSpace($existingScopeId)) { [guid]::NewGuid().ToString() } else { $existingScopeId }

    $existingRoleId = ConvertTo-TrimmedCliOutput (& az ad app show --id $clientId --query "appRoles[?value=='$RoleValue'].id | [0]" -o tsv 2>$null)
    $roleId = if ([string]::IsNullOrWhiteSpace($existingRoleId)) { [guid]::NewGuid().ToString() } else { $existingRoleId }

    $body = @{
        identifierUris = @($appIdUri)
        api = @{
            requestedAccessTokenVersion = 2
            oauth2PermissionScopes = @(
                @{
                    id = $scopeId
                    adminConsentDescription = 'Access the HR MCP API.'
                    adminConsentDisplayName = 'Access HR MCP'
                    isEnabled = $true
                    type = 'User'
                    userConsentDescription = 'Access the HR MCP API on your behalf.'
                    userConsentDisplayName = 'Access HR MCP'
                    value = $ScopeValue
                }
            )
        }
        appRoles = @(
            @{
                id = $roleId
                allowedMemberTypes = @('Application')
                description = 'Applications can call the HR MCP API.'
                displayName = 'Invoke HR MCP (application)'
                isEnabled = $true
                value = $RoleValue
            }
        )
    } | ConvertTo-Json -Depth 8 -Compress
    Update-GraphApplication -ObjectId $objectId -Body $body

    return [pscustomobject]@{
        ObjectId = $objectId
        ClientId = $clientId
        ScopeId = $scopeId
        AppRoleId = $roleId
        Audience = $appIdUri
        Scope = "$appIdUri/$ScopeValue"
    }
}

function Ensure-PublicClientRegistration {
    param(
        [string]$DisplayName,
        [AllowNull()][string]$RequestedClientId,
        [string]$ApiClientId,
        [string]$ScopeId
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedClientId)) {
        $objectId = ConvertTo-TrimmedCliOutput (& az ad app show --id $RequestedClientId --query id -o tsv 2>$null)
        if ([string]::IsNullOrWhiteSpace($objectId)) { throw "HR_MCP_PUBLIC_CLIENT_ID '$RequestedClientId' was not found." }
    } else {
        $objectId = Ensure-SingleAppByDisplayName -DisplayName $DisplayName
    }

    $clientId = Get-AppClientIdFromObjectId -ObjectId $objectId
    $body = @{
        isFallbackPublicClient = $true
        publicClient = @{ redirectUris = @('http://localhost') }
        requiredResourceAccess = @(
            @{
                resourceAppId = $ApiClientId
                resourceAccess = @(@{ id = $ScopeId; type = 'Scope' })
            }
        )
    } | ConvertTo-Json -Depth 8 -Compress
    Update-GraphApplication -ObjectId $objectId -Body $body

    return [pscustomobject]@{
        ObjectId = $objectId
        ClientId = $clientId
    }
}

function Ensure-ApiServicePrincipal {
    param([string]$ApiClientId)

    $existing = ConvertTo-TrimmedCliOutput (& az ad sp show --id $ApiClientId --query id -o tsv 2>$null)
    if (-not [string]::IsNullOrWhiteSpace($existing)) {
        Write-Host 'Service principal already exists for HR MCP API app.'
        return
    }
    & az ad sp create --id $ApiClientId --only-show-errors -o none
    if ($LASTEXITCODE -ne 0) {
        throw "Could not create service principal for HR MCP API app '$ApiClientId'. Ensure you have permission to create Enterprise Applications/service principals."
    }
    Write-Host 'Created service principal for HR MCP API app.'
}

function Set-ApiPreauthorizedClients {
    param(
        [string]$ApiObjectId,
        [string]$ScopeId,
        [string[]]$ClientIds
    )

    $app = (& az ad app show --id $ApiObjectId -o json) | ConvertFrom-Json
    $api = if ($app.api) { $app.api } else { [pscustomobject]@{} }
    $scopes = @($api.oauth2PermissionScopes)
    $preauth = @($api.preAuthorizedApplications)
    $byApp = @{}
    foreach ($entry in $preauth) {
        if ($entry.appId) { $byApp[$entry.appId] = $entry }
    }
    foreach ($clientId in $ClientIds) {
        if ([string]::IsNullOrWhiteSpace($clientId)) { continue }
        if (-not $byApp.ContainsKey($clientId)) {
            $byApp[$clientId] = [pscustomobject]@{
                appId = $clientId
                delegatedPermissionIds = @()
            }
        }
        $ids = @($byApp[$clientId].delegatedPermissionIds)
        if ($ids -notcontains $ScopeId) {
            $byApp[$clientId].delegatedPermissionIds = @($ids + $ScopeId)
        }
    }
    $body = @{
        api = @{
            requestedAccessTokenVersion = $(if ($api.requestedAccessTokenVersion) { $api.requestedAccessTokenVersion } else { 2 })
            oauth2PermissionScopes = $scopes
            preAuthorizedApplications = @($byApp.Values)
        }
    } | ConvertTo-Json -Depth 12 -Compress
    Update-GraphApplication -ObjectId $ApiObjectId -Body $body
    Write-Host 'Pre-authorized Azure CLI/public clients for HR MCP delegated scope.'
}

function Save-AzdValue {
    param([string]$Name, [AllowNull()][string]$Value)
    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        & azd env set $Name $Value *> $null
    }
}

function Add-PrivateDnsARecord {
    param(
        [string]$ZoneResourceGroup,
        [string]$ZoneName,
        [string]$RecordName,
        [string]$IpAddress
    )

    if ((Invoke-NativeCommandQuietly { & az network private-dns record-set a show --resource-group $ZoneResourceGroup --zone-name $ZoneName --name "$RecordName" }) -ne 0) {
        & az network private-dns record-set a create `
            --resource-group $ZoneResourceGroup `
            --zone-name $ZoneName `
            --name "$RecordName" `
            --ttl 30 `
            --only-show-errors `
            -o none
    }

    $existing = ConvertTo-TrimmedCliOutput (& az network private-dns record-set a show `
        --resource-group $ZoneResourceGroup `
        --zone-name $ZoneName `
        --name "$RecordName" `
        --query "aRecords[?ipv4Address=='$IpAddress'].ipv4Address | [0]" `
        -o tsv 2>$null)
    if ([string]::IsNullOrWhiteSpace($existing)) {
        & az network private-dns record-set a add-record `
            --resource-group $ZoneResourceGroup `
            --zone-name $ZoneName `
            --record-set-name "$RecordName" `
            --ipv4-address $IpAddress `
            --only-show-errors `
            -o none
    }
}

function Set-PrivateAcaDns {
    param(
        [string]$ZoneResourceGroup,
        [string]$VnetId,
        [string]$DefaultDomain,
        [string]$StaticIp
    )

    if ([string]::IsNullOrWhiteSpace($DefaultDomain)) { throw 'Private Container Apps environment defaultDomain is missing; cannot configure private DNS.' }
    if ([string]::IsNullOrWhiteSpace($StaticIp)) { throw 'Private Container Apps environment staticIp is missing; cannot configure private DNS.' }

    Write-Step "Configuring private DNS for internal ACA domain: $DefaultDomain"
    if ((Invoke-NativeCommandQuietly { & az network private-dns zone show --resource-group $ZoneResourceGroup --name $DefaultDomain }) -ne 0) {
        & az network private-dns zone create `
            --resource-group $ZoneResourceGroup `
            --name $DefaultDomain `
            --only-show-errors `
            -o none
    }

    $linkName = 'lnk-hr-mcp-aca'
    if ((Invoke-NativeCommandQuietly { & az network private-dns link vnet show --resource-group $ZoneResourceGroup --zone-name $DefaultDomain --name $linkName }) -ne 0) {
        & az network private-dns link vnet create `
            --resource-group $ZoneResourceGroup `
            --zone-name $DefaultDomain `
            --name $linkName `
            --virtual-network $VnetId `
            --registration-enabled false `
            --only-show-errors `
            -o none
    }

    Add-PrivateDnsARecord -ZoneResourceGroup $ZoneResourceGroup -ZoneName $DefaultDomain -RecordName '*' -IpAddress $StaticIp
    Add-PrivateDnsARecord -ZoneResourceGroup $ZoneResourceGroup -ZoneName $DefaultDomain -RecordName '*.internal' -IpAddress $StaticIp
}

function Get-PropertyValue {
    param([AllowNull()]$InputObject, [string]$Name)
    if ($null -eq $InputObject) { return $null }
    $member = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $member) { return $null }
    return $member.Value
}

function Test-AcaDelegation {
    param($SubnetObject)

    $properties = Get-PropertyValue -InputObject $SubnetObject -Name 'properties'
    $delegations = Get-PropertyValue -InputObject $properties -Name 'delegations'
    if ($delegations) {
        return $null -ne (@($delegations | Where-Object { (Get-PropertyValue -InputObject (Get-PropertyValue -InputObject $_ -Name 'properties') -Name 'serviceName') -eq 'Microsoft.App/environments' }) | Select-Object -First 1)
    }

    $delegations = Get-PropertyValue -InputObject $SubnetObject -Name 'delegations'
    if ($delegations) {
        return $null -ne (@($delegations | Where-Object { (Get-PropertyValue -InputObject $_ -Name 'serviceName') -eq 'Microsoft.App/environments' }) | Select-Object -First 1)
    }
    return $false
}

function ConvertTo-IPv4UInt32 {
    param([string]$Address)
    $bytes = [System.Net.IPAddress]::Parse($Address).GetAddressBytes()
    [Array]::Reverse($bytes)
    return [BitConverter]::ToUInt32($bytes, 0)
}

function Test-CidrContains {
    param(
        [string]$ParentCidr,
        [string]$ChildCidr
    )
    $parentParts = $ParentCidr.Split('/')
    $childParts = $ChildCidr.Split('/')
    $parentPrefix = [int]$parentParts[1]
    $childPrefix = [int]$childParts[1]
    if ($childPrefix -lt $parentPrefix) { return $false }
    $parentIp = ConvertTo-IPv4UInt32 $parentParts[0]
    $childIp = ConvertTo-IPv4UInt32 $childParts[0]
    $mask = if ($parentPrefix -eq 0) { [uint32]0 } else { [uint32]::MaxValue -shl (32 - $parentPrefix) }
    return (($parentIp -band $mask) -eq ($childIp -band $mask))
}

function Test-PrefixInsideAnyVnetPrefix {
    param(
        [string]$RequestedPrefix,
        [string[]]$VnetPrefixes
    )
    foreach ($prefix in $VnetPrefixes) {
        if (Test-CidrContains -ParentCidr $prefix -ChildCidr $RequestedPrefix) {
            return $true
        }
    }
    return $false
}

function Test-CidrOverlap {
    param(
        [string]$CidrA,
        [string]$CidrB
    )
    return (Test-CidrContains -ParentCidr $CidrA -ChildCidr $CidrB) -or (Test-CidrContains -ParentCidr $CidrB -ChildCidr $CidrA)
}

function Get-SubnetCandidates {
    param(
        [string]$ParentCidr,
        [int]$NewPrefixLength
    )
    $parts = $ParentCidr.Split('/')
    $parentIp = ConvertTo-IPv4UInt32 $parts[0]
    $parentPrefix = [int]$parts[1]
    if ($parentPrefix -gt $NewPrefixLength) { return @() }
    $parentSize = [uint64]1 -shl (32 - $parentPrefix)
    $candidateSize = [uint64]1 -shl (32 - $NewPrefixLength)
    $parentMask = if ($parentPrefix -eq 0) { [uint32]0 } else { [uint32]::MaxValue -shl (32 - $parentPrefix) }
    $network = [uint32]($parentIp -band $parentMask)
    $results = @()
    for ($offset = [uint64]0; $offset -lt $parentSize; $offset += $candidateSize) {
        $candidate = [uint32]($network + $offset)
        $bytes = [BitConverter]::GetBytes($candidate)
        [Array]::Reverse($bytes)
        $results += "$([System.Net.IPAddress]::new($bytes))/$NewPrefixLength"
    }
    return $results
}

function Find-AvailableSubnetPrefix {
    param(
        [string[]]$VnetPrefixes,
        [string[]]$UsedSubnetPrefixes,
        [int]$PrefixLength
    )
    foreach ($parent in ($VnetPrefixes | Sort-Object)) {
        foreach ($candidate in (Get-SubnetCandidates -ParentCidr $parent -NewPrefixLength $PrefixLength)) {
            $overlaps = $false
            foreach ($used in $UsedSubnetPrefixes) {
                if ($used -and (Test-CidrOverlap -CidrA $candidate -CidrB $used)) {
                    $overlaps = $true
                    break
                }
            }
            if (-not $overlaps) { return $candidate }
        }
    }
    return $null
}

function Resolve-CitadelAcaSubnet {
    param(
        [string]$HubResourceGroup,
        [AllowNull()][string]$RequestedVnetName,
        [string]$RequestedSubnetName,
        [AllowNull()][string]$RequestedSubnetId,
        [AllowNull()][string]$RequestedSubnetPrefix,
        [int]$RequestedSubnetPrefixLength
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedSubnetId)) {
        $subnet = & az network vnet subnet show --ids $RequestedSubnetId -o json 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($subnet)) {
            throw "HR_MCP_ACA_SUBNET_ID was provided but could not be resolved: $RequestedSubnetId"
        }
        $subnetObj = $subnet | ConvertFrom-Json
        $parts = $subnetObj.id -split '/'
        $vnetName = $parts[[Array]::IndexOf($parts, 'virtualNetworks') + 1]
        if (-not (Test-AcaDelegation -SubnetObject $subnetObj)) {
            throw "Subnet '$($subnetObj.name)' is not delegated to Microsoft.App/environments. Set HR_MCP_ACA_SUBNET_ID to a dedicated ACA subnet."
        }
        return [pscustomobject]@{
            VnetName = $vnetName
            SubnetName = $subnetObj.name
            SubnetId = $subnetObj.id
        }
    }

    if ([string]::IsNullOrWhiteSpace($RequestedVnetName)) {
        $vnetsJson = & az network vnet list --resource-group $HubResourceGroup -o json 2>$null
        if ($LASTEXITCODE -ne 0) { throw "Could not list VNets in Citadel hub resource group '$HubResourceGroup'." }
        $vnets = @($vnetsJson | ConvertFrom-Json)
        if ($vnets.Count -ne 1) {
            throw "Expected exactly one Citadel hub VNet in resource group '$HubResourceGroup' but found $($vnets.Count). Set HR_MCP_CITADEL_VNET_NAME or HR_MCP_ACA_SUBNET_ID."
        }
        $RequestedVnetName = $vnets[0].name
    }

    $subnetJson = & az network vnet subnet show `
        --resource-group $HubResourceGroup `
        --vnet-name $RequestedVnetName `
        --name $RequestedSubnetName `
        -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($subnetJson)) {
        Write-Step "Creating dedicated HR MCP subnet '$RequestedSubnetName' in Citadel hub VNet"
        $vnetInfo = & az network vnet show --resource-group $HubResourceGroup --name $RequestedVnetName --query '{addressPrefixes:addressSpace.addressPrefixes,subnetPrefixes:subnets[].addressPrefix}' -o json | ConvertFrom-Json
        $prefixes = @($vnetInfo.addressPrefixes)
        $usedSubnetPrefixes = @($vnetInfo.subnetPrefixes)
        if ([string]::IsNullOrWhiteSpace($RequestedSubnetPrefix)) {
            $RequestedSubnetPrefix = Find-AvailableSubnetPrefix -VnetPrefixes $prefixes -UsedSubnetPrefixes $usedSubnetPrefixes -PrefixLength $RequestedSubnetPrefixLength
            if ([string]::IsNullOrWhiteSpace($RequestedSubnetPrefix)) {
                throw "Could not find an available /$RequestedSubnetPrefixLength subnet in VNet '$RequestedVnetName'. Set HR_MCP_ACA_SUBNET_PREFIX to an available, non-overlapping prefix or expand the Citadel hub VNet address space."
            }
        } elseif (-not (Test-PrefixInsideAnyVnetPrefix -RequestedPrefix $RequestedSubnetPrefix -VnetPrefixes $prefixes)) {
            throw "Requested HR_MCP_ACA_SUBNET_PREFIX '$RequestedSubnetPrefix' is outside VNet '$RequestedVnetName'. Choose a prefix inside the existing VNet address space."
        }
        & az network vnet subnet create `
            --resource-group $HubResourceGroup `
            --vnet-name $RequestedVnetName `
            --name $RequestedSubnetName `
            --address-prefixes $RequestedSubnetPrefix `
            --delegations Microsoft.App/environments `
            --only-show-errors `
            -o none
        if ($LASTEXITCODE -ne 0) {
            throw "Could not create subnet '$RequestedSubnetName'. Set HR_MCP_ACA_SUBNET_PREFIX to an available, non-overlapping prefix."
        }
        $subnetJson = & az network vnet subnet show `
            --resource-group $HubResourceGroup `
            --vnet-name $RequestedVnetName `
            --name $RequestedSubnetName `
            -o json
    }

    $subnetObj = $subnetJson | ConvertFrom-Json
    if (-not (Test-AcaDelegation -SubnetObject $subnetObj)) {
        throw "Subnet '$RequestedSubnetName' is not delegated to Microsoft.App/environments. Use a dedicated ACA subnet or set HR_MCP_ACA_SUBNET_ID to one."
    }

    return [pscustomobject]@{
        VnetName = $RequestedVnetName
        SubnetName = $subnetObj.name
        SubnetId = $subnetObj.id
    }
}

Assert-Command az
Assert-Command azd

if ((Invoke-NativeCommandQuietly { & az account show }) -ne 0) {
    throw 'Azure CLI is not logged in. Run az login, then rerun this script.'
}

Write-Step 'Ensuring Azure CLI extensions'
& az extension add --name application-insights --upgrade --only-show-errors *> $null
& az extension add --name containerapp --upgrade --only-show-errors *> $null

$azdResourceGroup = Get-AzdValue -Name 'AZURE_RESOURCE_GROUP'
$azdLocation = Get-AzdValue -Name 'AZURE_LOCATION'
$azdEnvName = Get-AzdValue -Name 'AZURE_ENV_NAME'
$azdSubscriptionId = Get-AzdValue -Name 'AZURE_SUBSCRIPTION_ID'

$location = Get-FirstNonEmpty @($env:AZURE_LOCATION, $azdLocation)
if ([string]::IsNullOrWhiteSpace($location)) { throw 'AZURE_LOCATION is missing. Set AZURE_LOCATION or select an azd environment with AZURE_LOCATION.' }

$subscriptionId = Get-FirstNonEmpty @($env:AZURE_SUBSCRIPTION_ID, $azdSubscriptionId)
if (-not [string]::IsNullOrWhiteSpace($subscriptionId)) {
    & az account set --subscription $subscriptionId
} else {
    $subscriptionId = ConvertTo-TrimmedCliOutput (& az account show --query id -o tsv)
}

$tenantId = ConvertTo-TrimmedCliOutput (& az account show --query tenantId -o tsv)
$envName = Get-FirstNonEmpty @($env:AZURE_ENV_NAME, $azdEnvName, 'hrmcp')
$seedSource = Get-FirstNonEmpty @($env:HR_MCP_NAME_SEED, $envName, $azdResourceGroup)
$nameSeed = ConvertTo-SafeNamePart $seedSource
$compactSeed = ConvertTo-CompactNamePart $seedSource
$subscriptionSuffix = ($subscriptionId -replace '-', '').Substring(0, 8)
$tagEnvName = if ([string]::IsNullOrWhiteSpace($envName)) { 'unknown' } else { $envName }

if ([string]::IsNullOrWhiteSpace($ResourceGroupName)) { $ResourceGroupName = "rg-$nameSeed-hr-mcp" }
if ($ResourceGroupName.Length -gt 90) { $ResourceGroupName = $ResourceGroupName.Substring(0, 90).TrimEnd('-') }
if ([string]::IsNullOrWhiteSpace($LogAnalyticsWorkspaceName)) { $LogAnalyticsWorkspaceName = "law-$nameSeed-hr-$subscriptionSuffix" }
if ($LogAnalyticsWorkspaceName.Length -gt 63) { $LogAnalyticsWorkspaceName = $LogAnalyticsWorkspaceName.Substring(0, 63).TrimEnd('-') }
if ([string]::IsNullOrWhiteSpace($AppInsightsName)) { $AppInsightsName = "appi-$nameSeed-hr-$subscriptionSuffix" }
if ($AppInsightsName.Length -gt 255) { $AppInsightsName = $AppInsightsName.Substring(0, 255).TrimEnd('-') }
if ([string]::IsNullOrWhiteSpace($AcrName)) { $AcrName = "acr${compactSeed}hr$subscriptionSuffix" }
$AcrName = $AcrName -replace '[^a-zA-Z0-9]', ''
if ($AcrName.Length -gt 50) { $AcrName = $AcrName.Substring(0, 50) }
if ([string]::IsNullOrWhiteSpace($AcaEnvironmentName)) { $AcaEnvironmentName = "cae-$nameSeed-hr-mcp" }
if ($AcaEnvironmentName.Length -gt 32) { $AcaEnvironmentName = $AcaEnvironmentName.Substring(0, 32).TrimEnd('-') }
if ([string]::IsNullOrWhiteSpace($ContainerAppName)) { $ContainerAppName = "ca-$nameSeed-hr-mcp" }
if ($ContainerAppName.Length -gt 32) { $ContainerAppName = $ContainerAppName.Substring(0, 32).TrimEnd('-') }
if ([string]::IsNullOrWhiteSpace($PrivateAcaEnvironmentName)) { $PrivateAcaEnvironmentName = "cae-$nameSeed-hr-mcp-int" }
if ($PrivateAcaEnvironmentName.Length -gt 32) { $PrivateAcaEnvironmentName = $PrivateAcaEnvironmentName.Substring(0, 32).TrimEnd('-') }
if ([string]::IsNullOrWhiteSpace($PrivateContainerAppName)) { $PrivateContainerAppName = "ca-$nameSeed-hr-mcp-int" }
if ($PrivateContainerAppName.Length -gt 32) { $PrivateContainerAppName = $PrivateContainerAppName.Substring(0, 32).TrimEnd('-') }

$apiDisplayName = Get-FirstNonEmpty @($env:HR_MCP_API_APP_DISPLAY_NAME, "$envName-hr-mcp-api")
$publicDisplayName = Get-FirstNonEmpty @($env:HR_MCP_PUBLIC_CLIENT_DISPLAY_NAME, "$envName-hr-mcp-public-client")
$imageRepository = Get-FirstNonEmpty @($env:HR_MCP_IMAGE_REPOSITORY, 'hr-mcp')
$imageTag = Get-FirstNonEmpty @($env:HR_MCP_IMAGE_TAG, ('build-' + (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')))
$issuer = Get-FirstNonEmpty @($env:HR_MCP_ISSUER, "https://login.microsoftonline.com/$tenantId/v2.0")

$scriptDir = Split-Path -Parent $PSCommandPath
$workshopDir = Resolve-Path (Join-Path $scriptDir '..' '..')
$dockerfilePath = Join-Path $workshopDir 'mcp-hr/server/Dockerfile'
if (-not (Test-Path $dockerfilePath)) { throw "Dockerfile not found: $dockerfilePath" }

if ([string]::IsNullOrWhiteSpace($CitadelResourceGroup)) {
    $CitadelResourceGroup = Get-FirstNonEmpty @($env:AZURE_RESOURCE_GROUP, $azdResourceGroup)
}
if ([string]::IsNullOrWhiteSpace($CitadelResourceGroup)) {
    throw 'Citadel hub resource group is missing. Set HR_MCP_CITADEL_RESOURCE_GROUP or ensure AZURE_RESOURCE_GROUP is available in azd env.'
}
$acaSubnet = Resolve-CitadelAcaSubnet -HubResourceGroup $CitadelResourceGroup -RequestedVnetName $CitadelVnetName -RequestedSubnetName $AcaSubnetName -RequestedSubnetId $AcaSubnetId -RequestedSubnetPrefix $AcaSubnetPrefix -RequestedSubnetPrefixLength $AcaSubnetPrefixLength

Write-Step 'Creating HR MCP resource group'
& az group create `
    --name $ResourceGroupName `
    --location $location `
    --tags "azd-env-name=$tagEnvName" 'workload=hr-mcp' $securityControlTag `
    -o none

Write-Step 'Creating Log Analytics workspace'
if ((Invoke-NativeCommandQuietly { & az monitor log-analytics workspace show --resource-group $ResourceGroupName --workspace-name $LogAnalyticsWorkspaceName }) -ne 0) {
    & az monitor log-analytics workspace create `
        --resource-group $ResourceGroupName `
        --workspace-name $LogAnalyticsWorkspaceName `
        --location $location `
        --sku PerGB2018 `
        --tags "azd-env-name=$tagEnvName" 'workload=hr-mcp' $securityControlTag `
        -o none
} else {
    Write-Host "Log Analytics workspace already exists: $LogAnalyticsWorkspaceName"
}
$logAnalyticsWorkspaceId = ConvertTo-TrimmedCliOutput (& az monitor log-analytics workspace show --resource-group $ResourceGroupName --workspace-name $LogAnalyticsWorkspaceName --query id -o tsv)

Write-Step 'Creating workspace-based Application Insights'
if ((Invoke-NativeCommandQuietly { & az monitor app-insights component show --app $AppInsightsName --resource-group $ResourceGroupName }) -ne 0) {
    & az monitor app-insights component create `
        --app $AppInsightsName `
        --location $location `
        --resource-group $ResourceGroupName `
        --workspace $logAnalyticsWorkspaceId `
        --kind web `
        --application-type web `
        --tags "azd-env-name=$tagEnvName" 'workload=hr-mcp' $securityControlTag `
        -o none
} else {
    Write-Host "Application Insights already exists: $AppInsightsName"
}
$appInsightsConnectionString = ConvertTo-TrimmedCliOutput (& az monitor app-insights component show --app $AppInsightsName --resource-group $ResourceGroupName --query connectionString -o tsv)

Write-Step 'Creating or configuring Entra app registrations'
$apiApp = Ensure-ApiAppRegistration -DisplayName $apiDisplayName -RequestedClientId $ApiClientId -ScopeValue $ScopeName -RoleValue $AppRoleValue
$publicApp = Ensure-PublicClientRegistration -DisplayName $publicDisplayName -RequestedClientId $PublicClientId -ApiClientId $apiApp.ClientId -ScopeId $apiApp.ScopeId
Ensure-ApiServicePrincipal -ApiClientId $apiApp.ClientId
Set-ApiPreauthorizedClients -ApiObjectId $apiApp.ObjectId -ScopeId $apiApp.ScopeId -ClientIds @($azureCliClientId, $publicApp.ClientId)

Write-Step 'Creating Azure Container Registry'
if ((Invoke-NativeCommandQuietly { & az acr show --name $AcrName --resource-group $ResourceGroupName }) -ne 0) {
    & az acr create `
        --name $AcrName `
        --resource-group $ResourceGroupName `
        --location $location `
        --sku Basic `
        --admin-enabled false `
        --tags "azd-env-name=$tagEnvName" 'workload=hr-mcp' $securityControlTag `
        -o none
} else {
    Write-Host "Container Registry already exists: $AcrName"
}
$acrId = ConvertTo-TrimmedCliOutput (& az acr show --name $AcrName --resource-group $ResourceGroupName --query id -o tsv)
$acrLoginServer = ConvertTo-TrimmedCliOutput (& az acr show --name $AcrName --resource-group $ResourceGroupName --query loginServer -o tsv)
$imageName = "${acrLoginServer}/${imageRepository}:${imageTag}"

Write-Step 'Building HR MCP image remotely with ACR'
$baseImageRef = 'python:3.13-slim'
$uvImageRef = 'ghcr.io/astral-sh/uv:latest'
& az acr import --name $AcrName --source docker.io/library/python:3.13-slim --image python:3.13-slim --force --only-show-errors -o none 2>$null
if ($LASTEXITCODE -eq 0) { $baseImageRef = "$acrLoginServer/python:3.13-slim" } else { Write-Warning "Could not import python:3.13-slim into $AcrName; building from Docker Hub (may hit pull-rate limits)." }
& az acr import --name $AcrName --source ghcr.io/astral-sh/uv:latest --image astral-sh/uv:latest --force --only-show-errors -o none 2>$null
if ($LASTEXITCODE -eq 0) { $uvImageRef = "$acrLoginServer/astral-sh/uv:latest" } else { Write-Warning "Could not import the uv image into $AcrName; building from GHCR." }
Push-Location $workshopDir
try {
    & az acr build `
        --registry $AcrName `
        --image "${imageRepository}:${imageTag}" `
        --file 'mcp-hr/server/Dockerfile' `
        --build-arg "BASE_IMAGE=$baseImageRef" `
        --build-arg "UV_IMAGE=$uvImageRef" `
        . `
        --only-show-errors `
        -o none
}
finally {
    Pop-Location
}

Write-Step 'Creating Container Apps environment'
if ((Invoke-NativeCommandQuietly { & az containerapp env show --name $AcaEnvironmentName --resource-group $ResourceGroupName }) -ne 0) {
    $workspaceCustomerId = ConvertTo-TrimmedCliOutput (& az monitor log-analytics workspace show --resource-group $ResourceGroupName --workspace-name $LogAnalyticsWorkspaceName --query customerId -o tsv)
    $workspaceKey = ConvertTo-TrimmedCliOutput (& az monitor log-analytics workspace get-shared-keys --resource-group $ResourceGroupName --workspace-name $LogAnalyticsWorkspaceName --query primarySharedKey -o tsv)
    & az containerapp env create `
        --name $AcaEnvironmentName `
        --resource-group $ResourceGroupName `
        --location $location `
        --logs-workspace-id $workspaceCustomerId `
        --logs-workspace-key $workspaceKey `
        --tags "azd-env-name=$tagEnvName" 'workload=hr-mcp' $securityControlTag `
        --only-show-errors `
        -o none
} else {
    Write-Host "Container Apps environment already exists: $AcaEnvironmentName"
}

Write-Step 'Creating private Container Apps environment in the Citadel hub VNet'
if ((Invoke-NativeCommandQuietly { & az containerapp env show --name $PrivateAcaEnvironmentName --resource-group $ResourceGroupName }) -ne 0) {
    $workspaceCustomerId = ConvertTo-TrimmedCliOutput (& az monitor log-analytics workspace show --resource-group $ResourceGroupName --workspace-name $LogAnalyticsWorkspaceName --query customerId -o tsv)
    $workspaceKey = ConvertTo-TrimmedCliOutput (& az monitor log-analytics workspace get-shared-keys --resource-group $ResourceGroupName --workspace-name $LogAnalyticsWorkspaceName --query primarySharedKey -o tsv)
    & az containerapp env create `
        --name $PrivateAcaEnvironmentName `
        --resource-group $ResourceGroupName `
        --location $location `
        --logs-workspace-id $workspaceCustomerId `
        --logs-workspace-key $workspaceKey `
        --infrastructure-subnet-resource-id $acaSubnet.SubnetId `
        --internal-only `
        --tags "azd-env-name=$tagEnvName" 'workload=hr-mcp' $securityControlTag `
        --only-show-errors `
        -o none
} else {
    Write-Host "Private Container Apps environment already exists: $PrivateAcaEnvironmentName"
}

$privateEnvDefaultDomain = ConvertTo-TrimmedCliOutput (& az containerapp env show --name $PrivateAcaEnvironmentName --resource-group $ResourceGroupName --query properties.defaultDomain -o tsv)
$privateEnvStaticIp = ConvertTo-TrimmedCliOutput (& az containerapp env show --name $PrivateAcaEnvironmentName --resource-group $ResourceGroupName --query properties.staticIp -o tsv)
$citadelVnetId = ConvertTo-TrimmedCliOutput (& az network vnet show --resource-group $CitadelResourceGroup --name $acaSubnet.VnetName --query id -o tsv)
Set-PrivateAcaDns -ZoneResourceGroup $CitadelResourceGroup -VnetId $citadelVnetId -DefaultDomain $privateEnvDefaultDomain -StaticIp $privateEnvStaticIp

$otelResourceAttributes = "service.namespace=workshop,deployment.environment=$tagEnvName,azure.resource_group=$ResourceGroupName"
$commonEnvVars = @(
    'AUTH_ENABLED=true',
    "ENTRA_TENANT_ID=$tenantId",
    "ENTRA_AUDIENCE=$($apiApp.Audience)",
    "ENTRA_REQUIRED_SCOPE=$ScopeName",
    "ENTRA_REQUIRED_ROLE=$AppRoleValue",
    "ENTRA_ISSUER=$issuer",
    "APPLICATIONINSIGHTS_CONNECTION_STRING=$appInsightsConnectionString",
    'OTEL_SERVICE_NAME=hr-mcp',
    "OTEL_RESOURCE_ATTRIBUTES=$otelResourceAttributes",
    'PORT=8080'
)

Write-Step 'Creating or updating HR MCP Container App'
if ((Invoke-NativeCommandQuietly { & az containerapp show --name $ContainerAppName --resource-group $ResourceGroupName }) -ne 0) {
    & az containerapp create `
        --name $ContainerAppName `
        --resource-group $ResourceGroupName `
        --environment $AcaEnvironmentName `
        --image 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest' `
        --target-port 80 `
        --ingress external `
        --min-replicas 0 `
        --max-replicas 2 `
        --system-assigned `
        --env-vars @commonEnvVars `
        --tags "azd-env-name=$tagEnvName" 'workload=hr-mcp' $securityControlTag `
        --only-show-errors `
        -o none
} else {
    Write-Host "Container App already exists: $ContainerAppName"
    & az containerapp identity assign `
        --name $ContainerAppName `
        --resource-group $ResourceGroupName `
        --system-assigned `
        --only-show-errors `
        -o none *> $null
}

$containerAppPrincipalId = ConvertTo-TrimmedCliOutput (& az containerapp show --name $ContainerAppName --resource-group $ResourceGroupName --query identity.principalId -o tsv)
if ([string]::IsNullOrWhiteSpace($containerAppPrincipalId)) { throw 'Could not resolve Container App managed identity principalId.' }
Add-RoleAssignmentIfMissing -PrincipalId $containerAppPrincipalId -PrincipalType ServicePrincipal -RoleId $acrPullRoleId -RoleName 'AcrPull (HR MCP Container App)' -Scope $acrId
Wait-RoleAssignment -PrincipalId $containerAppPrincipalId -RoleId $acrPullRoleId -Scope $acrId -RoleName 'AcrPull'

& az containerapp registry set `
    --name $ContainerAppName `
    --resource-group $ResourceGroupName `
    --server $acrLoginServer `
    --identity system `
    --only-show-errors `
    -o none

& az containerapp ingress update `
    --name $ContainerAppName `
    --resource-group $ResourceGroupName `
    --target-port 8080 `
    --only-show-errors `
    -o none

& az containerapp update `
    --name $ContainerAppName `
    --resource-group $ResourceGroupName `
    --image $imageName `
    --set-env-vars @commonEnvVars `
    --min-replicas 0 `
    --max-replicas 2 `
    --only-show-errors `
    -o none

Write-Step 'Creating or updating private HR MCP Container App for APIM backend traffic'
if ((Invoke-NativeCommandQuietly { & az containerapp show --name $PrivateContainerAppName --resource-group $ResourceGroupName }) -ne 0) {
    & az containerapp create `
        --name $PrivateContainerAppName `
        --resource-group $ResourceGroupName `
        --environment $PrivateAcaEnvironmentName `
        --image 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest' `
        --target-port 80 `
        --ingress external `
        --min-replicas 0 `
        --max-replicas 2 `
        --system-assigned `
        --env-vars @commonEnvVars `
        --tags "azd-env-name=$tagEnvName" 'workload=hr-mcp-private' $securityControlTag `
        --only-show-errors `
        -o none
} else {
    Write-Host "Private Container App already exists: $PrivateContainerAppName"
    & az containerapp identity assign `
        --name $PrivateContainerAppName `
        --resource-group $ResourceGroupName `
        --system-assigned `
        --only-show-errors `
        -o none *> $null
}

$privateContainerAppPrincipalId = ConvertTo-TrimmedCliOutput (& az containerapp show --name $PrivateContainerAppName --resource-group $ResourceGroupName --query identity.principalId -o tsv)
if ([string]::IsNullOrWhiteSpace($privateContainerAppPrincipalId)) { throw 'Could not resolve private Container App managed identity principalId.' }
Add-RoleAssignmentIfMissing -PrincipalId $privateContainerAppPrincipalId -PrincipalType ServicePrincipal -RoleId $acrPullRoleId -RoleName 'AcrPull (Private HR MCP Container App)' -Scope $acrId
Wait-RoleAssignment -PrincipalId $privateContainerAppPrincipalId -RoleId $acrPullRoleId -Scope $acrId -RoleName 'AcrPull (private app)'

& az containerapp registry set `
    --name $PrivateContainerAppName `
    --resource-group $ResourceGroupName `
    --server $acrLoginServer `
    --identity system `
    --only-show-errors `
    -o none

& az containerapp ingress update `
    --name $PrivateContainerAppName `
    --resource-group $ResourceGroupName `
    --target-port 8080 `
    --type external `
    --transport http `
    --only-show-errors `
    -o none

& az containerapp update `
    --name $PrivateContainerAppName `
    --resource-group $ResourceGroupName `
    --image $imageName `
    --set-env-vars @commonEnvVars `
    --min-replicas 0 `
    --max-replicas 2 `
    --only-show-errors `
    -o none

$containerAppUpdateHelp = (& az containerapp update -h 2>$null) -join "`n"
if ($containerAppUpdateHelp -match '--startup-probe') {
    Write-Step 'Configuring health probes'
    & az containerapp update `
        --name $ContainerAppName `
        --resource-group $ResourceGroupName `
        --startup-probe 'path=/health,port=8080,transport=HTTP,initialDelaySeconds=10,periodSeconds=10,failureThreshold=12' `
        --liveness-probe 'path=/health,port=8080,transport=HTTP,initialDelaySeconds=30,periodSeconds=30,failureThreshold=3' `
        --only-show-errors `
        -o none
    if ($LASTEXITCODE -ne 0) {
        Write-Warning 'Probe configuration failed. The app is deployed; configure /health probes from the Container App portal if your CLI version lacks compatible probe syntax.'
    }
    & az containerapp update `
        --name $PrivateContainerAppName `
        --resource-group $ResourceGroupName `
        --startup-probe 'path=/health,port=8080,transport=HTTP,initialDelaySeconds=10,periodSeconds=10,failureThreshold=12' `
        --liveness-probe 'path=/health,port=8080,transport=HTTP,initialDelaySeconds=30,periodSeconds=30,failureThreshold=3' `
        --only-show-errors `
        -o none
    if ($LASTEXITCODE -ne 0) {
        Write-Warning 'Private app probe configuration failed. The app is deployed; configure /health probes from the Container App portal if your CLI version lacks compatible probe syntax.'
    }
} else {
    Write-Warning 'Azure CLI containerapp extension does not expose probe flags. The app is configured correctly; add /health startup/liveness probes later if desired.'
}

$containerAppFqdn = ConvertTo-TrimmedCliOutput (& az containerapp show --name $ContainerAppName --resource-group $ResourceGroupName --query properties.configuration.ingress.fqdn -o tsv)
$directUrl = "https://$containerAppFqdn"
$directMcpUrl = "$directUrl/mcp"
$privateContainerAppFqdn = ConvertTo-TrimmedCliOutput (& az containerapp show --name $PrivateContainerAppName --resource-group $ResourceGroupName --query properties.configuration.ingress.fqdn -o tsv)
$privateBackendUrl = "https://$privateContainerAppFqdn"
$privateMcpUrl = "$privateBackendUrl/mcp"
$privateBackendIpUrl = "http://$privateEnvStaticIp"

Write-Step 'Saving HR MCP outputs to azd environment'
Save-AzdValue HR_MCP_RESOURCE_GROUP $ResourceGroupName
Save-AzdValue HR_MCP_ACR_NAME $AcrName
Save-AzdValue HR_MCP_ACR_LOGIN_SERVER $acrLoginServer
Save-AzdValue HR_MCP_CONTAINER_APP_NAME $ContainerAppName
Save-AzdValue HR_MCP_PRIVATE_ACA_ENVIRONMENT_NAME $PrivateAcaEnvironmentName
Save-AzdValue HR_MCP_PRIVATE_CONTAINER_APP_NAME $PrivateContainerAppName
Save-AzdValue HR_MCP_DIRECT_URL $directUrl
Save-AzdValue HR_MCP_DIRECT_MCP_URL $directMcpUrl
Save-AzdValue HR_MCP_PRIVATE_BACKEND_URL $privateBackendUrl
Save-AzdValue HR_MCP_PRIVATE_BACKEND_IP_URL $privateBackendIpUrl
Save-AzdValue HR_MCP_APIM_BACKEND_HOST_HEADER $privateContainerAppFqdn
Save-AzdValue HR_MCP_PRIVATE_MCP_URL $privateMcpUrl
Save-AzdValue HR_MCP_ACA_INTERNAL_FQDN $privateContainerAppFqdn
Save-AzdValue HR_MCP_PRIVATE_DNS_ZONE $privateEnvDefaultDomain
Save-AzdValue HR_MCP_PRIVATE_DNS_RESOURCE_GROUP $CitadelResourceGroup
Save-AzdValue HR_MCP_APIM_REQUIRE_PRIVATE_BACKEND 'true'
Save-AzdValue HR_MCP_CITADEL_RESOURCE_GROUP $CitadelResourceGroup
Save-AzdValue HR_MCP_CITADEL_VNET_NAME $acaSubnet.VnetName
Save-AzdValue HR_MCP_ACA_SUBNET_NAME $acaSubnet.SubnetName
Save-AzdValue HR_MCP_ACA_SUBNET_ID $acaSubnet.SubnetId
Save-AzdValue HR_MCP_APP_INSIGHTS_NAME $AppInsightsName
Save-AzdValue HR_MCP_TENANT_ID $tenantId
Save-AzdValue HR_MCP_API_CLIENT_ID $apiApp.ClientId
Save-AzdValue HR_MCP_PUBLIC_CLIENT_ID $publicApp.ClientId
Save-AzdValue HR_MCP_AUDIENCE $apiApp.Audience
Save-AzdValue HR_MCP_SCOPE $apiApp.Scope
Save-AzdValue HR_MCP_APP_ROLE_ID $apiApp.AppRoleId
Save-AzdValue HR_MCP_APP_ROLE_VALUE $AppRoleValue
Save-AzdValue HR_MCP_API_OBJECT_ID $apiApp.ObjectId
Save-AzdValue HR_MCP_REQUIRED_SCOPE_CLAIM $ScopeName

Write-Host "`nHR MCP ACA deployment is ready."
Write-Host "Resource group: $ResourceGroupName"
Write-Host "Container App: $ContainerAppName"
Write-Host "Direct URL: $directUrl"
Write-Host "MCP endpoint: $directMcpUrl"
Write-Host "Private Container App: $PrivateContainerAppName"
Write-Host "Private backend URL for APIM: $privateBackendUrl"
Write-Host "Private backend IP URL fallback: $privateBackendIpUrl"
Write-Host "Private ACA DNS zone: $privateEnvDefaultDomain ($CitadelResourceGroup)"
Write-Host "Citadel hub VNet/subnet: $($acaSubnet.VnetName)/$($acaSubnet.SubnetName)"
Write-Host "API app client id: $($apiApp.ClientId)"
Write-Host "Public client id: $($publicApp.ClientId)"
Write-Host "Audience: $($apiApp.Audience)"
Write-Host "Scope: $($apiApp.Scope)"
Write-Host "`nToken acquisition examples (these print tokens; use only in your own shell):"
Write-Host "az login --tenant `"$tenantId`" --use-device-code"
Write-Host "az account get-access-token --tenant `"$tenantId`" --scope `"$($apiApp.Scope)`" --query accessToken -o tsv"
Write-Host "`nSmoke test (acquires a token with Azure CLI; does not print it):"
Write-Host 'cd workshop; uv run python mcp-hr/scripts/test-hr-mcp-direct.py'
Write-Host "`nMCP config snippet (replace <ACCESS_TOKEN>; never store real tokens in source):"
Write-Host @"
{
  "mcpServers": {
    "hr-mcp-direct": {
      "type": "http",
      "url": "$directMcpUrl",
      "headers": {
        "Authorization": "Bearer <ACCESS_TOKEN>"
      }
    }
  }
}
"@
