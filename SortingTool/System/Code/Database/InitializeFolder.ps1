# InitializeFolder.ps1 (2.1)
# Records every file of Input or Result in the database: SHA-256, dHash for images, size,
# modification date, capture date with its source and GPS position (2.1 sections 3 and 4).
# Only the database changes, never a file. No preview, a progress bar and a summary instead.
# Can be cancelled at any time; everything already computed stays stored.
# Parameter: -Folder Input | Result (passed by the button via "arguments").

param($Context, [hashtable]$Arguments = @{})

$folder = [string]$Arguments['Folder']
if ($folder -ne 'Input' -and $folder -ne 'Result') {
    return (New-FunctionResult -Kind Failed -Message "Unbekannter Ordner für InitializeFolder: '$folder' (erlaubt: Input, Result).")
}
$label = $folder
$log = New-ActionLog -Group 'Database' -Script "Initialize$folder"
$absFolder = ConvertTo-AbsPath $folder
Write-StatusText "$label initialisieren: Dateien werden gezählt …"
$files = Get-FilesRecursive $absFolder

$existing = @{}
foreach ($row in (Get-EntriesUnder $folder)) { $existing[([string]$row.Path).ToLowerInvariant()] = $row }

$count = @{ New = 0; Unchanged = 0; Recomputed = 0; Moved = 0; Missing = 0; Errors = 0 }
$progress = New-ProgressDialog "$label initialisieren"
$cancelled = $false
$i = 0
Start-DbTransaction
try {
    foreach ($file in $files) {
        $i++
        Update-ProgressDialog -Dialog $progress -Value $i -Maximum $files.Count -Text "$i von $($files.Count): $($file.Name)"
        if ($progress.Cancelled) { $cancelled = $true; break }
        try {
            $rel = ConvertTo-RelPath $file.FullName
            $key = $rel.ToLowerInvariant()
            $entry = $null
            if ($existing.ContainsKey($key)) { $entry = $existing[$key] }
            if ($null -ne $entry -and (Test-EntryUpToDate -Entry $entry -Info $file)) {
                # Step 1: unchanged, nothing is computed.
                $count.Unchanged++
            }
            elseif ($null -ne $entry) {
                # Step 2: size or date changed, hashes and capture date are recomputed.
                Set-FileEntry (New-FileEntryData -RelPath $rel)
                $count.Recomputed++
            }
            else {
                # Step 3: new path. Same hash at a path whose file is gone = moved outside the tool.
                $data = New-FileEntryData -RelPath $rel
                $movedFrom = $null
                foreach ($candidate in (Get-EntriesByHash $data.Hash)) {
                    $cPath = [string]$candidate.Path
                    if (Test-RelEqual $cPath $rel) { continue }
                    if (-not [System.IO.File]::Exists((ConvertTo-AbsPath $cPath))) { $movedFrom = $candidate; break }
                }
                if ($null -ne $movedFrom) {
                    $oldPath = [string]$movedFrom.Path
                    # Keep what was learned about the file (category, keyword, ...), take the new values.
                    foreach ($col in @('Category', 'Keyword', 'NameHint', 'CategorySetHash')) { $data[$col] = $movedFrom[$col] }
                    Remove-FileEntry $oldPath
                    Set-FileEntry $data
                    Add-LogStep -Log $log -Type 'ENTRY_PATH_UPDATED' -Old $oldPath -New $rel -Extra 'File was moved outside the tool'
                    $count.Moved++
                }
                else {
                    Set-FileEntry $data
                    $count.New++
                }
            }
        }
        catch {
            $count.Errors++
            Add-LogStep -Log $log -Type 'ERROR' -Old $file.FullName -New '' -Extra $_.Exception.Message
        }
        if ($i % 200 -eq 0) { Complete-DbTransaction; Start-DbTransaction }
    }
    if (-not $cancelled) {
        # Step 4: entries of this folder whose file no longer exists (database row only).
        Update-ProgressDialog -Dialog $progress -Value $files.Count -Maximum $files.Count -Text 'Fehlende Dateien werden aus der Datenbank entfernt …'
        foreach ($row in (Get-EntriesUnder $folder)) {
            $path = [string]$row.Path
            if (-not [System.IO.File]::Exists((ConvertTo-AbsPath $path))) {
                $json = (ConvertTo-EntryHashtable $row) | ConvertTo-Json -Compress
                Remove-FileEntry $path
                Add-LogStep -Log $log -Type 'ENTRY_REMOVED' -Old $path -New '' -Extra $json
                $count.Missing++
            }
        }
    }
}
finally {
    Complete-DbTransaction
    Close-ProgressDialog $progress
}

$summary = "neu $($count.New), unverändert $($count.Unchanged), neu berechnet $($count.Recomputed), verschoben erkannt $($count.Moved), fehlend $($count.Missing)"
if ($count.Errors -gt 0) { $summary += ", Fehler $($count.Errors)" }
$log.Extra['Summary'] = "New $($count.New), unchanged $($count.Unchanged), recomputed $($count.Recomputed), moved $($count.Moved), missing $($count.Missing), errors $($count.Errors)"
if ($cancelled) { $log.Extra['Cancelled'] = "after $i of $($files.Count) files" }
[void](Save-ActionLog $log)

if ($cancelled) {
    return (New-FunctionResult -Kind Cancelled -Message "$label initialisieren abgebrochen nach $i von $($files.Count) Dateien. Bisher: $summary. Beim nächsten Mal geht es dort weiter.")
}
Write-StatusText "$label initialisiert: $summary."
return (New-FunctionResult -Kind Done -Message "$label initialisiert:`r`n$summary.")
