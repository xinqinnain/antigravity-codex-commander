[CmdletBinding()]
param(
    [ValidateSet('exec', 'review', 'resume', 'queue')]
    [string]$Mode = 'exec',

    [string]$Prompt,

    [string]$PromptFile,

    [string]$WorkDir = (Get-Location).Path,

    [ValidateSet('read-only', 'workspace-write', 'danger-full-access')]
    [string]$Sandbox = 'danger-full-access',

    [switch]$ApproveForMe,
    [switch]$Ephemeral,
    [switch]$SkipGitRepoCheck,
    [switch]$Worktree,
    [switch]$RawJson,
    [string]$OutputLastMessage,
    [string]$LogFile,
    [string[]]$Image,
    [string[]]$AddDir,

    # Review mode options
    [switch]$Uncommitted,
    [string]$Base,
    [string]$Commit,
    [string]$Title,

    # Resume / Queue mode options
    [string]$SessionId,
    [switch]$Last,
    [switch]$All,

    # Validation / inspection
    [switch]$DryRun,
    [switch]$NoDispatchDiscipline
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Locked per invocation from user environment variables (defaults: gpt-6.2-sol / high / threshold=4).
# Cannot be overridden via CLI parameters by the calling agent.
$resolvedModel = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_SKILL_MODEL)) {
    $env:CODEX_SKILL_MODEL.Trim()
} else {
    'gpt-6.2-sol'
}

$resolvedReasoning = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_SKILL_REASONING_EFFORT)) {
    $env:CODEX_SKILL_REASONING_EFFORT.Trim()
} else {
    'high'
}

$resolvedThreshold = 4
if (-not [string]::IsNullOrWhiteSpace($env:CODEX_SKILL_COMPACTION_THRESHOLD)) {
    $parsedThreshold = 0
    if ([int]::TryParse($env:CODEX_SKILL_COMPACTION_THRESHOLD.Trim(), [ref]$parsedThreshold) -and $parsedThreshold -ge 1) {
        $resolvedThreshold = $parsedThreshold
    } else {
        throw "Invalid CODEX_SKILL_COMPACTION_THRESHOLD: '$($env:CODEX_SKILL_COMPACTION_THRESHOLD)'. Expected a positive integer."
    }
}

Set-Variable -Name LOCKED_MODEL -Value $resolvedModel -Option ReadOnly
Set-Variable -Name LOCKED_REASONING_EFFORT -Value $resolvedReasoning -Option ReadOnly
Set-Variable -Name COMPACTION_SHIFT_THRESHOLD -Value $resolvedThreshold -Option ReadOnly
Set-Variable -Name DISPATCH_DISCIPLINE_TAG -Value '[Codex 输出与审图纪律]' -Option ReadOnly
Set-Variable -Name DISPATCH_DISCIPLINE_BLOCK -Value @"

[Codex 输出与审图纪律]
1. 输出精简：禁止将大日志、大文件或宽泛 grep 原样打印到 stdout；读取日志/代码/JSON 时必须先过滤关键行、按精准行号区间读取，或用短脚本直接聚合出关键数值与结论摘要。
2. 审图分工：2K/高清截图等视觉审查默认由主控 Antigravity 自己完成；请勿把几 MB 级高清原图读入本会话上下文，仅保存截图文件并汇报图片路径与客观数值指标（除非本轮明确要求你直接看图）。
"@ -Option ReadOnly

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8NoBom
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom

function Resolve-CodexExe {
    $cmd = Get-Command codex -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source -and (Test-Path -LiteralPath $cmd.Source)) {
        return $cmd.Source
    }

    $configPath = Join-Path $env:USERPROFILE '.codex\config.toml'
    if (Test-Path -LiteralPath $configPath) {
        $match = Select-String -LiteralPath $configPath -Pattern "CODEX_CLI_PATH\s*=\s*['""]([^'""]+)['""]" | Select-Object -First 1
        if ($match) {
            $candidate = $match.Matches[0].Groups[1].Value
            if (Test-Path -LiteralPath $candidate) {
                return $candidate
            }
        }
    }

    $localBinRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
    if (Test-Path -LiteralPath $localBinRoot) {
        $latest = Get-ChildItem -LiteralPath $localBinRoot -Recurse -Filter 'codex.exe' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($latest) {
            return $latest.FullName
        }
    }

    $pkg = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pkg -and $pkg.InstallLocation) {
        $appxExe = Join-Path $pkg.InstallLocation 'app\resources\codex.exe'
        if (Test-Path -LiteralPath $appxExe) {
            return $appxExe
        }
    }

    throw 'Codex CLI executable (codex.exe) could not be found on this machine.'
}

function Test-InGitRepo([string]$Path) {
    $current = (Resolve-Path -LiteralPath $Path).Path
    while ($current) {
        if (Test-Path -LiteralPath (Join-Path $current '.git')) {
            return $true
        }
        $parent = Split-Path -Path $current -Parent
        if (-not $parent -or $parent -eq $current) {
            break
        }
        $current = $parent
    }
    return $false
}

function Get-Prop($Obj, [string]$Name) {
    if ($null -eq $Obj) { return $null }
    $prop = $Obj.PSObject.Properties[$Name]
    if ($null -ne $prop) { return $prop.Value }
    return $null
}

function Format-CodexEvent([string]$Line) {
    if ([string]::IsNullOrWhiteSpace($Line)) { return $null }
    $ts = Get-Date -Format 'HH:mm:ss'

    try {
        $evt = $Line | ConvertFrom-Json -Depth 20
    } catch {
        return "[$ts] [RAW] $Line"
    }

    $evtType = Get-Prop $evt 'type'
    switch ($evtType) {
        'thread.started' {
            $tid = Get-Prop $evt 'thread_id'
            return "[$ts] [SESSION] thread_id=$tid | model=$LOCKED_MODEL | reasoning=$LOCKED_REASONING_EFFORT | sandbox=$Sandbox"
        }
        'turn.started' {
            return "[$ts] [TURN] Codex 开始新一轮思考与执行..."
        }
        'turn.completed' {
            $usage = Get-Prop $evt 'usage'
            if ($usage) {
                $inTok = Get-Prop $usage 'input_tokens'
                $outTok = Get-Prop $usage 'output_tokens'
                $reasTok = Get-Prop $usage 'reasoning_output_tokens'
                return "[$ts] [DONE] 本轮完成 (input=$inTok, output=$outTok, reasoning=$reasTok)"
            }
            return "[$ts] [DONE] 本轮完成"
        }
        'turn.failed' {
            $err = Get-Prop $evt 'error'
            $msg = if ($err) { Get-Prop $err 'message' } else { ($evt | ConvertTo-Json -Compress -Depth 6) }
            return "[$ts] [ERROR] 本轮失败: $msg"
        }
        'error' {
            $msg = Get-Prop $evt 'message'
            if (-not $msg) { $msg = ($evt | ConvertTo-Json -Compress -Depth 6) }
            return "[$ts] [ERROR] $msg"
        }
        { $_ -in @('item.started', 'item.updated', 'item.completed') } {
            $item = Get-Prop $evt 'item'
            $itemType = Get-Prop $item 'type'
            switch ($itemType) {
                'reasoning' {
                    $text = Get-Prop $item 'text'
                    if (-not [string]::IsNullOrWhiteSpace($text)) {
                        return "[$ts] [思考] $text"
                    }
                    return $null
                }
                'agent_message' {
                    $text = Get-Prop $item 'text'
                    if (-not [string]::IsNullOrWhiteSpace($text)) {
                        return "[$ts] [Codex说] $text"
                    }
                    return $null
                }
                'command_execution' {
                    $cmd = Get-Prop $item 'command'
                    $status = Get-Prop $item 'status'
                    $exitCode = Get-Prop $item 'exit_code'
                    if ($evtType -eq 'item.started') {
                        return "[$ts] [执行命令] $cmd"
                    } elseif ($evtType -eq 'item.completed') {
                        $summary = "[$ts] [命令完成 exit=$exitCode status=$status] $cmd"
                        $out = Get-Prop $item 'aggregated_output'
                        if ($exitCode -ne 0 -and -not [string]::IsNullOrWhiteSpace($out)) {
                            $snippet = $out.Trim()
                            if ($snippet.Length -gt 300) { $snippet = $snippet.Substring(0, 300) + '...' }
                            $summary += "`n  输出片段: $snippet"
                        }
                        return $summary
                    }
                    return $null
                }
                'file_change' {
                    $changes = Get-Prop $item 'changes'
                    $status = Get-Prop $item 'status'
                    if ($changes) {
                        $desc = ($changes | ForEach-Object { "$(Get-Prop $_ 'kind'):$(Get-Prop $_ 'path')" }) -join ', '
                        return "[$ts] [修改文件 $status] $desc"
                    }
                    return "[$ts] [修改文件 $status]"
                }
                'mcp_tool_call' {
                    $srv = Get-Prop $item 'server'
                    $tool = Get-Prop $item 'tool'
                    $status = Get-Prop $item 'status'
                    return "[$ts] [工具调用 $evtType] $srv.$tool ($status)"
                }
                'web_search' {
                    $query = Get-Prop $item 'query'
                    return "[$ts] [网页搜索] $query"
                }
                'todo_list' {
                    $items = Get-Prop $item 'items'
                    if ($items) {
                        $list = ($items | ForEach-Object {
                            $mark = if (Get-Prop $_ 'completed') { '[x]' } else { '[ ]' }
                            "$mark $(Get-Prop $_ 'text')"
                        }) -join ' | '
                        return "[$ts] [计划清单] $list"
                    }
                    return $null
                }
                default {
                    $compact = $item | ConvertTo-Json -Compress -Depth 6
                    return "[$ts] [$evtType/$itemType] $compact"
                }
            }
        }
        default {
            return "[$ts] [$evtType] $Line"
        }
    }
}

if ($Prompt -and $PromptFile) {
    throw 'Specify either -Prompt or -PromptFile, not both.'
}

$resolvedPrompt = $null
if ($PromptFile) {
    if (-not (Test-Path -LiteralPath $PromptFile)) {
        throw "PromptFile not found: $PromptFile"
    }
    $resolvedPrompt = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $PromptFile).Path, $utf8NoBom)
} elseif ($PSBoundParameters.ContainsKey('Prompt')) {
    $resolvedPrompt = $Prompt
}

if (-not (Test-Path -LiteralPath $WorkDir)) {
    throw "WorkDir does not exist: $WorkDir"
}
$resolvedWorkDir = (Resolve-Path -LiteralPath $WorkDir).Path

if ($Mode -eq 'exec' -and [string]::IsNullOrWhiteSpace($resolvedPrompt)) {
    throw 'In exec mode, -Prompt or -PromptFile is required.'
}

if ($Mode -eq 'resume' -and -not $Last -and [string]::IsNullOrWhiteSpace($SessionId)) {
    throw 'In resume mode, specify either -SessionId or -Last.'
}

if ($Mode -eq 'queue') {
    if ([string]::IsNullOrWhiteSpace($SessionId)) {
        throw 'In queue mode, -SessionId is required.'
    }
    if ([string]::IsNullOrWhiteSpace($resolvedPrompt)) {
        throw 'In queue mode, -Prompt or -PromptFile is required.'
    }
}

$disciplineApplied = $false
if (-not $NoDispatchDiscipline -and ($Mode -eq 'exec' -or $Mode -eq 'resume') -and -not [string]::IsNullOrWhiteSpace($resolvedPrompt)) {
    if (-not $resolvedPrompt.Contains($DISPATCH_DISCIPLINE_TAG)) {
        $resolvedPrompt = $resolvedPrompt.TrimEnd() + "`n" + $DISPATCH_DISCIPLINE_BLOCK.TrimStart("`r", "`n")
        $disciplineApplied = $true
    }
}

$codexExe = Resolve-CodexExe

$cliArgs = [System.Collections.Generic.List[string]]::new()

switch ($Mode) {
    'exec' {
        $cliArgs.Add('exec')
        $cliArgs.Add('-m')
        $cliArgs.Add($LOCKED_MODEL)
        $cliArgs.Add('-c')
        $cliArgs.Add("model=$LOCKED_MODEL")
        $cliArgs.Add('-c')
        $cliArgs.Add("model_reasoning_effort=$LOCKED_REASONING_EFFORT")
        $cliArgs.Add('--json')

        $cliArgs.Add('-C')
        $cliArgs.Add($resolvedWorkDir)
        $cliArgs.Add('-s')
        $cliArgs.Add($Sandbox)

        if ($ApproveForMe) { $cliArgs.Add('--approve-for-me') }
        if ($Ephemeral) { $cliArgs.Add('--ephemeral') }
        if ($Worktree) { $cliArgs.Add('--worktree') }
        if ($OutputLastMessage) {
            $cliArgs.Add('-o')
            $cliArgs.Add($OutputLastMessage)
        }
        if ($SkipGitRepoCheck -or -not (Test-InGitRepo $resolvedWorkDir)) {
            $cliArgs.Add('--skip-git-repo-check')
        }
        if ($Image) {
            foreach ($img in $Image) {
                $cliArgs.Add('-i')
                $cliArgs.Add($img)
            }
        }
        if ($AddDir) {
            foreach ($dir in $AddDir) {
                $cliArgs.Add('--add-dir')
                $cliArgs.Add($dir)
            }
        }
        $cliArgs.Add('-')
    }

    'review' {
        $cliArgs.Add('exec')
        $cliArgs.Add('review')
        $cliArgs.Add('-m')
        $cliArgs.Add($LOCKED_MODEL)
        $cliArgs.Add('-c')
        $cliArgs.Add("model=$LOCKED_MODEL")
        $cliArgs.Add('-c')
        $cliArgs.Add("model_reasoning_effort=$LOCKED_REASONING_EFFORT")
        $cliArgs.Add('-c')
        $cliArgs.Add("sandbox_mode=$Sandbox")
        $cliArgs.Add('--json')

        if ($Uncommitted) { $cliArgs.Add('--uncommitted') }
        if ($Base) {
            $cliArgs.Add('--base')
            $cliArgs.Add($Base)
        }
        if ($Commit) {
            $cliArgs.Add('--commit')
            $cliArgs.Add($Commit)
        }
        if ($Title) {
            $cliArgs.Add('--title')
            $cliArgs.Add($Title)
        }
        if ($Ephemeral) { $cliArgs.Add('--ephemeral') }
        if ($Worktree) { $cliArgs.Add('--worktree') }
        if ($SkipGitRepoCheck) { $cliArgs.Add('--skip-git-repo-check') }
        if ($OutputLastMessage) {
            $cliArgs.Add('-o')
            $cliArgs.Add($OutputLastMessage)
        }
        if (-not [string]::IsNullOrWhiteSpace($resolvedPrompt)) {
            $cliArgs.Add('-')
        }
    }

    'resume' {
        $cliArgs.Add('exec')
        $cliArgs.Add('resume')
        $cliArgs.Add('-m')
        $cliArgs.Add($LOCKED_MODEL)
        $cliArgs.Add('-c')
        $cliArgs.Add("model=$LOCKED_MODEL")
        $cliArgs.Add('-c')
        $cliArgs.Add("model_reasoning_effort=$LOCKED_REASONING_EFFORT")
        $cliArgs.Add('-c')
        $cliArgs.Add("sandbox_mode=$Sandbox")
        $cliArgs.Add('--json')

        if ($Last) { $cliArgs.Add('--last') }
        if ($All) { $cliArgs.Add('--all') }
        if ($Ephemeral) { $cliArgs.Add('--ephemeral') }
        if ($Worktree) { $cliArgs.Add('--worktree') }
        if ($SkipGitRepoCheck -or -not (Test-InGitRepo $resolvedWorkDir)) {
            $cliArgs.Add('--skip-git-repo-check')
        }
        if ($OutputLastMessage) {
            $cliArgs.Add('-o')
            $cliArgs.Add($OutputLastMessage)
        }
        if ($Image) {
            foreach ($img in $Image) {
                $cliArgs.Add('-i')
                $cliArgs.Add($img)
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($SessionId)) {
            $cliArgs.Add($SessionId)
        }
        if (-not [string]::IsNullOrWhiteSpace($resolvedPrompt)) {
            $cliArgs.Add('-')
        }
    }

    'queue' {
        $cliArgs.Add('queue')
        $cliArgs.Add('-c')
        $cliArgs.Add("model=$LOCKED_MODEL")
        $cliArgs.Add('-c')
        $cliArgs.Add("model_reasoning_effort=$LOCKED_REASONING_EFFORT")
        $cliArgs.Add('-C')
        $cliArgs.Add($resolvedWorkDir)
        $cliArgs.Add('--thread')
        $cliArgs.Add($SessionId)
        $cliArgs.Add('--message')
        $cliArgs.Add($resolvedPrompt)
    }
}

if (-not $LogFile -and $Mode -ne 'queue') {
    $baseTemp = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Temp' } else { [System.IO.Path]::GetTempPath() }
    $logDir = Join-Path $baseTemp 'codex-sol-high'
    if (-not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $LogFile = Join-Path $logDir "codex-$stamp-$PID.log"
}

if ($DryRun) {
    [PSCustomObject]@{
        Executable        = $codexExe
        Mode              = $Mode
        LockedModel       = $LOCKED_MODEL
        LockedReasoning   = $LOCKED_REASONING_EFFORT
        CompactionShiftAt = $COMPACTION_SHIFT_THRESHOLD
        DisciplineApplied = $disciplineApplied
        Sandbox           = $Sandbox
        WorkDir           = $resolvedWorkDir
        LogFile           = $LogFile
        Arguments         = @($cliArgs)
        HasStdinPrompt    = ($Mode -ne 'queue') -and (-not [string]::IsNullOrWhiteSpace($resolvedPrompt))
    } | ConvertTo-Json -Depth 4
    exit 0
}

$logWriter = $null
if ($LogFile) {
    $parentDir = Split-Path -Path $LogFile -Parent
    if ($parentDir -and -not (Test-Path -LiteralPath $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }
    $logStream = [System.IO.FileStream]::new($LogFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
    $logWriter = [System.IO.StreamWriter]::new($logStream, $utf8NoBom)
    $logWriter.AutoFlush = $true
}

function Write-LiveLine([string]$Text) {
    if ($null -eq $Text) { return }
    [Console]::Out.WriteLine($Text)
    [Console]::Out.Flush()
    if ($null -ne $logWriter) {
        $logWriter.WriteLine($Text)
    }
}

$psi = [System.Diagnostics.ProcessStartInfo]::new()
$psi.FileName = $codexExe
$psi.WorkingDirectory = $resolvedWorkDir
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.StandardOutputEncoding = $utf8NoBom
$psi.StandardErrorEncoding = $utf8NoBom
foreach ($arg in $cliArgs) {
    [void]$psi.ArgumentList.Add($arg)
}

$proc = [System.Diagnostics.Process]::new()
$proc.StartInfo = $psi

$finalExitCode = -1
try {
    if ($LogFile) {
        Write-LiveLine "[META] pid=$PID | log_file=$LogFile | workdir=$resolvedWorkDir | model=$LOCKED_MODEL | reasoning=$LOCKED_REASONING_EFFORT | sandbox=$Sandbox"
    }

    [void]$proc.Start()

    # Feed prompt to stdin (or close immediately so Codex never blocks on stdin)
    $stdinWriter = [System.IO.StreamWriter]::new($proc.StandardInput.BaseStream, $utf8NoBom)
    if ($Mode -ne 'queue' -and -not [string]::IsNullOrWhiteSpace($resolvedPrompt)) {
        $stdinWriter.Write($resolvedPrompt)
    }
    $stdinWriter.Flush()
    $stdinWriter.Close()

    # Drain stderr asynchronously to prevent pipe deadlocks
    $stderrTask = $proc.StandardError.ReadToEndAsync()

    $capturedThreadId = if (-not [string]::IsNullOrWhiteSpace($SessionId)) { $SessionId } else { $null }

    while ($null -ne ($line = $proc.StandardOutput.ReadLine())) {
        if (-not $capturedThreadId -and $line -match '"type":"thread\.started".*?"thread_id":"([^"]+)"') {
            $capturedThreadId = $Matches[1]
        }
        if ($Mode -eq 'queue' -or $RawJson) {
            Write-LiveLine $line
        } else {
            $formatted = Format-CodexEvent $line
            if ($null -ne $formatted) {
                Write-LiveLine $formatted
            }
        }
    }

    $proc.WaitForExit()
    $exitCode = $proc.ExitCode
    $finalExitCode = $exitCode
    $stderrText = $stderrTask.GetAwaiter().GetResult()

    if ($exitCode -ne 0 -and -not [string]::IsNullOrWhiteSpace($stderrText)) {
        $filteredErr = ($stderrText -split "`r?`n" | Where-Object {
            $_ -and
            $_ -notmatch 'rmcp::transport::worker' -and
            $_ -notmatch 'failed to load skill' -and
            $_ -notmatch 'failed to refresh available models'
        }) -join "`n"
        if ($filteredErr) {
            Write-LiveLine "[STDERR] $filteredErr"
        }
    }

    # Post-turn zero-token compaction health check (strictly AFTER the turn completes)
    if ($Mode -ne 'queue' -and -not $RawJson -and -not $Ephemeral -and $capturedThreadId) {
        $healthScript = Join-Path $PSScriptRoot 'check-session-health.ps1'
        if (Test-Path -LiteralPath $healthScript) {
            try {
                $healthJson = & $healthScript -SessionId $capturedThreadId -Threshold $COMPACTION_SHIFT_THRESHOLD
                $health = $healthJson | ConvertFrom-Json
                $ts = Get-Date -Format 'HH:mm:ss'
                $ctxInfo = if ($null -ne $health.LastContextTokens) { " | last_context_tokens=$($health.LastContextTokens)" } else { '' }
                if ($health.NeedsHandoffAfterTurn) {
                    Write-LiveLine "[$ts] [HANDOFF_REQUIRED] thread_id=$capturedThreadId | compactions=$($health.CompactionCount) (>=$COMPACTION_SHIFT_THRESHOLD)$ctxInfo | 压缩次数已达到或超过 $COMPACTION_SHIFT_THRESHOLD 次！请确保本轮任务完整验收后，先让老窗口写入交接单再开新窗口换班。"
                } else {
                    $phaseHint = if ($health.PhaseShiftEligible) { ' | phase_shift_eligible=true' } else { '' }
                    Write-LiveLine "[$ts] [HEALTH] thread_id=$capturedThreadId | compactions=$($health.CompactionCount) (shift_at>=$COMPACTION_SHIFT_THRESHOLD)$ctxInfo$phaseHint | status=OK"
                }
            } catch {
                # Do not fail the Codex run if local health inspection encounters a transient read error
            }
        }
    }

    exit $exitCode
} finally {
    if ($Mode -ne 'queue' -and -not $RawJson -and $null -ne $logWriter) {
        Write-LiveLine "[END] exit_code=$finalExitCode"
    }
    if ($null -ne $logWriter) {
        $logWriter.Dispose()
    }
    $proc.Dispose()
}
