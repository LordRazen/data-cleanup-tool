# ImageInfo.ps1
# Reading image metadata (EXIF dates, GPS), capture date (2.1 section 4), similarity hash (dHash,
# base section 10), thumbnails (base section 11) and smaller copies for Claude (2.8 section 5).
# Uses only System.Drawing and the Windows Shell, both part of Windows.

function Open-ImageFile {
    # Opens an image without locking the file for long. Returns $null if it cannot be read.
    param([Parameter(Mandatory)][string]$Path)
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $ms = New-Object System.IO.MemoryStream(, $bytes)
        return [System.Drawing.Image]::FromStream($ms, $false, $false)
    }
    catch { return $null }
}

function Get-ExifText {
    param($Image, [int]$Id)
    try {
        if ($Image.PropertyIdList -notcontains $Id) { return $null }
        $item = $Image.GetPropertyItem($Id)
        return ([System.Text.Encoding]::ASCII.GetString($item.Value)).Trim([char]0, ' ')
    }
    catch { return $null }
}

function ConvertFrom-ExifDate {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $d = [datetime]::MinValue
    $formats = [string[]]@('yyyy:MM:dd HH:mm:ss', 'yyyy-MM-dd HH:mm:ss', 'yyyy:MM:dd HH:mm', 'yyyy:MM:dd')
    if ([datetime]::TryParseExact($Text.Substring(0, [Math]::Min(19, $Text.Length)), $formats,
            [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$d)) {
        return $d
    }
    return $null
}

function Get-ExifGpsCoordinate {
    # Returns decimal degrees or $null. $ValueId: 0x0002 / 0x0004, $RefId: 0x0001 / 0x0003.
    param($Image, [int]$ValueId, [int]$RefId)
    try {
        if ($Image.PropertyIdList -notcontains $ValueId) { return $null }
        $v = $Image.GetPropertyItem($ValueId).Value
        if ($v.Length -lt 24) { return $null }
        $parts = @()
        for ($i = 0; $i -lt 3; $i++) {
            $num = [System.BitConverter]::ToUInt32($v, $i * 8)
            $den = [System.BitConverter]::ToUInt32($v, $i * 8 + 4)
            if ($den -eq 0) { $parts += 0.0 } else { $parts += ([double]$num / [double]$den) }
        }
        $value = $parts[0] + $parts[1] / 60.0 + $parts[2] / 3600.0
        $ref = Get-ExifText -Image $Image -Id $RefId
        if ($ref -eq 'S' -or $ref -eq 'W') { $value = - $value }
        if ($value -eq 0) { return $null }
        return [Math]::Round($value, 7)
    }
    catch { return $null }
}

function Get-DHash {
    # 64-bit difference hash: image scaled to 9x8 grey pixels, each bit = left pixel brighter than right.
    param([Parameter(Mandatory)]$Image)
    $bmp = New-Object System.Drawing.Bitmap 9, 8
    try {
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBilinear
        $g.DrawImage($Image, 0, 0, 9, 8)
        $g.Dispose()
        [UInt64]$hash = 0
        for ($y = 0; $y -lt 8; $y++) {
            for ($x = 0; $x -lt 8; $x++) {
                $a = $bmp.GetPixel($x, $y)
                $b = $bmp.GetPixel($x + 1, $y)
                $la = 0.299 * $a.R + 0.587 * $a.G + 0.114 * $a.B
                $lb = 0.299 * $b.R + 0.587 * $b.G + 0.114 * $b.B
                $hash = [UInt64]($hash -shl 1)
                if ($la -gt $lb) { $hash = [UInt64]($hash -bor [UInt64]1) }
            }
        }
        return $hash.ToString('x16')
    }
    finally { $bmp.Dispose() }
}

function Get-ImageMetadata {
    # EXIF dates, GPS, size, camera model and dHash of an image. Fields are $null if not available.
    param([Parameter(Mandatory)][string]$Path, [switch]$WithHash)
    $result = @{ ExifOriginal = $null; ExifDigitized = $null; Latitude = $null; Longitude = $null
        DHash = $null; Width = $null; Height = $null; CameraModel = $null; Readable = $false }
    $img = Open-ImageFile $Path
    if ($null -eq $img) { return $result }
    try {
        $result.Readable = $true
        $result.Width = $img.Width
        $result.Height = $img.Height
        $result.ExifOriginal = ConvertFrom-ExifDate (Get-ExifText -Image $img -Id 0x9003)
        $result.ExifDigitized = ConvertFrom-ExifDate (Get-ExifText -Image $img -Id 0x9004)
        $result.CameraModel = Get-ExifText -Image $img -Id 0x0110
        $lat = Get-ExifGpsCoordinate -Image $img -ValueId 0x0002 -RefId 0x0001
        $lon = Get-ExifGpsCoordinate -Image $img -ValueId 0x0004 -RefId 0x0003
        if ($null -ne $lat -and $null -ne $lon) { $result.Latitude = $lat; $result.Longitude = $lon }
        if ($WithHash) {
            try { $result.DHash = Get-DHash -Image $img } catch { }
        }
    }
    finally { $img.Dispose() }
    return $result
}

function Test-PlausibleDate {
    # Values before 1990 or in the future are invalid (camera clock not set, 2.1 section 4).
    param($Date)
    if ($null -eq $Date) { return $false }
    return ($Date -ge [datetime]'1990-01-01' -and $Date -le (Get-Date).AddDays(1))
}

function Get-ShellDate {
    # Windows property "Date taken" or "Media created" (source 3 of 2.1 section 4).
    param([Parameter(Mandatory)][string]$Path)
    try {
        if (-not $global:ST.Shell) { $global:ST.Shell = New-Object -ComObject Shell.Application }
        $folder = $global:ST.Shell.Namespace([System.IO.Path]::GetDirectoryName($Path))
        if ($null -eq $folder) { return $null }
        $item = $folder.ParseName([System.IO.Path]::GetFileName($Path))
        if ($null -eq $item) { return $null }
        foreach ($prop in @('System.Photo.DateTaken', 'System.Media.DateEncoded')) {
            $v = $item.ExtendedProperty($prop)
            if ($v -is [datetime]) {
                # The shell delivers these values in UTC.
                $local = [datetime]::SpecifyKind($v, [System.DateTimeKind]::Utc).ToLocalTime()
                if (Test-PlausibleDate $local) { return $local }
            }
        }
    }
    catch { }
    return $null
}

function Get-DateFromFileName {
    # Date (and time if present) in names like IMG_20240713_183012.jpg, PXL_20240713_183012345.jpg,
    # IMG-20240713-WA0001.jpg, Screenshot_2024-07-13-10-11-12.png (source 4 of 2.1 section 4).
    param([Parameter(Mandatory)][string]$Name)
    $base = [System.IO.Path]::GetFileNameWithoutExtension($Name)
    $patterns = @(
        '(?<!\d)(?<y>(19|20)\d{2})(?<m>\d{2})(?<d>\d{2})[_\-T ]?(?<H>\d{2})(?<M>\d{2})(?<S>\d{2})\d{0,3}(?!\d)',
        '(?<!\d)(?<y>(19|20)\d{2})-(?<m>\d{2})-(?<d>\d{2})[ _\-]+(um |at )?(?<H>\d{2})[.\-_:]?(?<M>\d{2})[.\-_:]?(?<S>\d{2})(?!\d)',
        '(?<!\d)(?<y>(19|20)\d{2})[\-_.]?(?<m>\d{2})[\-_.]?(?<d>\d{2})(?!\d)'
    )
    foreach ($p in $patterns) {
        foreach ($m in [regex]::Matches($base, $p)) {
            try {
                $h = 0; $mi = 0; $s = 0
                if ($m.Groups['H'].Success) { $h = [int]$m.Groups['H'].Value; $mi = [int]$m.Groups['M'].Value; $s = [int]$m.Groups['S'].Value }
                if ($h -gt 23 -or $mi -gt 59 -or $s -gt 59) { $h = 0; $mi = 0; $s = 0 }
                $d = New-Object DateTime ([int]$m.Groups['y'].Value), ([int]$m.Groups['m'].Value), ([int]$m.Groups['d'].Value), $h, $mi, $s
                if (Test-PlausibleDate $d) { return $d }
            }
            catch { }
        }
    }
    return $null
}

function Get-CaptureDate {
    # Capture date by the order of 2.1 section 4. Returns @{ Date; Source }.
    # $Metadata: optional result of Get-ImageMetadata (avoids opening the image twice).
    param([Parameter(Mandatory)][string]$Path, $Metadata = $null)
    $kind = Get-ExtensionKind $Path
    if ($null -eq $Metadata -and $kind -eq 'Image') { $Metadata = Get-ImageMetadata -Path $Path }
    if ($null -ne $Metadata) {
        if (Test-PlausibleDate $Metadata.ExifOriginal) { return @{ Date = $Metadata.ExifOriginal; Source = 'ExifOriginal' } }
        if (Test-PlausibleDate $Metadata.ExifDigitized) { return @{ Date = $Metadata.ExifDigitized; Source = 'ExifDigitized' } }
    }
    if ($kind -ne 'Other') {
        $shellDate = Get-ShellDate $Path
        if ($null -ne $shellDate) { return @{ Date = $shellDate; Source = 'WindowsProperty' } }
    }
    $nameDate = Get-DateFromFileName ([System.IO.Path]::GetFileName($Path))
    if ($null -ne $nameDate) { return @{ Date = $nameDate; Source = 'FileName' } }
    $info = New-Object System.IO.FileInfo $Path
    $date = $info.LastWriteTime
    if ($info.CreationTime -lt $date) { $date = $info.CreationTime }
    return @{ Date = $date; Source = 'FileSystem' }
}

function Get-CaptureSourceLabel {
    # German label of a capture date source for the preview (2.3 section 6).
    param([string]$Source)
    switch ($Source) {
        'ExifOriginal' { return 'EXIF' }
        'ExifDigitized' { return 'EXIF' }
        'WindowsProperty' { return 'Windows' }
        'FileName' { return 'Dateiname' }
        'FileSystem' { return 'Dateidatum' }
        default { return 'unbekannt' }
    }
}

function New-ThumbnailBitmap {
    # Square thumbnail, image centered on a white background. Returns $null if the image cannot be read.
    param([Parameter(Mandatory)][string]$Path, [int]$Size = 128)
    $img = Open-ImageFile $Path
    if ($null -eq $img) { return $null }
    try {
        $scale = [Math]::Min($Size / [double]$img.Width, $Size / [double]$img.Height)
        if ($scale -gt 1) { $scale = 1 }
        $w = [Math]::Max(1, [int]($img.Width * $scale))
        $h = [Math]::Max(1, [int]($img.Height * $scale))
        $bmp = New-Object System.Drawing.Bitmap $Size, $Size
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.Clear([System.Drawing.Color]::White)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.DrawImage($img, [int](($Size - $w) / 2), [int](($Size - $h) / 2), $w, $h)
        $g.Dispose()
        return $bmp
    }
    catch { return $null }
    finally { $img.Dispose() }
}

function Save-ResizedImageCopy {
    # Writes a JPEG copy with at most $MaxEdge pixels on the long side and without metadata
    # (2.8 section 5 step 3). The EXIF orientation is applied, so the copy is upright.
    # Returns $true on success. The original is never changed.
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Destination, [int]$MaxEdge = 1568)
    $img = Open-ImageFile $Source
    if ($null -eq $img) { return $false }
    try {
        $scale = [Math]::Min(1.0, $MaxEdge / [double]([Math]::Max($img.Width, $img.Height)))
        $w = [Math]::Max(1, [int]($img.Width * $scale))
        $h = [Math]::Max(1, [int]($img.Height * $scale))
        $bmp = New-Object System.Drawing.Bitmap $w, $h
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.Clear([System.Drawing.Color]::White)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.DrawImage($img, 0, 0, $w, $h)
        $g.Dispose()
        try {
            if ($img.PropertyIdList -contains 0x0112) {
                $o = [System.BitConverter]::ToUInt16($img.GetPropertyItem(0x0112).Value, 0)
                switch ($o) {
                    3 { $bmp.RotateFlip([System.Drawing.RotateFlipType]::Rotate180FlipNone) }
                    6 { $bmp.RotateFlip([System.Drawing.RotateFlipType]::Rotate90FlipNone) }
                    8 { $bmp.RotateFlip([System.Drawing.RotateFlipType]::Rotate270FlipNone) }
                }
            }
        }
        catch { }
        $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' } | Select-Object -First 1
        $params = New-Object System.Drawing.Imaging.EncoderParameters 1
        $params.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter ([System.Drawing.Imaging.Encoder]::Quality), ([long]88)
        $bmp.Save($Destination, $codec, $params)
        $bmp.Dispose()
        return $true
    }
    catch { return $false }
    finally { $img.Dispose() }
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try {
        $bytes = $sha.ComputeHash($fs)
        return ([System.BitConverter]::ToString($bytes).Replace('-', ''))
    }
    finally { $fs.Dispose(); $sha.Dispose() }
}
