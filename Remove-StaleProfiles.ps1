#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Removes Windows user profiles that have not been used in the last 90 days.

.PARAMETER DaysInactive
    Number of days of inactivity before a profile is considered stale. Default: 90.

.PARAMETER WhatIf
    Simulate the operation without deleting anything. Enabled by default.

.PARAMETER Force
    Actually delete profiles. Without this flag, the script runs in dry-run mode.

.PARAMETER LogPath
    Path to write a log file. Default: C:\Logs\Remove-StaleProfiles.log

.EXAMPLE
    .\Remove-StaleProfiles.ps1
    Dry run — shows what would be removed.

.EXAMPLE
    .\Remove-StaleProfiles.ps1 -Force
    Actually removes stale profiles.

.EXAMPLE
    .\Remove-StaleProfiles.ps1 -DaysInactive 60 -Force
    Removes profiles inactive for more than 60 days.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [int]$DaysInactive = 90,
    [switch]$Force,
    [string]$LogPath = "C:\Logs\Remove-StaleProfiles.log"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Logging ──────────────────────────────────────────────────────────────────

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$timestamp] [$Level] $Message"
    Write-Host $line -ForegroundColor $(switch ($Level) {
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        'DRY'   { 'Cyan' }
        'DEL'   { 'Magenta' }
        default { 'White' }
    })
    if (-not (Test-Path (Split-Path $LogPath))) {
        New-Item -ItemType Directory -Path (Split-Path $LogPath) -Force | Out-Null
    }
    Add-Content -Path $LogPath -Value $line
}

# ── Folder size helper ───────────────────────────────────────────────────────

function Get-FolderSize {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return 0 }
    try {
        return (Get-ChildItem -Path $Path -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { -not $_.PSIsContainer } |
            Measure-Object -Property Length -Sum).Sum
    } catch {
        return 0
    }
}

function Format-Bytes {
    param([long]$Bytes)
    switch ($Bytes) {
        { $_ -ge 1GB } { return "{0:N2} GB" -f ($_ / 1GB) }
        { $_ -ge 1MB } { return "{0:N2} MB" -f ($_ / 1MB) }
        { $_ -ge 1KB } { return "{0:N2} KB" -f ($_ / 1KB) }
        default        { return "$_ bytes" }
    }
}

# ── SID-to-username helper ────────────────────────────────────────────────────

function Resolve-SidToName {
    param([string]$Sid)
    try {
        $principal = New-Object System.Security.Principal.SecurityIdentifier($Sid)
        return $principal.Translate([System.Security.Principal.NTAccount]).Value
    } catch {
        return $Sid  # fall back to raw SID if translation fails
    }
}

# ── Main ──────────────────────────────────────────────────────────────────────

$cutoff = (Get-Date).AddDays(-$DaysInactive)
$isDryRun = -not $Force.IsPresent

Write-Log "=================================================="
Write-Log "Remove-StaleProfiles started"
Write-Log "Cutoff date  : $($cutoff.ToString('yyyy-MM-dd'))"
Write-Log "Days inactive: $DaysInactive"
Write-Log "Mode         : $(if ($isDryRun) { 'DRY RUN (use -Force to delete)' } else { 'LIVE — profiles WILL be deleted' })"
Write-Log "=================================================="

# SIDs for well-known built-in accounts to always skip
$skipSids = @(
    'S-1-5-18',   # SYSTEM / LocalSystem
    'S-1-5-19',   # LOCAL SERVICE
    'S-1-5-20'    # NETWORK SERVICE
)

$profiles       = Get-CimInstance -ClassName Win32_UserProfile
$total          = 0
$removed        = 0
$skipped        = 0
$errors         = 0
$totalBytesFreed = [long]0

foreach ($profile in $profiles) {
    $total++
    $sid      = $profile.SID
    $path     = $profile.LocalPath
    $loaded   = $profile.Loaded
    $special  = $profile.Special
    $lastUsed = $profile.LastUseTime  # DateTime or $null

    $username = Resolve-SidToName -Sid $sid

    # ── Skip special / system profiles ──────────────────────────────────────
    if ($special -or ($sid -in $skipSids)) {
        Write-Log "SKIP (system)   : $username  [$path]" 'INFO'
        $skipped++
        continue
    }

    # ── Skip profiles that are currently active ──────────────────────────────
    if ($loaded) {
        Write-Log "SKIP (active)   : $username  [$path]" 'WARN'
        $skipped++
        continue
    }

    # ── Skip Default / Public / systemprofile directories ───────────────────
    $leafName = Split-Path $path -Leaf
    if ($leafName -in @('Default', 'Public', 'systemprofile', 'LocalService', 'NetworkService')) {
        Write-Log "SKIP (built-in) : $username  [$path]" 'INFO'
        $skipped++
        continue
    }

    # ── Determine last use ───────────────────────────────────────────────────
    if ($null -eq $lastUsed) {
        # No WMI timestamp — fall back to profile folder's LastWriteTime
        if (Test-Path $path) {
            $lastUsed = (Get-Item $path).LastWriteTime
            Write-Log "No WMI timestamp for $username; using folder mtime: $($lastUsed.ToString('yyyy-MM-dd'))" 'WARN'
        } else {
            Write-Log "SKIP (no path)  : $username  [$path] — folder missing, skipping" 'WARN'
            $skipped++
            continue
        }
    }

    # ── Check age ────────────────────────────────────────────────────────────
    if ($lastUsed -ge $cutoff) {
        $age = [math]::Round(((Get-Date) - $lastUsed).TotalDays)
        Write-Log "KEEP            : $username  [$path]  (last used $age days ago)" 'INFO'
        $skipped++
        continue
    }

    $age = [math]::Round(((Get-Date) - $lastUsed).TotalDays)

    # ── Remove or simulate ───────────────────────────────────────────────────
    if ($isDryRun) {
        Write-Log "Calculating size: $path ..." 'DRY'
        $sizeBytes = Get-FolderSize -Path $path
        $totalBytesFreed += $sizeBytes
        Write-Log "DRY RUN - would remove: $username  [$path]  (last used $age days ago)  [$(Format-Bytes $sizeBytes)]" 'DRY'
        $removed++
    } else {
        try {
            $sizeBytes = Get-FolderSize -Path $path
            Write-Log "REMOVING        : $username  [$path]  (last used $age days ago)  [$(Format-Bytes $sizeBytes)]" 'DEL'
            # Remove-CimInstance on Win32_UserProfile removes both the folder and
            # the registry hive under HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList
            Remove-CimInstance -InputObject $profile
            $totalBytesFreed += $sizeBytes
            Write-Log "REMOVED OK      : $username  [$path]" 'DEL'
            $removed++
        } catch {
            Write-Log "ERROR removing $username [$path]: $_" 'ERROR'
            $errors++
        }
    }
}

Write-Log "=================================================="
Write-Log "Summary"
Write-Log "  Profiles scanned : $total"
Write-Log "  Skipped (active / system / recent) : $skipped"
if ($isDryRun) {
    Write-Log "  Would remove     : $removed  ($(Format-Bytes $totalBytesFreed) would be freed)" 'DRY'
    Write-Log "  DRY RUN complete. Re-run with -Force to actually delete profiles." 'DRY'
} else {
    Write-Log "  Removed          : $removed  ($(Format-Bytes $totalBytesFreed) freed)"
    Write-Log "  Errors           : $errors"
}
Write-Log "Log written to: $LogPath"
Write-Log "=================================================="
