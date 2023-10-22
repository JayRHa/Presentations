$avActive = $false
if(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct){
    $avActive = $true
}

$freeStorage = [math]::Round((Get-PSDrive -Name C).Free / 1024 / 1024 / 1024)
$output = @{ AvActive = $avActive; FreeStorage = $freeStorage}
return $output | ConvertTo-Json -Compress