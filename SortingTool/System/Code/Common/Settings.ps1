# Settings.ps1
# Reading and writing of the JSON files in System/Config (base section 6):
# layout.json (groups and buttons), settings.json (settings), Categories/*.json (2.8).

function Read-JsonFile {
    param([Parameter(Mandatory)][string]$Path)
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    return ($text | ConvertFrom-Json)
}

function Write-JsonFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Object)
    $json = $Object | ConvertTo-Json -Depth 20
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json, $utf8)
}

function Get-DefaultSettings {
    # Defaults from the specifications. Used for keys missing in settings.json.
    $json = @'
{
  "similarityThreshold": 5,
  "thumbnailSize": 128,
  "explorerViewInput": "List",
  "explorerViewResult": "Folder",
  "imageExtensions": [ ".jpg", ".jpeg", ".png", ".gif", ".bmp", ".heic", ".heif", ".webp", ".tif", ".tiff", ".cr2", ".cr3", ".nef", ".arw", ".orf", ".rw2", ".dng" ],
  "videoExtensions": [ ".mp4", ".mov", ".m4v", ".avi", ".mkv", ".3gp", ".mts", ".m2ts", ".wmv" ],
  "minImagesPerDay": 5,
  "resultTargetDepth": 2,
  "places": { "maxLookupsPerFolder": 10, "secondPlaceShare": 0.3, "maxImagesPerFolder": 5, "minConfidence": 0.6 },
  "categories": { "maxImageEdge": 1568, "minCategoryConfidence": 0.7, "maxKeywordLength": 80, "genericNamePatterns": [] },
  "api": {
    "claude": { "enabled": true, "executable": "claude", "model": "", "timeoutSeconds": 120, "maxCallsPerRun": 100, "workingFolder": "System/Temp/Claude", "limitRetryMinutes": 15 },
    "nominatim": { "enabled": true, "baseUrl": "https://nominatim.openstreetmap.org", "zoom": 10, "language": "de", "coordinatePrecision": 3, "minSecondsBetweenRequests": 1.1, "maxRequestsPerRun": 200, "timeoutSeconds": 20 }
  }
}
'@
    return ($json | ConvertFrom-Json)
}

function Merge-Defaults {
    # Adds every property of $Default that is missing in $Target (recursively).
    param($Target, $Default)
    foreach ($prop in $Default.PSObject.Properties) {
        $existing = $Target.PSObject.Properties[$prop.Name]
        if ($null -eq $existing) {
            $Target | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value
        }
        elseif ($prop.Value -is [System.Management.Automation.PSCustomObject] -and
            $existing.Value -is [System.Management.Automation.PSCustomObject]) {
            Merge-Defaults -Target $existing.Value -Default $prop.Value
        }
    }
}

function Import-ToolSettings {
    $path = Join-Path $global:ST.Config 'settings.json'
    $defaults = Get-DefaultSettings
    if (Test-Path -LiteralPath $path) {
        $settings = Read-JsonFile $path
        Merge-Defaults -Target $settings -Default $defaults
    }
    else {
        $settings = $defaults
    }
    # Extensions are compared in lower case.
    $settings.imageExtensions = @($settings.imageExtensions | ForEach-Object { $_.ToLowerInvariant() })
    $settings.videoExtensions = @($settings.videoExtensions | ForEach-Object { $_.ToLowerInvariant() })
    # The policy of Nominatim requires at least one second between requests (3.2 section 7).
    if ([double]$settings.api.nominatim.minSecondsBetweenRequests -lt 1) { $settings.api.nominatim.minSecondsBetweenRequests = 1 }
    $global:ST.Settings = $settings
    return $settings
}

function Save-ToolSetting {
    # Changes one top-level key in settings.json and writes the file (used for explorer views).
    param([Parameter(Mandatory)][string]$Key, $Value)
    $path = Join-Path $global:ST.Config 'settings.json'
    try {
        $onDisk = Read-JsonFile $path
        if ($onDisk.PSObject.Properties[$Key]) { $onDisk.$Key = $Value }
        else { $onDisk | Add-Member -NotePropertyName $Key -NotePropertyValue $Value }
        Write-JsonFile -Path $path -Object $onDisk
        $global:ST.Settings.$Key = $Value
    }
    catch {
        Write-StatusText "Einstellung konnte nicht gespeichert werden: $($_.Exception.Message)"
    }
}

function Import-ToolLayout {
    $path = Join-Path $global:ST.Config 'layout.json'
    $layout = Read-JsonFile $path
    $global:ST.Layout = $layout
    return $layout
}

function Get-CategoryDefinitions {
    # All enabled category definitions of 2.8 (System/Config/Categories/*.json), sorted by name.
    # Each definition gets the defaults of 2.8 section 3 for missing optional keys.
    param([switch]$IncludeDisabled)
    $folder = Join-Path $global:ST.Config 'Categories'
    $list = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $folder)) { return , $list }
    foreach ($file in (Get-ChildItem -LiteralPath $folder -Filter '*.json' | Sort-Object Name)) {
        try {
            $def = Read-JsonFile $file.FullName
        }
        catch {
            Write-StatusText "Kategoriedatei $($file.Name) ist fehlerhaft und wird ignoriert."
            continue
        }
        $defaults = @{ target = 'Result'; rename = $true; enabled = $true; subfolderByYear = $false; keywordPrefix = ''
            namePatterns = @(); subfolders = @(); keywordRule = ''; minConfidence = $null; label = $def.name; folder = $def.name }
        foreach ($k in $defaults.Keys) {
            if ($null -eq $def.PSObject.Properties[$k]) { $def | Add-Member -NotePropertyName $k -NotePropertyValue $defaults[$k] }
        }
        $def | Add-Member -NotePropertyName 'FilePath' -NotePropertyValue $file.FullName -Force
        $def | Add-Member -NotePropertyName 'FileText' -NotePropertyValue ([System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)) -Force
        if ($IncludeDisabled -or $def.enabled -ne $false) { $list.Add($def) }
    }
    return , $list
}

function Get-CategorySetHash {
    # Hash over all enabled definition files (2.8 section 10, column CategorySetHash).
    param($Definitions)
    $text = (($Definitions | Sort-Object name | ForEach-Object { $_.FileText.Trim() }) -join "`n---`n")
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text))
        return ([System.BitConverter]::ToString($bytes).Replace('-', '').Substring(0, 16))
    }
    finally { $sha.Dispose() }
}
