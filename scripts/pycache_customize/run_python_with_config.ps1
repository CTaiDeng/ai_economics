#!/usr/bin/env pwsh
# SPDX-FileCopyrightText: 2026 GaoZheng
# SPDX-License-Identifier: MIT
# Full license: LICENSES/MIT.txt (repository root)

<#
  Load pycache governance from this directory before Python starts.
  PYTHONPYCACHEPREFIX is therefore active during interpreter initialization.
#>

$PythonArgs = @($args)

$ErrorActionPreference = "Stop"

function Resolve-ConfiguredPath {
  param(
    [Parameter(Mandatory = $true)][string]$RawPath,
    [Parameter(Mandatory = $true)][string]$BasePath
  )

  $expanded = [Environment]::ExpandEnvironmentVariables($RawPath.Trim())
  if ($expanded.StartsWith("~")) {
    $expanded = Join-Path `
      $env:USERPROFILE `
      $expanded.Substring(1).TrimStart('\', '/')
  }
  if (-not [IO.Path]::IsPathRooted($expanded)) {
    $expanded = Join-Path $BasePath $expanded
  }
  return [IO.Path]::GetFullPath($expanded)
}

function Get-OptionalProperty {
  param(
    $InputObject,
    [Parameter(Mandatory = $true)][string]$Name
  )

  if ($null -eq $InputObject) {
    return $null
  }
  $property = $InputObject.PSObject.Properties[$Name]
  if ($null -eq $property) {
    return $null
  }
  return $property.Value
}

function Find-WorkspaceRoot {
  param(
    [Parameter(Mandatory = $true)]$Config,
    [Parameter(Mandatory = $true)][string]$ConfigDirectory
  )

  $runtimePaths = Get-OptionalProperty $Config "runtime_paths"
  $configuredRoot = [string](
    Get-OptionalProperty $runtimePaths "workspace_root"
  )
  $configuredRoot = $configuredRoot.Trim()
  if (-not [string]::IsNullOrWhiteSpace($configuredRoot)) {
    return Resolve-ConfiguredPath `
      -RawPath $configuredRoot `
      -BasePath $ConfigDirectory
  }
  $current = [IO.DirectoryInfo]::new(
    [IO.Path]::GetFullPath($ConfigDirectory)
  )
  while ($null -ne $current) {
    if (Test-Path -LiteralPath (Join-Path $current.FullName ".git")) {
      return $current.FullName
    }
    $current = $current.Parent
  }
  return [IO.Path]::GetFullPath($ConfigDirectory)
}

function Test-StrictDescendant {
  param(
    [Parameter(Mandatory = $true)][string]$PathValue,
    [Parameter(Mandatory = $true)][string]$RootValue
  )

  $path = [IO.Path]::GetFullPath($PathValue).TrimEnd('\', '/')
  $root = [IO.Path]::GetFullPath($RootValue).TrimEnd('\', '/')
  return -not $path.Equals(
    $root,
    [StringComparison]::OrdinalIgnoreCase
  ) -and $path.StartsWith(
    $root + [IO.Path]::DirectorySeparatorChar,
    [StringComparison]::OrdinalIgnoreCase
  )
}

function Resolve-PythonExecutable {
  param(
    [Parameter(Mandatory = $true)]$Config,
    [Parameter(Mandatory = $true)][string]$WorkspaceRoot
  )

  $candidates = @()
  $pythonConfig = Get-OptionalProperty $Config "python"
  $configuredExecutable = [string](
    Get-OptionalProperty $pythonConfig "executable"
  )
  if (-not [string]::IsNullOrWhiteSpace($configuredExecutable)) {
    $candidates += Resolve-ConfiguredPath `
      -RawPath $configuredExecutable `
      -BasePath $WorkspaceRoot
  }
  if ($candidates.Count -eq 0) {
    $candidates += @(
      (Join-Path $WorkspaceRoot ".venv\Scripts\python.exe"),
      (Join-Path $WorkspaceRoot ".venv\bin\python")
    )
  }
  foreach ($candidate in ($candidates | Select-Object -Unique)) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      return (Resolve-Path -LiteralPath $candidate).Path
    }
  }
  throw (
    "The governed .venv Python interpreter was not found. Checked: " +
    (($candidates | Select-Object -Unique) -join ", ")
  )
}

$scriptDirectory = [IO.Path]::GetFullPath($PSScriptRoot)
$configPath = if (
  [string]::IsNullOrWhiteSpace($env:PYCACHE_GOVERNANCE_CONFIG)
) {
  Join-Path $scriptDirectory "pycache_governance.json"
} else {
  Resolve-ConfiguredPath `
    -RawPath $env:PYCACHE_GOVERNANCE_CONFIG `
    -BasePath (Get-Location).Path
}
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
  throw "Pycache governance file was not found: $configPath"
}
try {
  $config = Get-Content `
    -LiteralPath $configPath `
    -Raw `
    -Encoding UTF8 | ConvertFrom-Json
} catch {
  throw (
    "Invalid pycache governance JSON '$configPath': " +
    $_.Exception.Message
  )
}
$runtimePaths = Get-OptionalProperty $config "runtime_paths"
if ($null -eq $runtimePaths) {
  throw "Governance JSON must contain runtime_paths."
}
$rawPrefix = ([string](
    Get-OptionalProperty $runtimePaths "pycache_prefix"
  )).Trim()
if ([string]::IsNullOrWhiteSpace($rawPrefix)) {
  throw "runtime_paths.pycache_prefix must be a non-empty string."
}
$workspaceRoot = Find-WorkspaceRoot `
  -Config $config `
  -ConfigDirectory (Split-Path -Parent $configPath)
$pycachePrefix = Resolve-ConfiguredPath `
  -RawPath $rawPrefix `
  -BasePath $workspaceRoot
$allowExternal = $false
$policyConfig = Get-OptionalProperty $config "policy"
$allowExternalValue = Get-OptionalProperty `
  $policyConfig `
  "allow_external_prefix"
if ($null -ne $allowExternalValue) {
  if ($allowExternalValue -isnot [bool]) {
    throw "policy.allow_external_prefix must be boolean."
  }
  $allowExternal = [bool]$allowExternalValue
}
if (-not $allowExternal -and
    -not (Test-StrictDescendant `
      -PathValue $pycachePrefix `
      -RootValue $workspaceRoot)) {
  throw (
    "runtime_paths.pycache_prefix must be below the workspace root unless " +
    "policy.allow_external_prefix is true: $pycachePrefix"
  )
}
$createPrefix = $true
$createPrefixValue = Get-OptionalProperty $policyConfig "create_prefix"
if ($null -ne $createPrefixValue) {
  if ($createPrefixValue -isnot [bool]) {
    throw "policy.create_prefix must be boolean."
  }
  $createPrefix = [bool]$createPrefixValue
}
if ($createPrefix -and
    -not (Test-Path -LiteralPath $pycachePrefix -PathType Container)) {
  New-Item -ItemType Directory -Path $pycachePrefix -Force | Out-Null
}
if (-not $createPrefix -and
    -not (Test-Path -LiteralPath $pycachePrefix -PathType Container)) {
  throw "Governed pycache prefix does not exist: $pycachePrefix"
}

$pythonExecutable = Resolve-PythonExecutable `
  -Config $config `
  -WorkspaceRoot $workspaceRoot
$requirementsPath = ""
$requirementsConfig = Get-OptionalProperty $config "requirements"
$configuredRequirements = [string](
  Get-OptionalProperty $requirementsConfig "path"
)
if (-not [string]::IsNullOrWhiteSpace($configuredRequirements)) {
  $requirementsPath = Resolve-ConfiguredPath `
    -RawPath $configuredRequirements `
    -BasePath $workspaceRoot
  if (-not (Test-Path -LiteralPath $requirementsPath -PathType Leaf)) {
    throw "Governed requirements file was not found: $requirementsPath"
  }
}
$env:PYCACHE_GOVERNANCE_CONFIG = [IO.Path]::GetFullPath($configPath)
$env:PYTHONPYCACHEPREFIX = $pycachePrefix
$env:PROJECT_REQUIREMENTS_FILE = $requirementsPath
$pythonDirectory = Split-Path -Parent $pythonExecutable
$expectedVenvRoot = [IO.Path]::GetFullPath(
  (Join-Path $workspaceRoot ".venv")
)
if ($pythonExecutable.StartsWith(
    $expectedVenvRoot + [IO.Path]::DirectorySeparatorChar,
    [StringComparison]::OrdinalIgnoreCase)) {
  $env:VIRTUAL_ENV = $expectedVenvRoot
  $pathEntries = @($pythonDirectory)
  if (-not [string]::IsNullOrWhiteSpace($env:PATH)) {
    $pathEntries += $env:PATH.Split([IO.Path]::PathSeparator)
  }
  $env:PATH = ($pathEntries |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Select-Object -Unique) -join [IO.Path]::PathSeparator
  Remove-Item Env:CONDA_DEFAULT_ENV -ErrorAction SilentlyContinue
  Remove-Item Env:CONDA_PREFIX -ErrorAction SilentlyContinue
  Remove-Item Env:CONDA_PROMPT_MODIFIER -ErrorAction SilentlyContinue
}
$pythonPathEntries = @($scriptDirectory, $workspaceRoot)
if (-not [string]::IsNullOrWhiteSpace($env:PYTHONPATH)) {
  $pythonPathEntries += $env:PYTHONPATH.Split([IO.Path]::PathSeparator)
}
$env:PYTHONPATH = ($pythonPathEntries |
  Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
  Select-Object -Unique) -join [IO.Path]::PathSeparator

$requiredVersion = ""
$pythonConfig = Get-OptionalProperty $config "python"
$requiredVersion = ([string](
    Get-OptionalProperty $pythonConfig "required_version"
  )).Trim()
if (-not [string]::IsNullOrWhiteSpace($requiredVersion)) {
  $actualVersionLines = @(& $pythonExecutable `
      -c "import platform; print(platform.python_version())")
  $versionExitCode = [int]$LASTEXITCODE
  $actualVersion = ($actualVersionLines |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Select-Object -Last 1).Trim()
  if ($versionExitCode -ne 0 -or $actualVersion -cne $requiredVersion) {
    throw (
      "Governed Python version mismatch: expected=$requiredVersion " +
      "actual=$actualVersion executable=$pythonExecutable"
    )
  }
}

& $pythonExecutable @PythonArgs
$exitCode = [int]$LASTEXITCODE
exit $exitCode
