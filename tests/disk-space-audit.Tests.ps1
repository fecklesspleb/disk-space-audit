# Pester 5+ tests for disk-space-audit.ps1.
# Drives and the Recycle Bin are faked with mocks; folders are built inside
# Pester's throwaway TestDrive:. The tests run on any OS and never touch a real
# drive, TEMP folder or Recycle Bin. They do NOT prove how a real Windows PC behaves.

BeforeAll {
    . (Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'disk-space-audit.ps1')

    # Get-CimInstance only exists on Windows. Define a stand-in elsewhere so
    # Pester has something to mock.
    if (-not (Get-Command -Name Get-CimInstance -ErrorAction SilentlyContinue)) {
        function global:Get-CimInstance { param($ClassName, $Filter) $null = $ClassName, $Filter }
    }

    function Add-TestFile {
        param([string] $Path, [int] $Bytes, [int] $AgeDays = 0)
        $dir = Split-Path -Path $Path -Parent
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [System.IO.File]::WriteAllBytes($Path, (New-Object byte[] $Bytes))
        (Get-Item -LiteralPath $Path).LastWriteTime = (Get-Date).AddDays(-$AgeDays)
    }
}

Describe 'Get-FixedDriveSpace' {
    It 'asks only for local fixed disks and converts bytes to GB and percent' {
        Mock Get-CimInstance {
            [pscustomobject]@{ DeviceID = 'C:'; Size = [double](100GB); FreeSpace = [double](25GB) }
        }
        $r = Get-FixedDriveSpace
        Should -Invoke Get-CimInstance -Times 1 -Exactly -ParameterFilter {
            $ClassName -eq 'Win32_LogicalDisk' -and $Filter -eq 'DriveType = 3'
        }
        $r.Drive | Should -Be 'C:'
        $r.SizeGB | Should -Be 100
        $r.FreeGB | Should -Be 25
        $r.PercentFree | Should -Be 25
    }

    It 'does not divide by zero for a drive that reports size 0' {
        Mock Get-CimInstance { [pscustomobject]@{ DeviceID = 'D:'; Size = 0; FreeSpace = 0 } }
        (Get-FixedDriveSpace).PercentFree | Should -BeNullOrEmpty
    }
}

Describe 'Get-FolderSize' {
    It 'adds up file sizes in nested folders' {
        $root = Join-Path $TestDrive 'size1'
        Add-TestFile -Path (Join-Path $root 'a.bin') -Bytes 1000
        Add-TestFile -Path (Join-Path $root 'sub/b.bin') -Bytes 500
        $r = Get-FolderSize -Path $root
        $r.Bytes | Should -Be 1500
        $r.Files | Should -Be 2
    }

    It 'does not follow a symbolic link to another folder' {
        $root = Join-Path $TestDrive 'size2'
        $outside = Join-Path $TestDrive 'outside'
        Add-TestFile -Path (Join-Path $root 'a.bin') -Bytes 100
        Add-TestFile -Path (Join-Path $outside 'big.bin') -Bytes 9000
        New-Item -ItemType SymbolicLink -Path (Join-Path $root 'link') -Target $outside | Out-Null
        $r = Get-FolderSize -Path $root
        $r.Bytes | Should -Be 100
        $r.SkippedLinks | Should -Be 1
    }

    It 'returns zero for a folder that does not exist' {
        (Get-FolderSize -Path (Join-Path $TestDrive 'nope')).Bytes | Should -Be 0
    }
}

Describe 'Get-LargestFolder' {
    It 'sorts folders by size, biggest first, and honours -Top' {
        $root = Join-Path $TestDrive 'largest'
        Add-TestFile -Path (Join-Path $root 'small/x.bin') -Bytes 10
        Add-TestFile -Path (Join-Path $root 'big/x.bin') -Bytes 5000
        Add-TestFile -Path (Join-Path $root 'mid/x.bin') -Bytes 700
        $r = @(Get-LargestFolder -Path $root -Top 2)
        $r.Count | Should -Be 2
        (Split-Path $r[0].Folder -Leaf) | Should -Be 'big'
        (Split-Path $r[1].Folder -Leaf) | Should -Be 'mid'
    }
}

Describe 'Get-CleanupCandidate' {
    BeforeEach {
        $script:base = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $script:temp = Join-Path $base 'Temp'
        $script:win = Join-Path $base 'Windows'
        $script:dl = Join-Path $base 'Downloads'
        Add-TestFile -Path (Join-Path $temp 'new.tmp') -Bytes 100 -AgeDays 1
        Add-TestFile -Path (Join-Path $temp 'old.tmp') -Bytes 300 -AgeDays 30
        Add-TestFile -Path (Join-Path $win 'SoftwareDistribution/Download/u.cab') -Bytes 50
        Add-TestFile -Path (Join-Path $dl 'setup.exe') -Bytes 20
        Mock Get-RecycleBinByteCount { [long]2GB }
    }

    It 'reports every location and changes nothing' {
        $r = @(Get-CleanupCandidate -TempPath $temp -WindowsPath $win -DownloadsPath $dl -SystemDrive $base -OlderThanDays 7)
        $r.Count | Should -Be 5   # no Windows.old in this fake system drive
        ($r | Where-Object Location -eq 'Recycle Bin').SizeGB | Should -Be 2
        Test-Path (Join-Path $temp 'old.tmp') | Should -BeTrue
        Test-Path (Join-Path $dl 'setup.exe') | Should -BeTrue
    }

    It 'adds a Windows.old row with a cannot-undo warning when that folder exists' {
        Add-TestFile -Path (Join-Path $base 'Windows.old/f.bin') -Bytes 10
        $r = @(Get-CleanupCandidate -TempPath $temp -WindowsPath $win -DownloadsPath $dl -SystemDrive $base)
        $r.Count | Should -Be 6
        ($r | Where-Object Location -like 'Previous Windows*').Advice | Should -BeLike '*cannot go back*'
    }
}

Describe 'Get-OldTempFile' {
    It 'lists only files older than the cutoff and skips linked folders' {
        $temp = Join-Path $TestDrive 'old1/Temp'
        $outside = Join-Path $TestDrive 'old1/outside'
        Add-TestFile -Path (Join-Path $temp 'new.tmp') -Bytes 1 -AgeDays 1
        Add-TestFile -Path (Join-Path $temp 'sub/old.tmp') -Bytes 1 -AgeDays 30
        Add-TestFile -Path (Join-Path $outside 'precious.doc') -Bytes 1 -AgeDays 400
        New-Item -ItemType SymbolicLink -Path (Join-Path $temp 'link') -Target $outside | Out-Null
        $r = @(Get-OldTempFile -TempPath $temp -OlderThanDays 7)
        $r.Name | Should -Be @('old.tmp')
    }
}

Describe 'Remove-OldTempFile' {
    BeforeEach {
        $script:temp = Join-Path $TestDrive (Join-Path ([guid]::NewGuid().ToString()) 'Temp')
        Add-TestFile -Path (Join-Path $temp 'new.tmp') -Bytes 100 -AgeDays 1
        Add-TestFile -Path (Join-Path $temp 'old.tmp') -Bytes 300 -AgeDays 30
    }

    It '-WhatIf deletes nothing' {
        $r = Remove-OldTempFile -TempPath $temp -OlderThanDays 7 -WhatIf
        Test-Path (Join-Path $temp 'old.tmp') | Should -BeTrue
        $r.Found | Should -Be 1
        $r.Deleted | Should -Be 0
    }

    It 'real run deletes only the old file' {
        $r = Remove-OldTempFile -TempPath $temp -OlderThanDays 7 -Confirm:$false
        Test-Path (Join-Path $temp 'old.tmp') | Should -BeFalse
        Test-Path (Join-Path $temp 'new.tmp') | Should -BeTrue
        $r.Deleted | Should -Be 1
    }

    It 'counts a file that cannot be deleted as skipped and keeps going' {
        Mock Remove-Item { throw 'The process cannot access the file because it is being used by another process.' }
        $r = Remove-OldTempFile -TempPath $temp -OlderThanDays 7 -Confirm:$false
        $r.Deleted | Should -Be 0
        $r.Skipped | Should -Be 1
    }

    It 'refuses to clean a folder that is not named Temp or Tmp' {
        $home2 = Join-Path $TestDrive 'Users/someone'
        Add-TestFile -Path (Join-Path $home2 'old.doc') -Bytes 1 -AgeDays 30
        { Remove-OldTempFile -TempPath $home2 -Confirm:$false } | Should -Throw '*not named Temp or Tmp*'
        Test-Path (Join-Path $home2 'old.doc') | Should -BeTrue
    }

    It 'refuses when the TEMP path is empty' {
        { Remove-OldTempFile -TempPath '' -Confirm:$false } | Should -Throw '*empty*'
    }

    It 'asks for confirmation by default (ConfirmImpact is High)' {
        $cmd = Get-Command Remove-OldTempFile
        $attr = $cmd.ScriptBlock.Attributes | Where-Object { $_ -is [System.Management.Automation.CmdletBindingAttribute] }
        $attr.SupportsShouldProcess | Should -BeTrue
        $attr.ConfirmImpact | Should -Be 'High'
    }
}
