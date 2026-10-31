# DeterminePlaceByGps.ps1 (2.6)
# Determines the place of every day folder "YYYY-MM-DD" directly in Input from the GPS data of
# its photos and videos (OpenStreetMap Nominatim, 3.2) and adds it to the folder name:
# "2024-07-13" -> "2024-07-13 - Tokio". Renames only folders, never files. Folders that already
# have a place are skipped. Only rounded coordinates are sent, never images or file names.

param($Context, [hashtable]$Arguments = @{})

$places = $global:ST.Settings.places
$maxLookups = [Math]::Max(1, [int]$places.maxLookupsPerFolder)
$secondShare = [double]$places.secondPlaceShare

$groups = Get-InputFolderGroups
if ($groups.Other.Count -gt 0) {
    $answer = Show-ChoiceDialog -Text 'Die folgenden Ordner in Input haben kein Datumsformat und werden ignoriert:' -Lines $groups.Other -Buttons @('Weiter', 'Abbrechen') -Title 'Ort bestimmen (OpenStreetMap)'
    if ($answer -ne 'Weiter') { return (New-FunctionResult -Kind Cancelled) }
}
if ($groups.Day.Count -eq 0) {
    return (New-FunctionResult -Kind Message -Message 'Ort bestimmen: In Input gibt es keine Tagesordner ohne Ort (Format JJJJ-MM-TT).')
}
$check = Test-NominatimEndpoint
if (-not $check.Available) { return (New-FunctionResult -Kind Failed -Message $check.Message) }
Reset-NominatimRun

$plan = New-Plan -Title 'Ort bestimmen (OpenStreetMap)' -Group 'Images' -Script 'DeterminePlaceByGps' -Roots @('Input')
$plan.Notice = '© OpenStreetMap-Mitwirkende'
$plan.EditLabel = 'Ort (bearbeitbar)'
$plan.LogExtra['Source'] = 'OpenStreetMap Nominatim, © OpenStreetMap contributors'
$reserved = New-PathSet
$stopped = $null
$precision = [int]$global:ST.Settings.api.nominatim.coordinatePrecision
$folderNo = 0

foreach ($day in $groups.Day) {
    $folderNo++
    $folder = "Input/$day"
    Write-StatusText "Ort bestimmen: Ordner $folderNo von $($groups.Day.Count) ($day) …"
    if ($stopped) {
        [void](Add-PlanItem -Plan $plan -Action 'Info' -Source $folder -Info 'Ort konnte nicht bestimmt werden')
        continue
    }
    # GPS per file from the database (filled by InitializeFolder; missing entries are created).
    $files = Get-FilesRecursive (ConvertTo-AbsPath $folder)
    $media = @($files | Where-Object { (Get-ExtensionKind $_.Name) -ne 'Other' })
    $gps = New-Object System.Collections.Generic.List[object]
    Start-DbTransaction
    try {
        foreach ($f in $media) {
            $rel = ConvertTo-RelPath $f.FullName
            $entry = $null
            try { $entry = Resolve-FileEntry $rel } catch { }
            if ($entry -and $null -ne $entry.Latitude -and $null -ne $entry.Longitude -and "$($entry.Latitude)" -ne '') {
                $gps.Add(@{
                        Lat  = [Math]::Round([double]$entry.Latitude, $precision)
                        Lon  = [Math]::Round([double]$entry.Longitude, $precision)
                        Date = [string]$entry.CaptureDate
                    })
            }
        }
    }
    finally { Complete-DbTransaction }
    if ($gps.Count -eq 0) {
        [void](Add-PlanItem -Plan $plan -Action 'Info' -Source $folder -Info 'kein GPS – wird übersprungen')
        continue
    }
    # Distinct coordinates, at most maxLookupsPerFolder, spread evenly over the day (2.6 section 4).
    $ordered = @($gps | Sort-Object { $_.Date })
    $distinct = New-Object System.Collections.Generic.List[object]
    $seen = New-PathSet
    foreach ($g in $ordered) {
        $key = "$($g.Lat)|$($g.Lon)"
        if ($seen.Add($key)) { $distinct.Add($g) }
    }
    $chosen = New-Object System.Collections.Generic.List[object]
    if ($distinct.Count -le $maxLookups) { foreach ($d in $distinct) { $chosen.Add($d) } }
    else {
        for ($k = 0; $k -lt $maxLookups; $k++) {
            $idx = [int][Math]::Floor($k * ($distinct.Count - 1) / [double]($maxLookups - 1))
            if ($maxLookups -eq 1) { $idx = [int]($distinct.Count / 2) }
            $chosen.Add($distinct[$idx])
        }
    }
    $lookups = New-Object System.Collections.Generic.List[object]
    foreach ($c in $chosen) {
        $answer = Invoke-NominatimEndpoint -Latitude $c.Lat -Longitude $c.Lon
        $summary = ''
        if ($answer.Success) {
            $summary = "Place=$($answer.Data.Place); Country=$($answer.Data.Country)"
            if ($answer.Data.FromCache) { $summary += '; cache' }
        }
        else { $summary = $answer.Error }
        Add-PlanPreStep -Plan $plan -Type 'API_CALL' -Old 'NominatimEndpoint' -New "$day ($($c.Lat), $($c.Lon))" -Extra (Format-ApiCallExtra $answer $summary)
        if ($answer.Success) {
            if ($answer.Data.Place) { $lookups.Add(@{ Lat = $c.Lat; Lon = $c.Lon; Place = $answer.Data.Place }) }
        }
        elseif ($answer.ErrorKind -in @('Offline', 'LimitReached', 'Timeout')) {
            $stopped = $answer.ErrorKind
            break
        }
    }
    if ($lookups.Count -eq 0) {
        $text = 'Ort konnte nicht bestimmt werden'
        [void](Add-PlanItem -Plan $plan -Action 'Info' -Source $folder -Info $text)
        continue
    }
    # Each file belongs to the place of the nearest looked-up coordinate.
    $counts = @{}
    foreach ($g in $gps) {
        $best = $null; $bestDist = [double]::MaxValue
        foreach ($l in $lookups) {
            $dist = [Math]::Pow($g.Lat - $l.Lat, 2) + [Math]::Pow($g.Lon - $l.Lon, 2)
            if ($dist -lt $bestDist) { $bestDist = $dist; $best = $l }
        }
        if ($counts.ContainsKey($best.Place)) { $counts[$best.Place]++ } else { $counts[$best.Place] = 1 }
    }
    $rank = @($counts.GetEnumerator() | Sort-Object Value -Descending)
    $place = [string]$rank[0].Key
    $mainCount = [int]$rank[0].Value
    if ($rank.Count -gt 1 -and ([int]$rank[1].Value / [double]$gps.Count) -ge $secondShare) {
        $place = "$place, $($rank[1].Key)"
    }
    $place = Remove-InvalidNameChars $place
    $item = Add-PlanItem -Plan $plan -Action 'MoveFolder' -Source $folder -Target $folder `
        -Info "$place ($mainCount von $($gps.Count) Dateien mit GPS, $($media.Count) Dateien insgesamt)" -Extra "Place=$place; FilesWithGps=$($gps.Count); Files=$($media.Count); Source=OpenStreetMap"
    $item.EditMode = 'Suffix'
    $item.EditPrefix = "$day - "
    $item.EditValue = $place
    $item.Data.DefaultSuffix = $place
    Set-SuffixRenameTarget -Plan $plan -Item $item
    [void]$reserved.Add($item.Target)
}

if ($stopped -eq 'Offline') { Show-ErrorMessage 'Keine Internetverbindung. Der Ort kann gerade nicht bestimmt werden.' }
elseif ($stopped -eq 'LimitReached') { Show-ErrorMessage 'OpenStreetMap hat die Anfragen vorübergehend gesperrt. Bitte später erneut versuchen.' }
elseif ($stopped -eq 'Timeout') { Show-ErrorMessage 'OpenStreetMap antwortet nicht. Die übrigen Ordner bleiben unverändert.' }

$plan.OnItemEdited = {
    param($plan, $item)
    Set-SuffixRenameTarget -Plan $plan -Item $item
}
return $plan
