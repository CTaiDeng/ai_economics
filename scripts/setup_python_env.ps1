param(
    [switch]$ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$repositoryRoot = [IO.Path]::GetFullPath(
    [IO.Path]::Combine($PSScriptRoot, "..")
)
$venvRoot = Join-Path $repositoryRoot ".venv"
$venvPython = Join-Path $venvRoot "Scripts\python.exe"
$requirementsPath = Join-Path $repositoryRoot "requirements.txt"
$governanceConfigPath = Join-Path `
    $repositoryRoot `
    "scripts\pycache_customize\pycache_governance.json"
$runner = Join-Path `
    $repositoryRoot `
    "scripts\pycache_customize\run_python_with_config.ps1"

function Resolve-ExactPythonLauncher {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Selector,
        [Parameter(Mandatory = $true)]
        [string]$ExpectedVersion
    )

    $candidatePaths = @(
        Get-Command py.exe -CommandType Application -All `
            -ErrorAction SilentlyContinue |
            ForEach-Object { [string]$_.Source } |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_) -and
                (Test-Path -LiteralPath $_ -PathType Leaf)
            } |
            Select-Object -Unique
    )
    if ($candidatePaths.Count -eq 0) {
        throw (
            "Python Launcher was not found. Install Python $ExpectedVersion " +
            "before creating the repository .venv."
        )
    }

    $diagnostics = [Collections.Generic.List[string]]::new()
    foreach ($candidatePath in $candidatePaths) {
        try {
            $versionLines = @(& $candidatePath $Selector -c `
                "import platform; print(platform.python_version())" 2>&1)
            if ($null -eq $LASTEXITCODE) {
                $exitCode = 0
            }
            else {
                $exitCode = [int]$LASTEXITCODE
            }
            $actualVersion = [string](
                $versionLines |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Select-Object -Last 1
            )
            $actualVersion = $actualVersion.Trim()
            if ($exitCode -eq 0 -and $actualVersion -ceq $ExpectedVersion) {
                return $candidatePath
            }
            $diagnostics.Add(
                "$candidatePath (exit=$exitCode, version=$actualVersion)"
            )
        }
        catch {
            $diagnostics.Add(
                "$candidatePath (error=$($_.Exception.Message))"
            )
        }
    }

    throw (
        "No Python Launcher candidate provides Python $ExpectedVersion. " +
        "Checked: $($diagnostics -join '; ')"
    )
}

foreach ($requiredFile in @(
    $requirementsPath,
    $governanceConfigPath,
    $runner
)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Required Python environment file was not found: $requiredFile"
    }
}

try {
    $governanceConfig = Get-Content `
        -LiteralPath $governanceConfigPath `
        -Raw `
        -Encoding UTF8 | ConvertFrom-Json
}
catch {
    throw (
        "Invalid pycache governance JSON '$governanceConfigPath': " +
        $_.Exception.Message
    )
}
$requiredPythonVersion = [string]$governanceConfig.python.required_version
$requiredPythonVersion = $requiredPythonVersion.Trim()
if ([string]::IsNullOrWhiteSpace($requiredPythonVersion)) {
    throw "python.required_version must be configured in pycache_governance.json"
}
$requiredVersion = [Version]$requiredPythonVersion
$launcherSelector = "-$($requiredVersion.Major).$($requiredVersion.Minor)"

if (-not (Test-Path -LiteralPath $venvPython -PathType Leaf)) {
    if ($ValidateOnly) {
        throw "Repository .venv Python was not found: $venvPython"
    }
    $launcherPath = Resolve-ExactPythonLauncher `
        -Selector $launcherSelector `
        -ExpectedVersion $requiredPythonVersion
    & $launcherPath $launcherSelector -m venv $venvRoot
    if ($LASTEXITCODE -ne 0 -or
        -not (Test-Path -LiteralPath $venvPython -PathType Leaf)) {
        throw "Failed to create repository .venv: $venvRoot"
    }
}

Push-Location $repositoryRoot
try {
    if (-not $ValidateOnly) {
        $installArgs = @(
            "-m", "pip", "install",
            "--disable-pip-version-check",
            "--requirement", $requirementsPath
        )
        & $runner @installArgs
        if ($LASTEXITCODE -ne 0) {
            throw "requirements installation failed: exit=$LASTEXITCODE"
        }
    }

    $probe = @'
import importlib.metadata as metadata
import json
from packaging.requirements import Requirement
from pathlib import Path
import platform
import sys

requirements_path = Path(sys.argv[1]).resolve()
required_python_version = sys.argv[2]
expected = {}
for raw_line in requirements_path.read_text(encoding='utf-8').splitlines():
    line = raw_line.split('#', 1)[0].strip()
    if not line or line.startswith(('--', '-e ')):
        continue
    requirement = Requirement(line)
    if requirement.marker is not None and not requirement.marker.evaluate():
        continue
    expected[requirement.name] = str(requirement.specifier)

mismatches = []
installed = {}
for name, expected_specifier in sorted(expected.items()):
    try:
        actual_version = metadata.version(name)
    except metadata.PackageNotFoundError:
        actual_version = '<missing>'
    installed[name] = actual_version
    if actual_version == '<missing>' or actual_version not in Requirement(
        f'{name}{expected_specifier}'
    ).specifier:
        mismatches.append(
            f'{name}: expected={expected_specifier} actual={actual_version}'
        )

payload = {
    'python_version': platform.python_version(),
    'python_executable': str(Path(sys.executable).resolve()),
    'requirements': str(requirements_path),
    'installed': installed,
    'mismatches': mismatches,
}
print(json.dumps(payload, ensure_ascii=False, sort_keys=True))
if platform.python_version() != required_python_version or mismatches:
    raise SystemExit(1)
'@
    $probeArgs = @(
        "-c", $probe, $requirementsPath, $requiredPythonVersion
    )
    $probeOutput = @(& $runner @probeArgs)
    if ($LASTEXITCODE -ne 0) {
        throw "Python $requiredPythonVersion requirements validation failed."
    }
    $probePayload = ($probeOutput |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Last 1) | ConvertFrom-Json

    $pipCheckArgs = @("-m", "pip", "check")
    $pipCheckOutput = @(& $runner @pipCheckArgs)
    if ($LASTEXITCODE -ne 0) {
        throw "pip dependency consistency validation failed."
    }

    Write-Host ($probePayload | ConvertTo-Json -Compress -Depth 4)
    foreach ($line in $pipCheckOutput) {
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            Write-Host $line
        }
    }
    Write-Host "python_environment=closed" -ForegroundColor Green
}
finally {
    Pop-Location
}
