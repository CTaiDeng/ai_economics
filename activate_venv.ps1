# SPDX-FileCopyrightText: 2026 GaoZheng
# SPDX-License-Identifier: MIT
# Full license: LICENSES/MIT.txt (repository root)

param(
    [string]$Root = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Resolve-RepoRoot([string]$rootArg) {
    if (-not [string]::IsNullOrWhiteSpace($rootArg)) {
        return (Resolve-Path -LiteralPath $rootArg).Path
    }
    return (Resolve-Path -LiteralPath $PSScriptRoot).Path
}

$root = Resolve-RepoRoot $Root
$venvDir = Join-Path $root ".venv"
if (-not (Test-Path -LiteralPath $venvDir)) {
    throw ("未找到虚拟环境目录：{0}（请先在仓库根目录创建 .venv）" -f $venvDir)
}

$candidates = @(
    (Join-Path $venvDir "Scripts\\Activate.ps1"),  # Windows
    (Join-Path $venvDir "bin\\Activate.ps1")       # Linux/macOS (pwsh)
)

foreach ($act in $candidates) {
    if (Test-Path -LiteralPath $act) {
        . $act
        $governanceScript = Join-Path `
            $root `
            "scripts\pycache_customize\enable_pycache_governance.ps1"
        if (-not (Test-Path -LiteralPath $governanceScript -PathType Leaf)) {
            throw ("未找到 pycache 治理脚本：{0}" -f $governanceScript)
        }
        & $governanceScript -Quiet
        Write-Host ("[Venv] 已激活：{0}" -f $venvDir)
        if (-not [string]::IsNullOrWhiteSpace($env:VIRTUAL_ENV)) {
            Write-Host ("[Venv] VIRTUAL_ENV={0}" -f $env:VIRTUAL_ENV)
        }
        Write-Host (
            "[Venv] PYTHONPYCACHEPREFIX={0}" -f $env:PYTHONPYCACHEPREFIX
        )
        return
    }
}

throw ("未找到激活脚本 Activate.ps1。已检查：{0}" -f ($candidates -join ", "))
