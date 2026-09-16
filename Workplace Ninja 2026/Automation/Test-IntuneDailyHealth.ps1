#requires -Version 7.4
# Offline fixtures only. All HTTP, auth, secret reads and sleep are replaced below.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/Invoke-IntuneDailyHealth.ps1"
$script:Now = [DateTimeOffset]'2026-09-10T06:00:00Z'
$script:Results = [Collections.Generic.List[object]]::new()
$script:Responses = @()
$script:Calls = 0
$script:Methods = @()
$script:Bodies = @()
$script:SleepCalls = @()
$script:AuthFails = $false
$script:ConfigFails = $false

function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Throws([scriptblock]$Action, [string]$Match = '') {
    $thrown = $false
    try { & $Action | Out-Null } catch { $thrown = $true; if ($Match) { Assert-True ($_.Exception.Message -match $Match) 'Unexpected error text' } }
    Assert-True $thrown 'Expected a terminating error'
}
function Test-Case([string]$Name, [scriptblock]$Action) {
    $script:Responses = @(); $script:Calls = 0; $script:Methods = @(); $script:Bodies = @(); $script:SleepCalls = @(); $script:AuthFails=$false; $script:ConfigFails=$false
    try { & $Action; $script:Results.Add([pscustomobject]@{Test=$Name;Passed=$true}); Write-Host "PASS $Name" }
    catch { $script:Results.Add([pscustomobject]@{Test=$Name;Passed=$false;Error=$_.Exception.Message}); Write-Host "FAIL $Name : $($_.Exception.Message)" }
}
function New-FixtureDevice([string]$Id='a', [string]$State='compliant', $Sync='2026-09-09T06:00:00Z') {
    [pscustomobject]@{ id=$Id; complianceState=$State; lastSyncDateTime=$Sync }
}
function New-FixtureToken([string]$Tenant=$script:ExpectedTenantId, [string]$Audience='https://graph.microsoft.com', [long]$Expiry=([DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeSeconds()), [string[]]$Roles=@('DeviceManagementManagedDevices.Read.All')) {
    $payload = @{tid=$Tenant;aud=$Audience;exp=$Expiry;roles=$Roles} | ConvertTo-Json -Compress
    'fixture.' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload)).TrimEnd('=').Replace('+','-').Replace('/','_') + '.fixture'
}
function Add-Reply($Body, [int]$Status=200, [hashtable]$Headers=@{}, [bool]$TransportFailure=$false) {
    $script:Responses += @{Body=$Body;Status=$Status;Headers=$Headers;TransportFailure=$TransportFailure}
}
function Invoke-RestMethod {
    param($Method,$Uri,$Headers,$TimeoutSec,$MaximumRedirection,$ErrorAction,$SkipHttpErrorCheck,$StatusCodeVariable,$ResponseHeadersVariable,$ContentType,$Body)
    if ($script:Calls -ge $script:Responses.Count) { throw 'Fixture response queue exhausted: network is disabled.' }
    $entry = $script:Responses[$script:Calls++]
    $script:Methods += [string]$Method
    $script:Bodies += [string]$Body
    Set-Variable -Name $StatusCodeVariable -Value $entry.Status -Scope 1
    Set-Variable -Name $ResponseHeadersVariable -Value $entry.Headers -Scope 1
    if ($entry.TransportFailure) { throw 'PRIVATE_TEST_MARKER should never appear in run output' }
    return $entry.Body
}
function Start-Sleep { param($Seconds); $script:SleepCalls += $Seconds }
function Get-ManagedIdentityGraphToken { if ($script:AuthFails) { throw 'PRIVATE_TEST_MARKER token unavailable' }; New-FixtureToken }
function Get-AutomationVariable { param($Name,$ErrorAction); if ($script:ConfigFails) { throw 'PRIVATE_TEST_MARKER secret read failed' }; 'https://example.logic.azure.com/workflows/fixture/triggers/manual/paths/invoke?sig=PRIVATE_TEST_MARKER' }

Test-Case 'Healthy inventory has no issues' {
    $result = Get-IntuneHealthSummary -Devices @(New-FixtureDevice) -Now $script:Now
    Assert-True (-not $result.HasIssues -and $result.Counts.Compliant -eq 1) 'Healthy device incorrectly flagged'
}
Test-Case 'Noncompliant device flags attention' {
    $result = Get-IntuneHealthSummary -Devices @(New-FixtureDevice -State noncompliant) -Now $script:Now
    Assert-True ($result.HasIssues -and $result.Counts.Noncompliant -eq 1 -and $result.Counts.AffectedDevices -eq 1) 'Noncompliance lost'
}
Test-Case 'Overlapping stale and noncompliant count one affected device' {
    $result = Get-IntuneHealthSummary -Devices @(New-FixtureDevice -State noncompliant -Sync '2026-08-01T00:00:00Z') -Now $script:Now
    Assert-True ($result.Counts.StaleSync -eq 1 -and $result.Counts.Noncompliant -eq 1 -and $result.Counts.AffectedDevices -eq 1) 'Affected count double counted'
}
Test-Case 'Exactly 14 days is not older than 14 days' {
    $result = Get-IntuneHealthSummary -Devices @(New-FixtureDevice -Sync '2026-08-27T06:00:00Z') -Now $script:Now
    Assert-True (-not $result.HasIssues) 'Threshold boundary incorrect'
}
Test-Case 'One second older than threshold is stale' {
    $result = Get-IntuneHealthSummary -Devices @(New-FixtureDevice -Sync '2026-08-27T05:59:59Z') -Now $script:Now
    Assert-True ($result.Counts.StaleSync -eq 1) 'Threshold off by one'
}
Test-Case 'Null empty malformed sentinel and future sync dates are unknown' {
    $devices = @(); $index=0
    foreach ($date in @($null,'','bad-date','0001-01-01T00:00:00Z','2026-09-11T00:00:00Z')) { $devices += New-FixtureDevice -Id ([string]$index++) -Sync $date }
    $result = Get-IntuneHealthSummary -Devices $devices -Now $script:Now
    Assert-True ($result.Counts.UnknownSync -eq 5 -and $result.Counts.AffectedDevices -eq 5) 'Invalid dates treated as healthy'
}
Test-Case 'Missing fields are visible coverage issues' {
    $result = Get-IntuneHealthSummary -Devices @([pscustomobject]@{id='a'}) -Now $script:Now
    Assert-True ($result.Counts.UnknownSync -eq 1 -and $result.Counts.UnknownCompliance -eq 1 -and $result.Counts.AffectedDevices -eq 1) 'Missing fields lost'
}
Test-Case 'Conflict error grace and unknown states are classified' {
    $states = @('conflict','error','inGracePeriod','unknown','futureNewState')
    $devices = @(); for ($i=0; $i -lt $states.Count; $i++) { $devices += New-FixtureDevice -Id ([string]$i) -State $states[$i] }
    $result = Get-IntuneHealthSummary -Devices $devices -Now $script:Now
    Assert-True ($result.Counts.ComplianceErrors -eq 2 -and $result.Counts.InGracePeriod -eq 1 -and $result.Counts.UnknownCompliance -eq 2) 'State grouping incorrect'
}
Test-Case 'ConfigManager state is informational' {
    $result = Get-IntuneHealthSummary -Devices @(New-FixtureDevice -State configManager) -Now $script:Now
    Assert-True (-not $result.HasIssues -and $result.Counts.ConfigManager -eq 1) 'ConfigMgr wrongly marked as Intune failure'
}
Test-Case 'Duplicate IDs do not inflate totals' {
    $result = Get-IntuneHealthSummary -Devices @((New-FixtureDevice),(New-FixtureDevice)) -Now $script:Now
    Assert-True ($result.Counts.TotalDevices -eq 1) 'Duplicate IDs inflated total'
}
Test-Case 'Empty inventory is visible rather than healthy' {
    $result = Get-IntuneHealthSummary -Devices @() -Now $script:Now
    Assert-True ($result.EmptyInventory -and $result.HasIssues) 'Empty inventory marked healthy'
}
Test-Case 'Wrong tenant token is rejected' { Assert-Throws { Assert-GraphToken -Token (New-FixtureToken -Tenant 'other-tenant') } }
Test-Case 'Wrong audience token is rejected' { Assert-Throws { Assert-GraphToken -Token (New-FixtureToken -Audience 'https://management.azure.com') } }
Test-Case 'Expired token is rejected' { Assert-Throws { Assert-GraphToken -Token (New-FixtureToken -Expiry 100) } }
Test-Case 'Missing Graph read role is rejected' { Assert-Throws { Assert-GraphToken -Token (New-FixtureToken -Roles @('User.Read.All')) } }
Test-Case 'Graph application audience ID is supported' { Assert-GraphToken -Token (New-FixtureToken -Audience '00000003-0000-0000-c000-000000000000') }
Test-Case 'Multiple Graph pages are collected and deduplicated' {
    Add-Reply ([pscustomobject]@{value=@(New-FixtureDevice); '@odata.nextLink'='https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?$skiptoken=page2'})
    Add-Reply ([pscustomobject]@{value=@((New-FixtureDevice),(New-FixtureDevice -Id b))})
    $devices = @(Get-GraphManagedDevices -Token (New-FixtureToken))
    Assert-True ($devices.Count -eq 2 -and $script:Calls -eq 2) 'Paging or deduplication failed'
}
Test-Case 'Empty Graph value array is a valid empty collection' {
    Add-Reply ([pscustomobject]@{value=@()})
    $devices = @(Get-GraphManagedDevices -Token (New-FixtureToken))
    Assert-True ($devices.Count -eq 0) 'Empty page unexpectedly fails'
}
Test-Case 'Cross-host nextLink is rejected before token forwarding' {
    Add-Reply ([pscustomobject]@{value=@();'@odata.nextLink'='https://example.org/steal'})
    Assert-Throws { Get-GraphManagedDevices -Token (New-FixtureToken) } 'pagination target'
    Assert-True ($script:Calls -eq 1) 'Token forwarded to other host'
}
Test-Case 'Repeated nextLink is rejected' {
    $next='https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?$skiptoken=loop'
    Add-Reply ([pscustomobject]@{value=@();'@odata.nextLink'=$next})
    Add-Reply ([pscustomobject]@{value=@();'@odata.nextLink'=$next})
    Assert-Throws { Get-GraphManagedDevices -Token (New-FixtureToken) } 'did not terminate'
}
Test-Case 'Malformed Graph page is not empty healthy data' {
    Add-Reply ([pscustomobject]@{unexpected=@()})
    Assert-Throws { Get-GraphManagedDevices -Token (New-FixtureToken) } 'invalid device page'
}
Test-Case '429 honors Retry-After and retries' {
    Add-Reply $null -Status 429 -Headers @{'Retry-After'='7'}
    Add-Reply ([pscustomobject]@{value=@(New-FixtureDevice)})
    $devices = @(Get-GraphManagedDevices -Token (New-FixtureToken))
    Assert-True ($devices.Count -eq 1 -and $script:Calls -eq 2 -and $script:SleepCalls[0] -eq 7) 'Retry-After ignored'
}
Test-Case 'Graph 503 retries then succeeds' {
    Add-Reply $null -Status 503; Add-Reply ([pscustomobject]@{value=@()})
    Get-GraphManagedDevices -Token (New-FixtureToken) | Out-Null
    Assert-True ($script:Calls -eq 2) 'Transient Graph failure not retried'
}
Test-Case '403 fails without retry' {
    Add-Reply $null -Status 403
    Assert-Throws { Get-GraphManagedDevices -Token (New-FixtureToken) } 'HTTP 403'
    Assert-True ($script:Calls -eq 1) 'Permanent failure retried'
}
Test-Case 'Long Retry-After does not cause premature replay' {
    Add-Reply $null -Status 429 -Headers @{'Retry-After'='900'}
    Assert-Throws { Get-GraphManagedDevices -Token (New-FixtureToken) } 'extended retry delay'
    Assert-True ($script:Calls -eq 1) 'Request replayed before server delay'
}
Test-Case 'Teams card contains counts only and valid attachment shape' {
    $summary = Get-IntuneHealthSummary -Devices @(New-FixtureDevice -Id 'PRIVATE_DEVICE_ID' -State noncompliant) -Now $script:Now
    $payload = New-TeamsHealthPayload -Summary $summary
    $json = $payload | ConvertTo-Json -Depth 16
    Assert-True ($payload.type -eq 'message' -and $payload.attachments[0].contentType -eq 'application/vnd.microsoft.card.adaptive') 'Invalid Workflow payload'
    Assert-True ($json -notmatch 'PRIVATE_DEVICE_ID|userPrincipalName|serialNumber|Bearer') 'Sensitive device details leaked'
}
Test-Case 'APNs expiry is detected' {
    Add-Reply ([pscustomobject]@{expirationDateTime='2026-09-01T00:00:00Z';certificateUploadStatus='success'})
    $health = Get-ApplePushHealth -Token (New-FixtureToken) -Now $script:Now
    Assert-True ($health.Status -eq 'Expired' -and $health.HasIssue) 'Expired certificate missed'
}
Test-Case 'APNs near expiry is detected' {
    Add-Reply ([pscustomobject]@{expirationDateTime='2026-09-25T00:00:00Z';certificateUploadStatus='success'})
    $health = Get-ApplePushHealth -Token (New-FixtureToken) -Now $script:Now
    Assert-True ($health.Status -eq 'ExpiringSoon') 'Renewal warning missed'
}
Test-Case 'APNs permission error is an explicit coverage gap' {
    Add-Reply $null -Status 403
    $health = Get-ApplePushHealth -Token (New-FixtureToken) -Now $script:Now
    Assert-True ($health.Status -eq 'Unavailable' -and $health.HasIssue -and -not $health.CoverageComplete) 'APNs unavailable looked healthy'
}
Test-Case 'Healthy run sends no Teams noise' {
    Add-Reply ([pscustomobject]@{value=@(New-FixtureDevice -Sync ([DateTimeOffset]::UtcNow.ToString('o')))})
    $result = Invoke-IntuneHealthRun -IncludeApplePushCheck $false | ConvertFrom-Json
    Assert-True ($result.Notification -eq 'NotNeeded' -and $script:Calls -eq 1 -and $result.Status -eq 'Completed') 'Healthy run sent a message'
}
Test-Case 'Issue run posts one card and reports HTTP acceptance' {
    Add-Reply ([pscustomobject]@{value=@(New-FixtureDevice -State noncompliant)})
    Add-Reply $null -Status 202
    $result = Invoke-IntuneHealthRun -IncludeApplePushCheck $false | ConvertFrom-Json
    Assert-True ($result.Notification -eq 'AcceptedByWorkflow' -and $script:Methods[-1] -eq 'POST') 'Issue was not delivered to Workflow'
}
Test-Case 'APNs unavailable sends coverage alert rather than claiming healthy' {
    Add-Reply ([pscustomobject]@{value=@(New-FixtureDevice -Sync ([DateTimeOffset]::UtcNow.ToString('o')))})
    Add-Reply $null -Status 403
    Add-Reply $null -Status 202
    $result = Invoke-IntuneHealthRun | ConvertFrom-Json
    Assert-True ($result.Status -eq 'CompletedWithCoverageGap' -and $result.ApplePush.Status -eq 'Unavailable' -and $result.Notification -eq 'AcceptedByWorkflow') 'Incomplete coverage hidden'
}
Test-Case 'Graph failure sends a run-failure card and job still fails' {
    Add-Reply $null -Status 403; Add-Reply $null -Status 202
    Assert-Throws { Invoke-IntuneHealthRun -IncludeApplePushCheck $false } "stage 'graph'"
    Assert-True ($script:Methods[-1] -eq 'POST' -and $script:Bodies[-1] -match 'could not complete') 'Failure alert missing'
}
Test-Case 'Auth failure sends a run-failure card with no sensitive error' {
    $script:AuthFails=$true; Add-Reply $null -Status 202
    Assert-Throws { Invoke-IntuneHealthRun } "stage 'authentication'"
    Assert-True ($script:Bodies[-1] -notmatch 'PRIVATE_TEST_MARKER') 'Error details leaked'
}
Test-Case 'Missing webhook is a failed job even if health would be good' {
    $script:ConfigFails=$true
    Assert-Throws { Invoke-IntuneHealthRun } "stage 'configuration'"
    Assert-True ($script:Calls -eq 0) 'Continued with missing configuration'
}
Test-Case 'Webhook HTTP failure cannot report successful notification' {
    Add-Reply ([pscustomobject]@{value=@(New-FixtureDevice -State noncompliant)}); Add-Reply $null -Status 500
    Assert-Throws { Invoke-IntuneHealthRun -IncludeApplePushCheck $false } "stage 'notification'"
    Assert-True ($script:Calls -eq 2) 'Ambiguous post was duplicated'
}
Test-Case 'Webhook transport failure is not replayed or logged with secret' {
    Add-Reply ([pscustomobject]@{value=@(New-FixtureDevice -State noncompliant)}); Add-Reply $null -TransportFailure $true
    $message=''
    try { Invoke-IntuneHealthRun -IncludeApplePushCheck $false | Out-Null } catch { $message=$_.Exception.Message }
    Assert-True ($message -match "stage 'notification'" -and $message -notmatch 'PRIVATE_TEST_MARKER' -and $script:Calls -eq 2) 'Transport failure handling incorrect'
}
Test-Case 'Failed fallback webhook remains a failed job' {
    Add-Reply $null -Status 403; Add-Reply $null -Status 500
    Assert-Throws { Invoke-IntuneHealthRun -IncludeApplePushCheck $false } 'Failure alert: Failed'
}

$failed = @($script:Results | Where-Object { -not $_.Passed })
$report = [pscustomobject]@{ Runtime=$PSVersionTable.PSVersion.ToString(); Mode='Offline fixtures; no cloud calls'; Total=$script:Results.Count; Passed=$script:Results.Count-$failed.Count; Failed=$failed.Count; Results=@($script:Results) }
$report | ConvertTo-Json -Depth 6 | Set-Content -Path "$PSScriptRoot/test-results.json" -Encoding utf8
Write-Host "$($report.Passed)/$($report.Total) fixture tests passed."
if ($failed.Count) { exit 1 }
