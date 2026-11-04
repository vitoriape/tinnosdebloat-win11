#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [ValidateSet('Audit', 'Plan', 'Deploy')][string]$Mode = 'Audit',
    [string]$OutputDirectory = "$env:ProgramData\TinnosDebloat-Win11\Deployment"
)
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\Provisioning.psm1" -Force
try {
    $result = Invoke-CorporateProvisioning -ConfigPath $ConfigPath -Mode $Mode -OutputDirectory $OutputDirectory
    Write-Output ("Status: {0}; report: {1}" -f $result.Status, $result.ReportPath)
    switch ($result.Status) {
        'Complete' { exit 0 }
        'Planned' { exit 0 }
        'Pending' { exit 3010 }
        default { exit 1 }
    }
} catch {
    Write-Error $_
    exit 1
}
