#Requires -Version 5.1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
# Also applies to direct module use and the per-user cleanup/activation helpers.
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('en-US')
[Threading.Thread]::CurrentThread.CurrentUICulture = [Globalization.CultureInfo]::GetCultureInfo('en-US')
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$OutputEncoding = [Console]::OutputEncoding
$script:ModuleRoot = $PSScriptRoot
$script:OfficePolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\Office\16.0\common\officeupdate'
$script:BrowserPolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
$script:TeamNames = @('MSTeams', 'MicrosoftTeams')
$script:RequiredApps = [ordered]@{ Word='WINWORD.EXE'; Excel='EXCEL.EXE'; PowerPoint='POWERPNT.EXE'; OneNote='ONENOTE.EXE' }
$script:Report = $null
$script:DebloatCatalog = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'debloat-catalog.json')) | ConvertFrom-Json
$script:ErrorCatalog = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'error-codes.json')) | ConvertFrom-Json

function New-TinnosError([string]$Code, [string]$Message, $NativeCode = $null) {
    $exception = New-Object InvalidOperationException($Message)
    $exception.Data['TinnosCode'] = $Code
    if ($null -ne $NativeCode) { $exception.Data['NativeCode'] = $NativeCode }
    return $exception
}

function Get-TinnosErrorCode($ErrorRecord, [string]$Default = 'TNO-900') {
    $exception = if ($ErrorRecord -is [Exception]) { $ErrorRecord } else { $ErrorRecord.Exception }
    while ($null -ne $exception) {
        if ($exception.Data.Contains('TinnosCode')) { return [string]$exception.Data['TinnosCode'] }
        if ($exception -is [Net.WebException]) {
            if ($exception.Status -in @([Net.WebExceptionStatus]::NameResolutionFailure,[Net.WebExceptionStatus]::ProxyNameResolutionFailure)) { return 'TNO-300' }
            if ($exception.Status -eq [Net.WebExceptionStatus]::Timeout) { return 'TNO-302' }
            return 'TNO-301'
        }
        if ($exception -is [UnauthorizedAccessException] -or $exception -is [IO.IOException]) { return 'TNO-104' }
        $exception = $exception.InnerException
    }
    return $Default
}

function New-DeploymentIssue([string]$Code, [string]$Message, [string]$Stage, [string]$Severity = 'Error', $ErrorRecord = $null) {
    if ($null -ne $ErrorRecord) { $Code = Get-TinnosErrorCode $ErrorRecord $Code }
    $entry = $script:ErrorCatalog.PSObject.Properties[$Code]
    if ($null -eq $entry) { $Code = 'TNO-900'; $entry = $script:ErrorCatalog.PSObject.Properties[$Code] }
    $native = $null
    if ($null -ne $ErrorRecord) {
        $exception = $ErrorRecord.Exception
        while ($null -ne $exception) {
            if ($exception.Data.Contains('NativeCode')) { $native = $exception.Data['NativeCode']; break }
            $exception = $exception.InnerException
        }
    }
    [pscustomobject]@{ Code=$Code; Title=$entry.Value.Title; Message=$Message; Action=$entry.Value.Action; Stage=$Stage; Severity=$Severity; NativeCode=$native }
}

function Add-RunIssue($Issue) {
    if ($null -ne $script:Report -and $null -ne $script:Report.PSObject.Properties['Issues']) { $script:Report.Issues += $Issue }
    Send-DeploymentEvent 'Issue' $Issue.Stage $Issue.Message $Issue
}

function Send-DeploymentEvent([string]$Kind, [string]$Task, [string]$Message, $Issue = $null) {
    $event = [pscustomobject]@{Kind=$Kind;Task=$Task;Message=$Message;Issue=$Issue;TimeUTC=[DateTime]::UtcNow.ToString('o')}
    # Console avoids mixing transport messages into a function's success pipeline.
    [Console]::WriteLine('TINNOS_EVENT:' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($event | ConvertTo-Json -Depth 12 -Compress))))
}

function Invoke-MaintenanceStep([string]$Name, [scriptblock]$Operation, [string]$Code = 'TNO-500') {
    Send-DeploymentEvent 'Task' $Name 'Starting'
    $before = @(Get-Value $script:Report 'Issues' @()).Count + @(Get-Value $script:Report 'Pending' @()).Count
    try {
        $null = & $Operation
        $after = @(Get-Value $script:Report 'Issues' @()).Count + @(Get-Value $script:Report 'Pending' @()).Count
        if ($after -gt $before) {Send-DeploymentEvent 'Task' $Name 'Finished with issues or pending actions. Other tasks will continue; see Errors.'}
        else {Send-DeploymentEvent 'Success' $Name 'Task finished; final validation will confirm the outcome.'}
        return $true
    } catch {
        $issue=New-DeploymentIssue $Code $_.Exception.Message $Name 'Error' $_
        $script:Report.Errors += "$Name`: $($_.Exception.Message)"
        Add-RunIssue $issue
        return $false
    }
}

function Get-Value($Object, [string]$Name, $Default = $null) {
    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}

function Get-OfficeProductId([string]$LicenseEdition) {
    switch ($LicenseEdition) {
        'Business' { return 'O365BusinessRetail' }
        default { throw 'This build requires Microsoft 365 Apps for Business (O365BusinessRetail).' }
    }
}

function Read-DeploymentConfig([string]$Path) {
    $inputConfig = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($null -eq $inputConfig -or $inputConfig -isnot [pscustomobject]) { throw (New-TinnosError 'TNO-100' 'Configuration must be a JSON object.') }
    $allowed = @('LicenseEdition','Architecture','Languages','Channel','AppMode','InstallItems','RemoveItems')
    foreach ($property in $inputConfig.PSObject.Properties) {
        $key = $property.Name
        if ($key -notin $allowed) { throw "Unknown configuration field: $key" }
    }
    $edition = Get-Value $inputConfig 'LicenseEdition' 'Business'
    $null = Get-OfficeProductId $edition
    $architecture = Get-Value $inputConfig 'Architecture' '64'
    if ($architecture -notin @('32','64')) { throw 'Architecture must be 32 or 64.' }
    $languages = @(Get-Value $inputConfig 'Languages' @('pt-br'))
    if ($languages.Count -ne 1 -or $languages[0] -ne 'pt-br') { throw (New-TinnosError 'TNO-100' 'Office language is fixed to pt-br. Remove other languages from the configuration.') }
    $channel = Get-Value $inputConfig 'Channel' 'Current'
    $appMode = Get-Value $inputConfig 'AppMode' 'Install'
    if ($appMode -notin @('Download','Install')) { throw 'AppMode must be Download or Install.' }
    if ($channel -notin @('Current','MonthlyEnterprise','SemiAnnual','SemiAnnualPreview','CurrentPreview','BetaChannel')) { throw 'Unsupported Office channel.' }
    $installItems = @(Get-Value $inputConfig 'InstallItems' @('Office','Chrome','GoogleDrive'))
    foreach ($id in $installItems) {
        if ($id -isnot [string] -or $id -cnotin @('Office','Chrome','GoogleDrive')) {throw (New-TinnosError 'TNO-100' "Unknown installation selection: $id")}
    }
    $removeItems = @(Get-Value $inputConfig 'RemoveItems' @($script:DebloatCatalog | Where-Object {(Get-Value $_ 'DefaultSelected' $true)} | ForEach-Object {$_.Id}))
    foreach ($id in $removeItems) {
        if ($id -isnot [string] -or $id -cnotin @($script:DebloatCatalog.Id)) { throw (New-TinnosError 'TNO-100' "Unknown removal selection: $id") }
    }
    $removeItems = @($removeItems | Select-Object -Unique)
    [pscustomobject]@{
        LicenseEdition=$edition; ProductId=(Get-OfficeProductId $edition); Architecture=[string]$architecture
        Languages=@($languages | Select-Object -Unique); Channel=$channel
        AppMode=$appMode
        InstallItems=@($installItems | Select-Object -Unique)
        RemoveItems=$removeItems
        IncludeAccess=$false; ExcludeOneDrive=$true; ExcludeNewOutlook=$true
    }
}

function Get-DesiredExclusions($Config, $Office) {
    # Keep exclusions for unrelated apps during an existing-install reconfiguration.
    $excluded = @('Teams','Lync','Publisher','Access','Groove','OneDrive','Outlook','OutlookForWindows') + @(Get-Value $Office 'ExcludedApps' @())
    $required = @('Word','Excel','PowerPoint','OneNote')
    @($excluded | Where-Object { $_ -and $_ -notin $required } | Sort-Object -Unique)
}

function New-OfficeConfiguration($Config, $Office, [string]$Path) {
    $xml = New-Object System.Xml.XmlDocument
    $root = $xml.CreateElement('Configuration'); $null = $xml.AppendChild($root)
    $add = $xml.CreateElement('Add'); $null = $root.AppendChild($add)
    $add.SetAttribute('OfficeClientEdition', $Config.Architecture)
    $add.SetAttribute('Channel', $Config.Channel)
    $add.SetAttribute('SourcePath', (Join-Path ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))) 'OfficeMedia'))
    $product = $xml.CreateElement('Product'); $product.SetAttribute('ID', $Config.ProductId); $null = $add.AppendChild($product)
    $languages = @('pt-br')
    foreach ($language in @($languages | Where-Object { $_ } | Select-Object -Unique)) {
        $node = $xml.CreateElement('Language'); $node.SetAttribute('ID', $language); $null = $product.AppendChild($node)
    }
    foreach ($app in @(Get-DesiredExclusions $Config $Office)) {
        $node = $xml.CreateElement('ExcludeApp'); $node.SetAttribute('ID', $app); $null = $product.AppendChild($node)
    }
    $display = $xml.CreateElement('Display'); $display.SetAttribute('Level','None'); $display.SetAttribute('AcceptEULA','TRUE'); $null = $root.AppendChild($display)
    $updates = $xml.CreateElement('Updates'); $updates.SetAttribute('Enabled','TRUE'); $updates.SetAttribute('Channel',$Config.Channel); $null = $root.AppendChild($updates)
    # Never force-close an employee's open documents, migrate architecture, or remove other products.
    $property = $xml.CreateElement('Property'); $property.SetAttribute('Name','FORCEAPPSHUTDOWN'); $property.SetAttribute('Value','FALSE'); $null = $root.AppendChild($property)
    $xml.Save($Path)
    return $xml
}

function Get-UninstallEntries([string]$Hive = 'HKLM:') {
    foreach ($branch in @('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall','SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        $path = "$Hive\$branch"
        if (Test-Path -LiteralPath $path) {
            foreach ($key in @(Get-ChildItem -LiteralPath $path)) {
                $entry = Get-ItemProperty -LiteralPath $key.PSPath
                if (Get-Value $entry 'DisplayName') {
                    [pscustomobject]@{
                        Name=$entry.DisplayName; Key=$key.PSChildName; Version=(Get-Value $entry 'DisplayVersion')
                        WindowsInstaller=(Get-Value $entry 'WindowsInstaller' 0)
                        UninstallString=(Get-Value $entry 'UninstallString' '')
                        QuietUninstallString=(Get-Value $entry 'QuietUninstallString' '')
                        Publisher=(Get-Value $entry 'Publisher' '')
                        Scope=$Hive
                    }
                }
            }
        }
    }
}

function Test-TeamsEntry($Entry) {
    $Entry.Name -match '^(Microsoft Teams(?: classic| \(work or school\)| \(personal\))?|Teams Machine-Wide Installer|Microsoft Teams Meeting Add-in for Microsoft Office)$'
}

function Get-OfficeState($Config) {
    $path = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
    $c2r = if (Test-Path -LiteralPath $path) { Get-ItemProperty -LiteralPath $path } else { $null }
    $roots = @("$env:ProgramFiles\Microsoft Office\root\Office16", "${env:ProgramFiles(x86)}\Microsoft Office\root\Office16")
    $apps = [ordered]@{}
    foreach ($app in $script:RequiredApps.Keys) { $apps[$app] = @($roots | ForEach-Object { Join-Path $_ $script:RequiredApps[$app] } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1) }
    $apps['Access'] = @($roots | ForEach-Object { Join-Path $_ 'MSACCESS.EXE' } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1)
    $languages = @()
    $releaseRoot = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\ProductReleaseIDs'
    if (Test-Path -LiteralPath $releaseRoot) {
        $languages += @(Get-ChildItem -LiteralPath $releaseRoot -Recurse | Where-Object { $_.PSChildName -match '^[a-z]{2}-[a-z]{2}$' } | ForEach-Object { $_.PSChildName.ToLowerInvariant() })
    }
    $culture = Get-Value $c2r 'ClientCulture'
    if ($culture) { $languages += $culture.ToLowerInvariant() }
    [pscustomobject]@{
        Present=($null -ne $c2r); ProductIds=@(([string](Get-Value $c2r 'ProductReleaseIds' '') -split ',') | Where-Object { $_ })
        Platform=(Get-Value $c2r 'Platform'); Version=(Get-Value $c2r 'VersionToReport')
        Channel=(Get-Value $c2r 'UpdateChannel' (Get-Value $c2r 'CDNBaseUrl' ''))
        ExcludedApps=@(([string](Get-Value $c2r "$($Config.ProductId).ExcludedApps" '') -split '[,; ]+') | Where-Object { $_ })
        Languages=@($languages | Sort-Object -Unique); Apps=[pscustomobject]$apps
        OtherOffice=@(Get-UninstallEntries | Where-Object { $_.Name -match 'Microsoft (Office|365)' })
    }
}

function Test-OfficeMatches($Config, $Office) {
    $channelIds = @{
        Current='492350f6-3a01-4f97-b9c0-c7c6ddf67d60'; MonthlyEnterprise='55336b82-a18d-4dd6-b5f6-9e5095c314a6'
        SemiAnnual='7ffbc6bf-bc32-4f92-8982-f9dd17fd3114'; SemiAnnualPreview='b8f9b850-328d-4355-9145-c59439a0c4cf'
        CurrentPreview='64256afe-f5d9-4f86-8936-8840a6a4f5be'; BetaChannel='5440fd1f-7ecb-4221-8110-145efaa6372f'
    }
    if (!$Office.Present -or $Config.ProductId -notin $Office.ProductIds) { return $false }
    if ($Office.Platform -ne "x$($Config.Architecture)") { return $false }
    if ($Office.Channel -notmatch [regex]::Escape($channelIds[$Config.Channel])) { return $false }
    foreach ($app in $script:RequiredApps.Keys) { if (!@(Get-Value $Office.Apps $app @()).Count) { return $false } }
    foreach ($language in $Config.Languages) { if ($language -notin $Office.Languages) { return $false } }
    foreach ($app in @(Get-DesiredExclusions $Config $Office)) { if ($app -notin $Office.ExcludedApps) { return $false } }
    return $true
}

function Use-ProfileHive($Profile, [scriptblock]$Action) {
    $hive = "Registry::HKEY_USERS\$($Profile.SID)"
    if (Test-Path -LiteralPath $hive) { return & $Action $hive }
    $file = Join-Path $Profile.LocalPath 'NTUSER.DAT'
    if (!(Test-Path -LiteralPath $file)) { throw "Profile hive unavailable: $($Profile.SID); connect/unlock the profile and rerun." }
    $name = 'TinnosDebloat-Win11Audit_' + [guid]::NewGuid().ToString('N')
    $null = & reg.exe load "HKU\$name" $file 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Cannot inspect profile $($Profile.SID); sign out/unlock profile and rerun." }
    try { & $Action "Registry::HKEY_USERS\$name" }
    finally {
        [GC]::Collect(); [GC]::WaitForPendingFinalizers()
        $null = & reg.exe unload "HKU\$name" 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Temporary hive HKU\$name could not be unloaded; administrator action required." }
    }
}

function Get-TeamsStartup([string]$Hive) {
    foreach ($branch in @('SOFTWARE\Microsoft\Windows\CurrentVersion\Run','SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run','SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce')) {
        $path = "$Hive\$branch"
        if (Test-Path -LiteralPath $path) {
            $values = Get-ItemProperty -LiteralPath $path
            foreach ($value in $values.PSObject.Properties) {
                if ($value.Name -match '^(com\.squirrel\.Teams\.Teams|Teams|TeamsMachineInstaller|TeamsMachineUninstallerLocalAppData|TeamsMachineUninstallerProgramData)$' -or
                    [string]$value.Value -match '(?i)(\\Microsoft\\Teams\\.*Update\.exe|\\Teams Installer\\Teams\.exe|\\MSTeams_[^\\]+\\ms-teams\.exe)') {
                    [pscustomobject]@{ Path=$path; Name=$value.Name; Value=[string]$value.Value }
                }
            }
        }
    }
    # Windows packaged-app startup state is per user. Keep disabled entries as evidence,
    # but do not treat an inert entry left by Appx removal as an installed application.
    foreach ($family in @('MSTeams_8wekyb3d8bbwe','MicrosoftTeams_8wekyb3d8bbwe')) {
        $path = "$Hive\SOFTWARE\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData\$family"
        if (Test-Path -LiteralPath $path) {
            foreach ($key in @(Get-ChildItem -LiteralPath $path)) {
                if ($key.PSChildName -match 'Teams.*StartupTask') {
                    $state = Get-Value (Get-ItemProperty -LiteralPath $key.PSPath) 'State'
                    if ($null -ne $state -and [int]$state -in @(2,4)) {
                        [pscustomobject]@{ Path=$key.PSPath; Name='State'; Value=[string]$state; PackagedStartup=$true }
                    }
                }
            }
        }
    }
}

function Disable-TeamsStartup($Entry) {
    if (Get-Value $Entry 'PackagedStartup' $false) {
        if ([int]$Entry.Value -eq 4) { throw (New-TinnosError 'TNO-202' 'Teams startup is enabled by central policy; resolve the policy instead of overriding it.') }
        # The supported startup task State=1 disables user autostart; never change shared app state.
        $null = New-ItemProperty -LiteralPath $Entry.Path -Name State -PropertyType DWord -Value 1 -Force
    } else { Remove-ItemProperty -LiteralPath $Entry.Path -Name $Entry.Name }
}

function Test-TeamsShortcut([string]$Target, [string]$Arguments, [string]$AppUserModelId) {
    if ($Target -match '(?i)\\Microsoft(?:\\| )Teams\\current\\Teams\.exe$' -or
        $Target -match '(?i)\\(?:WindowsApps\\MSTeams_[^\\]+|Microsoft\\WindowsApps)\\ms-teams\.exe$') { return $true }
    if ($Target -match '(?i)\\Microsoft\\Teams\\Update\.exe$' -and $Arguments -match '(?i)(?:^|\s|["''])Teams\.exe(?:$|\s|["''])') { return $true }
    if ($AppUserModelId -match '^(MSTeams|MicrosoftTeams)_8wekyb3d8bbwe!' -or
        $Arguments -match '(?i)shell:AppsFolder\\(?:MSTeams|MicrosoftTeams)_8wekyb3d8bbwe!') { return $true }
    return $false
}

function Get-TeamsShortcuts([string[]]$Roots) {
    $shell = New-Object -ComObject WScript.Shell
    $shellApplication = New-Object -ComObject Shell.Application
    try {
        foreach ($root in $Roots) {
            if (!(Test-Path -LiteralPath $root)) { continue }
            foreach ($file in @(Get-ChildItem -LiteralPath $root -Filter '*.lnk' -File -Recurse)) {
                $link = $shell.CreateShortcut($file.FullName)
                try {
                    $appId = ''
                    $folder = $null; $item = $null
                    try {
                        $folder = $shellApplication.NameSpace($file.DirectoryName)
                        if ($null -ne $folder) {
                            $item = $folder.ParseName($file.Name)
                            if ($null -ne $item) { $appId = [string]$item.ExtendedProperty('System.AppUserModel.ID') }
                        }
                    } finally {
                        if ($null -ne $item) { $null = [Runtime.InteropServices.Marshal]::ReleaseComObject($item) }
                        if ($null -ne $folder) { $null = [Runtime.InteropServices.Marshal]::ReleaseComObject($folder) }
                    }
                    if (Test-TeamsShortcut $link.TargetPath $link.Arguments $appId) {
                        [pscustomobject]@{ Path=$file.FullName; Target=$link.TargetPath }
                    }
                } finally { $null = [Runtime.InteropServices.Marshal]::ReleaseComObject($link) }
            }
        }
    } finally {
        $null = [Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
        $null = [Runtime.InteropServices.Marshal]::ReleaseComObject($shellApplication)
    }
}

function Get-ProfileShortcutRoots([string]$LocalPath) {
    @((Join-Path $LocalPath 'Desktop'), (Join-Path $LocalPath 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs'))
}

function Get-TeamsInventory {
    $errors = New-Object 'System.Collections.Generic.List[string]'
    $profiles = @(); $packages = @(); $provisioned = @(); $machine = @(); $startup = @(); $shortcuts = @(); $binaries = @()
    try { $packages = @(Get-AppxPackage -AllUsers | Where-Object { $_.Name -in $script:TeamNames } | Select-Object Name,PackageFullName,PackageUserInformation) } catch { $errors.Add("Appx all-user enumeration: $_") }
    try { $provisioned = @(Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -in $script:TeamNames } | Select-Object DisplayName,PackageName) } catch { $errors.Add("Provisioned package enumeration: $_") }
    try { $machine = @(Get-UninstallEntries | Where-Object { Test-TeamsEntry $_ }); $startup = @(Get-TeamsStartup 'HKLM:') } catch { $errors.Add("Machine inventory: $_") }
    try { $shortcuts = @(Get-TeamsShortcuts @("$env:PUBLIC\Desktop", "$env:ProgramData\Microsoft\Windows\Start Menu\Programs")) } catch { $errors.Add("Machine shortcut inventory: $_") }
    foreach ($path in @("${env:ProgramFiles(x86)}\Teams Installer\Teams.exe", "$env:ProgramFiles\Teams Installer\Teams.exe")) { if (Test-Path -LiteralPath $path) { $binaries += $path } }
    try {
        $localProfiles = @(Get-CimInstance Win32_UserProfile | Where-Object { !$_.Special })
        foreach ($profile in $localProfiles) {
            try {
                $registry = Use-ProfileHive $profile { param($hive)
                    [pscustomobject]@{ Entries=@(Get-UninstallEntries $hive | Where-Object { Test-TeamsEntry $_ }); Startup=@(Get-TeamsStartup $hive) }
                }
                $profileBinaries = @()
                foreach ($relative in @('AppData\Local\Microsoft\Teams\current\Teams.exe','AppData\Local\Microsoft\Teams\Update.exe','AppData\Local\Microsoft\WindowsApps\ms-teams.exe')) {
                    $candidate = Join-Path $profile.LocalPath $relative
                    if (Test-Path -LiteralPath $candidate) { $profileBinaries += $candidate }
                }
                $addinFiles = @()
                foreach ($relative in @('AppData\Local\Microsoft\TeamsMeetingAddin','AppData\Local\Microsoft\TeamsMeetingAdd-in')) {
                    $addin = Join-Path $profile.LocalPath $relative
                    if (Test-Path -LiteralPath $addin) { $addinFiles += @(Get-ChildItem -LiteralPath $addin -Filter 'Microsoft.Teams.AddinLoader.dll' -File -Recurse | Select-Object -ExpandProperty FullName) }
                }
                $profiles += [pscustomobject]@{ SID=$profile.SID; LocalPath=$profile.LocalPath; Loaded=$profile.Loaded
                    Entries=$registry.Entries; Startup=$registry.Startup; Binaries=$profileBinaries; AddinFiles=@($addinFiles)
                    Shortcuts=@(Get-TeamsShortcuts (Get-ProfileShortcutRoots $profile.LocalPath)) }
            } catch { $errors.Add("Profile $($profile.SID): $_") }
        }
    } catch { $errors.Add("Profile enumeration: $_") }
    $machineAddins = @()
    foreach ($root in @("$env:ProgramFiles\Microsoft\TeamsMeetingAddin", "${env:ProgramFiles(x86)}\Microsoft\TeamsMeetingAddin", "$env:ProgramFiles\Microsoft\TeamsMeetingAdd-in", "${env:ProgramFiles(x86)}\Microsoft\TeamsMeetingAdd-in")) {
        try { if (Test-Path -LiteralPath $root) { $machineAddins += @(Get-ChildItem -LiteralPath $root -Filter 'Microsoft.Teams.AddinLoader.dll' -File -Recurse | Select-Object -ExpandProperty FullName) } } catch { $errors.Add("Add-in inventory: $_") }
    }
    [pscustomobject]@{ Packages=$packages; Provisioned=$provisioned; MachineEntries=$machine; MachineBinaries=$binaries
        MachineStartup=$startup; MachineShortcuts=$shortcuts; MachineAddinFiles=$machineAddins; Profiles=$profiles; Errors=@($errors.ToArray())
        Scope='All non-special Win32_UserProfile local profiles and all-user Appx/provisioning. Detached/remote profile containers must be audited when attached.' }
}

function Test-TeamsAbsent($Inventory) {
    if (@($Inventory.Errors).Count) { return $false }
    foreach ($name in @('Packages','Provisioned','MachineEntries','MachineBinaries','MachineStartup','MachineShortcuts','MachineAddinFiles')) {
        if (@($Inventory.$name).Count) { return $false }
    }
    foreach ($profile in $Inventory.Profiles) {
        foreach ($name in @('Entries','Startup','Binaries','Shortcuts','AddinFiles')) { if (@($profile.$name).Count) { return $false } }
    }
    return $true
}

function Invoke-Installer([string]$FilePath, [string]$Arguments, [int[]]$SuccessCodes = @(0,3010,1641), [switch]$Interactive) {
    $task = [IO.Path]::GetFileName($FilePath)
    Send-DeploymentEvent 'Task' $task 'Installer running; remaining time is not provided by this installer.'
    $windowStyle = if ($Interactive) {'Normal'} else {'Hidden'}
    $process = Start-Process -FilePath $FilePath -ArgumentList $Arguments -WindowStyle $windowStyle -PassThru
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $lastUpdate = 0
    try {
        while (!$process.WaitForExit(1000)) {
            if ($watch.Elapsed.TotalSeconds - $lastUpdate -ge 5) {
                $lastUpdate = [int]$watch.Elapsed.TotalSeconds
                Send-DeploymentEvent 'Progress' $task ("Installer still running. Elapsed: {0:mm\:ss}. Remaining time: unavailable." -f $watch.Elapsed)
            }
        }
        $process.WaitForExit()
        $exitCode = $process.ExitCode
    } finally { $watch.Stop(); $process.Dispose() }
    if ($exitCode -notin $SuccessCodes) { throw (New-TinnosError 'TNO-400' "$task failed with exit code $exitCode." $exitCode) }
    if ($null -ne $script:Report -and $exitCode -in @(3010,1641)) { $script:Report.RebootRequired = $true }
    if ($null -ne $script:Report) { $script:Report.Operations += [pscustomobject]@{ Executable=$task; Arguments=$Arguments; ExitCode=$exitCode } }
    Send-DeploymentEvent 'Success' $task "Installer exited with accepted code $exitCode. Checking the installed application next."
    return $exitCode
}

function Assert-Publisher([string]$Path, [ValidateSet('Microsoft','Google','Dell','ASUS')][string]$Publisher) {
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    $organization = switch ($Publisher) {
        'Dell' {'O="?Dell(?:,? Inc\.?| Technologies,? Inc\.?| Products,? L\.?P\.?)"?(?:,|$)'}
        'ASUS' {'O="?ASUSTeK COMPUTER INC\.?"?(?:,|$)'}
        default {"O=$Publisher (Corporation|LLC|Inc\.)[, ]"}
    }
    if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate -or $signature.SignerCertificate.Subject -notmatch $organization) {
        throw (New-TinnosError 'TNO-303' "Invalid $Publisher Authenticode signature: $Path")
    }
}

function Get-TrustedDownload([string]$Url, [string]$Path, [string]$Publisher) {
    $uri = [uri]$Url
    $allowedHost = if ($Publisher -eq 'Microsoft') { '(^|\.)microsoft\.com$' } else { '^dl\.google\.com$' }
    if ($uri.Scheme -ne 'https' -or $uri.Host -notmatch $allowedHost) { throw (New-TinnosError 'TNO-305' "Unexpected download origin: $Url") }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $absolutePath = [IO.Path]::GetFullPath($Path)
    $partial = Join-Path ([IO.Path]::GetDirectoryName($absolutePath)) ([IO.Path]::GetFileNameWithoutExtension($absolutePath) + '.download-' + [guid]::NewGuid().ToString('N') + [IO.Path]::GetExtension($absolutePath))
    $failures = @(); $failureCodes = @(); $downloaded = $false; $methodUsed = ''
    try {
        foreach ($method in @('PowerShell','curl')) {
            try {
                Send-DeploymentEvent 'Task' ([IO.Path]::GetFileName($absolutePath)) "Downloading from $($uri.Host) using $method. Remaining time: unavailable."
                if ($method -eq 'PowerShell') {
                    Invoke-WebRequest -Uri $uri -OutFile $partial -UseBasicParsing -TimeoutSec 60
                } else {
                    Invoke-CurlTransfer $Url $partial
                }
                if (!(Test-Path -LiteralPath $partial) -or (Get-Item -LiteralPath $partial).Length -eq 0) { throw (New-TinnosError 'TNO-304' 'The downloaded file is empty.') }
                $downloaded = $true; $methodUsed = $method; break
            } catch {
                $failures += "$method`: $($_.Exception.Message)"
                $failureCodes += Get-TinnosErrorCode $_ 'TNO-301'
                Add-RunIssue (New-DeploymentIssue 'TNO-301' "Download attempt failed ($method) for $Url. $($_.Exception.Message)" 'Download retry' 'Warning' $_)
                if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
            }
        }
        if (!$downloaded) {
            $code = if ('TNO-300' -in $failureCodes) {'TNO-300'} elseif ('TNO-302' -in $failureCodes) {'TNO-302'} elseif ('TNO-304' -in $failureCodes) {'TNO-304'} else {'TNO-301'}
            throw (New-TinnosError $code ("Download failed for $Url. " + ($failures -join '; ')))
        }
        # Never accept a successful HTTP response without a valid vendor signature.
        Assert-Publisher $partial $Publisher
        Move-Item -LiteralPath $partial -Destination $absolutePath -Force
        if ($null -ne $script:Report) {
            $script:Report.Downloads += [pscustomobject]@{ Url=$Url; File=$absolutePath; Bytes=(Get-Item -LiteralPath $absolutePath).Length
                SHA256=(Get-FileHash -LiteralPath $absolutePath -Algorithm SHA256).Hash; Publisher=$Publisher; Method=$methodUsed; EarlierFailures=$failures }
        }
        Send-DeploymentEvent 'Success' ([IO.Path]::GetFileName($absolutePath)) 'Download completed and publisher signature verified.'
        return $absolutePath
    } finally { if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force } }
}

function Invoke-CurlTransfer([string]$Url, [string]$Destination) {
    # Use Windows' protected inbox executable, never an executable found on a user PATH.
    $curl = Join-Path $env:WINDIR 'System32\curl.exe'
    if (!(Test-Path -LiteralPath $curl)) { throw (New-TinnosError 'TNO-301' 'Windows curl.exe is unavailable.') }
    $curlError = @(& $curl --location --fail --silent --show-error --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 120 --output $Destination $Url 2>&1) -join ' '
    if ($LASTEXITCODE -ne 0) {
        $code = if ($LASTEXITCODE -in @(5,6)) {'TNO-300'} elseif ($LASTEXITCODE -eq 28) {'TNO-302'} else {'TNO-301'}
        throw (New-TinnosError $code "curl exit $LASTEXITCODE`: $curlError" $LASTEXITCODE)
    }
}

function Remove-TeamsMsi($Entry, [string]$LogDirectory) {
    if (!(Test-TeamsEntry $Entry)) { throw 'Refusing to uninstall an unrelated product.' }
    if ($Entry.Key -notmatch '^\{[0-9A-Fa-f-]{36}\}$' -or $Entry.WindowsInstaller -ne 1) { throw (New-TinnosError 'TNO-205' "Unsupported Teams uninstaller for $($Entry.Name); use its supported uninstaller in the correct user context.") }
    if ($Entry.Name -match 'Meeting Add-in' -and @(Get-Process OUTLOOK -ErrorAction SilentlyContinue).Count) { throw (New-TinnosError 'TNO-403' 'Close Outlook before removing the Teams Meeting Add-in; no application was force-closed.') }
    $null = Invoke-Installer "$env:WINDIR\System32\msiexec.exe" "/x $($Entry.Key) /qn /norestart" @(0,1605,1614,3010,1641)
}

function Invoke-TeamsUserCleanup {
    $script:Report = [pscustomobject]@{ RebootRequired=$false; Operations=@() }
    $errors = New-Object 'System.Collections.Generic.List[string]'
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $updater = Join-Path $env:LOCALAPPDATA 'Microsoft\Teams\Update.exe'
    if (Test-Path -LiteralPath $updater) {
        try { Assert-Publisher $updater 'Microsoft'; $null = Invoke-Installer $updater '--uninstall -s' } catch { $errors.Add([string]$_) }
    }
    foreach ($entry in @(Get-UninstallEntries 'HKCU:' | Where-Object { Test-TeamsEntry $_ })) {
        try { Remove-TeamsMsi $entry '' } catch { $errors.Add([string]$_) }
    }
    foreach ($entry in @(Get-TeamsStartup 'HKCU:')) {
        try { Disable-TeamsStartup $entry } catch { $errors.Add([string]$_) }
    }
    foreach ($link in @(Get-TeamsShortcuts (Get-ProfileShortcutRoots $env:USERPROFILE))) {
        try { Remove-Item -LiteralPath $link.Path } catch { $errors.Add([string]$_) }
    }
    [pscustomobject]@{ SID=$sid; Time=(Get-Date).ToUniversalTime().ToString('o'); RebootRequired=$script:Report.RebootRequired; Operations=$script:Report.Operations; Errors=@($errors.ToArray()) }
}

function Initialize-ProtectedDirectory([string]$Path, [switch]$AdministratorsOnly) {
    $null = New-Item -Path $Path -ItemType Directory -Force
    $item = Get-Item -LiteralPath $Path
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw (New-TinnosError 'TNO-104' "Refusing reparse-point deployment directory: $Path") }
    # Protect scheduled task code, installers, configuration and reports from standard-user replacement.
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true,$false)
    $rules = @(@('S-1-5-18','FullControl'),@('S-1-5-32-544','FullControl'))
    if (!$AdministratorsOnly) { $rules += ,@('S-1-5-32-545','ReadAndExecute') }
    foreach ($pair in $rules) {
        $identity = New-Object Security.Principal.SecurityIdentifier($pair[0])
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity,$pair[1],'ContainerInherit,ObjectInherit','None','Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Backup-TeamsUserData($Inventory, [string]$Directory) {
    # Appx removal can remove application data; PreserveApplicationData does not work
    # for production Store packages. Preserve complete Teams stores before uninstall.
    if (@($Inventory.Errors).Count) { throw (New-TinnosError 'TNO-200' 'All profiles must be inspectable before Teams data can be preserved. No Teams removal was started.') }
    if (Test-TeamsAbsent $Inventory) { return }
    if (@(Get-Process Teams,ms-teams,msteams -ErrorAction SilentlyContinue).Count) { throw (New-TinnosError 'TNO-403' 'Close Teams in every active session before preserving data and removing it. No Teams process was force-closed.') }
    $backupRoot = Join-Path $Directory 'PreservedTeamsData'
    Initialize-ProtectedDirectory $backupRoot -AdministratorsOnly
    foreach ($profile in $Inventory.Profiles) {
        foreach ($relative in @('AppData\Local\Packages\MSTeams_8wekyb3d8bbwe', 'AppData\Local\Packages\MicrosoftTeams_8wekyb3d8bbwe',
            'AppData\Local\Microsoft\Teams', 'AppData\Local\Microsoft Teams', 'AppData\Roaming\Microsoft\Teams',
            'AppData\Local\Publishers\8wekyb3d8bbwe\TeamsSharedConfig')) {
            $source = Join-Path $profile.LocalPath $relative
            if (!(Test-Path -LiteralPath $source)) { continue }
            $sourceItem = Get-Item -LiteralPath $source -Force
            $reparse = @($sourceItem) + @(Get-ChildItem -LiteralPath $source -Force -Recurse)
            if (@($reparse | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) {
                throw (New-TinnosError 'TNO-204' "Teams data contains redirected/reparse paths: $source. Preserve its target before retrying; no removal was started.")
            }
            $target = Join-Path (Join-Path $backupRoot $profile.SID) $relative
            $null = New-Item -Path $target -ItemType Directory -Force
            $null = & "$env:WINDIR\System32\robocopy.exe" $source $target /E /COPY:DAT /DCOPY:DAT /XJ /R:0 /W:0 /NFL /NDL /NP
            if ($LASTEXITCODE -ge 8) { throw (New-TinnosError 'TNO-204' "Teams data backup failed for $($profile.SID) (robocopy $LASTEXITCODE). Close Teams/sign out and rerun; no removal was started." $LASTEXITCODE) }
            $script:Report.PreservedData += [pscustomobject]@{ SID=$profile.SID; Source=$source; Backup=$target; CopyExitCode=$LASTEXITCODE }
        }
    }
}

function Get-UserCleanupResults($Inventory, [switch]$RemoveCompleted) {
    $lastBoot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime()
    foreach ($task in @(Get-ScheduledTask -TaskName 'TinnosDebloat-Win11-RemoveTeams-*' -ErrorAction SilentlyContinue)) {
        $sid = $task.TaskName -replace '^TinnosDebloat-Win11-RemoveTeams-', ''
        $profile = @($Inventory.Profiles | Where-Object { $_.SID -eq $sid })
        $info = Get-ScheduledTaskInfo -TaskName $task.TaskName
        if ($info.LastTaskResult -eq 3010 -and $info.LastRunTime.ToUniversalTime() -gt $lastBoot) { $script:Report.RebootRequired = $true }
        $script:Report.UserCleanup += [pscustomobject]@{ SID=$sid; TaskName=$task.TaskName; State=[string]$task.State; LastTaskResult=$info.LastTaskResult; LastRunTime=$info.LastRunTime }
        $remaining = $true
        if ($profile.Count -eq 1) {
            $remaining = $false
            foreach ($field in @('Entries','Binaries','Startup','Shortcuts','AddinFiles')) { if (@($profile[0].$field).Count) { $remaining = $true } }
        }
        if (!$remaining -and !@($Inventory.Errors).Count -and $task.State -ne 'Running') {
            if ($RemoveCompleted) {
                Unregister-ScheduledTask -TaskName $task.TaskName -Confirm:$false
                $script:Report.Pending = @($script:Report.Pending | Where-Object { $_ -notlike "User cleanup scheduled: $($task.TaskName).*" })
                $script:Report.Notes += "Completed cleanup task removed: $($task.TaskName). Preserved user data retained."
            }
        } else { $script:Report.Pending += "Profile cleanup requires sign-in/retry: $($task.TaskName); task state $($task.State), last result $($info.LastTaskResult)." }
    }
}

function Register-UserCleanup($Profile, [string]$Directory) {
    $code = Join-Path $Directory 'UserCleanup'
    Initialize-ProtectedDirectory $code
    foreach ($file in @('Invoke-UserCleanup.ps1','Provisioning.psm1','error-codes.json','debloat-catalog.json')) { Copy-Item -LiteralPath (Join-Path $script:ModuleRoot $file) -Destination $code -Force }
    $name = 'TinnosDebloat-Win11-RemoveTeams-' + $Profile.SID
    $action = New-ScheduledTaskAction -Execute "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$code\Invoke-UserCleanup.ps1`""
    $principal = New-ScheduledTaskPrincipal -UserId $Profile.SID -LogonType Interactive -RunLevel Limited
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $Profile.SID
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 15) -MultipleInstances IgnoreNew
    $null = Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Trigger $trigger -Settings $settings -Force
    if ($Profile.Loaded) { try { Start-ScheduledTask -TaskName $name } catch { $script:Report.Pending += "Sign into profile $($Profile.SID) to complete cleanup: $_" } }
    $script:Report.Pending += "User cleanup scheduled: $name. Sign in, close Outlook/Teams, then press Start again."
}

function Remove-TeamsApplications($Inventory, $Config, [string]$Directory) {
    Backup-TeamsUserData $Inventory $Directory
    if (@($Inventory.Packages).Count) {
        try {
            $bootstrapper = Get-TrustedDownload 'https://go.microsoft.com/fwlink/?linkid=2243204&clcid=0x409' (Join-Path $Directory 'teamsbootstrapper.exe') 'Microsoft'
            # This is exclusively uninstall mode. Never pass -p or install a Teams MSIX.
            $null = Invoke-Installer $bootstrapper '-x -m'
        } catch { $script:Report.Errors += "Teams bootstrapper: $_"; Add-RunIssue (New-DeploymentIssue 'TNO-203' ([string]$_) 'Teams bootstrapper' 'Error' $_) }
    }
    foreach ($entry in $Inventory.MachineEntries) {
        try { Remove-TeamsMsi $entry $Directory } catch { $script:Report.Pending += "Machine component $($entry.Name): $_"; Add-RunIssue (New-DeploymentIssue 'TNO-203' ([string]$_) 'Teams MSI' 'Pending' $_) }
    }
    foreach ($package in $Inventory.Packages) {
        try { Remove-AppxPackage -Package $package.PackageFullName -AllUsers -ErrorAction Stop } catch { $script:Report.Pending += "Appx $($package.PackageFullName): $_"; Add-RunIssue (New-DeploymentIssue 'TNO-203' ([string]$_) 'Teams Appx' 'Pending' $_) }
    }
    foreach ($profile in $Inventory.Profiles) {
        if (@($profile.Entries).Count -or @($profile.Binaries).Count -or @($profile.Startup).Count -or @($profile.Shortcuts).Count -or @($profile.AddinFiles).Count) {
            try { Register-UserCleanup $profile $Directory } catch {
                $script:Report.Errors += "Cannot schedule cleanup for $($profile.SID): $_"
                Add-RunIssue (New-DeploymentIssue 'TNO-206' $_.Exception.Message "Teams profile $($profile.SID)" 'Error' $_)
            }
        }
    }
    foreach ($entry in $Inventory.MachineStartup) {
        try {Disable-TeamsStartup $entry} catch {Add-RunIssue (New-DeploymentIssue 'TNO-203' $_.Exception.Message 'Teams startup' 'Error' $_)}
    }
    foreach ($link in $Inventory.MachineShortcuts) {
        try {Remove-Item -LiteralPath $link.Path} catch {Add-RunIssue (New-DeploymentIssue 'TNO-203' $_.Exception.Message 'Teams shortcut' 'Error' $_)}
    }
}

function Assert-TeamsRemovalComplete {
    $inventory = Get-TeamsInventory
    if (@($inventory.Errors).Count) { throw (New-TinnosError 'TNO-200' ('Cannot verify Teams removal: ' + ($inventory.Errors -join '; '))) }
    if (!(Test-TeamsAbsent $inventory)) {
        $exception = New-TinnosError 'TNO-203' 'Teams removal is pending. Close Teams/Outlook, sign into affected profiles or reboot, then press Start again. App installation has not started.'
        $exception.Data['PendingAction'] = $true
        throw $exception
    }
}

function Remove-TeamsProvisioning($Inventory) {
    foreach ($package in $Inventory.Provisioned) {
        try {
            $result = Remove-AppxProvisionedPackage -Online -PackageName $package.PackageName -AllUsers -ErrorAction Stop
            if ($result.RestartNeeded) { $script:Report.RebootRequired = $true }
        } catch {
            $script:Report.Pending += "Provisioning $($package.PackageName): $_"
            Add-RunIssue (New-DeploymentIssue 'TNO-203' $_.Exception.Message 'Teams provisioning' 'Pending' $_)
        }
    }
}

function Get-PolicyEvidence {
    $effective = if (Test-Path -LiteralPath $script:OfficePolicy) { Get-Value (Get-ItemProperty -LiteralPath $script:OfficePolicy) 'preventteamsinstall' } else { $null }
    $evidence = @(); $conflicts = @(); $errors = @()
    $domainJoined = (Get-CimInstance Win32_ComputerSystem).PartOfDomain
    try {
        $rsop = @(Get-CimInstance -Namespace 'root\RSOP\Computer' -ClassName RSOP_RegistryPolicySetting -ErrorAction Stop)
        foreach ($row in $rsop) {
            if ($row.valueName -match 'preventteamsinstall|DefaultAssociationsConfiguration|updatebranch|updatepath|updatechannel') {
                $evidence += [pscustomobject]@{ Source='GroupPolicy'; Key=$row.keyName; Name=$row.valueName; Value=$row.value; GPO=(Get-Value $row 'GPOID') }
                if ($row.valueName -eq 'preventteamsinstall') {
                    $value = $row.value
                    if ($value -is [array] -and $value.Count -ge 4) { $value = [BitConverter]::ToUInt32([byte[]]$value,0) }
                    if ([string]$value -eq '0') { $conflicts += "Group Policy disables Teams installation prevention: $($row.keyName). Resolve in the originating GPO." }
                }
            }
        }
    } catch { if ($domainJoined) { $errors += "Cannot inspect domain RSoP: $_" } }
    $mdmRoot = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device'
    if (Test-Path -LiteralPath $mdmRoot) {
        try {
            foreach ($key in @(Get-ChildItem -LiteralPath $mdmRoot -Recurse)) {
                if ($key.Name -match 'Office|ApplicationDefaults|Teams') {
                    $properties = Get-ItemProperty -LiteralPath $key.PSPath
                    foreach ($property in $properties.PSObject.Properties) {
                        if ($property.Name -notmatch '^PS' -and ($property.Name -match 'preventteamsinstall|DefaultAssociationsConfiguration|updatebranch|updatechannel' -or $key.Name -match 'PreventTeamsInstall')) {
                            $evidence += [pscustomobject]@{ Source='MDM'; Key=$key.Name; Name=$property.Name; Value=$property.Value }
                            if ($property.Name -notmatch '_ProviderSet|_WinningProvider' -and ($property.Name -match 'preventteamsinstall' -or $key.Name -match 'PreventTeamsInstall') -and [string]$property.Value -match '^(0|<disabled\s*/>)$') {
                                $conflicts += "MDM disables Teams install prevention: $($key.Name) / $($property.Name)"
                            }
                        }
                    }
                }
            }
        } catch { $errors += "Cannot inspect effective MDM policy: $_" }
    }
    if ($null -ne $effective -and [int]$effective -ne 1) { $conflicts += 'Existing preventteamsinstall policy is not 1; the tool will not overwrite it.' }
    $officeValues = if (Test-Path -LiteralPath $script:OfficePolicy) { Get-ItemProperty -LiteralPath $script:OfficePolicy } else { $null }
    $updatePolicies = @()
    foreach ($name in @('updatebranch','updatepath','updatechannel','officemgmtcom','enableautomaticupdates')) {
        $value = Get-Value $officeValues $name
        if ($null -ne $value) { $updatePolicies += [pscustomobject]@{ Name=$name; Value=$value } }
    }
    [pscustomobject]@{ PreventTeamsInstall=$effective; Evidence=$evidence; Conflicts=$conflicts; Errors=$errors; UpdatePolicies=$updatePolicies; DomainJoined=$domainJoined
        Note='Effective local GPO/MDM evidence only. Tenant app assignments and Office cloud Modern Apps settings require administrator review; no central policies are changed.' }
}

function Set-TeamsPrevention($Evidence) {
    if (@($Evidence.Conflicts).Count -or @($Evidence.Errors).Count) { throw (New-TinnosError 'TNO-202' 'Teams policy conflict or unreadable central policy evidence; resolve centrally before Office installation.') }
    if ($null -eq $Evidence.PreventTeamsInstall) {
        $null = New-Item -Path $script:OfficePolicy -Force
        $null = New-ItemProperty -LiteralPath $script:OfficePolicy -Name preventteamsinstall -PropertyType DWord -Value 1
    }
    if ([int](Get-ItemProperty -LiteralPath $script:OfficePolicy).preventteamsinstall -ne 1) { throw (New-TinnosError 'TNO-202' 'Teams prevention policy verification failed.') }
}

function Resolve-OfficialOdtUrl([string]$Content) {
    $normalized = [Net.WebUtility]::HtmlDecode($Content).Replace('\/', '/')
    $match = [regex]::Match($normalized, 'https://download\.microsoft\.com/[^"\s<>]*officedeploymenttool[^"\s<>]*\.exe', 'IgnoreCase')
    if (!$match.Success) { throw 'Microsoft Download Center did not provide a recognizable official ODT link. No alternative installer was used; retry later.' }
    return $match.Value
}

function Get-OdtSetup($Config, [string]$Directory) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    try {
        $page = Invoke-WebRequest -Uri 'https://www.microsoft.com/en-us/download/details.aspx?id=49117' -UseBasicParsing -TimeoutSec 20
        $url = Resolve-OfficialOdtUrl $page.Content
    } catch {
        # Actual Download Center link verified 2026-11-04. Different Microsoft host
        # avoids requiring www.microsoft.com DNS just to resolve the archive URL.
        $url = 'https://download.microsoft.com/download/6c1eeb25-cf8b-41d9-8d0d-cc1dbc032140/officedeploymenttool_20430-20146.exe'
        Write-Host 'Download Center unavailable; trying the verified official Microsoft ODT archive link.'
        $script:Report.Notes += "ODT link discovery failed; official archive fallback selected. $($_.Exception.Message)"
        Add-RunIssue (New-DeploymentIssue 'TNO-306' "ODT discovery unavailable; using the official archive fallback. $($_.Exception.Message)" 'ODT discovery' 'Warning')
    }
    $archive = Get-TrustedDownload $url (Join-Path $Directory 'officedeploymenttool.exe') 'Microsoft'
    $extract = Join-Path $Directory 'ODT'
    $null = New-Item -Path $extract -ItemType Directory -Force
    $null = Invoke-Installer $archive "/quiet /extract:`"$extract`"" @(0)
    $setup = Join-Path $extract 'setup.exe'
    Assert-Publisher $setup 'Microsoft'
    Assert-OdtExecutable $setup
    Send-DeploymentEvent 'Success' 'Office Deployment Tool' 'Official Microsoft ODT extracted and verified.'
    return $setup
}

function Assert-OdtExecutable([string]$Path) {
    # Provenance is the signed official ODT archive plus the extracted file's
    # Microsoft signature. Version-resource names/descriptions vary by release.
    $bytes = [IO.File]::ReadAllBytes($Path)
    $valid = $bytes.Length -ge 64 -and $bytes[0] -eq 0x4d -and $bytes[1] -eq 0x5a
    if ($valid) {
        $offset = [BitConverter]::ToInt32($bytes, 0x3c)
        $valid = $offset -ge 64 -and $offset -le ($bytes.Length - 24)
        if ($valid) { $valid = [BitConverter]::ToUInt32($bytes, $offset) -eq 0x4550 }
    }
    if (!$valid) { throw (New-TinnosError 'TNO-307' 'The signed ODT archive did not produce a valid setup.exe executable. Retry the official download.') }
}

function Install-Office($Config, $Office, $Policies, [string]$XmlPath, [string]$Directory) {
    if ($Config.AppMode -eq 'Download') { return Get-OfficeMedia $Config $XmlPath $Directory }
    if (!(Get-Value $Office 'InventoryAvailable' $true)) { throw (New-TinnosError 'TNO-200' 'Office inventory is unavailable. Retry or resolve Office manually; other applications will continue.') }
    if (Test-OfficeMatches $Config $Office) { $script:Report.Notes += 'Office already matches requested applications, product, architecture, languages, channel and exclusions; ODT skipped.'; return [pscustomobject]@{Status='AlreadyInstalled'} }
    if ($Office.Present -and ($Office.Platform -ne "x$($Config.Architecture)" -or $Config.ProductId -notin $Office.ProductIds)) { throw (New-TinnosError 'TNO-401' 'Existing Office architecture/license product differs. Plan a migration; automatic removal is disabled.') }
    if (!$Office.Present -and @($Office.OtherOffice).Count) { throw (New-TinnosError 'TNO-401' 'Existing nonmatching Office installation detected. Resolve compatibility before deploying Microsoft 365.') }
    if (@($Policies.UpdatePolicies).Count) { throw (New-TinnosError 'TNO-202' 'Office update settings are centrally configured. Align the configuration centrally before changing Office.') }
    if (@(Get-Process WINWORD,EXCEL,POWERPNT,OUTLOOK,ONENOTE,MSACCESS -ErrorAction SilentlyContinue).Count) { throw (New-TinnosError 'TNO-403' 'Close Office applications and rerun; installation will not force-close documents.') }
    $media = Get-OfficeMedia $Config $XmlPath $Directory
    $null = Invoke-Installer $media.Setup "/configure `"$XmlPath`""
    if (!(Test-OfficeMatches $Config (Get-OfficeState $Config))) { throw (New-TinnosError 'TNO-404' 'ODT finished but the required Office installation is not yet verified. Reboot if indicated and retry.') }
    return [pscustomobject]@{Status='Installed';Artifact=$media.Artifact}
}

function Test-OfficeMedia([string]$SourcePath, [string]$Architecture) {
    $data = Join-Path $SourcePath 'Office\Data'
    $cab = Join-Path $data "v$Architecture.cab"
    if (!(Test-Path -LiteralPath $cab) -or (Get-Item -LiteralPath $cab).Length -eq 0) { return $false }
    return (@(Get-ChildItem -LiteralPath $data -File -Recurse -Filter '*.dat' | Where-Object {$_.Length -gt 0}).Count -gt 0)
}

function Get-OfficeMedia($Config, [string]$XmlPath, [string]$Directory) {
    $setup = Get-OdtSetup $Config $Directory
    [xml]$xml = Get-Content -LiteralPath $XmlPath -Raw
    $source = $xml.Configuration.Add.SourcePath
    $null = New-Item -Path $source -ItemType Directory -Force
    $null = Invoke-Installer $setup "/download `"$XmlPath`"" @(0)
    if (!(Test-OfficeMedia $source $Config.Architecture)) { throw (New-TinnosError 'TNO-402' 'ODT did not produce verifiable Office installation media; incomplete download retained for retry.') }
    return [pscustomobject]@{Status='Downloaded';Artifact=$source;Setup=$setup;Configuration=$XmlPath}
}

function Get-GoogleApps {
    $chrome = @(@("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe") | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1)
    $drive = @()
    foreach ($root in @("$env:ProgramFiles\Google\Drive File Stream", "${env:ProgramFiles(x86)}\Google\Drive File Stream")) {
        if (Test-Path -LiteralPath $root) { $drive += @(Get-ChildItem -LiteralPath $root -Filter GoogleDriveFS.exe -File -Recurse | Select-Object -ExpandProperty FullName) }
    }
    [pscustomobject]@{ Chrome=@($chrome); Drive=@($drive) }
}

function Install-GoogleChrome([string]$Directory, [switch]$DownloadOnly) {
    if (!$DownloadOnly -and @((Get-GoogleApps).Chrome).Count) { return [pscustomobject]@{Status='AlreadyInstalled'} }
    $msi = Get-TrustedDownload 'https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi' (Join-Path $Directory 'chrome.msi') 'Google'
    if ($DownloadOnly) { return [pscustomobject]@{Status='Downloaded';Artifact=$msi} }
    $null = Invoke-Installer "$env:WINDIR\System32\msiexec.exe" "/i `"$msi`" /qn /norestart"
    if (!@((Get-GoogleApps).Chrome).Count) { throw (New-TinnosError 'TNO-404' 'Chrome installer exited, but Chrome was not detected. Retry or install manually.') }
    return [pscustomobject]@{Status='Installed';Artifact=$msi}
}

function Install-GoogleDrive([string]$Directory, [switch]$DownloadOnly) {
    if (!$DownloadOnly -and @((Get-GoogleApps).Drive).Count) { return [pscustomobject]@{Status='AlreadyInstalled'} }
    $setup = Get-TrustedDownload 'https://dl.google.com/drive-file-stream/GoogleDriveSetup.exe' (Join-Path $Directory 'GoogleDriveSetup.exe') 'Google'
    if ($DownloadOnly) { return [pscustomobject]@{Status='Downloaded';Artifact=$setup} }
    $null = Invoke-Installer $setup '--silent --skip_launch_new --gsuite_shortcuts=false'
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while (!@((Get-GoogleApps).Drive).Count) {
        if ($watch.Elapsed.TotalSeconds -ge 120) { throw (New-TinnosError 'TNO-404' 'Google Drive installer exited, but Drive is not yet detected. A background installer or reboot may still be pending; check Windows before retrying.') }
        Send-DeploymentEvent 'Progress' 'Google Drive' ("Waiting for GoogleDriveFS.exe. Elapsed after installer exit: {0:mm\:ss}. Remaining time: unavailable." -f $watch.Elapsed)
        Start-Sleep -Seconds 5
    }
    return [pscustomobject]@{Status='Installed';Artifact=$setup}
}

function New-ChromeAssociations([string]$Path) {
    $xml = New-Object System.Xml.XmlDocument
    $root = $xml.CreateElement('DefaultAssociations'); $null = $xml.AppendChild($root)
    foreach ($identifier in @('.htm','.html','http','https')) {
        $node = $xml.CreateElement('Association'); $node.SetAttribute('Identifier',$identifier)
        $node.SetAttribute('ProgId','ChromeHTML'); $node.SetAttribute('ApplicationName','Google Chrome'); $null = $root.AppendChild($node)
    }
    $xml.Save($Path)
}

function Set-ChromeDefault([string]$Directory, $Evidence) {
    if (@(Get-Value $Evidence 'Errors' @()).Count) {throw (New-TinnosError 'TNO-202' 'Central policy evidence is unreadable. Chrome was installed, but browser-default changes require administrator review.')}
    if (!(Test-Path -LiteralPath 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Classes\ChromeHTML')) { throw 'Machine ChromeHTML registration is missing.' }
    $target = Join-Path $Directory 'chrome-associations.xml'
    New-ChromeAssociations $target
    $existing = if (Test-Path -LiteralPath $script:BrowserPolicy) { Get-Value (Get-ItemProperty -LiteralPath $script:BrowserPolicy) 'DefaultAssociationsConfiguration' } else { $null }
    if (@($Evidence.Evidence | Where-Object { $_.Source -eq 'MDM' -and $_.Name -match 'DefaultAssociationsConfiguration' }).Count) { throw (New-TinnosError 'TNO-202' 'MDM controls default associations; deploy the generated Chrome associations through Intune. Existing policy preserved.') }
    if ($existing -and (Test-ChromeAssociationFile $existing)) {
        $script:Report.Notes += 'Existing default association policy already selects Chrome; its path and all unrelated mappings were preserved.'
        return
    }
    if ($existing -and $existing -ne $target) { throw (New-TinnosError 'TNO-202' "Existing default association policy preserved: $existing. Merge Chrome mappings centrally.") }
    $null = Invoke-Installer "$env:WINDIR\System32\dism.exe" "/Online /Import-DefaultAppAssociations:`"$target`"" @(0,3010)
    $null = New-Item -Path $script:BrowserPolicy -Force
    $null = New-ItemProperty -LiteralPath $script:BrowserPolicy -Name DefaultAssociationsConfiguration -Value $target -PropertyType String -Force
    $script:Report.Notes += 'Chrome defaults configured through DISM and supported association policy. Existing sessions apply at next sign-in; UserChoice hashes are never modified.'
}

function Test-ChromeAssociationFile([string]$Path) {
    try {
        [xml]$xml = Get-Content -LiteralPath $Path -Raw
        foreach ($id in @('.htm','.html','http','https')) {
            if (!@($xml.DefaultAssociations.Association | Where-Object { $_.Identifier -eq $id -and $_.ProgId -eq 'ChromeHTML' }).Count) { return $false }
        }
        return $true
    } catch { return $false }
}

function Get-OfficeActivation([string]$ProductId) {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $paths = @("$env:ProgramFiles\Microsoft Office\Office16\vnextdiag.ps1", "$env:ProgramFiles\Microsoft Office\root\Office16\vnextdiag.ps1",
        "${env:ProgramFiles(x86)}\Microsoft Office\Office16\vnextdiag.ps1", "${env:ProgramFiles(x86)}\Microsoft Office\root\Office16\vnextdiag.ps1")
    $diagnostic = $paths | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (!$diagnostic) { return [pscustomobject]@{ Status='Unknown'; ContextSID=$sid; Reason='vnextdiag.ps1 unavailable; sign in to Office and run Check-OfficeActivation.ps1 as the employee.' } }
    try {
        $output = @(& "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $diagnostic -action list 2>&1) -join "`n"
        if ($LASTEXITCODE -ne 0) { throw "vnextdiag exit $LASTEXITCODE" }
        # vnextdiag returns one JSON object per license. Avoid mixing another product's Licensed state.
        $blocks = [regex]::Matches($output,'(?s)\{[^{}]*\}')
        $licenses = @()
        foreach ($block in $blocks) {
            try {
                $license = $block.Value | ConvertFrom-Json
                $product = Get-Value $license 'Product'
                if ($product -eq $ProductId) { $licenses += [pscustomobject]@{ Product=$product; State=(Get-Value $license 'LicenseState' (Get-Value $license 'State' 'Unknown')); Type=(Get-Value $license 'LicenseType' (Get-Value $license 'Type' 'Unknown')) } }
            } catch { continue }
        }
        $status = if (@($licenses | Where-Object { $_.State -eq 'Licensed' }).Count) { 'Licensed' } elseif ($licenses.Count) { 'NotLicensed' } else { 'Unknown' }
        [pscustomobject]@{ Status=$status; ContextSID=$sid; ProductId=$ProductId; Licenses=$licenses
            Reason='Read-only vnextdiag -action list in this execution account. Employee activation is separate; sign in with a licensed Microsoft 365 account. No tokens, email addresses or keys are collected.' }
    } catch { [pscustomobject]@{ Status='Unknown'; ContextSID=$sid; Reason=[string]$_ } }
}

function Get-DeploymentChecks($Config, $Office, $Teams, $Policies, $Google, [string]$Directory, [string]$Mode = 'Audit', $Applications = @()) {
    $checks = @()
    $installItems=@(Get-Value $Config 'InstallItems' @('Office','Chrome','GoogleDrive'))
    $removeItems=@(Get-Value $Config 'RemoveItems' @())
    foreach ($app in $script:RequiredApps.Keys) { $checks += [pscustomobject]@{ Name=$app; Pass=(@(Get-Value $Office.Apps $app @()).Count -gt 0); Detail=@(Get-Value $Office.Apps $app @()) } }
    $checks += [pscustomobject]@{ Name='Chrome'; Pass=(@($Google.Chrome).Count -gt 0); Detail=$Google.Chrome }
    $checks += [pscustomobject]@{ Name='GoogleDrive'; Pass=(@($Google.Drive).Count -gt 0); Detail=$Google.Drive }
    $checks += [pscustomobject]@{ Name='TeamsCompletelyAbsent'; Pass=(Test-TeamsAbsent $Teams); Detail=$Teams }
    $checks += [pscustomobject]@{ Name='NoTeamsMachineWideInstaller'; Pass=(!@($Teams.MachineEntries | Where-Object { $_.Name -eq 'Teams Machine-Wide Installer' }).Count -and !@($Teams.MachineBinaries).Count); Detail=$Teams.MachineEntries }
    $checks += [pscustomobject]@{ Name='NoTeamsProvisioning'; Pass=(!@($Teams.Provisioned).Count); Detail=$Teams.Provisioned }
    $checks += [pscustomobject]@{ Name='TeamsPreventionPolicy'; Pass=($Policies.PreventTeamsInstall -eq 1 -and !@($Policies.Conflicts).Count -and !@($Policies.Errors).Count); Detail=$Policies }
    $checks += [pscustomobject]@{ Name='OfficeConfiguration'; Pass=(Test-OfficeMatches $Config $Office); Detail=$Office }
    $checks += [pscustomobject]@{ Name='OfficeTeamsExcluded'; Pass=('Teams' -in $Office.ExcludedApps); Detail=$Office.ExcludedApps }
    $policyPath = if (Test-Path -LiteralPath $script:BrowserPolicy) { Get-Value (Get-ItemProperty -LiteralPath $script:BrowserPolicy) 'DefaultAssociationsConfiguration' } else { $null }
    $browserValid = $false
    try {
        if ($policyPath) {
            [xml]$associations = Get-Content -LiteralPath $policyPath -Raw
            $browserValid = $true
            foreach ($id in @('.htm','.html','http','https')) {
                if (!@($associations.DefaultAssociations.Association | Where-Object { $_.Identifier -eq $id -and $_.ProgId -eq 'ChromeHTML' }).Count) { $browserValid = $false }
            }
        }
    } catch { $browserValid = $false }
    $checks += [pscustomobject]@{ Name='ChromeDefaultPolicy'; Pass=$browserValid; Detail="Policy: $policyPath. Existing sessions require next sign-in; this check does not claim that every current UserChoice has changed." }
    $appChecks = @('Word','Excel','PowerPoint','Outlook','OneNote','Access','Chrome','GoogleDrive','OfficeConfiguration','OfficeTeamsExcluded','ChromeDefaultPolicy')
    foreach ($check in $checks) {
        $isApp = $check.Name -in $appChecks
        # Installed-app observations stay visible in a download-only report but are
        # not claims that downloading an installer also installs its applications.
        $required = !$isApp -or ($Mode -eq 'Audit' -and $Config.AppMode -eq 'Install')
        $check | Add-Member -NotePropertyName Required -NotePropertyValue $required
        $check | Add-Member -NotePropertyName Category -NotePropertyValue $(if ($isApp) {'Application'} else {'Cleanup'})
    }
    # Scope validation to requested actions. Unchecked apps/services are never
    # presented as successful removals or as failures of this run.
    $checks=@($checks | Where-Object {
        if ($_.Name -in @('TeamsCompletelyAbsent','NoTeamsMachineWideInstaller','NoTeamsProvisioning')) {'Teams' -in $removeItems}
        elseif ($_.Name -eq 'TeamsPreventionPolicy') {'Office' -in $installItems -or 'Teams' -in $removeItems}
        elseif ($_.Name -in @('Word','Excel','PowerPoint','OneNote','OfficeConfiguration','OfficeTeamsExcluded')) {'Office' -in $installItems}
        elseif ($_.Name -in @('Chrome','ChromeDefaultPolicy')) {'Chrome' -in $installItems}
        elseif ($_.Name -eq 'GoogleDrive') {'GoogleDrive' -in $installItems}
        else {$true}
    })
    $checks+=[pscustomobject]@{Name='SelectedActions';Pass=$true;Required=$true;Category='Selection';Detail=[pscustomobject]@{InstallItems=$installItems;RemoveItems=$removeItems}}
    foreach ($app in $Applications) {
        if ($app.Action -eq 'RemoveRdc') {
            $pass=$false;$evidence=$app
            try {$state=Get-RemoteDesktopConnectionState;$pass=!$state.Present -and $app.Status -ne 'Failed';$evidence=$state} catch {$evidence=[string]$_}
            $checks+=[pscustomobject]@{Name='RemoteDesktopConnection';Pass=$pass;Required=$true;Category='Debloat';Detail=$evidence;ErrorCode='TNO-504'}
            continue
        }
        if ($app.Action -eq 'RemoveDesktop') {
            $pass=$false;$evidence=$app
            try {
                $native=Get-DesktopUtilityInventory $app.Name
                $pass=!$native.Entries.Count -and !$native.Packages.Count -and !$native.Provisioned.Count -and $app.Status -ne 'Failed'
                $evidence=$native
            } catch {$evidence=[string]$_}
            $checks+=[pscustomobject]@{Name=$app.Name;Pass=$pass;Required=$true;Category='Debloat';Detail=$evidence;ErrorCode='TNO-504'}
            continue
        }
        if ($app.Action -in @('Remove','Disable')) {
            $pass=$false; $evidence=$app
            try {
                if ($app.Action -eq 'Remove') {
                    $remaining=@(Get-AppxPackage -AllUsers -Name $app.Name -ErrorAction Stop | Where-Object {$_.Name -eq $app.Name})
                    $provisioning=@(Get-AppxProvisionedPackage -Online -ErrorAction Stop | Where-Object {$_.DisplayName -eq $app.Name})
                    $pass=!$remaining.Count -and !$provisioning.Count -and $app.Status -ne 'Failed'
                    $evidence=[pscustomobject]@{Packages=$remaining;Provisioned=$provisioning;Operation=$app}
                } else {
                    $service=Get-CimInstance Win32_Service -Filter "Name='$($app.Name)'" -ErrorAction Stop | Select-Object Name,StartMode,State
                    $pass=($null -eq $service -or ($service.StartMode -eq 'Disabled' -and $service.State -eq 'Stopped')) -and $app.Status -ne 'Failed'
                    $evidence=[pscustomobject]@{Service=$service;Operation=$app}
                }
            } catch { $evidence=[string]$_ }
            $checks += [pscustomobject]@{Name=$app.Name;Pass=$pass;Required=$true;Category='Debloat';Detail=$evidence;ErrorCode=$(if ($app.Action -eq 'Remove') {'TNO-500'} else {'TNO-502'})}
            continue
        }
        if ($app.Action -eq 'Configure' -and $app.Name -ne 'ChromeDefaults') {
            $checks += [pscustomobject]@{Name=$app.Name;Pass=($app.Status -eq 'Configured');Required=$true;Category='Debloat';Detail=$app;ErrorCode='TNO-503'}
            continue
        }
        if ($app.Name -eq 'ChromeDefaults') { continue }
        $checks += [pscustomobject]@{Name=($app.Name + $Config.AppMode); Pass=($app.Status -in @('Downloaded','Installed','AlreadyInstalled')); Required=$false; Category='Application'; Detail=$app}
    }
    return $checks
}

function Get-DeploymentStatus($Checks, $Errors, [bool]$RebootRequired, $Pending, $AppIssues = @()) {
    if (@($Errors).Count) { return 'Failed' }
    if (!@($Checks).Count) { return 'Failed' }
    if (@($Checks | Where-Object { !$_.Pass -and (Get-Value $_ 'Required' $true) }).Count) {
        if (@($Pending).Count -or $RebootRequired) { return 'Pending' }
        return 'Failed'
    }
    if ($RebootRequired -or @($Pending).Count) { return 'Pending' }
    if (@($AppIssues).Count) { return 'CompletedWithIssues' }
    return 'Complete'
}

function Get-PendingRebootReasons {
    foreach ($path in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')) {
        if (Test-Path -LiteralPath $path) { $path }
    }
    $sessionManager = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    if (Test-Path -LiteralPath $sessionManager) {
        $pending = Get-Value (Get-ItemProperty -LiteralPath $sessionManager) 'PendingFileRenameOperations'
        if ($null -ne $pending -and @($pending).Count) { 'PendingFileRenameOperations (may be unrelated to this deployment)' }
    }
}

function Backup-SelectedAppData($Packages, [string]$Directory) {
    if (!@($Packages).Count) { return }
    $profiles = @(Get-CimInstance Win32_UserProfile -ErrorAction Stop | Where-Object {!$_.Special})
    foreach ($profile in $profiles) {
        if (!(Test-Path -LiteralPath $profile.LocalPath -ErrorAction Stop)) {
            throw (New-TinnosError 'TNO-501' "Profile $($profile.SID) is unavailable. Attach it before removing this app.")
        }
        foreach ($family in @($Packages.PackageFamilyName | Select-Object -Unique)) {
            $source = Join-Path $profile.LocalPath "AppData\Local\Packages\$family"
            # Never follow redirected profile/package data during an elevated copy.
            $ancestor = $source
            while ($ancestor) {
                if (Test-Path -LiteralPath $ancestor) {
                    if ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw (New-TinnosError 'TNO-501' "Redirected app data: $ancestor. Preserve it manually before removal.") }
                }
                $ancestor = Split-Path $ancestor -Parent
            }
            if (!(Test-Path -LiteralPath $source -ErrorAction Stop)) { continue }
            if (@(Get-ChildItem -LiteralPath $source -Recurse -Force -ErrorAction Stop | Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count) {
                throw (New-TinnosError 'TNO-501' "App data contains redirected paths: $source. Removal skipped.")
            }
            $root = Join-Path $Directory 'PreservedAppData'
            Initialize-ProtectedDirectory $root -AdministratorsOnly
            $target = Join-Path (Join-Path $root $profile.SID) $family
            $null = New-Item -Path $target -ItemType Directory -Force
            Send-DeploymentEvent 'Task' "Preserve $family" "Copying app data for $($profile.SID) before uninstall."
            try {
                $null = Invoke-Installer "$env:WINDIR\System32\robocopy.exe" "`"$source`" `"$target`" /E /COPY:DAT /DCOPY:DAT /XJ /R:0 /W:0 /NFL /NDL /NP /NJH /NJS" @(0,1,2,3,4,5,6,7)
            } catch {throw (New-TinnosError 'TNO-501' "Could not preserve $family for $($profile.SID). No removal of this app was started. $($_.Exception.Message)")}
            $script:Report.PreservedData += [pscustomobject]@{SID=$profile.SID;Source=$source;Backup=$target}
        }
    }
}

function Remove-SelectedApp([string]$PackageName, [string]$Directory) {
    if ($PackageName -notin @($script:DebloatCatalog | ForEach-Object {$_.Packages})) { throw (New-TinnosError 'TNO-100' 'App removal is limited to exact catalog package names.') }
    $installed = @(Get-AppxPackage -AllUsers -Name $PackageName -ErrorAction Stop | Where-Object {$_.Name -eq $PackageName})
    $provisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop | Where-Object {$_.DisplayName -eq $PackageName})
    if (!$installed.Count -and !$provisioned.Count) { return [pscustomobject]@{Status='NotPresent'} }
    Backup-SelectedAppData $installed $Directory
    foreach ($package in $installed) {
        try {
            if ($package.IsFramework -or $package.NonRemovable) { throw (New-TinnosError 'TNO-500' "Windows marks $PackageName as a framework or nonremovable app. It was left intact.") }
            Send-DeploymentEvent 'Task' $PackageName "Removing $($package.PackageFullName) for all users."
            Remove-AppxPackage -Package $package.PackageFullName -AllUsers -ErrorAction Stop
        } catch { Add-RunIssue (New-DeploymentIssue 'TNO-500' $_.Exception.Message $PackageName 'Error' $_) }
    }
    foreach ($package in $provisioned) {
        try {
            Send-DeploymentEvent 'Task' $PackageName 'Removing provisioning for future users.'
            $result=Remove-AppxProvisionedPackage -Online -PackageName $package.PackageName -AllUsers -ErrorAction Stop
            if ($result.RestartNeeded) {$script:Report.RebootRequired=$true}
        } catch { Add-RunIssue (New-DeploymentIssue 'TNO-500' $_.Exception.Message $PackageName 'Error' $_) }
    }
    $remaining = @(Get-AppxPackage -AllUsers -Name $PackageName -ErrorAction Stop | Where-Object {$_.Name -eq $PackageName})
    $remainingProvisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop | Where-Object {$_.DisplayName -eq $PackageName})
    if ($remaining.Count -or $remainingProvisioned.Count) { throw (New-TinnosError 'TNO-500' "$PackageName still has installed/provisioned entries. Close the app, sign out or reboot if needed; then retry or uninstall manually.") }
    return [pscustomobject]@{Status='Removed'}
}

function Assert-ServicePolicy([string]$Name) {
    # Respect service policies even when they agree with this selection: their
    # owner controls the service, rather than this local tool.
    $computer = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    $rows = @()
    try {
        $rows += @(Get-CimInstance -Namespace 'root\RSOP\Computer' -ClassName RSOP_SystemService -ErrorAction Stop | Where-Object {$_.serviceName -eq $Name})
        $rows += @(Get-CimInstance -Namespace 'root\RSOP\Computer' -ClassName RSOP_RegistryPolicySetting -ErrorAction Stop | Where-Object {$_.keyName -like "*Services\$Name" -and $_.valueName -eq 'Start'})
    } catch {
        if ($computer.PartOfDomain) { throw (New-TinnosError 'TNO-202' "Cannot verify central service policy for $Name. Change it through your administrator.") }
    }
    $mdm = 'HKLM:\SOFTWARE\Microsoft\Enrollments'
    if (Test-Path -LiteralPath $mdm) {
        # MDM scripts/remediations do not expose reliable policy ownership.
        if (@(Get-ChildItem -LiteralPath $mdm -ErrorAction Stop | Where-Object {(Get-Value (Get-ItemProperty -LiteralPath $_.PSPath) 'EnrollmentState' 0) -eq 1}).Count) {
            throw (New-TinnosError 'TNO-202' "MDM enrollment detected. Disable $Name centrally to avoid overriding Intune service configuration.")
        }
    }
    if ($rows.Count) { throw (New-TinnosError 'TNO-202' "Service $Name is centrally managed. Resolve its startup setting in Group Policy.") }
}

function Disable-SelectedService([string]$Name) {
    if ($Name -notin @($script:DebloatCatalog | ForEach-Object {$_.Services})) { throw (New-TinnosError 'TNO-100' 'Service changes are limited to the explicit catalog.') }
    $previous = Get-CimInstance Win32_Service -Filter "Name='$Name'" -ErrorAction Stop
    if ($null -eq $previous) { return [pscustomobject]@{Status='NotPresent'} }
    $service = Get-Service -Name $Name -ErrorAction Stop
    Assert-ServicePolicy $Name
    Send-DeploymentEvent 'Task' $Name "Disabling service (previous startup: $($previous.StartMode), state: $($previous.State))."
    # No Force: dependent services must not be stopped as collateral damage.
    if ($service.Status -ne 'Stopped') { Stop-Service -Name $Name -ErrorAction Stop }
    $stopWatch=[Diagnostics.Stopwatch]::StartNew()
    while ((Get-CimInstance Win32_Service -Filter "Name='$Name'" -ErrorAction Stop).State -ne 'Stopped') {
        if ($stopWatch.Elapsed.TotalSeconds -ge 30) {throw (New-TinnosError 'TNO-502' "$Name has not stopped within 30 seconds. Startup was not changed; resolve the pending service stop and retry.")}
        Send-DeploymentEvent 'Progress' $Name 'Waiting for the service to reach Stopped; dependent services are not force-stopped.'
        Start-Sleep -Milliseconds 1000
    }
    Set-Service -Name $Name -StartupType Disabled -ErrorAction Stop
    $current = Get-CimInstance Win32_Service -Filter "Name='$Name'" -ErrorAction Stop
    if ($current.StartMode -ne 'Disabled' -or $current.State -ne 'Stopped') { throw (New-TinnosError 'TNO-502' "$Name is not both stopped and disabled. Retry or use services.msc after resolving dependencies/policy.") }
    return [pscustomobject]@{Status='Disabled';PreviousStartMode=$previous.StartMode;PreviousState=$previous.State}
}

function Get-RemoteDesktopConnectionState {
    $paths=@('System32','SysWOW64' | ForEach-Object {Join-Path $env:WINDIR "$_\mstsc.exe"} | Where-Object {Test-Path -LiteralPath $_ -ErrorAction Stop})
    [pscustomobject]@{Present=($paths.Count -gt 0);Paths=$paths}
}

function Remove-RemoteDesktopConnection {
    $state=Get-RemoteDesktopConnectionState
    if (!$state.Present) {return [pscustomobject]@{Status='NotPresent'}}
    $windows=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
    if ([int]$windows.CurrentBuildNumber -lt 22631) {throw (New-TinnosError 'TNO-504' 'Remote Desktop Connection removal requires Windows 11 23H2 or newer. The client was left intact.')}
    if (@(Get-Process mstsc -ErrorAction SilentlyContinue).Count) {throw (New-TinnosError 'TNO-403' 'Close outgoing Remote Desktop Connection sessions before removing the client. No session was force-closed.')}
    $client=Join-Path $env:WINDIR 'System32\mstsc.exe'
    if (!(Test-Path -LiteralPath $client)) {throw (New-TinnosError 'TNO-504' 'The supported System32 mstsc.exe uninstaller is unavailable. Use Windows Installed apps.')}
    Assert-Publisher $client 'Microsoft'
    Send-DeploymentEvent 'Task' 'Remote Desktop Connection' 'Windows will show its own uninstall/restart prompt. Choose restart later so other tasks can finish. Saved RDP files are preserved.'
    # Do not pass /noPromptBeforeRestart: Microsoft documents it as an automatic restart.
    $null=Invoke-Installer $client '/uninstall' @(0,3010) -Interactive
    if ((Get-RemoteDesktopConnectionState).Present) {
        $message='Remote Desktop Connection removal is not yet verified. Complete the Windows prompt and restart if requested, then retry. No automatic restart was requested.'
        $script:Report.Pending += $message
        Add-RunIssue (New-DeploymentIssue 'TNO-504' $message 'Remote Desktop Connection' 'Pending')
        return [pscustomobject]@{Status='Pending'}
    }
    return [pscustomobject]@{Status='Removed'}
}

function Get-DesktopUtilityInventory([string]$Id) {
    $definition=@($script:DebloatCatalog | Where-Object {$_.Id -eq $Id -and (Get-Value $_ 'DesktopProducts')})
    if ($definition.Count -ne 1) {throw (New-TinnosError 'TNO-100' 'Desktop removal is limited to catalog products.')}
    $names=@($definition[0].DesktopProducts)
    $entries=@(Get-UninstallEntries | Where-Object {$_.Name -in $names})
    # Inspect per-user entries, but do not run another user's uninstaller elevated.
    foreach ($profile in @(Get-CimInstance Win32_UserProfile -ErrorAction Stop | Where-Object {!$_.Special})) {
        $entries+=@(Use-ProfileHive $profile {param($Hive);Get-UninstallEntries $Hive | Where-Object {$_.Name -in $names}})
    }
    $packages=@();$provisioned=@()
    foreach ($name in @(Get-Value $definition[0] 'DetectionPackages' @())) {
        $packages+=@(Get-AppxPackage -AllUsers -Name $name -ErrorAction Stop | Where-Object {$_.Name -eq $name})
        $provisioned+=@(Get-AppxProvisionedPackage -Online -ErrorAction Stop | Where-Object {$_.DisplayName -eq $name})
    }
    [pscustomobject]@{Entries=$entries;Packages=$packages;Provisioned=$provisioned;Definition=$definition[0]}
}

function Get-DesktopQuietCommand($Entry, [string]$Vendor) {
    $quiet=[string](Get-Value $Entry 'QuietUninstallString' '')
    $match=[regex]::Match($quiet, '^"([^"\r\n]+\.exe)"\s+([^\r\n]+)$|^(\S+\.exe)\s+([^\r\n]+)$', 'IgnoreCase')
    if (!$match.Success) {throw (New-TinnosError 'TNO-504' "No supported silent uninstaller is registered for $($Entry.Name). Use Windows Installed apps.")}
    $file=if ($match.Groups[1].Success) {$match.Groups[1].Value} else {$match.Groups[3].Value}
    $arguments=if ($match.Groups[1].Success) {$match.Groups[2].Value} else {$match.Groups[4].Value}
    if (![IO.Path]::IsPathRooted($file)) {throw (New-TinnosError 'TNO-504' 'The vendor uninstaller must use an absolute local path.')}
    $file=[IO.Path]::GetFullPath($file)
    $allowed=$false
    foreach ($root in @($env:ProgramFiles,${env:ProgramFiles(x86)},$env:ProgramData) | Where-Object {$_}) {
        if ([IO.Path]::IsPathRooted($file) -and $file.StartsWith(([IO.Path]::GetFullPath($root).TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase)) {$allowed=$true}
    }
    if (!$allowed -or $file.StartsWith('\\')) {throw (New-TinnosError 'TNO-504' 'The registered vendor uninstaller is outside trusted local application directories.')}
    for ($path=$file; $path; $path=Split-Path $path -Parent) {
        if ((Get-Item -LiteralPath $path -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint) {throw (New-TinnosError 'TNO-504' 'A redirected vendor uninstaller was rejected.')}
    }
    Assert-Publisher $file $Vendor
    [pscustomobject]@{File=$file;Arguments=$arguments}
}

function Remove-DesktopUtility([string]$Id) {
    $inventory=Get-DesktopUtilityInventory $Id
    $definition=$inventory.Definition
    if (!$inventory.Entries.Count -and !$inventory.Packages.Count -and !$inventory.Provisioned.Count) {return [pscustomobject]@{Status='NotPresent';ProductId=$Id}}
    if (Get-Value $definition 'ManualUrl') {throw (New-TinnosError 'TNO-504' "Use the official ASUS uninstall tool for complete $Id removal, then reboot and retry. $($definition.ManualUrl)")}
    $publisherPattern=switch ($definition.Vendor) {
        'Dell' {'^Dell(?:,? Inc\.?| Technologies,? Inc\.?| Products,? L\.?P\.?)?$'}
        'ASUS' {'^(?:ASUSTeK COMPUTER INC\.?|ASUS)$'}
        'Microsoft' {'^Microsoft(?: Corporation)?$'}
        default {throw (New-TinnosError 'TNO-100' 'Unknown desktop utility vendor.')}
    }
    foreach ($entry in $inventory.Entries) {
        try {
            if ($entry.Scope -ne 'HKLM:') {throw (New-TinnosError 'TNO-504' "Remove $($entry.Name) while signed into its owning user account. Its per-user uninstaller was not run as administrator.")}
            if ((Get-Value $entry 'Publisher' '') -notmatch $publisherPattern) {throw (New-TinnosError 'TNO-504' "Publisher mismatch for $($entry.Name). Use the vendor's uninstaller manually.")}
            Send-DeploymentEvent 'Task' $entry.Name 'Running the registered vendor uninstaller.'
            if ($entry.WindowsInstaller -eq 1 -and $entry.Key -match '^\{[0-9A-Fa-f]{8}-(?:[0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}\}$') {
                $null=Invoke-Installer "$env:WINDIR\System32\msiexec.exe" "/x $($entry.Key) /qn /norestart" @(0,1605,1614,3010,1641)
            } else {
                $command=Get-DesktopQuietCommand $entry $definition.Vendor
                $null=Invoke-Installer $command.File $command.Arguments @(0,1605,1614,3010,1641)
            }
        } catch {Add-RunIssue (New-DeploymentIssue 'TNO-504' $_.Exception.Message $entry.Name 'Error' $_)}
    }
    $remaining=Get-DesktopUtilityInventory $Id
    if ($remaining.Entries.Count -or $remaining.Packages.Count -or $remaining.Provisioned.Count) {throw (New-TinnosError 'TNO-504' "$Id still has installed components. Review Errors, reboot if indicated, or uninstall manually.")}
    return [pscustomobject]@{Status='Removed';ProductId=$Id}
}

function Assert-LocalDesktopSettings {
    if ((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).PartOfDomain) { throw (New-TinnosError 'TNO-202' 'This device is domain joined. Apply desktop and taskbar preferences through your administrator to preserve central policy.') }
    $enrollments='HKLM:\SOFTWARE\Microsoft\Enrollments'
    if (Test-Path -LiteralPath $enrollments) {
        foreach ($key in @(Get-ChildItem -LiteralPath $enrollments -ErrorAction Stop)) {
            if ((Get-Value (Get-ItemProperty -LiteralPath $key.PSPath) 'EnrollmentState' 0) -eq 1) { throw (New-TinnosError 'TNO-202' 'MDM enrollment detected. Apply desktop and taskbar preferences centrally.') }
        }
    }
}

function Set-VerifiedDword([string]$Path, [string]$Name, [int]$Value, [switch]$Policy) {
    $old = if (Test-Path -LiteralPath $Path) {Get-Value (Get-ItemProperty -LiteralPath $Path) $Name} else {$null}
    if ($Policy -and $null -ne $old -and [int]$old -ne $Value) { throw (New-TinnosError 'TNO-202' "An existing policy conflicts with $Name at $Path. It was preserved.") }
    $null=New-Item -Path $Path -Force
    $null=New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType DWord -Force
    if ((Get-Value (Get-ItemProperty -LiteralPath $Path) $Name) -ne $Value) { throw (New-TinnosError 'TNO-503' "Could not verify $Name at $Path.") }
}

function Set-SelectedDesktopSetting([ValidateSet('DesktopIcons','TaskbarSearch','TaskbarWidgets','DarkMode')][string]$Setting) {
    Assert-LocalDesktopSettings
    $windows = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    if ($Setting -ne 'DarkMode' -and $windows.EditionID -notmatch 'Professional|Enterprise|Education|IoT') { throw (New-TinnosError 'TNO-503' 'This Windows edition does not support the required desktop/taskbar policy. Use Windows Settings manually.') }
    switch ($Setting) {
        'DesktopIcons' {Set-VerifiedDword 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'NoDesktop' 1 -Policy}
        'TaskbarSearch' {
            if ([int]$windows.CurrentBuildNumber -lt 26100) {throw (New-TinnosError 'TNO-503' 'Taskbar search policy requires Windows 11 24H2 or newer in this tool. Hide search manually in Taskbar settings on this version.')}
            Set-VerifiedDword 'HKLM:\Software\Policies\Microsoft\Windows\Windows Search' 'SearchOnTaskbarMode' 0 -Policy
        }
        'TaskbarWidgets' {Set-VerifiedDword 'HKLM:\Software\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0 -Policy}
        'DarkMode' {
            $profiles=@(Get-CimInstance Win32_UserProfile -ErrorAction Stop | Where-Object {!$_.Special})
            if (!$profiles.Count) {throw (New-TinnosError 'TNO-503' 'No applicable local profiles found for dark mode.')}
            $failed=$false
            foreach ($profile in $profiles) {
                try {
                    Use-ProfileHive $profile {
                        param($Hive)
                        $path="$Hive\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"
                        Set-VerifiedDword $path 'AppsUseLightTheme' 0
                        Set-VerifiedDword $path 'SystemUsesLightTheme' 0
                    }
                    Send-DeploymentEvent 'Success' 'Dark mode' "Configured for $($profile.SID). Sign out and back in to apply."
                } catch { $failed=$true; Add-RunIssue (New-DeploymentIssue 'TNO-503' $_.Exception.Message "Dark mode - $($profile.SID)" 'Error' $_) }
            }
            if ($failed) {throw (New-TinnosError 'TNO-503' 'Dark mode could not be configured for every applicable profile. Retry after unlocking affected profiles.')}
        }
    }
    Send-DeploymentEvent 'Task' $Setting 'Setting verified in the registry. Sign out and back in to apply; Explorer was not force-restarted.'
    return [pscustomobject]@{Status='Configured';Apply='Next sign-in';Setting=$Setting}
}

function Invoke-SelectedDebloat($Config, [string]$Directory) {
    $selectedItems=@($script:DebloatCatalog | Where-Object {$_.Id -in @(Get-Value $Config 'RemoveItems' @('Teams')) -and $_.Id -ne 'Teams'})
    $remaining=$selectedItems.Count
    foreach ($item in $selectedItems) {
        Send-DeploymentEvent 'Task' 'Cleanup queue' "$remaining selected groups left to attempt. Current: $($item.Name). Only checked installation tasks follow cleanup."
        foreach ($package in $item.Packages) {
            Invoke-ApplicationStep $package 'Remove' { Remove-SelectedApp $package $Directory }
        }
        foreach ($service in $item.Services) {
            Invoke-ApplicationStep $service 'Disable' { Disable-SelectedService $service }
        }
        if (Get-Value $item 'DesktopProducts') {Invoke-ApplicationStep $item.Id 'RemoveDesktop' {Remove-DesktopUtility $item.Id}}
        if ((Get-Value $item 'WindowsApp') -eq 'RemoteDesktopConnection') {Invoke-ApplicationStep $item.Id 'RemoveRdc' {Remove-RemoteDesktopConnection}}
        if (Get-Value $item 'Setting') { Invoke-ApplicationStep $item.Name 'Configure' {Set-SelectedDesktopSetting $item.Setting} }
        $remaining--
    }
}

function Invoke-DeploymentSteps($Config, $Office, $Teams, $Policies, [string]$XmlPath, [string]$Directory) {
    $installItems=@(Get-Value $Config 'InstallItems' @('Office','Chrome','GoogleDrive'))
    $removeItems=@(Get-Value $Config 'RemoveItems' @())
    Send-DeploymentEvent 'Task' 'Selected actions' ("Install: {0}. Remove/configure: {1}. Unchecked items will be left alone." -f ($installItems -join ', '),($removeItems -join ', '))
    if (!$installItems.Count -and !$removeItems.Count) {Send-DeploymentEvent 'Success' 'Selection' 'Nothing selected; no system changes requested.';return}
    $script:Report.Steps += 'Create or verify a Windows restore point before deployment changes'
    $restoreOk = Invoke-MaintenanceStep 'Restore point' {$script:Report.RestorePoint = New-DeploymentRestorePoint} 'TNO-201'
    if (!$restoreOk) {
        Send-DeploymentEvent 'Task' 'Recovery' 'Restore point unavailable. Selected system changes were skipped; resolve the restore-point error and retry.'
        return
    }
    $teamsSelected='Teams' -in $removeItems
    $teamsOk=!$teamsSelected; $policyOk=$false
    if ($teamsSelected) {
    $script:Report.Steps += '2 Remove Teams applications and machine-wide installers'
    $dataSafe = Invoke-MaintenanceStep 'Teams applications' {Remove-TeamsApplications $Teams $Config $Directory} 'TNO-203'
    $script:Report.Steps += '3 Remove Teams provisioned packages'
    if ($dataSafe) {$null=Invoke-MaintenanceStep 'Teams provisioning' {Remove-TeamsProvisioning $Teams} 'TNO-203'}
    else {Send-DeploymentEvent 'Task' 'Teams provisioning' 'Skipped because Teams data preservation/removal could not be completed.'}
    # User-context tasks may finish after this process. Never install Office ahead
    # of unresolved per-profile removal, even with Teams excluded in the XML.
    }
    if ('Office' -in $installItems -or $teamsSelected) {
    $script:Report.Steps += '4 Configure supported Teams installation-prevention policy'
    $policyOk=Invoke-MaintenanceStep 'Teams prevention policy' {Set-TeamsPrevention $Policies} 'TNO-202'
    if ($teamsSelected -and 'Office' -in $installItems -and $Config.AppMode -eq 'Install') {$teamsOk=Invoke-MaintenanceStep 'Verify Teams removal' {Assert-TeamsRemovalComplete} 'TNO-203'}
    }
    if ($removeItems.Count) {$null=Invoke-MaintenanceStep 'Selected app and service cleanup' {Invoke-SelectedDebloat $Config $Directory} 'TNO-500'}
    if ('Office' -in $installItems) {
    $script:Report.Steps += "5 $($Config.AppMode) Microsoft 365 Apps with ODT and Teams excluded"
    Invoke-ApplicationStep 'Office' $Config.AppMode {
        if ($Config.AppMode -eq 'Install' -and (!$teamsOk -or !$policyOk)) { throw (New-TinnosError 'TNO-203' 'Office installation skipped until selected Teams removal and prevention policy are verified. Other selected installations will continue.') }
        Install-Office $Config $Office $Policies $XmlPath $Directory
    }
    if ($Config.AppMode -eq 'Install' -and @($script:Report.Applications | Where-Object {$_.Name -eq 'Office' -and $_.Status -in @('Installed','AlreadyInstalled')}).Count) {
        $postOffice=$Config.PSObject.Copy()
        $postOffice.RemoveItems=@($removeItems | Where-Object {$_ -in @('Copilot','NewOutlook')})
        if ($postOffice.RemoveItems.Count) {
            Send-DeploymentEvent 'Task' 'Post-Office cleanup' 'Rechecking selected Copilot and new Outlook packages after Office installation.'
            $null=Invoke-MaintenanceStep 'Post-Office selected removals' {Invoke-SelectedDebloat $postOffice $Directory} 'TNO-500'
        }
    }
    }
    if ('Chrome' -in $installItems) {
    $script:Report.Steps += "6 $($Config.AppMode) Google Chrome"
    Invoke-ApplicationStep 'Chrome' $Config.AppMode { Install-GoogleChrome $Directory -DownloadOnly:($Config.AppMode -eq 'Download') }
    }
    if ('GoogleDrive' -in $installItems) {
    $script:Report.Steps += "7 $($Config.AppMode) Google Drive for desktop"
    Invoke-ApplicationStep 'GoogleDrive' $Config.AppMode { Install-GoogleDrive $Directory -DownloadOnly:($Config.AppMode -eq 'Download') }
    }
    if ($Config.AppMode -eq 'Install' -and 'Chrome' -in $installItems) {
        $script:Report.Steps += '8 Configure Chrome defaults with supported Windows mechanisms'
        Invoke-ApplicationStep 'ChromeDefaults' 'Configure' {
            if (!@((Get-GoogleApps).Chrome).Count) {throw (New-TinnosError 'TNO-404' 'Chrome defaults skipped because Chrome is not installed.')}
            Set-ChromeDefault $Directory $Policies; [pscustomobject]@{Status='Configured'}
        }
    }
}

function Invoke-ApplicationStep([string]$Name, [string]$Action, [scriptblock]$Operation) {
    Send-DeploymentEvent 'Task' $Name "$Action starting"
    try {
        $result = & $Operation
        $status = Get-Value $result 'Status'
        if ($status -notin @('Downloaded','Installed','AlreadyInstalled','Configured','Removed','Disabled','NotPresent','Pending')) { throw (New-TinnosError 'TNO-405' 'The app operation returned no confirmed result.') }
        $script:Report.Applications += [pscustomobject]@{Name=$Name;Action=$Action;Status=$status;Detail=$result;Error=$null}
        Send-DeploymentEvent $(if ($status -eq 'Pending') {'Task'} else {'Success'}) $Name $status
    } catch {
        $message = "$Name $Action failed and was skipped: $($_.Exception.Message)"
        $script:Report.AppIssues += $message
        $defaultCode = if ($Action -eq 'Remove') {'TNO-500'} elseif ($Action -in @('RemoveDesktop','RemoveRdc')) {'TNO-504'} elseif ($Action -eq 'Disable') {'TNO-502'} else {'TNO-404'}
        $issue = New-DeploymentIssue $defaultCode $_.Exception.Message $Name 'Error' $_
        Add-RunIssue $issue
        $script:Report.Applications += [pscustomobject]@{Name=$Name;Action=$Action;Status='Failed';Detail=$null;Error=$_.Exception.Message;ErrorCode=$issue.Code}
    }
}

function Convert-RestorePointTime($Point) {
    if ($Point.CreationTime -is [datetime]) { return $Point.CreationTime.ToUniversalTime() }
    return [Management.ManagementDateTimeConverter]::ToDateTime([string]$Point.CreationTime).ToUniversalTime()
}

function New-DeploymentRestorePoint {
    try {
        $policy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore'
        if (Test-Path -LiteralPath $policy) {
            $settings = Get-ItemProperty -LiteralPath $policy
            if ((Get-Value $settings 'DisableSR' 0) -eq 1 -or (Get-Value $settings 'DisableConfig' 0) -eq 1) {
                throw 'System Restore is disabled by organization policy. Resolve it centrally before deployment.'
            }
        }
        $description = 'TinnosDebloat-Win11 ' + (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ') + ' ' + [guid]::NewGuid().ToString('N').Substring(0,8)
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
        $checkpointError = $null
        $checkpointWarnings = @()
        try {
            Checkpoint-Computer -Description $description -RestorePointType MODIFY_SETTINGS -ErrorAction Stop -WarningAction SilentlyContinue -WarningVariable checkpointWarnings
            if ($checkpointWarnings.Count) {$checkpointError = ($checkpointWarnings | ForEach-Object {[string]$_}) -join ' '}
        }
        catch { $checkpointError = [string]$_ }
        $points = @(Get-ComputerRestorePoint -ErrorAction Stop | Sort-Object SequenceNumber -Descending)
        $created = @($points | Where-Object { $_.Description -eq $description })
        if ($created.Count) {
            return [pscustomobject]@{ Status='Created'; SequenceNumber=$created[0].SequenceNumber; Description=$description; CreatedUTC=(Convert-RestorePointTime $created[0]).ToString('o') }
        }
        # Windows normally limits Checkpoint-Computer to one restore point per day.
        # Accept an existing recent point only when Windows explicitly throttled creation.
        if ($checkpointError -match '24|frequency|frequ.ncia|already.*created|j.*criado' -and $points.Count) {
            $time = Convert-RestorePointTime $points[0]
            $age = (Get-Date).ToUniversalTime() - $time
            if ($age.TotalHours -ge 0 -and $age.TotalHours -lt 24) {
                return [pscustomobject]@{ Status='ReusedRecent'; SequenceNumber=$points[0].SequenceNumber; Description=$points[0].Description; CreatedUTC=$time.ToString('o'); Reason='Windows limited restore-point creation to one point per day. A verified point less than 24 hours old was reused.' }
            }
        }
        throw "A restore point could not be verified. $checkpointError"
    } catch {
        $exception = New-TinnosError 'TNO-201' "Restore point unavailable. Deployment stopped before application removal or installation. $($_.Exception.Message)"
        $exception.Data['PendingAction'] = $true
        throw $exception
    }
}

function Get-ScopedDeploymentInventory($Config, [string]$Phase) {
    $install=@(Get-Value $Config 'InstallItems' @('Office','Chrome','GoogleDrive'));$remove=@(Get-Value $Config 'RemoveItems' @())
    $office=[pscustomobject]@{InventoryAvailable=$false;Present=$false;ProductIds=@();Platform='';Channel='';ExcludedApps=@();Languages=@();Apps=[pscustomobject]@{};OtherOffice=@()}
    $teams=[pscustomobject]@{Errors=@();Packages=@();Provisioned=@();MachineEntries=@();MachineBinaries=@();MachineStartup=@();MachineShortcuts=@();MachineAddinFiles=@();Profiles=@()}
    $policies=[pscustomobject]@{Errors=@();Conflicts=@();PreventTeamsInstall=$null;UpdatePolicies=@();Evidence=@();DomainJoined=$false}
    $google=[pscustomobject]@{Chrome=@();Drive=@()}
    if ('Office' -in $install) {
        try {$office=Get-OfficeState $Config} catch {Add-RunIssue (New-DeploymentIssue 'TNO-200' $_.Exception.Message "$Phase Office inventory" 'Error' $_)}
    }
    if ('Teams' -in $remove) {
        try {$teams=Get-TeamsInventory} catch {$teams.Errors=@([string]$_);Add-RunIssue (New-DeploymentIssue 'TNO-200' $_.Exception.Message "$Phase Teams inventory" 'Error' $_)}
    }
    if ('Teams' -in $remove -or 'Office' -in $install -or 'Chrome' -in $install) {
        try {$policies=Get-PolicyEvidence} catch {$policies.Errors=@([string]$_);Add-RunIssue (New-DeploymentIssue 'TNO-202' $_.Exception.Message "$Phase policy inventory" 'Error' $_)}
    }
    if ($Phase -eq 'After' -and ('Chrome' -in $install -or 'GoogleDrive' -in $install)) {
        try {$google=Get-GoogleApps} catch {Add-RunIssue (New-DeploymentIssue 'TNO-200' $_.Exception.Message 'Google application inventory' 'Error' $_)}
    }
    [pscustomobject]@{Office=$office;Teams=$teams;Policies=$policies;Google=$google}
}

function Assert-ProvisioningHost {
    if (![Environment]::Is64BitProcess) { throw (New-TinnosError 'TNO-102' 'Run 64-bit Windows PowerShell 5.1, including from 32-bit management agents via Sysnative.') }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (!(New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw (New-TinnosError 'TNO-101' 'Administrator privileges are required to inspect every profile and provisioned package.') }
}

function Invoke-CorporateProvisioning([string]$ConfigPath, [ValidateSet('Audit','Plan','Deploy')][string]$Mode, [string]$OutputDirectory) {
    Assert-ProvisioningHost
    $config = Read-DeploymentConfig $ConfigPath
    $mutex = New-Object Threading.Mutex($false, 'Global\TinnosDebloat-Win11CorporateProvisioning')
    $locked = $false
    try {
        try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
        if (!$locked) { throw (New-TinnosError 'TNO-103' 'Another TinnosDebloat-Win11 provisioning run is active.') }
        Initialize-ProtectedDirectory $OutputDirectory
        $directory = Join-Path $OutputDirectory ((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8))
        Initialize-ProtectedDirectory $directory
        $script:Report = [pscustomobject]@{ Mode=$Mode; Status='Running'; Computer=$env:COMPUTERNAME; StartedUTC=(Get-Date).ToUniversalTime().ToString('o'); FinishedUTC=$null
            Configuration=$config; Steps=@(); Operations=@(); Downloads=@(); Applications=@(); AppIssues=@(); Issues=@(); PreservedData=@(); UserCleanup=@(); Errors=@(); Pending=@(); Notes=@(); Checks=@(); RestorePoint=$null; RebootRequired=$false; RebootReasons=@(); Before=$null; After=$null; Activation=$null }
        try {
            $script:Report.Steps += '1 Detect existing Office and Teams'
            Send-DeploymentEvent 'Task' 'Inventory' 'Detecting Office, Teams and policy settings.'
            $before=Get-ScopedDeploymentInventory $config 'Before'
            $office=$before.Office;$teams=$before.Teams;$policies=$before.Policies
            $script:Report.Before = [pscustomobject]@{ Office=$office; Teams=$teams; Policies=$policies }
            $xmlPath = Join-Path $directory 'office-configuration.xml'
            if ('Office' -in $config.InstallItems) {$null=Invoke-MaintenanceStep 'Office configuration' {$null=New-OfficeConfiguration $config $office $xmlPath} 'TNO-100'}
            if ($Mode -eq 'Deploy') {
                Invoke-DeploymentSteps $config $office $teams $policies $xmlPath $directory
            }
        } catch {
            if ($_.Exception.Data.Contains('PendingAction')) { $script:Report.Pending += [string]$_ }
            else { $script:Report.Errors += [string]$_ }
            Add-RunIssue (New-DeploymentIssue 'TNO-900' $_.Exception.Message 'Deployment' $(if ($_.Exception.Data.Contains('PendingAction')) {'Pending'} else {'Error'}) $_)
        }
        # Validate even after an installer/policy error. Empty/failed enumeration never proves absence.
        $script:Report.Steps += '9 Validate application results, Teams absence and policies; activation deferred'
        Send-DeploymentEvent 'Task' 'Final verification' 'Checking applications, selected removals, services and policies.'
        try {
            $after=Get-ScopedDeploymentInventory $config 'After'
            $office=$after.Office;$teams=$after.Teams;$policies=$after.Policies;$google=$after.Google
            if ('Teams' -in $config.RemoveItems) {Get-UserCleanupResults $teams -RemoveCompleted:($Mode -eq 'Deploy')}
            $script:Report.RebootReasons = @(Get-PendingRebootReasons)
            if ($script:Report.RebootReasons.Count) { $script:Report.RebootRequired = $true }
            $script:Report.After = [pscustomobject]@{ Office=$office; Teams=$teams; Policies=$policies; Google=$google }
            $script:Report.Checks = @(Get-DeploymentChecks $config $office $teams $policies $google $directory $Mode $script:Report.Applications)
            $script:Report.Errors += @($teams.Errors)
            foreach ($message in @($teams.Errors)) { Add-RunIssue (New-DeploymentIssue 'TNO-200' $message 'Inventory') }
            if ('Office' -in $config.InstallItems -or 'Teams' -in $config.RemoveItems) {
                $script:Report.Errors += @($policies.Errors) + @($policies.Conflicts)
                foreach ($message in $policies.Errors) {Add-RunIssue (New-DeploymentIssue 'TNO-200' $message 'Policy inventory')}
                foreach ($message in $policies.Conflicts) { Add-RunIssue (New-DeploymentIssue 'TNO-202' $message 'Policy') }
            }
            $script:Report.Activation = [pscustomobject]@{Status='Deferred';Reason='No sign-in, activation or license-status query attempted. An employee may activate Office later using their licensed account.'}
            if ($Mode -eq 'Deploy' -and $config.AppMode -eq 'Install') {
                foreach ($check in @($script:Report.Checks | Where-Object {$_.Category -eq 'Application' -and !$_.Pass})) {
                    $script:Report.AppIssues += "Application validation did not pass: $($check.Name). See the check evidence; cleanup results remain separate."
                    Add-RunIssue (New-DeploymentIssue 'TNO-404' "Application validation did not pass: $($check.Name)." 'Application validation')
                }
            }
            $script:Report.Status = Get-DeploymentStatus $script:Report.Checks $script:Report.Errors $script:Report.RebootRequired $script:Report.Pending $script:Report.AppIssues
            if ($Mode -eq 'Plan' -and !$script:Report.Errors.Count) { $script:Report.Status = 'Planned' }
        } catch { $script:Report.Errors += "Validation: $_"; $script:Report.Status = 'Failed'; Add-RunIssue (New-DeploymentIssue 'TNO-200' $_.Exception.Message 'Validation' 'Error' $_) }
        foreach ($message in $script:Report.Pending) {
            if ($message -notlike 'Remote Desktop Connection removal*') {Add-RunIssue (New-DeploymentIssue 'TNO-203' $message 'Cleanup' 'Pending')}
        }
        foreach ($task in $script:Report.UserCleanup) {
            if ($task.LastTaskResult -notin @(0,3010,267009,267011) -and @($script:Report.Pending | Where-Object {$_ -like "*$($task.TaskName)*"}).Count) { Add-RunIssue (New-DeploymentIssue 'TNO-206' "Cleanup task $($task.TaskName) returned $($task.LastTaskResult)." 'User cleanup' 'Pending') }
        }
        if ($script:Report.RebootRequired) { Add-RunIssue (New-DeploymentIssue 'TNO-207' 'A reboot is required before final verification.' 'Cleanup' 'Pending') }
        foreach ($check in @($script:Report.Checks | Where-Object {$_.Required -and !$_.Pass})) {
            Add-RunIssue (New-DeploymentIssue $(if ($check.Name -eq 'TeamsPreventionPolicy') {'TNO-202'} elseif ($check.Category -eq 'Application') {'TNO-404'} elseif ($check.Category -eq 'Debloat') {$check.ErrorCode} else {'TNO-203'}) "Check did not pass: $($check.Name)." 'Final verification')
        }
        if ($script:Report.Status -eq 'Complete' -and @($script:Report.Issues | Where-Object {$_.Severity -eq 'Error'}).Count) {$script:Report.Status='CompletedWithIssues'}
        $script:Report.FinishedUTC = (Get-Date).ToUniversalTime().ToString('o')
        $script:Report.Steps += '10 Return results to the application in memory'
        [pscustomobject]@{ Status=$script:Report.Status; Report=$script:Report }
    } finally { if ($locked) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}

Export-ModuleMember -Function *
