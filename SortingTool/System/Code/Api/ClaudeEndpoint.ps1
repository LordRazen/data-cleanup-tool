# ClaudeEndpoint.ps1 (3.1)
# Lets functions ask Claude through the locally installed Claude Code in headless mode:
#   claude -p --output-format json   (prompt on standard input)
# This runs on the Claude subscription. Never pay per use: the variables ANTHROPIC_API_KEY and
# ANTHROPIC_AUTH_TOKEN are removed for the started process, so Claude Code cannot use an API key.
# Claude may only read the passed files: they are copied under neutral names into the empty
# working folder System/Temp/Claude, the call runs there and allows no tool except Read.
# One call at a time. Usage limits are detected and waited for (Invoke-ClaudeWithLimitWait).

$global:ST.ClaudeRun = @{ Calls = 0; Skipped = $false }
$global:ST.ClaudeStatus = $null

function Reset-ClaudeRun {
    # Called at the start of every function run (maxCallsPerRun, "Rest überspringen").
    $global:ST.ClaudeRun.Calls = 0
    $global:ST.ClaudeRun.Skipped = $false
}

function New-ClaudeResult {
    param([bool]$Success, $Data = $null, [string]$ErrorText = '', [string]$ErrorKind = '', [long]$DurationMs = 0, $ResetTime = $null, [string]$Text = '')
    return [pscustomobject]@{ Success = $Success; Data = $Data; Error = $ErrorText; ErrorKind = $ErrorKind; DurationMs = $DurationMs; ResetTime = $ResetTime; Text = $Text }
}

function Resolve-ClaudeExecutable {
    # Full path of Claude Code, or $null if it cannot be found.
    $exe = [string]$global:ST.Settings.api.claude.executable
    if (-not $exe) { $exe = 'claude' }
    if ([System.IO.File]::Exists($exe)) { return $exe }
    $cmds = @(Get-Command $exe -CommandType Application -ErrorAction SilentlyContinue)
    # npm installs claude.cmd and claude.ps1; the .cmd or .exe is used.
    $best = $cmds | Where-Object { $_.Path -match '\.(exe|cmd|bat)$' } | Select-Object -First 1
    if ($best) { return $best.Path }
    foreach ($candidate in @(
            (Join-Path $env:USERPROFILE '.local\bin\claude.exe'),
            (Join-Path $env:APPDATA 'npm\claude.cmd'),
            (Join-Path $env:LOCALAPPDATA 'Programs\claude\claude.exe'))) {
        if ($candidate -and [System.IO.File]::Exists($candidate)) { return $candidate }
    }
    return $null
}

function Get-ClaudeWorkingFolder {
    $rel = [string]$global:ST.Settings.api.claude.workingFolder
    if (-not $rel) { $rel = 'System/Temp/Claude' }
    $abs = ConvertTo-AbsPath $rel
    if (-not [System.IO.Directory]::Exists($abs)) { [void][System.IO.Directory]::CreateDirectory($abs) }
    return $abs
}

function Clear-ClaudeWorkingFolder {
    # Removes the temporary copies the tool itself wrote into System/Temp/Claude (never user files).
    $abs = Get-ClaudeWorkingFolder
    foreach ($f in (Get-ChildItem -LiteralPath $abs -File -ErrorAction SilentlyContinue)) {
        if ($f.Name -like 'st_*') { try { $f.Delete() } catch { } }
    }
}

function Test-ClaudeEndpoint {
    # Installed, logged in, enabled (3.1 section 4). -Quick skips the test call (used at start).
    param([switch]$Quick, [switch]$Force)
    $cfg = $global:ST.Settings.api.claude
    if (-not $cfg.enabled) {
        return [pscustomobject]@{ Available = $false; Kind = 'Other'; Message = 'Claude ist in den Einstellungen ausgeschaltet (api.claude.enabled).' }
    }
    if (-not (Resolve-ClaudeExecutable)) {
        return [pscustomobject]@{ Available = $false; Kind = 'NotInstalled'; Message = 'Claude ist nicht installiert. Installiere Claude Code und melde dich einmal mit deinem Konto an.' }
    }
    if ($Quick) { return [pscustomobject]@{ Available = $true; Kind = ''; Message = '' } }
    if ($global:ST.ClaudeStatus -and -not $Force) { return $global:ST.ClaudeStatus }
    $answer = Invoke-ClaudeEndpoint -Prompt 'Reply with the single word OK.' -NoCount
    $status = [pscustomobject]@{ Available = $true; Kind = ''; Message = '' }
    if (-not $answer.Success) {
        switch ($answer.ErrorKind) {
            'NotLoggedIn' { $status = [pscustomobject]@{ Available = $false; Kind = 'NotLoggedIn'; Message = 'Claude ist nicht angemeldet. Starte einmal ‚claude‘ in der Eingabeaufforderung und melde dich an.' } }
            'NotInstalled' { $status = [pscustomobject]@{ Available = $false; Kind = 'NotInstalled'; Message = 'Claude ist nicht installiert. Installiere Claude Code und melde dich einmal mit deinem Konto an.' } }
            'LimitReached' { $status = [pscustomobject]@{ Available = $true; Kind = 'LimitReached'; Message = 'Das Claude-Nutzungslimit ist gerade erreicht.' } }
            default { $status = [pscustomobject]@{ Available = $false; Kind = $answer.ErrorKind; Message = "Claude antwortet nicht: $($answer.Error)" } }
        }
    }
    if ($status.Kind -ne 'LimitReached') { $global:ST.ClaudeStatus = $status }
    return $status
}

function Get-ClaudeResetTime {
    # Reads the reset time from a limit message, e.g. "...limit reached|1730390400" or "resets 3pm".
    param([string]$Text)
    $m = [regex]::Match($Text, '\|(\d{10})\b')
    if ($m.Success) { return ([System.DateTimeOffset]::FromUnixTimeSeconds([long]$m.Groups[1].Value)).LocalDateTime }
    $m = [regex]::Match($Text, '(?i)reset[s]?\s*(at\s*)?(?<h>\d{1,2})(:(?<m>\d{2}))?\s*(?<ap>am|pm)?')
    if ($m.Success) {
        $h = [int]$m.Groups['h'].Value
        $mi = 0
        if ($m.Groups['m'].Success) { $mi = [int]$m.Groups['m'].Value }
        $ap = $m.Groups['ap'].Value.ToLowerInvariant()
        if ($ap -eq 'pm' -and $h -lt 12) { $h += 12 }
        if ($ap -eq 'am' -and $h -eq 12) { $h = 0 }
        if ($h -gt 23 -or $mi -gt 59) { return $null }
        $t = (Get-Date).Date.AddHours($h).AddMinutes($mi)
        if ($t -le (Get-Date)) { $t = $t.AddDays(1) }
        return $t
    }
    return $null
}

function Get-ClaudeErrorKind {
    param([string]$Text)
    if ($Text -match '(?i)usage limit|limit reached|hit your limit|reached your limit|rate.?limit|out of (extra )?usage|5-hour limit|weekly limit') { return 'LimitReached' }
    if ($Text -match '(?i)not logged in|please run /login|run claude login|invalid api key|authentication|unauthorized|log in') { return 'NotLoggedIn' }
    return ''
}

function ConvertFrom-ClaudeJsonText {
    # Extracts the JSON object from Claude's answer (also inside ``` fences). Returns $null if none.
    param([string]$Text)
    if (-not $Text) { return $null }
    $t = $Text.Trim()
    $t = [regex]::Replace($t, '^```(json)?\s*', '')
    $t = [regex]::Replace($t, '\s*```$', '')
    $start = $t.IndexOf('{')
    $end = $t.LastIndexOf('}')
    if ($start -lt 0 -or $end -le $start) { return $null }
    try { return ($t.Substring($start, $end - $start + 1) | ConvertFrom-Json) } catch { return $null }
}

function Invoke-ClaudeEndpoint {
    # One call. -File / -Files: relative paths (from SortingTool) or absolute paths of files Claude may read.
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [string]$File = '',
        [string[]]$Files = @(),
        [switch]$ExpectJson,
        [switch]$NoCount
    )
    $cfg = $global:ST.Settings.api.claude
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    if (-not $cfg.enabled) { return (New-ClaudeResult -Success $false -ErrorText 'Endpoint disabled' -ErrorKind 'Other') }
    $exe = Resolve-ClaudeExecutable
    if (-not $exe) { return (New-ClaudeResult -Success $false -ErrorText 'Claude Code not found' -ErrorKind 'NotInstalled') }
    if (-not $NoCount) {
        if ($global:ST.ClaudeRun.Calls -ge [int]$cfg.maxCallsPerRun) {
            return (New-ClaudeResult -Success $false -ErrorText 'maxCallsPerRun reached' -ErrorKind 'Other')
        }
        $global:ST.ClaudeRun.Calls++
    }

    $work = Get-ClaudeWorkingFolder
    Clear-ClaudeWorkingFolder
    $allFiles = @()
    if ($File) { $allFiles += $File }
    $allFiles += @($Files | Where-Object { $_ })
    $names = @()
    $k = 0
    foreach ($f in $allFiles) {
        $k++
        $abs = $f
        if (-not [System.IO.Path]::IsPathRooted($abs)) { $abs = ConvertTo-AbsPath $f }
        if (-not [System.IO.File]::Exists($abs)) { return (New-ClaudeResult -Success $false -ErrorText "File not found: $f" -ErrorKind 'Other') }
        # Neutral name: no file names or folders are sent unless the prompt contains them.
        $name = 'st_{0:D2}{1}' -f $k, [System.IO.Path]::GetExtension($abs).ToLowerInvariant()
        $dest = Join-Path $work $name
        if (-not [string]::Equals([System.IO.Path]::GetFullPath($abs), $dest, [System.StringComparison]::OrdinalIgnoreCase)) {
            [System.IO.File]::Copy($abs, $dest, $true)
        }
        $names += $name
    }
    $fullPrompt = $Prompt
    if ($names.Count -gt 0) {
        $fullPrompt += "`n`nThe image files are in the current folder: " + (($names | ForEach-Object { "./$_" }) -join ', ') + '. Look at them with the Read tool. Do not use any other tool.'
    }
    if ($ExpectJson) { $fullPrompt += "`n`nAnswer only with the JSON object, no other text." }

    $arguments = '-p --output-format json --max-turns 8 --allowedTools Read --disallowedTools Bash,Edit,MultiEdit,Write,NotebookEdit,WebFetch,WebSearch,Task,TodoWrite'
    if ($cfg.model) { $arguments += ' --model ' + [string]$cfg.model }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    if ($exe -match '\.(cmd|bat)$') {
        $psi.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
        $psi.Arguments = '/d /s /c ""' + $exe + '" ' + $arguments + '"'
    }
    else {
        $psi.FileName = $exe
        $psi.Arguments = $arguments
    }
    $psi.WorkingDirectory = $work
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    # Guarantee for the subscription (3.1 section 3): no API key for the started process.
    foreach ($var in @('ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN')) {
        if ($psi.EnvironmentVariables.ContainsKey($var)) { $psi.EnvironmentVariables.Remove($var) }
    }
    $process = $null
    try {
        $process = [System.Diagnostics.Process]::Start($psi)
        $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($fullPrompt)
        $process.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        $process.StandardInput.BaseStream.Flush()
        $process.StandardInput.Close()
        $outTask = $process.StandardOutput.ReadToEndAsync()
        $errTask = $process.StandardError.ReadToEndAsync()
        $timeout = [int]$cfg.timeoutSeconds
        while (-not $process.WaitForExit(200)) {
            [System.Windows.Forms.Application]::DoEvents()
            if ($watch.Elapsed.TotalSeconds -gt $timeout) {
                try { & taskkill.exe /PID $process.Id /T /F 2>$null | Out-Null } catch { }
                return (New-ClaudeResult -Success $false -ErrorText "No answer within $timeout seconds" -ErrorKind 'Timeout' -DurationMs $watch.ElapsedMilliseconds)
            }
        }
        $process.WaitForExit()
        $stdout = $outTask.Result
        $stderr = $errTask.Result
    }
    catch {
        return (New-ClaudeResult -Success $false -ErrorText $_.Exception.Message -ErrorKind 'Other' -DurationMs $watch.ElapsedMilliseconds)
    }
    finally {
        if ($process) { $process.Dispose() }
        Clear-ClaudeWorkingFolder
    }
    $duration = $watch.ElapsedMilliseconds

    $envelope = $null
    try { $envelope = $stdout | ConvertFrom-Json } catch { }
    if ($null -eq $envelope) {
        $text = "$stdout $stderr".Trim()
        $kind = Get-ClaudeErrorKind $text
        if ($kind -eq 'LimitReached') { return (New-ClaudeResult -Success $false -ErrorText 'Usage limit reached' -ErrorKind 'LimitReached' -DurationMs $duration -ResetTime (Get-ClaudeResetTime $text) -Text $text) }
        if ($kind) { return (New-ClaudeResult -Success $false -ErrorText $text -ErrorKind $kind -DurationMs $duration -Text $text) }
        if ($text -match '(?i)ENOTFOUND|ECONNREFUSED|network|getaddrinfo|offline') { return (New-ClaudeResult -Success $false -ErrorText $text -ErrorKind 'Offline' -DurationMs $duration -Text $text) }
        return (New-ClaudeResult -Success $false -ErrorText "Unreadable answer: $text" -ErrorKind 'InvalidResponse' -DurationMs $duration -Text $text)
    }
    $resultText = ''
    if ($envelope.PSObject.Properties['result']) { $resultText = [string]$envelope.result }
    $isError = $false
    if ($envelope.PSObject.Properties['is_error']) { $isError = [bool]$envelope.is_error }
    if ($isError -or ($envelope.PSObject.Properties['subtype'] -and [string]$envelope.subtype -ne 'success')) {
        $text = "$resultText $stderr".Trim()
        $kind = Get-ClaudeErrorKind $text
        if ($kind -eq 'LimitReached') { return (New-ClaudeResult -Success $false -ErrorText 'Usage limit reached' -ErrorKind 'LimitReached' -DurationMs $duration -ResetTime (Get-ClaudeResetTime $text) -Text $text) }
        if (-not $kind) { $kind = 'Other' }
        return (New-ClaudeResult -Success $false -ErrorText $text -ErrorKind $kind -DurationMs $duration -Text $text)
    }
    if ($ExpectJson) {
        $data = ConvertFrom-ClaudeJsonText $resultText
        if ($null -eq $data) {
            $kind = Get-ClaudeErrorKind $resultText
            if ($kind -eq 'LimitReached') { return (New-ClaudeResult -Success $false -ErrorText 'Usage limit reached' -ErrorKind 'LimitReached' -DurationMs $duration -ResetTime (Get-ClaudeResetTime $resultText) -Text $resultText) }
            return (New-ClaudeResult -Success $false -ErrorText 'Answer is not valid JSON' -ErrorKind 'InvalidResponse' -DurationMs $duration -Text $resultText)
        }
        return (New-ClaudeResult -Success $true -Data $data -DurationMs $duration -Text $resultText)
    }
    return (New-ClaudeResult -Success $true -Data $resultText -DurationMs $duration -Text $resultText)
}

function Invoke-ClaudeWithLimitWait {
    # Like Invoke-ClaudeEndpoint, but waits when the usage limit is reached and continues
    # automatically (3.1 section 5). Shows the wait dialog with countdown and "Rest überspringen".
    # After "Rest überspringen" every further call returns ErrorKind 'Skipped' at once.
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [string[]]$Files = @(),
        [switch]$ExpectJson,
        [string]$ProgressText = ''
    )
    if ($global:ST.ClaudeRun.Skipped) { return (New-ClaudeResult -Success $false -ErrorText 'Skipped by user' -ErrorKind 'Skipped') }
    while ($true) {
        $answer = Invoke-ClaudeEndpoint -Prompt $Prompt -Files $Files -ExpectJson:$ExpectJson
        if ($answer.Success -or $answer.ErrorKind -ne 'LimitReached') { return $answer }
        # The call did not count, it will be repeated.
        if ($global:ST.ClaudeRun.Calls -gt 0) { $global:ST.ClaudeRun.Calls-- }
        $retryMinutes = [Math]::Max(1, [int]$global:ST.Settings.api.claude.limitRetryMinutes)
        $known = $null -ne $answer.ResetTime
        while ($true) {
            if ($known) { $until = $answer.ResetTime.AddMinutes(1) } else { $until = (Get-Date).AddMinutes($retryMinutes) }
            Write-StatusText "Claude-Nutzungslimit erreicht, warte bis $($until.ToString('HH:mm')) …"
            $choice = Show-WaitDialog -Until $until -ProgressText $ProgressText -RetryMode:(-not $known)
            if ($choice -eq 'Skip') {
                $global:ST.ClaudeRun.Skipped = $true
                return (New-ClaudeResult -Success $false -ErrorText 'Skipped by user' -ErrorKind 'Skipped')
            }
            if ($known) { break }
            # No reset time known: check with a tiny test call, no fast retries (3.1 section 5).
            $probe = Invoke-ClaudeEndpoint -Prompt 'Reply with the single word OK.' -NoCount
            if ($probe.Success) { break }
            if ($probe.ErrorKind -ne 'LimitReached') { return $probe }
            if ($null -ne $probe.ResetTime) { $answer = $probe; $known = $true }
        }
    }
}

function Format-ApiCallExtra {
    # Text of an API_CALL log line: result, duration and a short summary (3 - API.md section 4).
    param($Answer, [string]$Summary = '')
    $result = 'OK'
    if (-not $Answer.Success) { $result = $Answer.ErrorKind }
    $text = "$result | $($Answer.DurationMs) ms"
    if ($Summary) { $text += " | $Summary" }
    return $text
}
