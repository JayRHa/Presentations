<#
Version: 1.0
Author: 
- Jannik Reinhard (jannikreinhard.com)
Script: Invoke-CleanStorageDetection
Description:
Hint: This is a community script. There is no guarantee for this. Please check thoroughly before running.
Version 1.0: Init
Run as: User 
Context: 64 Bit
#> 

$storageThreshold = 15

$utilization = (Get-PSDrive | Where {$_.name -eq "C"}).free

if(($storageThreshold *1GB) -lt $utilization){exit 0}
else{exit 1}