# Log.ps1
# One log file per action (base section 8).
# File name: "YYYY-MM-DD_HH-MM-SS - Group - Script.log".
# Head: StartTime, EndTime, Group, Script, FilesMoved, Errors (plus optional extra lines such as
# Summary). After an empty line one line per step, separated by tabulators:
#   type <TAB> old path <TAB> new path [<TAB> extra information]

$global:ST.UndoableStepTypes = @('MOVED', 'RENAMED', 'FOLDER_CREATED', 'EMPTY_FOLDER_REMOVED', 'LINK_CREATED',
    'LINK_REMOVED', 'ENTRY_REMOVED', 'ENTRY_RESTORED')

function New-ActionLog {
    param([Parameter(Mandatory)][string]$Group, [Parameter(Mandatory)][string]$Script)
    return @{
        Group      = $Group
        Script     = $Script
        StartTime  = Get-Date
        Steps      = New-Object System.Collections.Generic.List[object]
        FilesMoved = 0
        Errors     = 0
        Extra      = [ordered]@{}
        Saved      = $null
    }
}

function ConvertTo-LogField {
    param($Value)
    if ($null -eq $Value) { return '' }
    return ([string]$Value) -replace "[`t`r`n]+", ' '
}

function Add-LogStep {
    param(
        [Parameter(Mandatory)]$Log,
        [Parameter(Mandatory)][string]$Type,
        [AllowEmptyString()][string]$Old = '',
        [AllowEmptyString()][string]$New = '',
        [AllowEmptyString()][string]$Extra = ''
    )
    $Log.Steps.Add([pscustomobject]@{ Type = $Type; Old = $Old; New = $New; Extra = $Extra })
    if ($Type -eq 'MOVED' -or $Type -eq 'RENAMED') { $Log.FilesMoved++ }
    if ($Type -eq 'ERROR') { $Log.Errors++ }
}

function Save-ActionLog {
    # Writes the log file. Returns its full path.
    param([Parameter(Mandatory)]$Log)
    $end = Get-Date
    $stamp = $Log.StartTime.ToString('yyyy-MM-dd_HH-mm-ss')
    $baseName = "$stamp - $($Log.Group) - $($Log.Script)"
    $path = Join-Path $global:ST.Logs "$baseName.log"
    $n = 1
    while (Test-Path -LiteralPath $path) {
        $n++
        $path = Join-Path $global:ST.Logs "$baseName ($n).log"
    }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("StartTime: $($Log.StartTime.ToString('yyyy-MM-dd HH:mm:ss'))")
    [void]$sb.AppendLine("EndTime: $($end.ToString('yyyy-MM-dd HH:mm:ss'))")
    [void]$sb.AppendLine("Group: $($Log.Group)")
    [void]$sb.AppendLine("Script: $($Log.Script)")
    [void]$sb.AppendLine("FilesMoved: $($Log.FilesMoved)")
    [void]$sb.AppendLine("Errors: $($Log.Errors)")
    foreach ($k in $Log.Extra.Keys) {
        [void]$sb.AppendLine("$($k): $(ConvertTo-LogField $Log.Extra[$k])")
    }
    [void]$sb.AppendLine('')
    foreach ($step in $Log.Steps) {
        $line = (ConvertTo-LogField $step.Type) + "`t" + (ConvertTo-LogField $step.Old) + "`t" + (ConvertTo-LogField $step.New)
        if (-not [string]::IsNullOrEmpty($step.Extra)) { $line += "`t" + (ConvertTo-LogField $step.Extra) }
        [void]$sb.AppendLine($line)
    }
    $utf8 = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($path, $sb.ToString(), $utf8)
    $Log.Saved = $path
    return $path
}

function Read-ActionLog {
    param([Parameter(Mandatory)][string]$Path)
    $header = [ordered]@{}
    $steps = New-Object System.Collections.Generic.List[object]
    $inSteps = $false
    foreach ($line in [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)) {
        if (-not $inSteps) {
            if ([string]::IsNullOrWhiteSpace($line)) { $inSteps = $true; continue }
            $i = $line.IndexOf(':')
            if ($i -gt 0) { $header[$line.Substring(0, $i).Trim()] = $line.Substring($i + 1).Trim() }
            continue
        }
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line.Split("`t")
        $step = [pscustomobject]@{
            Type  = $parts[0]
            Old   = $(if ($parts.Count -gt 1) { $parts[1] } else { '' })
            New   = $(if ($parts.Count -gt 2) { $parts[2] } else { '' })
            Extra = $(if ($parts.Count -gt 3) { ($parts[3..($parts.Count - 1)] -join "`t") } else { '' })
        }
        $steps.Add($step)
    }
    return [pscustomobject]@{ Path = $Path; Name = [System.IO.Path]::GetFileNameWithoutExtension($Path); Header = $header; Steps = $steps }
}

function Get-ActionNameFromLog {
    # "2026-10-25_06-20-00 - Images - FindDuplicates" -> "Images - FindDuplicates"
    param([Parameter(Mandatory)][string]$LogName)
    $m = [regex]::Match($LogName, '^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2} - (.+?)( \(\d+\))?$')
    if ($m.Success) { return $m.Groups[1].Value }
    return $LogName
}

function Get-UndoableLogs {
    # Log files that contain at least one step that can be undone, newest first (base section 9).
    # Initialization logs are not offered (2.1 section 6).
    $result = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $global:ST.Logs)) { return , $result }
    $files = Get-ChildItem -LiteralPath $global:ST.Logs -Filter '*.log' | Sort-Object Name -Descending
    foreach ($file in $files) {
        if ($file.Name -match ' - Database - Initialize(Input|Result)') { continue }
        try {
            $log = Read-ActionLog $file.FullName
        }
        catch { continue }
        $count = @($log.Steps | Where-Object { $global:ST.UndoableStepTypes -contains $_.Type }).Count
        if ($count -eq 0) { continue }
        $log | Add-Member -NotePropertyName UndoableCount -NotePropertyValue $count
        $result.Add($log)
    }
    return , $result
}

function Write-StatusText {
    # Status area at the bottom of the main window (base section 5), German text.
    param([AllowEmptyString()][string]$Text)
    if ($global:ST.StatusLabel) {
        $global:ST.StatusLabel.Text = $Text
        if ($global:ST.StatusStrip) { $global:ST.StatusStrip.Refresh() }
        [System.Windows.Forms.Application]::DoEvents()
    }
}

function Write-AppErrorLog {
    # Problems outside an action (e.g. missing script at start) are written to a log of their own.
    param([Parameter(Mandatory)][string]$Script, [Parameter(Mandatory)][string[]]$Messages)
    $log = New-ActionLog -Group 'Main' -Script $Script
    foreach ($m in $Messages) { Add-LogStep -Log $log -Type 'ERROR' -Old '' -New '' -Extra $m }
    [void](Save-ActionLog $log)
}
