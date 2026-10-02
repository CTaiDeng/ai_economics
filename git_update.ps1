# 用法：.\git_update.ps1 [-Message update] [-TrackedOnly] [-IncludeExcluded] [-NoPush] [-Remote origin] [-Branch master]
# 默认行为：自动刷新 .gitattributes 审查白名单，然后提交并推送全部变更。
# -IncludeExcluded 为旧版兼容参数；现在全部路径默认都会被 stage。
param(
    [string]$Message = "update",
    [string]$Remote = "",
    [string]$Branch = "",
    [switch]$TrackedOnly,
    [switch]$IncludeExcluded,
    [switch]$NoPush
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Redact-UrlCredentials {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }

    # Redact credentials embedded in URLs (e.g. https://token@github.com/...).
    return ([regex]::Replace($Text, "(?i)(https?://)([^/\\s@]+)@", '${1}***@'))
}

function Write-Step {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    Write-Host ("[{0}] {1}" -f $ts, $Message)
}

function Quote-Win32Arg {
    param([string]$Arg)
    if ($null -eq $Arg) { return '""' }

    $a = [string]$Arg
    if ($a.Length -eq 0) { return '""' }
    if ($a -notmatch '[\s"]') { return $a }

    $result = '"'
    $backslashes = 0

    foreach ($ch in $a.ToCharArray()) {
        if ($ch -eq '\') {
            $backslashes++
            continue
        }

        if ($ch -eq '"') {
            $result += ('\' * ($backslashes * 2 + 1)) + '"'
            $backslashes = 0
            continue
        }

        if ($backslashes -gt 0) {
            $result += ('\' * $backslashes)
            $backslashes = 0
        }

        $result += $ch
    }

    if ($backslashes -gt 0) {
        $result += ('\' * ($backslashes * 2))
    }

    $result += '"'
    return $result
}

function Join-Win32Args {
    param([string[]]$ArgList)
    $parts = @()
    foreach ($a in @($ArgList)) {
        $parts += (Quote-Win32Arg -Arg $a)
    }
    return ($parts -join " ")
}

function Read-TextLinesAuto {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return @() }
    if (-not (Test-Path -LiteralPath $Path)) { return @() }

    $bytes = $null
    try { $bytes = [System.IO.File]::ReadAllBytes($Path) } catch { return @() }
    if ($null -eq $bytes -or $bytes.Length -eq 0) { return @() }

    $encoding = $null
    $offset = 0

    # BOM detection
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $encoding = [System.Text.Encoding]::UTF8
        $offset = 3
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $encoding = [System.Text.Encoding]::Unicode
        $offset = 2
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $encoding = [System.Text.Encoding]::BigEndianUnicode
        $offset = 2
    } else {
        # Prefer strict UTF-8; fallback to system ANSI codepage if bytes are not valid UTF-8.
        try {
            $utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
            [void]$utf8Strict.GetString($bytes)
            $encoding = [System.Text.Encoding]::UTF8
            $offset = 0
        } catch {
            $encoding = [System.Text.Encoding]::Default
            $offset = 0
        }
    }

    $text = ""
    try { $text = $encoding.GetString($bytes, $offset, $bytes.Length - $offset) } catch { return @() }
    if ([string]::IsNullOrEmpty($text)) { return @() }

    $text = $text -replace "`r`n", "`n"
    $text = $text -replace "`r", "`n"
    return ($text -split "`n", 0, "SimpleMatch")
}

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)]
        [Alias("Args")]
        [string[]]$GitArgs,
        [switch]$AllowFailure
    )

    $code = $null
    $out = @()

    # git writes progress output (e.g. "To https://...") to stderr even on success.
    # With $ErrorActionPreference="Stop", PowerShell treats native stderr as errors and will terminate.
    # Temporarily relax it and rely on exit codes instead.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        Write-Step ("git " + ($GitArgs -join " "))
        $gitExe = $null
        try { $gitExe = (Get-Command git -ErrorAction SilentlyContinue).Source } catch { $gitExe = $null }
        if ([string]::IsNullOrWhiteSpace($gitExe)) { $gitExe = "git" }

        # Prevent git / GCM from blocking forever on undetected terminal prompts.
        # (Commit hooks / GPG pinentry still use the shared console; see -NoNewWindow below.)
        #
        # Also sanitize the child process environment so MSYS2/Git-bash hooks (which run
        # bash/sh for commit-msg / pre-commit / etc.) don't inherit Windows-specific Conda,
        # venv, or shell-startup pollution.  Symptoms of such pollution include: conda.exe
        # path-not-found errors, hooks hanging because bash tries to exec a GUI conda hook,
        # or the classic "Start-Process -Wait hangs forever" because grandchildren survive.
        $savedEnv = @{}
        $spawnsLongLivedChildren = $false
        foreach ($a in @($GitArgs)) {
            if ($a -eq "commit" -or $a -eq "tag" -or $a -eq "merge" -or $a -eq "pull" -or $a -eq "push" -or $a -eq "rebase" -or $a -eq "fetch" -or $a -eq "clone") {
                $spawnsLongLivedChildren = $true
                break
            }
        }
        $blockVars = @(
            "GIT_TERMINAL_PROMPT",
            "GCM_INTERACTIVE",
            "BASH_ENV",
            "ENV",
            "PROMPT_COMMAND",
            "PYTHONHOME"
        )
        foreach ($envVar in $blockVars) {
            $savedEnv[$envVar] = [Environment]::GetEnvironmentVariable($envVar, "Process")
            [Environment]::SetEnvironmentVariable($envVar, $null, "Process")
        }
        # Explicit safety-set: never prompt for terminal credentials inside automation.
        # Exception: commit / tag / merge may require GPG pinentry passphrase prompt; allow
        # GIT_TERMINAL_PROMPT to remain unset (system default) so pinentry dialogs can surface.
        if (-not $spawnsLongLivedChildren) {
            [Environment]::SetEnvironmentVariable("GIT_TERMINAL_PROMPT", "0", "Process")
        }
        [Environment]::SetEnvironmentVariable("GCM_INTERACTIVE", "0", "Process")

        # Strip Conda / venv injection variables.  Patterns: CONDA_*, _CONDA_*, VIRTUAL_ENV.
        # These commonly force Windows Python / Conda paths into MSYS2 $PATH via /etc/profile.d
        # or BASH_ENV scripts, producing "bash: /D/.../conda.exe: No such file or directory".
        $condaLike = @(Get-ChildItem Env: -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -like "CONDA_*" -or $_.Name -like "_CONDA_*" -or $_.Name -eq "VIRTUAL_ENV" -or $_.Name -eq "Anaconda3"
        })
        foreach ($item in $condaLike) {
            if (-not $savedEnv.ContainsKey($item.Name)) {
                $savedEnv[$item.Name] = [Environment]::GetEnvironmentVariable($item.Name, "Process")
                [Environment]::SetEnvironmentVariable($item.Name, $null, "Process")
            }
        }
        try {
            $argLine = Join-Win32Args -ArgList $GitArgs
            $timeoutMs = 30 * 60 * 1000

            # Mode A (passthrough console): for commit / tag / push / pull etc. which spawn
            # long-lived grandchildren (gpg-agent, fsmonitor--daemon, credential helper).
            #
            # Two separate Windows bugs force this approach:
            #  1. Start-Process -RedirectStandardOutput/Error creates inheritable pipe
            #     handles. Grandchildren (gpg-agent etc.) keep those pipes open forever,
            #     so our read-end never receives EOF and blocks indefinitely.
            #  2. Process.Start with CreateNoWindow=$true / UseShellExecute=$false puts
            #     the child on a non-interactive window station; GPG pinentry and other
            #     GUI helpers can never surface their dialogs and the child waits forever.
            #
            # Workaround: invoke git directly via PowerShell call operator so it attaches
            # to the CURRENT console, inheriting our stdin/stdout/stderr with NO new pipe
            # handles. Grandchildren can't inherit redirected streams so EOF works. The
            # visible window station lets pinentry / credential dialogs appear to the user.
            #
            # A watchdog thread enforces the timeout by killing the git PID tree.
            if ($spawnsLongLivedChildren) {
                $gitProc = $null
                try {
                    # Launch git in current console (same console window station = pinentry works).
                    # No redirection of stdout/stderr: no inheritable pipe handles are created,
                    # so long-lived grandchildren (gpg-agent, fsmonitor-daemon) can't hold
                    # streams open and cause WaitForExit to hang.
                    $ErrorActionPreference = "Continue"
                    $gitProc = Start-Process -FilePath $gitExe -ArgumentList $argLine -NoNewWindow -PassThru
                    $exited = $gitProc.WaitForExit($timeoutMs)
                    if (-not $exited) {
                        try { $gitProc.Kill($true) } catch { try { $gitProc.Kill() } catch { } }
                        try { $gitProc.WaitForExit(5000) } catch { }
                        throw ("git {0} timed out after {1} minutes (likely waiting for interactive input such as GPG passphrase, pinentry dialog, or commit hook prompt)." -f ($GitArgs -join " "), 30)
                    }
                    [void]$gitProc.WaitForExit()
                    $code = $gitProc.ExitCode
                }
                finally {
                    try {
                        if ($gitProc -and -not $gitProc.HasExited) {
                            $gitProc | Stop-Process -Force -ErrorAction SilentlyContinue
                        }
                    } catch { }
                }
            }
            # Mode B (capture streams): for stateless commands (add / diff / status / config ...).
            # Safe to use Start-Process redirection because no persistent grandchildren remain.
            else {
                $stdoutPath = $null
                $stderrPath = $null
                try {
                    $stdoutPath = [System.IO.Path]::GetTempFileName()
                    $stderrPath = [System.IO.Path]::GetTempFileName()
                    # IMPORTANT: do NOT use -Wait here.  On Windows, Start-Process -Wait combined with
                    # redirected stdout/stderr waits for the ENTIRE process tree (including grandchildren
                    # spawned by hooks, gpg-agent, credential helpers, etc.).  Call $proc.WaitForExit()
                    # instead, which only waits for the direct git child process.
                    #
                    # A generous 30-minute timeout is still applied so interactive prompts that cannot
                    # proceed (e.g. pinentry with no GUI) eventually surface as errors instead of hanging.
                    $proc = Start-Process -FilePath $gitExe -ArgumentList $argLine -NoNewWindow -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
                    $exited = $proc.WaitForExit($timeoutMs)
                    if (-not $exited) {
                        try { $proc.Kill() } catch { }
                        try { $proc.WaitForExit(5000) } catch { }
                        throw ("git {0} timed out after {1} minutes (likely waiting for interactive input such as GPG passphrase, pinentry dialog, or commit hook prompt)." -f ($GitArgs -join " "), 30)
                    }
                    # Ensure output streams are fully flushed after WaitForExit with timeout.
                    [void]$proc.WaitForExit()
                    $code = $proc.ExitCode

                    if (Test-Path -LiteralPath $stdoutPath) {
                        $out += Read-TextLinesAuto -Path $stdoutPath
                    }
                    if (Test-Path -LiteralPath $stderrPath) {
                        $out += Read-TextLinesAuto -Path $stderrPath
                    }
                }
                finally {
                    if (-not [string]::IsNullOrWhiteSpace($stdoutPath)) {
                        Remove-Item -LiteralPath $stdoutPath -ErrorAction SilentlyContinue
                    }
                    if (-not [string]::IsNullOrWhiteSpace($stderrPath)) {
                        Remove-Item -LiteralPath $stderrPath -ErrorAction SilentlyContinue
                    }
                }
            }
        }
        finally {
            foreach ($envVar in $savedEnv.Keys) {
                [Environment]::SetEnvironmentVariable($envVar, $savedEnv[$envVar], "Process")
            }
        }
    }
    finally {
        $ErrorActionPreference = $prevEap
    }
    if ($null -eq $code) { $code = $LASTEXITCODE }

    $lines = @()
    foreach ($o in @($out)) {
        if ($null -eq $o) { continue }

        # Avoid PowerShell's ErrorRecord formatting (which prints "At ...", CategoryInfo, etc).
        $line = ""
        if ($o -is [System.Management.Automation.ErrorRecord]) {
            try { $line = $o.ToString() } catch { $line = "" }
        } else {
            try { $line = [string]$o } catch { $line = "" }
        }

        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $line = Redact-UrlCredentials -Text $line.TrimEnd()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $lines += $line
    }

    foreach ($line in $lines) {
        Write-Host $line
    }

    if (-not $AllowFailure -and $code -ne 0) {
        if ($lines.Count -gt 0) {
            throw ("git {0} failed with exit code {1}`n{2}" -f ($GitArgs -join " "), $code, ($lines -join "`n"))
        }

        throw ("git {0} failed with exit code {1}" -f ($GitArgs -join " "), $code)
    }

    return $code
}

function Resolve-RepoRoot {
    $root = $null
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $root = $PSScriptRoot
    } else {
        $root = (Get-Location).Path
    }

    # Best-effort: prefer git's view of the repository root.
    try {
        $gitRoot = (& git -C $root rev-parse --show-toplevel 2>&1)
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($gitRoot)) {
            $root = ([string]$gitRoot).Trim()
        }
    } catch {
    }

    try { $root = (Resolve-Path -LiteralPath $root).Path } catch { }
    return ([string]$root).Trim()
}

function To-GitPath {
    param([string]$Path)
    $p = $Path
    try { $p = (Resolve-Path -LiteralPath $p).Path } catch { }
    return ([string]$p).Replace("\\", "/")
}

function Write-Utf8NoBomLf {
    param(
        [string]$Path,
        [string[]]$Lines
    )

    $text = (($Lines -join "`n") + "`n")
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $text, $encoding)
}

function Test-GitRemote {
    param(
        [string]$RepoRoot,
        [string]$RemoteName
    )

    if ([string]::IsNullOrWhiteSpace($RemoteName)) { return $false }

    $out = @(& git -C $RepoRoot remote get-url $RemoteName 2>$null)
    return ($LASTEXITCODE -eq 0 -and $out.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace(([string]$out[0]).Trim()))
}

function Set-ManagedBlock {
    param(
        [string]$Path,
        [string]$BeginMarker,
        [string]$EndMarker,
        [string[]]$BlockLines
    )

    $existing = @()
    if (Test-Path -LiteralPath $Path) {
        $existing = Read-TextLinesAuto -Path $Path
    }

    $kept = @()
    $inside = $false
    foreach ($line in @($existing)) {
        if ($line -eq $BeginMarker) {
            $inside = $true
            continue
        }
        if ($line -eq $EndMarker) {
            $inside = $false
            continue
        }
        if (-not $inside) {
            $kept += $line
        }
    }

    while ($kept.Count -gt 0 -and [string]::IsNullOrWhiteSpace($kept[$kept.Count - 1])) {
        if ($kept.Count -eq 1) {
            $kept = @()
        } else {
            $kept = @($kept[0..($kept.Count - 2)])
        }
    }

    if ($kept.Count -gt 0) {
        $kept += ""
    }
    $kept += $BlockLines
    Write-Utf8NoBomLf -Path $Path -Lines $kept
}

function Get-ReviewWhitelistPathspecs {
    return @(
        ".gitattributes",
        ".gitignore",
        "AGENTS.md",
        "git_update.ps1",
        "docs",
        "scripts",
        "src/.gitattributes",
        "src/godot3d/project.godot",
        "src/godot3d/scenes",
        "src/godot3d/scripts",
        "src/godot3d/data/godot_domain/resources",
        "src/godot3d/data/godot_domain/fixtures"
    )
}

function Test-ReviewWhitelistPath {
    param([string]$Path)

    $p = ([string]$Path).Replace("\\", "/").Trim()
    if ([string]::IsNullOrWhiteSpace($p)) { return $false }

    $exact = @(
        ".gitattributes",
        ".gitignore",
        "AGENTS.md",
        "git_update.ps1",
        "src/.gitattributes",
        "src/godot3d/project.godot"
    )
    foreach ($item in $exact) {
        if ($p -eq $item) { return $true }
    }

    $prefixes = @(
        "docs/",
        "scripts/",
        "src/godot3d/scenes/",
        "src/godot3d/scripts/",
        "src/godot3d/data/godot_domain/resources/",
        "src/godot3d/data/godot_domain/fixtures/"
    )
    foreach ($prefix in $prefixes) {
        if ($p.StartsWith($prefix, [System.StringComparison]::Ordinal)) {
            return $true
        }
    }

    return $false
}

function Get-ChangedGitPaths {
    param([string]$RepoRoot)

    $lines = @(& git -C $RepoRoot status --porcelain=v1 2>$null)
    $paths = @()
    foreach ($line in @($lines)) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.Length -lt 4) { continue }
        $path = $line.Substring(3).Trim()
        if ($path.Contains(" -> ")) {
            $parts = $path -split " -> "
            $path = $parts[$parts.Count - 1].Trim()
        }
        $path = $path.Trim('"')
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            $paths += $path.Replace("\\", "/")
        }
    }
    return @($paths | Sort-Object -Unique)
}

function Write-ExcludedReviewPaths {
    param([string]$RepoRoot)

    $excluded = @()
    foreach ($path in @(Get-ChangedGitPaths -RepoRoot $RepoRoot)) {
        if (-not (Test-ReviewWhitelistPath -Path $path)) {
            $excluded += $path
        }
    }

    if ($excluded.Count -eq 0) {
        Write-Step "review whitelist: no excluded working-tree changes"
        return
    }

    Write-Step ("review whitelist: excluded {0} changed path(s)" -f $excluded.Count)
    foreach ($path in @($excluded | Select-Object -First 30)) {
        Write-Host ("  excluded: {0}" -f $path)
    }
    if ($excluded.Count -gt 30) {
        Write-Host ("  ... {0} more" -f ($excluded.Count - 30))
    }
}

function Update-ReviewWhitelistAttributes {
    param([string]$RepoRoot)

    $rootAttributes = Join-Path $RepoRoot ".gitattributes"
    $srcAttributes = Join-Path $RepoRoot "src\.gitattributes"

    $rootBlock = @(
        "# BEGIN git_update.ps1 review whitelist",
        "# Default: exclude everything from text normalization and review diffs.",
        "# Allowed paths below are review/diff whitelist entries; git_update.ps1 stages all paths by default.",
        "* -text -diff linguist-generated=true",
        "*.pdf filter=lfs diff=lfs merge=lfs -text -eol -working-tree-encoding linguist-generated=true",
        ".gitattributes text eol=lf working-tree-encoding=UTF-8 diff linguist-generated=false",
        ".gitignore text eol=lf working-tree-encoding=UTF-8 diff linguist-generated=false",
        "AGENTS.md text eol=lf working-tree-encoding=UTF-8 diff linguist-generated=false",
        "git_update.ps1 text eol=lf working-tree-encoding=UTF-8 diff linguist-generated=false",
        "docs/** text eol=lf working-tree-encoding=UTF-8 diff linguist-generated=false",
        "docs/**/*.pdf filter=lfs diff=lfs merge=lfs -text -eol -working-tree-encoding linguist-generated=true",
        "scripts/** text eol=lf working-tree-encoding=UTF-8 diff linguist-generated=false",
        "src/.gitattributes text eol=lf working-tree-encoding=UTF-8 diff linguist-generated=false",
        "src/godot3d/project.godot text eol=lf working-tree-encoding=UTF-8 diff linguist-generated=false",
        "src/godot3d/scenes/** text eol=lf working-tree-encoding=UTF-8 diff linguist-generated=false",
        "src/godot3d/scripts/** text eol=lf working-tree-encoding=UTF-8 diff linguist-generated=false",
        "src/godot3d/data/godot_domain/resources/** text eol=lf working-tree-encoding=UTF-8 diff linguist-generated=false",
        "src/godot3d/data/godot_domain/fixtures/** text eol=lf working-tree-encoding=UTF-8 diff linguist-generated=false",
        "# END git_update.ps1 review whitelist"
    )

    $srcBlock = @(
        "# BEGIN git_update.ps1 review whitelist",
        "# Default inside src: exclude third-party and generated trees from review diffs.",
        "* -text -diff linguist-generated=true",
        ".gitattributes text eol=lf working-tree-encoding=UTF-8 diff linguist-generated=false",
        "godot3d/project.godot text eol=lf working-tree-encoding=UTF-8 diff linguist-generated=false",
        "godot3d/scenes/** text eol=lf working-tree-encoding=UTF-8 diff linguist-generated=false",
        "godot3d/scripts/** text eol=lf working-tree-encoding=UTF-8 diff linguist-generated=false",
        "godot3d/data/godot_domain/resources/** text eol=lf working-tree-encoding=UTF-8 diff linguist-generated=false",
        "godot3d/data/godot_domain/fixtures/** text eol=lf working-tree-encoding=UTF-8 diff linguist-generated=false",
        "openra/** -text -diff linguist-generated=true",
        "# END git_update.ps1 review whitelist"
    )

    Write-Step "updating .gitattributes review whitelist"
    Set-ManagedBlock -Path $rootAttributes -BeginMarker $rootBlock[0] -EndMarker $rootBlock[$rootBlock.Count - 1] -BlockLines $rootBlock

    if (-not (Test-Path -LiteralPath (Split-Path -Parent $srcAttributes))) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $srcAttributes) | Out-Null
    }
    Set-ManagedBlock -Path $srcAttributes -BeginMarker $srcBlock[0] -EndMarker $srcBlock[$srcBlock.Count - 1] -BlockLines $srcBlock
}

function Ensure-GitLongPaths {
    param([string]$RepoRoot)

    $current = ""
    try { $current = (& git -C $RepoRoot config --get core.longpaths 2>$null | Select-Object -First 1).Trim() } catch { $current = "" }
    if ($current -eq "true") {
        Write-Step "git core.longpaths already enabled"
        return
    }

    Write-Step "enabling git core.longpaths for this repository"
    Invoke-Git -Args @("-C", $RepoRoot, "config", "core.longpaths", "true") | Out-Null
}

$repoRoot = Resolve-RepoRoot
Push-Location $repoRoot
try {
    Write-Step ("repoRoot={0}" -f $repoRoot)
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "git not found in PATH."
    }

    $dotGit = Join-Path $repoRoot ".git"
    if (-not (Test-Path -LiteralPath $dotGit)) {
        throw ("Not inside a git repository: '{0}' has no .git metadata." -f $repoRoot)
    }

    Write-Step "checking git repository..."
    $insideOut = & git -C $repoRoot rev-parse --is-inside-work-tree 2>&1
    $insideCode = $LASTEXITCODE
    $insideText = ""
    try { $insideText = ($insideOut | Out-String).Trim() } catch { $insideText = "" }
    $insideText = Redact-UrlCredentials -Text $insideText

    if ($insideCode -ne 0) {
        # Auto-fix Git's "dubious ownership" safe.directory guard when applicable.
        if ($insideText -match "(?i)dubious ownership|safe\\.directory") {
            $safePath = To-GitPath -Path $repoRoot
            Write-Step ("applying git safe.directory: {0}" -f $safePath)
            Invoke-Git -Args @("config", "--global", "--add", "safe.directory", $safePath) | Out-Null

            $insideOut = & git -C $repoRoot rev-parse --is-inside-work-tree 2>&1
            $insideCode = $LASTEXITCODE
            try { $insideText = ($insideOut | Out-String).Trim() } catch { $insideText = "" }
            $insideText = Redact-UrlCredentials -Text $insideText
        }
    }

    if ($insideCode -ne 0) {
        if ([string]::IsNullOrWhiteSpace($insideText)) {
            throw "Not inside a git repository."
        }

        throw ("Not inside a git repository.`n{0}" -f $insideText)
    }

    $branchNow = ""
    try { $branchNow = (& git -C $repoRoot rev-parse --abbrev-ref HEAD).Trim() } catch { $branchNow = "" }
    if (-not [string]::IsNullOrWhiteSpace($branchNow)) {
        Write-Step ("current branch: {0}" -f $branchNow)
    }

    Ensure-GitLongPaths -RepoRoot $repoRoot
    Update-ReviewWhitelistAttributes -RepoRoot $repoRoot

    if ($IncludeExcluded) {
        Write-Step "IncludeExcluded is already the default; continuing with full staging"
    }

    if ($TrackedOnly) {
        Write-Step "staging: all tracked changes (git add -u)"
        Invoke-Git -Args @("-C", $repoRoot, "add", "-u") | Out-Null
    } else {
        Write-Step "staging: all changes (git add -A)"
        Invoke-Git -Args @("-C", $repoRoot, "add", "-A") | Out-Null
    }

    $hasStaged = $false
    Write-Step "checking staged changes..."
    $diffCode = Invoke-Git -Args @("-C", $repoRoot, "diff", "--cached", "--quiet") -AllowFailure
    if ($diffCode -eq 1) {
        $hasStaged = $true
    } elseif ($diffCode -eq 0) {
        $hasStaged = $false
    } else {
        throw ("git diff --cached --quiet failed with exit code {0}" -f $diffCode)
    }

    if ($hasStaged) {
        Write-Step ("committing: message='{0}'" -f $Message)
        Invoke-Git -Args @("-C", $repoRoot, "commit", "-m", $Message) | Out-Null
    } else {
        Write-Step "no staged changes; skip commit"
    }

    if ($NoPush) {
        Write-Step "NoPush set; done"
        return
    }

    Write-Step "detecting upstream..."
    $upstream = $null
    try {
        $upstream = (& git -C $repoRoot rev-parse --abbrev-ref --symbolic-full-name "@{u}" 2>$null)
        if ($LASTEXITCODE -ne 0) { $upstream = $null }
    } catch {
        $upstream = $null
    }

    $remoteToUse = $Remote
    if ([string]::IsNullOrWhiteSpace($remoteToUse)) { $remoteToUse = "origin" }

    $remoteForPushCheck = $remoteToUse
    if (-not [string]::IsNullOrWhiteSpace($upstream)) {
        $upstreamText = $upstream.Trim()
        $slash = $upstreamText.IndexOf("/")
        if ($slash -gt 0) {
            $remoteForPushCheck = $upstreamText.Substring(0, $slash)
        }
    }

    if (-not (Test-GitRemote -RepoRoot $repoRoot -RemoteName $remoteForPushCheck)) {
        return
    }

    $branchToUse = $Branch
    if ([string]::IsNullOrWhiteSpace($branchToUse)) {
        $branchToUse = (& git -C $repoRoot rev-parse --abbrev-ref HEAD).Trim()
    }

    if ([string]::IsNullOrWhiteSpace($branchToUse) -or $branchToUse -eq "HEAD") {
        throw "Detached HEAD; cannot auto-push."
    }

    if ([string]::IsNullOrWhiteSpace($upstream)) {
        Write-Step ("pushing: set upstream {0} {1}" -f $remoteToUse, $branchToUse)
        Invoke-Git -Args @("-C", $repoRoot, "push", "--set-upstream", $remoteToUse, $branchToUse) | Out-Null
    } else {
        Write-Step ("pushing: upstream={0}" -f $upstream.Trim())
        Invoke-Git -Args @("-C", $repoRoot, "push") | Out-Null
    }

    Write-Step "done"
}
finally {
    Pop-Location
}