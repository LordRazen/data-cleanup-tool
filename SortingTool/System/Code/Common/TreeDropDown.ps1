# TreeDropDown.ps1
# A combo box that opens a tree (2.5 section 4 "Ziel in Result"). Windows Forms has no such
# control, so it is built from a button and a drop-down that hosts a TreeView.
# Usage:
#   $dd = New-TreeDropDown -Width 400
#   $dd.Tree.Nodes.Add(...)            # node.Tag = value
#   $dd.OnSelect = { param($dd, $node) ... return $true to accept }
#   $dd.Button is the control to place on the form, $dd.Selected the chosen node.

function New-TreeDropDown {
    param([int]$Width = 400, [int]$DropHeight = 320, [string]$Placeholder = '(bitte wählen)')
    $state = @{ Selected = $null; OnSelect = $null; Placeholder = $Placeholder }
    $button = New-Object System.Windows.Forms.Button
    $button.Width = $Width
    $button.Height = 26
    $button.TextAlign = 'MiddleLeft'
    $button.Text = "$Placeholder  ▾"
    $tree = New-Object System.Windows.Forms.TreeView
    $tree.Width = $Width
    $tree.Height = $DropHeight
    $tree.HideSelection = $false
    $tree.BorderStyle = 'None'
    $tree.PathSeparator = " › "
    $ctlHost = New-Object System.Windows.Forms.ToolStripControlHost $tree
    $ctlHost.Margin = New-Object System.Windows.Forms.Padding 0
    $ctlHost.Padding = New-Object System.Windows.Forms.Padding 0
    $ctlHost.AutoSize = $false
    $ctlHost.Size = New-Object System.Drawing.Size $Width, $DropHeight
    $drop = New-Object System.Windows.Forms.ToolStripDropDown
    $drop.Padding = New-Object System.Windows.Forms.Padding 0
    [void]$drop.Items.Add($ctlHost)
    $state.Button = $button
    $state.Tree = $tree
    $state.DropDown = $drop
    $button.Tag = $state
    $tree.Tag = $state
    $button.Add_Click({
            $st = $this.Tag
            $st.DropDown.Show($this, 0, $this.Height)
            $st.Tree.Focus()
        })
    $tree.Add_NodeMouseClick({
            param($sender, $e)
            $st = $this.Tag
            # Clicks on the +/- sign only expand or collapse.
            $hit = $this.HitTest($e.Location)
            if ($hit.Location -eq [System.Windows.Forms.TreeViewHitTestLocations]::PlusMinus) { return }
            $accept = $true
            if ($st.OnSelect) { $accept = & $st.OnSelect $st $e.Node }
            if ($accept -ne $false) {
                Select-TreeDropDownNode $st $e.Node
            }
            $st.DropDown.Close()
        })
    return $state
}

function Select-TreeDropDownNode {
    param($State, $Node)
    $State.Selected = $Node
    $State.Tree.SelectedNode = $Node
    if ($Node) { $State.Button.Text = "$($Node.FullPath)  ▾" } else { $State.Button.Text = "$($State.Placeholder)  ▾" }
}
