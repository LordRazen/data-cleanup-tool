# Common.ps1
# Shared helpers of the SortingTool (base specification section 4 and 7).
# Moving, renaming, logging, database, undo and all other shared logic live here.
# To keep the file readable, the helpers are split into topic files in Code/Common,
# which this file loads. The API endpoints (Code/Api) are loaded here as well (3 - API.md).
#
# All shared state is kept in one global hashtable $global:ST, so that helper functions
# behave the same no matter from which script (main program, function script, endpoint)
# they are called.

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic

$commonFolder = Join-Path $PSScriptRoot 'Common'
foreach ($file in @(
        'Paths.ps1',
        'Settings.ps1',
        'Database.ps1',
        'Log.ps1',
        'ImageInfo.ps1',
        'FileIndex.ps1',
        'FileOps.ps1',
        'Plan.ps1',
        'Undo.ps1',
        'Dialogs.ps1',
        'Preview.ps1',
        'ListPreview.ps1',
        'TreeDropDown.ps1'
    )) {
    . (Join-Path $commonFolder $file)
}

$apiFolder = Join-Path $PSScriptRoot 'Api'
foreach ($file in @('ClaudeEndpoint.ps1', 'NominatimEndpoint.ps1')) {
    $path = Join-Path $apiFolder $file
    if (Test-Path -LiteralPath $path) { . $path }
}
