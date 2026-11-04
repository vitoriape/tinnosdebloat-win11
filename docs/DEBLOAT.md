# Removal, services and desktop settings

Expand **Choose apps, services and desktop settings** in the application. Only checked entries are applied; Teams removal is required. The catalog uses exact package and service names, never a broad Microsoft or Xbox wildcard. The interface and engine share `debloat-catalog.json`.

## Apps

| Selection ID | App | Exact Store package names |
| --- | --- | --- |
| `Clipchamp` | Clipchamp | `Clipchamp.Clipchamp` |
| `Copilot` | Copilot app | `Microsoft.Copilot`, `Microsoft.CopilotDev` |
| `NewOutlook` | Outlook (new Windows app) | `Microsoft.OutlookForWindows` |
| `Family` | Microsoft Family | `MicrosoftCorporationII.MicrosoftFamily` |
| `Maps` | Windows Maps | `Microsoft.WindowsMaps` |
| `GameBar` | Xbox Game Bar | `Microsoft.XboxGamingOverlay`, `Microsoft.XboxGameOverlay` |
| `FeedbackHub` | Feedback Hub | `Microsoft.WindowsFeedbackHub` |
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

Teams uses its separate official bootstrapper, Appx/provisioning and supported legacy uninstallers. Classic Outlook is part of the required Office deployment; **NewOutlook** removes only `Microsoft.OutlookForWindows`. Games means the listed Microsoft casual games, not arbitrary games or their documents. Copilot means the listed Store apps, not removal of Windows shell components or Microsoft 365 shared files. Legacy non-Store Quick Assist/Paint versions are outside this package-only selection.

Installed packages are removed for all applicable users, and matching provisioned packages are removed for future users. App data in existing nonspecial local profiles is copied into an administrator/SYSTEM-only `PreservedAppData` directory before Appx removal. Unreadable, locked or redirected data prevents removal of that app. No documents or shared frameworks are recursively deleted. Close apps first; the tool does not force-close them. Windows may reject protected/nonremovable packages. Reboot or sign in and retry when directed. Future Store, Windows or organization assignments may reinstall apps; this utility does not claim to block every deployment source.

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

Each selected package, service and preference is a separate operation. Failures appear immediately in both Log and Errors; other tasks continue. A restore-point failure skips all system changes and permits only independent app downloads. Pending Teams cleanup or policy verification blocks Office installation; Chrome and Drive can still run. A task marked Removed/Disabled is verified again at the end. Remaining components or unreadable inventory prevent a claim of full cleanup. The separate Results screen has been removed.

## Sources

- [Microsoft ODT overview](https://learn.microsoft.com/en-us/microsoft-365-apps/deploy/overview-office-deployment-tool)
- [All-user Appx removal](https://learn.microsoft.com/en-us/powershell/module/appx/remove-appxpackage?view=windows-11)
- [Google Drive silent installation options](https://knowledge.workspace.google.com/admin/drive/set-up-drive-for-desktop-for-your-organization)
- [Hide desktop items policy](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-admx-desktop#nodesktop)
- [Search policy](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-search)
- [Widgets policy](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-newsandinterests)
