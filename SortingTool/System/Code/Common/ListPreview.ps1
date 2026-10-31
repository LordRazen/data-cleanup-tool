# ListPreview.ps1
# Simple list preview for plans that only change the database (2.4 section 5 and its undo):
# one line per entry, grouped by main folder (Input, Result, ToDelete), one checkbox per entry
# and per main folder. Returns $true for "Ausführen", $false for "Abbrechen".

function Format-EntryLine {
    param($Item)
    $row = $Item.Data.Row
    $path = $Item.Source
    if (-not $path) { $path = $Item.Target }
    $size = ''
    $date = ''
    if ($row) {
        $sizeValue = $null
        $dateValue = $null
        if ($row -is [System.Collections.IDictionary]) { $sizeValue = $row['Size']; $dateValue = $row['CaptureDate'] }
        else { $sizeValue = $row.Size; $dateValue = $row.CaptureDate }
        if ($null -ne $sizeValue -and "$sizeValue" -ne '') { $size = '{0:N0} KB' -f ([double]$sizeValue / 1024) }
        if ($dateValue) { $date = [string]$dateValue }
    }
    $text = "$path    $size    $date"
    if ($Item.Locked -and $Item.Conflict) { $text += "    ($($Item.Conflict))" }
    return $text
}

function Show-ListPreview {
    param([Parameter(Mandatory)]$Plan)
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Vorschau: $($Plan.Title)"
    $form.StartPosition = 'CenterParent'
    $form.Width = 1000
    $form.Height = 700
    $form.Tag = $false

    $top = New-Object System.Windows.Forms.Label
    $top.Dock = 'Top'
    $top.Height = 50
    $top.Padding = New-Object System.Windows.Forms.Padding 8
    $top.Text = $Plan.Title
    if ($Plan.Notice) { $top.Text += "`r`n" + $Plan.Notice; $top.ForeColor = [System.Drawing.Color]::DarkRed }

    $tree = New-Object System.Windows.Forms.TreeView
    $tree.Dock = 'Fill'
    $tree.CheckBoxes = $true
    $tree.Font = New-Object System.Drawing.Font('Consolas', 9)
    $groups = @{}
    foreach ($item in $Plan.Items) {
        if ($item.Action -notin @('RemoveEntry', 'RestoreEntry')) { continue }
        $path = $item.Source
        if (-not $path) { $path = $item.Target }
        $root = Get-RelRoot $path
        if (-not $groups.ContainsKey($root)) {
            $g = New-Object System.Windows.Forms.TreeNode $root
            $groups[$root] = $g
        }
        $node = New-Object System.Windows.Forms.TreeNode (Format-EntryLine $item)
        $node.Tag = $item
        $node.Checked = [bool]$item.Checked
        if ($item.Locked) { $node.ForeColor = [System.Drawing.Color]::Gray }
        [void]$groups[$root].Nodes.Add($node)
    }
    foreach ($name in @('Input', 'Result', 'ToDelete') + @($groups.Keys)) {
        if ($groups.ContainsKey($name) -and -not $tree.Nodes.Contains($groups[$name])) {
            $g = $groups[$name]
            $g.Text = "$name ($($g.Nodes.Count))"
            $all = $true
            foreach ($c in $g.Nodes) { if (-not $c.Checked) { $all = $false } }
            $g.Checked = $all
            [void]$tree.Nodes.Add($g)
            $g.Expand()
        }
    }
    $summary = New-Object System.Windows.Forms.Label
    $summary.Dock = 'Fill'
    $summary.TextAlign = 'MiddleLeft'
    $state = @{ Busy = $false; Tree = $tree; Summary = $summary; Plan = $Plan }
    $updateSummary = {
        $checked = 0; $total = 0
        foreach ($i in $state.Plan.Items) {
            if ($i.Action -notin @('RemoveEntry', 'RestoreEntry')) { continue }
            $total++
            if ($i.Checked -and -not $i.Locked) { $checked++ }
        }
        $state.Summary.Text = "Angehakt: $checked   Gefundene Einträge: $total   Werden geändert: $checked"
    }
    $tree.Add_BeforeCheck({
            param($sender, $e)
            if ($e.Node.Tag -and $e.Node.Tag.Locked) { $e.Cancel = $true }
        })
    $tree.Add_AfterCheck({
            param($sender, $e)
            if ($state.Busy) { return }
            $state.Busy = $true
            try {
                if ($e.Node.Tag) {
                    $e.Node.Tag.Checked = $e.Node.Checked
                }
                else {
                    foreach ($c in $e.Node.Nodes) {
                        if ($c.Tag.Locked) { continue }
                        $c.Checked = $e.Node.Checked
                        $c.Tag.Checked = $e.Node.Checked
                    }
                }
            }
            finally { $state.Busy = $false }
            & $updateSummary
        })
    $setAll = {
        param([bool]$value)
        $state.Busy = $true
        foreach ($g in $state.Tree.Nodes) {
            $g.Checked = $value
            foreach ($c in $g.Nodes) {
                if ($c.Tag.Locked) { continue }
                $c.Checked = $value
                $c.Tag.Checked = $value
            }
        }
        $state.Busy = $false
        & $updateSummary
    }
    $bottom = New-Object System.Windows.Forms.Panel
    $bottom.Dock = 'Bottom'
    $bottom.Height = 46
    $buttons = New-Object System.Windows.Forms.FlowLayoutPanel
    $buttons.Dock = 'Right'
    $buttons.FlowDirection = 'RightToLeft'
    $buttons.Width = 480
    $buttons.Padding = New-Object System.Windows.Forms.Padding 4, 8, 4, 4
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Abbrechen'
    $cancel.AutoSize = $true
    $cancel.Add_Click({ $this.FindForm().Tag = $false; $this.FindForm().Close() })
    $run = New-Object System.Windows.Forms.Button
    $run.Text = 'Ausführen'
    $run.AutoSize = $true
    $run.Add_Click({ $this.FindForm().Tag = $true; $this.FindForm().Close() })
    $none = New-Object System.Windows.Forms.Button
    $none.Text = 'Alle ablehnen'
    $none.AutoSize = $true
    $none.Add_Click({ & $setAll $false })
    $allB = New-Object System.Windows.Forms.Button
    $allB.Text = 'Alle annehmen'
    $allB.AutoSize = $true
    $allB.Add_Click({ & $setAll $true })
    $buttons.Controls.AddRange(@($cancel, $run, $none, $allB))
    $bottom.Controls.Add($summary)
    $bottom.Controls.Add($buttons)
    $form.Controls.Add($tree)
    $form.Controls.Add($top)
    $form.Controls.Add($bottom)
    $form.CancelButton = $cancel
    & $updateSummary
    [void]$form.ShowDialog((Get-OwnerForm))
    $result = [bool]$form.Tag
    $form.Dispose()
    return $result
}
