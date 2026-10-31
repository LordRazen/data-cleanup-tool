# Explorer.ps1
# File explorer in the main window (base section 11): two separate areas, left Input, right Result.
# Each area has a path line with "Eine Ebene hoch", its own view switch (Liste / Ordneransicht),
# thumbnails for images, rename (F2), drag and drop within and between the areas, double-click to
# open, multi-selection, F5 to refresh. Renaming and moving by hand run at once, without preview,
# but are logged and can be undone ("Explorer - Rename" / "Explorer - Move").
# System and ToDelete are not shown. There is no delete.

$explorerSorterSource = @'
using System;
using System.Collections;
using System.Windows.Forms;

namespace SortingTool
{
    public class ListViewSorter : IComparer
    {
        public int Column;
        public bool Ascending = true;
        public int Compare(object x, object y)
        {
            ListViewItem a = (ListViewItem)x;
            ListViewItem b = (ListViewItem)y;
            int r;
            object ta = Column < a.SubItems.Count ? a.SubItems[Column].Tag : null;
            object tb = Column < b.SubItems.Count ? b.SubItems[Column].Tag : null;
            if (ta is IComparable && tb != null && ta.GetType() == tb.GetType())
                r = ((IComparable)ta).CompareTo(tb);
            else
            {
                string sa = Column < a.SubItems.Count ? a.SubItems[Column].Text : "";
                string sb = Column < b.SubItems.Count ? b.SubItems[Column].Text : "";
                r = String.Compare(sa, sb, StringComparison.CurrentCultureIgnoreCase);
            }
            return Ascending ? r : -r;
        }
    }
}
'@
if (-not ('SortingTool.ListViewSorter' -as [type])) {
    Add-Type -TypeDefinition $explorerSorterSource -ReferencedAssemblies System.Windows.Forms
}

function New-FolderBitmap {
    param([int]$Size)
    $bmp = New-Object System.Drawing.Bitmap $Size, $Size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)
    $w = $Size * 0.8; $h = $Size * 0.6; $x = $Size * 0.1; $y = $Size * 0.25
    $tab = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 230, 180, 60))
    $body = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 250, 205, 90))
    $g.FillRectangle($tab, [float]$x, [float]($y - $Size * 0.08), [float]($w * 0.4), [float]($Size * 0.12))
    $g.FillRectangle($body, [float]$x, [float]$y, [float]$w, [float]$h)
    $g.Dispose(); $tab.Dispose(); $body.Dispose()
    return $bmp
}

function Get-ExtensionIconKey {
    # Windows icon of a file type, cached per extension in the image list of a pane.
    param($Pane, [string]$AbsPath)
    $ext = [System.IO.Path]::GetExtension($AbsPath).ToLowerInvariant()
    $key = "ext:$ext"
    if (-not $Pane.Images.Images.ContainsKey($key)) {
        $bmp = $null
        try {
            $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($AbsPath)
            $size = $Pane.Images.ImageSize.Width
            $bmp = New-Object System.Drawing.Bitmap $size, $size
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.Clear([System.Drawing.Color]::Transparent)
            $iconBmp = $icon.ToBitmap()
            $s = [Math]::Min($size, 48)
            $g.DrawImage($iconBmp, [int](($size - $s) / 2), [int](($size - $s) / 2), $s, $s)
            $g.Dispose(); $iconBmp.Dispose(); $icon.Dispose()
        }
        catch { }
        if ($null -eq $bmp) { $bmp = New-Object System.Drawing.Bitmap 16, 16 }
        $Pane.Images.Images.Add($key, $bmp)
    }
    return $key
}

function Format-FileSize {
    param([long]$Bytes)
    if ($Bytes -lt 1024) { return "$Bytes B" }
    if ($Bytes -lt 1MB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    if ($Bytes -lt 1GB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    return ('{0:N2} GB' -f ($Bytes / 1GB))
}

function New-ExplorerPane {
    param([Parameter(Mandatory)][ValidateSet('Input', 'Result')][string]$Root)
    $view = [string]$global:ST.Settings."explorerView$Root"
    if ($view -ne 'List' -and $view -ne 'Folder') { $view = 'Folder' }
    $pane = @{ Root = $Root; Current = $Root; View = $view; Pending = (New-Object System.Collections.Generic.List[object]); ScanIndex = 0 }

    $panel = New-Object System.Windows.Forms.Panel
    $panel.Dock = 'Fill'

    $toolbar = New-Object System.Windows.Forms.FlowLayoutPanel
    $toolbar.Dock = 'Top'
    $toolbar.AutoSize = $true
    $toolbar.WrapContents = $false
    $title = New-Object System.Windows.Forms.Label
    $title.Text = $Root
    $title.AutoSize = $true
    $title.Font = New-Object System.Drawing.Font($title.Font.FontFamily, 10, [System.Drawing.FontStyle]::Bold)
    $title.Margin = New-Object System.Windows.Forms.Padding 3, 7, 10, 3
    $up = New-Object System.Windows.Forms.Button
    $up.Text = 'Eine Ebene hoch'
    $up.AutoSize = $true
    $listButton = New-Object System.Windows.Forms.Button
    $listButton.Text = 'Liste'
    $listButton.AutoSize = $true
    $folderButton = New-Object System.Windows.Forms.Button
    $folderButton.Text = 'Ordneransicht'
    $folderButton.AutoSize = $true
    $refresh = New-Object System.Windows.Forms.Button
    $refresh.Text = 'Aktualisieren'
    $refresh.AutoSize = $true
    $toolbar.Controls.AddRange(@($title, $up, $listButton, $folderButton, $refresh))

    $pathBar = New-Object System.Windows.Forms.FlowLayoutPanel
    $pathBar.Dock = 'Top'
    $pathBar.Height = 26
    $pathBar.WrapContents = $false
    $pathBar.AutoScroll = $false
    $pathBar.BackColor = [System.Drawing.Color]::FromArgb(255, 245, 246, 248)

    $list = New-Object System.Windows.Forms.ListView
    $list.Dock = 'Fill'
    $list.HideSelection = $false
    $list.MultiSelect = $true
    $list.LabelEdit = $true
    $list.AllowDrop = $true
    $list.FullRowSelect = $true
    $sorter = New-Object SortingTool.ListViewSorter
    $sorter.Column = 0

    $size = [int]$global:ST.Settings.thumbnailSize
    if ($size -lt 32) { $size = 32 }
    if ($size -gt 256) { $size = 256 }
    $images = New-Object System.Windows.Forms.ImageList
    $images.ColorDepth = [System.Windows.Forms.ColorDepth]::Depth32Bit
    $images.ImageSize = New-Object System.Drawing.Size $size, $size
    $images.Images.Add('folder', (New-FolderBitmap $size))
    $list.LargeImageList = $images

    $panel.Controls.Add($list)
    $panel.Controls.Add($pathBar)
    $panel.Controls.Add($toolbar)

    $pane.Panel = $panel
    $pane.List = $list
    $pane.PathBar = $pathBar
    $pane.UpButton = $up
    $pane.ListButton = $listButton
    $pane.FolderButton = $folderButton
    $pane.Images = $images
    $pane.Sorter = $sorter
    foreach ($c in @($list, $up, $listButton, $folderButton, $refresh, $pathBar)) { $c.Tag = $pane }

    $up.Add_Click({
            $p = $this.Tag
            if (-not (Test-RelEqual $p.Current $p.Root)) { $p.Current = Get-RelParent $p.Current; Update-ExplorerPane $p }
        })
    $listButton.Add_Click({ Set-ExplorerView $this.Tag 'List' })
    $folderButton.Add_Click({ Set-ExplorerView $this.Tag 'Folder' })
    $refresh.Add_Click({ Update-Explorer })

    $list.Add_DoubleClick({
            $p = $this.Tag
            if ($this.SelectedItems.Count -ne 1) { return }
            $info = $this.SelectedItems[0].Tag
            if ($info.IsFolder) { $p.Current = $info.Rel; Update-ExplorerPane $p }
            else {
                try { Invoke-Item -LiteralPath (ConvertTo-AbsPath $info.Rel) }
                catch { Show-ErrorMessage "Die Datei konnte nicht geöffnet werden: $($_.Exception.Message)" }
            }
        })
    $list.Add_KeyDown({
            param($sender, $e)
            $p = $this.Tag
            if ($e.KeyCode -eq [System.Windows.Forms.Keys]::F5) { Update-Explorer; $e.Handled = $true }
            elseif ($e.KeyCode -eq [System.Windows.Forms.Keys]::F2) {
                if (-not $global:ST.Busy -and $this.SelectedItems.Count -eq 1) { $this.SelectedItems[0].BeginEdit() }
                $e.Handled = $true
            }
            elseif ($e.Control -and $e.KeyCode -eq [System.Windows.Forms.Keys]::A) {
                $this.BeginUpdate()
                foreach ($it in $this.Items) { $it.Selected = $true }
                $this.EndUpdate()
                $e.Handled = $true
            }
            elseif ($e.KeyCode -eq [System.Windows.Forms.Keys]::Back) {
                if (-not (Test-RelEqual $p.Current $p.Root)) { $p.Current = Get-RelParent $p.Current; Update-ExplorerPane $p }
                $e.Handled = $true
            }
            elseif ($e.KeyCode -eq [System.Windows.Forms.Keys]::Delete) {
                # No delete in the explorer (base section 11).
                $e.Handled = $true
            }
        })
    $list.Add_ColumnClick({
            param($sender, $e)
            $p = $this.Tag
            if ($p.Sorter.Column -eq $e.Column) { $p.Sorter.Ascending = -not $p.Sorter.Ascending }
            else { $p.Sorter.Column = $e.Column; $p.Sorter.Ascending = $true }
            $this.ListViewItemSorter = $p.Sorter
            $this.Sort()
        })
    $list.Add_BeforeLabelEdit({
            param($sender, $e)
            if ($global:ST.Busy) { $e.CancelEdit = $true }
        })
    $list.Add_AfterLabelEdit({
            param($sender, $e)
            $e.CancelEdit = $true
            if ($null -eq $e.Label) { return }
            # The rename runs after the edit has ended, so the list can be refreshed safely.
            $global:ST.PendingRename = @{ Pane = $this.Tag; Item = $this.Items[$e.Item]; Name = $e.Label }
            $this.BeginInvoke([System.Action] {
                    $r = $global:ST.PendingRename
                    $global:ST.PendingRename = $null
                    if ($r) { Invoke-ExplorerRename -Pane $r.Pane -Item $r.Item -NewName $r.Name }
                }) | Out-Null
        })
    $list.Add_ItemDrag({
            param($sender, $e)
            if ($global:ST.Busy) { return }
            $paths = New-Object System.Collections.Generic.List[string]
            foreach ($it in $this.SelectedItems) { $paths.Add($it.Tag.Rel) }
            if ($paths.Count -eq 0) { return }
            $data = New-Object System.Windows.Forms.DataObject
            $data.SetData('SortingToolPaths', [string[]]$paths.ToArray())
            [void]$this.DoDragDrop($data, [System.Windows.Forms.DragDropEffects]::Move)
        })
    $list.Add_DragOver({
            param($sender, $e)
            $e.Effect = [System.Windows.Forms.DragDropEffects]::None
            if ($global:ST.Busy -or -not $e.Data.GetDataPresent('SortingToolPaths')) { return }
            $p = $this.Tag
            if ($p.View -ne 'Folder') { return }   # nothing can be dropped in the list view
            $target = Get-ExplorerDropTarget -Pane $p -ScreenX $e.X -ScreenY $e.Y
            if ($target) { $e.Effect = [System.Windows.Forms.DragDropEffects]::Move }
        })
    $list.Add_DragDrop({
            param($sender, $e)
            $p = $this.Tag
            if ($p.View -ne 'Folder') { return }
            $target = Get-ExplorerDropTarget -Pane $p -ScreenX $e.X -ScreenY $e.Y
            if (-not $target) { return }
            $paths = [string[]]$e.Data.GetData('SortingToolPaths')
            Request-ExplorerMove -Paths $paths -TargetFolder $target
        })

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 150
    $timer.Tag = $pane
    $timer.Add_Tick({ Update-ExplorerThumbnails $this.Tag })
    $timer.Start()
    $pane.Timer = $timer
    return $pane
}

function Get-ExplorerDropTarget {
    # Folder under the mouse, or the open folder when dropped on free space.
    param($Pane, [int]$ScreenX, [int]$ScreenY)
    $pt = $Pane.List.PointToClient((New-Object System.Drawing.Point $ScreenX, $ScreenY))
    $item = $Pane.List.GetItemAt($pt.X, $pt.Y)
    if ($item) {
        if ($item.Tag.IsFolder -and -not $item.Selected) { return $item.Tag.Rel }
        if ($item.Tag.IsFolder) { return $null }
    }
    return $Pane.Current
}

function Set-ExplorerView {
    param($Pane, [string]$View)
    if ($Pane.View -eq $View) { return }
    $Pane.View = $View
    Save-ToolSetting -Key "explorerView$($Pane.Root)" -Value $View
    Update-ExplorerPane $Pane
}

function Update-ExplorerPathBar {
    param($Pane)
    $bar = $Pane.PathBar
    $bar.SuspendLayout()
    foreach ($c in @($bar.Controls)) { $c.Dispose() }
    $bar.Controls.Clear()
    $parts = $Pane.Current.Split('/')
    for ($i = 0; $i -lt $parts.Count; $i++) {
        $rel = ($parts[0..$i] -join '/')
        if ($i -gt 0) {
            $sep = New-Object System.Windows.Forms.Label
            $sep.Text = '›'
            $sep.AutoSize = $true
            $sep.Margin = New-Object System.Windows.Forms.Padding 0, 5, 0, 0
            $bar.Controls.Add($sep)
        }
        $link = New-Object System.Windows.Forms.LinkLabel
        $link.Text = $parts[$i]
        $link.AutoSize = $true
        $link.Margin = New-Object System.Windows.Forms.Padding 2, 5, 2, 0
        $link.AllowDrop = $true
        $link.Tag = @{ Pane = $Pane; Rel = $rel }
        $link.Add_LinkClicked({ $t = $this.Tag; $t.Pane.Current = $t.Rel; Update-ExplorerPane $t.Pane })
        $link.Add_DragEnter({
                param($sender, $e)
                if (-not $global:ST.Busy -and $e.Data.GetDataPresent('SortingToolPaths')) { $e.Effect = [System.Windows.Forms.DragDropEffects]::Move }
                else { $e.Effect = [System.Windows.Forms.DragDropEffects]::None }
            })
        $link.Add_DragDrop({
                param($sender, $e)
                $paths = [string[]]$e.Data.GetData('SortingToolPaths')
                Request-ExplorerMove -Paths $paths -TargetFolder $this.Tag.Rel
            })
        $bar.Controls.Add($link)
    }
    $bar.ResumeLayout()
}

function Update-ExplorerPane {
    param($Pane)
    if (-not [System.IO.Directory]::Exists((ConvertTo-AbsPath $Pane.Current))) { $Pane.Current = $Pane.Root }
    $list = $Pane.List
    $Pane.UpButton.Enabled = -not (Test-RelEqual $Pane.Current $Pane.Root)
    $bold = New-Object System.Drawing.Font($Pane.ListButton.Font, [System.Drawing.FontStyle]::Bold)
    $normal = New-Object System.Drawing.Font($Pane.ListButton.Font, [System.Drawing.FontStyle]::Regular)
    if ($Pane.View -eq 'List') { $Pane.ListButton.Font = $bold; $Pane.FolderButton.Font = $normal; $Pane.ListButton.BackColor = [System.Drawing.Color]::LightSteelBlue; $Pane.FolderButton.UseVisualStyleBackColor = $true }
    else { $Pane.FolderButton.Font = $bold; $Pane.ListButton.Font = $normal; $Pane.FolderButton.BackColor = [System.Drawing.Color]::LightSteelBlue; $Pane.ListButton.UseVisualStyleBackColor = $true }
    Update-ExplorerPathBar $Pane
    $Pane.Pending.Clear()
    $Pane.ScanIndex = 0
    # Thumbnails of the previous folder are released.
    foreach ($key in @($Pane.Images.Images.Keys)) {
        if ($key -like 'thumb:*') { $Pane.Images.Images.RemoveByKey($key) }
    }
    $list.BeginUpdate()
    $list.ListViewItemSorter = $null
    $list.Items.Clear()
    $list.Columns.Clear()
    $abs = ConvertTo-AbsPath $Pane.Current
    if ($Pane.View -eq 'List') {
        $list.View = 'Details'
        [void]$list.Columns.Add('Name', 260)
        [void]$list.Columns.Add('Ordner', 220)
        [void]$list.Columns.Add('Größe', 90, [System.Windows.Forms.HorizontalAlignment]::Right)
        [void]$list.Columns.Add('Änderungsdatum', 130)
        $files = Get-FilesRecursive $abs
        $items = New-Object System.Collections.Generic.List[System.Windows.Forms.ListViewItem]
        $max = 20000
        foreach ($f in $files) {
            if ($items.Count -ge $max) { break }
            $rel = ConvertTo-RelPath $f.FullName
            $item = New-Object System.Windows.Forms.ListViewItem $f.Name
            $folderText = Get-RelParent $rel
            if ($folderText.Length -gt $Pane.Current.Length) { $folderText = $folderText.Substring($Pane.Current.Length).TrimStart('/') } else { $folderText = '' }
            [void]$item.SubItems.Add($folderText)
            $s = $item.SubItems.Add((Format-FileSize $f.Length)); $s.Tag = [long]$f.Length
            $d = $item.SubItems.Add($f.LastWriteTime.ToString('yyyy-MM-dd HH:mm')); $d.Tag = $f.LastWriteTime
            $item.Tag = @{ Rel = $rel; IsFolder = $false }
            $items.Add($item)
        }
        $list.Items.AddRange($items.ToArray())
        if ($files.Count -gt $max) { Write-StatusText "Liste zeigt die ersten $max von $($files.Count) Dateien." }
        $Pane.Sorter.Column = 0; $Pane.Sorter.Ascending = $true
        $list.ListViewItemSorter = $Pane.Sorter
        $list.Sort()
    }
    else {
        $list.View = 'LargeIcon'
        $info = New-Object System.IO.DirectoryInfo $abs
        $items = New-Object System.Collections.Generic.List[System.Windows.Forms.ListViewItem]
        try {
            foreach ($d in ($info.GetDirectories() | Sort-Object Name)) {
                $item = New-Object System.Windows.Forms.ListViewItem $d.Name, 'folder'
                $item.ImageKey = 'folder'
                $item.Tag = @{ Rel = (ConvertTo-RelPath $d.FullName); IsFolder = $true }
                $items.Add($item)
            }
            foreach ($f in ($info.GetFiles() | Sort-Object Name)) {
                $rel = ConvertTo-RelPath $f.FullName
                $item = New-Object System.Windows.Forms.ListViewItem $f.Name
                $item.ImageKey = Get-ExtensionIconKey -Pane $Pane -AbsPath $f.FullName
                $isImage = (Get-ExtensionKind $f.Name) -eq 'Image'
                $item.Tag = @{ Rel = $rel; IsFolder = $false; NeedsThumb = $isImage }
                $items.Add($item)
                if ($isImage) { $Pane.Pending.Add($item) }
            }
        }
        catch { Write-StatusText "Ordner konnte nicht gelesen werden: $($_.Exception.Message)" }
        $list.Items.AddRange($items.ToArray())
    }
    $list.EndUpdate()
}

function Update-ExplorerThumbnails {
    # Computes thumbnails only for images that are currently visible (base section 11).
    param($Pane)
    if ($Pane.View -ne 'Folder' -or $Pane.Pending.Count -eq 0) { return }
    $list = $Pane.List
    if (-not $list.Visible -or $list.IsDisposed) { return }
    $client = $list.ClientRectangle
    $done = 0
    $scanned = 0
    $size = $Pane.Images.ImageSize.Width
    $i = 0
    while ($i -lt $Pane.Pending.Count -and $scanned -lt 300 -and $done -lt 4) {
        $item = $Pane.Pending[$i]
        $scanned++
        if ($item.ListView -ne $list) { $Pane.Pending.RemoveAt($i); continue }
        $bounds = $item.Bounds
        if (-not $client.IntersectsWith($bounds)) { $i++; continue }
        $Pane.Pending.RemoveAt($i)
        $bmp = New-ThumbnailBitmap -Path (ConvertTo-AbsPath $item.Tag.Rel) -Size $size
        if ($bmp) {
            # Thumbnails live only in memory (base section 11).
            $key = 'thumb:' + $item.Tag.Rel
            $Pane.Images.Images.Add($key, $bmp)
            $item.ImageKey = $key
        }
        $done++
    }
}

function Update-Explorer {
    # Reads both areas again (button "Aktualisieren", F5, after every action).
    if (-not $global:ST.Explorer) { return }
    foreach ($pane in $global:ST.Explorer.Values) { Update-ExplorerPane $pane }
}

function Invoke-ExplorerRename {
    # Rename by hand (base section 11 "Umbenennen"): runs at once, logged, can be undone.
    param($Pane, $Item, [string]$NewName)
    if ($global:ST.Busy) { return }
    $info = $Item.Tag
    $oldName = Get-RelName $info.Rel
    $NewName = $NewName.Trim()
    if ($NewName -ceq $oldName) { return }
    if ((Get-RelDepth $info.Rel) -lt 2) { Show-ErrorMessage 'Input und Result selbst lassen sich nicht umbenennen.'; return }
    $reason = Get-InvalidNameReason $NewName
    $retry = {
        param($pane, $rel)
        # Opens the name field again after a refused name. Runs later from the message loop,
        # so the values are kept in the global state.
        $global:ST.RenameRetry = @{ Pane = $pane; Rel = $rel }
        $pane.List.BeginInvoke([System.Action] {
                $r = $global:ST.RenameRetry
                if (-not $r) { return }
                foreach ($it in $r.Pane.List.Items) { if (Test-RelEqual $it.Tag.Rel $r.Rel) { $it.BeginEdit(); break } }
            }) | Out-Null
    }
    if ($reason) { Show-ErrorMessage $reason; & $retry $Pane $info.Rel; return }
    $target = Join-RelPath (Get-RelParent $info.Rel) $NewName
    if (-not (Test-RelEqual $target $info.Rel) -and (Test-RelExists $target)) {
        Show-ErrorMessage "Im selben Ordner gibt es schon einen Eintrag mit dem Namen „$NewName“. Bitte einen anderen Namen eingeben."
        & $retry $Pane $info.Rel
        return
    }
    if (-not $info.IsFolder) {
        $oldExt = [System.IO.Path]::GetExtension($oldName)
        $newExt = [System.IO.Path]::GetExtension($NewName)
        if ($oldExt -ne $newExt) {
            if (-not (Show-YesNo "Die Dateiendung ändert sich von „$oldExt“ zu „$newExt“. Ist das gewollt?")) { & $retry $Pane $info.Rel; return }
        }
    }
    $log = New-ActionLog -Group 'Explorer' -Script 'Rename'
    try {
        if ($info.IsFolder) { [void](Move-FolderTracked -Source $info.Rel -Target $target -Log $log -StepType 'RENAMED') }
        else { [void](Move-FileTracked -Source $info.Rel -Target $target -Log $log -StepType 'RENAMED') }
        Write-StatusText "Umbenannt: $oldName → $NewName"
    }
    catch {
        Add-LogStep -Log $log -Type 'ERROR' -Old $info.Rel -New $target -Extra $_.Exception.Message
        Show-ErrorMessage "Umbenennen nicht möglich: $($_.Exception.Message)"
    }
    [void](Save-ActionLog $log)
    Update-Explorer
}

function Request-ExplorerMove {
    # Runs the move after the drag and drop operation has ended (the lists are refreshed afterwards).
    param([string[]]$Paths, [string]$TargetFolder)
    $global:ST.PendingMove = @{ Paths = $Paths; Target = $TargetFolder }
    $global:ST.MainForm.BeginInvoke([System.Action] {
            $m = $global:ST.PendingMove
            $global:ST.PendingMove = $null
            if ($m) { Invoke-ExplorerMove -Paths $m.Paths -TargetFolder $m.Target }
        }) | Out-Null
}

function Invoke-ExplorerMove {
    # Move by drag and drop (base section 11 "Verschieben per Ziehen und Ablegen").
    param([string[]]$Paths, [Parameter(Mandatory)][string]$TargetFolder)
    if ($global:ST.Busy -or -not $Paths -or $Paths.Count -eq 0) { return }
    $root = Get-RelRoot $TargetFolder
    if ($root -ne 'Input' -and $root -ne 'Result') { return }
    $log = New-ActionLog -Group 'Explorer' -Script 'Move'
    $parents = New-Object System.Collections.Generic.List[string]
    $messages = New-Object System.Collections.Generic.List[string]
    Start-DbTransaction
    try {
        foreach ($rel in $Paths) {
            if ((Get-RelDepth $rel) -lt 2) { $messages.Add('Input und Result selbst lassen sich nicht verschieben.'); continue }
            if (Test-RelEqual (Get-RelParent $rel) $TargetFolder) { continue }   # already there
            $isFolder = Test-RelIsFolder $rel
            if ($isFolder -and (Test-RelUnderOrEqual $TargetFolder $rel)) {
                $messages.Add("„$(Get-RelName $rel)“ kann nicht in sich selbst oder einen Unterordner verschoben werden.")
                continue
            }
            $target = Join-RelPath $TargetFolder (Get-RelName $rel)
            try {
                if ($isFolder) { $final = Move-FolderTracked -Source $rel -Target $target -Log $log -AllowSuffix }
                else { $final = Move-FileTracked -Source $rel -Target $target -Log $log -AllowSuffix }
                if (-not (Test-RelEqual (Get-RelName $final) (Get-RelName $rel))) {
                    $messages.Add("„$(Get-RelName $rel)“ heißt am Ziel „$(Get-RelName $final)“.")
                }
                $parents.Add((Get-RelParent $rel))
            }
            catch {
                Add-LogStep -Log $log -Type 'ERROR' -Old $rel -New $target -Extra $_.Exception.Message
                $messages.Add("Fehler bei „$(Get-RelName $rel)“: $($_.Exception.Message)")
            }
        }
        [void](Remove-EmptyInputFolders -Candidates $parents -Log $log)
    }
    finally { Complete-DbTransaction }
    if ($log.Steps.Count -gt 0) { [void](Save-ActionLog $log) }
    $status = "Verschoben: $($log.FilesMoved)"
    if ($messages.Count -gt 0) { $status += ' – ' + ($messages -join ' ') }
    Write-StatusText $status
    Update-Explorer
}

function New-ExplorerView {
    # Returns the control for the main window and registers both panes in $global:ST.Explorer.
    $split = New-Object System.Windows.Forms.SplitContainer
    $split.Dock = 'Fill'
    $split.Orientation = 'Vertical'
    $left = New-ExplorerPane -Root 'Input'
    $right = New-ExplorerPane -Root 'Result'
    $split.Panel1.Controls.Add($left.Panel)
    $split.Panel2.Controls.Add($right.Panel)
    $global:ST.Explorer = [ordered]@{ Input = $left; Result = $right }
    return $split
}
