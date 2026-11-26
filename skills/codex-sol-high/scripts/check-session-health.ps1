[CmdletBinding()]
param(
    [string]$SessionId,

    [switch]$All,

    [int]$Top = 10,

    [int]$Threshold = 4,

    [int]$PhaseShiftContextTokens = 150000,

    [int]$ColdIdleMinutes = 10,

    [int]$ColdResumeHighContextTokens = 200000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom

$sessionsRoot = Join-Path $env:USERPROFILE '.codex\sessions'
if (-not (Test-Path -LiteralPath $sessionsRoot)) {
    throw "Codex sessions directory not found: $sessionsRoot"
}

function Get-SessionHealth([System.IO.FileInfo]$File, [int]$ShiftAtCompactions) {
    $compactions = 0
    $lastTokenLine = $null
    $resolvedId = $null

    if ($File.Name -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$') {
        $resolvedId = $Matches[1]
    }

    $fs = [System.IO.FileStream]::new($File.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    $reader = [System.IO.StreamReader]::new($fs, $utf8NoBom)
    try {
        while ($null -ne ($line = $reader.ReadLine())) {
            if ($line.Contains('"type":"compacted"')) {
                $compactions++
            } elseif ($line.Contains('"type":"token_usage_record"')) {
                $lastTokenLine = $line
            }
        }
    } finally {
        $reader.Dispose()
        $fs.Dispose()
    }

    $lastContextTokens = $null
    $cumulativeThreadTokens = $null
    if ($lastTokenLine) {
        try {
            $parsed = $lastTokenLine | ConvertFrom-Json -Depth 10
            if ($parsed.payload -and $parsed.payload.usage) {
                $lastContextTokens = $parsed.payload.usage.input_tokens
            }
            if ($parsed.payload -and $parsed.payload.thread_token_usage) {
                $cumulativeThreadTokens = $parsed.payload.thread_token_usage.total_tokens
            }
        } catch {
            # Ignore malformed trailing line if session is still actively flushing
        }
    }

    $idleMinutes = [Math]::Max(0.0, [Math]::Round(((Get-Date) - $File.LastWriteTime).TotalMinutes, 1))
    $phaseShiftEligible = (($null -ne $lastContextTokens -and $lastContextTokens -ge $PhaseShiftContextTokens) -or ($compactions -ge 1))
    $cacheLikelyCold = (($idleMinutes -ge $ColdIdleMinutes) -and ($null -ne $lastContextTokens -and $lastContextTokens -gt $PhaseShiftContextTokens))
    $coldResumeHighPressure = ($cacheLikelyCold -and (($lastContextTokens -gt $ColdResumeHighContextTokens) -or ($compactions -ge 3)))

    return [PSCustomObject]@{
        SessionId              = $resolvedId
        RolloutFile            = $File.FullName
        CompactionCount        = $compactions
        Threshold              = $ShiftAtCompactions
        NeedsHandoffAfterTurn  = ($compactions -ge $ShiftAtCompactions)
        PhaseShiftEligible     = $phaseShiftEligible
        IdleMinutes            = $idleMinutes
        CacheLikelyCold        = $cacheLikelyCold
        ColdResumeHighPressure = $coldResumeHighPressure
        LastContextTokens      = $lastContextTokens
        CumulativeThreadTokens = $cumulativeThreadTokens
        FileSizeMB             = [Math]::Round($File.Length / 1MB, 2)
        LastUpdated            = $File.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
    }
}

if ($SessionId) {
    $target = Get-ChildItem -LiteralPath $sessionsRoot -Recurse -Filter "*$SessionId*.jsonl" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if (-not $target) {
        [PSCustomObject]@{
            SessionId              = $SessionId
            RolloutFile            = $null
            CompactionCount        = 0
            Threshold              = $Threshold
            NeedsHandoffAfterTurn  = $false
            PhaseShiftEligible     = $false
            IdleMinutes            = 0.0
            CacheLikelyCold        = $false
            ColdResumeHighPressure = $false
            Note                   = 'No persisted rollout file found (session may be ephemeral or not yet flushed).'
        } | ConvertTo-Json -Depth 4
        exit 0
    }

    (Get-SessionHealth -File $target -ShiftAtCompactions $Threshold) | ConvertTo-Json -Depth 4
    exit 0
}

$files = Get-ChildItem -LiteralPath $sessionsRoot -Recurse -Filter '*.jsonl' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending

if (-not $All) {
    $files = $files | Select-Object -First $Top
}

$results = foreach ($f in $files) {
    Get-SessionHealth -File $f -ShiftAtCompactions $Threshold
}

@($results) | ConvertTo-Json -Depth 4
