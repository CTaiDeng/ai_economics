#!/usr/bin/env pwsh
<#
  从远程仓库拉取最新代码（git pull）。

  说明：
  - 默认 remote=origin；
  - 默认 branch=当前分支；若显式传入 -Branch 且与当前分支不同，会先 checkout 到该分支再拉取；
  - 默认要求工作区干净；可用 -AutoStash 自动 stash（含未跟踪文件）并在拉取后恢复；
  - 可选 -Prune：先执行一次 git fetch --prune；
  - 可选 -Rebase：使用 git pull --rebase（否则使用 merge）。

  用法：
    .\git_pull.ps1
    .\git_pull.ps1 -Remote origin -Branch main
    .\git_pull.ps1 -Prune
    .\git_pull.ps1 -Rebase
    .\git_pull.ps1 -AutoStash -Prune -Rebase
#>

param(
  [string]$Remote = "origin",
  [string]$Branch = "",
  [switch]$Rebase = $false,
  [switch]$Prune = $false,
  [switch]$AutoStash = $false
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

function Invoke-GitCapture {
  param(
    [Parameter(Mandatory = $true)]
    [Alias("Args")]
    [string[]]$GitArgs
  )

  $code = $null
  $out = @()

  # git 会把部分进度/提示输出到 stderr；用 Start-Process 重定向避免 PowerShell 将其当作 ErrorRecord。
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    Write-Step ("git " + ($GitArgs -join " "))

    $gitExe = $null
    try { $gitExe = (Get-Command git -ErrorAction SilentlyContinue).Source } catch { $gitExe = $null }
    if ([string]::IsNullOrWhiteSpace($gitExe)) { $gitExe = "git" }

    $stdoutPath = $null
    $stderrPath = $null
    try {
      $stdoutPath = [System.IO.Path]::GetTempFileName()
      $stderrPath = [System.IO.Path]::GetTempFileName()
      $argLine = Join-Win32Args -ArgList $GitArgs
      $proc = Start-Process -FilePath $gitExe -ArgumentList $argLine -NoNewWindow -Wait -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
      $code = $proc.ExitCode

      if (Test-Path -LiteralPath $stdoutPath) { $out += Read-TextLinesAuto -Path $stdoutPath }
      if (Test-Path -LiteralPath $stderrPath) { $out += Read-TextLinesAuto -Path $stderrPath }
    } finally {
      if (-not [string]::IsNullOrWhiteSpace($stdoutPath)) {
        Remove-Item -LiteralPath $stdoutPath -ErrorAction SilentlyContinue
      }
      if (-not [string]::IsNullOrWhiteSpace($stderrPath)) {
        Remove-Item -LiteralPath $stderrPath -ErrorAction SilentlyContinue
      }
    }
  } finally {
    $ErrorActionPreference = $prevEap
  }
  if ($null -eq $code) { $code = $LASTEXITCODE }

  $lines = @()
  foreach ($o in @($out)) {
    if ($null -eq $o) { continue }
    $line = ""
    try { $line = [string]$o } catch { $line = "" }
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $line = Redact-UrlCredentials -Text $line.TrimEnd()
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $lines += $line
  }

  return @{ Code = [int]$code; Lines = $lines }
}

function Invoke-Git {
  param(
    [Parameter(Mandatory = $true)]
    [Alias("Args")]
    [string[]]$GitArgs,
    [switch]$AllowFailure
  )

  $res = Invoke-GitCapture -Args $GitArgs
  foreach ($line in @($res.Lines)) { Write-Host $line }
  if (-not $AllowFailure -and [int]$res.Code -ne 0) {
    if ($res.Lines.Count -gt 0) {
      throw ("git {0} failed with exit code {1}`n{2}" -f ($GitArgs -join " "), $res.Code, ($res.Lines -join "`n"))
    }
    throw ("git {0} failed with exit code {1}" -f ($GitArgs -join " "), $res.Code)
  }
  return [int]$res.Code
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
    $r = Invoke-GitCapture -Args @("-C", $root, "rev-parse", "--show-toplevel")
    if ($r.Code -eq 0 -and $r.Lines.Count -gt 0) {
      $root = ([string]$r.Lines[-1]).Trim()
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

function Test-GitRemote {
  param(
    [string]$RepoRoot,
    [string]$RemoteName
  )

  if ([string]::IsNullOrWhiteSpace($RemoteName)) { return $false }

  $remote = Invoke-GitCapture -Args @("-C", $RepoRoot, "remote", "get-url", $RemoteName)
  return ($remote.Code -eq 0 -and $remote.Lines.Count -gt 0)
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
  $inside = Invoke-GitCapture -Args @("-C", $repoRoot, "rev-parse", "--is-inside-work-tree")
  $insideText = ($inside.Lines -join "`n").Trim()
  if ($inside.Code -ne 0) {
    if ($insideText -match "(?i)dubious ownership|safe\\.directory") {
      $safePath = To-GitPath -Path $repoRoot
      Write-Step ("applying git safe.directory: {0}" -f $safePath)
      Invoke-Git -Args @("config", "--global", "--add", "safe.directory", $safePath) | Out-Null
      $inside = Invoke-GitCapture -Args @("-C", $repoRoot, "rev-parse", "--is-inside-work-tree")
      $insideText = ($inside.Lines -join "`n").Trim()
    }
  }
  if ($inside.Code -ne 0) {
    if ([string]::IsNullOrWhiteSpace($insideText)) { throw "Not inside a git repository." }
    throw ("Not inside a git repository.`n{0}" -f $insideText)
  }

  $remoteToUse = ([string]($Remote ?? "")).Trim()
  if ([string]::IsNullOrWhiteSpace($remoteToUse)) { $remoteToUse = "origin" }

  if (-not (Test-GitRemote -RepoRoot $repoRoot -RemoteName $remoteToUse)) {
    return
  }

  $branchNow = ""
  try {
    $bn = Invoke-GitCapture -Args @("-C", $repoRoot, "rev-parse", "--abbrev-ref", "HEAD")
    if ($bn.Code -eq 0 -and $bn.Lines.Count -gt 0) { $branchNow = ([string]$bn.Lines[-1]).Trim() }
  } catch {
    $branchNow = ""
  }

  if ([string]::IsNullOrWhiteSpace($branchNow) -or $branchNow -eq "HEAD") {
    throw "当前处于 Detached HEAD；请先 checkout 到某个分支后再拉取。"
  }

  $targetBranch = ([string]($Branch ?? "")).Trim()
  if ([string]::IsNullOrWhiteSpace($targetBranch)) { $targetBranch = $branchNow }

  Write-Step ("current branch: {0}" -f $branchNow)
  if ($targetBranch -ne $branchNow) {
    Write-Step ("target branch : {0}" -f $targetBranch)
  }

  $didStash = $false
  if ($AutoStash) {
    $status = Invoke-GitCapture -Args @("-C", $repoRoot, "status", "--porcelain")
    if ($status.Code -ne 0) { throw ("git status failed with exit code {0}" -f $status.Code) }
    if ($status.Lines.Count -gt 0) {
      $msg = "auto-stash before pull " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
      Write-Step "worktree dirty; auto-stash enabled"
      Invoke-Git -Args @("-C", $repoRoot, "stash", "push", "-u", "-m", $msg) | Out-Null
      $didStash = $true
    }
  } else {
    $status = Invoke-GitCapture -Args @("-C", $repoRoot, "status", "--porcelain")
    if ($status.Code -ne 0) { throw ("git status failed with exit code {0}" -f $status.Code) }
    if ($status.Lines.Count -gt 0) {
      throw "工作区存在未提交改动（git status --porcelain 非空）。请先提交/丢弃，或使用 -AutoStash。"
    }
  }

  # 先 fetch（可选 prune），便于后续 checkout 远程分支/减少 pull 的歧义。
  if ($Prune) {
    Invoke-Git -Args @("-C", $repoRoot, "fetch", "--prune", $remoteToUse) | Out-Null
  } else {
    Invoke-Git -Args @("-C", $repoRoot, "fetch", $remoteToUse) | Out-Null
  }

  if ($targetBranch -ne $branchNow) {
    $co = Invoke-GitCapture -Args @("-C", $repoRoot, "checkout", $targetBranch)
    foreach ($line in @($co.Lines)) { Write-Host $line }
    if ($co.Code -ne 0) {
      Write-Step ("checkout 失败，尝试创建本地分支并跟踪 {0}/{1}" -f $remoteToUse, $targetBranch)
      Invoke-Git -Args @("-C", $repoRoot, "checkout", "-b", $targetBranch, "$remoteToUse/$targetBranch") | Out-Null
    }
  }

  $pullArgs = @("-C", $repoRoot, "pull")
  if ($Rebase) { $pullArgs += @("--rebase") }
  $pullArgs += @($remoteToUse, $targetBranch)
  Invoke-Git -Args $pullArgs | Out-Null

  if ($didStash) {
    Write-Step "restoring stash (git stash pop)"
    Invoke-Git -Args @("-C", $repoRoot, "stash", "pop") | Out-Null
  }

  Write-Step "done"
} finally {
  Pop-Location
}
