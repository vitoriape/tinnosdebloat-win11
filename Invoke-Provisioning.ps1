#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [ValidateSet('Audit', 'Plan', 'Deploy')][string]$Mode = 'Audit',
    [string]$OutputDirectory = "$env:ProgramData\TinnosDebloat-Win11\Deployment"
)
$ErrorActionPreference = 'Stop'
# Keep diagnostic language independent of Windows and the PT-BR Office payload.
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('en-US')
[Threading.Thread]::CurrentThread.CurrentUICulture = [Globalization.CultureInfo]::GetCultureInfo('en-US')
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$OutputEncoding = [Console]::OutputEncoding
try {
    Import-Module "$PSScriptRoot\Provisioning.psm1" -Force
    $result = Invoke-CorporateProvisioning -ConfigPath $ConfigPath -Mode $Mode -OutputDirectory $OutputDirectory
    $json = $result.Report | ConvertTo-Json -Depth 25 -Compress
    Write-Output ('TINNOS_RESULT:' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json)))
    switch ($result.Status) {
        'Complete' { exit 0 }
        'Planned' { exit 0 }
        'Pending' { exit 3010 }
        'CompletedWithIssues' { exit 2 }
        default { exit 1 }
    }
} catch {
    $issue = if (Get-Command New-DeploymentIssue -ErrorAction SilentlyContinue) { New-DeploymentIssue 'TNO-100' $_.Exception.Message 'Setup' 'Error' $_ }
        else { [pscustomobject]@{Code='TNO-900';Title='Engine startup failed';Message=$_.Exception.Message;Action='Use a freshly built executable and review Details.';Stage='Setup';Severity='Error';NativeCode=$null} }
    $report = [pscustomobject]@{Status='Failed';Applications=@();Checks=@();Issues=@($issue);Notes=@()}
    $json = $report | ConvertTo-Json -Depth 10 -Compress
    Write-Output ('TINNOS_RESULT:' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json)))
    exit 1
}
