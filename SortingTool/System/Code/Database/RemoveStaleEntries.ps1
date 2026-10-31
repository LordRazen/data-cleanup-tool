# RemoveStaleEntries.ps1 (2.4)
# Removes every database entry whose file no longer exists at its stored path, for all folders
# (Input, Result, ToDelete). Only database rows are removed, never a file. No hashing.
# Safety check: if a main folder is missing or more than half of its entries are missing, the
# entries of that folder are offered unchecked with a warning (drive not connected?).

param($Context, [hashtable]$Arguments = @{})

Write-StatusText 'Datenbank bereinigen: Einträge werden geprüft …'
$rows = Invoke-DbQuery 'SELECT * FROM Files ORDER BY Path'
$total = @{}
$missing = @{}
$stale = New-Object System.Collections.Generic.List[object]
$n = 0
foreach ($row in $rows) {
    $n++
    if ($n % 500 -eq 0) { Write-StatusText "Datenbank bereinigen: $n von $($rows.Count) Einträgen geprüft …" }
    $path = [string]$row.Path
    $root = Get-RelRoot $path
    if ($total.ContainsKey($root)) { $total[$root]++ } else { $total[$root] = 1 }
    if (-not [System.IO.File]::Exists((ConvertTo-AbsPath $path))) {
        if ($missing.ContainsKey($root)) { $missing[$root]++ } else { $missing[$root] = 1 }
        $stale.Add($row)
    }
}
if ($stale.Count -eq 0) {
    return (New-FunctionResult -Kind Message -Message 'Keine veralteten Einträge gefunden.')
}

$unsafe = New-PathSet
foreach ($root in $missing.Keys) {
    $folderMissing = -not [System.IO.Directory]::Exists((ConvertTo-AbsPath $root))
    if ($folderMissing -or ($missing[$root] * 2 -gt $total[$root])) { [void]$unsafe.Add($root) }
}

$plan = New-Plan -Title 'Datenbank bereinigen' -Group 'Database' -Script 'RemoveStaleEntries' -Roots @('Input', 'Result', 'ToDelete')
foreach ($row in $stale) {
    $path = [string]$row.Path
    $checked = -not $unsafe.Contains((Get-RelRoot $path))
    [void](Add-PlanItem -Plan $plan -Action 'RemoveEntry' -Source $path -Checked $checked -Data @{ Row = $row })
}
if ($unsafe.Count -gt 0) {
    $messages = @()
    foreach ($root in $unsafe) { $messages += "Der Ordner $root fehlt oder ist größtenteils leer. Ist die Platte richtig angeschlossen?" }
    $plan.Notice = ($messages -join ' ') + ' Diese Einträge sind deshalb nicht angehakt.'
    Show-ErrorMessage ($messages -join "`r`n")
}
$plan.LogExtra['Summary'] = "Entries checked $($rows.Count), stale $($stale.Count)"
return $plan
