#!/usr/bin/env pwsh
<#
  Install a one-line .pth startup hook into the governed virtual environment.
  The hook sets sys.pycache_prefix before user modules or py_compile execute.
#>

[CmdletBinding()]
param(
    [string]$PythonExecutable = "",
    [string]$ConfigPath = (Join-Path $PSScriptRoot "pycache_governance.json")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$enableScript = Join-Path $PSScriptRoot "enable_pycache_governance.ps1"
& $enableScript -ConfigPath $ConfigPath -Quiet

$resolvedConfig = [IO.Path]::GetFullPath($env:PYCACHE_GOVERNANCE_CONFIG)
$config = Get-Content -LiteralPath $resolvedConfig -Raw -Encoding UTF8 |
    ConvertFrom-Json
$configDirectory = Split-Path -Parent $resolvedConfig
$workspaceRoot = [IO.Path]::GetFullPath(
    (Join-Path $configDirectory ([string]$config.runtime_paths.workspace_root))
)

if ([string]::IsNullOrWhiteSpace($PythonExecutable)) {
    $configuredPython = [string]$config.python.executable
    if ([string]::IsNullOrWhiteSpace($configuredPython)) {
        throw "python.executable must be configured when -PythonExecutable is omitted."
    }
    $PythonExecutable = Join-Path $workspaceRoot $configuredPython
}
$pythonPath = (Resolve-Path -LiteralPath $PythonExecutable).Path

$sitePackagesOutput = @(
    & $pythonPath -c "import sysconfig; print(sysconfig.get_path('purelib'))"
)
if ($LASTEXITCODE -ne 0) {
    throw "Unable to query site-packages from $pythonPath"
}
$sitePackages = ($sitePackagesOutput |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Select-Object -Last 1).Trim()
if ([string]::IsNullOrWhiteSpace($sitePackages)) {
    throw "Python returned an empty site-packages path: $pythonPath"
}
[IO.Directory]::CreateDirectory($sitePackages) | Out-Null

$prefixLiteral = ConvertTo-Json $env:PYTHONPYCACHEPREFIX -Compress
$configLiteral = ConvertTo-Json $resolvedConfig -Compress
$hookText = (
    "import os,sys; " +
    "sys.pycache_prefix=$prefixLiteral; " +
    "os.environ['PYTHONPYCACHEPREFIX']=$prefixLiteral; " +
    "os.environ['PYCACHE_GOVERNANCE_CONFIG']=$configLiteral" +
    "`n"
)
$hookPath = Join-Path $sitePackages "workshare_pycache_governance.pth"
[IO.File]::WriteAllText(
    $hookPath,
    $hookText,
    [Text.UTF8Encoding]::new($false)
)

Write-Host "[pycache_governance] installed=$hookPath"
Write-Host "[pycache_governance] prefix=$env:PYTHONPYCACHEPREFIX"

