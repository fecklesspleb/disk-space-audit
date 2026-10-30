<#
.SYNOPSIS
    Read-only disk-space audit for Windows: free space per drive, the largest
    folders under a path, and the size of common cleanable locations. One
    optional cleanup (old files in your user TEMP folder) that supports
    -WhatIf and -Confirm.

.DESCRIPTION
    Dot-source this file to load five functions:

      Get-FixedDriveSpace    Size and free space of each local fixed drive.
      Get-FolderSize         Total bytes and file count under one folder.
                             Does not follow junctions or symbolic links.
      Get-LargestFolder      The biggest folders directly under a path.
      Get-CleanupCandidate   Sizes of: user TEMP (all, and files older than N
                             days), Windows Update download cache, Recycle Bin,
                             Downloads, Windows.old. Read-only; each row says
                             what Microsoft suggests doing about it.
      Remove-OldTempFile     Deletes files older than N days from your user
                             TEMP folder only. Supports -WhatIf and -Confirm,
                             and asks before deleting by default. Hidden and
                             read-only files are left alone. No undo.

    Nothing except Remove-OldTempFile changes anything. Downloads, the
    Recycle Bin, the Windows Update cache and Windows.old are only measured.

    Test status: parsed and checked with PSScriptAnalyzer and Pester tests
    that use fake drives and a throwaway test folder, under PowerShell 7 on
    Linux. NOT yet run on a real Windows 11 PC or on Windows PowerShell 5.1.
    Try every change with -WhatIf first.

    Written with AI assistance. MIT License (see LICENSE).
    Not affiliated with or endorsed by Microsoft.

.EXAMPLE
    . .\disk-space-audit.ps1
    Get-FixedDriveSpace | Format-Table -AutoSize

.EXAMPLE
    Get-LargestFolder -Path $env:USERPROFILE -Top 10 | Format-Table -AutoSize

.EXAMPLE
    Get-CleanupCandidate | Format-Table Location, SizeGB, Advice -Wrap

.EXAMPLE
    Remove-OldTempFile -OlderThanDays 7 -WhatIf
#>

# --- Part 1: read-only audit -------------------------------------------

function Get-FixedDriveSpace {
    [CmdletBinding()]
    param()
    # DriveType 3 = "Local Disk" in the Win32_LogicalDisk class.
    Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType = 3' -ErrorAction Stop |
        ForEach-Object {
            $pct = if ($_.Size -gt 0) { [math]::Round(100 * $_.FreeSpace / $_.Size, 1) } else { $null }
            [pscustomobject]@{
                Drive       = $_.DeviceID
                SizeGB      = [math]::Round($_.Size / 1GB, 1)
                FreeGB      = [math]::Round($_.FreeSpace / 1GB, 1)
                PercentFree = $pct
            }
        }
}

function Get-FolderSize {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    $result = [pscustomobject]@{
        Path         = $Path
        Bytes        = [long]0
        Files        = 0
        SkippedLinks = 0
        Unreadable   = 0
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $result }

    # Walk the tree ourselves so junctions and symbolic links are never followed
    # (otherwise a link can make a folder look far bigger than it is, or loop).
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        $errs = $null
        $items = Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue -ErrorVariable errs
        $result.Unreadable += @($errs).Count
        foreach ($item in $items) {
            $isLink = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
            if ($item.PSIsContainer) {
                if ($isLink) { $result.SkippedLinks++ } else { $stack.Push($item.FullName) }
            }
            elseif ($isLink) {
                $result.SkippedLinks++
            }
            else {
                $result.Bytes += $item.Length
                $result.Files++
            }
        }
    }
    $result
}

function Get-LargestFolder {
    [CmdletBinding()]
    param(
        [string] $Path = $env:USERPROFILE,
        [ValidateRange(1, 1000)] [int] $Top = 10
    )
    Get-ChildItem -LiteralPath $Path -Directory -Force -ErrorAction Stop |
        Where-Object { ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0 } |
        ForEach-Object {
            $s = Get-FolderSize -Path $_.FullName
            [pscustomobject]@{
                Folder     = $_.FullName
                SizeGB     = [math]::Round($s.Bytes / 1GB, 2)
                Files      = $s.Files
                Unreadable = $s.Unreadable
                Bytes      = $s.Bytes
            }
        } |
        Sort-Object -Property Bytes -Descending |
        Select-Object -First $Top
}

# Wrapped in its own function so tests can replace it. Uses the Shell
# "Recycle Bin" virtual folder (ShellSpecialFolderConstants ssfBITBUCKET = 10).
function Get-RecycleBinByteCount {
    [CmdletBinding()]
    [OutputType([long])]
    param()
    try {
        $shell = New-Object -ComObject Shell.Application
        $bin = $shell.NameSpace(10)
        $total = [long]0
        foreach ($i in $bin.Items()) { $total += [long]$i.Size }
        $total
    }
    catch {
        Write-Warning "Could not read the Recycle Bin size: $($_.Exception.Message)"
        $null
    }
}

function Get-CleanupCandidate {
    [CmdletBinding()]
    param(
        [ValidateRange(0, 3650)] [int] $OlderThanDays = 7,
        [string] $DownloadsPath = (Join-Path -Path $env:USERPROFILE -ChildPath 'Downloads'),
        [string] $TempPath = $env:TEMP,
        [string] $WindowsPath = $env:SystemRoot,
        [string] $SystemDrive = $env:SystemDrive
    )

    $toGB = { param($b) if ($null -eq $b) { $null } else { [math]::Round($b / 1GB, 2) } }

    $temp = Get-FolderSize -Path $TempPath
    $old = Get-OldTempFile -TempPath $TempPath -OlderThanDays $OlderThanDays
    $oldBytes = [long](($old | Measure-Object -Property Length -Sum).Sum)
    $wuDownload = Get-FolderSize -Path (Join-Path -Path $WindowsPath -ChildPath 'SoftwareDistribution\Download')
    $downloads = Get-FolderSize -Path $DownloadsPath
    $winOldPath = Join-Path -Path "$SystemDrive\" -ChildPath 'Windows.old'
    $winOld = Get-FolderSize -Path $winOldPath

    [pscustomobject]@{
        Location = "User TEMP ($TempPath)"
        SizeGB   = & $toGB $temp.Bytes
        Advice   = 'Settings > System > Storage > Cleanup recommendations (Temporary files), or Remove-OldTempFile.'
    }
    [pscustomobject]@{
        Location = "User TEMP files older than $OlderThanDays days"
        SizeGB   = & $toGB $oldBytes
        Advice   = "Remove-OldTempFile -OlderThanDays $OlderThanDays -WhatIf  (then without -WhatIf)"
    }
    [pscustomobject]@{
        Location = 'Windows Update download cache (SoftwareDistribution\Download)'
        SizeGB   = & $toGB $wuDownload.Bytes
        Advice   = 'Report only. Cleanup recommendations or Disk Cleanup handle system files; this script never touches it.'
    }
    [pscustomobject]@{
        Location = 'Recycle Bin'
        SizeGB   = & $toGB (Get-RecycleBinByteCount)
        Advice   = 'Check it first, then: Clear-RecycleBin -WhatIf  (then without -WhatIf)'
    }
    [pscustomobject]@{
        Location = "Downloads ($DownloadsPath)"
        SizeGB   = & $toGB $downloads.Bytes
        Advice   = 'Your own files. Sort by size in File Explorer and move or delete what you do not need.'
    }
    if (Test-Path -LiteralPath $winOldPath -PathType Container) {
        [pscustomobject]@{
            Location = "Previous Windows install ($winOldPath)"
            SizeGB   = & $toGB $winOld.Bytes
            Advice   = 'Removing it means you cannot go back to the previous version. Use Settings > System > Storage > Cleanup recommendations.'
        }
    }
}

# --- Part 2: optional cleanup of old user TEMP files -------------------

function Assert-SafeTempPath {
    [CmdletBinding()]
    param([string] $TempPath)
    if ([string]::IsNullOrWhiteSpace($TempPath)) { throw 'TEMP path is empty. Refusing to clean.' }
    if (-not (Test-Path -LiteralPath $TempPath -PathType Container)) { throw "TEMP folder not found: $TempPath" }
    $leaf = Split-Path -Path $TempPath.TrimEnd('\', '/') -Leaf
    if ($leaf -notin @('Temp', 'Tmp')) {
        throw "Refusing to clean '$TempPath': the folder is not named Temp or Tmp."
    }
}

function Get-OldTempFile {
    [CmdletBinding()]
    param(
        [string] $TempPath = $env:TEMP,
        [ValidateRange(0, 3650)] [int] $OlderThanDays = 7
    )
    if ([string]::IsNullOrWhiteSpace($TempPath) -or -not (Test-Path -LiteralPath $TempPath -PathType Container)) { return }
    $cutoff = (Get-Date).AddDays(-$OlderThanDays)
    # Same manual walk as Get-FolderSize: never descend into a junction or
    # symbolic link, so nothing outside the TEMP folder can be listed.
    # Hidden and system files are left alone (no -Force).
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($TempPath)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        foreach ($item in (Get-ChildItem -LiteralPath $dir -ErrorAction SilentlyContinue)) {
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            if ($item.PSIsContainer) { $stack.Push($item.FullName) }
            elseif ($item.LastWriteTime -lt $cutoff) { $item }
        }
    }
}

function Remove-OldTempFile {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [ValidateRange(1, 3650)] [int] $OlderThanDays = 7,
        [string] $TempPath = $env:TEMP
    )

    Assert-SafeTempPath -TempPath $TempPath
    $files = @(Get-OldTempFile -TempPath $TempPath -OlderThanDays $OlderThanDays)
    $bytes = [long](($files | Measure-Object -Property Length -Sum).Sum)
    $mb = [math]::Round($bytes / 1MB, 1)

    $deleted = 0; $freed = [long]0; $failed = 0
    $target = "$($files.Count) file(s) ($mb MB) in $TempPath not changed in $OlderThanDays days"
    if ($files.Count -gt 0 -and $PSCmdlet.ShouldProcess($target, 'Delete (no undo)')) {
        foreach ($f in $files) {
            try {
                Remove-Item -LiteralPath $f.FullName -ErrorAction Stop -Confirm:$false
                $deleted++
                $freed += $f.Length
            }
            catch {
                # Files in use by a running program, or read-only files, are skipped.
                $failed++
                Write-Verbose "Skipped $($f.FullName): $($_.Exception.Message)"
            }
        }
    }
    [pscustomobject]@{
        TempPath = $TempPath
        Found    = $files.Count
        Deleted  = $deleted
        Skipped  = $failed
        FreedMB  = [math]::Round($freed / 1MB, 1)
    }
}
