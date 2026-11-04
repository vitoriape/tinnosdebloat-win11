#Requires -Version 5.1
# Runs with the affected user's interactive token, never with an administrator's HKCU.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\Provisioning.psm1" -Force
$result = Invoke-TeamsUserCleanup
if ($result.Errors.Count) { exit 1 }
if ($result.RebootRequired) { exit 3010 }
exit 0
