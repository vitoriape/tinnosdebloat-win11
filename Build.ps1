#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (!(Test-Path -LiteralPath $compiler)) { throw 'Windows .NET Framework 4.x compiler is required.' }
$output=Join-Path $PSScriptRoot 'tinnosdebloat-win11.exe'
$arguments=@('/nologo','/target:winexe','/platform:x64','/optimize+',
    '/reference:System.Windows.Forms.dll','/reference:System.Drawing.dll','/reference:System.Web.Extensions.dll',
    "/win32manifest:$PSScriptRoot\src\app.manifest", "/out:$output")
foreach ($name in @('Invoke-Provisioning.ps1','Invoke-UserCleanup.ps1','Provisioning.psm1','Check-OfficeActivation.ps1','config.example.json','error-codes.json','debloat-catalog.json')) {
    $arguments += "/resource:$PSScriptRoot\$name,Payload.$name"
}
$arguments += "/win32icon:$PSScriptRoot\assets\app.ico"
$arguments += "/resource:$PSScriptRoot\assets\app.ico,Brand.app.ico"
$arguments += "/resource:$PSScriptRoot\assets\emblem.png,Brand.emblem.png"
$arguments += "$PSScriptRoot\src\Program.cs"
& $compiler @arguments
if ($LASTEXITCODE -ne 0) { throw "C# compilation failed: $LASTEXITCODE" }
$hash=(Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash
"$hash  tinnosdebloat-win11.exe" | Set-Content -LiteralPath "$output.sha256" -Encoding ASCII
[pscustomobject]@{Executable=$output;Bytes=(Get-Item -LiteralPath $output).Length;SHA256=$hash}
