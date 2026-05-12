# Remove-StaleProfiles

A PowerShell script that scans all Windows user profiles on a machine and removes any that have not been used in the last 90 days (configurable). Cleans up both the profile folder under `C:\Users\` and the associated registry hive, freeing disk space on workstations and servers where old accounts accumulate over time.

## Features

- **Dry run by default** — shows exactly what would be deleted and how much disk space would be freed before anything is touched
- **Per-profile size reporting** — calculates the actual folder size of each stale profile so you know the impact upfront
- **Smart skipping** — automatically skips system accounts, built-in profiles (`Default`, `Public`), any profile that is currently loaded/active, and any profile containing a OneDrive folder
- **Full cleanup** — uses `Win32_UserProfile` via CIM to remove both the profile folder and the registry entry in one operation
- **Logging** — writes a timestamped log file for every run (default: `C:\Logs\Remove-StaleProfiles.log`)
- **Configurable threshold** — defaults to 90 days, adjustable via parameter

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+
- Must be run as **Administrator**

## Usage

### Dry run (safe — nothing is deleted)
```powershell
.\Remove-StaleProfiles.ps1
```

### Live run — actually delete stale profiles
```powershell
.\Remove-StaleProfiles.ps1 -Force
```

### Custom inactivity threshold
```powershell
.\Remove-StaleProfiles.ps1 -DaysInactive 60 -Force
```

### Custom log path
```powershell
.\Remove-StaleProfiles.ps1 -Force -LogPath "D:\AdminLogs\profiles.log"
```

## Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-DaysInactive` | `int` | `90` | Days of inactivity before a profile is considered stale |
| `-Force` | `switch` | off | Actually delete profiles. Omit to run in dry-run mode |
| `-LogPath` | `string` | `C:\Logs\Remove-StaleProfiles.log` | Path to write the log file |

## Example Output

```
[2026-05-12 09:14:01] [INFO] ==================================================
[2026-05-12 09:14:01] [INFO] Remove-StaleProfiles started
[2026-05-12 09:14:01] [INFO] Cutoff date  : 2026-02-11
[2026-05-12 09:14:01] [INFO] Days inactive: 90
[2026-05-12 09:14:01] [INFO] Mode         : DRY RUN (use -Force to delete)
[2026-05-12 09:14:01] [INFO] ==================================================
[2026-05-12 09:14:02] [INFO] KEEP            : DOMAIN\jdoe  [C:\Users\jdoe]  (last used 12 days ago)
[2026-05-12 09:14:02] [WARN] SKIP (active)   : DOMAIN\asmith  [C:\Users\asmith]
[2026-05-12 09:14:04] [CYAN] DRY RUN - would remove: DOMAIN\bjones  [C:\Users\bjones]  (last used 142 days ago)  [4.87 GB]
[2026-05-12 09:14:06] [CYAN] DRY RUN - would remove: DOMAIN\twilson  [C:\Users\twilson]  (last used 201 days ago)  [1.23 GB]
[2026-05-12 09:14:06] [INFO] ==================================================
[2026-05-12 09:14:06] [INFO] Summary
[2026-05-12 09:14:06] [INFO]   Profiles scanned : 6
[2026-05-12 09:14:06] [INFO]   Skipped (active / system / recent) : 4
[2026-05-12 09:14:06] [CYAN]   Would remove     : 2  (6.10 GB would be freed)
[2026-05-12 09:14:06] [CYAN]   DRY RUN complete. Re-run with -Force to actually delete profiles.
```

## How It Works

1. Queries all user profiles via `Get-CimInstance Win32_UserProfile`
2. Skips special/system accounts and any currently loaded profile
3. Checks `LastUseTime` from WMI; falls back to the folder's last-write time if unavailable
4. In dry-run mode, recursively calculates each stale profile's folder size and reports the total space that would be freed
5. In live mode, calls `Remove-CimInstance` on the `Win32_UserProfile` object — this removes both `C:\Users\<name>` and the registry key under `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList`

## OneDrive

Profiles that contain a OneDrive folder (e.g. `OneDrive`, `OneDrive - CompanyName`) are automatically skipped with a warning. This avoids two problems:

- Deleting a profile mid-sync can corrupt the OneDrive sync state
- A user returning after profile deletion would trigger a full re-sync from the cloud

These profiles are logged as `SKIP (OneDrive)` and counted in the skipped total. To handle them, offboard the user's OneDrive first, then re-run the script.

## Notes

- Profiles with no WMI timestamp fall back to the folder's last-modified time and are flagged with a warning in the log
- The size calculation during dry run does a full recursive scan, which may take a moment on large profiles
- Recommended to schedule via Task Scheduler with `-Force` after verifying the dry-run output
