# SelfTest.ps1
# Automatic self test of the non-visual parts of the SortingTool. Runs in its own temporary folder
# (%TEMP%\SortingToolSelfTest_...), never in the real Input, Result or ToDelete.
# Start with SelfTest.cmd in this folder. Prints PASS / FAIL per check.

$ErrorActionPreference = 'Stop'
$codeFolder = Split-Path -Parent $PSScriptRoot
. (Join-Path $codeFolder 'Common.ps1')

$script:passed = 0
$script:failed = 0
function Assert-True {
    param([bool]$Condition, [string]$Name)
    if ($Condition) { $script:passed++; Write-Host "PASS  $Name" -ForegroundColor Green }
    else { $script:failed++; Write-Host "FAIL  $Name" -ForegroundColor Red }
}
function Invoke-Function {
    param([string]$Folder, [string]$Name, [hashtable]$Arguments = @{})
    $path = Join-Path (Join-Path $codeFolder $Folder) "$Name.ps1"
    $out = @(& $path -Context @{} -Arguments $Arguments)
    for ($i = $out.Count - 1; $i -ge 0; $i--) { if ($out[$i] -is [hashtable] -and $out[$i].ContainsKey('Kind')) { return $out[$i] } }
    return $null
}

$realConfig = Join-Path (Split-Path -Parent $codeFolder) 'Config'
$tmp = Join-Path $env:TEMP ("SortingToolSelfTest_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$fakeCode = Join-Path $tmp 'System\Code'
[void][System.IO.Directory]::CreateDirectory($fakeCode)
Write-Host "Test folder: $tmp"
try {
    Initialize-ToolPaths -CodeFolder $fakeCode
    $global:ST.Config = $realConfig
    [void](Import-ToolSettings)
    Open-ToolDatabase

    # --- paths and names
    $abs = ConvertTo-AbsPath 'Input/A/b.jpg'
    Assert-True ((ConvertTo-RelPath $abs) -eq 'Input/A/b.jpg') 'Relative path round trip'
    Assert-True ((Get-SuffixedName -Name 'Image.jpg' -Number 2) -eq 'Image_2.jpg') 'Suffix _2 before the extension'
    Assert-True ((Get-RelParent 'Input/A/b.jpg') -eq 'Input/A') 'Parent of a relative path'
    Assert-True ($null -ne (Get-InvalidNameReason 'a:b')) 'Invalid characters are refused'
    Assert-True ($null -eq (Get-InvalidNameReason 'Tokio Shibuya')) 'Valid name is accepted'

    # --- capture date from file names (2.1 section 4)
    $d = Get-DateFromFileName 'IMG_20240713_183012.jpg'
    Assert-True ($d -eq [datetime]'2024-07-13 18:30:12') 'Date from IMG_yyyyMMdd_HHmmss'
    $d = Get-DateFromFileName 'IMG-20240713-WA0001.jpg'
    Assert-True ($d -eq [datetime]'2024-07-13') 'Date from WhatsApp name'
    $d = Get-DateFromFileName 'Screenshot_2024-07-13-10-11-12.png'
    Assert-True ($d -eq [datetime]'2024-07-13 10:11:12') 'Date from screenshot name'
    Assert-True ($null -eq (Get-DateFromFileName 'IMG_1234.jpg')) 'No date in a camera counter name'

    # --- test files
    [void][System.IO.Directory]::CreateDirectory((ConvertTo-AbsPath 'Input/Phone'))
    [System.IO.File]::WriteAllText((ConvertTo-AbsPath 'Input/Phone/note.txt'), 'same content')
    [System.IO.File]::WriteAllText((ConvertTo-AbsPath 'Input/copy.txt'), 'same content')
    [void][System.IO.Directory]::CreateDirectory((ConvertTo-AbsPath 'Result/Docs'))
    [System.IO.File]::WriteAllText((ConvertTo-AbsPath 'Result/Docs/original.txt'), 'unique in result')
    [System.IO.File]::WriteAllText((ConvertTo-AbsPath 'Input/dupe-of-result.txt'), 'unique in result')
    $bmp = New-Object System.Drawing.Bitmap 64, 48
    for ($x = 0; $x -lt 64; $x++) { for ($y = 0; $y -lt 48; $y++) { $bmp.SetPixel($x, $y, [System.Drawing.Color]::FromArgb(255, $x * 4, $y * 5, 100)) } }
    $bmp.Save((ConvertTo-AbsPath 'Input/IMG_20230514_101112.png'), [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()

    # --- 2.1 InitializeFolder
    $r = Invoke-Function 'Database' 'InitializeFolder' @{ Folder = 'Result' }
    Assert-True ($r.Kind -eq 'Done') 'InitializeFolder Result finishes'
    $r = Invoke-Function 'Database' 'InitializeFolder' @{ Folder = 'Input' }
    Assert-True ($r.Kind -eq 'Done') 'InitializeFolder Input finishes'
    $count = Invoke-DbScalar 'SELECT COUNT(*) FROM Files'
    Assert-True ($count -eq 5) "Five files recorded (found $count)"
    $img = Get-FileEntry 'Input/IMG_20230514_101112.png'
    Assert-True ($img -and $img.SimilarityHash) 'dHash computed for the image'
    Assert-True ($img -and $img.CaptureDateSource -eq 'FileName' -and ([string]$img.CaptureDate).StartsWith('2023-05-14')) 'Capture date of the image from its file name'
    $r = Invoke-Function 'Database' 'InitializeFolder' @{ Folder = 'Input' }
    Assert-True ($r.Message -match 'unverändert 4') 'Second run finds everything unchanged'

    # --- 2.2 FindDuplicates
    $plan = Invoke-Function 'Database' 'FindDuplicates'
    Assert-True ($plan.Kind -eq 'Plan') 'FindDuplicates returns a plan'
    $moves = @($plan.Items | Where-Object { $_.Action -eq 'MoveFile' })
    $links = @($plan.Items | Where-Object { $_.Action -eq 'CreateLink' })
    Assert-True ($moves.Count -eq 2) "Two duplicates found (found $($moves.Count))"
    Assert-True ($links.Count -eq 4) 'Two shortcuts per duplicate'
    $toResult = @($moves | Where-Object { $_.Source -eq 'Input/dupe-of-result.txt' })
    Assert-True ($toResult.Count -eq 1 -and $toResult[0].Data.Original -eq 'Result/Docs/original.txt') 'Original in Result is preferred'
    $log = Invoke-Plan -Plan $plan
    Assert-True ($log.Errors -eq 0) 'FindDuplicates executes without errors'
    Assert-True (Test-RelExists 'ToDelete/Doublets/dupe-of-result.txt') 'Duplicate moved to ToDelete/Doublets'
    Assert-True (Test-RelExists 'ToDelete/Doublets/dupe-of-result.txt - Result File.lnk') 'File shortcut created'
    Assert-True (Test-RelExists 'ToDelete/Doublets/dupe-of-result.txt - Result Folder.lnk') 'Folder shortcut created'
    Assert-True ($null -ne (Get-FileEntry 'ToDelete/Doublets/dupe-of-result.txt')) 'Database path follows the move'
    $unchecked = Invoke-DbScalar "SELECT COUNT(*) FROM Files WHERE lower(substr(Path,1,6)) = 'input/' AND (DuplicateChecked IS NULL OR DuplicateChecked = '')"
    Assert-True ($unchecked -eq 0) 'All checked files are marked as checked'

    # --- preview model (no window)
    $plan2 = New-Plan -Title 'Test' -Group 'Test' -Script 'Test' -Roots @('Input')
    [void](Add-PlanItem -Plan $plan2 -Action 'MoveFile' -Source 'Input/IMG_20230514_101112.png' -Target 'Input/2023-05-14/IMG_20230514_101112.png')
    [void](Add-PlanItem -Plan $plan2 -Action 'CreateFolder' -Target 'Input/2023-05-14')
    $S = @{ Plan = $plan2; Listing = @{}; CollapsedFolders = (New-PathSet); ExpandedRuns = (New-PathSet); ExpandAll = $false; Filter = $null }
    Build-PreviewModel $S
    $rows = Get-PreviewRows $S
    $red = @($rows | Where-Object { $_.Kind -eq 'Node' -and $_.State -eq 'Removed' })
    $green = @($rows | Where-Object { $_.Kind -eq 'Node' -and $_.State -eq 'Added' })
    Assert-True ($red.Count -eq 1) 'Preview: one red row for the file leaving'
    Assert-True ($green.Count -eq 2) 'Preview: green rows for the new folder and the arriving file'

    # --- undo of FindDuplicates (base section 9, 2.2 section 7)
    $logs = Get-UndoableLogs
    Assert-True ($logs.Count -ge 1 -and $logs[0].Name -like '*FindDuplicates*') 'FindDuplicates log is offered for undo'
    $undo = New-UndoPlan -ActionLog $logs[0]
    $undoLog = Invoke-Plan -Plan $undo
    Assert-True ($undoLog.Errors -eq 0) 'Undo executes without errors'
    Assert-True (Test-RelExists 'Input/dupe-of-result.txt') 'Duplicate is back in Input'
    Assert-True (-not (Test-RelExists 'ToDelete/Doublets/dupe-of-result.txt - Result File.lnk')) 'Own shortcuts removed on undo'
    Assert-True ($null -ne (Get-FileEntry 'Input/dupe-of-result.txt')) 'Database path reset on undo'
    Assert-True ((Split-Path -Leaf $undoLog.Saved) -like '* - Undo - Database - FindDuplicates.log') 'Undo writes its own log'

    # --- 2.4 RemoveStaleEntries (the test removes one of its own test files)
    Start-Sleep -Milliseconds 1100
    [System.IO.File]::Delete((ConvertTo-AbsPath 'Input/copy.txt'))
    $plan3 = Invoke-Function 'Database' 'RemoveStaleEntries'
    Assert-True ($plan3.Kind -eq 'Plan' -and @($plan3.Items).Count -eq 1) 'RemoveStaleEntries finds the missing file'
    [void](Invoke-Plan -Plan $plan3)
    Assert-True ($null -eq (Get-FileEntry 'Input/copy.txt')) 'Stale row removed'
    $logs = Get-UndoableLogs
    $undo = New-UndoPlan -ActionLog $logs[0]
    Assert-True (Test-PlanDatabaseOnly $undo) 'Undo of RemoveStaleEntries is database only'
    [void](Invoke-Plan -Plan $undo)
    Assert-True ($null -ne (Get-FileEntry 'Input/copy.txt')) 'Removed row restored by undo'

    # --- conflict naming and moves keep the database in sync
    $l = New-ActionLog -Group 'Test' -Script 'Move'
    [System.IO.File]::WriteAllText((ConvertTo-AbsPath 'Result/Docs/note.txt'), 'other')
    $final = Move-FileTracked -Source 'Input/Phone/note.txt' -Target 'Result/Docs/note.txt' -Log $l -AllowSuffix
    Assert-True ($final -eq 'Result/Docs/note_2.txt') 'Name conflict gives _2'
    $removed = Remove-EmptyInputFolders -Candidates @('Input/Phone') -Log $l
    Assert-True (-not (Test-RelExists 'Input/Phone')) 'Emptied Input folder removed'
    Assert-True ($null -ne (Get-FileEntry 'Result/Docs/note_2.txt')) 'Entry follows the renamed move'
}
catch {
    $script:failed++
    Write-Host "FAIL  Unexpected error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace
}
finally {
    Close-ToolDatabase
    # The temporary test folder belongs to this test only.
    try { Remove-Item -LiteralPath $tmp -Recurse -Force } catch { Write-Host "Test folder could not be removed: $tmp" }
}
Write-Host ''
Write-Host "Passed: $script:passed   Failed: $script:failed"
