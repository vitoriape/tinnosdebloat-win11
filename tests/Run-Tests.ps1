#Requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$modulePath=Join-Path $root 'Provisioning.psm1'
$work=Join-Path ([IO.Path]::GetTempPath()) ('tinnos-tests-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -Path $work -ItemType Directory
$script:passed=0
function Assert($Condition,[string]$Message) { if (!$Condition) { throw $Message } }
function Test([string]$Name,[scriptblock]$Body) { & $Body; $script:passed++; Write-Output "PASS $Name" }
function Throws([scriptblock]$Body) { $thrown=$false; try { & $Body } catch { $thrown=$true }; Assert $thrown 'Expected failure.' }
function Reset-Engine { Import-Module $modulePath -Force -DisableNameChecking }
function Empty-Teams { [pscustomobject]@{Errors=@();Packages=@();Provisioned=@();MachineEntries=@();MachineBinaries=@();MachineStartup=@();MachineShortcuts=@();MachineAddinFiles=@();Profiles=@()} }
try {
    Reset-Engine
    $config=Read-DeploymentConfig (Join-Path $root 'config.example.json')
    Test 'PowerShell files parse' {
        foreach ($file in @(Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object {$_.Extension -in @('.ps1','.psm1')})) {
            $tokens=$null; $errors=$null
            $null=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
            Assert (!$errors.Count) ("Syntax error in " + $file.Name)
        }
    }
    Test 'Business license and x64 defaults are fixed' {
        Assert ($config.ProductId -eq 'O365BusinessRetail' -and $config.Architecture -eq '64') 'Wrong product/architecture.'
        Throws { Get-OfficeProductId 'Enterprise' }
        $path=Join-Path $work 'minimal.json'; '{}' | Set-Content -LiteralPath $path
        Assert ((Read-DeploymentConfig $path).ProductId -eq 'O365BusinessRetail') 'Missing Business default.'
    }
    Test 'Custom installer URLs and ODT paths are rejected' {
        foreach ($field in @('OdtSetupPath','OdtDownloadUrl','TeamsBootstrapperUrl','LicenseKey')) {
            $path=Join-Path $work 'invalid.json'; ('{"'+$field+'":"untrusted"}') | Set-Content -LiteralPath $path
            Throws { Read-DeploymentConfig $path }
        }
    }
    Test 'Required Office apps are retained while Teams is always excluded' {
        $xml=New-OfficeConfiguration $config $null (Join-Path $work 'office.xml')
        $excluded=@($xml.Configuration.Add.Product.ExcludeApp | ForEach-Object {$_.ID})
        Assert ($xml.Configuration.Add.Product.ID -eq 'O365BusinessRetail') 'Wrong product.'
        Assert ('Teams' -in $excluded -and 'OutlookForWindows' -in $excluded -and 'Groove' -in $excluded) 'Required exclusion missing.'
        Assert (!@($excluded | Where-Object {$_ -in @('Word','Excel','PowerPoint','Outlook','OneNote')}).Count) 'Required app excluded.'
        Assert ($xml.Configuration.Display.Level -eq 'None' -and $xml.Configuration.Property.Value -eq 'FALSE') 'Unsafe UI/document settings.'
        Assert (!$xml.SelectNodes('//Remove|//RemoveMSI|//PIDKEY').Count) 'Unexpected removal or key.'
    }
    Test 'Access selection is honored' {
        $optional=Read-DeploymentConfig (Join-Path $root 'config.example.json'); $optional.IncludeAccess=$true
        $excluded=Get-DesiredExclusions $optional $null
        Assert ('Access' -notin $excluded -and 'Teams' -in $excluded) 'Optional Access selection lost.'
    }
    Test 'Official ODT URL resolves from HTML and escaped JSON' {
        $url='https://download.microsoft.com/download/test/officedeploymenttool_current.exe'
        Assert ((Resolve-OfficialOdtUrl ('<a href="'+$url+'">Download</a>')) -eq $url) 'HTML download resolution failed.'
        Assert ((Resolve-OfficialOdtUrl $url.Replace('/','\/')) -eq $url) 'JSON download resolution failed.'
        Throws { Resolve-OfficialOdtUrl 'https://evil.test/officedeploymenttool.exe' }
    }
    Test 'Nonofficial and insecure downloads are rejected before network access' {
        Throws { Get-TrustedDownload 'http://download.microsoft.com/setup.exe' 'unused' Microsoft }
        Throws { Get-TrustedDownload 'https://microsoft.com.evil.test/setup.exe' 'unused' Microsoft }
        Throws { Get-TrustedDownload 'https://evil.test/drive.exe' 'unused' Google }
    }
    Test 'All Teams inventory dimensions must be empty' {
        Assert (Test-TeamsAbsent (Empty-Teams)) 'Empty inventory rejected.'
        foreach ($field in @('Errors','Packages','Provisioned','MachineEntries','MachineBinaries','MachineStartup','MachineShortcuts','MachineAddinFiles')) {
            $teams=Empty-Teams; $teams.$field=@('remaining'); Assert (!(Test-TeamsAbsent $teams)) "Remaining $field accepted."
        }
        foreach ($field in @('Entries','Binaries','Startup','Shortcuts','AddinFiles')) {
            $profile=[pscustomobject]@{Entries=@();Binaries=@();Startup=@();Shortcuts=@();AddinFiles=@()}; $profile.$field=@('remaining')
            $teams=Empty-Teams; $teams.Profiles=@($profile); Assert (!(Test-TeamsAbsent $teams)) "Per-user $field ignored."
        }
    }
    Test 'Policy conflicts and incomplete inventory fail closed' {
        Throws { Set-TeamsPrevention ([pscustomobject]@{Conflicts=@('MDM conflict');Errors=@()}) }
        $teams=Empty-Teams; $teams.Errors=@('Profile inaccessible'); Throws { Backup-TeamsUserData $teams $work }
    }
    Test 'Document shortcuts and unrelated products are preserved' {
        Assert (!(Test-TeamsEntry ([pscustomobject]@{Name='Microsoft Office'}))) 'Office classified as Teams.'
        Assert (!(Test-TeamsShortcut 'C:\Docs\Teams.exe' '' '')) 'Unrelated shortcut targeted.'
        Assert (Test-TeamsShortcut '' '' 'MSTeams_8wekyb3d8bbwe!Teams') 'Packaged Teams shortcut missed.'
    }
    Test 'Reruns preserve an existing matching Chrome association policy (mocked)' {
        $existing=Join-Path $work 'existing-chrome.xml'; New-ChromeAssociations $existing
        $module=Get-Module Provisioning
        & $module {
            param($existingPath)
            $script:ExistingChrome=$existingPath; $script:Report=[pscustomobject]@{Notes=@()}
            function script:Test-Path { return $true }
            function script:Get-ItemProperty { [pscustomobject]@{DefaultAssociationsConfiguration=$script:ExistingChrome} }
            function script:Invoke-Installer { throw 'Matching associations must not be reimported.' }
        } $existing
        try {
            Set-ChromeDefault $work ([pscustomobject]@{Evidence=@()})
            Assert ((& $module {$script:Report.Notes.Count}) -eq 1) 'Existing matching policy not recognized.'
        } finally {Reset-Engine}
    }
    Test 'Status cannot claim completion with pending actions or failed checks' {
        $pass=@([pscustomobject]@{Pass=$true}); $fail=@([pscustomobject]@{Pass=$false})
        Assert ((Get-DeploymentStatus $pass @() $false @()) -eq 'Complete') 'Passing result rejected.'
        Assert ((Get-DeploymentStatus $pass @() $false @('Restore unavailable')) -eq 'Pending') 'Pending result accepted.'
        Assert ((Get-DeploymentStatus $fail @() $false @()) -eq 'Failed') 'Failed check accepted.'
        Assert ((Get-DeploymentStatus @() @() $false @()) -eq 'Failed') 'Missing checks accepted.'
    }
    Test 'A newly created restore point is independently verified (mocked)' {
        $module=Get-Module Provisioning
        & $module {
            function script:Test-Path { return $false }
            function script:Enable-ComputerRestore {}
            function script:Checkpoint-Computer { param($Description); $script:CreatedDescription=$Description }
            function script:Get-ComputerRestorePoint { [pscustomobject]@{SequenceNumber=8;Description=$script:CreatedDescription;CreationTime=(Get-Date)} }
        }
        try { $point=New-DeploymentRestorePoint; Assert ($point.Status -eq 'Created' -and $point.SequenceNumber -eq 8) 'Restore point not verified.' }
        finally { Reset-Engine }
    }
    Test 'Windows daily throttle can reuse a verified recent restore point (mocked)' {
        $module=Get-Module Provisioning
        & $module {
            function script:Test-Path { return $false }
            function script:Enable-ComputerRestore {}
            function script:Checkpoint-Computer { throw 'A restore point was already created within the past 24 hours.' }
            function script:Get-ComputerRestorePoint { [pscustomobject]@{SequenceNumber=7;Description='Existing restore';CreationTime=(Get-Date).AddHours(-2)} }
        }
        try { Assert ((New-DeploymentRestorePoint).Status -eq 'ReusedRecent') 'Recent point not reported.' }
        finally { Reset-Engine }
    }
    Test 'Restore failure stops deployment before any software changes (mocked)' {
        $module=Get-Module Provisioning
        & $module {
            $script:Report=[pscustomobject]@{Steps=@();RestorePoint=$null}; $script:MutationReached=$false
            function script:Test-Path { return $false }
            function script:Enable-ComputerRestore { throw 'System Restore unavailable.' }
            function script:Remove-TeamsApplications { $script:MutationReached=$true }
        }
        try {
            $errorResult=$null
            try { Invoke-DeploymentSteps $config $null $null $null 'unused' $work } catch { $errorResult=$_ }
            Assert ($null -ne $errorResult -and $errorResult.Exception.Data['PendingAction']) 'Restore failure not reported as pending.'
            Assert (!(& $module {$script:MutationReached})) 'Software mutation preceded restore point.'
        } finally { Reset-Engine }
    }
    Test 'Organization restore policy is preserved (mocked)' {
        $module=Get-Module Provisioning
        & $module {
            function script:Test-Path { return $true }
            function script:Get-ItemProperty { [pscustomobject]@{DisableSR=1} }
            function script:Enable-ComputerRestore { throw 'Should not enable policy-disabled restore' }
        }
        try { Throws { New-DeploymentRestorePoint } } finally { Reset-Engine }
    }
    Test 'Restore, removal and installations execute in the required order (mocked)' {
        $module=Get-Module Provisioning
        & $module {
            $script:Report=[pscustomobject]@{Steps=@();RestorePoint=$null}; $script:Trace=@()
            function script:New-DeploymentRestorePoint {$script:Trace+='restore';[pscustomobject]@{Status='Created'}}
            function script:Remove-TeamsApplications {$script:Trace+='teams'}
            function script:Remove-TeamsProvisioning {$script:Trace+='provisioning'}
            function script:Set-TeamsPrevention {$script:Trace+='policy'}
            function script:Assert-TeamsRemovalComplete {$script:Trace+='gate'}
            function script:Install-Office {$script:Trace+='office'}
            function script:Install-GoogleChrome {$script:Trace+='chrome'}
            function script:Install-GoogleDrive {$script:Trace+='drive'}
            function script:Set-ChromeDefault {$script:Trace+='defaults'}
        }
        try {
            Invoke-DeploymentSteps $config $null $null $null 'unused' $work
            Assert ((& $module {$script:Trace -join ','}) -eq 'restore,teams,provisioning,policy,gate,office,chrome,drive,defaults') 'Deployment order changed.'
        } finally { Reset-Engine }
    }
    $exe=Join-Path $root 'tinnosdebloat-win11.exe'
    $assembly=[Reflection.Assembly]::LoadFile($exe)
    $type=$assembly.GetType('TinnosDebloat.Payload',$true)
    Test 'Portable EXE embeds all current PowerShell sources and defaults' {
        $null=$type.GetMethod('Validate').Invoke($null,@())
        foreach ($file in @('Invoke-Provisioning.ps1','Invoke-UserCleanup.ps1','Provisioning.psm1','Check-OfficeActivation.ps1','config.example.json')) {
            $stream=$assembly.GetManifestResourceStream("Payload.$file"); $memory=New-Object IO.MemoryStream
            try {
                $stream.CopyTo($memory)
                Assert ([Convert]::ToBase64String($memory.ToArray()) -eq [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $root $file)))) "Stale embedded source: $file"
            } finally {$stream.Dispose();$memory.Dispose()}
        }
    }
    Test 'Executable is Windows x64 and requests UAC elevation' {
        $bytes=[IO.File]::ReadAllBytes($exe);$offset=[BitConverter]::ToInt32($bytes,0x3c)
        Assert ([BitConverter]::ToUInt16($bytes,$offset+4) -eq 0x8664) 'Not an x64 PE.'
        Assert ([Text.Encoding]::UTF8.GetString($bytes) -match 'requestedExecutionLevel level="requireAdministrator"') 'UAC manifest missing.'
    }
    Test 'Launcher fixes local script restriction with a process-only setting' {
        $command=$type.GetMethod('Command').Invoke($null,@('C:\Tool folder','C:\config.json','Audit','C:\Reports'))
        Assert ($command.Arguments -match '-ExecutionPolicy Bypass -File ' -and $command.Arguments -notmatch 'Set-ExecutionPolicy') 'Unexpected persistent policy modification.'
        Assert (!$command.UseShellExecute -and $command.RedirectStandardError) 'Errors not captured.'
        Assert ($type.GetMethod('Quote').Invoke($null,@('C:\Path with space\')) -eq '"C:\Path with space\\"') 'Command quoting broken.'
    }
    Test 'Packaged launcher runs a harmless fixture with inherited Restricted policy' {
        if ((Get-ExecutionPolicy -Scope MachinePolicy) -ne 'Undefined' -or (Get-ExecutionPolicy -Scope UserPolicy) -ne 'Undefined') {
            Write-Output 'SKIP process execution under centrally configured policy; argument checks still apply.'
            return
        }
        $fixture=Join-Path $work 'Invoke-Provisioning.ps1'
        'param($ConfigPath,$Mode,$OutputDirectory); [Console]::WriteLine("safe-launch")' | Set-Content -LiteralPath $fixture
        $command=[TinnosDebloat.Payload]::Command($work,(Join-Path $work 'config.json'),'Audit',(Join-Path $work 'reports'))
        $command.EnvironmentVariables['PSExecutionPolicyPreference']='Restricted'
        $process=New-Object Diagnostics.Process; $process.StartInfo=$command
        try {
            $null=$process.Start(); $stdout=$process.StandardOutput.ReadToEnd(); $stderr=$process.StandardError.ReadToEnd(); $process.WaitForExit()
            Assert ($process.ExitCode -eq 0 -and $stdout.Trim() -eq 'safe-launch') ("Fixture launch failed: "+$stderr)
        } finally {$process.Dispose()}
    }
    Test 'Compact interface has selections and actions without license or ODT selectors' {
        Add-Type -AssemblyName System.Windows.Forms
        $form=$assembly.GetType('TinnosDebloat.Ui').GetMethod('Create').Invoke($null,@())
        function Walk-Controls($Control) { foreach ($child in $Control.Controls) {$child; Walk-Controls $child} }
        try {
            $controls=@(Walk-Controls $form)
            Assert ($form.Text -eq 'TinnosDebloat-Win11') 'Unexpected product name.'
            Assert (@($controls | Where-Object {$_ -is [Windows.Forms.CheckBox]}).Count -eq 5) 'Unexpected selection count.'
            Assert (!@($controls | Where-Object {$_ -is [Windows.Forms.ComboBox]}).Count) 'License or update dropdown remains.'
            Assert (!@($controls | Where-Object {$_.Text -match 'ODT|Browse|Enterprise'}).Count) 'Installer picker or Enterprise selection remains.'
        } finally {$form.Dispose()}
    }
    Test 'EXE checksum sidecar matches the build' {
        $hash=(Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
        Assert ((Get-Content -LiteralPath "$exe.sha256" -Raw).Trim() -eq "$hash  tinnosdebloat-win11.exe") 'Checksum mismatch.'
    }
    Write-Output "$script:passed tests passed. No deployment or restore-point operations executed."
} finally {
    $target=[IO.Path]::GetFullPath($work); $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if (!$target.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($target) -notmatch '^tinnos-tests-[0-9a-f]{32}$') {throw 'Unexpected test cleanup target.'}
    Remove-Item -LiteralPath $target -Recurse -Force
}
