# Undo.ps1
# Undo of an action from its log file (base section 9). The log is turned into a reversed plan
# that is shown in the same preview, so parts of an action can be undone as well.
# The undo writes its own log "... - Undo - <original action>.log", which can be undone again.

function New-UndoPlan {
    param([Parameter(Mandatory)]$ActionLog)
    $action = Get-ActionNameFromLog $ActionLog.Name
    $plan = New-Plan -Title "Rückgängig: $action" -Group 'Undo' -Script $action -Roots @()
    $roots = New-PathSet
    $steps = @($ActionLog.Steps)
    [array]::Reverse($steps)
    foreach ($step in $steps) {
        switch ($step.Type) {
            { $_ -eq 'MOVED' -or $_ -eq 'RENAMED' } {
                $isFolder = [System.IO.Directory]::Exists((ConvertTo-AbsPath $step.New))
                $kind = 'MoveFile'
                if ($isFolder) { $kind = 'MoveFolder' }
                $conflict = ''
                if (-not (Test-RelExists $step.New)) { $conflict = 'Nicht mehr am erwarteten Ort, wird übersprungen' }
                elseif ((Test-RelExists $step.Old) -and -not (Test-RelEqual $step.Old $step.New)) { $conflict = 'Am ursprünglichen Ort liegt schon etwas, wird übersprungen' }
                $item = Add-PlanItem -Plan $plan -Action $kind -Source $step.New -Target $step.Old -Locked ($conflict -ne '') -Conflict $conflict `
                    -AllowSuffix $false -StepType $step.Type
                if ($conflict) { $item.Info = $conflict }
                [void]$roots.Add((Get-RelRoot $step.New)); [void]$roots.Add((Get-RelRoot $step.Old))
            }
            'FOLDER_CREATED' {
                if (Test-RelIsFolder $step.New) {
                    [void](Add-PlanItem -Plan $plan -Action 'RemoveFolder' -Source $step.New -Info 'wird entfernt, wenn er leer ist')
                    [void]$roots.Add((Get-RelRoot $step.New))
                }
            }
            'EMPTY_FOLDER_REMOVED' {
                if (-not (Test-RelExists $step.Old)) {
                    [void](Add-PlanItem -Plan $plan -Action 'CreateFolder' -Target $step.Old -Force $true)
                    [void]$roots.Add((Get-RelRoot $step.Old))
                }
            }
            'LINK_CREATED' {
                $conflict = ''
                if (-not (Test-RelExists $step.New)) { $conflict = 'Verknüpfung nicht gefunden' }
                [void](Add-PlanItem -Plan $plan -Action 'RemoveLink' -Source $step.New -LinkTarget $step.Extra -Locked ($conflict -ne '') -Conflict $conflict -Info $conflict)
                [void]$roots.Add((Get-RelRoot $step.New))
            }
            'LINK_REMOVED' {
                $conflict = ''
                if (Test-RelExists $step.Old) { $conflict = 'Am Ort liegt schon eine Datei' }
                [void](Add-PlanItem -Plan $plan -Action 'CreateLink' -Target $step.Old -LinkTarget $step.Extra -Locked ($conflict -ne '') -Conflict $conflict -Info $conflict)
                [void]$roots.Add((Get-RelRoot $step.Old))
            }
            'ENTRY_REMOVED' {
                $row = $null
                try { $row = $step.Extra | ConvertFrom-Json } catch { }
                if ($null -eq $row) { continue }
                $conflict = ''
                if ($null -ne (Get-FileEntry $step.Old)) { $conflict = 'Für diesen Pfad gibt es inzwischen wieder einen Eintrag' }
                [void](Add-PlanItem -Plan $plan -Action 'RestoreEntry' -Target $step.Old -Locked ($conflict -ne '') -Conflict $conflict -Info $conflict -Data @{ Row = $row })
            }
            'ENTRY_RESTORED' {
                $row = Get-FileEntry $step.New
                if ($null -eq $row) { continue }
                [void](Add-PlanItem -Plan $plan -Action 'RemoveEntry' -Source $step.New -Data @{ Row = $row })
            }
        }
    }
    $plan.Roots = @($roots | Where-Object { $_ -in @('Input', 'Result', 'ToDelete') })
    if ($plan.Roots.Count -eq 0) { $plan.Roots = @('Input') }
    return $plan
}

function Test-PlanDatabaseOnly {
    param([Parameter(Mandatory)]$Plan)
    $items = @($Plan.Items | Where-Object { $_.Action -ne 'Info' })
    if ($items.Count -eq 0) { return $false }
    foreach ($i in $items) { if ($i.Action -notin @('RemoveEntry', 'RestoreEntry')) { return $false } }
    return $true
}
