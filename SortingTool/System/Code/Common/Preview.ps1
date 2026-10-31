# Preview.ps1
# Preview window in the style of a Git change view (base section 5 "Vorschaufenster").
#  - One table with two columns: left "Vorher", right "Nachher". Each file or folder is one row,
#    so both sides always stay at the same height and scroll together.
#  - Red: disappears at this place. Green: appears at this place. White: unchanged.
#  - Unchanged runs are collapsed to one row ("▸ 37 unveränderte Einträge"), 2 rows of context
#    stay visible around each change. Folders can be collapsed one by one (double-click).
#  - One checkbox per change, folder checkboxes switch all changes inside.
#  - Optional per plan: editable name, dropdown, thumbnails, filters, extra controls at the top.
# Returns $true when the user clicked "Ausführen", $false for "Abbrechen".

$global:ST.PreviewColors = @{
    Red     = [System.Drawing.Color]::FromArgb(255, 255, 215, 213)
    Green   = [System.Drawing.Color]::FromArgb(255, 204, 255, 216)
    White   = [System.Drawing.Color]::White
    Select  = [System.Drawing.Color]::FromArgb(255, 204, 228, 255)
    Grey    = [System.Drawing.Color]::Gray
    Summary = [System.Drawing.Color]::FromArgb(255, 241, 243, 245)
}

function Get-PreviewListing {
    # Direct children of a folder, cached for the lifetime of one preview.
    param($S, [string]$Folder)
    if ($S.Listing.ContainsKey($Folder)) { return $S.Listing[$Folder] }
    $list = New-Object System.Collections.Generic.List[object]
    $abs = ConvertTo-AbsPath $Folder
    if ([System.IO.Directory]::Exists($abs)) {
        $n = 0
        try {
            foreach ($e in [System.IO.Directory]::EnumerateFileSystemEntries($abs)) {
                $n++
                if ($n -gt 3000) { break }   # very large folders: only the first entries as context
                $list.Add(@{ Path = (ConvertTo-RelPath $e); IsFolder = [System.IO.Directory]::Exists($e) })
            }
        }
        catch { }
    }
    $S.Listing[$Folder] = $list
    return $list
}

function Get-PreviewPrimaryItem {
    # The item a row stands for: an item whose source or target is exactly this path.
    param($Node)
    foreach ($i in $Node.Items) {
        if ($i.Action -ne 'CreateFolder') { return $i }
    }
    return $null
}

function Build-PreviewModel {
    param($S)
    $plan = $S.Plan
    Update-PlanDerived $plan
    $nodes = @{}
    $addNode = {
        param([string]$Path, [bool]$IsFolder)
        $key = $Path.ToLowerInvariant()
        if (-not $nodes.ContainsKey($key)) {
            $nodes[$key] = @{ Path = $Path; IsFolder = $IsFolder; Items = (New-Object System.Collections.Generic.List[object]); InBefore = $false; InAfter = $false; Ghost = $false }
        }
        elseif ($IsFolder) { $nodes[$key].IsFolder = $true }
        return $nodes[$key]
    }
    $gone = New-PathSet
    $adds = New-PathSet
    $filter = $S.Filter
    foreach ($i in $plan.Items) {
        if ($i.Action -in @('RemoveEntry', 'RestoreEntry')) { continue }
        if ($null -ne $filter -and -not $i.Auto -and $i.Action -ne 'CreateFolder' -and -not (& $filter $i)) {
            # Hidden by the filter; its effect still counts for the before/after state.
            if ($i.Effective -and $i.Source) { [void]$gone.Add($i.Source) }
            if ($i.Effective -and $i.Target) { [void]$adds.Add($i.Target) }
            continue
        }
        switch ($i.Action) {
            'MoveFile' {
                (& $addNode $i.Source $false).Items.Add($i)
                (& $addNode $i.Target $false).Items.Add($i)
                if ($i.Effective) { [void]$gone.Add($i.Source); [void]$adds.Add($i.Target) }
            }
            'MoveFolder' {
                (& $addNode $i.Source $true).Items.Add($i)
                (& $addNode $i.Target $true).Items.Add($i)
                if ($i.Effective) { [void]$gone.Add($i.Source); [void]$adds.Add($i.Target) }
            }
            'CreateFolder' {
                (& $addNode $i.Target $true).Items.Add($i)
                if ($i.Effective) { [void]$adds.Add($i.Target) }
            }
            'CreateLink' {
                $path = $i.Target
                (& $addNode $path $false).Items.Add($i)
                if ($i.Effective) { [void]$adds.Add($path) }
            }
            'RemoveLink' {
                (& $addNode $i.Source $false).Items.Add($i)
                if ($i.Effective) { [void]$gone.Add($i.Source) }
            }
            'RemoveFolder' {
                (& $addNode $i.Source $true).Items.Add($i)
                if ($i.Effective) { [void]$gone.Add($i.Source) }
            }
            'Info' {
                $n = & $addNode $i.Source ([System.IO.Directory]::Exists((ConvertTo-AbsPath $i.Source)))
                $n.Items.Add($i)
            }
        }
    }
    # Context: the content of every folder that contains a change, plus the roots of the plan.
    $context = New-PathSet
    foreach ($n in @($nodes.Values)) {
        $p = Get-RelParent $n.Path
        if ($p) { [void]$context.Add($p) }
    }
    foreach ($r in $plan.Roots) { [void]$context.Add($r) }
    foreach ($c in $context) {
        if ((Get-RelRoot $c) -eq 'System') { continue }
        foreach ($child in (Get-PreviewListing $S $c)) { [void](& $addNode $child.Path $child.IsFolder) }
    }
    # Ancestors of everything.
    foreach ($n in @($nodes.Values)) {
        foreach ($a in (Get-RelAncestors $n.Path)) { [void](& $addNode $a $true) }
    }
    foreach ($r in $plan.Roots) {
        [void](& $addNode $r $true)
        foreach ($a in (Get-RelAncestors $r)) { [void](& $addNode $a $true) }
    }
    # Before / after state.
    foreach ($n in $nodes.Values) {
        $abs = ConvertTo-AbsPath $n.Path
        $n.InBefore = ([System.IO.File]::Exists($abs) -or [System.IO.Directory]::Exists($abs))
        if ($gone.Contains($n.Path)) { $n.InAfter = $false }
        elseif ($adds.Contains($n.Path)) { $n.InAfter = $true }
        else {
            $inside = $false
            foreach ($a in (Get-RelAncestors $n.Path)) { if ($gone.Contains($a)) { $inside = $true; break } }
            $n.InAfter = ($n.InBefore -and -not $inside)
        }
    }
    foreach ($n in @($nodes.Values)) {
        if ($n.InAfter) {
            foreach ($a in (Get-RelAncestors $n.Path)) { $nodes[$a.ToLowerInvariant()].InAfter = $true }
        }
    }
    foreach ($n in $nodes.Values) {
        if (-not $n.InBefore -and -not $n.InAfter) { $n.Ghost = $true }
    }
    # Check state per folder: counts of toggleable items below it.
    $agg = @{}
    $fileCount = @{}
    foreach ($i in $plan.Items) {
        if ($i.Action -in @('Info', 'RemoveEntry', 'RestoreEntry') -or $i.Locked) { continue }
        if ($i.ParentId -gt 0 -or $i.Auto) { continue }
        if ($i.Action -eq 'CreateFolder' -and -not $i.Force) { continue }
        $paths = New-PathSet
        foreach ($p in @($i.Source, $i.Target)) {
            if (-not $p) { continue }
            foreach ($a in (Get-RelAncestors $p)) { [void]$paths.Add($a) }
        }
        foreach ($p in $paths) {
            $k = $p.ToLowerInvariant()
            if (-not $agg.ContainsKey($k)) { $agg[$k] = @{ Checked = 0; Total = 0 } }
            $agg[$k].Total++
            if ($i.Checked) { $agg[$k].Checked++ }
        }
        if ($i.Action -eq 'MoveFile' -and $i.Effective) {
            foreach ($a in (Get-RelAncestors $i.Target)) {
                $k = $a.ToLowerInvariant()
                if ($fileCount.ContainsKey($k)) { $fileCount[$k]++ } else { $fileCount[$k] = 1 }
            }
        }
    }
    $S.Nodes = $nodes
    $S.Agg = $agg
    $S.FileCount = $fileCount
}

function Get-PreviewRows {
    # Turns the node tree into the list of visible rows (with collapsing).
    param($S)
    $nodes = $S.Nodes
    $children = @{}
    $top = New-Object System.Collections.Generic.List[object]
    foreach ($n in $nodes.Values) {
        $p = Get-RelParent $n.Path
        if (-not $p) { $top.Add($n); continue }
        $k = $p.ToLowerInvariant()
        if (-not $children.ContainsKey($k)) { $children[$k] = New-Object System.Collections.Generic.List[object] }
        $children[$k].Add($n)
    }
    $cmp = [System.StringComparer]::CurrentCultureIgnoreCase
    $sortNodes = {
        param($list)
        $order = @{ 'Input' = 0; 'Result' = 1; 'ToDelete' = 2 }
        return @($list | Sort-Object @{ Expression = { if ($order.ContainsKey($_.Path)) { $order[$_.Path] } else { 9 } } },
            @{ Expression = { -not $_.IsFolder } }, @{ Expression = { Get-RelName $_.Path } })
    }
    $all = New-Object System.Collections.Generic.List[object]
    $stack = New-Object System.Collections.Generic.Stack[object]
    $sortedTop = & $sortNodes $top
    for ($i = $sortedTop.Count - 1; $i -ge 0; $i--) { $stack.Push(@{ Node = $sortedTop[$i]; Depth = 0 }) }
    while ($stack.Count -gt 0) {
        $e = $stack.Pop()
        $n = $e.Node
        $state = 'Same'
        if ($n.Ghost) { $state = 'Ghost' }
        elseif ($n.InBefore -and -not $n.InAfter) { $state = 'Removed' }
        elseif (-not $n.InBefore -and $n.InAfter) { $state = 'Added' }
        $hasItem = $false
        foreach ($it in $n.Items) { if ($it.Action -ne 'CreateFolder' -or $it.Force) { $hasItem = $true } }
        $all.Add(@{ Kind = 'Node'; Node = $n; Depth = $e.Depth; State = $state; Key = ($state -ne 'Same' -or $hasItem) })
        $k = $n.Path.ToLowerInvariant()
        if ($n.IsFolder -and $children.ContainsKey($k) -and -not $S.CollapsedFolders.Contains($n.Path)) {
            $sorted = & $sortNodes $children[$k]
            for ($i = $sorted.Count - 1; $i -ge 0; $i--) { $stack.Push(@{ Node = $sorted[$i]; Depth = $e.Depth + 1 }) }
        }
    }
    # Visibility: changes, 2 rows of context, all ancestors of changes, the roots.
    $visible = New-Object bool[] $all.Count
    $index = @{}
    for ($i = 0; $i -lt $all.Count; $i++) { $index[$all[$i].Node.Path.ToLowerInvariant()] = $i }
    for ($i = 0; $i -lt $all.Count; $i++) {
        $r = $all[$i]
        if ($S.ExpandAll -or $r.Depth -eq 0) { $visible[$i] = $true }
        if (-not $r.Key) { continue }
        for ($j = [Math]::Max(0, $i - 2); $j -le [Math]::Min($all.Count - 1, $i + 2); $j++) { $visible[$j] = $true }
        foreach ($a in (Get-RelAncestors $r.Node.Path)) {
            $k = $a.ToLowerInvariant()
            if ($index.ContainsKey($k)) { $visible[$index[$k]] = $true }
        }
    }
    $rows = New-Object System.Collections.Generic.List[object]
    $i = 0
    while ($i -lt $all.Count) {
        if ($visible[$i]) { $rows.Add($all[$i]); $i++; continue }
        $start = $i
        while ($i -lt $all.Count -and -not $visible[$i]) { $i++ }
        $count = $i - $start
        if ($count -eq 1) { $rows.Add($all[$start]); continue }
        $runKey = $all[$start].Node.Path
        $expanded = $S.ExpandedRuns.Contains($runKey)
        $rows.Add(@{ Kind = 'Run'; RunKey = $runKey; Count = $count; Expanded = $expanded; Depth = $all[$start].Depth })
        if ($expanded) { for ($j = $start; $j -lt $i; $j++) { $rows.Add($all[$j]) } }
    }
    return , $rows
}

function Get-RowCheckValue {
    # $true / $false / $null (mixed) / 'none' (no checkbox)
    param($S, $Row)
    if ($Row.Kind -ne 'Node') { return 'none' }
    $n = $Row.Node
    $item = Get-PreviewPrimaryItem $n
    if ($null -ne $item) {
        if ($item.Action -eq 'Info') { return 'none' }
        if ($item.Locked) { return 'locked' }
        if ($item.ParentId -gt 0) {
            $parent = Get-PlanItemById $S.Plan $item.ParentId
            if ($parent) { return [bool]$parent.Checked }
        }
        return [bool]$item.Checked
    }
    if ($n.IsFolder) {
        $k = $n.Path.ToLowerInvariant()
        if ($S.Agg.ContainsKey($k)) {
            $a = $S.Agg[$k]
            if ($a.Checked -eq $a.Total) { return $true }
            if ($a.Checked -eq 0) { return $false }
            return $null
        }
    }
    foreach ($i in $n.Items) { if ($i.Action -eq 'CreateFolder' -and $i.Force) { return [bool]$i.Checked } }
    return 'none'
}

function Get-RowItem {
    # The item whose information, name field and dropdown are shown in this row.
    param($Row)
    if ($Row.Kind -ne 'Node') { return $null }
    $n = $Row.Node
    foreach ($i in $n.Items) {
        if ($i.Action -in @('MoveFile', 'MoveFolder', 'CreateLink') -and (Test-RelEqual $i.Target $n.Path)) { return $i }
    }
    foreach ($i in $n.Items) { if ($i.Action -ne 'CreateFolder') { return $i } }
    foreach ($i in $n.Items) { return $i }
    return $null
}

function Show-PlanPreview {
    param([Parameter(Mandatory)]$Plan)
    $S = @{
        Plan             = $Plan
        Listing          = @{}
        CollapsedFolders = (New-PathSet)
        ExpandedRuns     = (New-PathSet)
        ExpandAll        = $false
        Filter           = $null
        Thumbs           = @{}
        Rows             = $null
        Highlighted      = (New-Object System.Collections.Generic.List[int])
        Result           = $false
        Grid             = $null
        Summary          = $null
    }
    $hasEdit = @($Plan.Items | Where-Object { $_.EditMode }).Count -gt 0
    $hasChoice = @($Plan.Items | Where-Object { $_.Choices }).Count -gt 0

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Vorschau: $($Plan.Title)"
    $form.StartPosition = 'CenterParent'
    $form.Width = 1250
    $form.Height = 800
    $form.MinimumSize = New-Object System.Drawing.Size 800, 500
    $form.KeyPreview = $true

    # --- top bar ---
    $top = New-Object System.Windows.Forms.FlowLayoutPanel
    $top.Dock = 'Top'
    $top.AutoSize = $true
    $top.WrapContents = $true
    $top.Padding = New-Object System.Windows.Forms.Padding 6
    $title = New-Object System.Windows.Forms.Label
    $title.Text = $Plan.Title
    $title.AutoSize = $true
    $title.Font = New-Object System.Drawing.Font($form.Font.FontFamily, 11, [System.Drawing.FontStyle]::Bold)
    $title.Margin = New-Object System.Windows.Forms.Padding 3, 6, 20, 3
    $top.Controls.Add($title)
    $toggle = New-Object System.Windows.Forms.Button
    $toggle.Text = 'Alles ausklappen'
    $toggle.AutoSize = $true
    $toggle.Add_Click({
            $S.ExpandAll = -not $S.ExpandAll
            if ($S.ExpandAll) { $this.Text = 'Unverändertes einklappen' } else { $this.Text = 'Alles ausklappen'; $S.ExpandedRuns.Clear() }
            & $S.Refresh
        })
    $top.Controls.Add($toggle)
    $acceptAll = New-Object System.Windows.Forms.Button
    $acceptAll.Text = 'Alle annehmen'
    $acceptAll.AutoSize = $true
    $acceptAll.Add_Click({
            foreach ($i in $S.Plan.Items) { if (-not $i.Locked -and $i.Action -ne 'Info' -and -not $i.Auto) { $i.Checked = $true } }
            $S.Plan.AutoUnchecked.Clear()
            & $S.Refresh
        })
    $top.Controls.Add($acceptAll)
    $rejectAll = New-Object System.Windows.Forms.Button
    $rejectAll.Text = 'Alle ablehnen'
    $rejectAll.AutoSize = $true
    $rejectAll.Add_Click({
            foreach ($i in $S.Plan.Items) { if ($i.Action -ne 'Info' -and -not $i.Auto) { $i.Checked = $false } }
            & $S.Refresh
        })
    $top.Controls.Add($rejectAll)
    if ($Plan.Filters.Count -gt 0) {
        $filterLabel = New-Object System.Windows.Forms.Label
        $filterLabel.Text = 'Filter:'
        $filterLabel.AutoSize = $true
        $filterLabel.Margin = New-Object System.Windows.Forms.Padding 20, 8, 3, 3
        $top.Controls.Add($filterLabel)
        $filterBox = New-Object System.Windows.Forms.ComboBox
        $filterBox.DropDownStyle = 'DropDownList'
        $filterBox.Width = 180
        [void]$filterBox.Items.Add('Alle')
        foreach ($f in $Plan.Filters) { [void]$filterBox.Items.Add($f.Label) }
        $filterBox.SelectedIndex = 0
        $filterBox.Add_SelectedIndexChanged({
                if ($this.SelectedIndex -le 0) { $S.Filter = $null }
                else { $S.Filter = $S.Plan.Filters[$this.SelectedIndex - 1].Test }
                & $S.Refresh
            })
        $top.Controls.Add($filterBox)
    }
    if ($Plan.Notice) {
        $notice = New-Object System.Windows.Forms.Label
        $notice.Text = $Plan.Notice
        $notice.AutoSize = $true
        $notice.ForeColor = [System.Drawing.Color]::DimGray
        $notice.Margin = New-Object System.Windows.Forms.Padding 20, 8, 3, 3
        $top.Controls.Add($notice)
    }
    $extPanel = $null
    if ($Plan.ExtendPreview) {
        $extPanel = New-Object System.Windows.Forms.FlowLayoutPanel
        $extPanel.Dock = 'Top'
        $extPanel.AutoSize = $true
        $extPanel.Padding = New-Object System.Windows.Forms.Padding 6, 0, 6, 4
    }

    # --- grid ---
    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Dock = 'Fill'
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.RowHeadersVisible = $false
    $grid.SelectionMode = 'FullRowSelect'
    $grid.MultiSelect = $false
    $grid.EditMode = 'EditOnEnter'
    $grid.BackgroundColor = [System.Drawing.Color]::White
    $grid.BorderStyle = 'None'
    $grid.CellBorderStyle = 'SingleHorizontal'
    $grid.GridColor = [System.Drawing.Color]::FromArgb(255, 235, 235, 235)
    $grid.DefaultCellStyle.Font = New-Object System.Drawing.Font('Consolas', 9)
    $grid.DefaultCellStyle.SelectionBackColor = $global:ST.PreviewColors.Select
    $grid.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::Black
    $grid.AutoSizeRowsMode = 'None'
    $grid.RowTemplate.Height = $(if ($Plan.ShowThumbnails) { 52 } else { 22 })
    $type = $grid.GetType()
    $prop = $type.GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic')
    $prop.SetValue($grid, $true, $null)

    $colCheck = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $colCheck.Name = 'Check'
    $colCheck.HeaderText = ''
    $colCheck.Width = 30
    $colCheck.ThreeState = $true
    $colCheck.ReadOnly = $true
    [void]$grid.Columns.Add($colCheck)
    if ($Plan.ShowThumbnails) {
        $colThumb = New-Object System.Windows.Forms.DataGridViewImageColumn
        $colThumb.Name = 'Thumb'
        $colThumb.HeaderText = ''
        $colThumb.Width = 56
        $colThumb.ImageLayout = 'Zoom'
        $colThumb.ReadOnly = $true
        $colThumb.DefaultCellStyle.NullValue = $null
        [void]$grid.Columns.Add($colThumb)
    }
    foreach ($c in @(@('Before', 'Vorher'), @('After', 'Nachher'), @('Info', 'Hinweis'))) {
        $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $col.Name = $c[0]
        $col.HeaderText = $c[1]
        $col.ReadOnly = $true
        $col.SortMode = 'NotSortable'
        [void]$grid.Columns.Add($col)
    }
    $grid.Columns['Before'].AutoSizeMode = 'Fill'
    $grid.Columns['After'].AutoSizeMode = 'Fill'
    $grid.Columns['Info'].Width = 280
    if ($hasEdit) {
        $colEdit = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $colEdit.Name = 'Edit'
        $colEdit.HeaderText = $Plan.EditLabel
        $colEdit.Width = 220
        $colEdit.SortMode = 'NotSortable'
        [void]$grid.Columns.Add($colEdit)
    }
    if ($hasChoice) {
        $colChoice = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $colChoice.Name = 'Choice'
        $colChoice.HeaderText = $Plan.ChoiceLabel
        $colChoice.Width = 200
        $colChoice.SortMode = 'NotSortable'
        [void]$grid.Columns.Add($colChoice)
    }
    foreach ($col in $grid.Columns) { $col.SortMode = 'NotSortable' }

    # --- bottom ---
    $bottom = New-Object System.Windows.Forms.Panel
    $bottom.Dock = 'Bottom'
    $bottom.Height = 48
    $summary = New-Object System.Windows.Forms.Label
    $summary.AutoSize = $false
    $summary.Dock = 'Fill'
    $summary.TextAlign = 'MiddleLeft'
    $summary.Padding = New-Object System.Windows.Forms.Padding 8, 0, 0, 0
    $buttons = New-Object System.Windows.Forms.FlowLayoutPanel
    $buttons.Dock = 'Right'
    $buttons.FlowDirection = 'RightToLeft'
    $buttons.Width = 260
    $buttons.Padding = New-Object System.Windows.Forms.Padding 4, 8, 4, 4
    $run = New-Object System.Windows.Forms.Button
    $run.Text = 'Ausführen'
    $run.Size = New-Object System.Drawing.Size 110, 30
    $run.Add_Click({ $S.Result = $true; $this.FindForm().Close() })
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Abbrechen'
    $cancel.Size = New-Object System.Drawing.Size 110, 30
    $cancel.Add_Click({ $S.Result = $false; $this.FindForm().Close() })
    $buttons.Controls.AddRange(@($cancel, $run))
    $bottom.Controls.Add($summary)
    $bottom.Controls.Add($buttons)

    $form.Controls.Add($grid)
    if ($extPanel) { $form.Controls.Add($extPanel) }
    $form.Controls.Add($top)
    $form.Controls.Add($bottom)
    $form.CancelButton = $cancel
    $S.Grid = $grid
    $S.Summary = $summary
    $S.Form = $form

    # --- rendering ---
    $S.ApplyRowStyle = {
        param($gridRow, $desc, [bool]$highlight)
        $colors = $global:ST.PreviewColors
        $before = $gridRow.Cells['Before']
        $after = $gridRow.Cells['After']
        $before.Style.BackColor = $colors.White
        $after.Style.BackColor = $colors.White
        if ($desc.Kind -eq 'Run') {
            foreach ($cell in $gridRow.Cells) { $cell.Style.BackColor = $colors.Summary; $cell.Style.ForeColor = [System.Drawing.Color]::DimGray }
            return
        }
        switch ($desc.State) {
            'Removed' { $before.Style.BackColor = $colors.Red }
            'Added' { $after.Style.BackColor = $colors.Green }
            'Ghost' { $after.Style.ForeColor = $colors.Grey }
        }
        $item = Get-RowItem $desc
        if ($item -and ($item.Weak -or ($item.Locked -and $item.Action -ne 'Info'))) {
            $font = New-Object System.Drawing.Font('Consolas', 9, [System.Drawing.FontStyle]::Italic)
            foreach ($cell in $gridRow.Cells) { $cell.Style.Font = $font; $cell.Style.ForeColor = $colors.Grey }
        }
        if ($highlight) {
            $before.Style.BackColor = $colors.Select
            $after.Style.BackColor = $colors.Select
        }
    }
    $S.Refresh = {
        $grid = $S.Grid
        $first = 0
        try { if ($grid.RowCount -gt 0) { $first = $grid.FirstDisplayedScrollingRowIndex } } catch { }
        Build-PreviewModel $S
        $S.Rows = Get-PreviewRows $S
        $S.Highlighted.Clear()
        $grid.SuspendLayout()
        $grid.Rows.Clear()
        $hasThumb = $grid.Columns.Contains('Thumb')
        $hasEditCol = $grid.Columns.Contains('Edit')
        $hasChoiceCol = $grid.Columns.Contains('Choice')
        $gridRows = New-Object System.Collections.Generic.List[System.Windows.Forms.DataGridViewRow]
        foreach ($desc in $S.Rows) {
            $r = New-Object System.Windows.Forms.DataGridViewRow
            $r.CreateCells($grid)
            $r.Tag = $desc
            $indent = ''
            if ($desc.Depth -gt 0) { $indent = '    ' * $desc.Depth }
            if ($desc.Kind -eq 'Run') {
                $arrow = '▸'
                if ($desc.Expanded) { $arrow = '▾' }
                $text = "$indent$arrow $($desc.Count) unveränderte Einträge"
                $r.Cells[$grid.Columns['Before'].Index].Value = $text
                $r.Cells[$grid.Columns['After'].Index].Value = $text
                $r.Cells[0].Value = $null
                $r.Cells[0] = New-Object System.Windows.Forms.DataGridViewTextBoxCell
                $gridRows.Add($r)
                continue
            }
            $n = $desc.Node
            $name = Get-RelName $n.Path
            if ($n.IsFolder) {
                $arrow = '▾'
                if ($S.CollapsedFolders.Contains($n.Path)) { $arrow = '▸' }
                $name = "$arrow $name"
            }
            $afterName = $name
            $k = $n.Path.ToLowerInvariant()
            if ($n.IsFolder -and $desc.State -eq 'Added' -and $S.FileCount.ContainsKey($k)) {
                $cnt = $S.FileCount[$k]
                if ($cnt -eq 1) { $afterName = "$name (1 Datei)" } else { $afterName = "$name ($cnt Dateien)" }
            }
            if ($n.InBefore) { $r.Cells[$grid.Columns['Before'].Index].Value = $indent + $name }
            if ($n.InAfter -or $n.Ghost) { $r.Cells[$grid.Columns['After'].Index].Value = $indent + $afterName }
            $check = Get-RowCheckValue $S $desc
            if ($check -is [string]) {
                $r.Cells[0] = New-Object System.Windows.Forms.DataGridViewTextBoxCell
                if ($check -eq 'locked') { $r.Cells[0].Value = '⚠' } else { $r.Cells[0].Value = '' }
            }
            elseif ($null -eq $check) { $r.Cells[0].Value = [System.Windows.Forms.CheckState]::Indeterminate }
            elseif ($check) { $r.Cells[0].Value = [System.Windows.Forms.CheckState]::Checked }
            else { $r.Cells[0].Value = [System.Windows.Forms.CheckState]::Unchecked }
            $item = Get-RowItem $desc
            if ($item) {
                $info = $item.Info
                if ($item.Locked -and $item.Conflict -and -not $info) { $info = $item.Conflict }
                $r.Cells[$grid.Columns['Info'].Index].Value = $info
                $isTargetRow = (Test-RelEqual $item.Target $n.Path)
                if ($hasEditCol) {
                    $cell = $r.Cells[$grid.Columns['Edit'].Index]
                    if ($item.EditMode -and $isTargetRow -and -not $item.Locked) { $cell.Value = $item.EditValue; $cell.ReadOnly = $false }
                    else { $cell.ReadOnly = $true }
                }
                if ($hasChoiceCol) {
                    $idx = $grid.Columns['Choice'].Index
                    if ($item.Choices -and $isTargetRow -and -not $item.Locked) {
                        $combo = New-Object System.Windows.Forms.DataGridViewComboBoxCell
                        foreach ($c in $item.Choices) { [void]$combo.Items.Add([string]$c) }
                        $combo.DisplayStyle = 'DropDownButton'
                        $combo.FlatStyle = 'Flat'
                        $r.Cells[$idx] = $combo
                        if ($item.Choice -and $item.Choices -contains $item.Choice) { $combo.Value = [string]$item.Choice }
                        $combo.ReadOnly = $false
                    }
                    else { $r.Cells[$idx].ReadOnly = $true }
                }
                if ($hasThumb -and $item.Thumbnail -and ($isTargetRow -or -not $item.Target)) {
                    $r.Cells[$grid.Columns['Thumb'].Index].Tag = $item.Thumbnail
                }
            }
            else {
                if ($hasEditCol) { $r.Cells[$grid.Columns['Edit'].Index].ReadOnly = $true }
                if ($hasChoiceCol) { $r.Cells[$grid.Columns['Choice'].Index].ReadOnly = $true }
            }
            $gridRows.Add($r)
        }
        $grid.Rows.AddRange($gridRows.ToArray())
        for ($i = 0; $i -lt $grid.Rows.Count; $i++) {
            & $S.ApplyRowStyle $grid.Rows[$i] $grid.Rows[$i].Tag $false
        }
        $grid.ResumeLayout()
        if ($first -gt 0 -and $first -lt $grid.RowCount) { try { $grid.FirstDisplayedScrollingRowIndex = $first } catch { } }
        $counts = Get-PlanCounts $S.Plan
        $text = "Angenommen: $($counts.Accepted)   Abgelehnt: $($counts.Rejected)   Konflikte: $($counts.Conflicts)"
        if ($S.Plan.SummaryExtra) { $text += '   ' + (& $S.Plan.SummaryExtra $S.Plan) }
        $S.Summary.Text = $text
    }

    $S.ToggleRow = {
        param($desc)
        if ($desc.Kind -ne 'Node') { return }
        $n = $desc.Node
        $item = Get-PreviewPrimaryItem $n
        if ($null -ne $item) {
            if ($item.Action -eq 'Info' -or $item.Locked) { return }
            if ($item.ParentId -gt 0) {
                $parent = Get-PlanItemById $S.Plan $item.ParentId
                if ($parent -and -not $parent.Locked) { $parent.Checked = -not $parent.Checked }
            }
            elseif ($item.Auto) {
                if ($S.Plan.AutoUnchecked.Contains($item.Source)) { [void]$S.Plan.AutoUnchecked.Remove($item.Source) }
                else { [void]$S.Plan.AutoUnchecked.Add($item.Source) }
            }
            else { $item.Checked = -not $item.Checked }
            & $S.Refresh
            return
        }
        $value = Get-RowCheckValue $S $desc
        if ($value -is [string]) { return }
        $newValue = ($value -ne $true)
        foreach ($i in $S.Plan.Items) {
            if ($i.Locked -or $i.Action -eq 'Info' -or $i.Auto -or $i.ParentId -gt 0) { continue }
            $under = $false
            if ($i.Source -and (Test-RelUnderOrEqual $i.Source $n.Path)) { $under = $true }
            if ($i.Target -and (Test-RelUnderOrEqual $i.Target $n.Path)) { $under = $true }
            if ($under) { $i.Checked = $newValue }
        }
        if ($S.Plan.OnFolderToggled) { & $S.Plan.OnFolderToggled $S.Plan $n.Path $newValue }
        & $S.Refresh
    }

    $grid.Add_CellContentClick({
            param($sender, $e)
            if ($e.RowIndex -lt 0 -or $e.ColumnIndex -ne 0) { return }
            & $S.ToggleRow $S.Grid.Rows[$e.RowIndex].Tag
        })
    $grid.Add_KeyDown({
            param($sender, $e)
            if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Space -and $S.Grid.CurrentRow -and -not $S.Grid.IsCurrentCellInEditMode) {
                & $S.ToggleRow $S.Grid.CurrentRow.Tag
                $e.Handled = $true
            }
        })
    $grid.Add_CellClick({
            param($sender, $e)
            if ($e.RowIndex -lt 0) { return }
            $desc = $S.Grid.Rows[$e.RowIndex].Tag
            if ($desc.Kind -eq 'Run') {
                if ($S.ExpandedRuns.Contains($desc.RunKey)) { [void]$S.ExpandedRuns.Remove($desc.RunKey) } else { [void]$S.ExpandedRuns.Add($desc.RunKey) }
                & $S.Refresh
            }
        })
    $grid.Add_CellDoubleClick({
            param($sender, $e)
            if ($e.RowIndex -lt 0) { return }
            $desc = $S.Grid.Rows[$e.RowIndex].Tag
            if ($desc.Kind -eq 'Node' -and $desc.Node.IsFolder) {
                $col = $S.Grid.Columns[$e.ColumnIndex].Name
                if ($col -eq 'Edit' -or $col -eq 'Choice') { return }
                $p = $desc.Node.Path
                if ($S.CollapsedFolders.Contains($p)) { [void]$S.CollapsedFolders.Remove($p) } else { [void]$S.CollapsedFolders.Add($p) }
                & $S.Refresh
            }
        })
    $grid.Add_SelectionChanged({
            $g = $S.Grid
            foreach ($idx in $S.Highlighted) {
                if ($idx -lt $g.Rows.Count) { & $S.ApplyRowStyle $g.Rows[$idx] $g.Rows[$idx].Tag $false }
            }
            $S.Highlighted.Clear()
            if ($g.SelectedRows.Count -eq 0) { return }
            $desc = $g.SelectedRows[0].Tag
            if ($desc.Kind -ne 'Node') { return }
            $ids = @($desc.Node.Items | ForEach-Object { $_.Id })
            if ($ids.Count -eq 0) { return }
            for ($i = 0; $i -lt $g.Rows.Count; $i++) {
                if ($i -eq $g.SelectedRows[0].Index) { continue }
                $d = $g.Rows[$i].Tag
                if ($d.Kind -ne 'Node') { continue }
                foreach ($it in $d.Node.Items) {
                    if ($ids -contains $it.Id) {
                        & $S.ApplyRowStyle $g.Rows[$i] $d $true
                        $S.Highlighted.Add($i)
                        break
                    }
                }
            }
        })
    $grid.Add_CurrentCellDirtyStateChanged({
            if ($S.Grid.IsCurrentCellDirty -and $S.Grid.CurrentCell -is [System.Windows.Forms.DataGridViewComboBoxCell]) {
                [void]$S.Grid.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit)
            }
        })
    $grid.Add_DataError({ param($sender, $e) $e.ThrowException = $false })
    $grid.Add_CellValueChanged({
            param($sender, $e)
            if ($e.RowIndex -lt 0 -or $S.Busy) { return }
            $g = $S.Grid
            $colName = $g.Columns[$e.ColumnIndex].Name
            if ($colName -ne 'Edit' -and $colName -ne 'Choice') { return }
            $desc = $g.Rows[$e.RowIndex].Tag
            $item = Get-RowItem $desc
            if ($null -eq $item) { return }
            $value = [string]$g.Rows[$e.RowIndex].Cells[$e.ColumnIndex].Value
            if ($colName -eq 'Edit') {
                $clean = $value.Trim()
                $reason = $null
                if ($clean) { $reason = Get-InvalidNameReason $clean }
                if ($reason) {
                    Show-ErrorMessage $reason
                    $S.Busy = $true
                    $g.Rows[$e.RowIndex].Cells[$e.ColumnIndex].Value = $item.EditValue
                    $S.Busy = $false
                    return
                }
                $item.EditValue = $clean
            }
            else {
                $item.Choice = $value
            }
            if ($S.Plan.OnItemEdited) { & $S.Plan.OnItemEdited $S.Plan $item }
            $S.Busy = $true
            $S.Form.BeginInvoke([System.Action] { & $S.Refresh; $S.Busy = $false }) | Out-Null
        })
    if ($Plan.ShowThumbnails) {
        $grid.Add_CellFormatting({
                param($sender, $e)
                if ($e.RowIndex -lt 0) { return }
                if ($S.Grid.Columns[$e.ColumnIndex].Name -ne 'Thumb') { return }
                $cell = $S.Grid.Rows[$e.RowIndex].Cells[$e.ColumnIndex]
                $path = [string]$cell.Tag
                if (-not $path) { return }
                if (-not $S.Thumbs.ContainsKey($path)) {
                    $S.Thumbs[$path] = New-ThumbnailBitmap -Path (ConvertTo-AbsPath $path) -Size 48
                }
                if ($S.Thumbs[$path]) { $e.Value = $S.Thumbs[$path]; $e.FormattingApplied = $true }
            })
    }
    if ($Plan.FolderMenu.Count -gt 0) {
        $menu = New-Object System.Windows.Forms.ContextMenuStrip
        foreach ($entry in $Plan.FolderMenu) {
            $mi = New-Object System.Windows.Forms.ToolStripMenuItem $entry.Label
            $mi.Tag = $entry
            $mi.Add_Click({
                    $path = $S.MenuPath
                    if ($path) { & $this.Tag.Action $S.Plan $path $S; & $S.Refresh }
                })
            [void]$menu.Items.Add($mi)
        }
        $grid.Add_CellMouseDown({
                param($sender, $e)
                if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Right -or $e.RowIndex -lt 0) { return }
                $desc = $S.Grid.Rows[$e.RowIndex].Tag
                if ($desc.Kind -ne 'Node' -or -not $desc.Node.IsFolder) { return }
                $S.Grid.ClearSelection()
                $S.Grid.Rows[$e.RowIndex].Selected = $true
                $S.MenuPath = $desc.Node.Path
                $S.Menu.Show([System.Windows.Forms.Cursor]::Position)
            })
        $S.Menu = $menu
    }
    $form.Add_KeyDown({
            param($sender, $e)
            if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $S.Result = $false; $S.Form.Close() }
        })

    if ($extPanel) { & $Plan.ExtendPreview $Plan $extPanel $S }
    $form.Add_Shown({ & $S.Refresh })
    [void]$form.ShowDialog((Get-OwnerForm))
    foreach ($bmp in $S.Thumbs.Values) { if ($bmp) { $bmp.Dispose() } }
    $form.Dispose()
    return [bool]$S.Result
}
