<#
Version: 1.0
Author: Jannik Reinhard (jannikreinhard.com)
Script: Get-GraphExportApiReport
Description:
Get an CSV Report from the Graph API
Release notes:
Version 1.0: Init
#> 



$Parameters = @{
    TenantId = "f849cde7-f11d-4ef5-a31d-7fca98b21bf5"
    ClientId = "14d82eec-204b-4c2f-b7e8-296a70dab67e"
    RedirectUri = "http://localhost"
}

$AccessToken = Get-MsalToken @Parameters
$authenticationHeader = @{
    "Content-Type" = "application/json"
    "Authorization" = $AccessToken.CreateAuthorizationHeader()
    "ExpiresOn" = $AccessToken.ExpiresOn.LocalDateTime
}
$authenticationHeader


$reportName = 'Devices'
$body = @"
{ 
    "reportName": "$reportName", 
    "localizationType": "LocalizedValuesAsAdditionalColumn"
} 
"@


$id = (Invoke-RestMethod -Uri https://graph.microsoft.com/beta/deviceManagement/reports/exportJobs -Headers $authenticationHeader -Method POST -Body $body).id
$status = (Invoke-RestMethod -Uri "https://graph.microsoft.com/beta/deviceManagement/reports/exportJobs('$id')" -Headers $authenticationHeader -Method GET).status

while (-not ($status -eq 'completed')) {
    $response = Invoke-RestMethod -Uri "https://graph.microsoft.com/beta/deviceManagement/reports/exportJobs('$id')" -Headers $authenticationHeader -Method Get
    $status = ($response).status
    Start-Sleep -Seconds 2
}

Invoke-WebRequest -Uri $response.url -OutFile "./intuneExport.zip"
Expand-Archive "./intuneExport.zip" -DestinationPath "./intuneExport" 

## Copy the file to an storage or do some actions
########
########