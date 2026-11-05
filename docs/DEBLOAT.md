# Removal, services and desktop settings

Select installations in **EQUIP GEAR** and removals/preferences in **REMOVE WASPS**.
Checked means execute the named action; unchecked means leave it alone. Every app
line starts with **Uninstall**, every service line with **Deactivate**. Desktop
preferences use **Hide** or **Enable**. Teams removal can also be unchecked; Teams
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

Teams uses its separate official bootstrapper, Appx/provisioning and supported legacy uninstallers when selected. Office includes Word, Excel, PowerPoint and OneNote; **OneDrive, Access, classic Outlook and new Outlook are always excluded** from ODT. **NewOutlook** separately removes the existing Windows package `Microsoft.OutlookForWindows` when checked. Existing standalone Office products and OneDrive data are not force-deleted. Games means the listed Microsoft casual games, not arbitrary games or their documents. Copilot means the listed Store apps, not removal of Windows shell components or Microsoft 365 shared files. Legacy non-Store Quick Assist/Paint versions are outside this package-only selection.

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
drivers, ASUS System Control Interface/hotkey components, Dell Core Services,
Dell Command Update, firmware and recovery partitions are outside this list.
Feedback Hub (Hub de comentarios) and Xbox Live were already covered by
`FeedbackHub`, `Xbox` and `XboxServices`; they are not duplicate removals.

| Selection | Covered utilities | Default |
| --- | --- | --- |
| `DellSupportAssist` | Dell SupportAssist, SupportAssistAgent / SupportAssist Agent | Selected |
| `DellDigitalDelivery` | Digital Delivery Store app, desktop app and Services entry | Selected |
| `DellCustomerConnect` | Dell Customer Connect Store/desktop app | Selected |
| `ASUSGiftbox` | ASUS GIFTBOX Store/desktop promotional app | Selected |
| `DellOptimizer` | Dell Optimizer and Optimizer Core; affects power/performance settings | Unchecked |
| `DellRecoveryHelpers` | SupportAssist Remediation and OS Recovery Plugin for Dell Update; affects OEM recovery features | Unchecked |
| `MyASUS` | MyASUS (`B9ECED6F.ASUSPCAssistant`) and matching desktop entry; affects battery/device preferences | Unchecked |
| `ASUSArmouryCrate` | Armoury Crate / SE app and registered service products; official complete-uninstall workflow | Unchecked |

Native removal requires an exact catalog product name and expected registry
publisher. A registered MSI product uses its product GUID with Windows Installer.
Other desktop products need a registered `QuietUninstallString` pointing to an
authenticode-verified Microsoft, Dell or ASUS executable under local application
directories. Unsupported commands are not guessed or passed to a shell; they
produce `TNO-504` and a manual removal instruction. Per-user desktop registrations
are detected but must be uninstalled while signed into the owning account.
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

Group Policy service ownership and MDM enrollment are checked. Managed, unreadable or conflicting settings are skipped with `TNO-202`; apply them centrally. Access/dependency failures are reported without forcing other services to stop. The tool does not disable Defender, Windows Update, RPC, networking or arbitrary background processes. To undo a service change, use `services.msc` and the previous startup mode recorded in this session, or a verified System Restore point.

## Desktop, taskbar and dark mode

| Selection ID | Setting | Scope / application |
| --- | --- | --- |
| `DesktopIcons` | Hide desktop items using `NoDesktop=1` | Device policy; leaves files intact; sign out/in |
| `TaskbarSearch` | Hide search using `SearchOnTaskbarMode=0` | Windows 11 24H2+ policy; sign out/in |
| `TaskbarWidgets` | Disable Widgets news/weather using `AllowNewsAndInterests=0` | Device policy; applies to the entire Widgets experience |
| `DarkMode` | `AppsUseLightTheme=0`, `SystemUsesLightTheme=0` | Existing nonspecial local user profiles, including offline hives when accessible |

All four are selected by default. Dark mode affects Windows and apps that honor the Windows preference; it cannot force every third-party app to use a dark theme. New user profiles are not given a dark-mode default by this tool. Device desktop/taskbar policies require Pro, Enterprise, Education or IoT editions; unsupported versions/editions receive `TNO-503` and can be configured manually through Windows Settings. Explorer is not force-restarted, so existing sessions may need sign-out/sign-in.

Domain-joined or MDM-enrolled devices receive `TNO-202` for these local visual settings so organization configuration can be applied centrally. Existing opposite policy values are preserved. Files are hidden, not deleted. Uncheck a visual setting before Start to leave it alone; unchecking on a later run does not undo a previous change. Restore the policy/preferences manually or use System Restore.

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
