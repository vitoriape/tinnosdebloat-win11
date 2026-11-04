#Requires -Version 5.1
# Runs with the affected user's interactive token, never with an administrator's HKCU.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ResultPath)
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\Provisioning.psm1" -Force
$result = Invoke-TeamsUserCleanup
$result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
if ($result.Errors.Count) { exit 1 }
exit 0
