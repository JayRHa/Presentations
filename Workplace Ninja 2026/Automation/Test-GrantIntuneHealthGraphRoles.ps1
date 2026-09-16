#requires -Version 7.4
# Fully offline. Replaces the Azure CLI and all Graph requests with fixtures.
$ErrorActionPreference='Stop'
. "$PSScriptRoot/Grant-IntuneHealthGraphRoles.ps1"
$script:GrantTests=[Collections.Generic.List[object]]::new()
$script:FixturePrincipal='11111111-1111-1111-1111-111111111111'
$script:FixtureGraph='22222222-2222-2222-2222-222222222222'
$script:FixtureTenant=$script:GrantTenantId
$script:FixtureAudience='https://graph.microsoft.com'
$script:FixtureExisting=@()
$script:FixturePosts=@()
$script:FixtureAzCalls=@()
$script:FixtureWrongIdentity=$false
$script:FixtureRoleDisabled=$false
function Assert-Grant($Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-GrantThrows([scriptblock]$Action,[string]$Match='') {
    $caught=$false
    try { & $Action | Out-Null } catch { $caught=$true; if ($Match) { Assert-Grant ($_.Exception.Message -match $Match) 'Unexpected failure text' } }
    Assert-Grant $caught 'Expected terminating refusal'
}
function Test-Grant([string]$Name,[scriptblock]$Action) {
    $script:FixtureTenant=$script:GrantTenantId;$script:FixtureAudience='https://graph.microsoft.com';$script:FixtureExisting=@();$script:FixturePosts=@();$script:FixtureAzCalls=@();$script:FixtureWrongIdentity=$false;$script:FixtureRoleDisabled=$false
    try { & $Action; $script:GrantTests.Add([pscustomobject]@{Test=$Name;Passed=$true});Write-Host "PASS $Name" }
    catch { $script:GrantTests.Add([pscustomobject]@{Test=$Name;Passed=$false;Error=$_.Exception.Message});Write-Host "FAIL $Name : $($_.Exception.Message)" }
}
function New-OperatorFixtureToken {
    $json=@{tid=$script:FixtureTenant;aud=$script:FixtureAudience;exp=[DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeSeconds()} | ConvertTo-Json -Compress
    'fixture.'+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json)).TrimEnd('=').Replace('+','-').Replace('/','_')+'.fixture'
}
function Invoke-DemoAzRead {
    param([string[]]$Arguments)
    $script:FixtureAzCalls += ,$Arguments
    Assert-Grant ($Arguments -contains '--subscription' -and $Arguments -contains $script:GrantSubscriptionId) 'Missing explicit subscription'
    Assert-Grant ($Arguments -notcontains 'set' -and $Arguments -notcontains 'rest' -and $Arguments -notcontains 'login') 'Forbidden CLI mutation/default Graph route'
    if ($Arguments[0] -eq 'account' -and $Arguments[1] -eq 'show') { return @{id=$script:GrantSubscriptionId;tenantId=$script:FixtureTenant} }
    if ($Arguments[0] -eq 'resource') { return @{id=$script:GrantResourceId;name=$script:GrantAccountName;type='Microsoft.Automation/automationAccounts';identity=@{type='SystemAssigned';tenantId=$script:GrantTenantId;principalId=$script:FixturePrincipal}} }
    if ($Arguments[1] -eq 'get-access-token') {
        Assert-Grant ($Arguments -contains '--resource' -and $Arguments -contains 'https://graph.microsoft.com/') 'Wrong token resource'
        return @{tenant=$script:FixtureTenant;accessToken=(New-OperatorFixtureToken)}
    }
    throw 'Unexpected CLI fixture route'
}
function Invoke-DemoGraphRequest {
    param($Method,[uri]$Uri,$Token,$Body)
    if ($Method -eq 'POST') {
        Assert-Grant ($Uri.AbsolutePath -eq "/v1.0/servicePrincipals/$script:FixtureGraph/appRoleAssignedTo") 'Wrong write target'
        Assert-Grant ($Body.principalId -eq $script:FixturePrincipal -and $Body.resourceId -eq $script:FixtureGraph) 'Wrong assignment identity/resource'
        Assert-Grant ($Body.appRoleId -in @($script:AllowedGrantRoles.Values)) 'Unapproved broad role attempted'
        $script:FixturePosts += $Body
        $assignment=[pscustomobject]@{id='fixtureAssignment';principalId=$Body.principalId;resourceId=$Body.resourceId;appRoleId=$Body.appRoleId}
        $script:FixtureExisting += $assignment
        return $assignment
    }
    if ($Uri.AbsolutePath -match '/appRoleAssignments$') { return [pscustomobject]@{value=@($script:FixtureExisting)} }
    if ($Uri.AbsolutePath -eq "/v1.0/servicePrincipals/$script:FixturePrincipal") {
        return [pscustomobject]@{id=$script:FixturePrincipal;displayName=$script:GrantAccountName;servicePrincipalType=$(if($script:FixtureWrongIdentity){'Application'}else{'ManagedIdentity'})}
    }
    if ($Uri.AbsolutePath -like '*servicePrincipals(appId=*') {
        $roles=@();foreach($role in $script:AllowedGrantRoles.Keys){$roles += [pscustomobject]@{id=$script:AllowedGrantRoles[$role];value=$role;isEnabled=(-not $script:FixtureRoleDisabled);allowedMemberTypes=@('Application')}}
        return [pscustomobject]@{id=$script:FixtureGraph;appId=$script:GraphResourceAppId;appRoles=$roles}
    }
    throw 'Unexpected Graph fixture route'
}
Test-Grant 'Default preview performs zero writes' {
    $result=Invoke-DemoRoleGrant | ConvertFrom-Json
    Assert-Grant ($result.Mode -eq 'ReadOnlyPreview' -and $script:FixturePosts.Count -eq 0 -and $result.Roles.Count -eq 2) 'Default mode mutated grants'
}
Test-Grant 'Activation without selected approved roles refuses before access' {
    Assert-GrantThrows { Invoke-DemoRoleGrant -ActivateApprovedGrants } 'explicitly listing'
    Assert-Grant ($script:FixtureAzCalls.Count -eq 0 -and $script:FixturePosts.Count -eq 0) 'Activation gate late'
}
Test-Grant 'Unlisted Graph roles are rejected by parameter binding' {
    Assert-GrantThrows { Invoke-DemoRoleGrant -ActivateApprovedGrants -ApprovedRoles 'Directory.ReadWrite.All' }
    Assert-Grant ($script:FixturePosts.Count -eq 0) 'Broad role granted'
}
Test-Grant 'One approved role grants only that role and verifies it' {
    $result=Invoke-DemoRoleGrant -ActivateApprovedGrants -ApprovedRoles DeviceManagementManagedDevices.Read.All | ConvertFrom-Json
    Assert-Grant ($script:FixturePosts.Count -eq 1 -and $script:FixturePosts[0].appRoleId -eq $script:AllowedGrantRoles['DeviceManagementManagedDevices.Read.All'] -and $result.Roles[0].Result -eq 'GrantedAndVerified') 'Exact grant/readback failed'
}
Test-Grant 'Both approved roles grant exactly twice' {
    $result=Invoke-DemoRoleGrant -ActivateApprovedGrants -ApprovedRoles @($script:AllowedGrantRoles.Keys) | ConvertFrom-Json
    Assert-Grant ($script:FixturePosts.Count -eq 2 -and @($result.Roles | Where-Object Result -eq 'GrantedAndVerified').Count -eq 2) 'Expected two narrow grants'
}
Test-Grant 'Existing approved grants are not duplicated' {
    foreach($roleId in $script:AllowedGrantRoles.Values){$script:FixtureExisting += [pscustomobject]@{id='existing';principalId=$script:FixturePrincipal;resourceId=$script:FixtureGraph;appRoleId=$roleId}}
    $result=Invoke-DemoRoleGrant -ActivateApprovedGrants -ApprovedRoles @($script:AllowedGrantRoles.Keys) | ConvertFrom-Json
    Assert-Grant ($script:FixturePosts.Count -eq 0 -and @($result.Roles | Where-Object Result -eq 'AlreadyPresent').Count -eq 2) 'Existing grants duplicated'
}
Test-Grant 'Wrong subscription tenant blocks Graph operations' {
    $script:FixtureTenant='wrong-tenant'
    Assert-GrantThrows { Invoke-DemoRoleGrant -ActivateApprovedGrants -ApprovedRoles DeviceManagementManagedDevices.Read.All } 'approved subscription and tenant'
    Assert-Grant ($script:FixturePosts.Count -eq 0 -and $script:FixtureAzCalls.Count -eq 1) 'Tenant binding failed'
}
Test-Grant 'Wrong Graph token audience blocks activation' {
    $script:FixtureAudience='https://management.azure.com'
    Assert-GrantThrows { Invoke-DemoRoleGrant -ActivateApprovedGrants -ApprovedRoles DeviceManagementManagedDevices.Read.All } 'Refused Graph token'
    Assert-Grant ($script:FixturePosts.Count -eq 0) 'Wrong token audience accepted'
}
Test-Grant 'Graph identity must actually be the managed identity' {
    $script:FixtureWrongIdentity=$true
    Assert-GrantThrows { Invoke-DemoRoleGrant -ActivateApprovedGrants -ApprovedRoles DeviceManagementManagedDevices.Read.All } 'identity does not match'
    Assert-Grant ($script:FixturePosts.Count -eq 0) 'Application impersonated MI'
}
Test-Grant 'Disabled Graph role definition cannot be granted' {
    $script:FixtureRoleDisabled=$true
    Assert-GrantThrows { Invoke-DemoRoleGrant -ActivateApprovedGrants -ApprovedRoles DeviceManagementManagedDevices.Read.All } 'role definition mismatch'
    Assert-Grant ($script:FixturePosts.Count -eq 0) 'Disabled role granted'
}
$failed=@($script:GrantTests | Where-Object { -not $_.Passed })
$report=[pscustomobject]@{Runtime=$PSVersionTable.PSVersion.ToString();Mode='Offline fixtures; no Azure CLI or Graph calls';Total=$script:GrantTests.Count;Passed=$script:GrantTests.Count-$failed.Count;Failed=$failed.Count;Results=@($script:GrantTests)}
$report | ConvertTo-Json -Depth 6 | Set-Content -Path "$PSScriptRoot/grant-helper-test-results.json" -Encoding utf8
Write-Host "$($report.Passed)/$($report.Total) grant-helper fixture tests passed."
if($failed.Count){exit 1}
