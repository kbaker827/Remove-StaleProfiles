#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot '..\Remove-StaleProfiles.ps1')

    $script:Now    = Get-Date '2026-06-01'
    $script:Cutoff = $script:Now.AddDays(-90)
    $script:UserSid = 'S-1-5-21-1111111111-2222222222-3333333333-1105'

    function New-FakeProfile {
        param(
            [string]$Sid = $script:UserSid,
            [string]$Path = 'C:\Users\jdoe',
            [bool]$Loaded = $false,
            [bool]$Special = $false
        )
        [pscustomobject]@{ SID = $Sid; LocalPath = $Path; Loaded = $Loaded; Special = $Special }
    }

    function Get-TestDecision {
        param($UserProfile = (New-FakeProfile), $LastUsed = $script:Now.AddDays(-200),
              [string[]]$ExcludeUser = @(), [bool]$HasOneDrive = $false, [bool]$IncludeOneDrive = $false)
        Get-ProfileDecision -UserProfile $UserProfile -UserName 'CONTOSO\jdoe' -LastUsed $LastUsed `
            -Cutoff $script:Cutoff -ExcludeUser $ExcludeUser -HasOneDrive $HasOneDrive -IncludeOneDrive $IncludeOneDrive
    }
}

Describe 'Get-ProfileDecision' {
    It 'removes a stale, unloaded user profile' {
        $d = Get-TestDecision
        $d.Action | Should -Be 'Remove'
        $d.Reason | Should -Be 'stale'
    }

    It 'keeps a profile used after the cutoff' {
        (Get-TestDecision -LastUsed $script:Now.AddDays(-10)).Action | Should -Be 'Keep'
    }

    It 'keeps a profile used exactly at the cutoff' {
        (Get-TestDecision -LastUsed $script:Cutoff).Action | Should -Be 'Keep'
    }

    It 'skips special profiles' {
        (Get-TestDecision -UserProfile (New-FakeProfile -Special $true)).Reason | Should -Be 'system'
    }

    It 'skips loaded profiles even when stale' {
        (Get-TestDecision -UserProfile (New-FakeProfile -Loaded $true)).Reason | Should -Be 'loaded'
    }

    It 'skips non-user SIDs: <Sid>' -ForEach @(
        @{ Sid = 'S-1-5-18' }
        @{ Sid = 'S-1-5-82-3006700770-424185619-1745488364-794895919-4004696415' }   # IIS AppPool
        @{ Sid = 'S-1-5-80-3880718306-3832830129-1677859214-2598158968-1052248003' }  # NT SERVICE\*
    ) {
        $d = Get-TestDecision -UserProfile (New-FakeProfile -Sid $Sid -Path 'C:\Users\DefaultAppPool')
        $d.Action | Should -Be 'Skip'
        $d.Reason | Should -Be 'service account'
    }

    It 'allows Entra ID (S-1-12-1) accounts' {
        $p = New-FakeProfile -Sid 'S-1-12-1-111111111-2222222222-333333333-444444444'
        (Get-TestDecision -UserProfile $p).Action | Should -Be 'Remove'
    }

    It 'skips profiles under the Windows directory' {
        $p = New-FakeProfile -Path (Join-Path ([Environment]::GetFolderPath('Windows')) 'ServiceProfiles\Foo')
        (Get-TestDecision -UserProfile $p).Reason | Should -Be 'system'
    }

    It 'skips profiles with an empty path' {
        (Get-TestDecision -UserProfile (New-FakeProfile -Path '')).Reason | Should -Be 'system'
    }

    It 'skips built-in folder <Name>' -ForEach @(@{ Name = 'Default' }, @{ Name = 'Public' }, @{ Name = 'defaultuser0' }) {
        (Get-TestDecision -UserProfile (New-FakeProfile -Path "C:\Users\$Name")).Reason | Should -Be 'built-in'
    }

    It 'skips excluded users' {
        (Get-TestDecision -ExcludeUser 'j*').Reason | Should -Be 'excluded'
    }

    It 'skips when no timestamp is available' {
        (Get-TestDecision -LastUsed $null).Reason | Should -Be 'no timestamp'
    }

    It 'skips stale OneDrive profiles by default' {
        (Get-TestDecision -HasOneDrive $true).Reason | Should -Be 'OneDrive'
    }

    It 'removes stale OneDrive profiles with -IncludeOneDrive' {
        (Get-TestDecision -HasOneDrive $true -IncludeOneDrive $true).Action | Should -Be 'Remove'
    }

    It 'reports a recent OneDrive profile as Keep, not OneDrive' {
        (Get-TestDecision -HasOneDrive $true -LastUsed $script:Now.AddDays(-5)).Action | Should -Be 'Keep'
    }
}

Describe 'Test-ProfileExcluded' {
    It 'matches <Pattern> => <Expected>' -ForEach @(
        @{ Pattern = 'CONTOSO\jdoe'; Expected = $true }
        @{ Pattern = 'jdoe';         Expected = $true }
        @{ Pattern = '*doe';         Expected = $true }
        @{ Pattern = 'jdoe.CONTOSO'; Expected = $true }   # folder name variant
        @{ Pattern = 'admin*';       Expected = $false }
    ) {
        Test-ProfileExcluded -UserName 'CONTOSO\jdoe' -Path 'C:\Users\jdoe.CONTOSO' -Patterns @($Pattern) |
            Should -Be $Expected
    }

    It 'returns false with no patterns' {
        Test-ProfileExcluded -UserName 'CONTOSO\jdoe' -Path 'C:\Users\jdoe' -Patterns @() | Should -BeFalse
    }
}

Describe 'ConvertFrom-RegistryFileTime' {
    It 'combines high/low DWORDs including a negative (signed) low part' {
        $expected = Get-Date '2025-03-14 09:26:53'
        $ft   = $expected.ToFileTime()
        $high = [int]($ft -shr 32)
        $low  = [BitConverter]::ToInt32([BitConverter]::GetBytes($ft), 0)   # may be negative
        ConvertFrom-RegistryFileTime -High $high -Low $low | Should -Be $expected
    }

    It 'returns $null for zero or missing values' {
        ConvertFrom-RegistryFileTime -High 0 -Low 0 | Should -BeNullOrEmpty
        ConvertFrom-RegistryFileTime -High $null -Low 5 | Should -BeNullOrEmpty
    }
}

Describe 'Select-ProfileLastUsed' {
    It 'prefers the registry timestamp over WMI' {
        $r = Select-ProfileLastUsed -RegistryTime $script:Now.AddDays(-200) -WmiTime $script:Now -FolderTime $script:Now
        $r.Source   | Should -Be 'Registry'
        $r.LastUsed | Should -Be $script:Now.AddDays(-200)
    }

    It 'falls back to WMI, then folder' {
        (Select-ProfileLastUsed -WmiTime $script:Now -FolderTime $script:Now).Source | Should -Be 'WMI'
        (Select-ProfileLastUsed -FolderTime $script:Now).Source | Should -Be 'Folder'
    }

    It 'returns Source None when nothing is available' {
        $r = Select-ProfileLastUsed
        $r.Source   | Should -Be 'None'
        $r.LastUsed | Should -BeNullOrEmpty
    }
}

Describe 'Get-FolderSize' {
    BeforeAll {
        $script:Root = Join-Path $TestDrive 'profile'
        New-Item -ItemType Directory -Path (Join-Path $script:Root 'sub') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Root 'a.bin') -Value ('x' * 1000) -NoNewline
        Set-Content -LiteralPath (Join-Path $script:Root 'sub\b.bin') -Value ('y' * 500) -NoNewline
    }

    It 'sums files recursively' {
        Get-FolderSize -Path $script:Root | Should -Be 1500
    }

    It 'does not follow junctions' {
        $target = Join-Path $TestDrive 'elsewhere'
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $target 'big.bin') -Value ('z' * 5000) -NoNewline
        New-Item -ItemType Junction -Path (Join-Path $script:Root 'link') -Target $target | Out-Null
        Get-FolderSize -Path $script:Root | Should -Be 1500
    }

    It 'returns 0 for a missing path' {
        Get-FolderSize -Path (Join-Path $TestDrive 'nope') | Should -Be 0
    }
}

Describe 'Test-HasOneDrive' {
    It 'detects OneDrive - Company folders' {
        $p = Join-Path $TestDrive 'od'
        New-Item -ItemType Directory -Path (Join-Path $p 'OneDrive - Contoso') -Force | Out-Null
        Test-HasOneDrive -Path $p | Should -BeTrue
    }

    It 'ignores a file named OneDrive*' {
        $p = Join-Path $TestDrive 'nood'
        New-Item -ItemType Directory -Path $p -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $p 'OneDrive.txt') -Value 'x'
        Test-HasOneDrive -Path $p | Should -BeFalse
    }
}

Describe 'Format-Bytes' {
    It 'formats <Bytes> as <Text>' -ForEach @(
        @{ Bytes = 512;       Text = '512 bytes' }
        @{ Bytes = 2048;      Text = ('{0:N2} KB' -f 2) }
        @{ Bytes = 5MB;       Text = ('{0:N2} MB' -f 5) }
        @{ Bytes = 3GB;       Text = ('{0:N2} GB' -f 3) }
    ) {
        Format-Bytes -Bytes $Bytes | Should -Be $Text
    }
}

Describe 'Invoke-ProfileItem' {
    BeforeEach {
        Mock Write-Log {}
        Mock Resolve-SidToName { 'CONTOSO\jdoe' }
        Mock Test-HasOneDrive { $false }
        Mock Get-FolderSize { 1MB }
        Mock Remove-UserProfile { 'Removed' }
        Mock Get-ProfileLastUsedInfo { [pscustomobject]@{ LastUsed = $script:Now.AddDays(-200); Source = 'Registry' } }
        $script:Cmdlet = [pscustomobject]@{} | Add-Member -MemberType ScriptMethod -Name ShouldProcess -Value { $true } -PassThru
    }

    It 'does not delete in dry-run mode' {
        $row = Invoke-ProfileItem -UserProfile (New-FakeProfile) -Now $script:Now -Cutoff $script:Cutoff -IsLive $false -Cmdlet $script:Cmdlet
        $row.Result | Should -Be 'DryRun'
        $row.SizeBytes | Should -Be 1MB
        Should -Invoke Remove-UserProfile -Times 0
    }

    It 'deletes in live mode' {
        $row = Invoke-ProfileItem -UserProfile (New-FakeProfile) -Now $script:Now -Cutoff $script:Cutoff -IsLive $true -Cmdlet $script:Cmdlet
        $row.Result | Should -Be 'Removed'
        $row.AgeDays | Should -Be 200
        Should -Invoke Remove-UserProfile -Times 1
    }

    It 'does not delete when ShouldProcess declines (-WhatIf / -Confirm No)' {
        $no = [pscustomobject]@{} | Add-Member -MemberType ScriptMethod -Name ShouldProcess -Value { $false } -PassThru
        $row = Invoke-ProfileItem -UserProfile (New-FakeProfile) -Now $script:Now -Cutoff $script:Cutoff -IsLive $true -Cmdlet $no
        $row.Result | Should -Be 'DryRun'
        Should -Invoke Remove-UserProfile -Times 0
    }

    It 'never deletes a loaded profile in live mode' {
        $row = Invoke-ProfileItem -UserProfile (New-FakeProfile -Loaded $true) -Now $script:Now -Cutoff $script:Cutoff -IsLive $true -Cmdlet $script:Cmdlet
        $row.Action | Should -Be 'Skip'
        Should -Invoke Remove-UserProfile -Times 0
        Should -Invoke Get-FolderSize -Times 0
    }
}

Describe 'Remove-UserProfile' {
    BeforeEach { Mock Write-Log {} }

    It 'returns Failed when Remove-CimInstance throws' {
        Mock Remove-CimInstance { throw 'in use' } -RemoveParameterType InputObject
        Remove-UserProfile -UserProfile (New-FakeProfile -Path 'C:\nonexistent\x') -Label 'x' | Should -Be 'Failed'
    }

    It 'returns Partial when the folder survives' {
        Mock Remove-CimInstance {} -RemoveParameterType InputObject
        Remove-UserProfile -UserProfile (New-FakeProfile -Path $TestDrive) -Label 'x' | Should -Be 'Partial'
    }

    It 'returns Removed when the folder is gone' {
        Mock Remove-CimInstance {} -RemoveParameterType InputObject
        Remove-UserProfile -UserProfile (New-FakeProfile -Path (Join-Path $TestDrive 'gone')) -Label 'x' | Should -Be 'Removed'
    }
}
