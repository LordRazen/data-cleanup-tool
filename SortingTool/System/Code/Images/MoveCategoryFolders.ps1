# MoveCategoryFolders.ps1 (2.9)
# Moves the content of the category folders in Input (created by CategorizeImages, 2.8) to their
# target, keeping the subfolders: target "Result" -> Result/<folder>, target "ToDelete" ->
# ToDelete/<folder>, Default "Sonstiges" -> Result/Sonstiges. Renames nothing except "_2" on name
# conflicts. A file whose identical copy (same hash) is already in the target is not moved.

param($Context, [hashtable]$Arguments = @{})

$defs = Get-CategoryDefinitions
$folders = New-Object System.Collections.Generic.List[object]
foreach ($d in $defs) {
    $root = 'Result'
    if ([string]$d.target -eq 'ToDelete') { $root = 'ToDelete' }
    $folders.Add(@{ Source = "Input/$($d.folder)"; Target = "$root/$($d.folder)"; Label = [string]$d.label; Root = $root })
}
$folders.Add(@{ Source = 'Input/Sonstiges'; Target = 'Result/Sonstiges'; Label = 'Sonstiges'; Root = 'Result' })

$plan = New-Plan -Title 'Kategorien verschieben' -Group 'Images' -Script 'MoveCategoryFolders' -Roots @('Input', 'Result', 'ToDelete')
$reserved = New-PathSet
$unchecked = 0
$groupCounts = [ordered]@{}
Start-DbTransaction
try {
    foreach ($f in $folders) {
        $abs = ConvertTo-AbsPath $f.Source
        if (-not [System.IO.Directory]::Exists($abs)) { continue }
        $files = Get-FilesRecursive $abs
        $count = 0
        foreach ($file in ($files | Sort-Object FullName)) {
            $rel = ConvertTo-RelPath $file.FullName
            $below = $rel.Substring($f.Source.Length + 1)
            $target = "$($f.Target)/$below"
            $entry = Get-FileEntry $rel
            if ($null -eq $entry -or [string]::IsNullOrEmpty([string]$entry.DuplicateChecked)) { $unchecked++ }
            if ((Test-RelExists $target) -or $reserved.Contains($target)) {
                $same = $false
                if (Test-RelExists $target) {
                    try {
                        $a = Resolve-FileEntry $rel
                        $b = Resolve-FileEntry $target
                        if ($a -and $b -and [string]$a.Hash -eq [string]$b.Hash) { $same = $true }
                    }
                    catch { }
                }
                if ($same) {
                    [void](Add-PlanItem -Plan $plan -Action 'MoveFile' -Source $rel -Target $target -Locked $true `
                            -Conflict 'Same file already in target (duplicate). Run "Input initialisieren" first.' `
                            -Info 'Konflikt: Gleiche Datei liegt schon im Ziel (Doublette). Vorher „Input initialisieren“ ausführen.')
                    continue
                }
                $target = Get-UniqueRelPath -RelPath $target -Reserved $reserved
            }
            [void]$reserved.Add($target)
            $item = Add-PlanItem -Plan $plan -Action 'MoveFile' -Source $rel -Target $target -Info "$($f.Label) → $($f.Root)"
            $item.Data.Group = $f.Label
            $count++
        }
        if ($count -gt 0) { $groupCounts["$($f.Label) → $($f.Root)"] = $count }
    }
}
finally { Complete-DbTransaction }

if ($plan.Items.Count -eq 0) {
    return (New-FunctionResult -Kind Message -Message 'Kategorien verschieben: In den Kategorieordnern in Input liegen keine Dateien.')
}
if ($unchecked -gt 0) {
    $answer = Show-ChoiceDialog -Text 'Einige Dateien wurden noch nicht auf Doubletten geprüft. Vorher „Input initialisieren“ ausführen?' `
        -Buttons @('Trotzdem fortfahren', 'Abbrechen') -Title 'Kategorien verschieben'
    if ($answer -ne 'Trotzdem fortfahren') { return (New-FunctionResult -Kind Cancelled) }
}
$plan.Data.GroupCounts = $groupCounts
$plan.SummaryExtra = {
    param($plan)
    (($plan.Data.GroupCounts.Keys | ForEach-Object { "$_ ($($plan.Data.GroupCounts[$_]))" }) -join '   ')
}
return $plan
