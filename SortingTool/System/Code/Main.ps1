# Main.ps1
# Main program of the SortingTool (base section 4 and 5). Started by Start.cmd.
#  - Top: one frame per group from layout.json with its buttons.
#  - Middle: file explorer, left Input, right Result.
#  - Below: fixed button row (initialize, clean database, move to Result, undo).
#  - Bottom: status area.
# A button calls a chain of functions (2 - FunctionOverview.md). Each function runs completely
# (plan, preview, execute, log) before the next starts. Cancelling a preview stops the chain.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Off

try {
    . (Join-Path $PSScriptRoot 'Common.ps1')
    . (Join-Path $PSScriptRoot 'Explorer.ps1')
    [System.Windows.Forms.Application]::EnableVisualStyles()
    Initialize-ToolPaths -CodeFolder $PSScriptRoot
    [void](Import-ToolSettings)
    [void](Import-ToolLayout)
    Open-ToolDatabase
}
catch {
    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show("Das Sortierwerkzeug konnte nicht gestartet werden:`r`n`r`n$($_.Exception.Message)",
        'Sortierwerkzeug', 'OK', 'Error')
    exit 1
}

$global:ST.Buttons = New-Object System.Collections.Generic.List[object]

function Get-FunctionScriptPath {
    # Group buttons: Code/<Group>/<Function>.ps1, fixed buttons: Code/Database/<Function>.ps1.
    # A function entry may name another folder with "folder".
    param($FunctionDef, [string]$DefaultFolder)
    $folder = $DefaultFolder
    if ($FunctionDef.PSObject.Properties['folder'] -and $FunctionDef.folder) { $folder = $FunctionDef.folder }
    $name = [string]$FunctionDef.name
    if ($FunctionDef.PSObject.Properties['script'] -and $FunctionDef.script) { $name = [System.IO.Path]::GetFileNameWithoutExtension($FunctionDef.script) }
    return (Join-Path (Join-Path $global:ST.Code $folder) "$name.ps1")
}

function Get-ButtonFunctions {
    # "functions" list, or the single "script" of the base layout (base section 6).
    param($ButtonDef)
    if ($ButtonDef.PSObject.Properties['functions'] -and $ButtonDef.functions) { return @($ButtonDef.functions) }
    if ($ButtonDef.PSObject.Properties['script'] -and $ButtonDef.script) {
        return @([pscustomobject]@{ name = [System.IO.Path]::GetFileNameWithoutExtension($ButtonDef.script) })
    }
    return @()
}

function ConvertTo-Hashtable {
    param($Object)
    $h = @{}
    if ($null -eq $Object) { return $h }
    foreach ($p in $Object.PSObject.Properties) { $h[$p.Name] = $p.Value }
    return $h
}

function Set-UiBusy {
    # While a function runs, all buttons are locked and the explorer cannot change anything (base section 5).
    param([bool]$Busy)
    $global:ST.Busy = $Busy
    foreach ($b in $global:ST.Buttons) {
        if ($Busy) { $b.Control.Enabled = $false }
        else { $b.Control.Enabled = $b.Available }
    }
    if ($global:ST.Explorer) {
        foreach ($pane in $global:ST.Explorer.Values) { $pane.List.LabelEdit = -not $Busy; $pane.List.AllowDrop = -not $Busy }
    }
    if ($Busy) { $global:ST.MainForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor }
    else { $global:ST.MainForm.Cursor = [System.Windows.Forms.Cursors]::Default }
}

function Invoke-PlanWithPreview {
    # Shows the preview of a plan and executes it after confirmation. Returns $false on cancel.
    param([Parameter(Mandatory)]$Plan)
    $actionable = @($Plan.Items | Where-Object { $_.Action -ne 'Info' })
    if ($actionable.Count -eq 0) {
        $infos = @($Plan.Items | Where-Object { $_.Action -eq 'Info' })
        $text = 'Keine Änderungen nötig.'
        if ($infos.Count -gt 0) { $text += "`r`n`r`n" + (($infos | Select-Object -First 30 | ForEach-Object { "$($_.Source): $($_.Info)" }) -join "`r`n") }
        Show-InfoMessage $text $Plan.Title
        if ($Plan.OnExecuted) {
            $log = New-ActionLog -Group $Plan.Group -Script $Plan.Script
            $null = & $Plan.OnExecuted $Plan $log
            if ($log.Steps.Count -gt 0 -or $log.Extra.Count -gt 0) { [void](Save-ActionLog $log) }
        }
        return $true
    }
    Write-StatusText "Vorschau: $($Plan.Title)"
    if (Test-PlanDatabaseOnly $Plan) { $ok = Show-ListPreview -Plan $Plan }
    else { $ok = Show-PlanPreview -Plan $Plan }
    if (-not $ok) {
        Write-StatusText "Abgebrochen: $($Plan.Title). Es wurde nichts geändert."
        return $false
    }
    Write-StatusText "Ausführen: $($Plan.Title) …"
    $log = Invoke-Plan -Plan $Plan
    $text = "Fertig: $($Plan.Title). Verschoben: $($log.FilesMoved), Fehler: $($log.Errors)."
    Write-StatusText $text
    if ($log.Errors -gt 0) {
        $errors = @($log.Steps | Where-Object { $_.Type -eq 'ERROR' } | Select-Object -First 20 | ForEach-Object { "$($_.Old) → $($_.New): $($_.Extra)" })
        [void](Show-ChoiceDialog -Text "$text`r`nDetails stehen in der Logdatei $([System.IO.Path]::GetFileName($log.Saved))." -Lines $errors -Buttons @('OK'))
    }
    return $true
}

function Invoke-ToolFunction {
    # Runs one function of a chain. Returns $true if the chain may continue.
    param([Parameter(Mandatory)]$FunctionDef, [Parameter(Mandatory)][string]$DefaultFolder)
    $path = Get-FunctionScriptPath -FunctionDef $FunctionDef -DefaultFolder $DefaultFolder
    $name = [string]$FunctionDef.name
    if (-not (Test-Path -LiteralPath $path)) {
        Show-ErrorMessage "Das Skript für „$name“ fehlt: $path"
        return $false
    }
    $arguments = @{}
    if ($FunctionDef.PSObject.Properties['arguments']) { $arguments = ConvertTo-Hashtable $FunctionDef.arguments }
    $context = @{
        Root     = $global:ST.Root
        Input    = $global:ST.Input
        Result   = $global:ST.Result
        ToDelete = $global:ST.ToDelete
        Settings = $global:ST.Settings
        Function = $name
    }
    Write-StatusText "Starte $name …"
    try {
        $output = @(& $path -Context $context -Arguments $arguments)
    }
    catch {
        $message = $_.Exception.Message
        Write-AppErrorLog -Script $name -Messages @($message, $_.ScriptStackTrace)
        Show-ErrorMessage "„$name“ ist fehlgeschlagen:`r`n$message"
        Write-StatusText "Fehler in $name."
        return $false
    }
    $result = $null
    for ($i = $output.Count - 1; $i -ge 0; $i--) {
        if ($output[$i] -is [hashtable] -and $output[$i].ContainsKey('Kind')) { $result = $output[$i]; break }
    }
    if ($null -eq $result) { Write-StatusText "${name}: fertig."; return $true }
    switch ($result.Kind) {
        'Plan' {
            try { return (Invoke-PlanWithPreview -Plan $result) }
            catch {
                Write-AppErrorLog -Script $name -Messages @($_.Exception.Message, $_.ScriptStackTrace)
                Show-ErrorMessage "„$name“ ist beim Ausführen fehlgeschlagen:`r`n$($_.Exception.Message)"
                return $false
            }
        }
        'Done' {
            if ($result.Message) { Show-InfoMessage $result.Message }
            Write-StatusText "${name}: fertig."
            return $true
        }
        'Message' {
            if ($result.Message) { Show-InfoMessage $result.Message }
            Write-StatusText "${name}: $($result.Message)"
            return $true
        }
        'Cancelled' {
            Write-StatusText "Abgebrochen: $name. Es wurde nichts geändert."
            if ($result.Message) { Show-InfoMessage $result.Message }
            return $false
        }
        'Failed' {
            Show-ErrorMessage "„$name“ ist fehlgeschlagen:`r`n$($result.Message)"
            Write-StatusText "Fehler in $name."
            return $false
        }
    }
    return $true
}

function Invoke-ButtonChain {
    param([Parameter(Mandatory)]$ButtonInfo)
    if ($global:ST.Busy) { return }
    Set-UiBusy $true
    try {
        if ($ButtonInfo.Special -eq 'Undo') {
            $log = Show-LogSelection
            if ($log) {
                $plan = New-UndoPlan -ActionLog $log
                [void](Invoke-PlanWithPreview -Plan $plan)
            }
            return
        }
        foreach ($fn in $ButtonInfo.Functions) {
            $continue = Invoke-ToolFunction -FunctionDef $fn -DefaultFolder $ButtonInfo.Folder
            if (-not $continue) { break }
        }
    }
    catch {
        Write-AppErrorLog -Script 'Main' -Messages @($_.Exception.Message, $_.ScriptStackTrace)
        Show-ErrorMessage "Unerwarteter Fehler: $($_.Exception.Message)"
    }
    finally {
        Set-UiBusy $false
        try { Update-Explorer } catch { }
    }
}

function New-ToolButton {
    param([Parameter(Mandatory)]$ButtonDef, [Parameter(Mandatory)][string]$Folder, $ToolTip)
    $button = New-Object System.Windows.Forms.Button
    $button.Text = [string]$ButtonDef.label
    $button.AutoSize = $true
    $button.MinimumSize = New-Object System.Drawing.Size 200, 30
    $special = ''
    if ($ButtonDef.PSObject.Properties['special']) { $special = [string]$ButtonDef.special }
    $info = @{ Control = $button; Functions = (Get-ButtonFunctions $ButtonDef); Folder = $Folder; Special = $special; Available = $true; Label = $button.Text }
    $tip = [string]$ButtonDef.description
    # Missing scripts grey out the button (base section 7).
    $missing = @()
    foreach ($fn in $info.Functions) {
        $path = Get-FunctionScriptPath -FunctionDef $fn -DefaultFolder $Folder
        if (-not (Test-Path -LiteralPath $path)) { $missing += $path }
    }
    if ($missing.Count -gt 0) {
        $info.Available = $false
        $tip = "Skript fehlt: " + ($missing -join ', ')
        $global:ST.MissingScripts += $missing
    }
    # Functions that need Claude are greyed out when Claude is not available (3.1 section 4).
    if ($info.Available -and $ButtonDef.PSObject.Properties['requires'] -and (@($ButtonDef.requires) -contains 'Claude')) {
        if (Get-Command Test-ClaudeEndpoint -ErrorAction SilentlyContinue) {
            $check = Test-ClaudeEndpoint -Quick
            if (-not $check.Available) { $info.Available = $false; $tip = $check.Message }
        }
    }
    $button.Enabled = $info.Available
    $button.Tag = $info
    if ($ToolTip -and $tip) { $ToolTip.SetToolTip($button, $tip) }
    $button.Add_Click({ Invoke-ButtonChain -ButtonInfo $this.Tag })
    $global:ST.Buttons.Add($info)
    return $button
}

# ---------------------------------------------------------------- main window
$global:ST.MissingScripts = @()
$form = New-Object System.Windows.Forms.Form
$form.Text = "Sortierwerkzeug $($global:ST.Version) – $($global:ST.Root)"
$form.Width = 1400
$form.Height = 900
$form.StartPosition = 'CenterScreen'
$form.KeyPreview = $true
$global:ST.MainForm = $form
$toolTip = New-Object System.Windows.Forms.ToolTip
$toolTip.AutoPopDelay = 15000

# Top: groups
$groupBar = New-Object System.Windows.Forms.FlowLayoutPanel
$groupBar.Dock = 'Top'
$groupBar.AutoSize = $true
$groupBar.WrapContents = $true
$groupBar.Padding = New-Object System.Windows.Forms.Padding 6
foreach ($group in $global:ST.Layout.groups) {
    $box = New-Object System.Windows.Forms.GroupBox
    $box.Text = [string]$group.label
    $box.AutoSize = $true
    $box.AutoSizeMode = 'GrowAndShrink'
    $box.MinimumSize = New-Object System.Drawing.Size 220, 60
    $inner = New-Object System.Windows.Forms.FlowLayoutPanel
    $inner.FlowDirection = 'TopDown'
    $inner.AutoSize = $true
    $inner.WrapContents = $false
    $inner.Dock = 'Fill'
    $inner.Padding = New-Object System.Windows.Forms.Padding 4, 2, 4, 2
    $buttons = @($group.buttons)
    if ($buttons.Count -eq 0) {
        $empty = New-Object System.Windows.Forms.Label
        $empty.Text = '(noch keine Funktionen)'
        $empty.AutoSize = $true
        $empty.ForeColor = [System.Drawing.Color]::Gray
        $inner.Controls.Add($empty)
    }
    foreach ($b in $buttons) {
        $inner.Controls.Add((New-ToolButton -ButtonDef $b -Folder ([string]$group.name) -ToolTip $toolTip))
    }
    $box.Controls.Add($inner)
    $groupBar.Controls.Add($box)
}

# Middle: explorer
$explorer = New-ExplorerView

# Fixed button row
$fixedBar = New-Object System.Windows.Forms.FlowLayoutPanel
$fixedBar.Dock = 'Bottom'
$fixedBar.AutoSize = $true
$fixedBar.Padding = New-Object System.Windows.Forms.Padding 6
foreach ($b in @($global:ST.Layout.fixedButtons)) {
    $fixedBar.Controls.Add((New-ToolButton -ButtonDef $b -Folder 'Database' -ToolTip $toolTip))
}

# Status area
$statusStrip = New-Object System.Windows.Forms.StatusStrip
$statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusLabel.Spring = $true
$statusLabel.TextAlign = 'MiddleLeft'
$statusLabel.Text = 'Bereit.'
[void]$statusStrip.Items.Add($statusLabel)
$global:ST.StatusLabel = $statusLabel
$global:ST.StatusStrip = $statusStrip

$form.Controls.Add($explorer)
$form.Controls.Add($groupBar)
$form.Controls.Add($fixedBar)
$form.Controls.Add($statusStrip)

$form.Add_KeyDown({
        param($sender, $e)
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::F5 -and -not $global:ST.Busy) { Update-Explorer; $e.Handled = $true }
    })
$form.Add_Shown({
        $explorer.SplitterDistance = [int]($explorer.Width / 2)
        Update-Explorer
        if ($global:ST.MissingScripts.Count -gt 0) {
            Write-AppErrorLog -Script 'MissingScripts' -Messages @($global:ST.MissingScripts | ForEach-Object { "Script missing: $_" })
            Write-StatusText "Bereit. Hinweis: $($global:ST.MissingScripts.Count) Skript(e) fehlen, die Buttons sind ausgegraut."
        }
        else { Write-StatusText 'Bereit.' }
    })
$form.Add_FormClosing({
        param($sender, $e)
        if ($global:ST.Busy) { $e.Cancel = $true; return }
    })

[void]$form.ShowDialog()
foreach ($pane in $global:ST.Explorer.Values) { $pane.Timer.Stop() }
Close-ToolDatabase
