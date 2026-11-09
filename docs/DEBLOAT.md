# Removal, services and desktop settings

Select installations in **EQUIP GEAR** and removals/preferences in **REMOVE WASPS**.
Checked means execute the named action; unchecked means leave it alone. Every app
line starts with **Uninstall**, every service line with **Deactivate**. Desktop
preferences use **Hide**, **Enable** or **Set**. Teams removal can also be unchecked; Teams
is always excluded from Office regardless. The catalog uses exact package and
service names, never a broad Microsoft or Xbox wildcard. The interface and engine
share `debloat-catalog.json`; the upper-right jade pendant is a visual reference.

## Apps

| Selection ID | App | Exact Store package names |
| --- | --- | --- |
| `Clipchamp` | Clipchamp | `Clipchamp.Clipchamp` |
| `Copilot` | Copilot + Microsoft 365 Copilot | `Microsoft.Copilot`, `Microsoft.CopilotDev`, `Microsoft.MicrosoftOfficeHub` |
| `NewOutlook` | Outlook (new Windows app) | `Microsoft.OutlookForWindows` |
| `Family` | Microsoft Family | `MicrosoftCorporationII.MicrosoftFamily` |
| `Maps` | Windows Maps | `Microsoft.WindowsMaps` |
| `GameBar` | Xbox Game Bar | `Microsoft.XboxGamingOverlay`, `Microsoft.XboxGameOverlay` |
| `FeedbackHub` | Feedback Hub | `Microsoft.WindowsFeedbackHub` |
| `PowerAutomate` | Power Automate (Store / desktop) | `Microsoft.PowerAutomateDesktop`; registered desktop editions are checked separately |
| `ToDo` | Microsoft To Do | `Microsoft.Todos` |
| `MoviesTV` | Movies & TV | `Microsoft.ZuneVideo` |
| `News` | Microsoft News | `Microsoft.BingNews` |
| `Paint` | Microsoft Paint | `Microsoft.Paint`, `Microsoft.MSPaint` |
| `QuickAssist` | Quick Assist (Store app) | `MicrosoftCorporationII.QuickAssist` |
| `Games` | Microsoft casual games / Solitaire | `Microsoft.MicrosoftSolitaireCollection`, `Microsoft.MicrosoftMahjong`, `Microsoft.MicrosoftMinesweeper`, `Microsoft.MicrosoftJigsaw`, `Microsoft.MicrosoftSudoku` |
| `StickyNotes` | Sticky Notes | `Microsoft.MicrosoftStickyNotes` |
| `Terminal` | Windows Terminal | `Microsoft.WindowsTerminal`, `Microsoft.WindowsTerminalPreview` |
| `Xbox` | Xbox apps | `Microsoft.GamingApp`, `Microsoft.XboxApp`, `Microsoft.Xbox.TCUI`, `Microsoft.XboxIdentityProvider`, `Microsoft.XboxSpeechToTextOverlay` |
| `Weather` | Weather | `Microsoft.BingWeather` |

Teams uses its separate official bootstrapper, Appx/provisioning and supported legacy uninstallers when selected. Office includes Word, Excel and PowerPoint; **OneNote, OneDrive, Access, classic Outlook and new Outlook are always excluded** from ODT. **NewOutlook** separately removes the existing Windows package `Microsoft.OutlookForWindows` when checked. Existing standalone Office products and OneDrive data are not force-deleted. Games means the listed Microsoft casual games, not arbitrary games or their documents. Copilot means the listed Store apps, not removal of Windows shell components or Microsoft 365 shared files. The separate companion-app package is `Microsoft.M365Companions`, covering People, Files and Calendar. Legacy non-Store Quick Assist/Paint versions are outside this package-only selection.

### Why something may remain after cleanup

Detection uses language-independent package IDs, service names and the `mstsc.exe`
path, rather than the translated app name. The Microsoft 365 Copilot shell uses a
different package (`Microsoft.MicrosoftOfficeHub`) from consumer Copilot; both are
now covered by the Copilot selection. When Office is installed, selected Copilot
and new Outlook removals are attempted again afterward and verified at the end.
Microsoft 365 can deploy its Copilot app automatically; organization deployment
settings still need to be managed centrally to prevent a later reinstall.
[Microsoft deployment FAQ](https://learn.microsoft.com/en-us/microsoft-365-copilot/faq-deploy-microsoft-365-copilot-app).

Unchecked services/apps are intentionally left intact. Remote Desktop Connection
needs Windows 11 23H2+ and its Windows prompt may require user confirmation/reboot.
App locks, profile access, service dependencies and GPO/Intune ownership can also
block an action. These conditions appear in Errors; they are not counted as a
successful removal. Service verification waits for Stopped before setting Disabled
and checks both values again at the end. No force-stop of dependent services or
central policy override is attempted. See `TNO-202`, `TNO-403`, `TNO-500`, `TNO-502`
and `TNO-504` in [the error map](ERROR_CODES.md).

Installed packages are removed for all applicable users, and matching provisioned packages are removed for future users. App data in existing nonspecial local profiles is copied into an administrator/SYSTEM-only `PreservedAppData` directory before Appx removal. Unreadable, locked or redirected data prevents removal of that app. No documents or shared frameworks are recursively deleted. Close apps first; the tool does not force-close them. Windows may reject protected/nonremovable packages. Reboot or sign in and retry when directed. Future Store, Windows or organization assignments may reinstall apps; this utility does not claim to block every deployment source.

## Dell, ASUS and desktop utilities

These are separate checklist entries, not a blanket vendor removal. Hardware
drivers, ASUS System Control Interface/hotkey components, unrelated Dell Core Services,
Dell Command Update, firmware and recovery partitions are outside this list.
Feedback Hub (Hub de comentarios) and Xbox Live were already covered by
`FeedbackHub`, `Xbox` and `XboxServices`; they are not duplicate removals.

| Selection | Covered utilities | Default |
| --- | --- | --- |
| `DellSupportAssist` | Dell SupportAssist, SupportAssistAgent / SupportAssist Agent | Selected |
| `DellDigitalDelivery` | Digital Delivery Store app, desktop app and Services entry | Selected |
| `DellCustomerConnect` | Dell Customer Connect Store/desktop app | Selected |
| `ASUSGiftbox` | ASUS GIFTBOX Store/desktop promotional app | Selected |
| `DellOptimizer` | Optimizer/Core/Service/UI/Precision Optimizer; affects power/performance settings | Selected |
| `DellRecoveryHelpers` | SupportAssist Remediation and OS Recovery Plugin for Dell Update; affects OEM recovery features | Unchecked |
| `MyASUS` | MyASUS (`B9ECED6F.ASUSPCAssistant`) and matching desktop entry; affects battery/device preferences | Unchecked |
| `ASUSArmouryCrate` | Armoury Crate / SE app and registered service products; official complete-uninstall workflow | Unchecked |

Native removal requires an exact catalog product name and expected registry
publisher. A registered MSI product uses its product GUID with Windows Installer.
Desktop products use registered uninstall commands pointing to a signature-verified
Microsoft, Dell, ASUS or McAfee executable under trusted local directories. Dell
and McAfee can fall back to the registered interactive command when quiet mode
is unavailable; no silent switches are guessed. Unsupported commands are not guessed or passed to a shell; they
produce `TNO-504` and a manual removal instruction. Per-user desktop registrations
require the owning account. OneDrive supports a limited-token cleanup task; other
per-user native products are reported for removal in that account.
Inventory errors prevent a claim of complete removal.

Power Automate covers the Store app and recognized Microsoft desktop installer
entries. Store data is preserved through the existing Appx backup mechanism.
Desktop editions use their registered uninstallers; no user flow directories or
documents are force-deleted. Shared machine-runtime components are not broadly
matched or removed by a Power Automate wildcard.

Dell recommends a normal uninstall rather than deleting SupportAssist files or
registry trees. This utility follows the registered uninstaller path and leaves
remaining components as explicit errors. [Dell SupportAssist guidance](https://www.dell.com/support/kbdoc/en-us/000131491/supportassist-for-pcs-and-tablets-clean-uninstall-and-reinstall).

Armoury Crate needs ASUS's dedicated complete uninstall tool and a reboot; this
selection detects it and reports the official instructions instead of removing
only its Store front end. No undocumented silent switches are assumed.
[ASUS Armoury Crate instructions](https://www.asus.com/support/faq/1041654/).

Uninstalling a utility does not prevent a BIOS installer, Windows Update, Microsoft
Store or organization deployment from reinstalling it later. The tool does not
change firmware settings or delete recovery images to prevent reinstalls.

## Remote Desktop Connection client

`RemoteDesktopConnection` removes the built-in client (`mstsc.exe`). It is a
separate, unchecked-by-default entry from `RemoteDesktop`, which disables the
incoming Remote Desktop Services (`TermService`). On Windows 11 23H2 or newer,
the tool runs the signed Microsoft `System32\mstsc.exe /uninstall` with the Windows
prompt visible. Choose restart later so other tasks can finish. It never uses
`/noPromptBeforeRestart`, because that switch restarts without confirmation.
[Microsoft's supported procedure](https://learn.microsoft.com/en-us/windows-server/remote/remote-desktop-services/remotepc/uninstall-remote-desktop-connection).

Active outgoing `mstsc` sessions block this removal until closed. Saved `.rdp`
files are not deleted. Both System32 and SysWOW64 client paths are checked; if a
client remains, the run records a pending action rather than claiming removal.
Complete the Windows prompt, restart if requested, and run the tool again.
Older Windows versions receive `TNO-504` and are left intact. Removing this client
also affects the RemoteApp and Desktop Connections control panel. Reinstallation
is available from the Microsoft page linked above.

## Services

These are service startup changes, equivalent to disabling the selected service through Services. Each service must be both stopped and Disabled to pass verification. No dependent services are force-stopped. The previous startup mode and state appear in the live Log.

| Selection ID | Effect / service | Exact service names | Selected by default |
| --- | --- | --- | --- |
| `SearchIndexing` | Disable Windows Search indexing (affects Outlook search) | `WSearch` | Yes |
| `XboxServices` | Disable Xbox background services | `XboxGipSvc`, `XblAuthManager`, `XblGameSave`, `XboxNetApiSvc` | Yes |
| `ServerService` | Disable Server / SMB file sharing (LanmanServer) | `LanmanServer` | No - explicit opt-in |
| `AutoTimeZone` | Disable automatic time-zone updates (tzautoupdate) | `tzautoupdate` | Yes |
| `SmartCard` | Disable Smart Card / card sign-in (SCardSvr) | `SCardSvr` | No - explicit opt-in |
| `ParentalControls` | Disable Parental Controls (WpcMonSvc) | `WpcMonSvc` | No - explicit opt-in |
| `SshAgent` | Disable OpenSSH Authentication Agent (ssh-agent) | `ssh-agent` | No - explicit opt-in |
| `RemoteRegistry` | Disable Remote Registry (RemoteRegistry) | `RemoteRegistry` | Yes |
| `RoutingRemoteAccess` | Disable Routing and Remote Access / VPN (RemoteAccess) | `RemoteAccess` | No - explicit opt-in |
| `Biometrics` | Disable fingerprint / biometric sign-in (WbioSrvc) | `WbioSrvc` | No - explicit opt-in |
| `NetTcpPortSharing` | Disable Net.Tcp Port Sharing (NetTcpPortSharing) | `NetTcpPortSharing` | No - explicit opt-in |
| `BitLockerService` | Disable BitLocker management service (BDESVC) | `BDESVC` | No - explicit opt-in |
| `PhoneService` | Disable Phone Service (PhoneSvc) | `PhoneSvc` | Yes |
| `RemoteDesktop` | Disable Remote Desktop Services (TermService) | `TermService` | No - explicit opt-in |
| `SharedPc` | Disable Shared PC Account Manager (shpamsvc) | `shpamsvc` | No - explicit opt-in |
| `Telephony` | Disable Telephony / dial-up (TapiSrv) | `TapiSrv` | No - explicit opt-in |

Disabling **WSearch** stops indexing and can affect Start/File Explorer and classic Outlook search speed and results; existing index files are not deleted. Xbox service changes can affect controllers, sign-in and game saves. Server/SMB, VPN, Smart Card, OpenSSH agent, biometrics, Shared PC and Remote Desktop changes can interrupt their respective work features. Disabling BDESVC affects BitLocker management; this tool never decrypts disks, disables protection or changes recovery keys. Parental Controls changes affect family controls. Higher impact service choices start unchecked in both the GUI and the sample config.

Start-menu app and settings search can still work after indexing is disabled: these results are not stored in the file index ([Microsoft explanation](https://devblogs.microsoft.com/windows-search-platform/configuration-and-settings/)). A working Start search does not mean indexing is running. Select **Deactivate Windows Search indexing** under REMOVE WASPS and press **Start**. The success log must confirm `WSearch`, `State: Stopped; startup: Disabled`. You can also verify on the target PC with `Get-Service WSearch | Select-Object Name, Status, StartType`. Hiding the taskbar search box is a separate desktop preference.

Group Policy service ownership and MDM enrollment are checked. Managed, unreadable or conflicting settings are skipped with `TNO-202`; apply them centrally. Access/dependency failures are reported without forcing other services to stop. The tool does not disable Defender, Windows Update, RPC, networking or arbitrary background processes. To undo a service change, use `services.msc` and the previous startup mode recorded in this session, or a verified System Restore point.

## Desktop, taskbar and appearance

| Selection ID | Per-profile setting |
| --- | --- |
| `DesktopIcons` | `Explorer\Advanced\HideIcons=1`; desktop files remain intact |
| `TaskbarSearch` | `Search\SearchboxTaskbarMode=0`; works without the former 24H2 policy gate |
| `TaskbarWidgets` | `Explorer\Advanced\TaskbarDa=0`; hides the Widgets/news/weather taskbar entry |
| `DarkMode` | `AppsUseLightTheme=0`, `SystemUsesLightTheme=0` |
| `AccentGold` | Yellow gold / Ouro Amarelo `#FFB900`; manual accent for supported Windows surfaces |
| `BackgroundMoss` | Solid Moss / Musgo `#486860` (`72 104 96`), clears the wallpaper preference without deleting the image |

All six are selected by default. They target existing nonspecial local user hives,
including accessible offline profiles. They do not change the template for future
users. The tool no longer requires Pro or 24H2 just to set user preferences.
Effective GPO/MDM restrictions are checked per setting; existing policy values are
never overwritten. A domain join alone is not a conflict. Inaccessible profiles
and conflicting policies are reported, while other profiles continue.

A Windows shell refresh is requested for the account executing the tool. Other
active accounts, and Explorer caches that do not respond to the refresh, require
sign-out/sign-in. Registry verification confirms saved preferences, not every app's
visual response. Dark mode cannot force unrelated third-party apps to use a theme.
Final validation re-reads the saved values; it does not trust only an earlier
Configured result. Unchecking an action leaves the current state unchanged and
does not undo a previous change. No Explorer sessions are forcibly terminated.

## Additional native removals

- `DellConnectedServiceDelivery`: exact DCSD service/application and Subagent
  product entries. The registered service uninstaller owns service teardown;
  drivers, firmware and recovery partitions are not force-deleted. Removing only
  the Subagent can allow the DCSD service to restore it, so both are covered.
- `DellSupportAssist`: includes Home/Business variants and PC Analytics.
- `DellOptimizer`: Optimizer/Core/Service/UI/Precision Optimizer; checked by default.
- `Microsoft365Companions`: exact `Microsoft.M365Companions` Appx registrations and
  provisioned package, plus known registered desktop names. Selected removal runs
  again after Office. Calendar, contacts and files are not deleted from Microsoft 365.
- `OneDrive`: exact registered Microsoft OneDrive product. An Office exclusion
  prevents ODT inclusion but does not remove an existing sync client; this selection
  does. Machine products use their registered uninstaller. Per-user installations
  are queued under the owning account's limited interactive token and reported
  Pending until a later run verifies absence. The idempotent user task runs at
  sign-in; no user-owned executable is launched with administrator privileges.
  Synced folders and cloud files are preserved; online-only files are not downloaded
  or deleted by uninstalling the client. Finish any sync work before removal.
- `McAfeeWebAdvisor`: WebAdvisor only, including the Portuguese display name;
  other antivirus products and browser profiles are left alone. A McAfee prompt
  can appear if the registered uninstaller has no quiet mode. No general MCPR
  removal of the entire security suite is attempted.
- `RemoteDesktopConnection`: checked by default and still uses Microsoft's
  `mstsc.exe /uninstall` on Windows 11 23H2+. Complete the visible Windows prompt;
  choose restart later and restart afterward if requested. No unsupported silent
  switches or automatic reboot are used, and saved `.rdp` files remain intact.

Native removal requires an exact product name and matching publisher. MSI entries
use their registered product GUID; EXE uninstallers require a valid vendor
signature and a trusted local application path. Dell/McAfee may use their
registered interactive command if no quiet one exists. A locked user hive no
longer prevents trying machine-wide removal, but absence remains unverified if
that profile cannot be inspected. No leftover entry is reported as removed.

References: [Dell DCSD lifecycle](https://www.dell.com/support/kbdoc/en-us/000367384/dell-connected-service-delivery-reinstallation-after-removal),
[Microsoft companion removal](https://learn.microsoft.com/en-us/microsoft-365-apps/companions/companion-app-retirement),
[Remote Desktop Connection removal](https://learn.microsoft.com/en-us/windows-server/remote/remote-desktop-services/remotepc/uninstall-remote-desktop-connection),
[ODT exclusion IDs](https://learn.microsoft.com/en-us/microsoft-365-apps/deploy/office-deployment-tool-configuration-options),
[WebAdvisor removal](https://www.mcafee.com/support/s/article/000001669?language=en_US).

## Downloads and failure handling

Google Drive is installed with `--silent --skip_launch_new --gsuite_shortcuts=false`; `--desktop_shortcut` is omitted. This prevents new Docs/Sheets/Slides and Drive desktop shortcuts; shortcuts from earlier installations are not deleted. Google account sign-in is never requested.

Each selected package, service and preference is a separate operation. Failures
appear immediately in Log and Errors; other independent selected tasks continue.
No installation or cleanup is added implicitly. A restore-point failure skips
selected system changes and does not turn an installation request into a download.
When Teams removal is checked, pending Teams cleanup blocks Office installation;
Office prevention-policy verification is also required. Other selected installs
can continue. Removed/Disabled is verified again at the end. Remaining selected
components or unreadable relevant inventory prevent a claim of full cleanup.
An empty selection does nothing. Unchecking an item later does not undo a previous
change or cancel pending user-cleanup tasks created in a prior run.

## Sources

- [Microsoft ODT overview](https://learn.microsoft.com/en-us/microsoft-365-apps/deploy/overview-office-deployment-tool)
- [All-user Appx removal](https://learn.microsoft.com/en-us/powershell/module/appx/remove-appxpackage?view=windows-11)
- [Google Drive silent installation options](https://knowledge.workspace.google.com/admin/drive/set-up-drive-for-desktop-for-your-organization)
- [Hide desktop items policy](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-admx-desktop#nodesktop)
- [Search policy](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-search)
- [Widgets policy](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-newsandinterests)
- [Dell Digital Delivery removal](https://www.dell.com/support/kbdoc/en-us/000200562/how-to-uninstall-dell-digital-delivery)
- [MyASUS removal](https://www.asus.com/uk/support/faq/1045109/)
- [Power Automate installation types](https://learn.microsoft.com/en-us/power-automate/desktop-flows/install)
