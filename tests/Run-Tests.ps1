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
function Reset-Engine {
    Import-Module $modulePath -Force -DisableNameChecking
    # Capture live events in memory so mocks cannot pollute returned objects.
    & (Get-Module Provisioning) {
        $script:Events=@()
        function script:Send-DeploymentEvent($Kind,$Task,$Message,$Issue=$null) {
            $script:Events += [pscustomobject]@{Kind=$Kind;Task=$Task;Message=$Message;Issue=$Issue}
        }
    }
}
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
        Assert ($config.AppMode -eq 'Install' -and $config.InstallItems.Count -eq 3) 'Default must install the selected gear.'
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
        Assert (!@($excluded | Where-Object {$_ -in @('Word','Excel','PowerPoint','OneNote')}).Count) 'Required app excluded.'
        foreach ($id in @('Access','OneDrive','Outlook','OutlookForWindows')) {Assert ($id -in $excluded) ('Fixed exclusion missing: '+$id)}
        Assert ($xml.Configuration.Display.Level -eq 'None' -and $xml.Configuration.Property.Value -eq 'FALSE') 'Unsafe UI/document settings.'
        Assert (!$xml.SelectNodes('//Remove|//RemoveMSI|//PIDKEY').Count) 'Unexpected removal or key.'
    }
    Test 'Legacy Office flags cannot re-enable excluded apps' {
        $optional=Read-DeploymentConfig (Join-Path $root 'config.example.json'); $optional.IncludeAccess=$true
        $excluded=Get-DesiredExclusions $optional $null
        Assert ('Access' -in $excluded -and 'Outlook' -in $excluded -and 'OneDrive' -in $excluded) 'Fixed Office exclusions could be overridden.'
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
    Test 'Restore failure does not run unrequested downloads or system changes (mocked)' {
        $module=Get-Module Provisioning
        & $module {
            $script:Report=[pscustomobject]@{Steps=@();RestorePoint=$null;Errors=@();Issues=@();Applications=@();AppIssues=@();Notes=@()}; $script:MutationReached=$false; $script:Downloads=0
            function script:Test-Path { return $false }
            function script:Enable-ComputerRestore { throw 'System Restore unavailable.' }
            function script:Remove-TeamsApplications { $script:MutationReached=$true }
            function script:Invoke-SelectedDebloat {$script:MutationReached=$true}
            function script:Install-Office {param($Config);if ($Config.AppMode -ne 'Download') {throw 'Installation attempted'};$script:Downloads++;[pscustomobject]@{Status='Downloaded'}}
            function script:Install-GoogleChrome {param($Directory,[switch]$DownloadOnly);if (!$DownloadOnly) {throw 'Installation attempted'};$script:Downloads++;[pscustomobject]@{Status='Downloaded'}}
            function script:Install-GoogleDrive {param($Directory,[switch]$DownloadOnly);if (!$DownloadOnly) {throw 'Installation attempted'};$script:Downloads++;[pscustomobject]@{Status='Downloaded'}}
        }
        try {
            Invoke-DeploymentSteps $config $null $null $null 'unused' $work
            Assert ((& $module {$script:Report.Issues[0].Code}) -eq 'TNO-201') 'Restore failure not reported.'
            Assert (!(& $module {$script:MutationReached})) 'Software mutation preceded restore point.'
            Assert ((& $module {$script:Downloads}) -eq 0) 'Unrequested fallback downloads were started.'
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
            function script:Invoke-SelectedDebloat {}
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
            function script:Invoke-SelectedDebloat {}
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
            function script:Invoke-SelectedDebloat {}
            function script:Install-Office {param($Config);if ($Config.AppMode -ne 'Download') {throw 'Wrong app mode'};[pscustomobject]@{Status='Downloaded'}}
            function script:Install-GoogleChrome {param($Directory,[switch]$DownloadOnly);if (!$DownloadOnly) {throw 'Chrome installation requested'};[pscustomobject]@{Status='Downloaded'}}
            function script:Install-GoogleDrive {param($Directory,[switch]$DownloadOnly);if (!$DownloadOnly) {throw 'Drive installation requested'};[pscustomobject]@{Status='Downloaded'}}
            function script:Set-ChromeDefault {throw 'Must not change defaults in download-only mode'}
        }
        try {
            $downloadConfig=$config.PSObject.Copy();$downloadConfig.AppMode='Download'
            Invoke-DeploymentSteps $downloadConfig $null $null $null 'unused' $work
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
            $downloadConfig=$config.PSObject.Copy();$downloadConfig.AppMode='Download'
            $media=Install-Office $downloadConfig $null $null $xmlPath $work
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
            function script:Assert-OdtExecutable {}
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
    Test 'Removal configuration validates IDs and requires explicit selection of high impact services' {
        Assert ('DarkMode' -in $config.RemoveItems -and 'DesktopIcons' -in $config.RemoveItems -and 'TaskbarSearch' -in $config.RemoveItems -and 'TaskbarWidgets' -in $config.RemoveItems) 'Desktop defaults missing.'
        foreach($id in @('BitLockerService','RemoteDesktop','RemoteDesktopConnection','Biometrics','SmartCard','ServerService')) {Assert ($id -notin $config.RemoveItems) ('High impact default: '+$id)}
        $path=Join-Path $work 'choices.json'
        '{"RemoveItems":["Paint"]}' | Set-Content -LiteralPath $path
        $selected=Read-DeploymentConfig $path
        Assert ($selected.RemoveItems.Count -eq 1 -and 'Teams' -notin $selected.RemoveItems -and 'Paint' -in $selected.RemoveItems) 'Unchecked Teams was added to the selection.'
        '{"RemoveItems":["Defender"]}' | Set-Content -LiteralPath $path
        Throws {Read-DeploymentConfig $path}
    }
    Test 'ODT validation accepts PE files without version-resource assumptions and rejects truncated content' {
        # Signature/provenance is checked separately by Get-OdtSetup before this parser.
        $path=Join-Path $work 'setup.exe'
        $bytes=New-Object byte[] 128; $bytes[0]=0x4d; $bytes[1]=0x5a; $bytes[0x3c]=64; $bytes[64]=0x50; $bytes[65]=0x45
        [IO.File]::WriteAllBytes($path,$bytes)
        Assert-OdtExecutable $path
        [IO.File]::WriteAllText($path,'not a PE')
        try {Assert-OdtExecutable $path;throw 'Invalid PE accepted'} catch {Assert ((Get-TinnosErrorCode $_) -eq 'TNO-307') 'Wrong invalid ODT code.'}
    }
    Test 'Pending Teams blocks Office installation while selected cleanup, Chrome and Drive continue (mocked)' {
        $module=Get-Module Provisioning
        & $module {
            $script:Report=[pscustomobject]@{Steps=@();RestorePoint=$null;Applications=@();AppIssues=@();Issues=@();Errors=@();Notes=@()};$script:Trace=@()
            function script:New-DeploymentRestorePoint {[pscustomobject]@{Status='Created'}}
            function script:Remove-TeamsApplications {throw (New-TinnosError 'TNO-204' 'Teams data locked')}
            function script:Remove-TeamsProvisioning {throw 'Provisioning must not run without preservation'}
            function script:Set-TeamsPrevention {}
            function script:Assert-TeamsRemovalComplete {throw (New-TinnosError 'TNO-203' 'Teams remains')}
            function script:Invoke-SelectedDebloat {$script:Trace+='debloat'}
            function script:Install-Office {throw 'Office must be blocked'}
            function script:Install-GoogleChrome {$script:Trace+='chrome';[pscustomobject]@{Status='Installed'}}
            function script:Install-GoogleDrive {$script:Trace+='drive';[pscustomobject]@{Status='Installed'}}
            function script:Get-GoogleApps {[pscustomobject]@{Chrome=@('chrome.exe')}}
            function script:Set-ChromeDefault {}
        }
        try {
            $cfg=$config.PSObject.Copy();$cfg.AppMode='Install'
            Invoke-DeploymentSteps $cfg $null $null $null 'unused' $work
            Assert ((& $module {$script:Trace -join ','}) -eq 'debloat,chrome,drive') 'An independent task was stopped.'
            Assert ((& $module {$script:Report.Applications[0].ErrorCode}) -eq 'TNO-203') 'Office gate not reported.'
            Assert (@(& $module {$script:Events | Where-Object {$_.Kind -eq 'Issue'}}).Count -ge 2) 'Errors not emitted live.'
        } finally {Reset-Engine}
    }
    Test 'Selected app removal is exact, preserves data first and verifies installed and provisioned absence (mocked)' {
        $module=Get-Module Provisioning
        & $module {
            $script:Trace=@();$script:AppRemoved=$false;$script:ProvisionRemoved=$false
            $script:Report=[pscustomobject]@{RebootRequired=$false;Issues=@()}
            function script:Get-AppxPackage {
                if (!$script:AppRemoved) {[pscustomobject]@{Name='Microsoft.Paint';PackageFullName='paint-fixture';PackageFamilyName='Microsoft.Paint_fixture';IsFramework=$false;NonRemovable=$false}}
                [pscustomobject]@{Name='Unrelated.Paint';PackageFullName='unrelated';PackageFamilyName='Unrelated.Paint_fixture';IsFramework=$false;NonRemovable=$false}
            }
            function script:Get-AppxProvisionedPackage {if (!$script:ProvisionRemoved) {[pscustomobject]@{DisplayName='Microsoft.Paint';PackageName='paint-provisioning'}}}
            function script:Backup-SelectedAppData {$script:Trace+='backup'}
            function script:Remove-AppxPackage {param($Package,[switch]$AllUsers);if ($Package -ne 'paint-fixture' -or !$AllUsers) {throw 'Unsafe removal'};$script:Trace+='app';$script:AppRemoved=$true}
            function script:Remove-AppxProvisionedPackage {param([switch]$Online,$PackageName,[switch]$AllUsers);if ($PackageName -ne 'paint-provisioning' -or !$AllUsers) {throw 'Unsafe provisioning removal'};$script:Trace+='provision';$script:ProvisionRemoved=$true;[pscustomobject]@{RestartNeeded=$false}}
        }
        try {
            $result=Remove-SelectedApp 'Microsoft.Paint' $work
            Assert ($result.Status -eq 'Removed' -and (& $module {$script:Trace -join ','}) -eq 'backup,app,provision') 'Removal order or verification wrong.'
            Throws {Remove-SelectedApp 'Microsoft.Office' $work}
        } finally {Reset-Engine}
    }
    Test 'Locked app data prevents both installed and provisioned removal (mocked)' {
        $module=Get-Module Provisioning
        & $module {
            $script:Removed=$false
            function script:Get-AppxPackage {[pscustomobject]@{Name='Microsoft.Paint';PackageFullName='fixture';PackageFamilyName='fixture';IsFramework=$false;NonRemovable=$false}}
            function script:Get-AppxProvisionedPackage {[pscustomobject]@{DisplayName='Microsoft.Paint';PackageName='fixture'}}
            function script:Backup-SelectedAppData {throw (New-TinnosError 'TNO-501' 'Data locked')}
            function script:Remove-AppxPackage {$script:Removed=$true}
            function script:Remove-AppxProvisionedPackage {$script:Removed=$true}
        }
        try {Throws {Remove-SelectedApp 'Microsoft.Paint' $work};Assert (!(& $module {$script:Removed})) 'Data protection bypassed.'} finally {Reset-Engine}
    }
    Test 'An app removal failure still runs subsequent app and service selections (mocked)' {
        $module=Get-Module Provisioning
        & $module {
            $script:Trace=@();$script:Report=[pscustomobject]@{Applications=@();AppIssues=@();Issues=@()}
            function script:Remove-SelectedApp {param($PackageName);$script:Trace+=$PackageName;if ($PackageName -eq 'Clipchamp.Clipchamp') {throw 'App busy'};[pscustomobject]@{Status='Removed'}}
            function script:Disable-SelectedService {param($Name);$script:Trace+=$Name;[pscustomobject]@{Status='Disabled'}}
        }
        try {
            $cfg=$config.PSObject.Copy();$cfg.RemoveItems=@('Clipchamp','Copilot','SearchIndexing')
            Invoke-SelectedDebloat $cfg $work
            Assert ((& $module {$script:Trace -join ','}) -eq 'Clipchamp.Clipchamp,Microsoft.Copilot,Microsoft.CopilotDev,Microsoft.MicrosoftOfficeHub,WSearch') 'Failure stopped selected cleanup.'
            Assert ((& $module {$script:Report.Applications[-1].Status}) -eq 'Disabled') 'Last operation did not complete.'
        } finally {Reset-Engine}
    }
    Test 'Service changes verify disabled state and never force-stop dependent services (mocked)' {
        $module=Get-Module Provisioning
        & $module {
            $script:Changed=$false;$script:Stopped=$false
            function script:Assert-ServicePolicy {}
            function script:Get-Service {[pscustomobject]@{Status='Running'}}
            function script:Get-CimInstance {[pscustomobject]@{StartMode=$(if ($script:Changed) {'Disabled'} else {'Auto'});State=$(if ($script:Stopped) {'Stopped'} else {'Running'})}}
            function script:Stop-Service {param($Name,[switch]$Force);if ($Force) {throw 'Dependent services force stopped'};$script:Stopped=$true}
            function script:Set-Service {param($Name,$StartupType);if ($StartupType -ne 'Disabled') {throw 'Wrong startup'};$script:Changed=$true}
        }
        try {Assert ((Disable-SelectedService WSearch).Status -eq 'Disabled') 'Service state was not verified.';Throws {Disable-SelectedService WinDefend}} finally {Reset-Engine}
    }
    Test 'Managed service and desktop policy blocks local changes (mocked)' {
        $module=Get-Module Provisioning
        & $module {
            $script:Changed=$false
            function script:Get-Service {[pscustomobject]@{Status='Running'}}
            function script:Get-CimInstance {param($ClassName);if ($ClassName -eq 'Win32_ComputerSystem') {[pscustomobject]@{PartOfDomain=$true}} else {throw 'Policy unavailable'}}
            function script:Stop-Service {$script:Changed=$true}
            function script:Set-Service {$script:Changed=$true}
            function script:Set-VerifiedDword {$script:Changed=$true}
        }
        try {Throws {Disable-SelectedService WSearch};Throws {Set-SelectedDesktopSetting DarkMode};Assert (!(& $module {$script:Changed})) 'Managed configuration overwritten.'} finally {Reset-Engine}
    }
    Test 'Desktop and taskbar policies use the documented values without deleting files (mocked)' {
        $module=Get-Module Provisioning
        & $module {
            $script:Writes=@()
            function script:Assert-LocalDesktopSettings {}
            function script:Get-ItemProperty {[pscustomobject]@{EditionID='Professional';CurrentBuildNumber='26100'}}
            function script:Set-VerifiedDword {param($Path,$Name,$Value,[switch]$Policy);$script:Writes+=($Name+'='+$Value);if (!$Policy) {throw 'Expected policy'}}
            function script:Remove-Item {throw 'Desktop files must not be deleted'}
        }
        try {
            foreach($setting in @('DesktopIcons','TaskbarSearch','TaskbarWidgets')) {Assert ((Set-SelectedDesktopSetting $setting).Status -eq 'Configured') 'Setting failed.'}
            Assert ((& $module {$script:Writes -join ','}) -eq 'NoDesktop=1,SearchOnTaskbarMode=0,AllowNewsAndInterests=0') 'Wrong shell policy values.'
        } finally {Reset-Engine}
    }
    Test 'Dark mode sets Windows and apps for other profiles even if one hive is inaccessible (mocked)' {
        $module=Get-Module Provisioning
        & $module {
            $script:Writes=@();$script:Report=[pscustomobject]@{Issues=@()}
            function script:Assert-LocalDesktopSettings {}
            function script:Get-ItemProperty {[pscustomobject]@{EditionID='Professional'}}
            function script:Get-CimInstance {[pscustomobject]@{SID='locked';Special=$false};[pscustomobject]@{SID='available';Special=$false}}
            function script:Use-ProfileHive {param($Profile,$Action);if ($Profile.SID -eq 'locked') {throw 'Hive locked'};& $Action 'Registry::HKEY_USERS\available'}
            function script:Set-VerifiedDword {param($Path,$Name,$Value);$script:Writes+=($Name+'='+$Value)}
        }
        try {
            Throws {Set-SelectedDesktopSetting DarkMode}
            Assert ((& $module {$script:Writes -join ','}) -eq 'AppsUseLightTheme=0,SystemUsesLightTheme=0') 'Available profile did not get dark mode.'
            Assert ((& $module {$script:Report.Issues[0].Code}) -eq 'TNO-503') 'Inaccessible profile not reported.'
        } finally {Reset-Engine}
    }
    Test 'Drive installer excludes Docs editors and desktop shortcuts, and verifies Drive before success (mocked)' {
        $module=Get-Module Provisioning
        & $module {
            $script:Args='';$script:Calls=0
            function script:Get-GoogleApps {$script:Calls++;[pscustomobject]@{Drive=$(if ($script:Calls -ge 2) {@('GoogleDriveFS.exe')} else {@()})}}
            function script:Get-TrustedDownload {return 'drive-fixture.exe'}
            function script:Invoke-Installer {param($FilePath,$Arguments);$script:Args=$Arguments;return 0}
        }
        try {
            Assert ((Install-GoogleDrive $work).Status -eq 'Installed') 'Drive not verified.'
            $arguments=& $module {$script:Args}
            Assert ($arguments.Contains('--gsuite_shortcuts=false') -and !$arguments.Contains('--desktop_shortcut')) 'Unwanted Google shortcuts requested.'
        } finally {Reset-Engine}
    }
    Test 'Dell MSI removal matches only catalog products and verifies absence (mocked)' {
        $module=Get-Module Provisioning
        & $module {
            $script:Removed=$false;$script:Args='';$script:Report=[pscustomobject]@{Issues=@()}
            function script:Get-CimInstance {}
            function script:Get-UninstallEntries {
                if (!$script:Removed) {[pscustomobject]@{Name='Dell SupportAssist';Publisher='Dell Inc.';Scope='HKLM:';Key='{12345678-1234-1234-1234-123456789ABC}';WindowsInstaller=1;QuietUninstallString=''}}
                [pscustomobject]@{Name='Dell System Driver';Publisher='Dell Inc.';Scope='HKLM:';Key='{99999999-1234-1234-1234-123456789ABC}';WindowsInstaller=1;QuietUninstallString=''}
            }
            function script:Invoke-Installer {param($FilePath,$Arguments);$script:Args=$Arguments;$script:Removed=$true;return 0}
        }
        try {
            Assert ((Remove-DesktopUtility DellSupportAssist).Status -eq 'Removed') 'Dell removal not verified.'
            Assert ((& $module {$script:Args}) -eq '/x {12345678-1234-1234-1234-123456789ABC} /qn /norestart') 'Unrelated driver or unsafe MSI flags targeted.'
        } finally {Reset-Engine}
    }
    Test 'Unknown desktop uninstallers and wrong publishers are reported without executing (mocked)' {
        $module=Get-Module Provisioning
        & $module {
            $script:Executed=$false;$script:Report=[pscustomobject]@{Issues=@()};$script:Publisher='Unrelated Publisher'
            function script:Get-CimInstance {}
            function script:Get-UninstallEntries {[pscustomobject]@{Name='Dell SupportAssist';Publisher=$script:Publisher;Scope='HKLM:';Key='not-an-msi';WindowsInstaller=0;QuietUninstallString='';UninstallString='cmd.exe /c unsafe'}}
            function script:Invoke-Installer {$script:Executed=$true}
        }
        try {
            Throws {Remove-DesktopUtility DellSupportAssist}
            & $module {$script:Publisher='Dell Inc.'}
            Throws {Remove-DesktopUtility DellSupportAssist}
            Assert (!(& $module {$script:Executed})) 'An unsupported uninstaller was executed.'
            Assert ((& $module {$script:Report.Issues[-1].Code}) -eq 'TNO-504') 'Manual action missing.'
            Throws {Get-DesktopQuietCommand ([pscustomobject]@{QuietUninstallString='"C:\Windows\System32\cmd.exe" /c unsafe';Name='fixture'}) Dell}
        } finally {Reset-Engine}
    }
    Test 'Armoury Crate requires the official complete uninstall tool instead of a partial app deletion (mocked)' {
        $module=Get-Module Provisioning
        & $module {
            function script:Get-CimInstance {}
            function script:Get-UninstallEntries {[pscustomobject]@{Name='ARMOURY CRATE Service';Publisher='ASUSTeK COMPUTER INC.'}}
            function script:Get-AppxPackage {}
            function script:Get-AppxProvisionedPackage {}
            function script:Invoke-Installer {throw 'Must not guess silent tool flags'}
        }
        try {
            try {Remove-DesktopUtility ASUSArmouryCrate;throw 'Manual removal not required'} catch {
                Assert ((Get-TinnosErrorCode $_) -eq 'TNO-504' -and $_.Exception.Message.Contains('https://www.asus.com/support/faq/1041654/')) 'Official manual action not provided.'
            }
        } finally {Reset-Engine}
    }
    Test 'Remote Desktop Connection uses the official visible uninstaller without automatic restart or deleting RDP files (mocked)' {
        $module=Get-Module Provisioning
        & $module {
            $script:Removed=$false;$script:Report=[pscustomobject]@{Issues=@();Pending=@()}
            function script:Get-RemoteDesktopConnectionState {[pscustomobject]@{Present=(!$script:Removed);Paths=@()}}
            function script:Get-ItemProperty {[pscustomobject]@{CurrentBuildNumber='26100'}}
            function script:Get-Process {}
            function script:Test-Path {return $true}
            function script:Assert-Publisher {param($Path,$Publisher);if ($Publisher -ne 'Microsoft') {throw 'Wrong publisher'}}
            function script:Invoke-Installer {param($FilePath,$Arguments,$SuccessCodes,[switch]$Interactive);if ($FilePath -notlike '*\System32\mstsc.exe' -or $Arguments -ne '/uninstall' -or !$Interactive) {throw 'Unsupported or hidden uninstall'};$script:Removed=$true;return 0}
            function script:Remove-Item {throw 'Saved RDP files must not be deleted'}
        }
        try {Assert ((Remove-RemoteDesktopConnection).Status -eq 'Removed') 'Remote Desktop Connection removal not verified.'} finally {Reset-Engine}
    }
    Test 'Unsupported Windows and active Remote Desktop client sessions block only the affected removal (mocked)' {
        $module=Get-Module Provisioning
        & $module {
            $script:Build='22000';$script:Executed=$false
            function script:Get-RemoteDesktopConnectionState {[pscustomobject]@{Present=$true;Paths=@()}}
            function script:Get-ItemProperty {[pscustomobject]@{CurrentBuildNumber=$script:Build}}
            function script:Get-Process {[pscustomobject]@{Name='mstsc'}}
            function script:Invoke-Installer {$script:Executed=$true}
        }
        try {
            Throws {Remove-RemoteDesktopConnection}
            & $module {$script:Build='26100'}
            try {Remove-RemoteDesktopConnection;throw 'Active connection was ignored'} catch {Assert ((Get-TinnosErrorCode $_) -eq 'TNO-403') 'Active sessions were not protected.'}
            Assert (!(& $module {$script:Executed})) 'Blocked uninstaller was started.'
        } finally {Reset-Engine}
    }
    Test 'Remaining Remote Desktop binaries are reported as pending instead of removed (mocked)' {
        $module=Get-Module Provisioning
        & $module {
            $script:Report=[pscustomobject]@{Issues=@();Pending=@()}
            function script:Get-RemoteDesktopConnectionState {[pscustomobject]@{Present=$true;Paths=@('mstsc.exe')}}
            function script:Get-ItemProperty {[pscustomobject]@{CurrentBuildNumber='26100'}}
            function script:Get-Process {}
            function script:Test-Path {return $true}
            function script:Assert-Publisher {}
            function script:Invoke-Installer {return 0}
        }
        try {
            Assert ((Remove-RemoteDesktopConnection).Status -eq 'Pending') 'Remaining client reported removed.'
            Assert ((& $module {$script:Report.Pending.Count}) -eq 1 -and (& $module {$script:Report.Issues[0].Code}) -eq 'TNO-504') 'Pending action was not reported.'
        } finally {Reset-Engine}
    }
    Test 'Drive-only selection does not touch Office, Teams, unrelated cleanup or browser defaults (mocked)' {
        $module=Get-Module Provisioning
        & $module {
            $script:Report=[pscustomobject]@{Steps=@();RestorePoint=$null;Errors=@();Issues=@();Applications=@();AppIssues=@();Notes=@()};$script:Trace=@()
            function script:New-DeploymentRestorePoint {$script:Trace+='restore';[pscustomobject]@{Status='Created'}}
            function script:Install-GoogleDrive {$script:Trace+='drive';[pscustomobject]@{Status='Installed'}}
            function script:Install-Office {throw 'Unrequested Office install'}
            function script:Install-GoogleChrome {throw 'Unrequested Chrome install'}
            function script:Remove-TeamsApplications {throw 'Unchecked Teams removal'}
            function script:Invoke-SelectedDebloat {throw 'No removals selected'}
            function script:Set-TeamsPrevention {throw 'Unrequested Office policy'}
            function script:Set-ChromeDefault {throw 'Unrequested Chrome default'}
        }
        try {
            $cfg=$config.PSObject.Copy();$cfg.InstallItems=@('GoogleDrive');$cfg.RemoveItems=@()
            Invoke-DeploymentSteps $cfg $null $null $null 'unused' $work
            Assert ((& $module {$script:Trace -join ','}) -eq 'restore,drive') 'Unexpected mutation outside the selected scope.'
            Assert ((& $module {$script:Report.Applications.Count}) -eq 1 -and (& $module {$script:Report.Issues.Count}) -eq 0) 'Drive-only selection failed.'
        } finally {Reset-Engine}
    }
    Test 'Empty selection performs no restore, install or removal (mocked)' {
        $module=Get-Module Provisioning
        & $module {function script:New-DeploymentRestorePoint {throw 'Empty selection must do nothing'}}
        try {
            $cfg=$config.PSObject.Copy();$cfg.InstallItems=@();$cfg.RemoveItems=@()
            Invoke-DeploymentSteps $cfg $null $null $null 'unused' $work
            Assert ((& $module {$script:Events[-1].Message}) -match 'Nothing selected') 'Empty selection was not explained.'
        } finally {Reset-Engine}
    }
    Test 'Validation ignores unchecked applications and does not claim unchecked Teams removal (mocked)' {
        $module=Get-Module Provisioning
        & $module {function script:Test-Path {return $false}}
        try {
            $cfg=$config.PSObject.Copy();$cfg.InstallItems=@('GoogleDrive');$cfg.RemoveItems=@()
            $office=[pscustomobject]@{Present=$false;Apps=[pscustomobject]@{};ExcludedApps=@()}
            $teams=Empty-Teams;$teams.Packages=@('Teams intentionally kept')
            $policy=[pscustomobject]@{PreventTeamsInstall=0;Errors=@();Conflicts=@()}
            $google=[pscustomobject]@{Chrome=@();Drive=@('GoogleDriveFS.exe')}
            $checks=@(Get-DeploymentChecks $cfg $office $teams $policy $google $work Deploy @())
            Assert (!@($checks | Where-Object {$_.Name -match 'Teams|Office|Word|Excel|Chrome|Outlook'}).Count) 'Unchecked components were validated as requested work.'
            Assert ('GoogleDrive' -in $checks.Name -and (Get-DeploymentStatus $checks @() $false @()) -eq 'Complete') 'Drive-only validation failed.'
        } finally {Reset-Engine}
    }
    Test 'Service startup is changed only after a pending stop reaches Stopped (mocked)' {
        $module=Get-Module Provisioning
        & $module {
            $script:StoppedRequested=$false;$script:Poll=0;$script:Disabled=$false
            function script:Assert-ServicePolicy {}
            function script:Get-Service {[pscustomobject]@{Status='Running'}}
            function script:Get-CimInstance {
                if ($script:StoppedRequested) {$script:Poll++}
                [pscustomobject]@{State=$(if (!$script:StoppedRequested) {'Running'} elseif ($script:Poll -lt 2) {'Stop Pending'} else {'Stopped'});StartMode=$(if ($script:Disabled) {'Disabled'} else {'Auto'})}
            }
            function script:Stop-Service {$script:StoppedRequested=$true}
            function script:Start-Sleep {}
            function script:Set-Service {if ($script:Poll -lt 2) {throw 'Service still stopping'};$script:Disabled=$true}
        }
        try {
            Assert ((Disable-SelectedService WSearch).Status -eq 'Disabled') 'Service stop was not awaited.'
            Assert (@(& $module {$script:Events | Where-Object {$_.Kind -eq 'Progress'}}).Count -gt 0) 'Service stop wait not shown.'
        } finally {Reset-Engine}
    }
    Test 'Selected Copilot cleanup runs again after Office without installing unchecked gear (mocked)' {
        $module=Get-Module Provisioning
        & $module {
            $script:Report=[pscustomobject]@{Steps=@();RestorePoint=$null;Errors=@();Issues=@();Applications=@();AppIssues=@();Notes=@()};$script:Trace=@()
            function script:New-DeploymentRestorePoint {[pscustomobject]@{Status='Created'}}
            function script:Invoke-SelectedDebloat {param($Config);if ('Copilot' -notin $Config.RemoveItems) {throw 'Wrong post-install selection'};$script:Trace+='copilot'}
            function script:Set-TeamsPrevention {}
            function script:Remove-TeamsApplications {throw 'Unchecked Teams removal'}
            function script:Install-Office {$script:Trace+='office';[pscustomobject]@{Status='Installed'}}
            function script:Install-GoogleChrome {throw 'Unchecked Chrome install'}
            function script:Install-GoogleDrive {throw 'Unchecked Drive install'}
        }
        try {
            $cfg=$config.PSObject.Copy();$cfg.InstallItems=@('Office');$cfg.RemoveItems=@('Copilot')
            Invoke-DeploymentSteps $cfg $null $null $null 'unused' $work
            Assert ((& $module {$script:Trace -join ','}) -eq 'copilot,office,copilot') 'Copilot cleanup was not repeated after Office.'
        } finally {Reset-Engine}
    }
    Test 'A service that remains active fails final verification even after an earlier Disabled result (mocked)' {
        $module=Get-Module Provisioning
        & $module {
            function script:Test-Path {return $false}
            function script:Get-CimInstance {[pscustomobject]@{Name='WSearch';StartMode='Disabled';State='Running'}}
        }
        try {
            $cfg=$config.PSObject.Copy();$cfg.InstallItems=@();$cfg.RemoveItems=@('SearchIndexing')
            $office=[pscustomobject]@{Present=$false;Apps=[pscustomobject]@{};ExcludedApps=@()}
            $policy=[pscustomobject]@{PreventTeamsInstall=0;Errors=@();Conflicts=@()}
            $google=[pscustomobject]@{Chrome=@();Drive=@()}
            $apps=@([pscustomobject]@{Name='WSearch';Action='Disable';Status='Disabled'})
            $checks=@(Get-DeploymentChecks $cfg $office (Empty-Teams) $policy $google $work Deploy $apps)
            Assert (!(($checks | Where-Object {$_.Name -eq 'WSearch'}).Pass)) 'Running service reported stopped.'
            Assert ((Get-DeploymentStatus $checks @() $false @()) -eq 'Failed') 'Incomplete service change reported complete.'
        } finally {Reset-Engine}
    }
    $exe=Join-Path $root 'tinnosdebloat-win11.exe'
    $assembly=[Reflection.Assembly]::LoadFile($exe)
    $type=$assembly.GetType('TinnosDebloat.Payload',$true)
    Test 'Portable EXE embeds all current PowerShell sources and defaults' {
        $null=$type.GetMethod('Validate').Invoke($null,@())
        foreach ($file in @('Invoke-Provisioning.ps1','Invoke-UserCleanup.ps1','Provisioning.psm1','Check-OfficeActivation.ps1','config.example.json','error-codes.json','debloat-catalog.json')) {
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
    Test 'Worker logs use English culture and UTF-8 on both redirected streams' {
        $fixture=Join-Path $work 'Invoke-Provisioning.ps1'
        $moduleLiteral=$modulePath.Replace("'","''")
        $body=@'
param($ConfigPath,$Mode,$OutputDirectory)
[Threading.Thread]::CurrentThread.CurrentCulture = 'pt-BR'
[Threading.Thread]::CurrentThread.CurrentUICulture = 'pt-BR'
Import-Module '__MODULE__' -Force -DisableNameChecking
$sample='Vit'+[char]0x00f3+'ria '+[char]0x2014+' '+[char]0x65e5
[Console]::WriteLine([Globalization.CultureInfo]::CurrentCulture.Name)
[Console]::Error.WriteLine([Globalization.CultureInfo]::CurrentUICulture.Name)
[Console]::WriteLine($sample)
[Console]::Error.WriteLine($sample)
'@
        [IO.File]::WriteAllText($fixture,$body.Replace('__MODULE__',$moduleLiteral))
        $command=[TinnosDebloat.Payload]::Command($work,(Join-Path $work 'config.json'),'Audit',(Join-Path $work 'work'))
        Assert ($command.StandardOutputEncoding.WebName -eq 'utf-8' -and $command.StandardErrorEncoding.WebName -eq 'utf-8') 'Output decoder mismatch.'
        $process=New-Object Diagnostics.Process; $process.StartInfo=$command
        try {
            $null=$process.Start(); $stdout=$process.StandardOutput.ReadToEnd(); $stderr=$process.StandardError.ReadToEnd(); $process.WaitForExit()
            $expected='en-US'+[Environment]::NewLine+'Vit'+[char]0x00f3+'ria '+[char]0x2014+' '+[char]0x65e5
            Assert ($process.ExitCode -eq 0 -and $stdout.Trim() -eq $expected -and $stderr.Trim() -eq $expected) ('Language or UTF-8 roundtrip failed: '+$stdout+$stderr)
        } finally {$process.Dispose()}
        Assert ($config.Languages.Count -eq 1 -and $config.Languages[0] -eq 'pt-br') 'Diagnostic culture changed Office language.'
    }
    Test 'Installer waiting emits live elapsed-time heartbeats and accepted exit status using a harmless process' {
        $module=Get-Module Provisioning
        & $module {$script:Report=[pscustomobject]@{Operations=@();RebootRequired=$false}}
        $fixture=Join-Path $work 'harmless-wait.ps1'
        'Start-Sleep -Seconds 6; exit 0' | Set-Content -LiteralPath $fixture
        $result=Invoke-Installer "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$fixture`"" @(0)
        Assert ($result -eq 0) 'Harmless process exit not captured.'
        $events=@(& $module {$script:Events})
        Assert (@($events | Where-Object {$_.Kind -eq 'Progress' -and $_.Message -match 'Elapsed:.*Remaining time: unavailable'}).Count -ge 1) 'No heartbeat during wait.'
        Assert ($events[-1].Kind -eq 'Success') 'Accepted process exit not confirmed.'
        Reset-Engine
    }
    Test 'Interface separates installation and removal, labels every action and serializes exact selections' {
        Add-Type -AssemblyName System.Windows.Forms
        $form=$assembly.GetType('TinnosDebloat.Ui').GetMethod('Create').Invoke($null,@())
        function Walk-Controls($Control) { foreach ($child in $Control.Controls) {$child; Walk-Controls $child} }
        try {
            $controls=@(Walk-Controls $form)
            Assert ($form.Text -eq 'TinnosDebloat-Win11') 'Unexpected product name.'
            Assert (!@($controls | Where-Object {$_ -is [Windows.Forms.CheckBox] -or $_ -is [Windows.Forms.RadioButton]}).Count) 'Old app-action or Office toggles remain.'
            Assert ('EQUIP GEAR' -in $controls.Text -and 'REMOVE WASPS' -in $controls.Text) 'Action headings missing.'
            $gear=$form.Controls.Find('installList',$true)[0]
            Assert ($gear.Items.Count -eq 3 -and $gear.CheckedItems.Count -eq 3) 'Equipment choices missing.'
            $choices=$form.Controls.Find('removalList',$true)[0]
            Assert ($choices.Items.Count -eq (Get-Content (Join-Path $root 'debloat-catalog.json') -Raw | ConvertFrom-Json).Count) 'Removal choices differ from the engine catalog.'
            Assert ($choices.CheckedItems.Count -lt $choices.Items.Count) 'High impact services must require selection.'
            $choices.SetItemChecked(0,$false)
            Assert (!$choices.GetItemChecked(0)) 'Unchecked Teams cannot be kept.'
            foreach($item in $choices.Items) {Assert ($item.ToString() -match '^(Uninstall|Deactivate|Hide|Enable) ') ('Ambiguous action label: '+$item)}
            Assert ($form.Controls.Find('jadePendant',$true).Count -eq 1) 'Jade reference missing.'
            for($i=0;$i -lt $choices.Items.Count;$i++) {$choices.SetItemChecked($i,$false)}
            for($i=0;$i -lt $gear.Items.Count;$i++) {$gear.SetItemChecked($i,$false)}
            $gear.SetItemChecked(0,$true)
            $selected=$form.SelectedConfiguration() | ConvertFrom-Json
            Assert ($selected.InstallItems.Count -eq 1 -and $selected.InstallItems[0] -eq 'GoogleDrive' -and $selected.RemoveItems.Count -eq 0) 'Unselected actions added to the configuration.'
            Assert ($null -eq $selected.PSObject.Properties['IncludeAccess'] -and $null -eq $selected.PSObject.Properties['AppMode']) 'Removed configuration options still generated.'
            Assert ($form.Controls.Find('detailTabs',$true)[0].TabPages.Count -eq 2) 'Results tab remains.'
            $actions=@($controls | Where-Object {$_ -is [Windows.Forms.Button]})
            Assert ($actions.Count -eq 2 -and 'Start' -in $actions.Text -and 'Details' -in $actions.Text) 'Unexpected action buttons.'
            Assert (!@($controls | Where-Object {($_ -is [Windows.Forms.CheckBox] -or $_ -is [Windows.Forms.Button]) -and $_.Text -match 'PT-BR|English|Audit|reports'}).Count) 'Removed control still exists.'
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
            $activity=$form.Controls.Find('liveLog',$true)[0].Text
            Assert ($activity.Contains('Chrome: Failed') -and $activity.Contains('Office activation: Deferred')) 'Final summary missing.'
            $errors=$form.Controls.Find('errorDetails',$true)[0].Text
            Assert ($errors.Contains('TNO-400') -and $errors.Contains('1603') -and $errors.Contains('Check vendor exit')) 'Error evidence or recovery action missing.'
            Throws {$null=[TinnosDebloat.ResultChannel]::Decode('TINNOS_RESULT:invalid!')}
            Throws {$form.ApplyResult('{}')}
        } finally {$form.Dispose()}
    }
    Test 'Live errors and success updates appear before completion and final errors are deduplicated' {
        $form=[TinnosDebloat.Ui]::Create()
        try {
            $issue=@{Code='TNO-500';Title='Removal incomplete';Message='App is busy';Stage='Paint';Severity='Error';Action='Close Paint and retry';NativeCode=5}
            $event=@{Kind='Issue';Task='Paint';Message='App is busy';Issue=$issue}|ConvertTo-Json -Depth 6 -Compress
            $form.ApplyEvent($event)
            Assert ($form.Controls.Find('errorDetails',$true)[0].Text.Contains('Close Paint and retry')) 'Live error missing before final report.'
            $form.ApplyEvent('{"Kind":"Progress","Task":"Google Drive","Message":"Elapsed: 00:05. Remaining time: unavailable."}')
            Assert ($form.Controls.Find('currentTask',$true)[0].Text.Contains('Google Drive')) 'Status is stale.'
            $form.ApplyEvent('{"Kind":"Success","Task":"Chrome","Message":"Installed"}')
            Assert ($form.Controls.Find('liveLog',$true)[0].Text.Contains('OK - Chrome: Installed')) 'Success message missing.'
            $form.ApplyResult((@{Status='CompletedWithIssues';Issues=@($issue)}|ConvertTo-Json -Depth 6 -Compress))
            $text=$form.Controls.Find('errorDetails',$true)[0].Text
            Assert ([regex]::Matches($text,'\[TNO-500\]').Count -eq 1) 'Live error duplicated or lost on completion.'
        } finally {$form.Dispose()}
    }
    Test 'GUI startup works without console handles and startup failures reach the error handler' {
        $probe=Join-Path $work 'StartupProbe.exe'
        $compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
        $arguments=@('/nologo','/target:winexe','/platform:x64','/main:TinnosDebloat.StartupProbe',"/out:$probe",'/reference:System.Windows.Forms.dll','/reference:System.Drawing.dll','/reference:System.Web.Extensions.dll')
        foreach($file in [TinnosDebloat.Payload]::Files) {$arguments+="/resource:$root\$file,Payload.$file"}
        $arguments+=(Join-Path $root 'src\Program.cs');$arguments+=(Join-Path $root 'tests\StartupProbe.cs')
        & $compiler @arguments
        Assert ($LASTEXITCODE -eq 0) 'Startup fixture compilation failed.'
        foreach($mode in @('normal','failure')) {
            $evidence=Join-Path $work ("startup-$mode.txt")
            $start=New-Object Diagnostics.ProcessStartInfo
            $start.FileName=$probe;$start.Arguments=([TinnosDebloat.Payload]::Quote($evidence))+$(if ($mode -eq 'failure') {' --failure'} else {''})
            $start.UseShellExecute=$false;$start.CreateNoWindow=$true
            $process=New-Object Diagnostics.Process;$process.StartInfo=$start
            try {
                $null=$process.Start()
                if (!$process.WaitForExit(10000)) {$process.Kill();throw 'Startup fixture did not open and close its invisible test window.'}
                Assert ($process.ExitCode -eq 0 -and [IO.File]::ReadAllText($evidence) -eq 'PASS') ('Startup fixture failed: '+$mode)
            } finally {$process.Dispose()}
        }
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
