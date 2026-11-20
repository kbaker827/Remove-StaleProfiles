<#
.SYNOPSIS
    Removes Windows user profiles that have not been used in the last N days (default 90).

.DESCRIPTION
    Scans every profile in Win32_UserProfile and removes the stale ones (folder + ProfileList
    registry entry) via Remove-CimInstance. Runs as a dry run unless -Force is given.

    Last-use is taken from the ProfileList registry load/unload timestamps (Windows 10 1903+),
    because Win32_UserProfile.LastUseTime is bumped for every profile by feature updates,
    Defender and other services and so makes stale profiles look recently used. It falls back
    to LastUseTime, then the folder's last-write time. The source used is logged per profile.

    Only real user accounts are considered (local/domain S-1-5-21-* and Entra ID S-1-12-1-*).
    Service, virtual and IIS AppPool profiles are never touched.

.PARAMETER DaysInactive
    Days of inactivity before a profile is considered stale. 1-3650. Default: 90.

.PARAMETER Force
    Actually delete profiles. Without this switch the script is a dry run.
    -WhatIf overrides -Force; -Confirm prompts before each deletion.

.PARAMETER ExcludeUser
    Wildcard patterns for accounts to always keep. Matched against DOMAIN\user, the bare
    user name and the profile folder name. Example: -ExcludeUser 'admin*','svc_*'

.PARAMETER IncludeOneDrive
    Also remove stale profiles that contain a OneDrive folder (skipped by default).

.PARAMETER SkipSizeCalculation
    Do not measure profile folder sizes (faster on machines with large profiles).

.PARAMETER LogPath
    Log file path. Default: %SystemDrive%\Logs\Remove-StaleProfiles.log

.PARAMETER MaxLogSizeMB
    When the log exceeds this size it is rolled to <LogPath>.old. Default: 10.

.PARAMETER ReportPath
    Optional CSV report with one row per profile (and per orphaned folder).

.EXAMPLE
    .\Remove-StaleProfiles.ps1
    Dry run: shows what would be removed.

.EXAMPLE
    .\Remove-StaleProfiles.ps1 -Force -ExcludeUser 'Administrator','it_*'
    Removes stale profiles, never touching Administrator or any it_* account.

.EXAMPLE
    .\Remove-StaleProfiles.ps1 -DaysInactive 60 -Force -ReportPath C:\Logs\profiles.csv

.NOTES
    Exit codes: 0 = success, 1 = one or more removals failed, 2 = not elevated / fatal error.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateRange(1, 3650)]
    [int]$DaysInactive = 90,

    [switch]$Force,

    [string[]]$ExcludeUser = @(),

    [switch]$IncludeOneDrive,

    [switch]$SkipSizeCalculation,

    [ValidateNotNullOrEmpty()]
    [string]$LogPath = "$env:SystemDrive\Logs\Remove-StaleProfiles.log",

    [ValidateRange(1, 1024)]
    [int]$MaxLogSizeMB = 10,

    [string]$ReportPath
)

# -- Constants ----------------------------------------------------------------

$script:ProfileListKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
# Local/domain accounts (S-1-5-21) and Entra ID / Azure AD accounts (S-1-12-1).
$script:UserSidPattern = '^S-1-5-21-|^S-1-12-1-'
$script:BuiltInFolders = @('Default', 'Default User', 'Public', 'All Users', 'defaultuser0',
                           'systemprofile', 'LocalService', 'NetworkService')
# FILE_ATTRIBUTE_OFFLINE (0x1000) | FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS (0x400000): cloud-only files.
$script:CloudFileAttrs = 0x1000 -bor 0x400000
$script:ReparseAttr    = 0x400
$script:LogFile        = $null

# -- Logging ------------------------------------------------------------------

function Write-Log {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'DRY', 'DEL')][string]$Level = 'INFO'
    )
    $line  = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    $color = switch ($Level) {
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        'DRY'   { 'Cyan' }
        'DEL'   { 'Magenta' }
        default { 'White' }
    }
    Write-Host $line -ForegroundColor $color
    if (-not $script:LogFile) { return }
    try {
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch {
        Write-Warning "Cannot write to log '$($script:LogFile)': $($_.Exception.Message). Console only from here."
        $script:LogFile = $null
    }
}

function Initialize-LogFile {
    param([Parameter(Mandatory)][string]$Path, [int]$MaxSizeMB = 10)
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $dir  = Split-Path -Path $full -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
    }
    $existing = Get-Item -LiteralPath $full -ErrorAction SilentlyContinue
    if ($existing -and $existing.Length -gt ($MaxSizeMB * 1MB)) {
        Move-Item -LiteralPath $full -Destination "$full.old" -Force -ErrorAction Stop
    }
    return $full
}

# -- Helpers ------------------------------------------------------------------

function Test-IsAdministrator {
    $identity  = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Format-Bytes {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N2} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N2} KB' -f ($Bytes / 1KB) }
    return "$Bytes bytes"
}

function Get-FolderSize {
    <# Sums on-disk file sizes. Does not follow junctions/symlinks (e.g. "Application Data")
       and does not count cloud-only placeholder files, so the result is what deletion frees. #>
    param([string]$Path)
    if (-not $Path -or -not [System.IO.Directory]::Exists($Path)) { return [long]0 }
    $total = [long]0
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $dir = New-Object System.IO.DirectoryInfo($stack.Pop())
        try { $entries = $dir.GetFileSystemInfos() } catch { continue }   # access denied / path too long
        foreach ($entry in $entries) {
            $attrs = [int]$entry.Attributes
            if ($entry -is [System.IO.DirectoryInfo]) {
                if (-not ($attrs -band $script:ReparseAttr)) { $stack.Push($entry.FullName) }
            } elseif (-not ($attrs -band $script:CloudFileAttrs)) {
                $total += $entry.Length
            }
        }
    }
    return $total
}

function Resolve-SidToName {
    param([string]$Sid)
    try {
        $principal = New-Object System.Security.Principal.SecurityIdentifier($Sid)
        return $principal.Translate([System.Security.Principal.NTAccount]).Value
    } catch {
        return $Sid   # deleted / unreachable account: fall back to the raw SID
    }
}

function ConvertFrom-RegistryFileTime {
    <# Combines a High/Low DWORD pair (read back as signed Int32) into a DateTime. #>
    param($High, $Low)
    if ($null -eq $High -or $null -eq $Low) { return $null }
    $mask  = [long]4294967295
    $value = (([long]$High -band $mask) * 4294967296) + ([long]$Low -band $mask)
    if ($value -le 0) { return $null }
    try { return [DateTime]::FromFileTime($value) } catch { return $null }
}

function Get-RegistryProfileTime {
    <# Most recent of LocalProfileLoadTime / LocalProfileUnloadTime, or $null. #>
    param([Parameter(Mandatory)][string]$Sid)
    $props = Get-ItemProperty -LiteralPath (Join-Path $script:ProfileListKey $Sid) -ErrorAction SilentlyContinue
    if (-not $props) { return $null }
    $times = foreach ($kind in 'Load', 'Unload') {
        $hi = $props.PSObject.Properties["LocalProfile${kind}TimeHigh"]
        $lo = $props.PSObject.Properties["LocalProfile${kind}TimeLow"]
        if ($hi -and $lo) { ConvertFrom-RegistryFileTime -High $hi.Value -Low $lo.Value }
    }
    $valid = @($times | Where-Object { $_ })
    if ($valid.Count -eq 0) { return $null }
    return ($valid | Sort-Object -Descending | Select-Object -First 1)
}

function Select-ProfileLastUsed {
    <# Picks the most trustworthy last-use timestamp available. #>
    param($RegistryTime, $WmiTime, $FolderTime)
    if ($RegistryTime) { return [pscustomobject]@{ LastUsed = [datetime]$RegistryTime; Source = 'Registry' } }
    if ($WmiTime)      { return [pscustomobject]@{ LastUsed = [datetime]$WmiTime;      Source = 'WMI' } }
    if ($FolderTime)   { return [pscustomobject]@{ LastUsed = [datetime]$FolderTime;   Source = 'Folder' } }
    return [pscustomobject]@{ LastUsed = $null; Source = 'None' }
}

function Test-ProfileExcluded {
    param([string]$UserName, [string]$Path, [string[]]$Patterns)
    if (-not $Patterns) { return $false }
    $leaf = if ($Path) { Split-Path -Path $Path -Leaf } else { '' }
    $candidates = @($UserName, ($UserName -split '\\')[-1], $leaf)
    foreach ($pattern in $Patterns) {
        foreach ($candidate in $candidates) {
            if ($candidate -and $candidate -like $pattern) { return $true }
        }
    }
    return $false
}

function Test-HasOneDrive {
    param([string]$Path)
    if (-not $Path -or -not [System.IO.Directory]::Exists($Path)) { return $false }
    $match = Get-ChildItem -LiteralPath $Path -Directory -Force -Filter 'OneDrive*' -ErrorAction SilentlyContinue |
        Select-Object -First 1
    return [bool]$match
}

# -- Decision logic (pure, unit-tested) ---------------------------------------

function New-Decision {
    param([string]$Action, [string]$Reason)
    return [pscustomobject]@{ Action = $Action; Reason = $Reason }
}

function Get-ProfileDecision {
    param(
        [Parameter(Mandatory)]$UserProfile,          # needs SID, LocalPath, Loaded, Special
        [string]$UserName,
        $LastUsed,
        [Parameter(Mandatory)][datetime]$Cutoff,
        [string[]]$ExcludeUser = @(),
        [bool]$HasOneDrive,
        [bool]$IncludeOneDrive
    )
    $path    = [string]$UserProfile.LocalPath
    $windows = [Environment]::GetFolderPath('Windows')

    if ($UserProfile.Special)                              { return New-Decision 'Skip' 'system' }
    if ($UserProfile.SID -notmatch $script:UserSidPattern) { return New-Decision 'Skip' 'service account' }
    if (-not $path -or ($windows -and $path.StartsWith($windows, [StringComparison]::OrdinalIgnoreCase))) {
        return New-Decision 'Skip' 'system'
    }
    if ((Split-Path -Path $path -Leaf) -in $script:BuiltInFolders) { return New-Decision 'Skip' 'built-in' }
    if (Test-ProfileExcluded -UserName $UserName -Path $path -Patterns $ExcludeUser) {
        return New-Decision 'Skip' 'excluded'
    }
    if ($UserProfile.Loaded)                     { return New-Decision 'Skip' 'loaded' }
    if ($null -eq $LastUsed)                     { return New-Decision 'Skip' 'no timestamp' }
    if ([datetime]$LastUsed -ge $Cutoff)         { return New-Decision 'Keep' 'recent' }
    if ($HasOneDrive -and -not $IncludeOneDrive) { return New-Decision 'Skip' 'OneDrive' }
    return New-Decision 'Remove' 'stale'
}

# -- Actions ------------------------------------------------------------------

function Remove-UserProfile {
    <# Returns 'Removed', 'Partial' (unregistered but folder left behind) or 'Failed'. #>
    param([Parameter(Mandatory)]$UserProfile, [string]$Label)
    $path = $UserProfile.LocalPath
    try {
        # Removes the folder AND HKLM\...\ProfileList\<SID> in one operation.
        Remove-CimInstance -InputObject $UserProfile -ErrorAction Stop
    } catch {
        Write-Log "ERROR removing $Label : $($_.Exception.Message)" 'ERROR'
        return 'Failed'
    }
    if ($path -and [System.IO.Directory]::Exists($path)) {
        Write-Log "PARTIAL         : $Label - profile unregistered but folder remains (files in use?)" 'WARN'
        return 'Partial'
    }
    Write-Log "REMOVED OK      : $Label" 'DEL'
    return 'Removed'
}

function Find-OrphanedProfileFolders {
    <# Folders in the profiles directory with no ProfileList entry. Reported only, never deleted. #>
    param([string[]]$KnownPaths)
    $root = (Get-ItemProperty -LiteralPath $script:ProfileListKey -ErrorAction SilentlyContinue).ProfilesDirectory
    if (-not $root) { return @() }
    $root  = [Environment]::ExpandEnvironmentVariables($root)
    $known = @($KnownPaths | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\').ToLowerInvariant() })
    return @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue | Where-Object {
        -not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -and
        $_.Name -notin $script:BuiltInFolders -and
        $_.FullName.ToLowerInvariant() -notin $known
    })
}

function New-ReportRow {
    param($UserName, $Sid, $Path, $LastUsedInfo, $AgeDays, $Action, $Reason, $SizeBytes, $Result)
    $lastUsed = $null
    $source   = ''
    if ($LastUsedInfo) {
        $source = $LastUsedInfo.Source
        if ($LastUsedInfo.LastUsed) { $lastUsed = $LastUsedInfo.LastUsed.ToString('yyyy-MM-dd HH:mm') }
    }
    return [pscustomobject]@{
        ComputerName    = $env:COMPUTERNAME
        UserName        = $UserName
        SID             = $Sid
        Path            = $Path
        LastUsed        = $lastUsed
        TimestampSource = $source
        AgeDays         = $AgeDays
        Action          = $Action
        Reason          = $Reason
        SizeBytes       = $SizeBytes
        Result          = $Result
    }
}

# -- Per-profile processing ---------------------------------------------------

function Get-ProfileLastUsedInfo {
    param($UserProfile)
    $path = $UserProfile.LocalPath
    $folderTime = $null
    if ($path) {
        $folder = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        if ($folder) { $folderTime = $folder.LastWriteTime }
    }
    return Select-ProfileLastUsed -RegistryTime (Get-RegistryProfileTime -Sid $UserProfile.SID) `
                                  -WmiTime $UserProfile.LastUseTime -FolderTime $folderTime
}

function Invoke-ProfileItem {
    param($UserProfile, [datetime]$Now, [datetime]$Cutoff, [bool]$IsLive, $Cmdlet)
    $path     = $UserProfile.LocalPath
    $userName = Resolve-SidToName -Sid $UserProfile.SID
    $info     = Get-ProfileLastUsedInfo -UserProfile $UserProfile
    $age      = $null
    if ($info.LastUsed) { $age = [int][math]::Max(0, [math]::Floor(($Now - $info.LastUsed).TotalDays)) }

    $decision = Get-ProfileDecision -UserProfile $UserProfile -UserName $userName -LastUsed $info.LastUsed `
        -Cutoff $Cutoff -ExcludeUser $ExcludeUser -HasOneDrive (Test-HasOneDrive -Path $path) `
        -IncludeOneDrive $IncludeOneDrive.IsPresent
    $label = "$userName  [$path]"
    $row   = @{ UserName = $userName; Sid = $UserProfile.SID; Path = $path; LastUsedInfo = $info; AgeDays = $age
                Action = $decision.Action; Reason = $decision.Reason; SizeBytes = $null; Result = '' }
    $ageText = if ($null -ne $age) { "  (last used $age days ago, source: $($info.Source))" } else { '' }

    if ($decision.Action -ne 'Remove') {
        $level = if ($decision.Reason -in 'loaded', 'OneDrive', 'no timestamp') { 'WARN' } else { 'INFO' }
        Write-Log ('{0,-22}: {1}{2}' -f "$($decision.Action.ToUpper()) ($($decision.Reason))", $label, $ageText) $level
        return New-ReportRow @row
    }

    if (-not $SkipSizeCalculation) { $row.SizeBytes = Get-FolderSize -Path $path }
    $sizeText = if ($null -ne $row.SizeBytes) { "  [$(Format-Bytes $row.SizeBytes)]" } else { '' }

    if ($IsLive -and $Cmdlet.ShouldProcess($label, 'Remove user profile')) {
        Write-Log ('{0,-22}: {1}{2}{3}' -f 'REMOVING', $label, $ageText, $sizeText) 'DEL'
        $row.Result = Remove-UserProfile -UserProfile $UserProfile -Label $label
    } else {
        Write-Log ('{0,-22}: {1}{2}{3}' -f 'WOULD REMOVE', $label, $ageText, $sizeText) 'DRY'
        $row.Result = 'DryRun'
    }
    return New-ReportRow @row
}

# -- Main ---------------------------------------------------------------------

function Get-RowCount {
    param([object[]]$Rows, [scriptblock]$Filter)
    return @($Rows | Where-Object $Filter).Count
}

function Get-RowBytes {
    param([object[]]$Rows, [scriptblock]$Filter)
    $sum = [long]0
    foreach ($r in @($Rows | Where-Object $Filter)) { if ($r.SizeBytes) { $sum += [long]$r.SizeBytes } }
    return $sum
}

function Write-Summary {
    param([object[]]$Rows, [bool]$IsLive)
    Write-Log '=================================================='
    Write-Log 'Summary'
    Write-Log "  Profiles scanned : $(Get-RowCount $Rows { $_.Action -ne 'Orphan' })"
    Write-Log "  Kept (recent)    : $(Get-RowCount $Rows { $_.Action -eq 'Keep' })"
    Write-Log "  Skipped          : $(Get-RowCount $Rows { $_.Action -eq 'Skip' })"
    if ($IsLive) {
        $done = { $_.Result -in 'Removed', 'Partial' }
        Write-Log "  Removed          : $(Get-RowCount $Rows $done)  ($(Format-Bytes (Get-RowBytes $Rows $done)) freed)" 'DEL'
        Write-Log "  Partial          : $(Get-RowCount $Rows { $_.Result -eq 'Partial' })"
        Write-Log "  Errors           : $(Get-RowCount $Rows { $_.Result -eq 'Failed' })"
    } else {
        $would = { $_.Result -eq 'DryRun' }
        Write-Log "  Would remove     : $(Get-RowCount $Rows $would)  ($(Format-Bytes (Get-RowBytes $Rows $would)) would be freed)" 'DRY'
        Write-Log '  DRY RUN complete. Re-run with -Force to actually delete profiles.' 'DRY'
    }
    $orphans = Get-RowCount $Rows { $_.Action -eq 'Orphan' }
    if ($orphans) { Write-Log "  Orphan folders   : $orphans (not deleted; review manually)" 'WARN' }
}

function Write-Header {
    param([datetime]$Cutoff, [bool]$IsLive)
    Write-Log '=================================================='
    Write-Log "Remove-StaleProfiles started on $env:COMPUTERNAME as $([Environment]::UserName)"
    Write-Log "Cutoff date  : $($Cutoff.ToString('yyyy-MM-dd'))  ($DaysInactive days)"
    Write-Log "Mode         : $(if ($IsLive) { 'LIVE - profiles WILL be deleted' } else { 'DRY RUN (use -Force to delete)' })"
    if ($ExcludeUser)     { Write-Log "Excluding    : $($ExcludeUser -join ', ')" }
    if ($IncludeOneDrive) { Write-Log 'OneDrive     : profiles with OneDrive folders are eligible for removal' 'WARN' }
    Write-Log '=================================================='
}

function Invoke-StaleProfileCleanup {
    param($Cmdlet)
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if (-not (Test-IsAdministrator)) {
        Write-Error 'Remove-StaleProfiles must be run as Administrator (or SYSTEM).' -ErrorAction Continue
        return 2
    }
    try { $script:LogFile = Initialize-LogFile -Path $LogPath -MaxSizeMB $MaxLogSizeMB }
    catch { Write-Warning "Log file unavailable ($($_.Exception.Message)); logging to console only." }

    $now    = Get-Date
    $cutoff = $now.AddDays(-$DaysInactive)
    $isLive = $Force.IsPresent -and -not $WhatIfPreference
    Write-Header -Cutoff $cutoff -IsLive $isLive

    try { $profiles = @(Get-CimInstance -ClassName Win32_UserProfile -ErrorAction Stop) }
    catch { Write-Log "Cannot query Win32_UserProfile: $($_.Exception.Message)" 'ERROR'; return 2 }

    $rows = @(foreach ($p in $profiles) {
        try { Invoke-ProfileItem -UserProfile $p -Now $now -Cutoff $cutoff -IsLive $isLive -Cmdlet $Cmdlet }
        catch {
            Write-Log "ERROR processing $($p.SID) [$($p.LocalPath)]: $($_.Exception.Message)" 'ERROR'
            New-ReportRow -UserName $p.SID -Sid $p.SID -Path $p.LocalPath -Action 'Error' -Reason $_.Exception.Message -Result 'Failed'
        }
    })
    $knownPaths = @($profiles | ForEach-Object { $_.LocalPath })
    foreach ($orphan in (Find-OrphanedProfileFolders -KnownPaths $knownPaths)) {
        Write-Log "ORPHAN (report only)  : [$($orphan.FullName)] - no ProfileList entry; not deleted" 'WARN'
        $rows += New-ReportRow -UserName $orphan.Name -Path $orphan.FullName -Action 'Orphan' -Reason 'no registry entry' -Result 'Reported'
    }

    Write-Summary -Rows $rows -IsLive $isLive
    if ($ReportPath) {
        try {
            $rows | Export-Csv -LiteralPath $ReportPath -NoTypeInformation -Encoding UTF8
            Write-Log "Report written to: $ReportPath"
        } catch { Write-Log "Could not write report '$ReportPath': $($_.Exception.Message)" 'ERROR' }
    }
    if ($script:LogFile) { Write-Log "Log written to: $($script:LogFile)" }
    Write-Log '=================================================='

    if ((Get-RowCount $rows { $_.Result -eq 'Failed' }) -gt 0) { return 1 }
    return 0
}

# Dot-sourcing (e.g. from Pester) loads the functions without running anything.
if ($MyInvocation.InvocationName -eq '.') { return }

exit (Invoke-StaleProfileCleanup -Cmdlet $PSCmdlet)
