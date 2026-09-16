#requires -Version 7.4
<#
.SYNOPSIS
Preview, or explicitly activate approved Graph read roles for this demo's identity.
.DESCRIPTION
Default is read-only preview. No az account set, az login, az rest, role removals,
directory-role changes or arbitrary Graph roles. Never run activation until the
user has explicitly approved the selected application permissions.
.EXAMPLE
./Grant-IntuneHealthGraphRoles.ps1
.EXAMPLE
# ONLY AFTER explicit approval of BOTH permissions:
./Grant-IntuneHealthGraphRoles.ps1 -ActivateApprovedGrants -ApprovedRoles DeviceManagementManagedDevices.Read.All,DeviceManagementServiceConfig.Read.All
#>
[CmdletBinding()]
param(
    [switch]$ActivateApprovedGrants,
    [ValidateSet('DeviceManagementManagedDevices.Read.All','DeviceManagementServiceConfig.Read.All')]
    [string[]]$ApprovedRoles = @()
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
# SETUP: replace both zero GUIDs and the resource names below before using the helper.
$script:GrantTenantId = '00000000-0000-0000-0000-000000000000'
$script:GrantSubscriptionId = '00000000-0000-0000-0000-000000000000'
$script:GrantAccountName = 'aa-intune-health-demo'
$script:GrantResourceId = "/subscriptions/$($script:GrantSubscriptionId)/resourceGroups/rg-intune-keynote-demo/providers/Microsoft.Automation/automationAccounts/$($script:GrantAccountName)"
$script:GraphResourceAppId = '00000003-0000-0000-c000-000000000000'
$script:AllowedGrantRoles = [ordered]@{
    'DeviceManagementManagedDevices.Read.All' = '2f51be20-0bb4-4fed-bf7b-db946066c75e'
    'DeviceManagementServiceConfig.Read.All' = '06a5fe6d-c49d-46a7-b082-56b1b14103c7'
}

function Invoke-DemoAzRead {
    param([Parameter(Mandatory)][string[]]$Arguments)
    # All callers use fixed read-only verbs and explicitly select the configured subscription by ID.
    $output = & az @Arguments --only-show-errors --output json 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Azure CLI read failed. Check existing login/access; no global account configuration was changed.' }
    try { return (($output -join "`n") | ConvertFrom-Json -AsHashtable) }
    catch { throw 'Azure CLI returned invalid JSON; response suppressed.' }
}

function Assert-DemoOperatorGraphToken {
    param([Parameter(Mandatory)][string]$Token)
    try {
        $segments = $Token.Split('.')
        if ($segments.Count -ne 3) { throw 'Invalid token' }
        $segment = $segments[1].Replace('-', '+').Replace('_', '/')
        $segment = $segment.PadRight($segment.Length + ((4 - $segment.Length % 4) % 4), '=')
        $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($segment)) | ConvertFrom-Json -AsHashtable
        if ($claims['tid'] -ne $script:GrantTenantId) { throw 'Unexpected tenant' }
        if ($claims['aud'] -notin @('https://graph.microsoft.com','https://graph.microsoft.com/',$script:GraphResourceAppId)) { throw 'Unexpected audience' }
        if ([long]$claims['exp'] -le [DateTimeOffset]::UtcNow.AddMinutes(2).ToUnixTimeSeconds()) { throw 'Expired token' }
    } catch { throw 'Refused Graph token: tenant, audience or expiry does not match this operation.' }
}

function Invoke-DemoGraphRequest {
    param([Parameter(Mandatory)][ValidateSet('GET','POST')][string]$Method,
          [Parameter(Mandatory)][uri]$Uri,
          [Parameter(Mandatory)][Security.SecureString]$Token,
          [AllowNull()][hashtable]$Body)
    if ($Uri.Scheme -ne 'https' -or $Uri.Host -ne 'graph.microsoft.com' -or $Uri.Port -ne 443 -or $Uri.UserInfo -or $Uri.Fragment -or -not $Uri.AbsolutePath.StartsWith('/v1.0/servicePrincipals')) { throw 'Refused unexpected Graph request destination.' }
    $statusCode = 0
    $parameters = @{
        Method=$Method; Uri=$Uri; Authentication='Bearer'; Token=$Token
        TimeoutSec=60; MaximumRedirection=0; SkipHttpErrorCheck=$true
        StatusCodeVariable='statusCode'; ErrorAction='Stop'
    }
    if ($Method -eq 'POST') { $parameters['Body']=$Body | ConvertTo-Json -Compress; $parameters['ContentType']='application/json' }
    try { $result = Invoke-RestMethod @parameters }
    catch { throw 'Graph transport failed. No POST is automatically replayed; rerun the read-only preview before continuing. Response suppressed.' }
    if ($statusCode -lt 200 -or $statusCode -ge 300) { throw "Graph operation returned HTTP $statusCode. Verify operator privileges and rerun preview; no broad permissions were granted. Response suppressed." }
    return $result
}

function Get-DemoGraphCollection {
    param([Parameter(Mandatory)][uri]$Uri, [Parameter(Mandatory)][Security.SecureString]$Token)
    $items = [Collections.Generic.List[object]]::new()
    $visited = [Collections.Generic.HashSet[string]]::new()
    $next = [string]$Uri
    $initialPath = $Uri.AbsolutePath
    while ($next) {
        $pageUri = [uri]$next
        if ($pageUri.AbsolutePath -ne $initialPath -or -not $visited.Add($next) -or $visited.Count -gt 1000) { throw 'Unexpected or looping Graph pagination.' }
        $page = Invoke-DemoGraphRequest -Method GET -Uri $pageUri -Token $Token
        if ($null -eq $page -or $null -eq $page.PSObject.Properties['value'] -or $null -eq $page.value) { throw 'Graph collection response incomplete.' }
        foreach ($item in @($page.value)) { $items.Add($item) }
        $nextProperty = $page.PSObject.Properties['@odata.nextLink']
        $next = if ($null -ne $nextProperty) { [string]$nextProperty.Value } else { '' }
    }
    return @($items)
}

function Get-DemoExistingGrants {
    param([Parameter(Mandatory)][string]$PrincipalId, [Parameter(Mandatory)][Security.SecureString]$Token)
    Get-DemoGraphCollection -Uri ("https://graph.microsoft.com/v1.0/servicePrincipals/$PrincipalId/appRoleAssignments" + '?$select=id,principalId,resourceId,appRoleId') -Token $Token
}

function Invoke-DemoRoleGrant {
    param([switch]$ActivateApprovedGrants,
          [ValidateSet('DeviceManagementManagedDevices.Read.All','DeviceManagementServiceConfig.Read.All')]
          [string[]]$ApprovedRoles = @())
    if ($ActivateApprovedGrants -and $ApprovedRoles.Count -eq 0) { throw 'Activation requires explicitly listing the approved roles using -ApprovedRoles.' }
    $selectedRoles = if ($ApprovedRoles.Count) { @($ApprovedRoles | Select-Object -Unique) } else { @($script:AllowedGrantRoles.Keys) }
    $secureToken = $null
    $rawToken = $null
    try {
        $subscription = Invoke-DemoAzRead -Arguments @('account','show','--subscription',$script:GrantSubscriptionId)
        if ($subscription['id'] -ne $script:GrantSubscriptionId -or $subscription['tenantId'] -ne $script:GrantTenantId) { throw 'The configured subscription does not resolve to the approved subscription and tenant.' }
        $resource = Invoke-DemoAzRead -Arguments @('resource','show','--subscription',$script:GrantSubscriptionId,'--ids',$script:GrantResourceId,'--api-version','2024-10-23')
        if ($resource['id'] -ine $script:GrantResourceId -or $resource['name'] -ne $script:GrantAccountName -or $resource['type'] -ine 'Microsoft.Automation/automationAccounts') { throw 'ARM resource does not match the approved Automation account.' }
        $identity = $resource['identity']
        if ($null -eq $identity -or $identity['type'] -notmatch 'SystemAssigned' -or $identity['tenantId'] -ne $script:GrantTenantId) { throw 'The target account does not expose the expected system-assigned identity and tenant.' }
        $principalGuid = [guid]::Empty
        if (-not [guid]::TryParse([string]$identity['principalId'], [ref]$principalGuid) -or $principalGuid -eq [guid]::Empty) { throw 'ARM did not return a valid identity principal ID.' }
        $principalId = $principalGuid.ToString()

        # Explicit subscription is essential: never use az rest with default tenant.
        $tokenResponse = Invoke-DemoAzRead -Arguments @('account','get-access-token','--subscription',$script:GrantSubscriptionId,'--resource','https://graph.microsoft.com/')
        if ($tokenResponse.ContainsKey('tenant') -and $tokenResponse['tenant'] -ne $script:GrantTenantId) { throw 'Azure CLI token response tenant mismatch.' }
        $rawToken = [string]$tokenResponse['accessToken']
        Assert-DemoOperatorGraphToken -Token $rawToken
        $secureToken = ConvertTo-SecureString -String $rawToken -AsPlainText -Force
        $rawToken = $null
        $tokenResponse = $null

        $managedIdentity = Invoke-DemoGraphRequest -Method GET -Uri ("https://graph.microsoft.com/v1.0/servicePrincipals/$principalId" + '?$select=id,displayName,servicePrincipalType') -Token $secureToken
        if ($managedIdentity.id -ne $principalId -or $managedIdentity.servicePrincipalType -ne 'ManagedIdentity' -or $managedIdentity.displayName -ne $script:GrantAccountName) { throw 'Graph identity does not match the ARM-managed Automation account identity.' }
        $graph = Invoke-DemoGraphRequest -Method GET -Uri ("https://graph.microsoft.com/v1.0/servicePrincipals(appId='$($script:GraphResourceAppId)')" + '?$select=id,appId,appRoles') -Token $secureToken
        $graphGuid = [guid]::Empty
        if ($graph.appId -ne $script:GraphResourceAppId -or -not [guid]::TryParse([string]$graph.id,[ref]$graphGuid) -or $graphGuid -eq [guid]::Empty) { throw 'Could not resolve the correct Microsoft Graph resource service principal.' }
        $graphId = $graphGuid.ToString()
        foreach ($roleName in $selectedRoles) {
            $matching = @($graph.appRoles | Where-Object { $_.id -eq $script:AllowedGrantRoles[$roleName] -and $_.value -eq $roleName -and $_.isEnabled -eq $true -and 'Application' -in $_.allowedMemberTypes })
            if ($matching.Count -ne 1) { throw "Approved role definition mismatch: $roleName." }
        }
        $existing = @(Get-DemoExistingGrants -PrincipalId $principalId -Token $secureToken)
        $report = [Collections.Generic.List[object]]::new()
        foreach ($roleName in $selectedRoles) {
            $roleId = $script:AllowedGrantRoles[$roleName]
            $present = @($existing | Where-Object { $_.principalId -eq $principalId -and $_.resourceId -eq $graphId -and $_.appRoleId -eq $roleId }).Count -gt 0
            if ($present) {
                $report.Add([pscustomobject]@{Permission=$roleName;AppRoleId=$roleId;Result='AlreadyPresent'})
                continue
            }
            if (-not $ActivateApprovedGrants) {
                $report.Add([pscustomobject]@{Permission=$roleName;AppRoleId=$roleId;Result='WouldGrantAfterApproval'})
                continue
            }
            # Re-read immediately before each approved grant to keep re-runs safe.
            $existing = @(Get-DemoExistingGrants -PrincipalId $principalId -Token $secureToken)
            $present = @($existing | Where-Object { $_.principalId -eq $principalId -and $_.resourceId -eq $graphId -and $_.appRoleId -eq $roleId }).Count -gt 0
            if ($present) {
                $report.Add([pscustomobject]@{Permission=$roleName;AppRoleId=$roleId;Result='AlreadyPresent'})
                continue
            }
            $body = @{ principalId=$principalId; resourceId=$graphId; appRoleId=$roleId }
            # Resource-side appRoleAssignedTo is Microsoft's recommended route.
            $created = Invoke-DemoGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$graphId/appRoleAssignedTo" -Token $secureToken -Body $body
            if ($created.principalId -ne $principalId -or $created.resourceId -ne $graphId -or $created.appRoleId -ne $roleId) { throw 'Graph grant response did not match the approved assignment; inspect current grants before continuing.' }
            $existing = @(Get-DemoExistingGrants -PrincipalId $principalId -Token $secureToken)
            $verified = @($existing | Where-Object { $_.principalId -eq $principalId -and $_.resourceId -eq $graphId -and $_.appRoleId -eq $roleId }).Count -gt 0
            if (-not $verified) { throw 'Grant returned success but readback is not yet visible. Do not replay; rerun preview after propagation.' }
            $report.Add([pscustomobject]@{Permission=$roleName;AppRoleId=$roleId;Result='GrantedAndVerified'})
        }
        [pscustomobject]@{
            Mode=$(if ($ActivateApprovedGrants) { 'ExplicitApprovedActivation' } else { 'ReadOnlyPreview' })
            TenantId=$script:GrantTenantId;SubscriptionId=$script:GrantSubscriptionId
            AutomationAccount=$script:GrantAccountName;ManagedIdentityPrincipalId=$principalId
            MicrosoftGraphServicePrincipalId=$graphId;Roles=@($report)
        } | ConvertTo-Json -Depth 5
    } finally {
        $rawToken = $null
        if ($null -ne $secureToken) { $secureToken.Dispose(); $secureToken=$null }
    }
}

if ($MyInvocation.InvocationName -ne '.') { Invoke-DemoRoleGrant -ActivateApprovedGrants:$ActivateApprovedGrants -ApprovedRoles $ApprovedRoles }
