#!/usr/bin/env pwsh
# SPDX-FileCopyrightText: 2026 GaoZheng
# SPDX-License-Identifier: MIT
# Full license: LICENSES/MIT.txt (repository root)

<#
  Load the repository pycache policy into the current PowerShell process.
  Environment-variable changes survive normal (&) script invocation because
  they belong to the hosting PowerShell process.
#>

[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot "pycache_governance.json"),
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-OptionalProperty {
    param(
        $InputObject,
        [Parameter(Mandatory = $true)]
        [string]$Name
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

function Resolve-ConfiguredPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RawPath,
        [Parameter(Mandatory = $true)]
        [string]$BasePath
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

function Test-StrictDescendant {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PathValue,
        [Parameter(Mandatory = $true)]
        [string]$RootValue
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

$resolvedConfig = [IO.Path]::GetFullPath($ConfigPath)
if (-not (Test-Path -LiteralPath $resolvedConfig -PathType Leaf)) {
    throw "Pycache governance file was not found: $resolvedConfig"
}

$rawConfig = [IO.File]::ReadAllBytes($resolvedConfig)
if (
    ($rawConfig.Length -ge 3 -and
        $rawConfig[0] -eq 0xEF -and
        $rawConfig[1] -eq 0xBB -and
        $rawConfig[2] -eq 0xBF) -or
    ($rawConfig -contains 13)
) {
    throw "Governance JSON must be UTF-8 without BOM and LF-only: $resolvedConfig"
}

try {
    $config = [Text.Encoding]::UTF8.GetString($rawConfig) | ConvertFrom-Json
} catch {
    throw "Invalid pycache governance JSON '$resolvedConfig': $($_.Exception.Message)"
}

$runtimePaths = Get-OptionalProperty $config "runtime_paths"
if ($null -eq $runtimePaths) {
    throw "Governance JSON must contain runtime_paths."
}

$configDirectory = Split-Path -Parent $resolvedConfig
$rawWorkspace = [string](Get-OptionalProperty $runtimePaths "workspace_root")
if ([string]::IsNullOrWhiteSpace($rawWorkspace)) {
    throw "runtime_paths.workspace_root must be a non-empty string."
}
$workspaceRoot = Resolve-ConfiguredPath `
    -RawPath $rawWorkspace `
    -BasePath $configDirectory

$rawPrefix = [string](Get-OptionalProperty $runtimePaths "pycache_prefix")
if ([string]::IsNullOrWhiteSpace($rawPrefix)) {
    throw "runtime_paths.pycache_prefix must be a non-empty string."
}
$pycachePrefix = Resolve-ConfiguredPath `
    -RawPath $rawPrefix `
    -BasePath $workspaceRoot

$policy = Get-OptionalProperty $config "policy"
$allowExternal = $false
$createPrefix = $true
if ($null -ne $policy) {
    $configuredAllowExternal = Get-OptionalProperty $policy "allow_external_prefix"
    if ($null -ne $configuredAllowExternal) {
        if ($configuredAllowExternal -isnot [bool]) {
            throw "policy.allow_external_prefix must be boolean."
        }
        $allowExternal = [bool]$configuredAllowExternal
    }
    $configuredCreatePrefix = Get-OptionalProperty $policy "create_prefix"
    if ($null -ne $configuredCreatePrefix) {
        if ($configuredCreatePrefix -isnot [bool]) {
            throw "policy.create_prefix must be boolean."
        }
        $createPrefix = [bool]$configuredCreatePrefix
    }
}

if (
    -not $allowExternal -and
    -not (Test-StrictDescendant -PathValue $pycachePrefix -RootValue $workspaceRoot)
) {
    throw (
        "runtime_paths.pycache_prefix must be below the workspace root " +
        "unless policy.allow_external_prefix is true: $pycachePrefix"
    )
}

if ($createPrefix) {
    [IO.Directory]::CreateDirectory($pycachePrefix) | Out-Null
} elseif (-not (Test-Path -LiteralPath $pycachePrefix -PathType Container)) {
    throw "Governed pycache prefix does not exist: $pycachePrefix"
}

$requirementsPath = ""
$requirements = Get-OptionalProperty $config "requirements"
if ($null -ne $requirements) {
    $rawRequirements = [string](Get-OptionalProperty $requirements "path")
    if (-not [string]::IsNullOrWhiteSpace($rawRequirements)) {
        $requirementsPath = Resolve-ConfiguredPath `
            -RawPath $rawRequirements `
            -BasePath $workspaceRoot
    }
}

$env:PYCACHE_GOVERNANCE_CONFIG = $resolvedConfig
$env:PYTHONPYCACHEPREFIX = $pycachePrefix
$env:PROJECT_REQUIREMENTS_FILE = $requirementsPath

if (-not $Quiet) {
    Write-Host "[pycache_governance] config=$resolvedConfig"
    Write-Host "[pycache_governance] prefix=$pycachePrefix"
}
