# GroupByCaptureDate.ps1 (2.3)
# Groups the image and video files lying directly in Input by their capture day: one folder
# "YYYY-MM-DD" per day in Input, the files of that day move into it. Never renames a file.
# Days with at least minImagesPerDay files are checked, the others unchecked. The preview has a
# threshold field with "Übernehmen"; folders set by hand keep their state (hand symbol) until
# "Automatisch setzen" is chosen in their context menu.

param($Context, [hashtable]$Arguments = @{})

$settings = $global:ST.Settings
$inputAbs = ConvertTo-AbsPath 'Input'

# Warning for folders that are not day folders (2.3 section 3).
$otherFolders = @()
foreach ($d in (New-Object System.IO.DirectoryInfo $inputAbs).GetDirectories()) {
    if (-not (Test-DayFolderName $d.Name)) { $otherFolders += $d.Name }
}
if ($otherFolders.Count -gt 0) {
    $answer = Show-ChoiceDialog -Text 'Die folgenden Ordner in Input haben kein Datumsformat und werden ignoriert:' -Lines ($otherFolders | Sort-Object) -Buttons @('Weiter', 'Abbrechen') -Title 'Nach Aufnahmedatum gruppieren'
    if ($answer -ne 'Weiter') { return (New-FunctionResult -Kind Cancelled) }
}

# Files directly in Input (2.3 section 3), images and videos only.
$files = @((New-Object System.IO.DirectoryInfo $inputAbs).GetFiles() | Where-Object { (Get-ExtensionKind $_.Name) -ne 'Other' })
if ($files.Count -eq 0) {
    return (New-FunctionResult -Kind Message -Message 'Nach Aufnahmedatum gruppieren: Direkt in Input liegen keine Bild- oder Videodateien.')
}

$byDay = @{}
$n = 0
Start-DbTransaction
try {
    foreach ($f in $files) {
        $n++
        Write-StatusText "Aufnahmedatum wird gelesen: $n von $($files.Count) …"
        $rel = ConvertTo-RelPath $f.FullName
        $entry = Resolve-FileEntry $rel   # files without entry get one on the fly
        $date = $null
        $source = 'FileSystem'
        if ($entry -and $entry.CaptureDate) { $date = ConvertFrom-DbDate $entry.CaptureDate; $source = [string]$entry.CaptureDateSource }
        if ($null -eq $date) { $c = Get-CaptureDate -Path $f.FullName; $date = $c.Date; $source = $c.Source }
        $day = $date.ToString('yyyy-MM-dd')
        if (-not $byDay.ContainsKey($day)) { $byDay[$day] = New-Object System.Collections.Generic.List[object] }
        $byDay[$day].Add(@{ Rel = $rel; Name = $f.Name; Date = $date; Source = $source })
    }
}
finally { Complete-DbTransaction }

$threshold = [int]$settings.minImagesPerDay
$plan = New-Plan -Title 'Nach Aufnahmedatum gruppieren' -Group 'Images' -Script 'GroupByCaptureDate' -Roots @('Input')
$plan.Data.Threshold = $threshold
$plan.Data.Manual = New-PathSet
$plan.Data.Days = @{}   # folder path -> @{ FolderItem; FileItems; Count }

foreach ($day in ($byDay.Keys | Sort-Object)) {
    $folder = "Input/$day"
    $entries = $byDay[$day]
    $checked = ($entries.Count -ge $threshold)
    $folderItem = Add-PlanItem -Plan $plan -Action 'CreateFolder' -Target $folder
    $dayInfo = @{ FolderItem = $folderItem; FileItems = (New-Object System.Collections.Generic.List[object]); Count = $entries.Count }
    foreach ($e in ($entries | Sort-Object { $_.Name })) {
        $target = "$folder/$($e.Name)"
        $sourceLabel = Get-CaptureSourceLabel $e.Source
        $extra = "CaptureDate=$($e.Date.ToString('yyyy-MM-dd HH:mm:ss')); Source=$($e.Source)"
        if (Test-RelExists $target) {
            # Never renamed: a conflicting file stays in Input (2.3 section 4).
            $item = Add-PlanItem -Plan $plan -Action 'MoveFile' -Source $e.Rel -Target $target -Locked $true -AllowSuffix $false `
                -Conflict 'Name conflict in day folder, file stays in Input' -Info "Konflikt: Im Tagesordner gibt es schon „$($e.Name)“, bleibt in Input" -Extra $extra
        }
        else {
            $item = Add-PlanItem -Plan $plan -Action 'MoveFile' -Source $e.Rel -Target $target -Checked $checked -AllowSuffix $false `
                -Info "($sourceLabel)" -Weak ($e.Source -eq 'FileSystem') -Extra $extra
        }
        $dayInfo.FileItems.Add($item)
    }
    $plan.Data.Days[$folder.ToLowerInvariant()] = $dayInfo
}

$plan.Data.UpdateFolderInfo = {
    param($plan)
    foreach ($d in $plan.Data.Days.Values) {
        $info = ''
        if ($plan.Data.Manual.Contains($d.FolderItem.Target)) { $info = '✋ von Hand gesetzt' }
        $d.FolderItem.Info = $info
    }
}
$plan.Data.ApplyThreshold = {
    param($plan, [string]$OnlyFolder)
    foreach ($d in $plan.Data.Days.Values) {
        $folder = $d.FolderItem.Target
        if ($OnlyFolder -and -not (Test-RelEqual $OnlyFolder $folder)) { continue }
        if (-not $OnlyFolder -and $plan.Data.Manual.Contains($folder)) { continue }
        $checked = ($d.Count -ge $plan.Data.Threshold)
        foreach ($i in $d.FileItems) { if (-not $i.Locked) { $i.Checked = $checked } }
    }
}
$plan.OnFolderToggled = {
    param($plan, $folderPath, $checked)
    if ($plan.Data.Days.ContainsKey($folderPath.ToLowerInvariant())) {
        [void]$plan.Data.Manual.Add($folderPath)
        & $plan.Data.UpdateFolderInfo $plan
    }
}
$plan.FolderMenu = @(@{
        Label  = 'Automatisch setzen'
        Action = {
            param($plan, $folderPath, $api)
            if ($plan.Data.Days.ContainsKey($folderPath.ToLowerInvariant())) {
                [void]$plan.Data.Manual.Remove($folderPath)
                & $plan.Data.ApplyThreshold $plan $folderPath
                & $plan.Data.UpdateFolderInfo $plan
            }
        }
    })
$plan.ExtendPreview = {
    param($plan, $panel, $api)
    $label = New-Object System.Windows.Forms.Label
    $label.Text = 'Mindestanzahl Bilder pro Tag'
    $label.AutoSize = $true
    $label.Margin = New-Object System.Windows.Forms.Padding 3, 7, 3, 3
    $number = New-Object System.Windows.Forms.NumericUpDown
    $number.Minimum = 1
    $number.Maximum = 100000
    $number.Value = [Math]::Max(1, $plan.Data.Threshold)
    $number.Width = 80
    $apply = New-Object System.Windows.Forms.Button
    $apply.Text = 'Übernehmen'
    $apply.AutoSize = $true
    $apply.Tag = @{ Plan = $plan; Number = $number; Api = $api }
    $apply.Add_Click({
            $t = $this.Tag
            # Only for this preview; settings.json stays unchanged (2.3 section 6).
            $t.Plan.Data.Threshold = [int]$t.Number.Value
            & $t.Plan.Data.ApplyThreshold $t.Plan ''
            & $t.Api.Refresh
        })
    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = 'Rechtsklick auf einen von Hand gesetzten Ordner: „Automatisch setzen“'
    $hint.AutoSize = $true
    $hint.ForeColor = [System.Drawing.Color]::DimGray
    $hint.Margin = New-Object System.Windows.Forms.Padding 20, 7, 3, 3
    $panel.Controls.AddRange(@($label, $number, $apply, $hint))
}
$plan.SummaryExtra = {
    param($plan)
    $on = 0; $off = 0
    foreach ($d in $plan.Data.Days.Values) {
        $any = $false
        foreach ($i in $d.FileItems) { if ($i.Checked -and -not $i.Locked) { $any = $true; break } }
        if ($any) { $on++ } else { $off++ }
    }
    "Tagesordner angehakt: $on   nicht angehakt: $off"
}
return $plan
