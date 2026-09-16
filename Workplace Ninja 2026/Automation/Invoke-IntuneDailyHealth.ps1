#requires -Version 7.4
<#
.SYNOPSIS
Daily read-only Intune device health check for your Intune tenant.
.DESCRIPTION
Azure Automation PowerShell 7.4, system-assigned Managed Identity, Az.Accounts.
Graph APPLICATION permission: DeviceManagementManagedDevices.Read.All.
Encrypted Automation variable: TeamsHealthWebhook (Teams Workflows URL).
Healthy runs stay quiet. Issues generate a counts-only Adaptive Card.
Run/notification failures terminate the job with a sanitized error.
Optional APNs check: DeviceManagementServiceConfig.Read.All application role.
This checks device compliance, last sync and APNs expiry, not every Intune workload.
#>
[CmdletBinding()]
param(
    [ValidateRange(1,365)][int]$StaleAfterDays = 14,
    [bool]$IncludeApplePushCheck = $true,
    [ValidateRange(1,90)][int]$CertificateWarningDays = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
# SETUP: replace the zero GUID with your Entra tenant ID before publishing.
$script:ExpectedTenantId = '00000000-0000-0000-0000-000000000000'
$script:RequiredGraphRole = 'DeviceManagementManagedDevices.Read.All'
# SETUP: replace both zero GUIDs (tenant/subscription) and resource names in this portal link.
$script:AutomationUrl = 'https://portal.azure.com/#@00000000-0000-0000-0000-000000000000/resource/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-intune-keynote-demo/providers/Microsoft.Automation/automationAccounts/aa-intune-health-demo/overview'

function Assert-GraphToken {
    param([Parameter(Mandatory)][string]$Token)
    # Token was acquired from Entra by Az.Accounts. These checks bind its use to
    # this demo tenant/API; they are not a replacement for JWT signature validation.
    try {
        $segments = $Token.Split('.')
        if ($segments.Count -ne 3) { throw 'Invalid token' }
        $payload = $segments[1].Replace('-', '+').Replace('_', '/')
        $payload = $payload.PadRight($payload.Length + ((4 - $payload.Length % 4) % 4), '=')
        $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json -AsHashtable
        if ($claims['tid'] -ne $script:ExpectedTenantId) { throw 'Tenant mismatch' }
        if ($claims['aud'] -notin @('https://graph.microsoft.com', 'https://graph.microsoft.com/', '00000003-0000-0000-c000-000000000000')) { throw 'Audience mismatch' }
        if ([long]$claims['exp'] -le [DateTimeOffset]::UtcNow.AddMinutes(2).ToUnixTimeSeconds()) { throw 'Token expired' }
        if ($script:RequiredGraphRole -notin @($claims['roles'])) { throw 'Read role missing' }
    } catch { throw 'Graph authentication validation failed: expected tenant, audience, expiry or read permission is missing.' }
}

function Get-ManagedIdentityGraphToken {
    Import-Module Az.Accounts -ErrorAction Stop
    Disable-AzContextAutosave -Scope Process | Out-Null
    $context = (Connect-AzAccount -Identity -SkipContextPopulation -ErrorAction Stop).Context
    if ([string]$context.Tenant.Id -ne $script:ExpectedTenantId) { throw 'Managed identity tenant does not match the demo tenant.' }
    $result = Get-AzAccessToken -ResourceUrl 'https://graph.microsoft.com/' -TenantId $script:ExpectedTenantId -DefaultProfile $context -ErrorAction Stop
    $plainToken = if ($result.Token -is [Security.SecureString]) {
        [Net.NetworkCredential]::new('', $result.Token).Password
    } else { [string]$result.Token }
    Assert-GraphToken -Token $plainToken
    return $plainToken
}

function Get-RetryDelay {
    param([AllowNull()]$Headers, [int]$Attempt)
    $seconds = [int][Math]::Min(60, [Math]::Pow(2, $Attempt + 1))
    if ($null -ne $Headers -and $Headers.ContainsKey('Retry-After')) {
        $value = [string]@($Headers['Retry-After'])[0]
        $numeric = 0
        $date = [DateTimeOffset]::MinValue
        if ([int]::TryParse($value, [ref]$numeric)) { $seconds = [Math]::Max(0, $numeric) }
        elseif ([DateTimeOffset]::TryParse($value, [ref]$date)) { $seconds = [int][Math]::Max(0, [Math]::Ceiling(($date - [DateTimeOffset]::UtcNow).TotalSeconds)) }
    }
    # Never retry before a long server-requested delay; fail this daily job instead.
    if ($seconds -gt 120) { throw 'Remote service requested an extended retry delay; retry the job later.' }
    return $seconds
}

function Invoke-HealthHttp {
    param(
        [Parameter(Mandatory)][ValidateSet('GET','POST')][string]$Method,
        [Parameter(Mandatory)][uri]$Uri,
        [hashtable]$Headers = @{},
        [AllowNull()][string]$Body,
        [ValidateRange(0,5)][int]$MaxRetries = 4
    )
    for ($attempt = 0; $attempt -le $MaxRetries; $attempt++) {
        $statusCode = 0
        $responseHeaders = @{}
        $request = @{
            Method = $Method; Uri = $Uri; Headers = $Headers
            TimeoutSec = 60; MaximumRedirection = 0; ErrorAction = 'Stop'
            SkipHttpErrorCheck = $true; StatusCodeVariable = 'statusCode'
            ResponseHeadersVariable = 'responseHeaders'
        }
        if ($Method -eq 'POST') { $request['ContentType'] = 'application/json; charset=utf-8'; $request['Body'] = $Body }
        try { $response = Invoke-RestMethod @request }
        catch {
            # A POST may already have been delivered before a transport timeout.
            # Do not automatically replay it and create duplicate channel cards.
            if ($Method -eq 'GET' -and $attempt -lt $MaxRetries) {
                Start-Sleep -Seconds (Get-RetryDelay -Headers $null -Attempt $attempt)
                continue
            }
            throw 'Remote request failed or timed out; transport details suppressed to protect credentials.'
        }
        if ($statusCode -ge 200 -and $statusCode -lt 300) { return $response }
        $retryable = $statusCode -eq 429 -or ($Method -eq 'GET' -and $statusCode -in @(500,502,503,504))
        if ($retryable -and $attempt -lt $MaxRetries) {
            Start-Sleep -Seconds (Get-RetryDelay -Headers $responseHeaders -Attempt $attempt)
            continue
        }
        throw "Remote request failed (HTTP $statusCode); response and URL suppressed."
    }
}

function Get-GraphManagedDevices {
    param([Parameter(Mandatory)][string]$Token)
    Assert-GraphToken -Token $Token
    # Do not retrieve device names, UPNs, serial numbers or other user details.
    $next = 'https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?$select=id,complianceState,lastSyncDateTime&$top=100'
    $devices = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
    $visited = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    while (-not [string]::IsNullOrWhiteSpace($next)) {
        $uri = [uri]$next
        # Apply the same check to every nextLink before sending the bearer token.
        if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'graph.microsoft.com' -or $uri.Port -ne 443 -or $uri.UserInfo -or $uri.Fragment -or $uri.AbsolutePath -ne '/v1.0/deviceManagement/managedDevices') {
            throw 'Unexpected Microsoft Graph pagination target.'
        }
        if (-not $visited.Add($next) -or $visited.Count -gt 10000) { throw 'Microsoft Graph pagination did not terminate.' }
        $page = Invoke-HealthHttp -Method GET -Uri $uri -Headers @{ Authorization = "Bearer $Token"; Accept = 'application/json' }
        if ($null -eq $page -or $null -eq $page.PSObject.Properties['value'] -or $null -eq $page.value) { throw 'Microsoft Graph returned an invalid device page.' }
        foreach ($device in @($page.value)) {
            if ($null -eq $device -or $null -eq $device.PSObject.Properties['id'] -or [string]::IsNullOrWhiteSpace([string]$device.id)) { throw 'Microsoft Graph returned a device without an ID.' }
            $devices[[string]$device.id] = $device
        }
        $nextProperty = $page.PSObject.Properties['@odata.nextLink']
        $next = if ($null -ne $nextProperty) { [string]$nextProperty.Value } else { $null }
    }
    return @($devices.Values)
}

function Get-IntuneHealthSummary {
    param([AllowEmptyCollection()][Parameter(Mandatory)][object[]]$Devices,
          [ValidateRange(1,365)][int]$StaleAfterDays = 14,
          [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow)
    $counts = [ordered]@{
        TotalDevices = 0; AffectedDevices = 0; Compliant = 0; Noncompliant = 0
        ComplianceErrors = 0; InGracePeriod = 0; UnknownCompliance = 0
        ConfigManager = 0; StaleSync = 0; UnknownSync = 0
    }
    $unique = @{}
    foreach ($device in $Devices) {
        if ($null -eq $device -or $null -eq $device.PSObject.Properties['id'] -or [string]::IsNullOrWhiteSpace([string]$device.id)) { throw 'Invalid device fixture or Graph response.' }
        $unique[[string]$device.id] = $device
    }
    foreach ($device in $unique.Values) {
        $counts.TotalDevices++
        $affected = $false
        $state = if ($null -ne $device.PSObject.Properties['complianceState']) { [string]$device.complianceState } else { '' }
        switch ($state.ToLowerInvariant()) {
            'compliant' { $counts.Compliant++ }
            'noncompliant' { $counts.Noncompliant++; $affected = $true }
            { $_ -in @('error','conflict') } { $counts.ComplianceErrors++; $affected = $true }
            'ingraceperiod' { $counts.InGracePeriod++; $affected = $true }
            'configmanager' { $counts.ConfigManager++ } # Managed by ConfigMgr; not an Intune compliance failure.
            default { $counts.UnknownCompliance++; $affected = $true }
        }
        $sync = [DateTimeOffset]::MinValue
        $rawSync = if ($null -ne $device.PSObject.Properties['lastSyncDateTime']) { [string]$device.lastSyncDateTime } else { '' }
        if (-not [DateTimeOffset]::TryParse($rawSync, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$sync) -or $sync.Year -lt 2000 -or $sync -gt $Now.AddMinutes(5)) {
            $counts.UnknownSync++; $affected = $true
        } elseif ($sync -lt $Now.AddDays(-$StaleAfterDays)) { $counts.StaleSync++; $affected = $true }
        if ($affected) { $counts.AffectedDevices++ }
    }
    return [pscustomobject]@{
        CheckedAtUtc = $Now.ToUniversalTime().ToString('yyyy-MM-dd HH:mm') + ' UTC'
        StaleAfterDays = $StaleAfterDays; Counts = [pscustomobject]$counts
        EmptyInventory = $counts.TotalDevices -eq 0
        HasIssues = ($counts.AffectedDevices -gt 0 -or $counts.TotalDevices -eq 0)
        ApplePush = [pscustomobject]@{ Status='NotEnabled'; HasIssue=$false; CoverageComplete=$false; Detail='APNs expiry not checked' }
    }
}

function Get-ApplePushHealth {
    param([Parameter(Mandatory)][string]$Token,
          [ValidateRange(1,90)][int]$WarningDays = 30,
          [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow)
    try {
        Assert-GraphToken -Token $Token
        $certificate = Invoke-HealthHttp -Method GET -Uri 'https://graph.microsoft.com/v1.0/deviceManagement/applePushNotificationCertificate?$select=id,expirationDateTime,certificateUploadStatus' -Headers @{ Authorization="Bearer $Token"; Accept='application/json' }
        # Some Graph singleton examples wrap the object in a value property.
        if ($null -ne $certificate -and $null -ne $certificate.PSObject.Properties['value']) { $certificate = $certificate.value }
        if ($null -eq $certificate -or $null -eq $certificate.PSObject.Properties['expirationDateTime']) { throw 'Certificate response incomplete' }
        $expiry = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse([string]$certificate.expirationDateTime, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$expiry) -or $expiry.Year -lt 2000) {
            return [pscustomobject]@{ Status='NotConfiguredOrUnknown'; HasIssue=$true; CoverageComplete=$false; Detail='No valid APNs expiration date returned; verify Apple enrollment' }
        }
        $uploadStatus = if ($null -ne $certificate.PSObject.Properties['certificateUploadStatus']) { [string]$certificate.certificateUploadStatus } else { '' }
        $status = 'Valid'
        $hasIssue = $false
        if ($expiry -le $Now) { $status='Expired'; $hasIssue=$true }
        elseif ($expiry -le $Now.AddDays($WarningDays)) { $status='ExpiringSoon'; $hasIssue=$true }
        if ($uploadStatus -match '(?i)fail|error') { $status='UploadError'; $hasIssue=$true }
        return [pscustomobject]@{ Status=$status; HasIssue=$hasIssue; CoverageComplete=$true; Detail="APNs: $status; expires $($expiry.ToUniversalTime().ToString('yyyy-MM-dd'))" }
    } catch {
        # Permission/service failure is visible coverage loss, never a healthy result.
        return [pscustomobject]@{ Status='Unavailable'; HasIssue=$true; CoverageComplete=$false; Detail='APNs unavailable; check DeviceManagementServiceConfig.Read.All and service access' }
    }
}

function New-TeamsHealthPayload {
    param([AllowNull()]$Summary, [ValidateSet('','configuration','authentication','graph','evaluation','notification')][string]$FailureStage = '')
    $failed = -not [string]::IsNullOrEmpty($FailureStage)
    $body = [Collections.Generic.List[object]]::new()
    $body.Add(@{ type='TextBlock'; text='INTUNE DAILY HEALTH'; size='Small'; weight='Bolder'; color='Accent' })
    $title = if ($failed) { 'Health check could not complete' } else { "$($Summary.Counts.AffectedDevices) devices need attention" }
    if (-not $failed -and $Summary.EmptyInventory) { $title = 'No managed devices returned' }
    elseif (-not $failed -and $Summary.Counts.AffectedDevices -eq 0 -and $Summary.ApplePush.HasIssue) { $title = 'Apple push certificate needs attention' }
    $body.Add(@{ type='TextBlock'; text=$title; size='Large'; weight='Bolder'; wrap=$true })
    $body.Add(@{ type='TextBlock'; text='your Intune tenant · Read-only monitoring'; isSubtle=$true; spacing='Small'; wrap=$true })
    if ($failed) {
        $body.Add(@{ type='TextBlock'; text="The daily run failed during $FailureStage. Review the Azure Automation job before relying on today's health status."; wrap=$true; color='Attention' })
    } else {
        $facts = @(
            @{ title='Devices checked'; value=[string]$Summary.Counts.TotalDevices },
            @{ title='Noncompliant'; value=[string]$Summary.Counts.Noncompliant },
            @{ title='Compliance errors / conflicts'; value=[string]$Summary.Counts.ComplianceErrors },
            @{ title='In grace period'; value=[string]$Summary.Counts.InGracePeriod },
            @{ title='Unknown compliance'; value=[string]$Summary.Counts.UnknownCompliance },
            @{ title="No sync for > $($Summary.StaleAfterDays) days"; value=[string]$Summary.Counts.StaleSync },
            @{ title='Missing / invalid sync date'; value=[string]$Summary.Counts.UnknownSync },
            @{ title='Apple push certificate'; value=[string]$Summary.ApplePush.Status }
        )
        $body.Add(@{ type='FactSet'; facts=$facts; spacing='Medium' })
        $note = if ($Summary.EmptyInventory) { 'Check enrollment, licensing and expected inventory. An empty response is not treated as a healthy fleet.' } else { 'Affected devices are counted once. A device can appear in several checks. Investigate in Intune; this runbook does not change devices.' }
        $body.Add(@{ type='TextBlock'; text=$note; wrap=$true; isSubtle=$true; size='Small'; spacing='Medium' })
        $body.Add(@{ type='TextBlock'; text=($Summary.ApplePush.Detail + '. Scope: device compliance, sync age and optional APNs expiry. Other Intune connectors and workloads are not checked.'); wrap=$true; isSubtle=$true; size='Small'; spacing='Small' })
        $body.Add(@{ type='TextBlock'; text=$Summary.CheckedAtUtc; isSubtle=$true; size='Small'; spacing='Small' })
    }
    $card = @{
        '$schema'='http://adaptivecards.io/schemas/adaptive-card.json'
        type='AdaptiveCard'; version='1.2'; body=@($body)
        actions=@(
            @{ type='Action.OpenUrl'; title='Open Intune'; url='https://intune.microsoft.com/' },
            @{ type='Action.OpenUrl'; title='View health-check job'; url=$script:AutomationUrl }
        )
    }
    return @{ type='message'; attachments=@(@{ contentType='application/vnd.microsoft.card.adaptive'; contentUrl=$null; content=$card }) }
}

function Get-TeamsHealthWebhook {
    $value = [string](Get-AutomationVariable -Name 'TeamsHealthWebhook' -ErrorAction Stop)
    $uri = $null
    if (-not [uri]::TryCreate($value, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.Fragment) { throw 'TeamsHealthWebhook is missing or invalid.' }
    # Workflows currently issue regional Logic Apps or Power Platform endpoints.
    if ($uri.DnsSafeHost -notmatch '(^|\.)(logic\.azure\.com|environment\.api\.powerplatform\.com|api\.powerplatform\.com)$') { throw 'TeamsHealthWebhook must be a Teams Workflows endpoint.' }
    return $value
}

function Send-TeamsHealthPayload {
    param([Parameter(Mandatory)][string]$Webhook, [Parameter(Mandatory)][hashtable]$Payload)
    $json = ConvertTo-Json -InputObject $Payload -Depth 16 -Compress
    if ([Text.Encoding]::UTF8.GetByteCount($json) -gt 24000) { throw 'Teams card exceeds the allowed notification size.' }
    Invoke-HealthHttp -Method POST -Uri $Webhook -Body $json | Out-Null
    # HTTP acceptance only. The Teams Workflow run and the resulting channel card
    # must be verified once during deployment to establish end-to-end delivery.
}

function Invoke-IntuneHealthRun {
    param([ValidateRange(1,365)][int]$StaleAfterDays = 14,
          [bool]$IncludeApplePushCheck = $true,
          [ValidateRange(1,90)][int]$CertificateWarningDays = 30)
    $stage = 'configuration'
    $webhook = $null
    $token = $null
    try {
        $webhook = Get-TeamsHealthWebhook
        $stage = 'authentication'
        $token = Get-ManagedIdentityGraphToken
        $stage = 'graph'
        $devices = @(Get-GraphManagedDevices -Token $token)
        $stage = 'evaluation'
        $summary = Get-IntuneHealthSummary -Devices $devices -StaleAfterDays $StaleAfterDays
        if ($IncludeApplePushCheck) {
            $summary.ApplePush = Get-ApplePushHealth -Token $token -WarningDays $CertificateWarningDays
            $summary.HasIssues = $summary.HasIssues -or $summary.ApplePush.HasIssue
        }
        $notification = 'NotNeeded'
        if ($summary.HasIssues) {
            $stage = 'notification'
            Send-TeamsHealthPayload -Webhook $webhook -Payload (New-TeamsHealthPayload -Summary $summary)
            $notification = 'AcceptedByWorkflow'
        }
        # Counts only: no raw tokens, URLs, device IDs or user/device names in logs.
        $status = if ($IncludeApplePushCheck -and -not $summary.ApplePush.CoverageComplete) { 'CompletedWithCoverageGap' } else { 'Completed' }
        [pscustomobject]@{ Status=$status; CheckedAtUtc=$summary.CheckedAtUtc; HasIssues=$summary.HasIssues; Counts=$summary.Counts; ApplePush=$summary.ApplePush; Notification=$notification } | ConvertTo-Json -Depth 4 -Compress
    } catch {
        $failureAlert = 'Unavailable'
        # Do not resend after an ambiguous notification failure. That would risk
        # duplicate messages, and the same failing endpoint cannot be a fallback.
        if ($webhook -and $stage -ne 'notification') {
            try {
                Send-TeamsHealthPayload -Webhook $webhook -Payload (New-TeamsHealthPayload -Summary $null -FailureStage $stage)
                $failureAlert = 'AcceptedByWorkflow'
            } catch { $failureAlert = 'Failed' }
        }
        throw "Intune health run failed at stage '$stage'. Failure alert: $failureAlert. Review managed identity permissions, configuration and service availability. Sensitive response details suppressed."
    } finally { $token = $null; $webhook = $null }
}

# Dot-sourcing loads pure functions for local fixtures without cloud access.
if ($MyInvocation.InvocationName -ne '.') { Invoke-IntuneHealthRun -StaleAfterDays $StaleAfterDays -IncludeApplePushCheck $IncludeApplePushCheck -CertificateWarningDays $CertificateWarningDays }
