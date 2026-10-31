# FileOps.ps1
# The only place where the tool changes the file system. Every change is logged and keeps the
# database up to date (base section 10 "Datenbank bei jeder Änderung aktuell halten").
# There is no function that deletes a file. The only removals are:
#   - empty folders (Remove-EmptyFolderTracked, base section 2),
#   - shortcuts the tool created itself, on undo (Remove-ShortcutTracked, 2.2 section 7).

function Move-FileTracked {
    # Moves one file. Returns the relative path where the file ended up.
    # -AllowSuffix: on a name conflict the arriving file gets "_2", "_3", ... (base section 2).
    # Without it a conflict throws an error and nothing is changed.
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)]$Log,
        [switch]$AllowSuffix,
        [string]$StepType = 'MOVED',
        [string]$Extra = ''
    )
    $absSource = ConvertTo-AbsPath $Source
    if (-not [System.IO.File]::Exists($absSource)) { throw "Source file not found: $Source" }
    $finalTarget = $Target
    $caseOnly = Test-RelEqual $Source $Target
    if (-not $caseOnly -and (Test-RelExists $finalTarget)) {
        if (-not $AllowSuffix) { throw "Target already exists: $Target" }
        $finalTarget = Get-UniqueRelPath -RelPath $Target
    }
    $absTarget = ConvertTo-AbsPath $finalTarget
    $parent = [System.IO.Path]::GetDirectoryName($absTarget)
    if (-not [System.IO.Directory]::Exists($parent)) {
        New-FolderTracked -Path (Get-RelParent $finalTarget) -Log $Log
    }
    if ($caseOnly) {
        $temp = $absSource + '.sortingtool-rename'
        [System.IO.File]::Move($absSource, $temp)
        [System.IO.File]::Move($temp, $absTarget)
    }
    else {
        [System.IO.File]::Move($absSource, $absTarget)
    }
    $entry = Get-FileEntry $Source
    if ($null -ne $entry) {
        Update-EntryPath -OldPath $Source -NewPath $finalTarget
    }
    else {
        # A file without entry gets one when it is moved (base section 10).
        try { Set-FileEntry (New-FileEntryData -RelPath $finalTarget) } catch { }
    }
    Add-LogStep -Log $Log -Type $StepType -Old $Source -New $finalTarget -Extra $Extra
    return $finalTarget
}

function Move-FolderTracked {
    # Moves or renames a whole folder with its content. Returns the final relative path.
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)]$Log,
        [switch]$AllowSuffix,
        [string]$StepType = 'MOVED',
        [string]$Extra = ''
    )
    $absSource = ConvertTo-AbsPath $Source
    if (-not [System.IO.Directory]::Exists($absSource)) { throw "Source folder not found: $Source" }
    if (Test-RelUnder $Target $Source) { throw "A folder cannot be moved into itself: $Source" }
    $finalTarget = $Target
    $caseOnly = Test-RelEqual $Source $Target
    if (-not $caseOnly -and (Test-RelExists $finalTarget)) {
        if (-not $AllowSuffix) { throw "Target already exists: $Target" }
        $finalTarget = Get-UniqueRelPath -RelPath $Target -IsFolder
    }
    $absTarget = ConvertTo-AbsPath $finalTarget
    $parent = [System.IO.Path]::GetDirectoryName($absTarget)
    if (-not [System.IO.Directory]::Exists($parent)) {
        New-FolderTracked -Path (Get-RelParent $finalTarget) -Log $Log
    }
    if ($caseOnly) {
        $temp = $absSource.TrimEnd('\') + '.sortingtool-rename'
        [System.IO.Directory]::Move($absSource, $temp)
        [System.IO.Directory]::Move($temp, $absTarget)
    }
    else {
        [System.IO.Directory]::Move($absSource, $absTarget)
    }
    Update-EntryFolderPath -OldFolder $Source -NewFolder $finalTarget
    Add-LogStep -Log $Log -Type $StepType -Old $Source -New $finalTarget -Extra $Extra
    return $finalTarget
}

function New-FolderTracked {
    # Creates a folder and every missing parent; each created level is logged as FOLDER_CREATED,
    # so undo can remove it again if it becomes empty (base section 9).
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Log)
    $levels = @(Get-RelAncestors $Path) + @($Path)
    foreach ($level in $levels) {
        if ((Get-RelDepth $level) -lt 2) { continue }   # never create the main folders this way
        $abs = ConvertTo-AbsPath $level
        if (-not [System.IO.Directory]::Exists($abs)) {
            [void][System.IO.Directory]::CreateDirectory($abs)
            Add-LogStep -Log $Log -Type 'FOLDER_CREATED' -Old '' -New $level
        }
    }
}

function Test-FolderEmpty {
    param([Parameter(Mandatory)][string]$Path)
    $abs = ConvertTo-AbsPath $Path
    if (-not [System.IO.Directory]::Exists($abs)) { return $false }
    $e = [System.IO.Directory]::EnumerateFileSystemEntries($abs).GetEnumerator()
    try { return (-not $e.MoveNext()) } finally { $e.Dispose() }
}

function Remove-EmptyFolderTracked {
    # Removes a folder only if it is empty. Returns $true if it was removed.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Log)
    if ((Get-RelDepth $Path) -lt 2) { return $false }   # main folders are never removed
    if (-not (Test-FolderEmpty $Path)) { return $false }
    # Directory.Delete without "recursive" only succeeds for an empty folder.
    [System.IO.Directory]::Delete((ConvertTo-AbsPath $Path), $false)
    Add-LogStep -Log $Log -Type 'EMPTY_FOLDER_REMOVED' -Old $Path -New ''
    return $true
}

function Remove-EmptyInputFolders {
    # Removes folders in Input that became empty (base section 2). $Candidates: relative folder paths.
    # Checks every candidate and its parents, deepest first, never Input itself.
    # $Exclude: optional set of folders that must stay (unchecked in the preview).
    param([Parameter(Mandatory)]$Candidates, [Parameter(Mandatory)]$Log, $Exclude = $null)
    $all = New-PathSet
    foreach ($c in $Candidates) {
        if ([string]::IsNullOrEmpty($c)) { continue }
        if (-not (Test-RelUnder $c 'Input')) { continue }
        [void]$all.Add($c)
        foreach ($a in (Get-RelAncestors $c)) { if (Test-RelUnder $a 'Input') { [void]$all.Add($a) } }
    }
    $removed = New-Object System.Collections.Generic.List[string]
    foreach ($folder in ($all | Sort-Object { (Get-RelDepth $_) } -Descending)) {
        if ($null -ne $Exclude -and $Exclude.Contains($folder)) { continue }
        try {
            if (Remove-EmptyFolderTracked -Path $folder -Log $Log) { $removed.Add($folder) }
        }
        catch {
            Add-LogStep -Log $Log -Type 'ERROR' -Old $folder -New '' -Extra $_.Exception.Message
        }
    }
    return , $removed
}

function New-ShortcutTracked {
    # Creates a Windows shortcut (.lnk) pointing to a file or folder (2.2 section 4).
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$TargetRel, [Parameter(Mandatory)]$Log)
    if (-not $global:ST.WScript) { $global:ST.WScript = New-Object -ComObject WScript.Shell }
    $abs = ConvertTo-AbsPath $Path
    if ([System.IO.File]::Exists($abs)) { throw "Shortcut already exists: $Path" }
    $parent = [System.IO.Path]::GetDirectoryName($abs)
    if (-not [System.IO.Directory]::Exists($parent)) { New-FolderTracked -Path (Get-RelParent $Path) -Log $Log }
    $link = $global:ST.WScript.CreateShortcut($abs)
    $link.TargetPath = (ConvertTo-AbsPath $TargetRel)
    $link.Save()
    Add-LogStep -Log $Log -Type 'LINK_CREATED' -Old '' -New $Path -Extra $TargetRel
}

function Remove-ShortcutTracked {
    # Removes a shortcut the tool created itself (only on undo, 2.2 section 7). Only .lnk files.
    param([Parameter(Mandatory)][string]$Path, [string]$TargetRel = '', [Parameter(Mandatory)]$Log)
    if ([System.IO.Path]::GetExtension($Path).ToLowerInvariant() -ne '.lnk') { throw "Only shortcuts can be removed: $Path" }
    $abs = ConvertTo-AbsPath $Path
    if (-not [System.IO.File]::Exists($abs)) { throw "Shortcut not found: $Path" }
    [System.IO.File]::Delete($abs)
    Add-LogStep -Log $Log -Type 'LINK_REMOVED' -Old $Path -New '' -Extra $TargetRel
}
