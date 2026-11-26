[CmdletBinding()]
param(
    [string]$TargetRoot = (Join-Path $env:USERPROFILE '.gemini\config'),
    [switch]$IncludeFrontendRule,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = $PSScriptRoot
$srcSkill = Join-Path $repoRoot 'skills\codex-sol-high'
$dstSkill = Join-Path $TargetRoot 'skills\codex-sol-high'

if (-not (Test-Path -LiteralPath $srcSkill)) {
    throw "Source skill directory not found: $srcSkill"
}

if ((Test-Path -LiteralPath $dstSkill) -and -not $Force) {
    Write-Host "Updating existing skill directory: $dstSkill" -ForegroundColor Yellow
}

New-Item -ItemType Directory -Path $dstSkill -Force | Out-Null
Copy-Item -Path (Join-Path $srcSkill '*') -Destination $dstSkill -Recurse -Force
Write-Host "[OK] Installed skill to: $dstSkill" -ForegroundColor Green

if ($IncludeFrontendRule) {
    $srcRule = Join-Path $repoRoot 'rules\frontend-ownership.md'
    $dstRulesDir = Join-Path $TargetRoot 'rules'
    $dstRule = Join-Path $dstRulesDir 'frontend-ownership.md'
    New-Item -ItemType Directory -Path $dstRulesDir -Force | Out-Null
    Copy-Item -LiteralPath $srcRule -Destination $dstRule -Force
    Write-Host "[OK] Installed optional rule to: $dstRule" -ForegroundColor Green
}

Write-Host ""
Write-Host "Done! Note: ~/.codex/ was NOT modified." -ForegroundColor Cyan
Write-Host "Run a zero-cost DryRun check:" -ForegroundColor Cyan
Write-Host "  pwsh -NoProfile -File `"$dstSkill\scripts\run-codex.ps1`" -WorkDir `"$PWD`" -Prompt `"DryRun check`" -DryRun"
