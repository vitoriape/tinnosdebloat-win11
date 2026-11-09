#Requires -Version 5.1
# Runs with the affected user's interactive token, never with an administrator's HKCU.
[CmdletBinding()]
param([ValidateSet('OneDrive')][string]$NativeItem)
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\Provisioning.psm1" -Force
if ($NativeItem) {
    $result=Remove-DesktopUtility $NativeItem -UserContext
    if ($result.Status -notin @('Removed','NotPresent')) {exit 1}
    exit 0
}
$result = Invoke-TeamsUserCleanup
if ($result.Errors.Count) { exit 1 }
if ($result.RebootRequired) { exit 3010 }
exit 0
