$m = Get-Module -Name Microsoft.Graph.Intune -ListAvailable
if (-not $m)
{
    Install-Module NuGet -Force
    Install-Module Microsoft.Graph.Intune
}
Import-Module Microsoft.Graph.Intune -Global

Connect-MSGraph | Out-Null

$graphApiVersion = "Beta"
$graphUrl = "https://graph.microsoft.com/$graphApiVersion"
$scriptName = "WIN-CheckAvAndStroage"
$graph_path = 'deviceManagement/deviceCompliancePolicies?$filter=displayname eq ' + "'" + $scriptName + "'"

$result = Invoke-MSGraphRequest -Url "$graphUrl/$graph_path" -HttpMethod GET
$script = $result.value[0].deviceCompliancePolicyScript.rulesContent

if (($script).Length -ne 0) {
    [System.Text.Encoding]::ASCII.GetString([System.Convert]::FromBase64String($($script))) | Out-File -Encoding ASCII -FilePath $(Join-Path "CustomComplianceScript.ps1")
}