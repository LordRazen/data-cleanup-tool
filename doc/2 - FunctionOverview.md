# 2 Function Overview (v2.6)

List of all functions of the SortingTool and the buttons that call them. General rules are defined in the base specification (`1 - Base.md`).

Language rule: this document, the code and all descriptions in the code are in English. Only values visible in the GUI (button labels, group labels, tooltips, messages) are in German. They are marked as "GUI label".

## File naming
- All specifications are numbered hierarchically so they sort in the right order: `1 - Base.md`, `2 - FunctionOverview.md`, then one file per function `2.<n> - <InternalName>.md`.
- External services that functions can call are specified in `3 - API.md`, one file per endpoint `3.<n> - <Name>Endpoint.md`.

## Buttons and functions
- A **function** is one script with one clearly separated task (e.g. record files in the database, find duplicates).
- A **button** calls one or more functions in a fixed order (function chain).
- Chain behaviour (confirmed):
  - Each function runs completely before the next one starts: plan, preview, execute, log.
  - A function without file changes (e.g. `InitializeFolder`) shows no preview, only its summary, and the chain continues.
  - If a preview is cancelled ("Abbrechen"), the chain stops. Nothing of that function is changed. Functions already finished stay as they are.
  - If a function fails as a whole (e.g. database not reachable), the chain stops.
  - Each function writes its own log file. Undo works per function log.
- A button can pass arguments to a function (e.g. `InitializeFolder` with `-Folder Input`). Arguments are written like PowerShell parameters.
- For group buttons, `layout.json` gets a list `functions` instead of a single `script` (see "Notes on the base").

## Functions

| No. | Internal name | Script | Scope | Status |
|---|---|---|---|---|
| 2.1 | `InitializeFolder` | `Code/Database/InitializeFolder.ps1` | only the folder passed with `-Folder` (`Input` or `Result`), database only | v0.13, no open questions |
| 2.2 | `FindDuplicates` | `Code/Database/FindDuplicates.ps1` | `InputAndResult`, moves only from Input to `ToDelete/Doublets` | v0.8, no open questions |
| 2.3 | `GroupByCaptureDate` | `Code/Images/GroupByCaptureDate.ps1` | `Input` | v0.7, no open questions |
| 2.4 | `RemoveStaleEntries` | `Code/Database/RemoveStaleEntries.ps1` | all entries (Input, Result, ToDelete), database only | v0.3, no open questions |
| 2.5 | `MoveToResult` | `Code/Database/MoveToResult.ps1` | `InputAndResult`, moves only from Input to Result | v0.3, no open questions |
| 2.6 | `DeterminePlaceByGps` | `Code/Images/DeterminePlaceByGps.ps1` | `Input`, renames day folders | v0.2, no open questions |
| 2.7 | `DeterminePlaceByClaude` | `Code/Images/DeterminePlaceByClaude.ps1` | `Input`, renames day folders | v0.2, no open questions |
| 2.8 | `CategorizeImages` | `Code/Images/CategorizeImages.ps1` | `InputAndResult`, moves loose images from Input to `Result/<Category>` or to `ToDelete/<Category>` (e.g. Memes) | v0.6, 6 open questions; pre-assessment by file name; one spec per category `2.8.<n> - <Category>.md` |
| – | `Undo` | part of `Common.ps1` | same as the action being undone | done, base section 9 |

## Fixed buttons (bottom of the main window)

| GUI label | Calls (in order) |
|---|---|
| Input initialisieren | `InitializeFolder -Folder Input`, then `FindDuplicates` |
| Result initialisieren | `InitializeFolder -Folder Result` |
| Datenbank bereinigen | `RemoveStaleEntries` |
| Nach Result verschieben | `MoveToResult` |
| Aktion rückgängig machen | `Undo` |

## Group buttons

| Group (GUI label) | Group (internal name) | GUI label | Calls (in order) |
|---|---|---|---|
| Bilder | `Images` | Nach Aufnahmedatum gruppieren | `GroupByCaptureDate` |
| Bilder | `Images` | Ort bestimmen (OpenStreetMap) | `DeterminePlaceByGps` |
| Bilder | `Images` | Ort bestimmen (Claude) | `DeterminePlaceByClaude` |
| Bilder | `Images` | Bilder kategorisieren (Claude) | `CategorizeImages` |
| Dokumente | `Documents` | none yet | |
| Songs | `Songs` | none yet | |

## Rules for new functions
- One file per function, numbered `2.<n> - <InternalName>.md`.
- Parts of a function (e.g. the categories of `CategorizeImages`) get their own files `2.<n>.<m> - <Name>.md`, in the repository in a folder named like the function file.
- Each function explicitly states whether it works in Input only (`Input`) or in Input and Result (`InputAndResult`).
- Every new function is added to the table "Functions", every button to the matching button table.

## Notes on the base (not entered there)
- Base sections 6 and 7 say: one button starts exactly one script. With function chains, a button calls a list of functions. Example for `layout.json`:
```json
{
  "label": "Input initialisieren",
  "functions": [
    { "name": "InitializeFolder", "arguments": { "Folder": "Input" } },
    { "name": "FindDuplicates" }
  ],
  "description": "Erfasst neue Dateien in Input und sortiert Doubletten aus"
}
```
- Functions of the fixed buttons live in `System/Code/Database/`, since they do not belong to a group.

## Open questions
- None.
