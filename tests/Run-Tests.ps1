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
        Assert ($config.AppMode -eq 'Download') 'Default must download without installation.'
        Assert ($config.Languages.Count -eq 1 -and $config.Languages[0] -eq 'pt-br') 'Office language must be fixed to PT-BR.'
        Throws { Get-OfficeProductId 'Enterprise' }
        $path=Join-Path $work 'minimal.json'; '{}' | Set-Content -LiteralPath $path
        Assert ((Read-DeploymentConfig $path).ProductId -eq 'O365BusinessRetail') 'Missing Business default.'
    }
    Test 'English config is rejected and installed languages cannot change generated Office language' {
        $path=Join-Path $work 'english-config.json'; '{"Languages":["en-us"]}' | Set-Content -LiteralPath $path
        Throws {Read-DeploymentConfig $path}
        $xml=New-OfficeConfiguration $config ([pscustomobject]@{Languages=@('en-us');ExcludedApps=@()}) (Join-Path $work 'ptbr-office.xml')
        Assert (@($xml.Configuration.Add.Product.Language).Count -eq 1 -and $xml.Configuration.Add.Product.Language.ID -eq 'pt-br') 'Another language was added to Office XML.'
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
            $script:Report=[pscustomobject]@{Steps=@();RestorePoint=$null;Applications=@();AppIssues=@();Notes=@()}; $script:Trace=@()
            function script:New-DeploymentRestorePoint {$script:Trace+='restore';[pscustomobject]@{Status='Created'}}
            function script:Remove-TeamsApplications {$script:Trace+='teams'}
            function script:Remove-TeamsProvisioning {$script:Trace+='provisioning'}
            function script:Set-TeamsPrevention {$script:Trace+='policy'}
            function script:Assert-TeamsRemovalComplete {$script:Trace+='gate'}
            function script:Install-Office {$script:Trace+='office';[pscustomobject]@{Status='Installed'}}
            function script:Install-GoogleChrome {$script:Trace+='chrome';[pscustomobject]@{Status='Installed'}}
            function script:Install-GoogleDrive {$script:Trace+='drive';[pscustomobject]@{Status='Installed'}}
            function script:Set-ChromeDefault {$script:Trace+='defaults'}
            function script:Get-GoogleApps {[pscustomobject]@{Chrome=@('chrome.exe')}}
        }
        try {
            $installConfig=Read-DeploymentConfig (Join-Path $root 'config.example.json'); $installConfig.AppMode='Install'
            Invoke-DeploymentSteps $installConfig $null $null $null 'unused' $work
            Assert ((& $module {$script:Trace -join ','}) -eq 'restore,teams,provisioning,policy,gate,office,chrome,drive,defaults') 'Deployment order changed.'
        } finally { Reset-Engine }
    }
    Test 'Office failure is skipped while Chrome and Drive are still attempted (mocked)' {
        $module=Get-Module Provisioning
        & $module {
            $script:Report=[pscustomobject]@{Steps=@();RestorePoint=$null;Applications=@();AppIssues=@();Notes=@()}; $script:Trace=@()
            function script:New-DeploymentRestorePoint {[pscustomobject]@{Status='Created'}}
            function script:Remove-TeamsApplications {}
            function script:Remove-TeamsProvisioning {}
            function script:Set-TeamsPrevention {}
            function script:Assert-TeamsRemovalComplete {}
            function script:Install-Office {$script:Trace+='office';throw 'DNS lookup failed for www.microsoft.com'}
            function script:Install-GoogleChrome {$script:Trace+='chrome';[pscustomobject]@{Status='Installed'}}
            function script:Install-GoogleDrive {$script:Trace+='drive';[pscustomobject]@{Status='Installed'}}
            function script:Get-GoogleApps {[pscustomobject]@{Chrome=@('chrome.exe')}}
            function script:Set-ChromeDefault {}
        }
        try {
            $installConfig=Read-DeploymentConfig (Join-Path $root 'config.example.json'); $installConfig.AppMode='Install'
            Invoke-DeploymentSteps $installConfig $null $null $null 'unused' $work
            $result=& $module {$script:Report}
            Assert ((& $module {$script:Trace -join ','}) -eq 'office,chrome,drive') 'An app failure stopped the remaining apps.'
            Assert ($result.Applications[0].Status -eq 'Failed' -and $result.Applications[1].Status -eq 'Installed' -and $result.AppIssues.Count -eq 1) 'Mixed app outcomes were lost.'
            $passed=@([pscustomobject]@{Name='TeamsCompletelyAbsent';Pass=$true;Required=$true})
            Assert ((Get-DeploymentStatus $passed @() $false @() $result.AppIssues) -eq 'CompletedWithIssues') 'Skipped apps reported as full success.'
            $failed=@([pscustomobject]@{Name='TeamsCompletelyAbsent';Pass=$false;Required=$true})
            Assert ((Get-DeploymentStatus $failed @() $false @() $result.AppIssues) -eq 'Failed') 'Remaining Teams was hidden by an optional app failure.'
        } finally {Reset-Engine}
    }
    Test 'Download-only flow never requests installers or browser-default changes (mocked)' {
        $module=Get-Module Provisioning
        & $module {
            $script:Report=[pscustomobject]@{Steps=@();RestorePoint=$null;Applications=@();AppIssues=@();Notes=@()}
            function script:New-DeploymentRestorePoint {[pscustomobject]@{Status='Created'}}
            function script:Remove-TeamsApplications {}
            function script:Remove-TeamsProvisioning {}
            function script:Set-TeamsPrevention {}
            function script:Assert-TeamsRemovalComplete {throw 'Download-only does not install anything while cleanup is pending.'}
            function script:Install-Office {param($Config);if ($Config.AppMode -ne 'Download') {throw 'Wrong app mode'};[pscustomobject]@{Status='Downloaded'}}
            function script:Install-GoogleChrome {param($Directory,[switch]$DownloadOnly);if (!$DownloadOnly) {throw 'Chrome installation requested'};[pscustomobject]@{Status='Downloaded'}}
            function script:Install-GoogleDrive {param($Directory,[switch]$DownloadOnly);if (!$DownloadOnly) {throw 'Drive installation requested'};[pscustomobject]@{Status='Downloaded'}}
            function script:Set-ChromeDefault {throw 'Must not change defaults in download-only mode'}
        }
        try {
            Invoke-DeploymentSteps $config $null $null $null 'unused' $work
            $result=& $module {$script:Report}
            Assert ($result.Applications.Count -eq 3 -and !$result.AppIssues.Count) 'Download-only unexpectedly installed or skipped apps.'
            Assert (!@($result.Applications | Where-Object {$_.Status -ne 'Downloaded'}).Count) 'Downloads misrepresented as installations.'
        } finally {Reset-Engine}
    }
    Test 'Office download runs only ODT download mode, without checking existing licenses (mocked)' {
        $xmlPath=Join-Path $work 'download-office.xml'; $null=New-OfficeConfiguration $config $null $xmlPath
        $module=Get-Module Provisioning
        & $module {
            $script:Args=@()
            function script:Get-OdtSetup {return 'official-setup.exe'}
            function script:Invoke-Installer {param($FilePath,$Arguments);$script:Args+=$Arguments;return 0}
            function script:Test-OfficeMedia {return $true}
            function script:Get-OfficeActivation {throw 'Activation must not run'}
            function script:Test-OfficeMatches {throw 'An existing Office license is irrelevant to downloading media'}
        }
        try {
            $media=Install-Office $config $null $null $xmlPath $work
            $calls=@(& $module {$script:Args})
            Assert ($media.Status -eq 'Downloaded' -and $calls.Count -eq 1 -and $calls[0] -like '/download *') 'Office configure/activation was requested.'
        } finally {Reset-Engine}
    }
    Test 'Empty or incomplete Office media never passes download validation' {
        $mediaRoot=Join-Path $work 'media'; $data=Join-Path $mediaRoot 'Office\Data'
        $null=New-Item -Path $data -ItemType Directory -Force
        Assert (!(Test-OfficeMedia $mediaRoot '64')) 'Missing media accepted.'
        [IO.File]::WriteAllText((Join-Path $data 'v64.cab'),'cab-fixture')
        Assert (!(Test-OfficeMedia $mediaRoot '64')) 'Manifest without media payload accepted.'
        [IO.File]::WriteAllText((Join-Path $data 'stream.x64.dat'),'payload-fixture')
        Assert (Test-OfficeMedia $mediaRoot '64') 'Complete fixture not recognized.'
    }
    Test 'Unavailable Download Center falls back to the verified Microsoft archive host (mocked)' {
        $module=Get-Module Provisioning
        & $module {
            $script:Report=[pscustomobject]@{Notes=@()};$script:OdtUrl=''
            function script:Invoke-WebRequest {throw 'Cannot resolve www.microsoft.com'}
            function script:Get-TrustedDownload {param($Url);$script:OdtUrl=$Url;return 'odt-archive.exe'}
            function script:Invoke-Installer {return 0}
            function script:Assert-Publisher {}
            function script:Get-Item {[pscustomobject]@{VersionInfo=[pscustomobject]@{OriginalFilename='setup.exe';FileDescription='Microsoft Office';ProductName='Office'}}}
        }
        try {
            $null=Get-OdtSetup $config $work
            Assert ((& $module {$script:OdtUrl}) -like 'https://download.microsoft.com/*/officedeploymenttool_*.exe') 'ODT fallback is not an official Microsoft archive.'
        } finally {Reset-Engine}
    }
    Test 'PowerShell transfer failure can fall back to curl without accepting an empty file (mocked)' {
        $module=Get-Module Provisioning
        & $module {
            $script:Report=[pscustomobject]@{Downloads=@()}
            function script:Invoke-WebRequest {throw 'PowerShell transfer failed'}
            function script:Invoke-CurlTransfer {param($Url,$Destination);[IO.File]::WriteAllText($Destination,'download-fixture')}
            function script:Assert-Publisher {}
        }
        try {
            $path=Join-Path $work 'download-fixture.exe'
            $null=Get-TrustedDownload 'https://dl.google.com/download-fixture.exe' $path 'Google'
            Assert ((Get-Item -LiteralPath $path).Length -gt 0) 'No downloaded bytes.'
            Assert ((& $module {$script:Report.Downloads[0].Method}) -eq 'curl') 'Fallback method was not recorded.'
        } finally {Reset-Engine}
    }
    Test 'Unsigned responses and total network failures do not leave trusted final artifacts (mocked)' {
        $module=Get-Module Provisioning
        & $module {
            function script:Invoke-WebRequest {param($Uri,$OutFile);[IO.File]::WriteAllText($OutFile,'not-an-installer')}
        }
        try {
            $path=Join-Path $work 'unsigned.exe'
            Throws {Get-TrustedDownload 'https://dl.google.com/unsigned.exe' $path 'Google'}
            Assert (!(Test-Path -LiteralPath $path)) 'Unsigned artifact accepted.'
        } finally {Reset-Engine}
        $module=Get-Module Provisioning
        & $module {
            function script:Invoke-WebRequest {throw 'DNS unavailable'}
            function script:Invoke-CurlTransfer {throw 'curl unavailable'}
        }
        try {
            $path=Join-Path $work 'failed.exe'
            Throws {Get-TrustedDownload 'https://dl.google.com/failed.exe' $path 'Google'}
            Assert (!(Test-Path -LiteralPath $path)) 'Failed artifact retained as a successful download.'
            Assert (!@(Get-ChildItem -LiteralPath $work -Filter '*.download-*').Count) 'Partial transfer artifact leaked.'
        } finally {Reset-Engine}
    }
    Test 'Error codes preserve typed network failures, native installer exits and documented recovery actions' {
        $dns=New-Object Net.WebException('localized message',[Net.WebExceptionStatus]::NameResolutionFailure)
        Assert ((Get-TinnosErrorCode $dns) -eq 'TNO-300') 'DNS depends on localized message text.'
        $timeout=New-Object Net.WebException('localized message',[Net.WebExceptionStatus]::Timeout)
        Assert ((Get-TinnosErrorCode $timeout) -eq 'TNO-302') 'Timeout code missing.'
        try {throw (New-TinnosError 'TNO-400' 'vendor failure' 1603)} catch {$issue=New-DeploymentIssue 'TNO-900' $_.Exception.Message 'Installer' 'Error' $_}
        Assert ($issue.Code -eq 'TNO-400' -and $issue.NativeCode -eq 1603 -and $issue.Action) 'Native installer evidence lost.'
        $docs=[IO.File]::ReadAllText((Join-Path $root 'docs/ERROR_CODES.md'))
        $catalog=Get-Content (Join-Path $root 'error-codes.json') -Raw | ConvertFrom-Json
        foreach($entry in $catalog.PSObject.Properties) {
            Assert ($docs.Contains($entry.Name) -and $docs.Contains($entry.Value.Title) -and $docs.Contains($entry.Value.Action)) ('Undocumented error: '+$entry.Name)
        }
    }
    Test 'Audit returns results in memory without writing reports or querying activation (mocked)' {
        $module=Get-Module Provisioning
        & $module {
            function script:Assert-ProvisioningHost {}
            function script:Initialize-ProtectedDirectory($Path) {$null=New-Item -Path $Path -ItemType Directory -Force}
            function script:Get-OfficeState {[pscustomobject]@{ExcludedApps=@();Languages=@()}}
            function script:Get-TeamsInventory {[pscustomobject]@{Errors=@()}}
            function script:Get-PolicyEvidence {[pscustomobject]@{Errors=@();Conflicts=@()}}
            function script:Get-GoogleApps {}
            function script:Get-UserCleanupResults {}
            function script:Get-PendingRebootReasons {}
            function script:Get-OfficeActivation {throw 'Activation must not be queried'}
            function script:Get-DeploymentChecks {[pscustomobject]@{Name='TeamsCompletelyAbsent';Pass=$true;Required=$true;Category='Cleanup';Detail='Mocked inventory'}}
        }
        try {
            $out=Join-Path $work 'memory-results'
            $result=Invoke-CorporateProvisioning (Join-Path $root 'config.example.json') Audit $out
            Assert ($result.Status -eq 'Complete' -and $result.Report.Checks.Count -eq 1) 'Results not returned.'
            Assert ($result.Report.Activation.Status -eq 'Deferred') 'Activation state incorrect.'
            $files=@(Get-ChildItem -LiteralPath $out -Recurse -File)
            Assert ($files.Count -eq 1 -and $files[0].Name -eq 'office-configuration.xml') 'Unexpected saved report or log.'
        } finally {Reset-Engine}
    }
    $exe=Join-Path $root 'tinnosdebloat-win11.exe'
    $assembly=[Reflection.Assembly]::LoadFile($exe)
    $type=$assembly.GetType('TinnosDebloat.Payload',$true)
    Test 'Portable EXE embeds all current PowerShell sources and defaults' {
        $null=$type.GetMethod('Validate').Invoke($null,@())
        foreach ($file in @('Invoke-Provisioning.ps1','Invoke-UserCleanup.ps1','Provisioning.psm1','Check-OfficeActivation.ps1','config.example.json','error-codes.json')) {
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
    Test 'Interface has only Start and Details actions with fixed Office language' {
        Add-Type -AssemblyName System.Windows.Forms
        $form=$assembly.GetType('TinnosDebloat.Ui').GetMethod('Create').Invoke($null,@())
        function Walk-Controls($Control) { foreach ($child in $Control.Controls) {$child; Walk-Controls $child} }
        try {
            $controls=@(Walk-Controls $form)
            Assert ($form.Text -eq 'TinnosDebloat-Win11') 'Unexpected product name.'
            Assert (@($controls | Where-Object {$_ -is [Windows.Forms.CheckBox]}).Count -eq 3) 'Unexpected Office selection count.'
            $actions=@($controls | Where-Object {$_ -is [Windows.Forms.Button]})
            Assert ($actions.Count -eq 2 -and 'Start' -in $actions.Text -and 'Details' -in $actions.Text) 'Unexpected action buttons.'
            Assert (!@($controls | Where-Object {($_ -is [Windows.Forms.CheckBox] -or $_ -is [Windows.Forms.Button]) -and $_.Text -match 'PT-BR|English|Audit|reports'}).Count) 'Removed control still exists.'
            $download=@($controls | Where-Object {$_ -is [Windows.Forms.RadioButton] -and $_.Text -eq 'Download only'})
            $install=@($controls | Where-Object {$_ -is [Windows.Forms.RadioButton] -and $_.Text -eq 'Download + install'})
            Assert ($download.Count -eq 1 -and $install.Count -eq 1 -and $download[0].Checked -and !$install[0].Checked) 'Download-only default missing.'
            $install[0].Checked=$true
            Assert (!$download[0].Checked) 'Install mode is not exclusive.'
            $download[0].Checked=$true
            Assert (!$install[0].Checked) 'Download mode cannot be restored.'
            Assert (!@($controls | Where-Object {$_ -is [Windows.Forms.ComboBox]}).Count) 'License or update dropdown remains.'
            Assert (!@($controls | Where-Object {$_.Text -match 'ODT|Browse|Enterprise'}).Count) 'Installer picker or Enterprise selection remains.'
        } finally {$form.Dispose()}
    }
    Test 'In-app results decode the worker message and display failures with recovery and activation state' {
        $form=[TinnosDebloat.Ui]::Create()
        try {
            $json=@{Status='CompletedWithIssues';Applications=@(@{Name='Chrome';Status='Failed';ErrorCode='TNO-400';Error='vendor failure'});Issues=@(@{Code='TNO-400';Title='Installer failed';Message='vendor failure';Action='Check vendor exit';NativeCode=1603;Severity='Error'});Activation=@{Status='Deferred';Reason='No sign-in attempted'};Checks=@(@{Name='TeamsCompletelyAbsent';Pass=$true;Required=$true;Detail='all users checked'})} | ConvertTo-Json -Depth 8 -Compress
            $wire='TINNOS_RESULT:'+([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json)))
            $decoded=[TinnosDebloat.ResultChannel]::Decode($wire)
            $form.ApplyResult($decoded)
            $rows=$form.Controls.Find('resultList',$true)[0].Items
            Assert ($rows.Count -eq 4) 'Result rows missing.'
            Assert (@($rows | Where-Object {$_.Text -eq 'Office activation'})[0].SubItems[1].Text -eq 'Deferred') 'Deferred activation missing.'
            $errors=$form.Controls.Find('errorDetails',$true)[0].Text
            Assert ($errors.Contains('TNO-400') -and $errors.Contains('1603') -and $errors.Contains('Check vendor exit')) 'Error evidence or recovery action missing.'
            Throws {$null=[TinnosDebloat.ResultChannel]::Decode('TINNOS_RESULT:invalid!')}
            Throws {$form.ApplyResult('{}')}
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
