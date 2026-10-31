# Dialogs.ps1
# Small dialogs used by the main program and the functions. All visible texts are German.

function Get-OwnerForm {
    if ($global:ST.MainForm -and -not $global:ST.MainForm.IsDisposed) { return $global:ST.MainForm }
    return $null
}

function Show-InfoMessage {
    param([Parameter(Mandatory)][string]$Text, [string]$Title = 'Sortierwerkzeug')
    [void][System.Windows.Forms.MessageBox]::Show((Get-OwnerForm), $Text, $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
}

function Show-ErrorMessage {
    param([Parameter(Mandatory)][string]$Text, [string]$Title = 'Sortierwerkzeug')
    [void][System.Windows.Forms.MessageBox]::Show((Get-OwnerForm), $Text, $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
}

function Show-YesNo {
    param([Parameter(Mandatory)][string]$Text, [string]$Title = 'Sortierwerkzeug')
    $r = [System.Windows.Forms.MessageBox]::Show((Get-OwnerForm), $Text, $Title,
        [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    return ($r -eq [System.Windows.Forms.DialogResult]::Yes)
}

function Show-ChoiceDialog {
    # Dialog with a text, an optional list of lines and freely labelled buttons.
    # Returns the label of the clicked button, or the last label if the window is closed.
    param(
        [Parameter(Mandatory)][string]$Text,
        [string[]]$Lines = @(),
        [Parameter(Mandatory)][string[]]$Buttons,
        [string]$Title = 'Sortierwerkzeug'
    )
    $form = New-Object System.Windows.Forms.Form
    $form.Text = $Title
    $form.StartPosition = 'CenterParent'
    $form.FormBorderStyle = 'Sizable'
    $form.MinimizeBox = $false
    $form.MaximizeBox = $false
    $form.Width = 560
    $form.Height = $(if ($Lines.Count -gt 0) { 420 } else { 200 })
    $form.Tag = $Buttons[$Buttons.Count - 1]

    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Dock = 'Top'
    $label.Padding = New-Object System.Windows.Forms.Padding 10
    $label.AutoSize = $false
    $label.Height = 60
    $form.Controls.Add($label)

    $panel = New-Object System.Windows.Forms.FlowLayoutPanel
    $panel.Dock = 'Bottom'
    $panel.FlowDirection = 'RightToLeft'
    $panel.Height = 44
    $panel.Padding = New-Object System.Windows.Forms.Padding 6
    for ($i = $Buttons.Count - 1; $i -ge 0; $i--) {
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $Buttons[$i]
        $b.AutoSize = $true
        $b.MinimumSize = New-Object System.Drawing.Size 90, 28
        $b.Tag = $Buttons[$i]
        $b.Add_Click({ $this.FindForm().Tag = $this.Tag; $this.FindForm().Close() })
        $panel.Controls.Add($b)
        if ($i -eq 0) { $form.AcceptButton = $b }
    }
    $form.Controls.Add($panel)

    if ($Lines.Count -gt 0) {
        $box = New-Object System.Windows.Forms.TextBox
        $box.Multiline = $true
        $box.ReadOnly = $true
        $box.ScrollBars = 'Both'
        $box.WordWrap = $false
        $box.Dock = 'Fill'
        $box.Text = ($Lines -join "`r`n")
        $form.Controls.Add($box)
        $box.BringToFront()
    }
    [void]$form.ShowDialog((Get-OwnerForm))
    $result = [string]$form.Tag
    $form.Dispose()
    return $result
}

function Show-TextInput {
    # Asks for a text. Returns $null on cancel.
    param([Parameter(Mandatory)][string]$Prompt, [string]$Default = '', [string]$Title = 'Sortierwerkzeug')
    $form = New-Object System.Windows.Forms.Form
    $form.Text = $Title
    $form.StartPosition = 'CenterParent'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MinimizeBox = $false
    $form.MaximizeBox = $false
    $form.Width = 460
    $form.Height = 170
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Prompt
    $label.SetBounds(12, 12, 420, 20)
    $box = New-Object System.Windows.Forms.TextBox
    $box.Text = $Default
    $box.SetBounds(12, 38, 420, 24)
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'OK'
    $ok.SetBounds(256, 78, 85, 28)
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Abbrechen'
    $cancel.SetBounds(347, 78, 85, 28)
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.AddRange(@($label, $box, $ok, $cancel))
    $form.AcceptButton = $ok
    $form.CancelButton = $cancel
    $r = $form.ShowDialog((Get-OwnerForm))
    $text = $box.Text
    $form.Dispose()
    if ($r -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
    return $text
}

function New-ProgressDialog {
    # Non-modal progress window with a cancel button (base section 10 "Initialisieren").
    # Usage: $p = New-ProgressDialog 'Titel'; Update-ProgressDialog $p 5 100 'Text'; if ($p.Cancelled) ...; Close-ProgressDialog $p
    param([Parameter(Mandatory)][string]$Title)
    $state = @{ Cancelled = $false; Form = $null; Bar = $null; Label = $null; LastPump = [datetime]::MinValue }
    $form = New-Object System.Windows.Forms.Form
    $form.Text = $Title
    $form.StartPosition = 'CenterParent'
    $form.FormBorderStyle = 'FixedDialog'
    $form.ControlBox = $false
    $form.Width = 480
    $form.Height = 150
    $label = New-Object System.Windows.Forms.Label
    $label.SetBounds(12, 10, 440, 20)
    $label.AutoEllipsis = $true
    $bar = New-Object System.Windows.Forms.ProgressBar
    $bar.SetBounds(12, 36, 440, 22)
    $button = New-Object System.Windows.Forms.Button
    $button.Text = 'Abbrechen'
    $button.SetBounds(367, 70, 85, 28)
    $button.Tag = $state
    $button.Add_Click({ $this.Tag.Cancelled = $true; $this.Enabled = $false; $this.Text = 'Wird abgebrochen …' })
    $form.Controls.AddRange(@($label, $bar, $button))
    $state.Form = $form
    $state.Bar = $bar
    $state.Label = $label
    $owner = Get-OwnerForm
    if ($owner) {
        $form.StartPosition = 'Manual'
        $form.Location = New-Object System.Drawing.Point ([int]($owner.Left + ($owner.Width - $form.Width) / 2)), ([int]($owner.Top + ($owner.Height - $form.Height) / 2))
        $form.Show($owner)
    }
    else { $form.Show() }
    [System.Windows.Forms.Application]::DoEvents()
    return $state
}

function Update-ProgressDialog {
    param([Parameter(Mandatory)]$Dialog, [int]$Value, [int]$Maximum, [string]$Text)
    $now = Get-Date
    # Redraw at most every 100 ms, so the progress window does not slow down the work.
    if (($now - $Dialog.LastPump).TotalMilliseconds -lt 100 -and $Value -lt $Maximum) { return }
    $Dialog.LastPump = $now
    if ($Maximum -gt 0) {
        $Dialog.Bar.Maximum = $Maximum
        $Dialog.Bar.Value = [Math]::Min($Value, $Maximum)
    }
    if ($Text) { $Dialog.Label.Text = $Text }
    [System.Windows.Forms.Application]::DoEvents()
}

function Close-ProgressDialog {
    param([Parameter(Mandatory)]$Dialog)
    if ($Dialog.Form -and -not $Dialog.Form.IsDisposed) { $Dialog.Form.Close(); $Dialog.Form.Dispose() }
}

function Show-LogSelection {
    # Selection of a log file for undo, newest first (base section 9). Returns the log or $null.
    $logs = Get-UndoableLogs
    if ($logs.Count -eq 0) {
        Show-InfoMessage 'Es gibt keine Aktion, die rückgängig gemacht werden kann.'
        return $null
    }
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Aktion rückgängig machen'
    $form.StartPosition = 'CenterParent'
    $form.Width = 760
    $form.Height = 480
    $label = New-Object System.Windows.Forms.Label
    $label.Text = 'Welche Aktion soll rückgängig gemacht werden? Die neueste steht oben.'
    $label.Dock = 'Top'
    $label.Height = 30
    $label.Padding = New-Object System.Windows.Forms.Padding 8
    $list = New-Object System.Windows.Forms.ListView
    $list.View = 'Details'
    $list.FullRowSelect = $true
    $list.MultiSelect = $false
    $list.HideSelection = $false
    $list.Dock = 'Fill'
    [void]$list.Columns.Add('Zeitpunkt', 150)
    [void]$list.Columns.Add('Aktion', 330)
    [void]$list.Columns.Add('Schritte', 80)
    [void]$list.Columns.Add('Fehler', 60)
    foreach ($log in $logs) {
        $item = New-Object System.Windows.Forms.ListViewItem ([string]$log.Header['StartTime'])
        [void]$item.SubItems.Add((Get-ActionNameFromLog $log.Name))
        [void]$item.SubItems.Add([string]$log.UndoableCount)
        [void]$item.SubItems.Add([string]$log.Header['Errors'])
        $item.Tag = $log
        [void]$list.Items.Add($item)
    }
    $list.Items[0].Selected = $true
    $panel = New-Object System.Windows.Forms.FlowLayoutPanel
    $panel.Dock = 'Bottom'
    $panel.FlowDirection = 'RightToLeft'
    $panel.Height = 44
    $panel.Padding = New-Object System.Windows.Forms.Padding 6
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Abbrechen'
    $cancel.AutoSize = $true
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'Vorschau'
    $ok.AutoSize = $true
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $panel.Controls.AddRange(@($cancel, $ok))
    $form.Controls.Add($list)
    $form.Controls.Add($label)
    $form.Controls.Add($panel)
    $form.AcceptButton = $ok
    $form.CancelButton = $cancel
    $list.Add_DoubleClick({ $this.FindForm().DialogResult = [System.Windows.Forms.DialogResult]::OK })
    $r = $form.ShowDialog((Get-OwnerForm))
    $selected = $null
    if ($r -eq [System.Windows.Forms.DialogResult]::OK -and $list.SelectedItems.Count -gt 0) { $selected = $list.SelectedItems[0].Tag }
    $form.Dispose()
    return $selected
}

function Show-WaitDialog {
    # Waiting for the Claude usage limit (3.1 section 5). Shows a countdown and the progress so far.
    # Returns 'Resume' when the time is reached, or 'Skip' for "Rest überspringen".
    param(
        [Parameter(Mandatory)][datetime]$Until,
        [string]$ProgressText = '',
        [switch]$RetryMode
    )
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Claude-Nutzungslimit'
    $form.StartPosition = 'CenterParent'
    $form.FormBorderStyle = 'FixedDialog'
    $form.ControlBox = $false
    $form.Width = 520
    $form.Height = 200
    $form.Tag = 'Resume'
    $label = New-Object System.Windows.Forms.Label
    $label.SetBounds(12, 12, 480, 60)
    if ($RetryMode) {
        $label.Text = "Das Claude-Nutzungslimit ist erreicht. Nächster Versuch um $($Until.ToString('HH:mm'))."
    }
    else {
        $label.Text = "Das Claude-Nutzungslimit ist erreicht. Es geht automatisch weiter um $($Until.ToString('HH:mm'))."
    }
    $countdown = New-Object System.Windows.Forms.Label
    $countdown.SetBounds(12, 74, 480, 20)
    $progress = New-Object System.Windows.Forms.Label
    $progress.SetBounds(12, 96, 480, 20)
    $progress.Text = $ProgressText
    $skip = New-Object System.Windows.Forms.Button
    $skip.Text = 'Rest überspringen'
    $skip.SetBounds(352, 122, 140, 28)
    $skip.Add_Click({ $this.FindForm().Tag = 'Skip'; $this.FindForm().Close() })
    $form.Controls.AddRange(@($label, $countdown, $progress, $skip))
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1000
    $timer.Tag = @{ Until = $Until; Label = $countdown; Form = $form }
    $timer.Add_Tick({
            $t = $this.Tag
            $left = $t.Until - (Get-Date)
            if ($left.TotalSeconds -le 0) { $this.Stop(); $t.Form.Tag = 'Resume'; $t.Form.Close(); return }
            $t.Label.Text = 'Noch {0:hh\:mm\:ss}' -f $left
        })
    $timer.Start()
    [void]$form.ShowDialog((Get-OwnerForm))
    $timer.Stop()
    $timer.Dispose()
    $result = [string]$form.Tag
    $form.Dispose()
    return $result
}
