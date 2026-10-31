# FindDuplicates.ps1 (2.2)
# Checks every file in Input that was not checked yet (DuplicateChecked empty) for an exact
# duplicate (same SHA-256) in Result or elsewhere in Input. Duplicates move to ToDelete/Doublets,
# with two shortcuts next to each: "<name> - Result File.lnk" and "<name> - Result Folder.lnk"
# (or "Input File" / "Input Folder"). Nothing is ever moved out of Result.

param($Context, [hashtable]$Arguments = @{})

$selected = Invoke-DbQuery "SELECT * FROM Files WHERE lower(substr(Path, 1, 6)) = 'input/' AND (DuplicateChecked IS NULL OR DuplicateChecked = '')"
if ($selected.Count -eq 0) {
    return (New-FunctionResult -Kind Message -Message 'Doubletten finden: Es gibt keine neuen Dateien in Input, die noch geprüft werden müssen.')
}
$selectedSet = New-PathSet
foreach ($row in $selected) { [void]$selectedSet.Add([string]$row.Path) }

$plan = New-Plan -Title 'Doubletten finden' -Group 'Database' -Script 'FindDuplicates' -Roots @('Input', 'ToDelete/Doublets')
$plan.Data.Selected = @($selected | ForEach-Object { [string]$_.Path })
$plan.Data.FoundInResult = 0
$plan.Data.FoundInInput = 0
$reserved = New-PathSet
$handledHashes = New-PathSet

foreach ($row in $selected) {
    $hash = [string]$row.Hash
    if (-not $hash -or $handledHashes.Contains($hash)) { continue }
    # Files with 0 bytes are never duplicates (2.2 section 5).
    if ([long]$row.Size -le 0) { continue }
    [void]$handledHashes.Add($hash)
    $sameHash = Get-EntriesByHash $hash
    $group = @($sameHash | Where-Object {
            $p = [string]$_.Path
            ((Test-RelUnder $p 'Input') -or (Test-RelUnder $p 'Result')) -and [System.IO.File]::Exists((ConvertTo-AbsPath $p))
        })
    if ($group.Count -lt 2) { continue }
    $inResult = @($group | Where-Object { Test-RelUnder ([string]$_.Path) 'Result' } | Sort-Object { [string]$_.Path })
    $inInput = @($group | Where-Object { Test-RelUnder ([string]$_.Path) 'Input' })
    if ($inResult.Count -gt 0) {
        $original = $inResult[0]
        $where = 'Result'
    }
    else {
        # Oldest capture date, on a tie the alphabetically first path (2.2 section 3).
        $original = @($inInput | Sort-Object @{ Expression = { if ($_.CaptureDate) { [string]$_.CaptureDate } else { '9999' } } }, @{ Expression = { [string]$_.Path } })[0]
        $where = 'Input'
    }
    $originalPath = [string]$original.Path
    foreach ($dup in $inInput) {
        $dupPath = [string]$dup.Path
        if (Test-RelEqual $dupPath $originalPath) { continue }
        if (-not $selectedSet.Contains($dupPath)) { continue }   # earlier checked files are not checked again
        $target = Get-UniqueRelPath -RelPath ('ToDelete/Doublets/' + (Get-RelName $dupPath)) -Reserved $reserved
        [void]$reserved.Add($target)
        $move = Add-PlanItem -Plan $plan -Action 'MoveFile' -Source $dupPath -Target $target -Info "Original in ${where}: $originalPath" `
            -Extra "Original: $originalPath"
        $move.Data.Original = $originalPath
        $fileSuffix = " - $where File.lnk"
        $folderSuffix = " - $where Folder.lnk"
        $l1 = Add-PlanItem -Plan $plan -Action 'CreateLink' -Target ($target + $fileSuffix) -LinkTarget $originalPath -ParentId $move.Id -Info 'Verknüpfung zur Datei'
        $l1.Data.LinkSuffix = $fileSuffix
        $l2 = Add-PlanItem -Plan $plan -Action 'CreateLink' -Target ($target + $folderSuffix) -LinkTarget (Get-RelParent $originalPath) -ParentId $move.Id -Info 'Verknüpfung zum Ordner'
        $l2.Data.LinkSuffix = $folderSuffix
        if ($where -eq 'Result') { $plan.Data.FoundInResult++ } else { $plan.Data.FoundInInput++ }
    }
}

$plan.OnExecuted = {
    param($plan, $log)
    # Every selected file is marked as checked: duplicate, rejected or unique (2.2 section 3 step 7).
    $moved = @{}
    foreach ($s in $log.Steps) { if ($s.Type -eq 'MOVED') { $moved[$s.Old.ToLowerInvariant()] = $s.New } }
    $now = Get-NowText
    foreach ($p in $plan.Data.Selected) {
        $path = $p
        if ($moved.ContainsKey($p.ToLowerInvariant())) { $path = $moved[$p.ToLowerInvariant()] }
        try { Update-FileEntryFields -RelPath $path -Fields @{ DuplicateChecked = $now } } catch { }
    }
    $rejected = @($log.Steps | Where-Object { $_.Type -eq 'REJECTED' }).Count
    $log.Extra['Summary'] = "Checked $($plan.Data.Selected.Count), duplicates $($plan.Data.FoundInResult + $plan.Data.FoundInInput) (original in Result $($plan.Data.FoundInResult), in Input $($plan.Data.FoundInInput)), moved $($log.FilesMoved), rejected $rejected"
}
$plan.SummaryExtra = {
    param($plan)
    "Geprüft: $($plan.Data.Selected.Count)   Doubletten: $($plan.Data.FoundInResult + $plan.Data.FoundInInput) (Original in Result: $($plan.Data.FoundInResult), in Input: $($plan.Data.FoundInInput))"
}

if ($plan.Items.Count -eq 0) {
    $log = New-ActionLog -Group 'Database' -Script 'FindDuplicates'
    & $plan.OnExecuted $plan $log
    [void](Save-ActionLog $log)
    return (New-FunctionResult -Kind Message -Message "Doubletten finden: $($selected.Count) Dateien geprüft, keine Doubletten gefunden.")
}
return $plan
