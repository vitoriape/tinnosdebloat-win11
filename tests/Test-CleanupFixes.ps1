# Dot-sourced by Run-Tests.ps1. Only mocked operations; no workstation changes.
Test 'OneNote is excluded by ODT and not required for Office validation' {
    $xml=New-OfficeConfiguration $config $null (Join-Path $work 'no-onenote.xml')
    Assert ('OneNote' -in @($xml.Configuration.Add.Product.ExcludeApp | ForEach-Object {$_.ID})) 'OneNote exclusion missing.'
    Assert (!(& (Get-Module Provisioning) {$script:RequiredApps.Contains('OneNote')})) 'OneNote is still required.'
}
Test 'New cleanup selections cover exact companion, Dell, OneDrive and WebAdvisor products' {
    $catalog=Get-Content -LiteralPath (Join-Path $root 'debloat-catalog.json') -Raw | ConvertFrom-Json
    foreach ($id in @('DellConnectedServiceDelivery','DellOptimizer','Microsoft365Companions','OneDrive','McAfeeWebAdvisor','RemoteDesktopConnection','AccentGold','BackgroundMoss')) {
        Assert ($id -in $config.RemoveItems) ('Missing default: '+$id)
    }
    Assert ('Microsoft.M365Companions' -in @(($catalog | Where-Object Id -eq 'Microsoft365Companions').Packages)) 'Wrong companion package.'
    Assert ('Dell Connected Service Delivery Subagent' -in @(($catalog | Where-Object Id -eq 'DellConnectedServiceDelivery').DesktopProducts)) 'Dell subagent missing.'
    Assert ('WebAdvisor da McAfee' -in @(($catalog | Where-Object Id -eq 'McAfeeWebAdvisor').DesktopProducts)) 'Localized WebAdvisor missing.'
    Assert (!@($catalog | ForEach-Object {$_.Packages} | Where-Object {$_ -match '[*?]'}).Count) 'Broad package removal introduced.'
}
Test 'Gold and moss settings use fixed RGB values without wallpaper downloads' {
    $module=Get-Module Provisioning
    $gold=@(Get-DesktopPreferenceValues AccentGold)
    $moss=@(Get-DesktopPreferenceValues BackgroundMoss)
    Assert (($gold | Where-Object Name -eq 'AccentColor').Value -eq [BitConverter]::ToInt32([byte[]](255,185,0,255),0)) 'Wrong gold color.'
    Assert (($moss | Where-Object Name -eq 'Background').Value -eq '72 104 96') 'Wrong moss color.'
    Assert (($moss | Where-Object Name -eq 'Wallpaper').Value -ceq '') 'Old image was not cleared.'
    Assert (($moss | Where-Object Name -eq 'BackgroundType').Value -eq 1) 'Background is not solid.'
}
Test 'Appearance policy conflicts are preserved without blanket domain blocking (mocked)' {
    $module=Get-Module Provisioning
    & $module {
        $script:Conflict=$true
        function script:Test-Path {param($LiteralPath);return ($script:Conflict -and $LiteralPath -like '*Microsoft\Dsh')}
        function script:Get-ItemProperty {[pscustomobject]@{AllowNewsAndInterests=1}}
        function script:Get-CimInstance {throw 'Domain membership is not a blanket preference restriction'}
        function script:New-ItemProperty {throw 'Do not overwrite policy'}
    }
    try {
        try {Assert-LocalDesktopSettings TaskbarWidgets 'Registry::HKEY_USERS\fixture';throw 'Conflict was ignored'} catch {Assert ((Get-TinnosErrorCode $_) -eq 'TNO-202') 'Policy conflict not identified.'}
        & $module {$script:Conflict=$false}
        Assert-LocalDesktopSettings TaskbarWidgets 'Registry::HKEY_USERS\fixture'
    } finally {Reset-Engine}
}
Test 'Desktop final verification re-reads preferences rather than trusting prior success (mocked)' {
    $module=Get-Module Provisioning
    & $module {
        $script:Actual=1
        function script:Get-CimInstance {[pscustomobject]@{SID='fixture';Special=$false}}
        function script:Use-ProfileHive {param($Profile,$Action); & $Action 'Registry::HKEY_USERS\fixture'}
        function script:Assert-LocalDesktopSettings {}
        function script:Test-Path {return $true}
        function script:Get-ItemProperty {[pscustomobject]@{SearchboxTaskbarMode=$script:Actual}}
    }
    try {
        Assert (!(Test-DesktopSettingState TaskbarSearch)) 'Changed-back value passed.'
        & $module {$script:Actual=0}
        Assert (Test-DesktopSettingState TaskbarSearch) 'Correct value failed.'
    } finally {Reset-Engine}
}
Test 'Registered Dell and WebAdvisor uninstallers can show vendor prompts when no quiet command exists (mocked)' {
    $module=Get-Module Provisioning
    & $module {
        function script:Get-Item {[pscustomobject]@{Attributes=[IO.FileAttributes]::Normal}}
        function script:Assert-Publisher {}
    }
    try {
        foreach ($vendor in @('Dell','McAfee')) {
            $entry=[pscustomobject]@{Name='fixture';QuietUninstallString='';UninstallString=('"'+$env:ProgramFiles+'\'+$vendor+'\Uninstall.exe" /uninstall')}
            Assert ((Get-DesktopQuietCommand $entry $vendor).Interactive) 'Vendor prompt fallback missing.'
        }
        $noArgs=[pscustomobject]@{Name='WebAdvisor by McAfee';QuietUninstallString='';UninstallString=('"'+$env:ProgramFiles+'\McAfee\Uninstaller.exe"')}
        $command=Get-DesktopQuietCommand $noArgs McAfee
        Assert ($command.Interactive -and !$command.Arguments) 'A registered no-argument uninstaller was rejected.'
        Throws {Get-DesktopQuietCommand ([pscustomobject]@{Name='fixture';QuietUninstallString='';UninstallString='cmd.exe /c remove'}) Dell}
    } finally {Reset-Engine}
}
Test 'Per-user OneDrive is queued for the owning user instead of elevated execution (mocked)' {
    $module=Get-Module Provisioning
    & $module {
        $script:Owner='';$script:Report=[pscustomobject]@{Pending=@();Issues=@()}
        function script:Get-DesktopUtilityInventory {
            [pscustomobject]@{Definition=[pscustomobject]@{Vendor='Microsoft'};Entries=@([pscustomobject]@{Name='Microsoft OneDrive';Scope='Registry::HKEY_USERS\fixture';OwnerProfile=[pscustomobject]@{SID='fixture'}});Packages=@();Provisioned=@();Errors=@()}
        }
        function script:Register-UserCleanup {param($Profile,$Directory,$NativeItem);if ($NativeItem -ne 'OneDrive') {throw 'Wrong native item'};$script:Owner=$Profile.SID}
        function script:Invoke-Installer {throw 'Per-user uninstaller must not run in admin context'}
    }
    try {
        Assert ((Remove-DesktopUtility OneDrive $work).Status -eq 'Pending') 'Queued user cleanup incorrectly reported removed.'
        Assert ((& $module {$script:Owner}) -eq 'fixture') 'Wrong account queued.'
    } finally {Reset-Engine}
}
Test 'User-only OneDrive inventory reads HKCU without loading other profiles (mocked)' {
    $module=Get-Module Provisioning
    & $module {
        function script:Get-UninstallEntries {param($Hive);if ($Hive -ne 'HKCU:') {throw 'Wrong hive'};[pscustomobject]@{Name='Microsoft OneDrive';Scope='HKCU:'}}
        function script:Get-CimInstance {throw 'User worker must not inspect other profiles'}
    }
    try {Assert ((Get-DesktopUtilityInventory OneDrive -CurrentUserOnly).Entries.Count -eq 1) 'User inventory missing.'} finally {Reset-Engine}
}
Test 'Native cleanup task uses the owning interactive limited token (mocked)' {
    $module=Get-Module Provisioning
    & $module {
        $script:TaskArgs='';$script:Report=[pscustomobject]@{Pending=@()}
        function script:Initialize-ProtectedDirectory {param($Path);$null=New-Item -Path $Path -ItemType Directory -Force}
        function script:New-ScheduledTaskAction {param($Execute,$Argument);$script:TaskArgs=$Argument;return [pscustomobject]@{}}
        function script:New-ScheduledTaskPrincipal {param($UserId,$LogonType,$RunLevel);if ($UserId -ne 'fixture' -or $LogonType -ne 'Interactive' -or $RunLevel -ne 'Limited') {throw 'Incorrect user task principal'};return [pscustomobject]@{}}
        function script:New-ScheduledTaskTrigger {return [pscustomobject]@{}}
        function script:New-ScheduledTaskSettingsSet {return [pscustomobject]@{}}
        function script:Register-ScheduledTask {}
        function script:Start-ScheduledTask {throw 'Unloaded profile task must wait for sign-in'}
    }
    try {
        Register-UserCleanup ([pscustomobject]@{SID='fixture';Loaded=$false}) $work -NativeItem OneDrive
        Assert ((& $module {$script:TaskArgs}).Contains('-NativeItem OneDrive')) 'User task selection missing.'
    } finally {Reset-Engine}
}
Test 'McAfee WebAdvisor MSI removal checks publisher and absence (mocked)' {
    $module=Get-Module Provisioning
    & $module {
        $script:Removed=$false;$script:Report=[pscustomobject]@{Issues=@()}
        function script:Get-CimInstance {}
        function script:Get-UninstallEntries {if (!$script:Removed) {[pscustomobject]@{Name='WebAdvisor by McAfee';Publisher='McAfee, LLC';Scope='HKLM:';Key='{12345678-1234-1234-1234-123456789ABC}';WindowsInstaller=1}}}
        function script:Invoke-Installer {param($FilePath,$Arguments);if ($Arguments -notlike '/x * /qn /norestart') {throw 'Wrong MSI mode'};$script:Removed=$true;return 0}
    }
    try {Assert ((Remove-DesktopUtility McAfeeWebAdvisor).Status -eq 'Removed') 'WebAdvisor removal not verified.'} finally {Reset-Engine}
}
Test 'Search UI blocking verifies policy, requires restart and rejects unsupported systems (mocked)' {
    $module=Get-Module Provisioning
    try {
        & $module {
            $script:Report=[pscustomobject]@{RebootRequired=$false}
            $script:SearchValue=0
            function script:Assert-SearchUiSupport {}
            function script:Set-VerifiedDword($Path,$Name,$Value,[switch]$Policy) {
                if ($Name -ne 'DisableSearch' -or $Value -ne 1 -or !$Policy) {throw 'Wrong Search policy'}
                $script:SearchValue=$Value
            }
            function script:Test-Path { $true }
            function script:Get-ItemProperty {[pscustomobject]@{DisableSearch=$script:SearchValue}}
        }
        $result=Set-SelectedDesktopSetting DisableSearchUI
        Assert ($result.Status -eq 'Configured' -and (Test-DesktopSettingState DisableSearchUI)) 'Search UI policy not verified.'
        Assert (& $module {$script:Report.RebootRequired}) 'Restart requirement lost.'
        & $module {$script:SearchValue=0}
        Assert (!(Test-DesktopSettingState DisableSearchUI)) 'Reverted Search policy passed.'
        & $module {function script:Assert-SearchUiSupport {throw 'Unsupported Windows'}}
        Throws {Set-SelectedDesktopSetting DisableSearchUI}
    } finally {Reset-Engine}
}
Test 'Bing and Media Player defaults remove exact installed and provisioned packages and reject leftovers (mocked)' {
    $catalog=Get-Content -LiteralPath (Join-Path $root 'debloat-catalog.json') -Raw | ConvertFrom-Json
    foreach ($pair in @(@('Bing','Microsoft.BingSearch'),@('MediaPlayer','Microsoft.ZuneMusic'))) {
        Assert ($pair[0] -in $config.RemoveItems) 'New app missing from defaults.'
        Assert (@(($catalog | Where-Object Id -eq $pair[0]).Packages).Count -eq 1 -and ($catalog | Where-Object Id -eq $pair[0]).Packages[0] -eq $pair[1]) 'Wrong exact package mapping.'
        $module=Get-Module Provisioning
        try {
            & $module {
                param($Name)
                $script:FixtureName=$Name; $script:AppGone=$false; $script:ProvisionGone=$false; $script:KeepApp=$false; $script:BackedUp=$false
                $script:Report=[pscustomobject]@{RebootRequired=$false;Issues=@()}
                function script:Get-AppxPackage {
                    if (!$script:AppGone) {[pscustomobject]@{Name=$script:FixtureName;PackageFullName='fixture-app';IsFramework=$false;NonRemovable=$false}}
                    [pscustomobject]@{Name='Unrelated.App';PackageFullName='unrelated';IsFramework=$false;NonRemovable=$false}
                }
                function script:Get-AppxProvisionedPackage {if (!$script:ProvisionGone) {[pscustomobject]@{DisplayName=$script:FixtureName;PackageName='fixture-provision'}}}
                function script:Backup-SelectedAppData {$script:BackedUp=$true}
                function script:Remove-AppxPackage {
                    param($Package,[switch]$AllUsers)
                    if (!$script:BackedUp -or $Package -ne 'fixture-app' -or !$AllUsers) {throw 'Unsafe app removal'}
                    $script:AppGone=!$script:KeepApp
                }
                function script:Remove-AppxProvisionedPackage {
                    param([switch]$Online,$PackageName,[switch]$AllUsers)
                    if ($PackageName -ne 'fixture-provision' -or !$Online -or !$AllUsers) {throw 'Unsafe provisioning removal'}
                    $script:ProvisionGone=$true; [pscustomobject]@{RestartNeeded=$false}
                }
            } $pair[1]
            Assert ((Remove-SelectedApp $pair[1] $work).Status -eq 'Removed') 'App removal failed.'
            & $module {$script:AppGone=$false;$script:KeepApp=$true}
            Throws {Remove-SelectedApp $pair[1] $work}
        } finally {Reset-Engine}
    }
}
Test 'Optional ASUS, AMD and CryptSvc actions use exact service names and are never selected by default' {
    $catalog=Get-Content -LiteralPath (Join-Path $root 'debloat-catalog.json') -Raw | ConvertFrom-Json
    $expected=@{
        ASUSSystemDiagnosis='ASUSSystemDiagnosis'; ASUSSystemAnalysis='ASUSSystemAnalysis'
        ASUSSwitchService='ASUSSwitch'; ASUSSoftwareManagerService='ASUSSoftwareManager'
        ASUSOptimizationService='ASUSOptimization'; ASUSAppService='ASUSAppService'
        AMDExternalEvents='AMD External Events Utility'; AMDCrashDefender='AMD Crash Defender Service'
        CryptographicServices='CryptSvc'
    }
    foreach ($id in $expected.Keys) {
        $item=$catalog | Where-Object Id -eq $id
        Assert ($null -ne $item -and $item.Services.Count -eq 1 -and $item.Services[0] -ceq $expected[$id]) ('Wrong service: '+$id)
        Assert (!$item.DefaultSelected -and $id -notin $config.RemoveItems) ('Unsafe default: '+$id)
    }
    $form=[TinnosDebloat.Ui]::Create()
    try {
        $form.Controls.Find('deviceType',$true)[0].SelectedIndex=1
        $form.Controls.Find('manufacturer',$true)[0].SelectedIndex=1
        $selected=$form.SelectedConfiguration() | ConvertFrom-Json
        foreach ($id in $expected.Keys) {Assert ($id -notin $selected.RemoveItems) ('GUI preselected optional service: '+$id)}
        $choices=$form.Controls.Find('removalList',$true)[0]
        for($i=0;$i -lt $choices.Items.Count;$i++) {if($choices.Items[$i].ToString() -like 'Deactivate ASUS System Diagnosis*') {$choices.SetItemChecked($i,$true)}}
        $selected=$form.SelectedConfiguration() | ConvertFrom-Json
        Assert ('ASUSSystemDiagnosis' -in $selected.RemoveItems) 'Explicit service selection lost.'
        $form.Controls.Find('deviceType',$true)[0].SelectedIndex=0
        $selected=$form.SelectedConfiguration() | ConvertFrom-Json
        Assert ('ASUSSystemDiagnosis' -notin $selected.RemoveItems) 'ASUS service leaked to desktop.'
    } finally {$form.Dispose()}
}
Test 'Optional services stop and disable with verification, or report absent without changes (mocked)' {
    $names=@('ASUSSystemDiagnosis','ASUSSystemAnalysis','ASUSSwitch','ASUSSoftwareManager','ASUSOptimization','ASUSAppService','AMD External Events Utility','AMD Crash Defender Service','CryptSvc')
    foreach($name in $names) {
        $module=Get-Module Provisioning
        try {
            & $module {
                $script:Stopped=$false; $script:Disabled=$false; $script:Missing=$false
                function script:Assert-ServicePolicy {}
                function script:Get-CimInstance {
                    if (!$script:Missing) {[pscustomobject]@{State=$(if($script:Stopped){'Stopped'}else{'Running'});StartMode=$(if($script:Disabled){'Disabled'}else{'Auto'})}}
                }
                function script:Get-Service {[pscustomobject]@{Status='Running'}}
                function script:Stop-Service {param($Name,[switch]$Force);if($Force){throw 'Forced stop'};$script:Stopped=$true}
                function script:Set-Service {param($Name,$StartupType);if(!$script:Stopped -or $StartupType -ne 'Disabled'){throw 'Wrong order'};$script:Disabled=$true}
            }
            Assert ((Disable-SelectedService $name).Status -eq 'Disabled') ('Service not verified: '+$name)
            & $module {$script:Missing=$true;$script:Stopped=$false;$script:Disabled=$false}
            Assert ((Disable-SelectedService $name).Status -eq 'NotPresent') 'Missing service not handled.'
            Assert (!(& $module {$script:Stopped -or $script:Disabled})) 'Missing service was changed.'
        } finally {Reset-Engine}
    }
}
Test 'Personalization pickers serialize independent image selections and clear without applying them' {
    $form=[TinnosDebloat.Ui]::Create()
    try {
        $gear=$form.Controls.Find('installList',$true)[0]
        Assert ($gear.Items[3].ToString() -eq 'Install TranslucentTB' -and !$gear.GetItemChecked(3)) 'TranslucentTB option/default missing.'
        $gear.SetItemChecked(3,$true)
        $form.SetImageSelections('C:\Images\desktop.png','C:\Images\lock.jpg')
        $selected=$form.SelectedConfiguration() | ConvertFrom-Json
        Assert ('TranslucentTB' -in $selected.InstallItems -and $selected.WallpaperPath -eq 'C:\Images\desktop.png' -and $selected.LockScreenPath -eq 'C:\Images\lock.jpg') 'Selections not serialized.'
        $clear=$form.Controls.Find('clearImagesButton',$true)[0]
        $clear.GetType().GetMethod('OnClick',[Reflection.BindingFlags]'Instance,NonPublic').Invoke($clear,@([EventArgs]::Empty)) | Out-Null
        $selected=$form.SelectedConfiguration() | ConvertFrom-Json
        Assert ($null -eq $selected.PSObject.Properties['WallpaperPath'] -and $null -eq $selected.PSObject.Properties['LockScreenPath']) 'Cleared images would still apply.'
    } finally {$form.Dispose()}
}
Test 'Image config accepts existing image paths and rejects missing, nonimage and nonstring values' {
    $file=Join-Path $work 'config-image.png'
    [IO.File]::WriteAllText($file,'fixture')
    $path=Join-Path $work 'images-config.json'
    @{InstallItems=@('TranslucentTB');RemoveItems=@();WallpaperPath=$file;LockScreenPath=$file} | ConvertTo-Json | Set-Content -LiteralPath $path
    $cfg=Read-DeploymentConfig $path
    Assert ($cfg.WallpaperPath -eq $file -and $cfg.LockScreenPath -eq $file -and 'TranslucentTB' -in $cfg.InstallItems) 'Image config rejected.'
    Throws {New-PersonalizationImage $file $work}
    foreach($invalid in @('missing.jpg',17,$path)) {
        @{WallpaperPath=$invalid} | ConvertTo-Json | Set-Content -LiteralPath $path
        Throws {Read-DeploymentConfig $path}
    }
}
Test 'Selected images are decoded to durable JPEG assets without changing the source' {
    Add-Type -AssemblyName System.Drawing
    $file=Join-Path $work 'chosen-wallpaper.png';$bitmap=New-Object Drawing.Bitmap(8,8)
    try {$bitmap.Save($file,[Drawing.Imaging.ImageFormat]::Png)} finally {$bitmap.Dispose()}
    $hash=(Get-FileHash -LiteralPath $file).Hash
    $asset=New-PersonalizationImage $file $work
    Assert ((Test-Path -LiteralPath $asset) -and [IO.Path]::GetExtension($asset) -eq '.jpg') 'Persistent image not created.'
    Assert ((Get-FileHash -LiteralPath $file).Hash -eq $hash) 'Source image changed.'
}
Test 'Image-only run passes restore gate and applies exactly the chosen images (mocked)' {
    $module=Get-Module Provisioning
    try {
        & $module {
            $script:Report=[pscustomobject]@{Steps=@();RestorePoint=$null};$script:Images=@()
            function script:New-DeploymentRestorePoint {[pscustomobject]@{Status='Created'}}
            function script:Invoke-MaintenanceStep($Name,$Operation,$ErrorCode) {& $Operation;return $true}
            function script:Invoke-ApplicationStep($Name,$Action,$Operation) {$null=& $Operation}
            function script:Set-SelectedImage($Kind,$Path,$Directory) {$script:Images+=($Kind+':'+$Path);[pscustomobject]@{Status='Configured'}}
            function script:Install-Office {throw 'Office should not execute'}
            function script:Install-TranslucentTB {throw 'TranslucentTB should not execute'}
        }
        $cfg=[pscustomobject]@{AppMode='Install';InstallItems=@();RemoveItems=@();WallpaperPath='wall.png';LockScreenPath='lock.png'}
        Invoke-DeploymentSteps $cfg $null $null $null '' $work
        Assert ((& $module {$script:Images -join ','}) -eq 'Wallpaper:wall.png,LockScreen:lock.png') 'Images missing or unrequested apps ran.'
    } finally {Reset-Engine}
}
Test 'Image final verification re-reads current state and managed images block local mutation (mocked)' {
    $module=Get-Module Provisioning
    try {
        & $module {
            $script:ImageValue='selected.jpg'
            function script:Assert-ImagePolicy {}
            function script:Test-Path {$true}
            function script:Get-ItemProperty {[pscustomobject]@{Wallpaper=$script:ImageValue}}
            function script:Get-LockScreenImageHash {$script:ImageValue}
            function script:Get-FileHash {[pscustomobject]@{Hash='selected.jpg'}}
        }
        Assert (Test-SelectedImage Wallpaper 'selected.jpg') 'Matching wallpaper rejected.'
        Assert (Test-SelectedImage LockScreen 'selected.jpg') 'Matching lock screen rejected.'
        & $module {$script:ImageValue='other.jpg'}
        Assert (!(Test-SelectedImage Wallpaper 'selected.jpg') -and !(Test-SelectedImage LockScreen 'selected.jpg')) 'Reverted image accepted.'
        & $module {
            $script:Copied=$false
            function script:Assert-ImagePolicy {throw 'Managed image'}
            function script:New-PersonalizationImage {$script:Copied=$true}
        }
        Throws {Set-SelectedImage LockScreen 'selected.jpg' $work}
        Assert (!(& $module {$script:Copied})) 'Policy block happened after mutation.'
    } finally {Reset-Engine}
}
Test 'TranslucentTB uses verified App Installer and exact Store identity, verifies installed package (mocked)' {
    $module=Get-Module Provisioning
    try {
        & $module {
            $script:Installed=$false;$script:KeepMissing=$false;$script:SignatureChecked=$false
            function script:Get-TranslucentTBPackage {if($script:Installed){[pscustomobject]@{Name='28017CharlesMilette.TranslucentTB'}}}
            function script:Get-AppxPackage {[pscustomobject]@{InstallLocation='C:\Protected-AppInstaller'}}
            function script:Assert-Publisher($Path,$Publisher) {
                if($Path -notlike '*\winget.exe' -or $Publisher -ne 'Microsoft'){throw 'Wrong tool'};$script:SignatureChecked=$true
            }
            function script:Invoke-Installer($FilePath,$Arguments,$SuccessCodes) {
                if(!$script:SignatureChecked -or $Arguments -notmatch '9PF4KZ2VN4W9 --source msstore --exact'){throw 'Untrusted install source'}
                $script:Installed=!$script:KeepMissing;0
            }
        }
        Assert ((Install-TranslucentTB $work).Status -eq 'Installed') 'Installation did not verify.'
        Assert ((Install-TranslucentTB $work).Status -eq 'AlreadyInstalled') 'Existing install not reused.'
        & $module {$script:Installed=$false;$script:KeepMissing=$true}
        Throws {Install-TranslucentTB $work}
    } finally {Reset-Engine}
}
Test 'TranslucentTB download-only validates the official manifest and never installs it (mocked)' {
    $module=Get-Module Provisioning
    try {
        & $module {
            $script:WrongManifest=$false
            function script:Invoke-WebRequest($Uri,$OutFile) {
                if($Uri -ne 'https://github.com/TranslucentTB/TranslucentTB/releases/latest/download/TranslucentTB.appinstaller'){throw 'Wrong source'}
                $name=if($script:WrongManifest){'Unrelated.App'}else{'28017CharlesMilette.TranslucentTB'}
                [IO.File]::WriteAllText($OutFile,('<AppInstaller><MainBundle Name="'+$name+'" Uri="https://github.com/TranslucentTB/TranslucentTB/releases/download/2026.2/bundle.msixbundle" /></AppInstaller>'))
            }
            function script:Invoke-Installer {throw 'Download-only attempted installation'}
        }
        Assert ((Install-TranslucentTB $work -DownloadOnly).Status -eq 'Downloaded') 'Manifest download failed.'
        & $module {$script:WrongManifest=$true}
        Throws {Install-TranslucentTB $work -DownloadOnly}
        Assert (!(Test-Path -LiteralPath (Join-Path $work 'TranslucentTB.appinstaller'))) 'Invalid manifest retained.'
    } finally {Reset-Engine}
}
Test 'Empty Start layout is optional, preserves apps and fails on conflicting policy (mocked)' {
    $catalog=Get-Content -LiteralPath (Join-Path $root 'debloat-catalog.json') -Raw | ConvertFrom-Json
    $item=$catalog | Where-Object Id -eq EmptyStartMenu
    Assert (!$item.DefaultSelected -and $item.Packages.Count -eq 0 -and $item.Services.Count -eq 0) 'Start option removes apps or is automatic.'
    $values=@(Get-DesktopPreferenceValues EmptyStartMenu)
    Assert (($values | Where-Object Name -eq ConfigureStartPins).Value -ceq '{"pinnedList":[]}') 'Pins not cleared.'
    Assert (($values | Where-Object Name -eq HideRecommendedSection).Value -eq 1 -and ($values | Where-Object Name -eq NoStartMenuMorePrograms).Value -eq 1) 'Start sections not hidden.'
    $module=Get-Module Provisioning
    try {
        & $module {
            function script:Assert-StartMenuSupport {}
            function script:Test-Path {$true}
            function script:Get-ItemProperty {[pscustomobject]@{HideRecommendedSection=0}}
        }
        Throws {Assert-LocalDesktopSettings EmptyStartMenu 'HKCU:'}
        & $module {function script:Assert-StartMenuSupport {throw 'Unsupported Windows'}}
        Throws {Assert-LocalDesktopSettings EmptyStartMenu 'HKCU:'}
    } finally {Reset-Engine}
}
