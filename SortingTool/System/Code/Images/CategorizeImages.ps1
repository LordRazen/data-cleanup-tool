# CategorizeImages.ps1 (2.8)
# Lets Claude put images in Input into coarse categories (Recipe, Meme, Screenshot, ... from
# System/Config/Categories/*.json, or Default "Sonstiges"). Recognized images get a new name built
# from a keyword and are pre-sorted inside Input into a folder named like the category's target
# folder (Input/Rezepte, Input/Screenshots/2023, Input/Memes, Input/Sonstiges). Moving the category
# folders to Result or ToDelete is done later by MoveCategoryFolders (2.9).
# A local pre-assessment by file name runs first and for free (2.8 section 5a).

param($Context, [hashtable]$Arguments = @{})

$cfg = $global:ST.Settings.categories
$minDefault = [double]$cfg.minCategoryConfidence
$maxKeyword = [int]$cfg.maxKeywordLength
if ($maxKeyword -le 0) { $maxKeyword = 80 }
$generic = @($cfg.genericNamePatterns)
$defs = Get-CategoryDefinitions
if ($defs.Count -eq 0) {
    return (New-FunctionResult -Kind Failed -Message 'Es gibt keine aktiven Kategorien in System/Config/Categories.')
}
$setHash = Get-CategorySetHash $defs
$defaultFolder = 'Sonstiges'
$defByName = @{}
foreach ($d in $defs) { $defByName[([string]$d.name).ToLowerInvariant()] = $d }

# ---------------------------------------------------------------- helpers
function ConvertTo-HintText {
    # Lower case, separators as spaces, umlauts once as written and once as ae/oe/ue/ss.
    param([string]$Text)
    $t = ($Text.ToLowerInvariant() -replace '[_\-\.\s]+', ' ').Trim()
    $alt = $t.Replace('ä', 'ae').Replace('ö', 'oe').Replace('ü', 'ue').Replace('ß', 'ss')
    return @($t, $alt)
}

function Get-NameHint {
    # Pre-assessment by file name (2.8 section 5a). Returns @{ Category; Words; Tie }.
    param([string]$FileName)
    $base = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    foreach ($g in $generic) { if ($base -like $g) { return @{ Category = $null; Words = @(); Tie = @() } } }
    $forms = ConvertTo-HintText $base
    $best = @{}
    foreach ($d in $defs) {
        $words = @()
        foreach ($p in @($d.namePatterns)) {
            if (-not $p) { continue }
            $pForms = ConvertTo-HintText ([string]$p)
            $hit = $false
            foreach ($pf in $pForms) {
                foreach ($nf in $forms) {
                    if ($pf.IndexOfAny([char[]]'*?') -ge 0) {
                        if ($nf -like $pf -or @($nf.Split(' ') | Where-Object { $_ -like $pf }).Count -gt 0) { $hit = $true }
                    }
                    elseif ($nf.Contains($pf)) { $hit = $true }
                }
            }
            if ($hit) { $words += [string]$p }
        }
        if ($words.Count -gt 0) { $best[[string]$d.name] = $words }
    }
    if ($best.Count -eq 0) { return @{ Category = $null; Words = @(); Tie = @() } }
    $max = ($best.Values | ForEach-Object { $_.Count } | Measure-Object -Maximum).Maximum
    $top = @($best.Keys | Where-Object { $best[$_].Count -eq $max })
    if ($top.Count -gt 1) { return @{ Category = $null; Words = @(); Tie = $top } }
    return @{ Category = $top[0]; Words = $best[$top[0]]; Tie = @() }
}

function Get-CategoryLabel {
    param([string]$Category)
    if (-not $Category -or $Category -eq 'Default') { return 'Sonstiges' }
    $d = $defByName[$Category.ToLowerInvariant()]
    if ($d) { return [string]$d.label }
    return $Category
}

# Target path inside Input for an image, a category, a subfolder and a keyword (2.8 section 5
# step 6). Kept as a script block in the plan, because the preview calls it after this script ended.
$getTarget = {
    param($plan, $Image, [string]$Category, [string]$Subfolder, [string]$Keyword, $Reserved)
    $name = $Image.Name
    if (-not $Category -or $Category -eq 'Default') {
        $folder = 'Input/Sonstiges'
    }
    else {
        $d = $plan.Data.Defs[$Category.ToLowerInvariant()]
        $folder = "Input/$($d.folder)"
        if ($d.subfolderByYear -eq $true) {
            $folder = "$folder/$($Image.CaptureDate.ToString('yyyy'))"
        }
        elseif ($Subfolder) {
            $folder = "$folder/$Subfolder"
        }
        if ($d.rename -ne $false -and $Keyword) {
            $base = $Keyword
            if ([string]$d.keywordPrefix -eq 'CaptureDate') { $base = "$($Image.CaptureDate.ToString('yyyy-MM-dd')) - $Keyword" }
            $name = $base + [System.IO.Path]::GetExtension($Image.Name)
        }
    }
    $target = "$folder/$name"
    if (Test-RelEqual $target $Image.Rel) { return $target }
    return (Get-UniqueRelPath -RelPath $target -Reserved $Reserved)
}

# ---------------------------------------------------------------- collect (2.8 section 4)
$excludedTop = New-PathSet
foreach ($d in $defs) { [void]$excludedTop.Add([string]$d.folder) }
$claudeStatus = Test-ClaudeEndpoint
$claudeOk = $claudeStatus.Available
Reset-ClaudeRun
$maxCalls = [int]$global:ST.Settings.api.claude.maxCallsPerRun

Write-StatusText 'Bilder kategorisieren: Bilder werden gesammelt …'
$images = New-Object System.Collections.Generic.List[object]
$markOnly = New-Object System.Collections.Generic.List[string]
$all = Get-FilesRecursive (ConvertTo-AbsPath 'Input')
Start-DbTransaction
try {
    $n = 0
    foreach ($f in $all) {
        $n++
        if ((Get-ExtensionKind $f.Name) -ne 'Image') { continue }
        $rel = ConvertTo-RelPath $f.FullName
        $parts = $rel.Split('/')
        if ($parts.Count -gt 2) {
            $top = $parts[1]
            if ($excludedTop.Contains($top)) { continue }                       # already sorted
            if (Test-DayFolderName $top -AllowPlace) { continue }               # event workflow
        }
        if ($n % 50 -eq 0) { Write-StatusText "Bilder kategorisieren: $n von $($all.Count) Dateien gesammelt …" }
        $entry = $null
        try { $entry = Resolve-FileEntry $rel } catch { }
        if ($entry -and [string]$entry.CategorySetHash -eq $setHash) { continue }  # same set, not sent again
        $capture = $null
        if ($entry) { $capture = ConvertFrom-DbDate $entry.CaptureDate }
        if ($null -eq $capture) { $capture = (Get-CaptureDate -Path $f.FullName).Date }
        $images.Add(@{ Rel = $rel; Name = $f.Name; CaptureDate = $capture; InDefault = ($parts.Count -gt 2 -and $parts[1] -eq $defaultFolder) })
    }
}
finally { Complete-DbTransaction }

if ($images.Count -eq 0) {
    return (New-FunctionResult -Kind Message -Message 'Bilder kategorisieren: Es gibt keine neuen Bilder in Input, die kategorisiert werden müssen.')
}

$plan = New-Plan -Title 'Bilder kategorisieren (Claude)' -Group 'Images' -Script 'CategorizeImages' -Roots @('Input')
$plan.ShowThumbnails = $true
$plan.EditLabel = 'Schlagwort'
$plan.ChoiceLabel = 'Kategorie'
$plan.LogExtra['CategorySetHash'] = $setHash
$plan.Data.SetHash = $setHash
$plan.Data.MarkOnly = $markOnly
$plan.Data.Defs = $defByName
$plan.Data.MaxKeyword = $maxKeyword
$plan.Data.GetTarget = $getTarget
if (-not $claudeOk) { $plan.Notice = 'Claude ist nicht verfügbar. Nur Voreinschätzung nach Dateiname.' }

# Dropdown entries: all categories (with subfolders) plus "Sonstiges".
$choiceMap = [ordered]@{}
$choiceMap['Sonstiges'] = @{ Category = 'Default'; Subfolder = '' }
foreach ($d in $defs) {
    $choiceMap[[string]$d.label] = @{ Category = [string]$d.name; Subfolder = '' }
    if ($d.subfolderByYear -ne $true) {
        foreach ($s in @($d.subfolders)) {
            if ($s.folder) { $choiceMap["$($d.label) › $($s.folder)"] = @{ Category = [string]$d.name; Subfolder = [string]$s.folder } }
        }
    }
}
$plan.Data.ChoiceMap = $choiceMap
$choices = @($choiceMap.Keys)

# Category block of the prompt, built from the definition files (2.8 section 5 step 4).
$blocks = @()
foreach ($d in $defs) {
    $block = "Category `"$($d.name)`": $($d.definition)"
    if ($d.rename -ne $false -and $d.keywordRule) { $block += " Keyword: $($d.keywordRule)" }
    $subs = @($d.subfolders | Where-Object { $_.folder })
    if ($subs.Count -gt 0) { $block += ' Subfolders: ' + (($subs | ForEach-Object { "$($_.folder): $($_.description)" }) -join ', ') }
    $blocks += $block
}
$categoryText = $blocks -join "`n"

$reserved = New-PathSet
$k = 0
$claudeCount = [Math]::Min($images.Count, $maxCalls)
$remaining = 0
foreach ($img in $images) {
    $k++
    $hint = Get-NameHint $img.Name
    $hintText = ''
    if ($hint.Category) {
        $hintText = "$(Get-CategoryLabel $hint.Category) (Dateiname: " + (($hint.Words | ForEach-Object { "‚$_‘" }) -join ', ') + ')'
        Add-PlanPreStep -Plan $plan -Type 'PREASSESSMENT' -Old $img.Rel -Extra "Category=$($hint.Category); Words=$($hint.Words -join ',')"
    }
    elseif ($hint.Tie.Count -gt 0) {
        $hintText = 'Dateiname passt zu mehreren Kategorien: ' + (($hint.Tie | ForEach-Object { Get-CategoryLabel $_ }) -join ', ')
        Add-PlanPreStep -Plan $plan -Type 'PREASSESSMENT' -Old $img.Rel -Extra "Tie=$($hint.Tie -join ',')"
    }
    $img.Hint = $hint
    # Additional local hint for screenshots (2.8.3 section 5, proposal).
    $screenHint = ''
    $meta = Get-ImageMetadata -Path (ConvertTo-AbsPath $img.Rel)
    if ($meta.Readable -and -not $meta.CameraModel) {
        $sizes = @('1080x2400', '1080x2340', '1080x1920', '1170x2532', '1179x2556', '1284x2778', '1290x2796', '1125x2436', '750x1334', '1242x2688', '1440x3200', '1440x3088', '1920x1080', '2560x1440', '1366x768', '1536x864', '1280x720', '1440x900', '1680x1050', '1920x1200', '2560x1600', '3840x2160', '2048x1536', '1668x2388', '2732x2048')
        $s1 = "$($meta.Width)x$($meta.Height)"; $s2 = "$($meta.Height)x$($meta.Width)"
        if ($sizes -contains $s1 -or $sizes -contains $s2) { $screenHint = 'Bildgröße passt zu einem Bildschirm' }
    }

    $category = $null; $keyword = ''; $subfolder = ''; $confidence = $null; $reason = ''
    $source = 'None'
    if ($claudeOk -and $k -le $claudeCount -and -not $global:ST.ClaudeRun.Skipped) {
        Write-StatusText "Claude kategorisiert: $k von $claudeCount …"
        $copies = New-ClaudeImageCopies -RelPaths @($img.Rel)
        if ($copies.Count -gt 0) {
            $prompt = "Decide which one of the following categories this image belongs to.`n" +
            "The original file name is `"$($img.Name)`". Use it only as a hint; the image content decides.`n" +
            "$categoryText`n" +
            "If no category clearly fits, set category to null.`n" +
            "Answer only with JSON: {`"category`": one of the names above or null,`n" +
            "`"keyword`": keyword following the rule of the category, null if category is null,`n" +
            "`"subfolder`": one of the subfolders of the category or null,`n" +
            "`"confidence`": number from 0 to 1, `"reason`": short reason in German}"
            try {
                $answer = Invoke-ClaudeWithLimitWait -Prompt $prompt -Files @($copies) -ExpectJson -ProgressText "$($k - 1) von $claudeCount Dateien bearbeitet"
            }
            finally { Remove-ClaudeImageCopies $copies }
            if ($answer.Success) {
                $data = $answer.Data
                $source = 'Claude'
                $catName = $null
                if ($data.PSObject.Properties['category'] -and $data.category) { $catName = [string]$data.category }
                $valid = $true
                if ($catName -and -not $defByName.ContainsKey($catName.ToLowerInvariant())) { $valid = $false; $catName = $null }
                if ($catName) { $category = [string]$defByName[$catName.ToLowerInvariant()].name } else { $category = 'Default' }
                if ($data.PSObject.Properties['keyword'] -and $data.keyword) { $keyword = Remove-InvalidNameChars ([string]$data.keyword) -MaxLength $maxKeyword }
                if ($data.PSObject.Properties['subfolder'] -and $data.subfolder -and $category -ne 'Default') {
                    $d = $defByName[$category.ToLowerInvariant()]
                    $match = @($d.subfolders | Where-Object { [string]::Equals([string]$_.folder, [string]$data.subfolder, [System.StringComparison]::OrdinalIgnoreCase) })
                    if ($match.Count -gt 0) { $subfolder = [string]$match[0].folder }
                }
                $confidence = 0.0
                if ($data.PSObject.Properties['confidence']) { try { $confidence = [double]$data.confidence } catch { } }
                if ($data.PSObject.Properties['reason']) { $reason = [string]$data.reason }
                $result = 'OK'
                if (-not $valid) { $result = 'InvalidResponse' }
                Add-PlanPreStep -Plan $plan -Type 'API_CALL' -Old 'ClaudeEndpoint' -New $img.Rel `
                    -Extra "$result | $($answer.DurationMs) ms | Category=$category; Subfolder=$subfolder; Keyword=$keyword; Confidence=$confidence"
            }
            else {
                $kind = $answer.ErrorKind
                Add-PlanPreStep -Plan $plan -Type 'API_CALL' -Old 'ClaudeEndpoint' -New $img.Rel -Extra (Format-ApiCallExtra $answer $answer.Error)
                if ($kind -eq 'InvalidResponse') { $source = 'Claude'; $category = 'Default'; $confidence = 0.0; $reason = 'Ungültige Antwort von Claude' }
            }
        }
    }
    elseif ($claudeOk -and $k -gt $claudeCount) { $remaining++ }

    # Decide the row.
    $checked = $false
    $mismatch = $false
    $preOnly = $false
    if ($source -eq 'Claude') {
        $limit = $minDefault
        if ($category -ne 'Default') {
            $d = $defByName[$category.ToLowerInvariant()]
            if ($null -ne $d.minConfidence -and "$($d.minConfidence)" -ne '') { $limit = [double]$d.minConfidence }
        }
        $checked = ($confidence -ge $limit)
        if ($hint.Category -and $hint.Category -ne $category) { $mismatch = $true; $checked = $false }
        if ($category -ne 'Default' -and $defByName[$category.ToLowerInvariant()].rename -ne $false -and -not $keyword) { $checked = $false }
    }
    elseif ($hint.Category) {
        # Only the pre-assessment: proposed, unchecked, keyword empty (2.8 section 5a).
        $category = $hint.Category
        $preOnly = $true
        $checked = $false
    }
    else {
        continue   # no answer and no pre-assessment: stays as it is, asked again next time
    }
    if ($category -eq 'Default' -and $img.InDefault) {
        # Already in Input/Sonstiges and still Default: no change, but remembered for this set.
        if ($source -eq 'Claude') { $markOnly.Add($img.Rel) }
        continue
    }
    $target = & $plan.Data.GetTarget $plan $img $category $subfolder $keyword $reserved
    [void]$reserved.Add($target)
    $label = Get-CategoryLabel $category
    if ($subfolder) { $label = "$label › $subfolder" }
    $info = $label
    if ($source -eq 'Claude') { $info += " – $([int][Math]::Round($confidence * 100)) % – $reason" }
    if ($mismatch) { $info += " – Dateiname deutet auf $(Get-CategoryLabel $hint.Category) hin, Claude sagt $(Get-CategoryLabel $category)" }
    elseif ($hintText -and $source -eq 'Claude') { $info += " – bestätigt durch $hintText" }
    elseif ($preOnly) { $info += " – nur Voreinschätzung: $hintText" }
    if ($screenHint) { $info += " – $screenHint" }
    if ($category -ne 'Default' -and [string]$defByName[$category.ToLowerInvariant()].target -eq 'ToDelete') { $info += ' – Wird später zum Löschen aussortiert' }
    $weak = (-not $checked -and $source -eq 'Claude' -and -not $mismatch)
    $item = Add-PlanItem -Plan $plan -Action 'MoveFile' -Source $img.Rel -Target $target -Checked $checked -Weak $weak -Info $info `
        -Extra "Category=$category; Subfolder=$subfolder; Keyword=$keyword; Source=$source"
    $item.Thumbnail = $img.Rel
    $item.Choices = $choices
    $choiceLabel = Get-CategoryLabel $category
    if ($subfolder) { $choiceLabel = "$choiceLabel › $subfolder" }
    $item.Choice = $choiceLabel
    $item.Data.Image = $img
    $item.Data.Category = $category
    $item.Data.Subfolder = $subfolder
    $item.Data.Keyword = $keyword
    $item.Data.Mismatch = $mismatch
    $item.Data.PreOnly = $preOnly
    $item.Data.NameHint = $hintText
    $item.Data.FromClaude = ($source -eq 'Claude')
    if ($category -ne 'Default' -and $defByName[$category.ToLowerInvariant()].rename -ne $false) {
        $item.EditMode = 'Keyword'
        $item.EditValue = $keyword
    }
}
if ($remaining -gt 0) { Write-StatusText "Bilder kategorisieren: $remaining Bilder bleiben für einen nächsten Lauf (maxCallsPerRun)." }

$plan.OnItemEdited = {
    param($plan, $item)
    $map = $plan.Data.ChoiceMap
    $choice = [string]$item.Choice
    $newCat = $item.Data.Category
    $newSub = $item.Data.Subfolder
    if ($choice -and $map.Contains($choice)) { $newCat = $map[$choice].Category; $newSub = $map[$choice].Subfolder }
    $defs = $plan.Data.Defs
    $renames = ($newCat -ne 'Default' -and $defs[$newCat.ToLowerInvariant()].rename -ne $false)
    if ($newCat -ne $item.Data.Category) {
        # Changed to another category: the name field is empty and must be filled in (2.8 section 6).
        $item.Data.Keyword = ''
        $item.EditValue = ''
        if ($renames) { $item.Checked = $false }
    }
    else {
        $item.Data.Keyword = Remove-InvalidNameChars ([string]$item.EditValue) -MaxLength $plan.Data.MaxKeyword
        $item.EditValue = $item.Data.Keyword
        if ($renames -and $item.Data.Keyword) { $item.Checked = $true }
    }
    $item.Data.Category = $newCat
    $item.Data.Subfolder = $newSub
    if ($renames) { $item.EditMode = 'Keyword' } else { $item.EditMode = $null; $item.EditValue = '' }
    $reserved = Get-PlanReservedTargets -Plan $plan -Except $item
    $item.Target = & $plan.Data.GetTarget $plan $item.Data.Image $newCat $newSub $item.Data.Keyword $reserved
    $item.Extra = "Category=$newCat; Subfolder=$newSub; Keyword=$($item.Data.Keyword); Source=edited"
    $item.Weak = $false
}
$plan.Filters = @(
    @{ Label = 'Nur Abweichungen'; Test = { param($i) [bool]$i.Data.Mismatch } },
    @{ Label = 'Nur Voreinschätzung'; Test = { param($i) [bool]$i.Data.PreOnly } }
)
$plan.SummaryExtra = {
    param($plan)
    $groups = @{}
    foreach ($i in $plan.Items) {
        if ($i.Action -ne 'MoveFile') { continue }
        $c = [string]$i.Choice
        if ($c.Contains(' › ')) { $c = $c.Substring(0, $c.IndexOf(' › ')) }
        if ($groups.ContainsKey($c)) { $groups[$c]++ } else { $groups[$c] = 1 }
    }
    (($groups.Keys | Sort-Object | ForEach-Object { "$_ ($($groups[$_]))" }) -join '   ')
}
$plan.OnExecuted = {
    param($plan, $log)
    # Remember category, keyword and the set of definitions for moved images (2.8 section 10).
    $moved = @{}
    foreach ($s in $log.Steps) { if ($s.Type -eq 'MOVED') { $moved[$s.Old.ToLowerInvariant()] = $s.New } }
    foreach ($i in $plan.Items) {
        if ($i.Action -ne 'MoveFile') { continue }
        $key = $i.Source.ToLowerInvariant()
        $fields = @{ NameHint = [string]$i.Data.NameHint }
        $path = $i.Source
        if ($moved.ContainsKey($key)) {
            $path = $moved[$key]
            $fields.Category = [string]$i.Data.Category
            $fields.Keyword = [string]$i.Data.Keyword
            $fields.CategorySetHash = $plan.Data.SetHash
        }
        try { Update-FileEntryFields -RelPath $path -Fields $fields } catch { }
    }
    foreach ($p in $plan.Data.MarkOnly) {
        try { Update-FileEntryFields -RelPath $p -Fields @{ Category = 'Default'; CategorySetHash = $plan.Data.SetHash } } catch { }
    }
}
if ($plan.Items.Count -eq 0 -and $markOnly.Count -gt 0) {
    $log = New-ActionLog -Group 'Images' -Script 'CategorizeImages'
    & $plan.OnExecuted $plan $log
    return (New-FunctionResult -Kind Message -Message 'Bilder kategorisieren: Keine Änderungen nötig.')
}
return $plan
