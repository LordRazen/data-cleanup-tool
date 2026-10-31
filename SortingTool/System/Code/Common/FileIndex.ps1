# FileIndex.ps1
# Computing the database row of a file: hashes (base section 10), capture date and GPS (2.1 section 4).
# Used by InitializeFolder and by every move of a file that has no entry yet (base section 10).

function Format-DbDate {
    param($Date)
    if ($null -eq $Date) { return $null }
    return ([datetime]$Date).ToString('yyyy-MM-ddTHH:mm:ss')
}

function ConvertFrom-DbDate {
    param($Text)
    if ([string]::IsNullOrWhiteSpace([string]$Text)) { return $null }
    $d = [datetime]::MinValue
    if ([datetime]::TryParseExact([string]$Text, 'yyyy-MM-ddTHH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None, [ref]$d)) { return $d }
    if ([datetime]::TryParse([string]$Text, [ref]$d)) { return $d }
    return $null
}

function New-FileEntryData {
    # Computes all columns of a file. Returns a hashtable ready for Set-FileEntry.
    param([Parameter(Mandatory)][string]$RelPath)
    $abs = ConvertTo-AbsPath $RelPath
    $info = New-Object System.IO.FileInfo $abs
    $meta = $null
    if ((Get-ExtensionKind $info.Name) -eq 'Image') { $meta = Get-ImageMetadata -Path $abs -WithHash }
    $capture = Get-CaptureDate -Path $abs -Metadata $meta
    $entry = @{
        Path              = $RelPath
        Hash              = (Get-FileSha256 $abs)
        SimilarityHash    = $null
        Size              = [long]$info.Length
        Modified          = Format-DbDate $info.LastWriteTime
        LastChecked       = Get-NowText
        DuplicateChecked  = $null
        CaptureDate       = Format-DbDate $capture.Date
        CaptureDateSource = $capture.Source
        Latitude          = $null
        Longitude         = $null
        Category          = $null
        Keyword           = $null
        NameHint          = $null
        CategorySetHash   = $null
    }
    if ($null -ne $meta) {
        $entry.SimilarityHash = $meta.DHash
        $entry.Latitude = $meta.Latitude
        $entry.Longitude = $meta.Longitude
    }
    return $entry
}

function Test-EntryUpToDate {
    # Same size and modification date -> nothing has to be computed (base section 10, step 1).
    param([Parameter(Mandatory)]$Entry, [Parameter(Mandatory)][System.IO.FileInfo]$Info)
    return ([long]$Entry.Size -eq [long]$Info.Length -and [string]$Entry.Modified -eq (Format-DbDate $Info.LastWriteTime))
}

function Resolve-FileEntry {
    # Returns the entry of a file and creates it on the fly if it is missing or outdated.
    param([Parameter(Mandatory)][string]$RelPath)
    $abs = ConvertTo-AbsPath $RelPath
    if (-not [System.IO.File]::Exists($abs)) { return $null }
    $entry = Get-FileEntry $RelPath
    $info = New-Object System.IO.FileInfo $abs
    if ($null -ne $entry -and (Test-EntryUpToDate -Entry $entry -Info $info)) { return $entry }
    $data = New-FileEntryData -RelPath $RelPath
    Set-FileEntry $data
    return (Get-FileEntry $RelPath)
}
