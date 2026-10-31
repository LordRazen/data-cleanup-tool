# Plan.ps1
# A function script never touches a file itself. It returns a plan (base section 7): a list of
# items such as "move file A to B" or "create folder". The main program shows the plan in the
# preview, and after confirmation Invoke-Plan executes exactly the checked items.
#
# Item actions:
#   MoveFile      Source -> Target (renaming = moving under a new name)
#   MoveFolder    Source -> Target (folder rename or move with its whole content)
#   CreateFolder  Target. Only created if a checked item goes into it, or with Force (undo)
#   CreateLink    Target = .lnk path, LinkTarget = file or folder it points to (2.2)
#   RemoveLink    Source = .lnk path (undo of LINK_CREATED only, 2.2 section 7)
#   RemoveFolder  Source, only if empty after the plan (undo of FOLDER_CREATED, base section 9)
#   RemoveEntry   Source = database path (2.4), Data.Row = full row
#   RestoreEntry  Target = database path (undo of 2.4), Data.Row = full row
#   Info          Source, information row without checkbox (e.g. "kein GPS")
# The main program adds "remove empty folder in Input" items automatically (Auto = $true).

function New-Plan {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Group,
        [Parameter(Mandatory)][string]$Script,
        [string[]]$Roots = @('Input')
    )
    return @{
        Kind           = 'Plan'
        Title          = $Title
        Group          = $Group
        Script         = $Script
        Roots          = $Roots
        Items          = New-Object System.Collections.Generic.List[object]
        NextId         = 1
        Data           = @{}
        Notice         = ''          # text shown above the preview (e.g. OpenStreetMap attribution)
        SummaryExtra   = $null       # scriptblock ($plan) -> extra summary text
        OnExecuted     = $null       # scriptblock ($plan, $log) called after execution, before the log is saved
        OnItemEdited   = $null       # scriptblock ($plan, $item) after the name or choice of an item was edited
        OnFolderToggled = $null      # scriptblock ($plan, $folderPath, $checked)
        ExtendPreview  = $null       # scriptblock ($plan, $panel, $api) adds controls at the top of the preview
        FolderMenu     = @()         # @{ Label; Action = scriptblock ($plan, $folderPath, $api) }
        Filters        = @()         # @{ Label; Test = scriptblock ($item) -> bool }
        ShowThumbnails = $false
        EditLabel      = 'Name'
        ChoiceLabel    = 'Auswahl'
        AutoUnchecked  = (New-PathSet)
        LogExtra       = [ordered]@{}
        PreSteps       = (New-Object System.Collections.Generic.List[object])   # log lines written first (API_CALL, PREASSESSMENT)
    }
}

function Add-PlanItem {
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][ValidateSet('MoveFile', 'MoveFolder', 'CreateFolder', 'CreateLink', 'RemoveLink',
            'RemoveFolder', 'RemoveEntry', 'RestoreEntry', 'Info')][string]$Action,
        [string]$Source = '',
        [string]$Target = '',
        [string]$LinkTarget = '',
        [bool]$Checked = $true,
        [bool]$Locked = $false,
        [string]$Conflict = '',
        [int]$ParentId = 0,
        [string]$Info = '',
        [bool]$Weak = $false,
        [bool]$AllowSuffix = $true,
        [bool]$Force = $false,
        [string]$Extra = '',
        [string]$StepType = '',
        $Data = $null
    )
    if ($Locked) { $Checked = $false }
    if ($null -eq $Data) { $Data = @{} }
    $item = [pscustomobject]@{
        Id          = $Plan.NextId
        Action      = $Action
        Source      = $Source
        Target      = $Target
        LinkTarget  = $LinkTarget
        Checked     = $Checked
        Locked      = $Locked
        Conflict    = $Conflict
        ParentId    = $ParentId
        Info        = $Info
        Weak        = $Weak
        AllowSuffix = $AllowSuffix
        Force       = $Force
        Extra       = $Extra
        StepType    = $StepType
        EditMode    = $null      # $null, 'Suffix' (part after EditPrefix) or 'Keyword' (name without extension)
        EditPrefix  = ''
        EditValue   = ''
        Choices     = $null      # list of strings for a dropdown
        Choice      = $null
        Thumbnail   = ''         # relative path of an image to show as thumbnail
        Auto        = $false
        Data        = $Data
    }
    $Plan.NextId++
    $Plan.Items.Add($item)
    return $item
}

function Get-PlanItemById {
    param($Plan, [int]$Id)
    foreach ($i in $Plan.Items) { if ($i.Id -eq $Id) { return $i } }
    return $null
}

function Test-ItemEffective {
    # Whether an item would be executed with the current checkboxes (without derived folders).
    param($Plan, $Item)
    if ($Item.Action -eq 'Info') { return $false }
    if ($Item.Locked) { return $false }
    if ($Item.ParentId -gt 0) {
        $parent = Get-PlanItemById $Plan $Item.ParentId
        if ($null -ne $parent) { return ($parent.Checked -and -not $parent.Locked) }
    }
    return [bool]$Item.Checked
}

function Get-PlanReservedTargets {
    # Targets already used by other items of the plan, for "_2" naming inside one plan.
    param($Plan, $Except = $null)
    $set = New-PathSet
    foreach ($i in $Plan.Items) {
        if ($null -ne $Except -and $i.Id -eq $Except.Id) { continue }
        if ($i.Action -in @('MoveFile', 'MoveFolder', 'CreateLink') -and $i.Target) { [void]$set.Add($i.Target) }
    }
    return , $set
}

function Update-PlanDerived {
    # Recomputes the derived parts of a plan after a checkbox changed:
    #  - CreateFolder items: effective only if a checked item goes into the folder (base section 5),
    #  - automatic "remove empty folder in Input" items (base section 7).
    # Sets the note property Effective on every item.
    param([Parameter(Mandatory)]$Plan)
    # Drop old automatic items.
    for ($k = $Plan.Items.Count - 1; $k -ge 0; $k--) { if ($Plan.Items[$k].Auto) { $Plan.Items.RemoveAt($k) } }

    $targetsIn = New-Object System.Collections.Generic.List[string]
    foreach ($i in $Plan.Items) {
        $eff = Test-ItemEffective $Plan $i
        if ($i.Action -eq 'CreateFolder') { $eff = $false }
        $i | Add-Member -NotePropertyName Effective -NotePropertyValue $eff -Force
        if ($eff -and $i.Action -in @('MoveFile', 'MoveFolder', 'CreateLink', 'RestoreEntry') -and $i.Target) { $targetsIn.Add($i.Target) }
    }
    foreach ($i in $Plan.Items) {
        if ($i.Action -ne 'CreateFolder') { continue }
        $eff = $false
        if (-not $i.Locked) {
            if ($i.Force) { $eff = [bool]$i.Checked }
            else {
                foreach ($t in $targetsIn) { if (Test-RelUnder $t $i.Target) { $eff = $true; break } }
            }
        }
        $i.Effective = $eff
    }

    # Empty folders in Input after the plan.
    $gone = New-PathSet      # files and folders that leave their place
    $incoming = New-PathSet  # folders that receive something
    $candidates = New-PathSet
    foreach ($i in $Plan.Items) {
        if (-not $i.Effective) { continue }
        if ($i.Action -in @('MoveFile', 'MoveFolder')) {
            [void]$gone.Add($i.Source)
            $p = Get-RelParent $i.Source
            if (Test-RelUnder $p 'Input') { [void]$candidates.Add($p) }
        }
        if ($i.Action -eq 'RemoveFolder' -or $i.Action -eq 'RemoveLink') { [void]$gone.Add($i.Source) }
        if ($i.Target) {
            foreach ($a in (Get-RelAncestors $i.Target)) { [void]$incoming.Add($a) }
        }
    }
    $all = New-PathSet
    foreach ($c in $candidates) {
        [void]$all.Add($c)
        foreach ($a in (Get-RelAncestors $c)) { if (Test-RelUnder $a 'Input') { [void]$all.Add($a) } }
    }
    $removedFolders = New-PathSet
    foreach ($folder in ($all | Sort-Object { (Get-RelDepth $_) } -Descending)) {
        if ($incoming.Contains($folder)) { continue }
        if ($gone.Contains($folder)) { continue }
        $abs = ConvertTo-AbsPath $folder
        if (-not [System.IO.Directory]::Exists($abs)) { continue }
        $empty = $true
        try {
            foreach ($entry in [System.IO.Directory]::EnumerateFileSystemEntries($abs)) {
                $rel = ConvertTo-RelPath $entry
                if ($gone.Contains($rel) -or $removedFolders.Contains($rel)) { continue }
                $empty = $false
                break
            }
        }
        catch { $empty = $false }
        if (-not $empty) { continue }
        $item = Add-PlanItem -Plan $Plan -Action 'RemoveFolder' -Source $folder -Checked (-not $Plan.AutoUnchecked.Contains($folder))
        $item.Auto = $true
        $item | Add-Member -NotePropertyName Effective -NotePropertyValue ([bool]$item.Checked) -Force
        if ($item.Checked) { [void]$removedFolders.Add($folder); [void]$gone.Add($folder) }
    }
}

function Get-PlanCounts {
    # Numbers for the summary below the preview (base section 5).
    param([Parameter(Mandatory)]$Plan)
    $accepted = 0; $rejected = 0; $conflicts = 0
    foreach ($i in $Plan.Items) {
        if ($i.Action -in @('Info', 'CreateFolder') -or $i.ParentId -gt 0 -or $i.Auto) { continue }
        if ($i.Locked) { $conflicts++; continue }
        if ($i.Checked) { $accepted++ } else { $rejected++ }
    }
    return @{ Accepted = $accepted; Rejected = $rejected; Conflicts = $conflicts }
}

function Invoke-Plan {
    # Executes the effective items of a plan, writes the log and keeps the database up to date.
    # A failing item is logged as ERROR and does not stop the run (base section 8).
    # Returns the log object (with .Saved = path of the log file).
    param([Parameter(Mandatory)]$Plan)
    Update-PlanDerived $Plan
    $log = New-ActionLog -Group $Plan.Group -Script $Plan.Script
    foreach ($k in $Plan.LogExtra.Keys) { $log.Extra[$k] = $Plan.LogExtra[$k] }
    foreach ($step in $Plan.PreSteps) { Add-LogStep -Log $log -Type $step.Type -Old $step.Old -New $step.New -Extra $step.Extra }
    $finalTargets = @{}
    $opCount = 0
    Start-DbTransaction
    try {
        # 1. Folders, outermost first.
        foreach ($item in ($Plan.Items | Where-Object { $_.Action -eq 'CreateFolder' -and $_.Effective } | Sort-Object { Get-RelDepth $_.Target })) {
            try {
                if (-not [System.IO.Directory]::Exists((ConvertTo-AbsPath $item.Target))) { New-FolderTracked -Path $item.Target -Log $log }
            }
            catch { Add-LogStep -Log $log -Type 'ERROR' -Old '' -New $item.Target -Extra $_.Exception.Message }
        }
        # 2. Folder moves and renames.
        foreach ($item in ($Plan.Items | Where-Object { $_.Action -eq 'MoveFolder' -and $_.Effective })) {
            try {
                $type = 'MOVED'
                if ($item.StepType) { $type = $item.StepType }
                $final = Move-FolderTracked -Source $item.Source -Target $item.Target -Log $log -AllowSuffix:$item.AllowSuffix -StepType $type -Extra $item.Extra
                $finalTargets[$item.Id] = $final
            }
            catch { Add-LogStep -Log $log -Type 'ERROR' -Old $item.Source -New $item.Target -Extra $_.Exception.Message }
            $opCount++
            if ($opCount % 100 -eq 0) { Complete-DbTransaction; Start-DbTransaction; Write-StatusText "Ausführen … $opCount Schritte" }
        }
        # 3. File moves.
        foreach ($item in ($Plan.Items | Where-Object { $_.Action -eq 'MoveFile' -and $_.Effective })) {
            try {
                $type = 'MOVED'
                if ($item.StepType) { $type = $item.StepType }
                $final = Move-FileTracked -Source $item.Source -Target $item.Target -Log $log -AllowSuffix:$item.AllowSuffix -StepType $type -Extra $item.Extra
                $finalTargets[$item.Id] = $final
            }
            catch { Add-LogStep -Log $log -Type 'ERROR' -Old $item.Source -New $item.Target -Extra $_.Exception.Message }
            $opCount++
            if ($opCount % 100 -eq 0) { Complete-DbTransaction; Start-DbTransaction; Write-StatusText "Ausführen … $opCount Schritte" }
        }
        # 4. Shortcuts. A shortcut that belongs to a moved file follows the final file name.
        foreach ($item in ($Plan.Items | Where-Object { $_.Action -eq 'CreateLink' -and $_.Effective })) {
            try {
                $path = $item.Target
                if ($item.ParentId -gt 0 -and $item.Data.LinkSuffix) {
                    if (-not $finalTargets.ContainsKey($item.ParentId)) { continue }   # file was not moved
                    $path = $finalTargets[$item.ParentId] + $item.Data.LinkSuffix
                }
                New-ShortcutTracked -Path $path -TargetRel $item.LinkTarget -Log $log
            }
            catch { Add-LogStep -Log $log -Type 'ERROR' -Old '' -New $item.Target -Extra $_.Exception.Message }
        }
        foreach ($item in ($Plan.Items | Where-Object { $_.Action -eq 'RemoveLink' -and $_.Effective })) {
            try { Remove-ShortcutTracked -Path $item.Source -TargetRel $item.LinkTarget -Log $log }
            catch { Add-LogStep -Log $log -Type 'ERROR' -Old $item.Source -New '' -Extra $_.Exception.Message }
        }
        # 5. Database-only items (2.4 and its undo).
        foreach ($item in ($Plan.Items | Where-Object { $_.Action -eq 'RemoveEntry' -and $_.Effective })) {
            try {
                $json = (ConvertTo-EntryHashtable $item.Data.Row) | ConvertTo-Json -Compress
                Remove-FileEntry $item.Source
                Add-LogStep -Log $log -Type 'ENTRY_REMOVED' -Old $item.Source -New '' -Extra $json
            }
            catch { Add-LogStep -Log $log -Type 'ERROR' -Old $item.Source -New '' -Extra $_.Exception.Message }
        }
        foreach ($item in ($Plan.Items | Where-Object { $_.Action -eq 'RestoreEntry' -and $_.Effective })) {
            try {
                if ($null -ne (Get-FileEntry $item.Target)) { throw 'An entry exists again for this path.' }
                $row = @{}
                foreach ($p in $item.Data.Row.PSObject.Properties) { $row[$p.Name] = $p.Value }
                $row.Path = $item.Target
                Set-FileEntry $row
                $json = (ConvertTo-EntryHashtable $row) | ConvertTo-Json -Compress
                Add-LogStep -Log $log -Type 'ENTRY_RESTORED' -Old '' -New $item.Target -Extra $json
            }
            catch { Add-LogStep -Log $log -Type 'ERROR' -Old '' -New $item.Target -Extra $_.Exception.Message }
        }
        # 6. Folders to remove on undo, deepest first, only if empty.
        foreach ($item in ($Plan.Items | Where-Object { $_.Action -eq 'RemoveFolder' -and -not $_.Auto -and $_.Effective } |
                    Sort-Object { Get-RelDepth $_.Source } -Descending)) {
            try {
                if (-not (Remove-EmptyFolderTracked -Path $item.Source -Log $log)) {
                    if (Test-RelExists $item.Source) {
                        Add-LogStep -Log $log -Type 'REJECTED' -Old $item.Source -New '' -Extra 'Folder is not empty, kept.'
                    }
                }
            }
            catch { Add-LogStep -Log $log -Type 'ERROR' -Old $item.Source -New '' -Extra $_.Exception.Message }
        }
        # 7. Empty folders in Input (automatic), except those unchecked in the preview.
        $candidates = New-Object System.Collections.Generic.List[string]
        foreach ($item in $Plan.Items) {
            if ($item.Effective -and $item.Action -in @('MoveFile', 'MoveFolder') -and $finalTargets.ContainsKey($item.Id)) {
                $candidates.Add((Get-RelParent $item.Source))
            }
        }
        [void](Remove-EmptyInputFolders -Candidates $candidates -Log $log -Exclude $Plan.AutoUnchecked)
        # 8. Rejected items are logged too (base section 8).
        foreach ($item in $Plan.Items) {
            if ($item.Action -in @('Info', 'CreateFolder') -or $item.Auto -or $item.ParentId -gt 0) { continue }
            if ($item.Effective) { continue }
            $reason = 'Rejected in preview'
            if ($item.Locked -and $item.Conflict) { $reason = $item.Conflict }
            Add-LogStep -Log $log -Type 'REJECTED' -Old $item.Source -New $item.Target -Extra $reason
        }
        if ($Plan.OnExecuted) { & $Plan.OnExecuted $Plan $log }
    }
    finally {
        try { Complete-DbTransaction } catch { }
    }
    [void](Save-ActionLog $log)
    return $log
}

function New-FunctionResult {
    # Result of a function script that does not return a plan:
    #   Done      the function finished (e.g. InitializeFolder); Message = summary to show
    #   Message   nothing to do, show Message, the chain continues
    #   Cancelled the user cancelled, the chain stops
    #   Failed    the function failed as a whole, Message = reason, the chain stops
    param([Parameter(Mandatory)][ValidateSet('Done', 'Message', 'Cancelled', 'Failed')][string]$Kind, [string]$Message = '')
    return @{ Kind = $Kind; Message = $Message }
}

function Add-PlanPreStep {
    # A log line that is written at the start of the log when the plan is executed
    # (e.g. API_CALL lines of 3 - API.md section 4, PREASSESSMENT lines of 2.8).
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)][string]$Type, [string]$Old = '', [string]$New = '', [string]$Extra = '')
    $Plan.PreSteps.Add([pscustomobject]@{ Type = $Type; Old = $Old; New = $New; Extra = $Extra })
}

function Set-SuffixRenameTarget {
    # For folder renames with an editable name part (2.6, 2.7): the part after EditPrefix was
    # edited in the preview; the target follows, with "_2" if the name is taken (base section 2).
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)]$Item)
    $value = Remove-InvalidNameChars ([string]$Item.EditValue)
    if (-not $value) { $value = [string]$Item.Data.DefaultSuffix }
    $Item.EditValue = $value
    $parent = Get-RelParent $Item.Source
    $reserved = Get-PlanReservedTargets -Plan $Plan -Except $Item
    $Item.Target = Get-UniqueRelPath -RelPath (Join-RelPath $parent ($Item.EditPrefix + $value)) -Reserved $reserved -IsFolder
}

function Get-InputFolderGroups {
    # Folders directly in Input, split into day folders without place ("2024-07-13"), day folders
    # with place ("2024-07-13 - Tokio") and other folders (2.3 section 3, 2.6 section 3).
    $result = @{ Day = @(); DayWithPlace = @(); Other = @() }
    foreach ($d in ((New-Object System.IO.DirectoryInfo (ConvertTo-AbsPath 'Input')).GetDirectories() | Sort-Object Name)) {
        if (Test-DayFolderName $d.Name) { $result.Day += $d.Name }
        elseif (Test-DayFolderName $d.Name -AllowPlace) { $result.DayWithPlace += $d.Name }
        else { $result.Other += $d.Name }
    }
    return $result
}
