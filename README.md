# Remove-StaleProfiles

A PowerShell script that scans all Windows user profiles on a machine and removes any that have not been used in the last 90 days (configurable). It removes both the profile folder under `C:\Users\` and the matching registry entry, freeing disk space on shared workstations and servers where old accounts pile up.

## Features

- **Dry run by default**: shows exactly what would be deleted, and how much space it would free, before anything is touched
- **Accurate last-use detection**: reads the logon/logoff timestamps Windows keeps in the `ProfileList` registry key, instead of `Win32_UserProfile.LastUseTime`, which Windows updates and antivirus scans reset for every profile (see [How last use is determined](#how-last-use-is-determined))
- **Only touches real user accounts**: local/domain (`S-1-5-21-*`) and Entra ID (`S-1-12-1-*`) profiles. Service, virtual-service (`NT SERVICE\*`) and IIS AppPool profiles are never removed
- **Exclusion list**: `-ExcludeUser 'Administrator','it_*'` keeps named or wildcard-matched accounts
- **Smart skipping**: system profiles, built-in folders (`Default`, `Public`, `defaultuser0`, ...), loaded profiles and OneDrive profiles (optional) are skipped
- **Per-profile size reporting**: does not follow junctions and does not count OneDrive cloud-only files, so the number is the space actually freed
- **Supports `-WhatIf` / `-Confirm`** on top of `-Force`
- **Verifies each removal**: flags profiles that were unregistered but whose folder could not be fully deleted (files in use)
- **Orphan report**: lists folders in `C:\Users` that have no registry entry (report only, never deleted)
- **CSV report** (`-ReportPath`) with one row per profile, handy for collecting results across a fleet
- **Log file with rotation**, and **exit codes** for PDQ, Intune, SCCM, Task Scheduler and similar tools

## Requirements

- Windows 10 1903+ / Windows Server 2019+ for registry timestamps (older builds fall back automatically)
- Windows PowerShell 5.1 or PowerShell 7+
- Must run as **Administrator** or **SYSTEM**

## Usage

```powershell
# Dry run (safe, nothing is deleted)
.\Remove-StaleProfiles.ps1

# Delete stale profiles
.\Remove-StaleProfiles.ps1 -Force

# Never touch these accounts
.\Remove-StaleProfiles.ps1 -Force -ExcludeUser 'Administrator', 'it_*', 'CONTOSO\kiosk'

# 60-day threshold, CSV report, skip the (slow) size calculation
.\Remove-StaleProfiles.ps1 -DaysInactive 60 -Force -ReportPath C:\Logs\profiles.csv -SkipSizeCalculation

# Prompt before each deletion
.\Remove-StaleProfiles.ps1 -Force -Confirm

# Also remove stale profiles that contain a OneDrive folder
.\Remove-StaleProfiles.ps1 -Force -IncludeOneDrive
```

## Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-DaysInactive` | `int` (1-3650) | `90` | Days of inactivity before a profile is considered stale |
| `-Force` | `switch` | off | Actually delete profiles. Without it the script is a dry run |
| `-ExcludeUser` | `string[]` | none | Wildcard patterns matched against `DOMAIN\user`, the bare user name and the folder name |
| `-IncludeOneDrive` | `switch` | off | Also remove stale profiles that contain a `OneDrive*` folder |
| `-SkipSizeCalculation` | `switch` | off | Skip measuring folder sizes |
| `-LogPath` | `string` | `%SystemDrive%\Logs\Remove-StaleProfiles.log` | Log file |
| `-MaxLogSizeMB` | `int` | `10` | Roll the log to `<LogPath>.old` past this size |
| `-ReportPath` | `string` | none | Write a CSV report |
| `-WhatIf` / `-Confirm` | | | Standard PowerShell switches. `-WhatIf` overrides `-Force` |

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Success (including dry runs) |
| `1` | One or more profiles failed to process or remove |
| `2` | Not elevated, or profiles could not be queried |

## Example output

```
[2026-05-12 09:14:01] [INFO] ==================================================
[2026-05-12 09:14:01] [INFO] Remove-StaleProfiles started on WS-0142 as SYSTEM
[2026-05-12 09:14:01] [INFO] Cutoff date  : 2026-02-11  (90 days)
[2026-05-12 09:14:01] [INFO] Mode         : DRY RUN (use -Force to delete)
[2026-05-12 09:14:01] [INFO] ==================================================
[2026-05-12 09:14:02] [INFO] KEEP (recent)         : CONTOSO\jdoe  [C:\Users\jdoe]  (last used 12 days ago, source: Registry)
[2026-05-12 09:14:02] [WARN] SKIP (loaded)         : CONTOSO\asmith  [C:\Users\asmith]  (last used 0 days ago, source: Registry)
[2026-05-12 09:14:02] [INFO] SKIP (service account): IIS APPPOOL\DefaultAppPool  [C:\Users\DefaultAppPool]  (last used 3 days ago, source: WMI)
[2026-05-12 09:14:04] [DRY] WOULD REMOVE          : CONTOSO\bjones  [C:\Users\bjones]  (last used 142 days ago, source: Registry)  [4.87 GB]
[2026-05-12 09:14:06] [DRY] WOULD REMOVE          : CONTOSO\twilson  [C:\Users\twilson]  (last used 201 days ago, source: Registry)  [1.23 GB]
[2026-05-12 09:14:06] [WARN] ORPHAN (report only)  : [C:\Users\olduser] - no ProfileList entry; not deleted
[2026-05-12 09:14:06] [INFO] ==================================================
[2026-05-12 09:14:06] [INFO] Summary
[2026-05-12 09:14:06] [INFO]   Profiles scanned : 8
[2026-05-12 09:14:06] [INFO]   Kept (recent)    : 1
[2026-05-12 09:14:06] [INFO]   Skipped          : 5
[2026-05-12 09:14:06] [DRY]   Would remove     : 2  (6.10 GB would be freed)
[2026-05-12 09:14:06] [DRY]   DRY RUN complete. Re-run with -Force to actually delete profiles.
[2026-05-12 09:14:06] [WARN]   Orphan folders   : 1 (not deleted; review manually)
```

## How it works

1. Queries all profiles with `Get-CimInstance Win32_UserProfile`
2. Skips, in order: special/system profiles, non-user SIDs, anything under `C:\Windows`, built-in folders, excluded users, and loaded profiles
3. Works out when each profile was last used (see below). Profiles used after the cutoff are kept
4. Skips stale profiles that contain a OneDrive folder, unless `-IncludeOneDrive` is set
5. In dry-run mode, reports each stale profile and its size. In live mode, calls `Remove-CimInstance`, which removes the folder **and** `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\<SID>`, then checks that the folder is gone
6. Reports orphaned folders, writes the summary, the optional CSV and the exit code

### How last use is determined

`Win32_UserProfile.LastUseTime` is not reliable: Windows feature updates, Defender and other services load every profile's hive and reset it, so a profile nobody has logged into for a year can look like it was used last week. The script uses, in order:

1. **Registry**: the newer of `LocalProfileLoadTimeHigh/Low` and `LocalProfileUnloadTimeHigh/Low` under `ProfileList\<SID>` (Windows 10 1903+). These only change on a real logon or logoff
2. **WMI**: `Win32_UserProfile.LastUseTime`
3. **Folder**: the profile folder's last-write time

The source used is shown in the log (`source: Registry`) and in the CSV (`TimestampSource`).

## OneDrive

Profiles that contain a OneDrive folder (`OneDrive`, `OneDrive - CompanyName`) are skipped by default:

- Deleting a profile mid-sync can corrupt the OneDrive sync state
- A user who comes back after their profile is deleted triggers a full re-sync from the cloud

If OneDrive is backed up to the cloud and you accept the re-sync, use `-IncludeOneDrive`.

## Deploying (Task Scheduler / PDQ / Intune)

Run a dry run on a few machines first and check the log or CSV. Then schedule it as **SYSTEM**, for example:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Remove-StaleProfiles.ps1" -Force -ExcludeUser 'Administrator' -ReportPath "C:\Logs\Remove-StaleProfiles.csv"
```

Treat exit code `1` as a warning (some profiles could not be removed, usually because files were in use) and `2` as a failure.

As an alternative for domain-joined machines, Windows has a built-in Group Policy for this: *Computer Configuration > Administrative Templates > System > User Profiles > Delete user profiles older than a specified number of days on system restart*. This script adds a dry run, exclusions, OneDrive protection and reporting on top of that.

## Tests

Unit tests use [Pester 5](https://pester.dev):

```powershell
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser   # if needed
Invoke-Pester ./tests -Output Detailed
```

The tests load the script's functions without running it, and never touch real profiles. They also run in GitHub Actions on every push.
