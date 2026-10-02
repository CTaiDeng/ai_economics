#!/usr/bin/env pwsh
# SPDX-FileCopyrightText: 2026 GaoZheng
# SPDX-License-Identifier: MIT
# Full license: LICENSES/MIT.txt (repository root)

<#
  Clean workspace generated files:
  - clear out/ while keeping out/pycache (the governed PYTHONPYCACHEPREFIX),
    out/write_back, out/adversarial_scripts, and out/evidence_persistence;
  - keep out/py_http_srv directory and only clean files under it;
  - keep json files under out/adversarial_runs and only clean non-json files inside it;
  - recursively delete all __pycache__/ directories;
  - recursively delete all *.pyc files.

  Usage:
    .\clean_out_and_pycache.ps1             # clean directly without asking
    .\clean_out_and_pycache.ps1 -Confirm   # ask before deleting
    .\clean_out_and_pycache.ps1 -DryRun    # print targets only
    .\clean_out_and_pycache.ps1 -SkipOut   # skip out/ and clean only __pycache__/ and *.pyc
#>

param(
  [switch]$DryRun = $false,
  [switch]$Confirm = $false,
  [switch]$SkipOut = $false
)

$ErrorActionPreference = "Stop"

function Get-RelPath([string]$root, [string]$path) {
  try {
    $full = (Resolve-Path -LiteralPath $path -ErrorAction Stop).Path
  } catch {
    $full = $path
  }
  $rootFull = $root
  try {
    $rootFull = (Resolve-Path -LiteralPath $root -ErrorAction Stop).Path
  } catch {
    $rootFull = $root
  }
  if ($full.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
    $rel = $full.Substring($rootFull.Length)
    return $rel.TrimStart([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
  }
  return $full
}

function Is-ReparsePointDir($item) {
  try {
    if (-not $item.PSIsContainer) { return $false }
    return (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
  } catch {
    return $false
  }
}

function Normalize-FullPath([string]$Path) {
  try {
    return ([System.IO.Path]::GetFullPath($Path)).TrimEnd(
      [System.IO.Path]::DirectorySeparatorChar,
      [System.IO.Path]::AltDirectorySeparatorChar
    )
  } catch {
    return ([string]$Path).TrimEnd(
      [System.IO.Path]::DirectorySeparatorChar,
      [System.IO.Path]::AltDirectorySeparatorChar
    )
  }
}

function Is-PathUnderOrSame([string]$Path, [string]$BasePath) {
  $fullPath = Normalize-FullPath -Path $Path
  $baseFullPath = Normalize-FullPath -Path $BasePath
  if ($fullPath.Equals($baseFullPath, [System.StringComparison]::OrdinalIgnoreCase)) {
    return $true
  }
  return (
    $fullPath.StartsWith(
      $baseFullPath + [System.IO.Path]::DirectorySeparatorChar,
      [System.StringComparison]::OrdinalIgnoreCase
    ) -or
    $fullPath.StartsWith(
      $baseFullPath + [System.IO.Path]::AltDirectorySeparatorChar,
      [System.StringComparison]::OrdinalIgnoreCase
    )
  )
}

# Switch to repository root.
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root

# Directories skipped during recursive Python cache scans.
$skipDirNames = @(
  ".git",
  ".venv",
  "venv",
  "__pypackages__",
  ".mypy_cache",
  ".pytest_cache",
  ".ruff_cache",
  ".tox",
  "out"  # out/ is handled separately.
)

$outDir = Join-Path $root "out"
$outPycacheDir = Join-Path $outDir "pycache"
$outWriteBackDir = Join-Path $outDir "write_back"
$outAdversarialScriptsDir = Join-Path $outDir "adversarial_scripts"
$outEvidencePersistenceDir = Join-Path $outDir "evidence_persistence"
$outPyHttpSrvDir = Join-Path $outDir "py_http_srv"
$outAdversarialRunsDir = Join-Path $outDir "adversarial_runs"
# out/pycache is the repo-governed Python bytecode prefix and must never be deleted.
$outProtectedDirs = @(
  $outPycacheDir,
  $outWriteBackDir,
  $outAdversarialScriptsDir,
  $outEvidencePersistenceDir
)
$scanExcludeDirs = @(
  $outPycacheDir,
  $outWriteBackDir,
  $outAdversarialScriptsDir,
  $outEvidencePersistenceDir
)

function Should-SkipGlobalScanDir([string]$Path) {
  foreach ($skip in @($scanExcludeDirs)) {
    if (Is-PathUnderOrSame -Path $Path -BasePath $skip) { return $true }
  }
  return $false
}

# ---- 1) Collect out/ cleanup targets: files + directories. ----
$outFiles = @()
$outDirs = @()
if (-not $SkipOut) {
  if (Test-Path -LiteralPath $outDir) {
    function Should-SkipOutSubdir([string]$Path) {
      foreach ($skipDir in @($outProtectedDirs)) {
        if (Is-PathUnderOrSame -Path $Path -BasePath $skipDir) { return $true }
      }
      return $false
    }

    function Collect-PyHttpSrvFileTargets([string]$Directory) {
      $children = @(Get-ChildItem -LiteralPath $Directory -Force -ErrorAction SilentlyContinue)
      foreach ($child in $children) {
        if (Is-ReparsePointDir $child) { continue }
        if ($child.PSIsContainer) {
          Collect-PyHttpSrvFileTargets -Directory $child.FullName
          continue
        }
        $script:outFiles = @($script:outFiles + $child)
      }
    }

    function Collect-AdversarialRunsNonJsonFileTargets([string]$Directory) {
      $children = @(Get-ChildItem -LiteralPath $Directory -Force -ErrorAction SilentlyContinue)
      foreach ($child in $children) {
        if (Is-ReparsePointDir $child) { continue }
        if ($child.PSIsContainer) {
          Collect-AdversarialRunsNonJsonFileTargets -Directory $child.FullName
          continue
        }
        if ($child.Extension -like ".json*") {
          continue
        }
        $script:outFiles = @($script:outFiles + $child)
      }
    }

    function Collect-OutTargets([string]$Directory) {
      $children = @(Get-ChildItem -LiteralPath $Directory -Force -ErrorAction SilentlyContinue)
      foreach ($item in $children) {
        if (Is-ReparsePointDir $item) { continue }
        if (Should-SkipOutSubdir -Path $item.FullName) {
          continue
        }
        if ($item.PSIsContainer) {
          if (Is-PathUnderOrSame -Path $item.FullName -BasePath $outPyHttpSrvDir) {
            Collect-PyHttpSrvFileTargets -Directory $item.FullName
            continue
          }
        if (Is-PathUnderOrSame -Path $item.FullName -BasePath $outAdversarialRunsDir) {
            Collect-AdversarialRunsNonJsonFileTargets -Directory $item.FullName
            continue
          }
          Collect-OutTargets -Directory $item.FullName
          $script:outDirs = @($script:outDirs + $item)
          continue
        }
        $script:outFiles = @($script:outFiles + $item)
      }
    }

    Collect-OutTargets -Directory $outDir
    $outDirs = @($outDirs | Sort-Object { $_.FullName.Length } -Descending)
  }
}

# ---- 2) Collect __pycache__/ and *.pyc targets. ----
$pycacheDirs = New-Object System.Collections.Generic.List[string]
$pycFiles = New-Object System.Collections.Generic.List[string]

function Collect-Targets([string]$dir) {
  if (Should-SkipGlobalScanDir -Path $dir) {
    return
  }

  $items = @()
  try {
    $items = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)
  } catch {
    $items = @()
  }
  foreach ($item in $items) {
    if ($item.PSIsContainer) {
      if ($skipDirNames -contains $item.Name) { continue }
      if (Is-ReparsePointDir $item) { continue }
      if ($item.Name -eq "__pycache__") {
        $pycacheDirs.Add($item.FullName)
        continue
      }
      Collect-Targets -dir $item.FullName
      continue
    }
    if ($item.Name -like "*.pyc") {
      $pycFiles.Add($item.FullName)
    }
  }
}

Collect-Targets -dir $root

# ---- 3) Print cleanup targets. ----
if ($SkipOut) {
  Write-Host "[clean] out/ skipped (SkipOut)"
} else {
  Write-Host "[clean] out/ will delete: $($outFiles.Count + $outDirs.Count) (preserve out/pycache, out/write_back, out/adversarial_scripts, out/evidence_persistence)"
  foreach ($p in @($outFiles | Sort-Object FullName)) {
    Write-Host "  - $(Get-RelPath $root $p.FullName)"
  }
  foreach ($p in @($outDirs | Sort-Object FullName)) {
    Write-Host "  - $(Get-RelPath $root $p.FullName)"
  }
}

$pycacheSorted = @($pycacheDirs | Sort-Object)
Write-Host "[clean] __pycache__/ will delete: $($pycacheSorted.Count)"
foreach ($p in $pycacheSorted) {
  Write-Host "  - $(Get-RelPath $root $p)"
}

$pycSorted = @($pycFiles | Sort-Object)
Write-Host "[clean] *.pyc will delete: $($pycSorted.Count)"
foreach ($p in $pycSorted) {
  Write-Host "  - $(Get-RelPath $root $p)"
}

if ($DryRun) {
  Write-Host "[clean] dry-run: no deletion executed."
  exit 0
}

if ($Confirm) {
  $ans = Read-Host "[clean] Confirm deletion? Enter y to continue"
  if (([string]$ans).Trim().ToLower() -ne "y") {
    Write-Host "[clean] canceled."
    exit 1
  }
}

$deleted = 0

# ---- Delete out/: files first, then directories. ----
foreach ($f in $outFiles) {
  try {
    if (Test-Path -LiteralPath $f.FullName) {
      Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
      Write-Host "[clean] unlink $(Get-RelPath $root $f.FullName)"
      $deleted += 1
    }
  } catch {
    Write-Warning "[clean][warn] delete failed: $(Get-RelPath $root $f.FullName) ($($_.Exception.Message))"
  }
}
foreach ($d in $outDirs) {
  try {
    if (Test-Path -LiteralPath $d.FullName) {
      $di = Get-Item -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue
      if ($null -ne $di -and (Is-ReparsePointDir $di)) {
        Remove-Item -LiteralPath $d.FullName -Force -Confirm:$false -ErrorAction Stop
      } else {
        Remove-Item -LiteralPath $d.FullName -Recurse -Force -Confirm:$false -ErrorAction Stop
      }
      Write-Host "[clean] rmdir  $(Get-RelPath $root $d.FullName)"
      $deleted += 1
    }
  } catch {
    Write-Warning "[clean][warn] delete failed: $(Get-RelPath $root $d.FullName) ($($_.Exception.Message))"
  }
}

# ---- Delete *.pyc. ----
foreach ($p in $pycSorted) {
  try {
    if (Test-Path -LiteralPath $p) {
      Remove-Item -LiteralPath $p -Force -ErrorAction Stop
      Write-Host "[clean] unlink $(Get-RelPath $root $p)"
      $deleted += 1
    }
  } catch {
    Write-Warning "[clean][warn] delete failed: $(Get-RelPath $root $p) ($($_.Exception.Message))"
  }
}

# ---- Delete __pycache__/. ----
$pycacheDeleteOrder = @($pycacheSorted | Sort-Object { $_.Length } -Descending)
foreach ($d in $pycacheDeleteOrder) {
  try {
    if (Test-Path -LiteralPath $d) {
      $di = Get-Item -LiteralPath $d -Force -ErrorAction SilentlyContinue
      if ($null -ne $di -and (Is-ReparsePointDir $di)) {
        Remove-Item -LiteralPath $d -Force -ErrorAction Stop
        Write-Host "[clean] unlink $(Get-RelPath $root $d)"
        $deleted += 1
        continue
      }
      Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction Stop
      Write-Host "[clean] rmtree $(Get-RelPath $root $d)"
      $deleted += 1
    }
  } catch {
    Write-Warning "[clean][warn] delete failed: $(Get-RelPath $root $d) ($($_.Exception.Message))"
  }
}

Write-Host "[clean] done: deleted entries = $deleted"
exit 0
