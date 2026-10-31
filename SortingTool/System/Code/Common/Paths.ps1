# Paths.ps1
# Folder layout of the tool and helpers for relative paths.
# Relative paths always start at the main folder of the tool and use "/" as separator,
# e.g. "Result/Images/Holiday/IMG_0412.jpg" (base section 10). Comparisons ignore case,
# like Windows does.

if (-not $global:ST) { $global:ST = @{} }

function Initialize-ToolPaths {
    param([Parameter(Mandatory)][string]$CodeFolder)
    $system = Split-Path -Parent $CodeFolder
    $root = Split-Path -Parent $system
    $global:ST.Version = '1.0.0'
    $global:ST.Root = $root
    $global:ST.System = $system
    $global:ST.Code = $CodeFolder
    $global:ST.Input = Join-Path $root 'Input'
    $global:ST.Result = Join-Path $root 'Result'
    $global:ST.ToDelete = Join-Path $root 'ToDelete'
    $global:ST.Config = Join-Path $system 'Config'
    $global:ST.Logs = Join-Path $system 'Logs'
    $global:ST.DatabaseFolder = Join-Path $system 'Database'
    $global:ST.DbPath = Join-Path $global:ST.DatabaseFolder 'index.db'
    $global:ST.Lib = Join-Path $system 'Lib'
    $global:ST.Temp = Join-Path $system 'Temp'
    foreach ($folder in @($global:ST.Input, $global:ST.Result, $global:ST.ToDelete, $global:ST.Logs,
            $global:ST.DatabaseFolder, $global:ST.Temp)) {
        if (-not (Test-Path -LiteralPath $folder)) {
            [void][System.IO.Directory]::CreateDirectory($folder)
        }
    }
}

function ConvertTo-RelPath {
    # Absolute path -> relative path with "/".
    param([Parameter(Mandatory)][string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $root = $global:ST.Root.TrimEnd('\')
    if ($full.Length -lt $root.Length -or
        -not $full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside the tool folder: $Path"
    }
    $rel = $full.Substring($root.Length).TrimStart('\')
    return $rel.Replace('\', '/')
}

function ConvertTo-AbsPath {
    # Relative path with "/" -> absolute Windows path.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$RelPath)
    if ([string]::IsNullOrEmpty($RelPath)) { return $global:ST.Root }
    return Join-Path $global:ST.Root ($RelPath.Replace('/', '\'))
}

function Get-RelParent {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$RelPath)
    $i = $RelPath.LastIndexOf('/')
    if ($i -lt 0) { return '' }
    return $RelPath.Substring(0, $i)
}

function Get-RelName {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$RelPath)
    $i = $RelPath.LastIndexOf('/')
    if ($i -lt 0) { return $RelPath }
    return $RelPath.Substring($i + 1)
}

function Join-RelPath {
    param([AllowEmptyString()][string]$Parent, [AllowEmptyString()][string]$Child)
    if ([string]::IsNullOrEmpty($Parent)) { return $Child }
    if ([string]::IsNullOrEmpty($Child)) { return $Parent }
    return ($Parent.TrimEnd('/') + '/' + $Child.TrimStart('/'))
}

function Test-RelEqual {
    param([AllowEmptyString()][string]$A, [AllowEmptyString()][string]$B)
    return [string]::Equals($A, $B, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-RelUnder {
    # True if $RelPath lies below $Folder (not equal to it).
    param([AllowEmptyString()][string]$RelPath, [AllowEmptyString()][string]$Folder)
    if ([string]::IsNullOrEmpty($Folder)) { return -not [string]::IsNullOrEmpty($RelPath) }
    return $RelPath.StartsWith($Folder.TrimEnd('/') + '/', [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-RelUnderOrEqual {
    param([AllowEmptyString()][string]$RelPath, [AllowEmptyString()][string]$Folder)
    return (Test-RelEqual $RelPath $Folder) -or (Test-RelUnder $RelPath $Folder)
}

function Get-RelRoot {
    # First segment of a relative path: Input, Result, ToDelete or System.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$RelPath)
    $i = $RelPath.IndexOf('/')
    if ($i -lt 0) { return $RelPath }
    return $RelPath.Substring(0, $i)
}

function Get-RelDepth {
    param([AllowEmptyString()][string]$RelPath)
    if ([string]::IsNullOrEmpty($RelPath)) { return 0 }
    return ($RelPath.Split('/')).Count
}

function Get-RelAncestors {
    # All ancestors of a relative path, outermost first, without the path itself.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$RelPath)
    $result = New-Object System.Collections.Generic.List[string]
    $parts = $RelPath.Split('/')
    for ($i = 1; $i -lt $parts.Count; $i++) {
        $result.Add(($parts[0..($i - 1)] -join '/'))
    }
    return , $result
}

function Test-RelExists {
    param([Parameter(Mandatory)][string]$RelPath)
    $abs = ConvertTo-AbsPath $RelPath
    return ([System.IO.File]::Exists($abs) -or [System.IO.Directory]::Exists($abs))
}

function Test-RelIsFolder {
    param([Parameter(Mandatory)][string]$RelPath)
    return [System.IO.Directory]::Exists((ConvertTo-AbsPath $RelPath))
}

function Get-InvalidNameReason {
    # Returns $null if the name is a valid Windows file or folder name, else a German message.
    param([AllowEmptyString()][string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return 'Der Name darf nicht leer sein.' }
    if ($Name.IndexOfAny([char[]]'\/:*?"<>|') -ge 0) {
        return 'Der Name enthält unzulässige Zeichen: \ / : * ? " < > |'
    }
    if ($Name.EndsWith('.') -or $Name.EndsWith(' ')) { return 'Der Name darf nicht mit Punkt oder Leerzeichen enden.' }
    $base = [System.IO.Path]::GetFileNameWithoutExtension($Name).ToUpperInvariant()
    if (@('CON', 'PRN', 'AUX', 'NUL', 'COM1', 'COM2', 'COM3', 'COM4', 'LPT1', 'LPT2', 'LPT3') -contains $base) {
        return 'Dieser Name ist unter Windows reserviert.'
    }
    return $null
}

function Remove-InvalidNameChars {
    # Removes characters not allowed in Windows names and trims the result.
    param([AllowEmptyString()][string]$Name, [int]$MaxLength = 0)
    if ($null -eq $Name) { return '' }
    $clean = -join ($Name.ToCharArray() | Where-Object { '\/:*?"<>|'.IndexOf($_) -lt 0 -and [int]$_ -ge 32 })
    $clean = ($clean -replace '\s+', ' ').Trim().TrimEnd('.')
    if ($MaxLength -gt 0 -and $clean.Length -gt $MaxLength) { $clean = $clean.Substring(0, $MaxLength).Trim() }
    return $clean
}

function Get-SuffixedName {
    # "Image.jpg", 2 -> "Image_2.jpg" (base section 2). Folders have no extension.
    param([Parameter(Mandatory)][string]$Name, [int]$Number, [switch]$IsFolder)
    if ($IsFolder) { return "$($Name)_$Number" }
    $ext = [System.IO.Path]::GetExtension($Name)
    $base = [System.IO.Path]::GetFileNameWithoutExtension($Name)
    return "$($base)_$Number$ext"
}

function Get-UniqueRelPath {
    # Returns $RelPath, or the first free "_2", "_3", ... variant (base section 2).
    # $Reserved: optional HashSet of relative paths (lower case) already taken by the plan.
    param(
        [Parameter(Mandatory)][string]$RelPath,
        $Reserved = $null,
        [switch]$IsFolder
    )
    $parent = Get-RelParent $RelPath
    $name = Get-RelName $RelPath
    $candidate = $RelPath
    $n = 1
    while ((Test-RelExists $candidate) -or ($null -ne $Reserved -and $Reserved.Contains($candidate))) {
        $n++
        $candidate = Join-RelPath $parent (Get-SuffixedName -Name $name -Number $n -IsFolder:$IsFolder)
    }
    return $candidate
}

function New-PathSet {
    # Case-insensitive set of relative paths.
    # The comma keeps PowerShell from unrolling the (empty) set into nothing.
    return , (New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase))
}

function Get-ExtensionKind {
    # 'Image', 'Video' or 'Other' according to settings.json.
    param([Parameter(Mandatory)][string]$Name)
    $ext = [System.IO.Path]::GetExtension($Name).ToLowerInvariant()
    if ($global:ST.Settings.imageExtensions -contains $ext) { return 'Image' }
    if ($global:ST.Settings.videoExtensions -contains $ext) { return 'Video' }
    return 'Other'
}

function Test-DayFolderName {
    # "2024-07-13" (exact) or, with -AllowPlace, also "2024-07-13 - Tokio".
    param([string]$Name, [switch]$AllowPlace)
    if ($Name -match '^\d{4}-\d{2}-\d{2}$') { return $true }
    if ($AllowPlace -and $Name -match '^\d{4}-\d{2}-\d{2} - .+') { return $true }
    return $false
}

function Get-FilesRecursive {
    # All files below an absolute folder, as FileInfo objects. Errors on single folders are skipped.
    param([Parameter(Mandatory)][string]$Folder)
    $result = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    if (-not [System.IO.Directory]::Exists($Folder)) { return , $result }
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($Folder)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        try {
            $info = New-Object System.IO.DirectoryInfo $dir
            foreach ($f in $info.GetFiles()) { $result.Add($f) }
            foreach ($d in $info.GetDirectories()) { $stack.Push($d.FullName) }
        }
        catch { }
    }
    return , $result
}
