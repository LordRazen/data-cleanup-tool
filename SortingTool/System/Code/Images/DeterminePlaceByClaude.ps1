# DeterminePlaceByClaude.ps1 (2.7)
# Estimates the place of day folders "YYYY-MM-DD" without place from a few photos chosen by hand
# (landmarks, signs, landscape), using Claude through the subscription (3.1), and adds it to the
# folder name. Only the chosen images (as small copies without metadata) and the date are sent,
# no file names, no GPS. A place guessed by Claude is never applied without the preview.

param($Context, [hashtable]$Arguments = @{})

$places = $global:ST.Settings.places
$maxImages = [Math]::Max(1, [int]$places.maxImagesPerFolder)
$minConfidence = [double]$places.minConfidence

$groups = Get-InputFolderGroups
if ($groups.Other.Count -gt 0) {
    $answer = Show-ChoiceDialog -Text 'Die folgenden Ordner in Input haben kein Datumsformat und werden ignoriert:' -Lines $groups.Other -Buttons @('Weiter', 'Abbrechen') -Title 'Ort bestimmen (Claude)'
    if ($answer -ne 'Weiter') { return (New-FunctionResult -Kind Cancelled) }
}
if ($groups.Day.Count -eq 0) {
    return (New-FunctionResult -Kind Message -Message 'Ort bestimmen (Claude): In Input gibt es keine Tagesordner ohne Ort (Format JJJJ-MM-TT).')
}
Write-StatusText 'Prüfe, ob Claude verfügbar ist …'
$status = Test-ClaudeEndpoint
if (-not $status.Available) {
    foreach ($b in $global:ST.Buttons) {
        if (@($b.Functions | ForEach-Object { $_.name }) -contains 'DeterminePlaceByClaude') { $b.Available = $false }
    }
    return (New-FunctionResult -Kind Failed -Message $status.Message)
}
Reset-ClaudeRun

# ---------------------------------------------------------------- selection dialog (2.7 section 4)
$sel = @{ Selections = @{}; Loading = $false; Folder = $null; Pending = (New-Object System.Collections.Generic.List[object]); Max = $maxImages }
foreach ($day in $groups.Day) { $sel.Selections[$day] = New-PathSet }

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Ort bestimmen (Claude): Beispielbilder wählen'
$form.StartPosition = 'CenterParent'
$form.Width = 1100
$form.Height = 720
$hint = New-Object System.Windows.Forms.Label
$hint.Dock = 'Top'
$hint.Height = 40
$hint.Padding = New-Object System.Windows.Forms.Padding 8
$hint.Text = "Wähle pro Ordner die Bilder, die Claude ansehen soll (z. B. mit Sehenswürdigkeit oder Schild), höchstens $maxImages pro Ordner. Ordner ohne ausgewähltes Bild werden übersprungen."
$split = New-Object System.Windows.Forms.SplitContainer
$split.Dock = 'Fill'
$folderList = New-Object System.Windows.Forms.ListBox
$folderList.Dock = 'Fill'
$folderList.IntegralHeight = $false
foreach ($day in $groups.Day) { [void]$folderList.Items.Add($day) }
$split.Panel1.Controls.Add($folderList)
$imageList = New-Object System.Windows.Forms.ImageList
$imageList.ColorDepth = [System.Windows.Forms.ColorDepth]::Depth32Bit
$imageList.ImageSize = New-Object System.Drawing.Size 128, 128
$blank = New-Object System.Drawing.Bitmap 128, 128
$imageList.Images.Add('blank', $blank)
$view = New-Object System.Windows.Forms.ListView
$view.Dock = 'Fill'
$view.View = 'LargeIcon'
$view.CheckBoxes = $true
$view.LargeImageList = $imageList
$maxLabel = New-Object System.Windows.Forms.Label
$maxLabel.Dock = 'Top'
$maxLabel.Height = 22
$maxLabel.ForeColor = [System.Drawing.Color]::DarkRed
$split.Panel2.Controls.Add($view)
$split.Panel2.Controls.Add($maxLabel)
$buttons = New-Object System.Windows.Forms.FlowLayoutPanel
$buttons.Dock = 'Bottom'
$buttons.FlowDirection = 'RightToLeft'
$buttons.Height = 44
$buttons.Padding = New-Object System.Windows.Forms.Padding 6
$cancel = New-Object System.Windows.Forms.Button
$cancel.Text = 'Abbrechen'
$cancel.AutoSize = $true
$cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
$next = New-Object System.Windows.Forms.Button
$next.Text = 'Weiter'
$next.AutoSize = $true
$next.DialogResult = [System.Windows.Forms.DialogResult]::OK
$buttons.Controls.AddRange(@($cancel, $next))
$form.Controls.Add($split)
$form.Controls.Add($hint)
$form.Controls.Add($buttons)
$form.CancelButton = $cancel
$sel.View = $view
$sel.Images = $imageList
$sel.MaxLabel = $maxLabel
$sel.FolderList = $folderList

$sel.UpdateFolderTexts = {
    for ($i = 0; $i -lt $sel.FolderList.Items.Count; $i++) {
        $day = $groups.Day[$i]
        $n = $sel.Selections[$day].Count
        $text = $day
        if ($n -gt 0) { $text = "$day ($n ausgewählt)" }
        if ([string]$sel.FolderList.Items[$i] -ne $text) { $sel.FolderList.Items[$i] = $text }
    }
}
$folderList.Add_SelectedIndexChanged({
        if ($sel.Loading -or $this.SelectedIndex -lt 0) { return }
        $day = $groups.Day[$this.SelectedIndex]
        if ($sel.Folder -eq $day) { return }
        $sel.Folder = $day
        $sel.Loading = $true
        $sel.View.BeginUpdate()
        $sel.View.Items.Clear()
        $sel.Pending.Clear()
        foreach ($key in @($sel.Images.Images.Keys)) { if ($key -ne 'blank') { $sel.Images.Images.RemoveByKey($key) } }
        # Only images, no videos (2.7 section 4).
        $files = Get-FilesRecursive (ConvertTo-AbsPath "Input/$day")
        foreach ($f in ($files | Where-Object { (Get-ExtensionKind $_.Name) -eq 'Image' } | Sort-Object Name)) {
            $rel = ConvertTo-RelPath $f.FullName
            $item = New-Object System.Windows.Forms.ListViewItem $f.Name
            $item.ImageKey = 'blank'
            $item.Tag = $rel
            $item.Checked = $sel.Selections[$day].Contains($rel)
            [void]$sel.View.Items.Add($item)
            $sel.Pending.Add($item)
        }
        $sel.View.EndUpdate()
        $sel.MaxLabel.Text = ''
        $sel.Loading = $false
    })
$view.Add_ItemCheck({
        param($sender, $e)
        if ($sel.Loading -or -not $sel.Folder) { return }
        if ($e.NewValue -eq [System.Windows.Forms.CheckState]::Checked -and $sel.Selections[$sel.Folder].Count -ge $sel.Max) {
            $e.NewValue = $e.CurrentValue
            $sel.MaxLabel.Text = "Maximum erreicht: höchstens $($sel.Max) Bilder pro Ordner."
        }
    })
$view.Add_ItemChecked({
        param($sender, $e)
        if ($sel.Loading -or -not $sel.Folder) { return }
        $set = $sel.Selections[$sel.Folder]
        if ($e.Item.Checked) { [void]$set.Add([string]$e.Item.Tag) } else { [void]$set.Remove([string]$e.Item.Tag) }
        if ($set.Count -lt $sel.Max) { $sel.MaxLabel.Text = '' }
        & $sel.UpdateFolderTexts
    })
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 120
$timer.Add_Tick({
        $done = 0
        while ($sel.Pending.Count -gt 0 -and $done -lt 4) {
            $item = $sel.Pending[0]
            $sel.Pending.RemoveAt(0)
            if ($item.ListView -ne $sel.View) { continue }
            $bmp = New-ThumbnailBitmap -Path (ConvertTo-AbsPath ([string]$item.Tag)) -Size 128
            if ($bmp) {
                $key = 'thumb:' + [string]$item.Tag
                $sel.Images.Images.Add($key, $bmp)
                $item.ImageKey = $key
            }
            $done++
        }
    })
$form.Add_Shown({ if ($sel.FolderList.Items.Count -gt 0) { $sel.FolderList.SelectedIndex = 0 }; $timer.Start() })
$result = $form.ShowDialog((Get-OwnerForm))
$timer.Stop()
$timer.Dispose()
$form.Dispose()
if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return (New-FunctionResult -Kind Cancelled) }

$todo = @($groups.Day | Where-Object { $sel.Selections[$_].Count -gt 0 })
if ($todo.Count -eq 0) {
    return (New-FunctionResult -Kind Message -Message 'Ort bestimmen (Claude): Es wurde kein Bild ausgewählt, Claude wurde nicht gefragt.')
}

# ---------------------------------------------------------------- ask Claude, one call per folder
$plan = New-Plan -Title 'Ort bestimmen (Claude)' -Group 'Images' -Script 'DeterminePlaceByClaude' -Roots @('Input')
$plan.EditLabel = 'Ort (bearbeitbar)'
$plan.Notice = 'Von Claude geschätzt – bitte prüfen.'
$k = 0
foreach ($day in $todo) {
    $k++
    $folder = "Input/$day"
    Write-StatusText "Claude schätzt den Ort: Ordner $k von $($todo.Count) ($day) …"
    $copies = New-ClaudeImageCopies -RelPaths @($sel.Selections[$day])
    if ($copies.Count -eq 0) {
        [void](Add-PlanItem -Plan $plan -Action 'Info' -Source $folder -Info 'Bilder konnten nicht gelesen werden – wird übersprungen')
        continue
    }
    $date = [datetime]::ParseExact($day, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture).ToString('yyyy-MM-dd')
    $prompt = "These photos were taken on $date. Where were they most likely taken? Answer only with JSON: {`"place`": city or town in German, `"country`": country in German, `"confidence`": number from 0 to 1, `"reason`": short reason in German}. If you cannot tell, set place to null."
    try {
        $answer = Invoke-ClaudeWithLimitWait -Prompt $prompt -Files @($copies) -ExpectJson -ProgressText "$($k - 1) von $($todo.Count) Ordnern bearbeitet"
    }
    finally { Remove-ClaudeImageCopies $copies }
    if (-not $answer.Success) {
        Add-PlanPreStep -Plan $plan -Type 'API_CALL' -Old 'ClaudeEndpoint' -New "$day ($($copies.Count) images)" -Extra (Format-ApiCallExtra $answer $answer.Error)
        $text = 'Ort konnte nicht bestimmt werden'
        if ($answer.ErrorKind -eq 'Skipped') { $text = 'übersprungen (Nutzungslimit)' }
        [void](Add-PlanItem -Plan $plan -Action 'Info' -Source $folder -Info $text)
        continue
    }
    $data = $answer.Data
    $place = ''
    if ($data.PSObject.Properties['place'] -and $data.place) { $place = Remove-InvalidNameChars ([string]$data.place) }
    $confidence = 0.0
    if ($data.PSObject.Properties['confidence']) { try { $confidence = [double]$data.confidence } catch { } }
    $reason = ''
    if ($data.PSObject.Properties['reason']) { $reason = [string]$data.reason }
    $country = ''
    if ($data.PSObject.Properties['country']) { $country = [string]$data.country }
    Add-PlanPreStep -Plan $plan -Type 'API_CALL' -Old 'ClaudeEndpoint' -New "$day ($($copies.Count) images)" `
        -Extra (Format-ApiCallExtra $answer "Place=$place; Country=$country; Confidence=$confidence; Reason=$reason")
    $good = ($place -and $confidence -ge $minConfidence)
    $shownPlace = $place
    if (-not $shownPlace) { $shownPlace = 'unbekannt' }
    $percent = [int][Math]::Round($confidence * 100)
    $item = Add-PlanItem -Plan $plan -Action 'MoveFolder' -Source $folder -Target $folder -Checked $good -Weak (-not $good) `
        -Info "$shownPlace – $percent % – $reason" -Extra "Place=$place; Confidence=$confidence; Source=Claude"
    $item.EditMode = 'Suffix'
    $item.EditPrefix = "$day - "
    $default = $place
    if (-not $default) { $default = 'Unbekannter Ort' }
    $item.EditValue = $default
    $item.Data.DefaultSuffix = $default
    Set-SuffixRenameTarget -Plan $plan -Item $item
}
$plan.OnItemEdited = {
    param($plan, $item)
    Set-SuffixRenameTarget -Plan $plan -Item $item
}
return $plan
