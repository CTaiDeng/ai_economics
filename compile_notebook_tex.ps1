param(
    [Parameter(Position = 0, Mandatory = $true, ValueFromRemainingArguments = $true)]
    [Alias('TexFile', 'TexFiles')]
    [string[]]$TexTargets,
    [string]$OutputDir = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RepoRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StartDir
    )

    $currentDir = [System.IO.Path]::GetFullPath($StartDir)
    while ($true) {
        if (Test-Path -LiteralPath (Join-Path $currentDir '.git')) {
            return $currentDir
        }

        $parentDir = Split-Path -Parent $currentDir
        if (-not $parentDir -or $parentDir -eq $currentDir) {
            break
        }

        $currentDir = $parentDir
    }

    $repoRoot = ''
    try {
        $repoRoot = (& git -C $StartDir rev-parse --show-toplevel 2>$null | Select-Object -First 1).Trim()
    } catch {
        $repoRoot = ''
    }

    if ($repoRoot) {
        return [System.IO.Path]::GetFullPath($repoRoot)
    }

    # TeX compilation also works from source copies without Git metadata.
    return [System.IO.Path]::GetFullPath($StartDir)
}

function Test-IsSubPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$BasePath
    )

    $normalizedBase = [System.IO.Path]::GetFullPath($BasePath).TrimEnd('\', '/')
    $normalizedPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')

    if ($normalizedPath -eq $normalizedBase) {
        return $true
    }

    $basePrefix = $normalizedBase + [System.IO.Path]::DirectorySeparatorChar
    return $normalizedPath.StartsWith($basePrefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-LogText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LogFile
    )

    if (-not (Test-Path -LiteralPath $LogFile -PathType Leaf)) {
        return ''
    }

    return Get-Content -LiteralPath $LogFile -Raw
}

function Assert-NoLatexFatalError {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LogFile,
        [Parameter(Mandatory = $true)]
        [string]$PassName,
        [Parameter(Mandatory = $true)]
        [string]$ContextPath
    )

    if (-not (Test-Path -LiteralPath $LogFile -PathType Leaf)) {
        throw "$PassName did not create a log file for $ContextPath."
    }

    $logText = Get-LogText -LogFile $LogFile
    if ($logText -match 'LaTeX Error:|Fatal error occurred|no output PDF file produced|Emergency stop') {
        throw "$PassName found a fatal LaTeX error while compiling $ContextPath."
    }

    if ($logText -like '*Missing $ inserted*') {
        throw "$PassName found 'Missing dollar inserted' while compiling $ContextPath."
    }

    if ($logText -like '*Undefined control sequence*') {
        throw "$PassName found 'Undefined control sequence' while compiling $ContextPath."
    }
}

function Clear-CompileArtifactsForBaseName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetDir,
        [Parameter(Mandatory = $true)]
        [string]$BaseName,
        [Parameter(Mandatory = $true)]
        [string[]]$Suffixes
    )

    foreach ($suffix in $Suffixes) {
        Remove-Item -LiteralPath (Join-Path $TargetDir ($BaseName + $suffix)) -Force -ErrorAction SilentlyContinue
    }
}

function Compile-OneTexFile {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$ResolvedTexFile,
        [Parameter(Mandatory = $true)]
        [string]$OutputRoot
    )

    $sourceRoot = $ResolvedTexFile.DirectoryName
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($ResolvedTexFile.Name)
    $cleanupSuffixes = @(
        '.aux',
        '.bbl',
        '.blg',
        '.fdb_latexmk',
        '.fls',
        '.log',
        '.out',
        '.synctex.gz',
        '.toc',
        '.xdv'
    )

    Clear-CompileArtifactsForBaseName -TargetDir $sourceRoot -BaseName $baseName -Suffixes $cleanupSuffixes
    Clear-CompileArtifactsForBaseName -TargetDir $OutputRoot -BaseName $baseName -Suffixes $cleanupSuffixes

    $logFile = Join-Path $OutputRoot ($baseName + '.log')
    $pdfFile = Join-Path $OutputRoot ($baseName + '.pdf')
    $minPasses = 2
    $maxPasses = 3

    Push-Location $sourceRoot
    try {
        for ($pass = 1; $pass -le $maxPasses; $pass++) {
            $passName = "pass $pass"
            $compileOutput = & pdflatex '-interaction=nonstopmode' '-halt-on-error' '-file-line-error' ("-output-directory={0}" -f $OutputRoot) $ResolvedTexFile.Name 2>&1
            if ($LASTEXITCODE -ne 0) {
                $tail = ($compileOutput | Select-Object -Last 30) -join [Environment]::NewLine
                throw "$passName failed for $($ResolvedTexFile.Name).$([Environment]::NewLine)$tail"
            }

            Assert-NoLatexFatalError -LogFile $logFile -PassName $passName -ContextPath $ResolvedTexFile.Name

            if ($pass -lt $minPasses) {
                continue
            }

            $logText = Get-LogText -LogFile $logFile
            if ($pass -lt $maxPasses -and $logText -match 'Label\(s\) may have changed|Rerun to get cross-references right\.|There were undefined references\.') {
                continue
            }

            break
        }
    } finally {
        Pop-Location
    }

    if (-not (Test-Path -LiteralPath $pdfFile -PathType Leaf)) {
        throw "No PDF was generated: $pdfFile"
    }

    $finalLogText = Get-LogText -LogFile $logFile
    if ($finalLogText -match 'LaTeX Warning: (Reference|Citation).+undefined|There were undefined references') {
        throw "Undefined references remain. See log: $logFile"
    }

    if ($finalLogText -match 'Overfull \\hbox') {
        Write-Warning "Overfull hbox warnings remain. See log: $logFile"
    }

    Clear-CompileArtifactsForBaseName -TargetDir $sourceRoot -BaseName $baseName -Suffixes $cleanupSuffixes
    Clear-CompileArtifactsForBaseName -TargetDir $OutputRoot -BaseName $baseName -Suffixes $cleanupSuffixes

    Write-Host "compile_notebook_tex.ps1: compiled $($ResolvedTexFile.Name) -> $pdfFile" -ForegroundColor Green
}

function Resolve-TexTargetFiles {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Targets,
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot
    )

    $resolvedFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    $seenPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($target in $Targets) {
        if ([string]::IsNullOrWhiteSpace($target)) {
            continue
        }

        if ([System.IO.Path]::IsPathRooted($target)) {
            throw "TeX target must be relative to the repository root: $target"
        }

        $resolvedTargetPath = [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $target))
        if (-not (Test-IsSubPath -Path $resolvedTargetPath -BasePath $RepoRoot)) {
            throw "TeX target must be inside the repository: $target"
        }

        if (Test-Path -LiteralPath $resolvedTargetPath -PathType Leaf) {
            $resolvedTexFile = Get-Item -LiteralPath $resolvedTargetPath
            if ($resolvedTexFile.Extension -ne '.tex') {
                throw "The specified file is not a .tex file: $target"
            }

            if ($seenPaths.Add($resolvedTexFile.FullName)) {
                $resolvedFiles.Add($resolvedTexFile)
            }
            continue
        }

        if (Test-Path -LiteralPath $resolvedTargetPath -PathType Container) {
            $directoryTexFiles = Get-ChildItem -LiteralPath $resolvedTargetPath -Recurse -File -Filter '*.tex' |
                Sort-Object FullName
            foreach ($resolvedTexFile in $directoryTexFiles) {
                if (-not (Test-IsSubPath -Path $resolvedTexFile.FullName -BasePath $RepoRoot)) {
                    throw "Resolved TeX file escaped repository root: $($resolvedTexFile.FullName)"
                }

                if ($seenPaths.Add($resolvedTexFile.FullName)) {
                    $resolvedFiles.Add($resolvedTexFile)
                }
            }
            continue
        }

        throw "TeX target not found: $target"
    }

    if ($resolvedFiles.Count -eq 0) {
        throw 'No TeX files were resolved from the specified targets.'
    }

    return @($resolvedFiles)
}

$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot = Get-RepoRoot -StartDir $scriptDir

$resolvedTexFiles = @(Resolve-TexTargetFiles -Targets $TexTargets -RepoRoot $repoRoot)

if ($OutputDir) {
    if ([System.IO.Path]::IsPathRooted($OutputDir)) {
        throw "OutputDir must be relative to the repository root."
    }
    $outputRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $OutputDir))

    if (-not (Test-IsSubPath -Path $outputRoot -BasePath $repoRoot)) {
        throw "Output directory must be inside the repository: $OutputDir"
    }

    $duplicateBaseNames = $resolvedTexFiles |
        Group-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.Name) } |
        Where-Object { $_.Count -gt 1 }
    if ($duplicateBaseNames) {
        $names = ($duplicateBaseNames | ForEach-Object { $_.Name }) -join ', '
        throw "OutputDir cannot be shared by TeX files with duplicate base names: $names"
    }

    if (-not (Test-Path -LiteralPath $outputRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
    }
}

if (-not (Get-Command pdflatex -ErrorAction SilentlyContinue)) {
    throw 'pdflatex was not found. Install TeX Live or MiKTeX and add it to PATH.'
}

Write-Host ("TeX targets resolved: {0}" -f $resolvedTexFiles.Count) -ForegroundColor Cyan

foreach ($resolvedTexFile in $resolvedTexFiles) {
    if ($OutputDir) {
        $currentOutputRoot = $outputRoot
    } else {
        $currentOutputRoot = $resolvedTexFile.DirectoryName
    }

    if (-not (Test-IsSubPath -Path $currentOutputRoot -BasePath $repoRoot)) {
        throw "Output directory must be inside the repository: $currentOutputRoot"
    }

    if (-not (Test-Path -LiteralPath $currentOutputRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $currentOutputRoot -Force | Out-Null
    }

    Write-Host ("TeX file: {0}" -f $resolvedTexFile.FullName) -ForegroundColor Cyan
    Write-Host ("PDF output directory: {0}" -f $currentOutputRoot) -ForegroundColor Cyan

    Compile-OneTexFile -ResolvedTexFile $resolvedTexFile -OutputRoot $currentOutputRoot
}
