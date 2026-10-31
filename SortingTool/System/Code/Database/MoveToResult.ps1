# MoveToResult.ps1 (2.5)
# Moves finished files or folders from Input into one chosen folder in Result.
# A selection dialog comes first: source tree with checkboxes ("Was soll verschoben werden?")
# and a tree dropdown with the folders of Result up to resultTargetDepth levels ("Ziel in Result"),
# including "Neuer Ordner …". The relative path below Input is kept in the target, so a checked
# folder arrives with its name and content, and a partly checked folder only with the checked files.

param($Context, [hashtable]$Arguments = @{})

$depthLimit = [int]$global:ST.Settings.resultTargetDepth
if ($depthLimit -lt 1) { $depthLimit = 1 }

function Add-SourceNodes {
    param($Nodes, [string]$AbsFolder)
    $info = New-Object System.IO.DirectoryInfo $AbsFolder
    foreach ($d in ($info.GetDirectories() | Sort-Object Name)) {
        $node = New-Object System.Windows.Forms.TreeNode $d.Name
        $node.Tag = @{ Rel = (ConvertTo-RelPath $d.FullName); IsFolder = $true }
        [void]$Nodes.Add($node)
        Add-SourceNodes -Nodes $node.Nodes -AbsFolder $d.FullName
    }
    foreach ($f in ($info.GetFiles() | Sort-Object Name)) {
        $node = New-Object System.Windows.Forms.TreeNode $f.Name
        $node.Tag = @{ Rel = (ConvertTo-RelPath $f.FullName); IsFolder = $false }
        [void]$Nodes.Add($node)
    }
}

function Add-TargetNodes {
    param($Nodes, [string]$AbsFolder, [int]$Depth, [int]$MaxDepth)
    if ($Depth -gt $MaxDepth) { return }
    foreach ($d in ((New-Object System.IO.DirectoryInfo $AbsFolder).GetDirectories() | Sort-Object Name)) {
        $node = New-Object System.Windows.Forms.TreeNode $d.Name
        $node.Tag = @{ Rel = (ConvertTo-RelPath $d.FullName); Depth = $Depth; Virtual = $false }
        [void]$Nodes.Add($node)
        Add-TargetNodes -Nodes $node.Nodes -AbsFolder $d.FullName -Depth ($Depth + 1) -MaxDepth $MaxDepth
    }
}

function Get-CheckedFiles {
    param($Nodes, $List)
    foreach ($n in $Nodes) {
        if ($n.Tag.IsFolder) { Get-CheckedFiles -Nodes $n.Nodes -List $List }
        elseif ($n.Checked) { $List.Add($n.Tag.Rel) }
    }
}

# ---------------------------------------------------------------- selection dialog
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Nach Result verschieben'
$form.StartPosition = 'CenterParent'
$form.Width = 760
$form.Height = 720
$form.Tag = $false

$srcLabel = New-Object System.Windows.Forms.Label
$srcLabel.Text = 'Was soll verschoben werden?'
$srcLabel.Dock = 'Top'
$srcLabel.Height = 24
$srcLabel.Padding = New-Object System.Windows.Forms.Padding 6, 6, 0, 0
$tree = New-Object System.Windows.Forms.TreeView
$tree.Dock = 'Fill'
$tree.CheckBoxes = $true
$tree.PathSeparator = '/'
Add-SourceNodes -Nodes $tree.Nodes -AbsFolder (ConvertTo-AbsPath 'Input')
if ($tree.Nodes.Count -eq 0) {
    $form.Dispose()
    return (New-FunctionResult -Kind Message -Message 'Nach Result verschieben: Input ist leer.')
}

$targetPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$targetPanel.Dock = 'Bottom'
$targetPanel.Height = 40
$targetPanel.Padding = New-Object System.Windows.Forms.Padding 6
$targetLabel = New-Object System.Windows.Forms.Label
$targetLabel.Text = 'Ziel in Result'
$targetLabel.AutoSize = $true
$targetLabel.Margin = New-Object System.Windows.Forms.Padding 3, 7, 6, 3
$dd = New-TreeDropDown -Width 500
$rootNode = New-Object System.Windows.Forms.TreeNode 'Result'
$rootNode.Tag = @{ Rel = 'Result'; Depth = 0; Virtual = $false }
[void]$dd.Tree.Nodes.Add($rootNode)
Add-TargetNodes -Nodes $rootNode.Nodes -AbsFolder (ConvertTo-AbsPath 'Result') -Depth 1 -MaxDepth $depthLimit
$rootNode.Expand()
$newNode = New-Object System.Windows.Forms.TreeNode 'Neuer Ordner …'
$newNode.Tag = @{ New = $true }
$newNode.ForeColor = [System.Drawing.Color]::DarkGreen
[void]$dd.Tree.Nodes.Add($newNode)
$targetPanel.Controls.AddRange(@($targetLabel, $dd.Button))

$buttons = New-Object System.Windows.Forms.FlowLayoutPanel
$buttons.Dock = 'Bottom'
$buttons.FlowDirection = 'RightToLeft'
$buttons.Height = 44
$buttons.Padding = New-Object System.Windows.Forms.Padding 6
$cancel = New-Object System.Windows.Forms.Button
$cancel.Text = 'Abbrechen'
$cancel.AutoSize = $true
$cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
$previewButton = New-Object System.Windows.Forms.Button
$previewButton.Text = 'Vorschau'
$previewButton.AutoSize = $true
$previewButton.Enabled = $false
$previewButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
$buttons.Controls.AddRange(@($cancel, $previewButton))

$form.Controls.Add($tree)
$form.Controls.Add($srcLabel)
$form.Controls.Add($targetPanel)
$form.Controls.Add($buttons)
$form.CancelButton = $cancel

$dialog = @{ Busy = $false; Tree = $tree; DD = $dd; Preview = $previewButton; DepthLimit = $depthLimit }
$dialog.UpdateButton = {
    $files = New-Object System.Collections.Generic.List[string]
    Get-CheckedFiles -Nodes $dialog.Tree.Nodes -List $files
    $dialog.Preview.Enabled = ($files.Count -gt 0 -and $null -ne $dialog.DD.Selected)
}
$tree.Add_AfterCheck({
        param($sender, $e)
        if ($dialog.Busy) { return }
        $dialog.Busy = $true
        try {
            # Checking a folder checks everything below it (2.5 section 4).
            $stack = New-Object System.Collections.Stack
            foreach ($c in $e.Node.Nodes) { $stack.Push($c) }
            while ($stack.Count -gt 0) {
                $n = $stack.Pop()
                $n.Checked = $e.Node.Checked
                foreach ($c in $n.Nodes) { $stack.Push($c) }
            }
        }
        finally { $dialog.Busy = $false }
        & $dialog.UpdateButton
    })
$dd.OnSelect = {
    param($state, $node)
    if ($node.Tag.New) {
        # "Neuer Ordner …": below the chosen node, within the allowed depth (2.5 section 4).
        $parent = $state.Selected
        if ($null -eq $parent) { $parent = $state.Tree.Nodes[0] }
        if ($parent.Tag.Depth -ge $dialog.DepthLimit) {
            Show-ErrorMessage "Ein neuer Ordner kann höchstens $($dialog.DepthLimit) Ebenen tief in Result liegen. Bitte zuerst einen höheren Ordner wählen."
            return $false
        }
        $name = Show-TextInput -Prompt "Name des neuen Ordners in „$($parent.FullPath)“:" -Title 'Neuer Ordner'
        if ($null -eq $name) { return $false }
        $name = $name.Trim()
        $reason = Get-InvalidNameReason $name
        if ($reason) { Show-ErrorMessage $reason; return $false }
        foreach ($c in $parent.Nodes) {
            if ([string]::Equals($c.Text, $name, [System.StringComparison]::OrdinalIgnoreCase)) {
                Select-TreeDropDownNode $state $c
                & $dialog.UpdateButton
                return $false
            }
        }
        $virtual = New-Object System.Windows.Forms.TreeNode $name
        $virtual.Tag = @{ Rel = (Join-RelPath $parent.Tag.Rel $name); Depth = $parent.Tag.Depth + 1; Virtual = $true }
        $virtual.ForeColor = [System.Drawing.Color]::DarkGreen
        [void]$parent.Nodes.Add($virtual)
        $parent.Expand()
        Select-TreeDropDownNode $state $virtual
        & $dialog.UpdateButton
        return $false
    }
    $state.Selected = $node
    & $dialog.UpdateButton
    return $true
}

$answer = $form.ShowDialog((Get-OwnerForm))
$files = New-Object System.Collections.Generic.List[string]
Get-CheckedFiles -Nodes $tree.Nodes -List $files
$targetFolder = $null
if ($dd.Selected) { $targetFolder = [string]$dd.Selected.Tag.Rel }
$form.Dispose()
if ($answer -ne [System.Windows.Forms.DialogResult]::OK -or $files.Count -eq 0 -or -not $targetFolder) {
    return (New-FunctionResult -Kind Cancelled)
}

# ---------------------------------------------------------------- duplicate check warning
$unchecked = 0
foreach ($rel in $files) {
    $entry = Get-FileEntry $rel
    if ($null -eq $entry -or [string]::IsNullOrEmpty([string]$entry.DuplicateChecked)) { $unchecked++ }
}
if ($unchecked -gt 0) {
    $answer = Show-ChoiceDialog -Text 'Einige Dateien wurden noch nicht auf Doubletten geprüft. Vorher „Input initialisieren“ ausführen?' `
        -Buttons @('Trotzdem fortfahren', 'Abbrechen') -Title 'Nach Result verschieben'
    if ($answer -ne 'Trotzdem fortfahren') { return (New-FunctionResult -Kind Cancelled) }
}

# ---------------------------------------------------------------- plan
$plan = New-Plan -Title "Nach Result verschieben: $targetFolder" -Group 'Database' -Script 'MoveToResult' -Roots @('Input', 'Result')
$reserved = New-PathSet
$folders = New-PathSet
foreach ($rel in $files) {
    $relBelowInput = $rel.Substring('Input/'.Length)
    $target = Join-RelPath $targetFolder $relBelowInput
    $parent = Get-RelParent $target
    if (-not [System.IO.Directory]::Exists((ConvertTo-AbsPath $parent))) { [void]$folders.Add($parent) }
    if ((Test-RelExists $target) -or $reserved.Contains($target)) {
        $same = $false
        if (Test-RelExists $target) {
            try {
                $srcEntry = Resolve-FileEntry $rel
                $dstEntry = Resolve-FileEntry $target
                if ($srcEntry -and $dstEntry -and [string]$srcEntry.Hash -eq [string]$dstEntry.Hash) { $same = $true }
            }
            catch { }
        }
        if ($same) {
            [void](Add-PlanItem -Plan $plan -Action 'MoveFile' -Source $rel -Target $target -Locked $true `
                    -Conflict 'Same file already in target (duplicate). Run "Input initialisieren" first.' `
                    -Info 'Konflikt: Gleiche Datei liegt schon im Ziel (Doublette). Vorher „Input initialisieren“ ausführen.')
            continue
        }
        $newTarget = Get-UniqueRelPath -RelPath $target -Reserved $reserved
        [void]$reserved.Add($newTarget)
        [void](Add-PlanItem -Plan $plan -Action 'MoveFile' -Source $rel -Target $newTarget -Info "Name schon vergeben, neuer Name: $(Get-RelName $newTarget)")
        continue
    }
    [void]$reserved.Add($target)
    [void](Add-PlanItem -Plan $plan -Action 'MoveFile' -Source $rel -Target $target)
}
foreach ($f in ($folders | Sort-Object { Get-RelDepth $_ })) {
    [void](Add-PlanItem -Plan $plan -Action 'CreateFolder' -Target $f)
}
return $plan
