[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$LogFile,

    [int]$AfterLine = 0,

    [int]$DebounceSeconds = 8,

    [int]$MaxWaitSeconds = 600,

    [int]$PollMs = 500,

    [int]$MaxOutputChars = 3000,

    # Deprecated no-op: kept only so legacy conversations passing this flag
    # do not error out; speech-only mode is ALWAYS enforced.
    [switch]$IncludeAllEvents
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom

function Read-AllLinesShared([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        return @()
    }
    $fs = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    $reader = [System.IO.StreamReader]::new($fs, $utf8NoBom)
    $list = [System.Collections.Generic.List[string]]::new()
    try {
        while ($null -ne ($line = $reader.ReadLine())) {
            $list.Add($line)
        }
    } finally {
        $reader.Dispose()
        $fs.Dispose()
    }
    return $list.ToArray()
}

function Test-IsSpeechTriggerLine([string]$Line) {
    if ([string]::IsNullOrWhiteSpace($Line)) { return $false }
    if ($Line -match '^\[\d{2}:\d{2}:\d{2}\] \[(Codex说|ERROR|DONE|HANDOFF_REQUIRED)\]') { return $true }
    if ($Line -match '^\[STDERR\]') { return $true }
    return $false
}

function Test-ShouldEmitInSpeechMode([string]$Line) {
    if ([string]::IsNullOrWhiteSpace($Line)) { return $false }
    if ($Line -match '^\[\d{2}:\d{2}:\d{2}\] \[(SESSION|Codex说|ERROR|DONE|HEALTH|HANDOFF_REQUIRED)\]') { return $true }
    if ($Line -match '^\[(STDERR|END)\]') { return $true }
    return $false
}

function Get-RunnerPid([string[]]$Lines) {
    if ($Lines.Count -gt 0 -and $Lines[0] -match '^\[META\]\s+pid=(\d+)') {
        return [int]$Matches[1]
    }
    return $null
}

function Test-ProcessAlive($ProcId) {
    if ($null -eq $ProcId) { return $true }
    $p = Get-Process -Id ([int]$ProcId) -ErrorAction SilentlyContinue
    return ($null -ne $p)
}

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$debounceSw = $null
$runnerPid = $null
$status = 'HEARTBEAT'
[string[]]$allLines = @()

while ($true) {
    $allLines = @(Read-AllLinesShared -Path $LogFile)
    if ($null -eq $runnerPid -and $allLines.Count -gt 0) {
        $runnerPid = Get-RunnerPid -Lines $allLines
    }

    [string[]]$newSlice = @(if ($allLines.Count -gt $AfterLine) {
        $allLines[$AfterLine..($allLines.Count - 1)]
    })

    $hasEnd = $false
    $hasTrigger = $false
    foreach ($l in $newSlice) {
        if ($l -match '^\[END\]') {
            $hasEnd = $true
            $hasTrigger = $true
        } elseif (Test-IsSpeechTriggerLine $l) {
            $hasTrigger = $true
        }
    }

    if ($hasEnd) {
        $status = 'COMPLETED'
        break
    }

    if ($null -ne $runnerPid -and -not (Test-ProcessAlive $runnerPid)) {
        Start-Sleep -Milliseconds 150
        $allLines = @(Read-AllLinesShared -Path $LogFile)
        $status = 'COMPLETED'
        break
    }

    if ($hasTrigger) {
        if ($null -eq $debounceSw) {
            $debounceSw = [System.Diagnostics.Stopwatch]::StartNew()
        }
        if ($debounceSw.Elapsed.TotalSeconds -ge $DebounceSeconds) {
            $status = 'UPDATE'
            break
        }
    }

    if ($sw.Elapsed.TotalSeconds -ge $MaxWaitSeconds) {
        $status = if ($hasTrigger) { 'UPDATE' } else { 'HEARTBEAT' }
        break
    }

    Start-Sleep -Milliseconds $PollMs
}

$nextLine = $allLines.Count
$elapsedSec = [int][Math]::Round($sw.Elapsed.TotalSeconds)
[string[]]$rawNewLines = @(if ($nextLine -gt $AfterLine) {
    $allLines[$AfterLine..($nextLine - 1)]
})

[string[]]$emitLines = @($rawNewLines | Where-Object { Test-ShouldEmitInSpeechMode $_ })

$aliveFlag = if ($status -eq 'COMPLETED') { 'exited' } else { 'alive' }
$ignoredNote = if ($IncludeAllEvents) { ' | note=-IncludeAllEvents_ignored_speech_only_locked' } else { '' }
[Console]::Out.WriteLine("[WATCHER] status=$status | mode=speech-only-locked | runner=$aliveFlag | next_line=$nextLine | speech_lines=$($emitLines.Count) | elapsed=${elapsedSec}s$ignoredNote")

if ($emitLines.Count -gt 0) {
    $joined = $emitLines -join "`n"
    if ($joined.Length -gt $MaxOutputChars) {
        $truncated = $joined.Substring(0, $MaxOutputChars)
        [Console]::Out.WriteLine($truncated)
        [Console]::Out.WriteLine("[WATCHER_TRUNCATED] Output exceeded $MaxOutputChars chars; inspect full log at $LogFile (lines $($AfterLine + 1)-$nextLine)")
    } else {
        [Console]::Out.WriteLine($joined)
    }
}

[Console]::Out.Flush()
exit 0
