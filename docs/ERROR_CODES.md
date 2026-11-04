# Error codes

TinnosDebloat-Win11 uses stable `TNO-xxx` identifiers in Details > Errors. The original message and recovery action appear beside each code. Codes are shared by the launcher and engine through `error-codes.json`.

Codes describe a condition; severity determines whether it is an error, warning or pending action. `TNO-306` is normally a fallback warning. A pending reboot or profile cleanup must be resolved before complete removal can be confirmed. Vendor exit codes are displayed separately and do not replace these identifiers.

| Code | Condition | Recovery action |
| --- | --- | --- |
| `TNO-100` | Invalid configuration | Use the supplied config. Office language must be pt-br. |
| `TNO-101` | Administrator access required | Run the application with administrator access. |
| `TNO-102` | Unsupported process architecture | Use the x64 application and 64-bit Windows PowerShell. |
| `TNO-103` | Another run is active | Wait for the current run to finish. |
| `TNO-104` | Working directory unavailable | Check disk space, permissions and redirected/reparse paths. |
| `TNO-200` | Inventory incomplete | Unlock or attach the affected profile and retry. Absence cannot be certified. |
| `TNO-201` | Restore point unavailable | Check System Protection and organization policy, then retry. |
| `TNO-202` | Managed policy conflict | Resolve the conflicting GPO or Intune setting centrally. |
| `TNO-203` | Teams removal pending | Close Teams/Outlook, sign into affected profiles, or reboot as indicated, then retry. |
| `TNO-204` | Teams data preservation failed | Close Teams and resolve locked, redirected or unreadable data before removal. |
| `TNO-205` | Unsupported legacy uninstaller | Use the affected component's supported uninstaller in the correct user account. |
| `TNO-206` | User cleanup task needs attention | Sign into the affected account and retry; check Task Scheduler if it still fails. |
| `TNO-207` | Reboot required | Restart Windows, then run the application again. |
| `TNO-300` | DNS resolution failed | Check network DNS and access to the displayed official download host. |
| `TNO-301` | Download connection failed | Check internet, proxy, TLS and firewall access. No credentials are requested. |
| `TNO-302` | Download timed out | Check the connection and retry. |
| `TNO-303` | Publisher signature invalid | Do not run the file. Retry the official download and check certificate/proxy inspection. |
| `TNO-304` | Download empty or missing | Retry the transfer; verify the file has nonzero size. |
| `TNO-305` | Unapproved download origin | Use the built-in HTTPS Microsoft or Google download source. |
| `TNO-306` | ODT discovery fallback used | The official archive fallback is being used. Check the discovery host if it persists. |
| `TNO-307` | Unexpected ODT executable | Retry the official ODT package; the executable was not accepted as Office setup. |
| `TNO-400` | Installer or uninstaller failed | Use the native exit code shown in Details to troubleshoot the vendor installer. |
| `TNO-401` | Existing Office is incompatible | Plan an Office product/architecture migration; automatic removal is disabled. |
| `TNO-402` | Office media incomplete | Retry the Office download; the media files did not pass validation. |
| `TNO-403` | Application is still open | Save documents, close the indicated app and retry. |
| `TNO-404` | Application validation failed | Review the app result and retry the failed download or installation. |
| `TNO-405` | Application returned no confirmed result | Retry and review Details; success could not be verified. |
| `TNO-900` | Unexpected engine error | Review Details and report the code and message to the project maintainer. |
| `TNO-901` | Launcher could not start | Check working-directory access, executable integrity and Windows PowerShell availability. |
| `TNO-902` | Script execution blocked | Use organization-approved script signing or policy settings; central policy is not overridden. |
| `TNO-903` | Worker returned no result | Review the in-app log and process exit code, then retry. |
| `TNO-904` | Result message is invalid | Use a freshly built executable; the in-memory worker result could not be read. |

An unclassified failure uses `TNO-900`. Keep its original message when reporting a problem so the cause can be investigated and assigned a more specific code.

Process exit codes (`0`, `1`, `2`, `3010`) describe the overall run; see [Results in the README](../README.md#-results). Downloading never proves installation, and no error code bypasses activation, licensing or centrally managed policy.
