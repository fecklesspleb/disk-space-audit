# disk-space-audit

A small PowerShell file for a full drive on Windows. It shows how much free space each local drive has, which folders under your profile are the biggest, and how big the usual cleanable places are: your TEMP folder, the Windows Update download cache, the Recycle Bin, Downloads and `Windows.old`. It changes nothing unless you ask. There's one optional cleanup, which runs only when you opt in: it deletes old files from your TEMP folder (or from another folder named `Temp` or `Tmp` that you pass with `-TempPath`), and you can preview it with `-WhatIf`.

> **Test status, honestly:** the script parses cleanly, PSScriptAnalyzer reports 0 findings, and the Pester tests in `tests/` pass. All of that was done with **PowerShell 7 on Linux**, using fake drives, a fake Recycle Bin and a throwaway test folder. **It has not yet been run on a real Windows 11 PC, on Windows 10, or on Windows PowerShell 5.1.** Try the cleanup with `-WhatIf` first.

## What it does

Dot-sourcing `disk-space-audit.ps1` loads the functions below. Nothing runs and nothing changes until you call one.

| Function | Changes anything? | What it does |
|---|---|---|
| `Get-FixedDriveSpace` | No | Lists local fixed drives (`Win32_LogicalDisk` with `DriveType = 3`) with size, free GB and percent free. |
| `Get-FolderSize -Path <folder>` | No | Adds up file sizes under one folder. It never follows junctions or symbolic links, so links can't make a folder look bigger than it is. It counts folders it couldn't read instead of stopping. |
| `Get-LargestFolder [-Path <folder>] [-Top 10]` | No | Measures each folder directly under `-Path` (default: your user profile) and lists the biggest first. |
| `Get-CleanupCandidate [-OlderThanDays 7]` | No | One row each for: user TEMP (total), TEMP files older than N days, `%SystemRoot%\SoftwareDistribution\Download`, Recycle Bin, Downloads, and `Windows.old` if it exists. Each row says what to do about it. |
| `Remove-OldTempFile [-OlderThanDays 7]` | **Yes: deletes files** | Deletes files in your user TEMP folder (`$env:TEMP`) that haven't changed in N days. Asks first (`ConfirmImpact = 'High'`), supports `-WhatIf`. Skips hidden and read-only files, files in use, and anything behind a junction or symbolic link. |

What it does **not** delete: Downloads, the Recycle Bin, the Windows Update cache and `Windows.old` are only measured. For those:

- **Recycle Bin:** look inside first, then use PowerShell's built-in `Clear-RecycleBin -WhatIf`, then `Clear-RecycleBin`. Don't add `-Force`: Microsoft's docs say it also overrides `-WhatIf` and `-Confirm`.
- **Downloads:** these are your files. Sort by size in File Explorer and decide yourself.
- **Windows Update cache and `Windows.old`:** use **Settings > System > Storage > Cleanup recommendations** (or Disk Cleanup). Removing `Windows.old` means you can't go back to your previous version of Windows.
- **Storage Sense** (Settings > System > Storage) can clear temporary files and the Recycle Bin automatically.

## How to run it

1. Download `disk-space-audit.ps1` and read it (about 270 lines of plain text).
2. Open PowerShell. A normal (non-admin) window is enough. Some system folders can't be read without admin rights, and the script reports them in the `Unreadable` count rather than failing.
3. If PowerShell refuses to run scripts, allow them for this window only, and unblock the file you have read:

   ```powershell
   Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process
   Unblock-File -Path .\disk-space-audit.ps1
   ```

   `-Scope Process` lasts until you close the window. Your normal execution policy stays the same.
4. Load the functions (note the leading dot and space) and look around:

   ```powershell
   . .\disk-space-audit.ps1
   Get-FixedDriveSpace | Format-Table -AutoSize
   Get-LargestFolder -Top 10 | Format-Table Folder, SizeGB, Files -AutoSize
   Get-CleanupCandidate | Format-Table Location, SizeGB, Advice -Wrap
   ```

5. Optional cleanup, previewing first:

   ```powershell
   Remove-OldTempFile -OlderThanDays 7 -WhatIf
   Remove-OldTempFile -OlderThanDays 7
   ```

Measuring a big profile can take a few minutes. Use `-Path` to look at one folder at a time, for example `Get-LargestFolder -Path "$env:USERPROFILE\AppData\Local"`.

## -WhatIf, -Confirm and safety (as implemented)

- `Remove-OldTempFile` declares `SupportsShouldProcess` with `ConfirmImpact = 'High'`, so it asks before deleting even without `-Confirm`. With `-WhatIf` it prints one line (how many files, how many MB) and deletes nothing. Add `-Confirm:$false` to skip the prompt once you trust it.
- It refuses to run if `$env:TEMP` is empty, missing, or points at a folder that isn't named `Temp` or `Tmp`. That way a broken TEMP variable can't aim it at your profile or the Windows folder.
- It walks the folder itself and never goes into a junction or symbolic link, so it can't reach files outside TEMP.
- It calls `Remove-Item` without `-Force`, so hidden and read-only files are left alone. Files that can't be deleted (usually because a running program has them open) are counted as `Skipped`.
- There's no undo. It only takes files you haven't changed in N days (7 by default) from a folder that's meant for temporary files.
- Sizes are the sum of file lengths. That can differ from "size on disk" in File Explorer, for example for compressed files or OneDrive files that are only stored online.

## Tests

```powershell
Invoke-ScriptAnalyzer -Path . -Recurse -Severity Error,Warning,Information
Invoke-Pester -Path .\tests -Output Detailed
```

The tests mock `Get-CimInstance` and the Recycle Bin reader, and build real files and symbolic links only inside Pester's throwaway `TestDrive:`. They check:

- the drive query asks only for `DriveType = 3` and does the GB and percent maths (including a zero-size drive)
- folder sizes add up across subfolders
- a symbolic link to another folder is not followed, by either the size walk or the TEMP walk
- largest-folder sorting and `-Top` work
- the report rows appear, including `Windows.old` with its warning, and nothing is deleted
- `-WhatIf` deletes nothing
- a real run deletes only files older than the cutoff
- a file that can't be deleted is skipped
- a folder not named Temp, or an empty TEMP path, is refused
- `ConfirmImpact` is High

Last run (Oct 30, 2026, ET): PowerShell 7.4.6 on Linux, PSScriptAnalyzer 1.25.0: 0 findings in the script and in `tests/`; Pester 6.2.0: 15 passed, 0 failed. Not run on Windows yet. If you run it on Windows 10/11, please open an issue saying what happened.

## Sources (Microsoft)

- Free up drive space in Windows (Cleanup recommendations, Storage Sense, Disk Cleanup, Windows.old, Recycle Bin): https://support.microsoft.com/en-us/windows/experience/storage-filemanagement/free-up-drive-space-in-windows
- Manage drive space with Storage Sense: https://support.microsoft.com/en-us/windows/experience/storage-filemanagement/manage-drive-space-with-storage-sense
- Win32_LogicalDisk class (DriveType 3 = Local Disk, FreeSpace and Size in bytes): https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-logicaldisk
- Clear-RecycleBin (`-WhatIf`, `-Confirm`, and the `-Force` warning): https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/clear-recyclebin?view=powershell-5.1
- Remove-Item (read-only and hidden files need `-Force`): https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/remove-item?view=powershell-7.5
- ShellSpecialFolderConstants (Recycle Bin = `ssfBITBUCKET`, 10): https://learn.microsoft.com/en-us/windows/win32/api/shldisp/ne-shldisp-shellspecialfolderconstants
- FolderItem.Size: https://learn.microsoft.com/en-us/windows/win32/shell/folderitem-size
- KNOWNFOLDERID (Downloads = `%USERPROFILE%\Downloads` by default): https://learn.microsoft.com/en-us/windows/win32/shell/knownfolderid
- Get-ChildItem (symbolic links and junctions): https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/get-childitem
- Set-ExecutionPolicy: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.security/set-executionpolicy?view=powershell-5.1
- Everything you wanted to know about ShouldProcess: https://learn.microsoft.com/en-us/powershell/scripting/learn/deep-dives/everything-about-shouldprocess

## License and disclaimers

MIT (see `LICENSE`). Provided as-is, without warranty. Deleting files can't be undone; back up anything you care about first.

This code and README were written with AI assistance.

Not affiliated with or endorsed by Microsoft. Windows and PowerShell are trademarks of the Microsoft group of companies.

If you want the rest of the fixes (slow startup, full drive, stuck updates) in one place, I sell a 40-page guide with the scripts: [Windows 11 Fix-It Guide + PowerShell Toolkit](https://pcfixitkits.gumroad.com/l/vgkvmp), $19.
