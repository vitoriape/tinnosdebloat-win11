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
