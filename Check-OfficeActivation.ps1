#Requires -Version 5.1
# Run as the employee after signing into an Office application.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\Provisioning.psm1" -Force
Get-OfficeActivation -ProductId (Get-OfficeProductId 'Business') | ConvertTo-Json -Depth 8
