#!/usr/bin/env pwsh
# SPDX-FileCopyrightText: 2026 GaoZheng
# SPDX-License-Identifier: MIT
# Full license: LICENSES/MIT.txt (repository root)

<#
  分阶段 pull 脚本。

  目标：
  - 在项目根目录执行：.\out\staged_pull.ps1
  - 先分步骤同步目标远端分支，再按提交批次 fast-forward 合入；
  - 被中断后再次执行，会根据当前 HEAD 与 out/staged_pull_state.json 继续推进；
  - 默认自动修复上次 batch_merge 中断留下的未暂存工作区残留；
  - 非续跑残留的脏工作区仍会停止；可用 -AutoStash 临时保存未提交改动；
  - 后续阶段沿用同一组颜色打印阶段、命令和结果。

  常用示例：
    .\out\staged_pull.ps1
    .\out\staged_pull.ps1 -BatchSize 3
    .\out\staged_pull.ps1 -FetchDeepenStep 50 -FetchDeepenRounds 20
    .\out\staged_pull.ps1 -FetchFilter ""
    .\out\staged_pull.ps1 -NoBatchObjectFetch
    .\out\staged_pull.ps1 -TempPackPolicy RecoverOrDelete
    .\out\staged_pull.ps1 -TempPackPolicy Skip
    .\out\staged_pull.ps1 -TempPackRecoverMaxBytes 0
    .\out\staged_pull.ps1 -NoAutoRestoreWorktree
    .\out\staged_pull.ps1 -StopBlockingGitProcesses:$false
    .\out\staged_pull.ps1 -FetchTags
    .\out\staged_pull.ps1 -Remote origin -Branch main -Prune
    .\out\staged_pull.ps1 -DryRun
#>

[CmdletBinding()]
param(
  [string]$Remote = "origin",
  [string]$Branch = "",
  [ValidateRange(1, 10000)]
  [int]$BatchSize = 5,
  [switch]$Prune = $false,
  [switch]$AutoStash = $false,
  [switch]$DryRun = $false,
  [switch]$NoColorScheme = $false,
  [ValidateRange(1, 100000)]
  [int]$FetchDeepenStep = 20,
  [ValidateRange(0, 10000)]
  [int]$FetchDeepenRounds = 50,
  [string]$FetchFilter = "blob:none",
  [switch]$NoBatchObjectFetch = $false,
  [ValidateSet("DeleteOnly", "RecoverOrDelete", "Skip")]
  [string]$TempPackPolicy = "DeleteOnly",
  [Int64]$TempPackRecoverMaxBytes = 536870912,
  [switch]$NoAutoRestoreWorktree = $false,
  [switch]$StopBlockingGitProcesses = $true,
  [switch]$FetchTags = $false,
  [string]$StateFile = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
if ($TempPackRecoverMaxBytes -lt 0) { throw "TempPackRecoverMaxBytes 不能小于 0；传 0 表示不限制复用检查大小。" }

function Assert-StagedPullEntryPath {
  $currentScriptPath = $PSCommandPath
  if ([string]::IsNullOrWhiteSpace($currentScriptPath)) {
    $currentScriptPath = $MyInvocation.MyCommand.Path
  }

  $entryAllowed = $false
  if (-not [string]::IsNullOrWhiteSpace($currentScriptPath)) {
    $currentFullPath = [System.IO.Path]::GetFullPath($currentScriptPath)
    $currentDirectory = [System.IO.Path]::GetDirectoryName($currentFullPath)
    if (-not [string]::IsNullOrWhiteSpace($currentDirectory)) {
      $repoCandidate = [System.IO.Path]::GetDirectoryName($currentDirectory)
      if (-not [string]::IsNullOrWhiteSpace($repoCandidate)) {
        $expectedFullPath = [System.IO.Path]::GetFullPath((Join-Path (Join-Path $repoCandidate "out") "staged_pull.ps1"))
        $entryAllowed = [string]::Equals($currentFullPath, $expectedFullPath, [System.StringComparison]::OrdinalIgnoreCase)
      }
    }
  }

  if (-not $entryAllowed) {
    Write-Host "staged_pull.ps1 需要先复制到 out/staged_pull.ps1 后执行。"
    Write-Host "请运行：scripts/staged_pull.cmd"
    exit 1
  }
}

Assert-StagedPullEntryPath

$script:Color = @{
  Banner   = "Cyan"
  Phase    = "Magenta"
  Command  = "DarkGray"
  Detail   = "Gray"
  Ok       = "Green"
  Warn     = "Yellow"
  Error    = "Red"
  Progress = "Blue"
  Resume   = "DarkCyan"
  Skip     = "DarkYellow"
  SubStep  = "DarkMagenta"
}
$script:AutoStashCreated = $false
$script:AutoStashMessage = ""

function Write-Color {
  param(
    [Parameter(Mandatory = $true)][string]$Kind,
    [Parameter(Mandatory = $true)][string]$Message
  )

  $fg = "White"
  if ($script:Color.ContainsKey($Kind)) { $fg = $script:Color[$Kind] }
  Write-Host $Message -ForegroundColor $fg
}

function Write-Phase {
  param(
    [Parameter(Mandatory = $true)][int]$Index,
    [Parameter(Mandatory = $true)][int]$Total,
    [Parameter(Mandatory = $true)][string]$Title
  )

  Write-Host ""
  Write-Color -Kind Phase -Message ("[PHASE {0}/{1}] {2}" -f $Index, $Total, $Title)
}

function Write-SubStep {
  param(
    [Parameter(Mandatory = $true)][int]$Index,
    [Parameter(Mandatory = $true)][int]$Total,
    [Parameter(Mandatory = $true)][string]$Title
  )

  Write-Color -Kind SubStep -Message ("  [SUBSTEP {0}/{1}] {2}" -f $Index, $Total, $Title)
}

function Write-Log {
  param(
    [Parameter(Mandatory = $true)][string]$Kind,
    [Parameter(Mandatory = $true)][string]$Message
  )

  $ts = Get-Date -Format "HH:mm:ss"
  $label = $Kind.ToUpperInvariant()
  Write-Color -Kind $Kind -Message ("[{0}] [{1}] {2}" -f $ts, $label, $Message)
}

function Write-ColorScheme {
  Write-Host ""
  Write-Color -Kind Banner -Message "[COLOR SCHEME] 打印着色方案"
  Write-Color -Kind Phase -Message "  PHASE    阶段标题：当前处于哪一个执行阶段"
  Write-Color -Kind Command -Message "  COMMAND  Git 命令：脚本实际调用的 git 子命令"
  Write-Color -Kind SubStep -Message "  SUBSTEP  子步骤：当前阶段内部的细分动作"
  Write-Color -Kind Progress -Message "  PROGRESS 分块进度：当前批次、提交范围与剩余数量"
  Write-Color -Kind Resume -Message "  RESUME   续跑信息：发现上次状态或从当前 HEAD 继续"
  Write-Color -Kind Ok -Message "  OK       成功结果：阶段完成或仓库已同步"
  Write-Color -Kind Warn -Message "  WARN     需要注意：不会继续破坏性推进的情况"
  Write-Color -Kind Skip -Message "  SKIP     跳过动作：没有必要执行的步骤"
  Write-Color -Kind Error -Message "  ERROR    失败信息：需要人工处理后重试"
}

function Redact-UrlCredentials {
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
  return ([regex]::Replace($Text, "(?i)(https?://)([^/\s@]+)@", '${1}***@'))
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
  foreach ($arg in @($ArgList)) {
    $parts += (Quote-Win32Arg -Arg $arg)
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
    [string[]]$GitArgs,
    [switch]$Quiet = $false
  )

  $code = $null
  $out = @()
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    if (-not $Quiet) {
      Write-Color -Kind Command -Message ("git " + ($GitArgs -join " "))
    }

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
  foreach ($item in @($out)) {
    if ($null -eq $item) { continue }
    $line = ""
    try { $line = [string]$item } catch { $line = "" }
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $line = Redact-UrlCredentials -Text $line.TrimEnd()
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $lines += $line
  }

  return [pscustomobject]@{ Code = [int]$code; Lines = $lines }
}

function Invoke-Git {
  param(
    [Parameter(Mandatory = $true)]
    [Alias("Args")]
    [string[]]$GitArgs,
    [switch]$AllowFailure = $false
  )

  $res = Invoke-GitCapture -Args $GitArgs
  foreach ($line in @($res.Lines)) {
    Write-Color -Kind Detail -Message $line
  }

  if (-not $AllowFailure -and [int]$res.Code -ne 0) {
    if ($res.Lines.Count -gt 0) {
      throw ("git {0} failed with exit code {1}`n{2}" -f ($GitArgs -join " "), $res.Code, ($res.Lines -join "`n"))
    }
    throw ("git {0} failed with exit code {1}" -f ($GitArgs -join " "), $res.Code)
  }

  return [int]$res.Code
}

function Invoke-GitStreaming {
  param(
    [Parameter(Mandatory = $true)]
    [Alias("Args")]
    [string[]]$GitArgs,
    [switch]$AllowFailure = $false
  )

  Write-Color -Kind Command -Message ("git " + ($GitArgs -join " "))

  $gitExe = $null
  try { $gitExe = (Get-Command git -ErrorAction SilentlyContinue).Source } catch { $gitExe = $null }
  if ([string]::IsNullOrWhiteSpace($gitExe)) { $gitExe = "git" }

  $lines = @()
  $code = $null
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    & $gitExe @GitArgs 2>&1 | ForEach-Object {
      $text = ""
      if ($_ -is [System.Management.Automation.ErrorRecord]) {
        try { $text = $_.ToString() } catch { $text = "" }
      } else {
        try { $text = [string]$_ } catch { $text = "" }
      }

      if (-not [string]::IsNullOrWhiteSpace($text)) {
        $text = Redact-UrlCredentials -Text $text
        $text = $text -replace "`r`n", "`n"
        $text = $text -replace "`r", "`n"
        foreach ($line in ($text -split "`n", 0, "SimpleMatch")) {
          if ([string]::IsNullOrWhiteSpace($line)) { continue }
          $clean = $line.TrimEnd()
          $lines += $clean
          Write-Color -Kind Detail -Message $clean
        }
      }
    }
    $code = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $prevEap
  }

  if ($null -eq $code) { $code = 0 }
  if (-not $AllowFailure -and [int]$code -ne 0) {
    if ($lines.Count -gt 0) {
      throw ("git {0} failed with exit code {1}`n{2}" -f ($GitArgs -join " "), $code, ($lines -join "`n"))
    }
    throw ("git {0} failed with exit code {1}" -f ($GitArgs -join " "), $code)
  }

  return [int]$code
}

function Resolve-RepoRoot {
  $start = (Get-Location).Path
  $candidates = @($start)
  if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    $candidates += $PSScriptRoot
  }

  foreach ($candidate in $candidates) {
    $res = Invoke-GitCapture -Args @("-C", $candidate, "rev-parse", "--show-toplevel") -Quiet
    if ($res.Code -eq 0 -and $res.Lines.Count -gt 0) {
      $root = ([string]$res.Lines[-1]).Trim()
      try { return (Resolve-Path -LiteralPath $root).Path } catch { return $root }
    }
  }

  return $start
}

function To-GitPath {
  param([string]$Path)

  $p = $Path
  try { $p = (Resolve-Path -LiteralPath $p).Path } catch { }
  return ([string]$p).Replace("\", "/")
}

function Get-OneLine {
  param([string[]]$GitArgs)

  $res = Invoke-GitCapture -Args $GitArgs -Quiet
  if ($res.Code -ne 0 -or $res.Lines.Count -eq 0) { return "" }
  return ([string]$res.Lines[-1]).Trim()
}

function Save-State {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][hashtable]$Data
  )

  $dir = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir)) {
    [void](New-Item -ItemType Directory -Path $dir -Force)
  }

  if ($script:AutoStashCreated) {
    $Data["autoStashCreated"] = $true
    $Data["autoStashMessage"] = $script:AutoStashMessage
  }

  $json = $Data | ConvertTo-Json -Depth 6
  Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
}

function Read-State {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
  if (-not (Test-Path -LiteralPath $Path)) { return $null }

  try {
    $text = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return ($text | ConvertFrom-Json -ErrorAction Stop)
  } catch {
    return $null
  }
}

function Short-Sha {
  param([string]$Sha)

  if ([string]::IsNullOrWhiteSpace($Sha)) { return "" }
  if ($Sha.Length -le 12) { return $Sha }
  return $Sha.Substring(0, 12)
}

function Get-CommitSubject {
  param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$Commit
  )

  $res = Invoke-GitCapture -Args @("-C", $RepoRoot, "show", "-s", "--format=%s", $Commit) -Quiet
  if ($res.Code -eq 0 -and $res.Lines.Count -gt 0) { return ([string]$res.Lines[0]).Trim() }
  return ""
}

function Get-RemoteBranchTip {
  param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$Remote,
    [Parameter(Mandatory = $true)][string]$Branch
  )

  $res = Invoke-GitCapture -Args @("-C", $RepoRoot, "ls-remote", "--heads", $Remote, $Branch)
  if ($res.Code -ne 0) {
    throw ("git ls-remote failed with exit code {0}" -f $res.Code)
  }

  foreach ($line in @($res.Lines)) {
    $trimmed = ([string]$line).Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
    $parts = $trimmed -split "\s+"
    if ($parts.Count -ge 2 -and $parts[1] -eq ("refs/heads/{0}" -f $Branch)) {
      return $parts[0]
    }
  }

  return ""
}

function Test-GitCommitExists {
  param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$Commit
  )

  if ([string]::IsNullOrWhiteSpace($Commit)) { return $false }
  $res = Invoke-GitCapture -Args @("-C", $RepoRoot, "cat-file", "-e", ("{0}^{{commit}}" -f $Commit)) -Quiet
  return ($res.Code -eq 0)
}

function Get-RevCountText {
  param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$RevisionRange
  )

  $res = Invoke-GitCapture -Args @("-C", $RepoRoot, "rev-list", "--count", $RevisionRange) -Quiet
  if ($res.Code -eq 0 -and $res.Lines.Count -gt 0) {
    return ([string]$res.Lines[-1]).Trim()
  }
  return "unknown"
}

function Test-GitAncestor {
  param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$Ancestor,
    [Parameter(Mandatory = $true)][string]$Descendant
  )

  $code = Invoke-Git -Args @("-C", $RepoRoot, "merge-base", "--is-ancestor", $Ancestor, $Descendant) -AllowFailure
  return ($code -eq 0)
}

function Get-FetchFilterSpec {
  param([string]$Filter)

  $trimmed = ([string]$Filter).Trim()
  if ([string]::IsNullOrWhiteSpace($trimmed)) { return "" }
  if ($trimmed.StartsWith("--filter=", [System.StringComparison]::OrdinalIgnoreCase)) {
    return $trimmed.Substring("--filter=".Length)
  }
  return $trimmed
}

function Get-FetchFilterArg {
  param([string]$Filter)

  $spec = Get-FetchFilterSpec -Filter $Filter
  if ([string]::IsNullOrWhiteSpace($spec)) { return "" }
  return ("--filter={0}" -f $spec)
}

function Get-BranchFetchArgs {
  param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$Remote,
    [Parameter(Mandatory = $true)][string]$RefSpec,
    [string]$Filter = "",
    [string]$DepthArg = "",
    [switch]$Unshallow = $false
  )

  $args = @("-C", $RepoRoot, "fetch", "--no-tags", "--progress", "--verbose")
  $filterArg = Get-FetchFilterArg -Filter $Filter
  if (-not [string]::IsNullOrWhiteSpace($filterArg)) { $args += $filterArg }
  if (-not [string]::IsNullOrWhiteSpace($DepthArg)) { $args += $DepthArg }
  if ($Unshallow) { $args += "--unshallow" }
  $args += @($Remote, $RefSpec)
  return $args
}

function Enable-PartialFetchRemote {
  param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$Remote,
    [Parameter(Mandatory = $true)][string]$Filter
  )

  $filterArg = Get-FetchFilterArg -Filter $Filter
  if ([string]::IsNullOrWhiteSpace($filterArg)) { return }

  Write-Log -Kind Progress -Message ("启用轻量 fetch：{0}，缺失对象可在后续批次按需补齐。" -f $filterArg)
  $filterSpec = Get-FetchFilterSpec -Filter $Filter
  Invoke-Git -Args @("-C", $RepoRoot, "config", ("remote.{0}.promisor" -f $Remote), "true") | Out-Null
  Invoke-Git -Args @("-C", $RepoRoot, "config", ("remote.{0}.partialclonefilter" -f $Remote), $filterSpec) | Out-Null
}

function Get-ObjectFetchArgs {
  param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$Remote,
    [Parameter(Mandatory = $true)][string]$Commit
  )

  return @("-C", $RepoRoot, "fetch", "--no-tags", "--progress", "--verbose", $Remote, $Commit)
}

function Format-ByteSize {
  param([Int64]$Bytes)

  if ($Bytes -ge 1TB) { return ("{0:N2} TiB" -f ($Bytes / 1TB)) }
  if ($Bytes -ge 1GB) { return ("{0:N2} GiB" -f ($Bytes / 1GB)) }
  if ($Bytes -ge 1MB) { return ("{0:N2} MiB" -f ($Bytes / 1MB)) }
  if ($Bytes -ge 1KB) { return ("{0:N2} KiB" -f ($Bytes / 1KB)) }
  return ("{0} B" -f $Bytes)
}

function Get-RepoProcessMatchTerms {
  param(
    [string]$RepoRoot = "",
    [string]$RemoteUrl = ""
  )

  $terms = @()
  if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) {
    $root = $RepoRoot
    try { $root = (Resolve-Path -LiteralPath $RepoRoot).Path } catch { }
    $terms += $root
    $terms += $root.Replace("\", "/")
  }

  if (-not [string]::IsNullOrWhiteSpace($RemoteUrl)) {
    $url = Redact-UrlCredentials -Text $RemoteUrl
    $terms += $url
    $terms += ($url -replace "\.git$", "")

    $m = [regex]::Match($url, "(?i)(github\.com[:/])([^/\s]+/[^/\s]+?)(?:\.git)?$")
    if ($m.Success) {
      $terms += $m.Groups[2].Value
    }
  }

  $unique = @()
  foreach ($term in @($terms)) {
    if ([string]::IsNullOrWhiteSpace($term)) { continue }
    if ($unique -notcontains $term) { $unique += $term }
  }
  return $unique
}

function Get-ActiveGitPackProcesses {
  param(
    [string]$RepoRoot = "",
    [string]$RemoteUrl = ""
  )

  $items = @()
  try {
    $procs = Get-CimInstance Win32_Process -ErrorAction Stop |
      Where-Object { $_.Name -in @("git.exe", "git-remote-https.exe", "ssh.exe") }
  } catch {
    return @()
  }

  $terms = @(Get-RepoProcessMatchTerms -RepoRoot $RepoRoot -RemoteUrl $RemoteUrl)
  $candidates = @()
  foreach ($proc in @($procs)) {
    $name = [string]$proc.Name
    $cmd = [string]$proc.CommandLine
    if ([string]::IsNullOrWhiteSpace($cmd)) { $cmd = $name }

    $isPackProcess = $false
    if ($name -ieq "git-remote-https.exe") {
      $isPackProcess = $true
    } elseif ($name -ieq "ssh.exe") {
      $isPackProcess = ($cmd -match "(?i)(git-upload-pack|github|git@)")
    } elseif ($name -ieq "git.exe") {
      $isPackProcess = ($cmd -match "(?i)\b(fetch|index-pack|unpack-objects|pack-objects|remote-https)\b")
    }

    if ($isPackProcess) {
      $candidates += [pscustomobject]@{
        ProcessId = [int]$proc.ProcessId
        ParentProcessId = [int]$proc.ParentProcessId
        Name = $name
        CreationDate = $proc.CreationDate
        CommandLine = $cmd
      }
    }
  }

  if ($candidates.Count -eq 0) { return @() }

  $byPid = @{}
  $childrenByParent = @{}
  foreach ($proc in @($candidates)) {
    $byPid[[int]$proc.ProcessId] = $proc
    $ppid = [int]$proc.ParentProcessId
    if (-not $childrenByParent.ContainsKey($ppid)) { $childrenByParent[$ppid] = @() }
    $childrenByParent[$ppid] += [int]$proc.ProcessId
  }

  $seedIds = New-Object System.Collections.Generic.HashSet[int]
  foreach ($proc in @($candidates)) {
    $matchesRepo = ($terms.Count -eq 0)
    foreach ($term in @($terms)) {
      if ($proc.CommandLine.IndexOf($term, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
        $matchesRepo = $true
        break
      }
    }
    if ($matchesRepo) { [void]$seedIds.Add([int]$proc.ProcessId) }
  }
  if ($seedIds.Count -eq 0) { return @() }

  $closedIds = New-Object System.Collections.Generic.HashSet[int]
  $queue = New-Object System.Collections.Generic.Queue[int]
  foreach ($id in $seedIds) { $queue.Enqueue([int]$id) }

  while ($queue.Count -gt 0) {
    $currentId = $queue.Dequeue()
    if (-not $byPid.ContainsKey($currentId)) { continue }
    if (-not $closedIds.Add($currentId)) { continue }

    $parentId = [int]$byPid[$currentId].ParentProcessId
    if ($byPid.ContainsKey($parentId)) { $queue.Enqueue($parentId) }

    if ($childrenByParent.ContainsKey($currentId)) {
      foreach ($childId in @($childrenByParent[$currentId])) {
        if ($byPid.ContainsKey($childId)) { $queue.Enqueue([int]$childId) }
      }
    }
  }

  foreach ($id in $closedIds) {
    if ($byPid.ContainsKey($id)) { $items += $byPid[$id] }
  }

  return @($items | Sort-Object CreationDate, ProcessId)
}

function Invoke-GitIndexPackFromFile {
  param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$PackPath,
    [switch]$UsePromisor = $false
  )

  $gitExe = $null
  try { $gitExe = (Get-Command git -ErrorAction SilentlyContinue).Source } catch { $gitExe = $null }
  if ([string]::IsNullOrWhiteSpace($gitExe)) { $gitExe = "git" }

  $args = @("-C", $RepoRoot, "index-pack", "--stdin", "--fix-thin")
  if ($UsePromisor) {
    $args += "--promisor=staged-pull-temp-pack-recovery"
  }

  $lines = @()
  $copyError = ""
  $openFailed = $false
  $exitCode = 1
  $fileStream = $null

  try {
    $fileStream = [System.IO.File]::Open($PackPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
  } catch {
    $openFailed = $true
    $lines += ("无法读取临时 pack：{0}" -f $_.Exception.Message)
    return [pscustomobject]@{ Code = 1; Lines = @($lines); CopyError = ""; OpenFailed = $openFailed }
  }

  $proc = New-Object System.Diagnostics.Process
  $proc.StartInfo = New-Object System.Diagnostics.ProcessStartInfo
  $proc.StartInfo.FileName = $gitExe
  $proc.StartInfo.Arguments = Join-Win32Args -ArgList $args
  $proc.StartInfo.WorkingDirectory = $RepoRoot
  $proc.StartInfo.UseShellExecute = $false
  $proc.StartInfo.RedirectStandardInput = $true
  $proc.StartInfo.RedirectStandardOutput = $true
  $proc.StartInfo.RedirectStandardError = $true
  $proc.StartInfo.CreateNoWindow = $true

  try {
    [void]$proc.Start()
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()

    try {
      $fileStream.CopyTo($proc.StandardInput.BaseStream)
    } catch {
      $copyError = $_.Exception.Message
    } finally {
      try { $proc.StandardInput.Close() } catch { }
    }

    $proc.WaitForExit()
    $exitCode = [int]$proc.ExitCode

    $stdoutText = ""
    $stderrText = ""
    try { $stdoutText = $stdoutTask.GetAwaiter().GetResult() } catch { $stdoutText = "" }
    try { $stderrText = $stderrTask.GetAwaiter().GetResult() } catch { $stderrText = "" }

    foreach ($text in @($stdoutText, $stderrText)) {
      if ([string]::IsNullOrWhiteSpace($text)) { continue }
      $normalized = $text -replace "`r`n", "`n"
      $normalized = $normalized -replace "`r", "`n"
      foreach ($line in ($normalized -split "`n", 0, "SimpleMatch")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $lines += (Redact-UrlCredentials -Text $line.TrimEnd())
      }
    }
  } finally {
    if ($null -ne $fileStream) { $fileStream.Dispose() }
    try { $proc.Dispose() } catch { }
  }

  if (-not [string]::IsNullOrWhiteSpace($copyError)) {
    $lines += ("stdin copy error: {0}" -f $copyError)
  }

  return [pscustomobject]@{ Code = $exitCode; Lines = @($lines); CopyError = $copyError; OpenFailed = $openFailed }
}

function Repair-TempPackFiles {
  param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$StatePath,
    [Parameter(Mandatory = $true)][string]$Remote,
    [Parameter(Mandatory = $true)][string]$Branch,
    [Parameter(Mandatory = $true)][string]$Policy,
    [string]$RemoteUrl = "",
    [switch]$DryRun = $false,
    [switch]$UsePromisor = $false,
    [Int64]$RecoverMaxBytes = 536870912,
    [switch]$StopBlockingGitProcesses = $false
  )

  if ($Policy -eq "Skip") {
    Write-Log -Kind Skip -Message "TempPackPolicy=Skip，跳过 tmp_pack_* 检查。"
    return
  }
  $deleteOnly = ($Policy -eq "DeleteOnly")

  $packDir = Join-Path $RepoRoot ".git\objects\pack"
  if (-not (Test-Path -LiteralPath $packDir)) {
    Write-Log -Kind Skip -Message "未找到 .git/objects/pack 目录。"
    return
  }

  $files = @(Get-ChildItem -LiteralPath $packDir -Filter "tmp_pack_*" -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime)
  if ($files.Count -eq 0) {
    Write-Log -Kind Ok -Message "未发现 tmp_pack_* 临时垃圾。"
    return
  }

  $totalBytes = [Int64]0
  foreach ($file in @($files)) { $totalBytes += [Int64]$file.Length }
  Write-Log -Kind Warn -Message ("发现 tmp_pack_* {0} 个，合计 {1}。" -f $files.Count, (Format-ByteSize -Bytes $totalBytes))
  if ($deleteOnly) {
    Write-Log -Kind Warn -Message "TempPackPolicy=DeleteOnly，跳过 index-pack 复用检查，直接删除临时 pack。"
  }

  $active = @(Get-ActiveGitPackProcesses -RepoRoot $RepoRoot -RemoteUrl $RemoteUrl)
  if ($active.Count -gt 0) {
    if ($StopBlockingGitProcesses) {
      if ($DryRun) {
        Write-Log -Kind Skip -Message "DryRun：检测到阻塞清理的 Git 传输/pack 进程；真实运行会按 -StopBlockingGitProcesses 终止它们。"
        foreach ($proc in @($active)) {
          Write-Color -Kind Detail -Message ("  pid={0} name={1} cmd={2}" -f $proc.ProcessId, $proc.Name, $proc.CommandLine)
        }
        return
      }

      for ($attempt = 1; $attempt -le 3; $attempt++) {
        $active = @(Get-ActiveGitPackProcesses -RepoRoot $RepoRoot -RemoteUrl $RemoteUrl)
        if ($active.Count -eq 0) { break }

        Write-Log -Kind Warn -Message ("检测到阻塞清理的 Git 传输/pack 进程 {0} 个；StopBlockingGitProcesses 已启用，终止它们。attempt={1}/3" -f $active.Count, $attempt)
        $targets = @($active | Sort-Object CreationDate -Descending)
        foreach ($proc in @($targets)) {
          Write-Color -Kind Detail -Message ("  stop pid={0} name={1} cmd={2}" -f $proc.ProcessId, $proc.Name, $proc.CommandLine)
          try {
            Stop-Process -Id ([int]$proc.ProcessId) -Force -ErrorAction Stop
          } catch {
            Write-Log -Kind Warn -Message ("终止 pid={0} 失败：{1}" -f $proc.ProcessId, $_.Exception.Message)
          }
        }
        Start-Sleep -Seconds 2
      }

      $active = @(Get-ActiveGitPackProcesses -RepoRoot $RepoRoot -RemoteUrl $RemoteUrl)
      if ($active.Count -gt 0) {
        Write-Log -Kind Warn -Message "Git 传输/pack 进程仍在反复出现，停止清理。请先暂停 IDE Git 自动刷新后重跑。"
        foreach ($proc in @($active)) {
          Write-Color -Kind Detail -Message ("  pid={0} name={1} cmd={2}" -f $proc.ProcessId, $proc.Name, $proc.CommandLine)
        }
        throw "存在 Git 传输/pack 进程，请暂停 IDE Git 自动刷新后重跑脚本。"
      }
    } else {
      Write-Log -Kind Warn -Message "检测到当前仓库相关 Git fetch/index-pack 进程，停止清理以避免并发破坏。"
      foreach ($proc in @($active)) {
        Write-Color -Kind Detail -Message ("  pid={0} name={1} cmd={2}" -f $proc.ProcessId, $proc.Name, $proc.CommandLine)
      }
      Write-Log -Kind Warn -Message "如需脚本自动终止这些阻塞进程，请显式追加 -StopBlockingGitProcesses。"
      throw "存在 Git 传输/pack 进程，请等待其结束后重跑脚本。"
    }
  }

  Save-State -Path $StatePath -Data @{
    status = "temp_pack_cleanup"
    remote = $Remote
    branch = $Branch
    tempPackPolicy = $Policy
    tempPackRecoverMaxBytes = $RecoverMaxBytes
    stopBlockingGitProcesses = [bool]$StopBlockingGitProcesses
    tempPackCount = $files.Count
    tempPackBytes = $totalBytes
    updatedAt = (Get-Date).ToString("s")
  }

  if ($DryRun) {
    foreach ($file in @($files)) {
      if ($deleteOnly) {
        Write-Log -Kind Skip -Message ("DryRun：将直接删除 {0} ({1})" -f $file.Name, (Format-ByteSize -Bytes $file.Length))
      } elseif ($RecoverMaxBytes -gt 0 -and [Int64]$file.Length -gt $RecoverMaxBytes) {
        Write-Log -Kind Skip -Message ("DryRun：超过复用检查上限 {0}，将直接删除 {1} ({2})" -f (Format-ByteSize -Bytes $RecoverMaxBytes), $file.Name, (Format-ByteSize -Bytes $file.Length))
      } else {
        Write-Log -Kind Skip -Message ("DryRun：将检查可复用性并按结果导入或删除 {0} ({1})" -f $file.Name, (Format-ByteSize -Bytes $file.Length))
      }
    }
    return
  }

  $recovered = 0
  $deleted = 0
  $cleanedBytes = [Int64]0
  $index = 0
  foreach ($file in @($files)) {
    $index++
    if (-not (Test-Path -LiteralPath $file.FullName)) { continue }

    $relPath = Get-DisplayPath -RepoRoot $RepoRoot -Path $file.FullName
    $fileBytes = [Int64]$file.Length
    Write-Log -Kind Progress -Message ("tmp_pack 检查 {0}/{1}: {2} ({3})" -f $index, $files.Count, $relPath, (Format-ByteSize -Bytes $fileBytes))
    if ($deleteOnly) {
      Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
      $deleted++
      $cleanedBytes += $fileBytes
      Write-Log -Kind Warn -Message ("已直接删除 {0}" -f $file.Name)
      continue
    }

    if ($RecoverMaxBytes -gt 0 -and $fileBytes -gt $RecoverMaxBytes) {
      Write-Log -Kind Warn -Message ("超过复用检查上限 {0}，跳过 index-pack 并删除 {1}" -f (Format-ByteSize -Bytes $RecoverMaxBytes), $file.Name)
      Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
      $deleted++
      $cleanedBytes += $fileBytes
      Write-Log -Kind Warn -Message ("不可复用：已按大小上限删除 {0}" -f $file.Name)
      continue
    }

    $displayIndexArgs = @("index-pack", "--stdin", "--fix-thin")
    if ($UsePromisor) { $displayIndexArgs += "--promisor=staged-pull-temp-pack-recovery" }
    Write-Color -Kind Command -Message ("git -C <repo> {0} < {1}" -f ($displayIndexArgs -join " "), $relPath)
    Write-Log -Kind Detail -Message ("index-pack 复用检查开始：size={0}, recoverMax={1}" -f (Format-ByteSize -Bytes $fileBytes), ($(if ($RecoverMaxBytes -eq 0) { "不限制" } else { Format-ByteSize -Bytes $RecoverMaxBytes })))

    $indexStart = Get-Date
    $result = Invoke-GitIndexPackFromFile -RepoRoot $RepoRoot -PackPath $file.FullName -UsePromisor:$UsePromisor
    $elapsedSeconds = ((Get-Date) - $indexStart).TotalSeconds
    Write-Log -Kind Detail -Message ("index-pack 复用检查结束：exitCode={0}, elapsed={1:n1}s" -f [int]$result.Code, $elapsedSeconds)
    if ($result.OpenFailed) {
      foreach ($line in @($result.Lines)) { Write-Color -Kind Detail -Message $line }
      throw ("无法读取 {0}，停止清理。" -f $relPath)
    }

    if ([int]$result.Code -eq 0) {
      foreach ($line in @($result.Lines)) { Write-Color -Kind Detail -Message $line }
      Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
      $recovered++
      $cleanedBytes += $fileBytes
      Write-Log -Kind Ok -Message ("可复用：已导入对象库并删除原临时文件 {0}" -f $file.Name)
    } else {
      $tail = @($result.Lines | Select-Object -Last 8)
      foreach ($line in @($tail)) { Write-Color -Kind Detail -Message $line }
      Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
      $deleted++
      $cleanedBytes += $fileBytes
      Write-Log -Kind Warn -Message ("不可复用：已删除 {0}" -f $file.Name)
    }
  }

  Write-Log -Kind Ok -Message ("tmp_pack 清理完成：复用导入 {0} 个，直接删除 {1} 个，释放临时文件 {2}。" -f $recovered, $deleted, (Format-ByteSize -Bytes $cleanedBytes))
}

function Get-DisplayPath {
  param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$Path
  )

  try {
    $rootFull = (Resolve-Path -LiteralPath $RepoRoot).Path.TrimEnd("\", "/")
    $full = $Path
    if (Test-Path -LiteralPath $Path) {
      $full = (Resolve-Path -LiteralPath $Path).Path
    } else {
      $parent = Split-Path -Parent $Path
      $leaf = Split-Path -Leaf $Path
      if (-not [string]::IsNullOrWhiteSpace($parent) -and (Test-Path -LiteralPath $parent)) {
        $full = (Join-Path (Resolve-Path -LiteralPath $parent).Path $leaf)
      }
    }

    if ($full.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
      $rel = $full.Substring($rootFull.Length).TrimStart("\", "/")
      if ([string]::IsNullOrWhiteSpace($rel)) { return "." }
      return $rel.Replace("\", "/")
    }
  } catch {
  }

  return $Path
}

function Restore-AutoStash {
  param([Parameter(Mandatory = $true)][string]$RepoRoot)

  if (-not $script:AutoStashCreated) { return }

  Write-Log -Kind Progress -Message "恢复 AutoStash。"
  Invoke-Git -Args @("-C", $RepoRoot, "stash", "pop") | Out-Null
  $script:AutoStashCreated = $false
  $script:AutoStashMessage = ""
}

function Repair-WorktreeObstacle {
  param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][object]$StatusResult,
    [object]$PreviousState = $null,
    [switch]$DryRun = $false,
    [switch]$NoAutoRestoreWorktree = $false
  )

  $statusLines = @($StatusResult.Lines)
  if ($statusLines.Count -eq 0) { return $StatusResult }

  if ($NoAutoRestoreWorktree) {
    Write-Log -Kind Skip -Message "NoAutoRestoreWorktree 已启用，跳过工作区自动 restore。"
    return $StatusResult
  }

  $staged = @()
  $unstaged = @()
  $untracked = @()
  foreach ($line in @($statusLines)) {
    if ([string]::IsNullOrWhiteSpace($line) -or $line.Length -lt 2) { continue }
    $xy = $line.Substring(0, 2)
    if ($xy -eq "??") {
      $untracked += $line
      continue
    }
    if ($xy -eq "!!") { continue }
    if ($line.Substring(0, 1) -ne " ") { $staged += $line }
    if ($line.Substring(1, 1) -ne " ") { $unstaged += $line }
  }

  if ($unstaged.Count -eq 0) { return $StatusResult }
  if ($staged.Count -gt 0 -or $untracked.Count -gt 0) {
    Write-Log -Kind Warn -Message ("工作区含 staged 或 untracked 内容，跳过自动 restore。staged={0}, untracked={1}, unstaged={2}" -f $staged.Count, $untracked.Count, $unstaged.Count)
    return $StatusResult
  }

  $stateStatus = ""
  $headBeforeMerge = ""
  if ($null -ne $PreviousState) {
    if ($PreviousState.PSObject.Properties.Name -contains "status") { $stateStatus = [string]$PreviousState.status }
    if ($PreviousState.PSObject.Properties.Name -contains "headBeforeMerge") { $headBeforeMerge = [string]$PreviousState.headBeforeMerge }
  }
  if ($stateStatus -ne "batch_merge") {
    Write-Log -Kind Warn -Message ("当前工作区有未暂存改动，但上次状态不是 batch_merge，跳过自动 restore。status={0}" -f $(if ([string]::IsNullOrWhiteSpace($stateStatus)) { "<none>" } else { $stateStatus }))
    return $StatusResult
  }

  if (-not [string]::IsNullOrWhiteSpace($headBeforeMerge)) {
    $currentHead = Get-OneLine -GitArgs @("-C", $RepoRoot, "rev-parse", "HEAD")
    if ($currentHead -ne $headBeforeMerge) {
      Write-Log -Kind Warn -Message ("HEAD 与上次 batch_merge 前记录不一致，跳过自动 restore。HEAD={0}, expected={1}" -f (Short-Sha $currentHead), (Short-Sha $headBeforeMerge))
      return $StatusResult
    }
  }

  Write-Log -Kind Warn -Message ("检测到上次 batch_merge 中断留下的未暂存工作区残留 {0} 项，执行 git restore --worktree . 修复。" -f $unstaged.Count)
  foreach ($line in @($statusLines | Select-Object -First 20)) {
    Write-Color -Kind Detail -Message ("  " + $line)
  }
  if ($statusLines.Count -gt 20) {
    Write-Color -Kind Detail -Message ("  ... 其余 {0} 项省略" -f ($statusLines.Count - 20))
  }

  if ($DryRun) {
    Write-Log -Kind Skip -Message "DryRun：跳过 git -C <repo> restore --worktree ."
    return $StatusResult
  }

  Invoke-Git -Args @("-C", $RepoRoot, "restore", "--worktree", ".") | Out-Null
  $after = Invoke-GitCapture -Args @("-C", $RepoRoot, "status", "--porcelain") -Quiet
  if ($after.Code -ne 0) { throw ("git status failed with exit code {0}" -f $after.Code) }
  if ($after.Lines.Count -eq 0) {
    Write-Log -Kind Ok -Message "工作区自动 restore 完成，当前工作区干净。"
  } else {
    Write-Log -Kind Warn -Message ("自动 restore 后工作区仍有 {0} 项变更。" -f $after.Lines.Count)
  }
  return $after
}

$repoRoot = Resolve-RepoRoot
Push-Location $repoRoot
try {
  Write-Color -Kind Banner -Message "=== Staged Git Pull / 分阶段 Pull ==="

  Write-Phase -Index 1 -Total 6 -Title "环境检查"
  if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "git not found in PATH."
  }

  $inside = Invoke-GitCapture -Args @("-C", $repoRoot, "rev-parse", "--is-inside-work-tree")
  $insideText = ($inside.Lines -join "`n").Trim()
  if ($inside.Code -ne 0 -and $insideText -match "(?i)dubious ownership|safe\.directory") {
    $safePath = To-GitPath -Path $repoRoot
    Write-Log -Kind Warn -Message ("检测到 safe.directory 限制，写入 Git 全局可信目录：{0}" -f $safePath)
    Invoke-Git -Args @("config", "--global", "--add", "safe.directory", $safePath) | Out-Null
    $inside = Invoke-GitCapture -Args @("-C", $repoRoot, "rev-parse", "--is-inside-work-tree")
    $insideText = ($inside.Lines -join "`n").Trim()
  }
  if ($inside.Code -ne 0) {
    if ([string]::IsNullOrWhiteSpace($insideText)) { throw "当前目录不在 Git 工作树内。" }
    throw ("当前目录不在 Git 工作树内。`n{0}" -f $insideText)
  }

  $remoteToUse = ([string]$Remote).Trim()
  if ([string]::IsNullOrWhiteSpace($remoteToUse)) { $remoteToUse = "origin" }

  $currentBranch = Get-OneLine -GitArgs @("-C", $repoRoot, "rev-parse", "--abbrev-ref", "HEAD")
  if ([string]::IsNullOrWhiteSpace($currentBranch) -or $currentBranch -eq "HEAD") {
    throw "当前处于 Detached HEAD；请先 checkout 到需要更新的分支。"
  }

  $targetBranch = ([string]$Branch).Trim()
  if ([string]::IsNullOrWhiteSpace($targetBranch)) { $targetBranch = $currentBranch }

  $outDir = Join-Path $repoRoot "out"
  if ([string]::IsNullOrWhiteSpace($StateFile)) {
    $statePath = Join-Path $outDir "staged_pull_state.json"
  } else {
    $statePath = $StateFile
    if (-not [System.IO.Path]::IsPathRooted($statePath)) {
      $statePath = Join-Path $repoRoot $statePath
    }
  }

  $fetchFilterToUse = Get-FetchFilterSpec -Filter $FetchFilter
  $batchObjectFetchEnabled = (-not $NoBatchObjectFetch)
  $fetchFilterDisplay = $fetchFilterToUse
  if ([string]::IsNullOrWhiteSpace($fetchFilterDisplay)) { $fetchFilterDisplay = "<full>" }

  Write-Log -Kind Detail -Message ("remote={0}, branch={1}, batchSize={2}, fetchDeepenStep={3}, fetchDeepenRounds={4}, fetchFilter={5}, batchObjectFetch={6}, tempPackPolicy={7}, tempPackRecoverMaxBytes={8}, autoRestoreWorktree={9}, stopBlockingGitProcesses={10}, fetchTags={11}" -f $remoteToUse, $targetBranch, $BatchSize, $FetchDeepenStep, $FetchDeepenRounds, $fetchFilterDisplay, [bool]$batchObjectFetchEnabled, $TempPackPolicy, $TempPackRecoverMaxBytes, (-not [bool]$NoAutoRestoreWorktree), [bool]$StopBlockingGitProcesses, [bool]$FetchTags)
  Write-Log -Kind Detail -Message ("stateFile={0}" -f (Get-DisplayPath -RepoRoot $repoRoot -Path $statePath))

  $previousState = Read-State -Path $statePath
  if ($null -ne $previousState) {
    $stateSummary = @()
    foreach ($name in @("status", "remote", "branch", "completedCommits", "totalCommits", "lastCompletedCommit", "updatedAt")) {
      if ($previousState.PSObject.Properties.Name -contains $name) {
        $stateSummary += ("{0}={1}" -f $name, $previousState.$name)
      }
    }
    if ($stateSummary.Count -gt 0) {
      Write-Log -Kind Resume -Message ("发现上次状态：{0}" -f ($stateSummary -join ", "))
    }
    if (($previousState.PSObject.Properties.Name -contains "autoStashCreated") -and
        $previousState.autoStashCreated -and
        (($previousState.PSObject.Properties.Name -notcontains "status") -or $previousState.status -ne "completed")) {
      Write-Log -Kind Warn -Message "上次运行记录了未完成的 AutoStash；继续前请确认 git stash list 中是否有需要恢复的内容。"
    }
  }

  Write-Phase -Index 2 -Total 6 -Title "工作区保护"
  $status = Invoke-GitCapture -Args @("-C", $repoRoot, "status", "--porcelain") -Quiet
  if ($status.Code -ne 0) { throw ("git status failed with exit code {0}" -f $status.Code) }
  if ($status.Lines.Count -gt 0) {
    $status = Repair-WorktreeObstacle -RepoRoot $repoRoot -StatusResult $status -PreviousState $previousState -DryRun:$DryRun -NoAutoRestoreWorktree:$NoAutoRestoreWorktree
  }
  if ($status.Lines.Count -gt 0) {
    if (-not $AutoStash) {
      Write-Log -Kind Warn -Message "工作区存在未提交改动。请先提交/清理，或显式追加 -AutoStash。"
      foreach ($line in @($status.Lines)) { Write-Color -Kind Detail -Message ("  " + $line) }
      throw "工作区不干净，停止分阶段 pull。"
    }

    $script:AutoStashMessage = "staged-pull auto-stash " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    Write-Log -Kind Warn -Message "工作区存在未提交改动，已启用 AutoStash。"
    Invoke-Git -Args @("-C", $repoRoot, "stash", "push", "-u", "-m", $script:AutoStashMessage) | Out-Null
    $script:AutoStashCreated = $true
  } else {
    Write-Log -Kind Ok -Message "工作区干净。"
  }

  Write-Phase -Index 3 -Total 6 -Title "远端同步"
  $remoteRef = "$remoteToUse/$targetBranch"
  $remoteTrackingRef = "refs/remotes/{0}/{1}" -f $remoteToUse, $targetBranch
  $fetchRefSpec = "+refs/heads/{0}:{1}" -f $targetBranch, $remoteTrackingRef
  $remoteTipFromFetch = ""
  $fetchSubStepTotal = 8
  if ($FetchTags) { $fetchSubStepTotal = 9 }
  $fetchSubStep = 1

  Save-State -Path $statePath -Data @{
    status = "fetch_probe"
    remote = $remoteToUse
    branch = $targetBranch
    batchSize = $BatchSize
    fetchDeepenStep = $FetchDeepenStep
    fetchDeepenRounds = $FetchDeepenRounds
    fetchFilter = $fetchFilterToUse
    batchObjectFetch = $batchObjectFetchEnabled
    tempPackPolicy = $TempPackPolicy
    tempPackRecoverMaxBytes = $TempPackRecoverMaxBytes
    autoRestoreWorktree = (-not [bool]$NoAutoRestoreWorktree)
    stopBlockingGitProcesses = [bool]$StopBlockingGitProcesses
    startedAt = (Get-Date).ToString("s")
    updatedAt = (Get-Date).ToString("s")
  }

  Write-SubStep -Index $fetchSubStep -Total $fetchSubStepTotal -Title "读取远端地址与同步参数"
  $fetchSubStep++
  $remoteUrl = Get-OneLine -GitArgs @("-C", $repoRoot, "remote", "get-url", $remoteToUse)
  if ([string]::IsNullOrWhiteSpace($remoteUrl)) {
    throw ("找不到远端 {0}。" -f $remoteToUse)
  }
  $remoteUrl = Redact-UrlCredentials -Text $remoteUrl
  $isShallowText = Get-OneLine -GitArgs @("-C", $repoRoot, "rev-parse", "--is-shallow-repository")
  $isShallowRepo = ($isShallowText -eq "true")
  Write-Log -Kind Detail -Message ("remoteUrl={0}" -f $remoteUrl)
  Write-Log -Kind Detail -Message ("fetchRefSpec={0}" -f $fetchRefSpec)
  Write-Log -Kind Detail -Message ("isShallowRepository={0}, fetchDeepenStep={1}, fetchDeepenRounds={2}, fetchFilter={3}, fetchTags={4}" -f $isShallowText, $FetchDeepenStep, $FetchDeepenRounds, $fetchFilterDisplay, [bool]$FetchTags)
  Write-Log -Kind Resume -Message "续跑粒度为 Git 对象与提交批次；网络中断后重跑会复用已成功入库的对象与已快进的 HEAD。"
  if (-not [string]::IsNullOrWhiteSpace($fetchFilterToUse)) {
    if ($DryRun) {
      Write-Log -Kind Skip -Message ("DryRun：计划配置 remote.{0}.promisor=true 和 partialclonefilter={1}" -f $remoteToUse, $fetchFilterToUse)
    } else {
      Enable-PartialFetchRemote -RepoRoot $repoRoot -Remote $remoteToUse -Filter $fetchFilterToUse
    }
  } else {
    Write-Log -Kind Warn -Message "FetchFilter 为空，本次使用完整对象 fetch。"
  }

  Write-SubStep -Index $fetchSubStep -Total $fetchSubStepTotal -Title "检查并处理临时 pack 垃圾"
  $fetchSubStep++
  Repair-TempPackFiles -RepoRoot $repoRoot -StatePath $statePath -Remote $remoteToUse -Branch $targetBranch -Policy $TempPackPolicy -RemoteUrl $remoteUrl -DryRun:$DryRun -UsePromisor:(-not [string]::IsNullOrWhiteSpace($fetchFilterToUse)) -RecoverMaxBytes $TempPackRecoverMaxBytes -StopBlockingGitProcesses:$StopBlockingGitProcesses

  Write-SubStep -Index $fetchSubStep -Total $fetchSubStepTotal -Title "读取本地远端跟踪引用"
  $fetchSubStep++
  $localRemoteTipBefore = Get-OneLine -GitArgs @("-C", $repoRoot, "rev-parse", "--verify", $remoteRef)
  if ([string]::IsNullOrWhiteSpace($localRemoteTipBefore)) {
    Write-Log -Kind Warn -Message ("本地尚无远端跟踪引用 {0}。" -f $remoteRef)
  } else {
    Write-Log -Kind Detail -Message ("localRemoteTipBefore={0}" -f (Short-Sha $localRemoteTipBefore))
  }

  Write-SubStep -Index $fetchSubStep -Total $fetchSubStepTotal -Title "探测远端分支目标提交"
  $fetchSubStep++
  $remoteBranchTip = Get-RemoteBranchTip -RepoRoot $repoRoot -Remote $remoteToUse -Branch $targetBranch
  if ([string]::IsNullOrWhiteSpace($remoteBranchTip)) {
    throw ("远端 {0} 不存在分支 {1}。" -f $remoteToUse, $targetBranch)
  }
  Write-Log -Kind Detail -Message ("remoteBranchTip={0}" -f (Short-Sha $remoteBranchTip))

  Write-SubStep -Index $fetchSubStep -Total $fetchSubStepTotal -Title "按需清理远端失效引用"
  $fetchSubStep++
  if ($Prune) {
    Save-State -Path $statePath -Data @{
      status = "fetch_prune"
      remote = $remoteToUse
      branch = $targetBranch
      remoteBranchTip = $remoteBranchTip
      fetchFilter = $fetchFilterToUse
      updatedAt = (Get-Date).ToString("s")
    }
    if ($DryRun) {
      Write-Log -Kind Skip -Message ("DryRun：跳过 git -C <repo> remote prune {0}" -f $remoteToUse)
    } else {
      Invoke-Git -Args @("-C", $repoRoot, "remote", "prune", $remoteToUse) | Out-Null
    }
  } else {
    Write-Log -Kind Skip -Message "未指定 -Prune，跳过远端失效引用清理。"
  }

  Write-SubStep -Index $fetchSubStep -Total $fetchSubStepTotal -Title "检查目标提交是否已在本地对象库"
  $fetchSubStep++
  $remoteTipObjectExists = Test-GitCommitExists -RepoRoot $repoRoot -Commit $remoteBranchTip
  if ($remoteTipObjectExists) {
    Write-Log -Kind Ok -Message ("目标提交对象已存在：{0}" -f (Short-Sha $remoteBranchTip))
  } else {
    Write-Log -Kind Progress -Message ("目标提交对象尚未下载：{0}" -f (Short-Sha $remoteBranchTip))
  }

  Write-SubStep -Index $fetchSubStep -Total $fetchSubStepTotal -Title "同步分支对象与远端跟踪引用"
  $fetchSubStep++
  $branchFetchNeeded = $true
  if ($localRemoteTipBefore -eq $remoteBranchTip -and $remoteTipObjectExists) {
    $branchFetchNeeded = $false
  }

  if (-not $branchFetchNeeded) {
    Write-Log -Kind Skip -Message ("{0} 已指向远端目标提交，跳过分支 fetch。" -f $remoteRef)
  } elseif ($DryRun) {
    $plannedArgs = Get-BranchFetchArgs -RepoRoot "<repo>" -Remote $remoteToUse -RefSpec $fetchRefSpec -Filter $fetchFilterToUse
    Write-Log -Kind Skip -Message ("DryRun：跳过 git {0}" -f ($plannedArgs -join " "))
  } else {
    Save-State -Path $statePath -Data @{
      status = "fetch_branch"
      remote = $remoteToUse
      branch = $targetBranch
      remoteBranchTip = $remoteBranchTip
      localRemoteTipBefore = $localRemoteTipBefore
      fetchFilter = $fetchFilterToUse
      updatedAt = (Get-Date).ToString("s")
    }

    $fetchSatisfied = $false
    if ($isShallowRepo -and $FetchDeepenRounds -gt 0) {
      for ($round = 1; $round -le $FetchDeepenRounds; $round++) {
        Write-Log -Kind Progress -Message ("shallow deepen round {0}/{1}，每轮加深 {2} 个提交。" -f $round, $FetchDeepenRounds, $FetchDeepenStep)
        Save-State -Path $statePath -Data @{
          status = "fetch_deepen"
          remote = $remoteToUse
          branch = $targetBranch
          remoteBranchTip = $remoteBranchTip
          deepenRound = $round
          deepenRounds = $FetchDeepenRounds
          deepenStep = $FetchDeepenStep
          fetchFilter = $fetchFilterToUse
          updatedAt = (Get-Date).ToString("s")
        }
        $deepenFetchArgs = Get-BranchFetchArgs -RepoRoot $repoRoot -Remote $remoteToUse -RefSpec $fetchRefSpec -Filter $fetchFilterToUse -DepthArg ("--deepen={0}" -f $FetchDeepenStep)
        Invoke-GitStreaming -Args $deepenFetchArgs | Out-Null

        $tipNow = Get-OneLine -GitArgs @("-C", $repoRoot, "rev-parse", "--verify", $remoteRef)
        $aheadNow = Get-RevCountText -RepoRoot $repoRoot -RevisionRange ("HEAD..{0}" -f $remoteRef)
        Write-Log -Kind Detail -Message ("deepen round {0}: {1}={2}, ahead={3}" -f $round, $remoteRef, (Short-Sha $tipNow), $aheadNow)

        if ($tipNow -eq $remoteBranchTip) {
          if (Test-GitAncestor -RepoRoot $repoRoot -Ancestor "HEAD" -Descendant $remoteRef) {
            $fetchSatisfied = $true
            Write-Log -Kind Ok -Message "shallow deepen 已取得可 fast-forward 判定所需历史。"
            break
          }
          Write-Log -Kind Warn -Message "目标提交已到达，但共同祖先信息仍不足，继续加深。"
        }
      }
    }

    if (-not $fetchSatisfied) {
      $isStillShallowText = Get-OneLine -GitArgs @("-C", $repoRoot, "rev-parse", "--is-shallow-repository")
      $useUnshallow = ($isStillShallowText -eq "true" -and $isShallowRepo)
      $branchFetchArgs = Get-BranchFetchArgs -RepoRoot $repoRoot -Remote $remoteToUse -RefSpec $fetchRefSpec -Filter $fetchFilterToUse -Unshallow:$useUnshallow
      if ([string]::IsNullOrWhiteSpace($fetchFilterToUse)) {
        Write-Log -Kind Progress -Message "执行分支完整对象 fetch 兜底。"
      } else {
        Write-Log -Kind Progress -Message ("执行分支轻量 fetch 兜底：--filter={0}" -f $fetchFilterToUse)
      }
      Invoke-GitStreaming -Args $branchFetchArgs | Out-Null
    }
  }

  if ($FetchTags) {
    Write-SubStep -Index $fetchSubStep -Total $fetchSubStepTotal -Title "同步标签"
    $fetchSubStep++
    Save-State -Path $statePath -Data @{
      status = "fetch_tags"
      remote = $remoteToUse
      branch = $targetBranch
      remoteBranchTip = $remoteBranchTip
      fetchFilter = $fetchFilterToUse
      updatedAt = (Get-Date).ToString("s")
    }
    if ($DryRun) {
      Write-Log -Kind Skip -Message ("DryRun：跳过 git -C <repo> fetch --tags --progress {0}" -f $remoteToUse)
    } else {
      Invoke-GitStreaming -Args @("-C", $repoRoot, "fetch", "--tags", "--progress", $remoteToUse) | Out-Null
    }
  } else {
    Write-Log -Kind Skip -Message "未指定 -FetchTags，跳过标签同步。"
  }

  Write-SubStep -Index $fetchSubStep -Total $fetchSubStepTotal -Title "校验远端跟踪引用"
  $remoteTipAfterFetch = Get-OneLine -GitArgs @("-C", $repoRoot, "rev-parse", "--verify", $remoteRef)
  if ($DryRun) {
    $remoteTipFromFetch = $remoteBranchTip
    Write-Log -Kind Skip -Message ("DryRun：预计 {0} 将更新到 {1}。" -f $remoteRef, (Short-Sha $remoteBranchTip))
  } else {
    if ($remoteTipAfterFetch -ne $remoteBranchTip) {
      throw ("远端跟踪引用校验失败：{0}={1}, remoteBranchTip={2}" -f $remoteRef, (Short-Sha $remoteTipAfterFetch), (Short-Sha $remoteBranchTip))
    }
    $remoteTipFromFetch = $remoteTipAfterFetch
    Write-Log -Kind Ok -Message ("{0} 已同步到 {1}。" -f $remoteRef, (Short-Sha $remoteTipFromFetch))
  }

  if ($targetBranch -ne $currentBranch) {
    Write-Log -Kind Progress -Message ("切换分支：{0} -> {1}" -f $currentBranch, $targetBranch)
    if (-not $DryRun) {
      $checkout = Invoke-GitCapture -Args @("-C", $repoRoot, "checkout", $targetBranch)
      foreach ($line in @($checkout.Lines)) { Write-Color -Kind Detail -Message $line }
      if ($checkout.Code -ne 0) {
        Write-Log -Kind Warn -Message ("本地分支不存在，尝试从 {0}/{1} 创建跟踪分支。" -f $remoteToUse, $targetBranch)
        Invoke-Git -Args @("-C", $repoRoot, "checkout", "-b", $targetBranch, "--track", "$remoteToUse/$targetBranch") | Out-Null
      }
    }
  }

  Write-Phase -Index 4 -Total 6 -Title "分析待合入提交"
  if ([string]::IsNullOrWhiteSpace($remoteRef)) {
    $remoteRef = "$remoteToUse/$targetBranch"
  }
  $remoteTip = $remoteTipFromFetch
  if ([string]::IsNullOrWhiteSpace($remoteTip)) {
    $remoteTip = Get-OneLine -GitArgs @("-C", $repoRoot, "rev-parse", "--verify", $remoteRef)
  }
  if ([string]::IsNullOrWhiteSpace($remoteTip) -and $DryRun) {
    $remoteTip = "<dry-run-remote-tip>"
  }
  if ([string]::IsNullOrWhiteSpace($remoteTip)) {
    throw ("找不到远端引用 {0}。请确认远端和分支名称正确。" -f $remoteRef)
  }

  $headBefore = Get-OneLine -GitArgs @("-C", $repoRoot, "rev-parse", "HEAD")
  if ([string]::IsNullOrWhiteSpace($headBefore)) {
    throw "无法读取当前 HEAD。"
  }

  Write-Log -Kind Detail -Message ("HEAD={0}, remoteTip={1}" -f (Short-Sha $headBefore), (Short-Sha $remoteTip))
  if ($headBefore -eq $remoteTip) {
    Write-Log -Kind Ok -Message ("当前分支已经等于 {0}。" -f $remoteRef)
    Save-State -Path $statePath -Data @{
      status = "completed"
      remote = $remoteToUse
      branch = $targetBranch
      batchSize = $BatchSize
      totalCommits = 0
      completedCommits = 0
      remoteTip = $remoteTip
      fetchFilter = $fetchFilterToUse
      batchObjectFetch = $batchObjectFetchEnabled
      updatedAt = (Get-Date).ToString("s")
    }
    Restore-AutoStash -RepoRoot $repoRoot
    return
  }

  $analysisTarget = $remoteTip
  $remoteTipObjectAvailable = Test-GitCommitExists -RepoRoot $repoRoot -Commit $remoteTip
  if ($DryRun -and -not $remoteTipObjectAvailable) {
    Write-Log -Kind Warn -Message ("DryRun 未下载目标提交对象，无法枚举 HEAD..{0} 的具体提交。" -f (Short-Sha $remoteTip))
    Write-Log -Kind Progress -Message "去掉 -DryRun 后，Phase 3 会先轻量下载提交/树对象，Phase 5 再按批次补齐对象并快进。"
    Save-State -Path $statePath -Data @{
      status = "dryrun_fetch_needed"
      remote = $remoteToUse
      branch = $targetBranch
      batchSize = $BatchSize
      remoteTip = $remoteTip
      fetchFilter = $fetchFilterToUse
      batchObjectFetch = $batchObjectFetchEnabled
      updatedAt = (Get-Date).ToString("s")
    }
    Restore-AutoStash -RepoRoot $repoRoot
    return
  }

  if (-not $DryRun) {
    $headIsAncestor = Invoke-Git -Args @("-C", $repoRoot, "merge-base", "--is-ancestor", "HEAD", $analysisTarget) -AllowFailure
    if ($headIsAncestor -ne 0) {
      $remoteIsAncestor = Invoke-Git -Args @("-C", $repoRoot, "merge-base", "--is-ancestor", $analysisTarget, "HEAD") -AllowFailure
      if ($remoteIsAncestor -eq 0) {
        Write-Log -Kind Ok -Message ("本地 HEAD 已包含 {0}，没有远端提交需要合入。" -f $remoteRef)
        Restore-AutoStash -RepoRoot $repoRoot
        return
      }

      Write-Log -Kind Error -Message "本地分支与远端分支存在分叉，脚本不会自动创建 merge commit 或 rebase。"
      Write-Log -Kind Warn -Message "请先人工处理分叉；处理完成后再次运行本脚本即可继续。"
      throw "无法 fast-forward。"
    }
  }

  $revList = Invoke-GitCapture -Args @("-C", $repoRoot, "rev-list", "--reverse", "HEAD..$analysisTarget") -Quiet
  if ($revList.Code -ne 0) {
    throw ("git rev-list failed with exit code {0}" -f $revList.Code)
  }

  $commits = @()
  foreach ($line in @($revList.Lines)) {
    if (-not [string]::IsNullOrWhiteSpace($line)) { $commits += ([string]$line).Trim() }
  }

  $totalCommits = $commits.Count
  if ($totalCommits -eq 0) {
    Write-Log -Kind Ok -Message "没有待合入提交。"
    Restore-AutoStash -RepoRoot $repoRoot
    return
  }

  $totalBatches = [int][Math]::Ceiling([double]$totalCommits / [double]$BatchSize)
  Write-Log -Kind Progress -Message ("待合入提交 {0} 个，按每批 {1} 个拆为 {2} 批。" -f $totalCommits, $BatchSize, $totalBatches)

  Write-Phase -Index 5 -Total 6 -Title "分块快进"
  $completed = 0
  for ($offset = 0; $offset -lt $totalCommits; $offset += $BatchSize) {
    $batchIndex = [int][Math]::Floor([double]$offset / [double]$BatchSize) + 1
    $endIndex = [Math]::Min($offset + $BatchSize - 1, $totalCommits - 1)
    $batchCount = $endIndex - $offset + 1
    $targetCommit = $commits[$endIndex]
    $firstCommit = $commits[$offset]
    $subject = Get-CommitSubject -RepoRoot $repoRoot -Commit $targetCommit
    $completedAfterBatch = $endIndex + 1

    Write-Log -Kind Progress -Message ("批次 {0}/{1}：提交 {2}-{3} / {4}，目标 {5}" -f $batchIndex, $totalBatches, ($offset + 1), ($endIndex + 1), $totalCommits, (Short-Sha $targetCommit))
    if (-not [string]::IsNullOrWhiteSpace($subject)) {
      Write-Color -Kind Detail -Message ("  target subject: " + $subject)
    }

    Save-State -Path $statePath -Data @{
      status = "batch_running"
      remote = $remoteToUse
      branch = $targetBranch
      batchSize = $BatchSize
      batchIndex = $batchIndex
      totalBatches = $totalBatches
      totalCommits = $totalCommits
      completedCommits = $completed
      batchFirstCommit = $firstCommit
      batchTargetCommit = $targetCommit
      remoteTip = $remoteTip
      fetchFilter = $fetchFilterToUse
      batchObjectFetch = $batchObjectFetchEnabled
      updatedAt = (Get-Date).ToString("s")
    }

    if ($DryRun) {
      if ($batchObjectFetchEnabled -and -not [string]::IsNullOrWhiteSpace($fetchFilterToUse)) {
        $objectFetchPlan = Get-ObjectFetchArgs -RepoRoot "<repo>" -Remote $remoteToUse -Commit $targetCommit
        Write-Log -Kind Skip -Message ("DryRun：跳过批次对象补齐 git {0}" -f ($objectFetchPlan -join " "))
      }
      Write-Log -Kind Skip -Message ("DryRun：跳过 git merge --ff-only {0}，本批 {1} 个提交。" -f (Short-Sha $targetCommit), $batchCount)
    } else {
      if ($batchObjectFetchEnabled -and -not [string]::IsNullOrWhiteSpace($fetchFilterToUse)) {
        Save-State -Path $statePath -Data @{
          status = "batch_object_fetch"
          remote = $remoteToUse
          branch = $targetBranch
          batchSize = $BatchSize
          batchIndex = $batchIndex
          totalBatches = $totalBatches
          totalCommits = $totalCommits
          completedCommits = $completed
          batchFirstCommit = $firstCommit
          batchTargetCommit = $targetCommit
          remoteTip = $remoteTip
          fetchFilter = $fetchFilterToUse
          batchObjectFetch = $batchObjectFetchEnabled
          updatedAt = (Get-Date).ToString("s")
        }

        Write-Log -Kind Progress -Message ("批次 {0}/{1}：补齐目标提交对象 {2}" -f $batchIndex, $totalBatches, (Short-Sha $targetCommit))
        $objectFetchArgs = Get-ObjectFetchArgs -RepoRoot $repoRoot -Remote $remoteToUse -Commit $targetCommit
        Invoke-GitStreaming -Args $objectFetchArgs | Out-Null
        Write-Log -Kind Ok -Message ("批次 {0}/{1}：目标提交对象补齐步骤完成。" -f $batchIndex, $totalBatches)
      } elseif (-not $batchObjectFetchEnabled) {
        Write-Log -Kind Skip -Message "已指定 -NoBatchObjectFetch，跳过批次对象补齐。"
      } else {
        Write-Log -Kind Skip -Message "FetchFilter 为空，分支 fetch 已按完整对象策略执行，跳过批次对象补齐。"
      }

      $headBeforeMerge = Get-OneLine -GitArgs @("-C", $repoRoot, "rev-parse", "HEAD")
      Save-State -Path $statePath -Data @{
        status = "batch_merge"
        remote = $remoteToUse
        branch = $targetBranch
        batchSize = $BatchSize
        batchIndex = $batchIndex
        totalBatches = $totalBatches
        totalCommits = $totalCommits
        completedCommits = $completed
        batchFirstCommit = $firstCommit
        batchTargetCommit = $targetCommit
        headBeforeMerge = $headBeforeMerge
        remoteTip = $remoteTip
        fetchFilter = $fetchFilterToUse
        batchObjectFetch = $batchObjectFetchEnabled
        updatedAt = (Get-Date).ToString("s")
      }

      Write-Log -Kind Progress -Message ("批次 {0}/{1}：开始 fast-forward merge，HEAD {2} -> {3}" -f $batchIndex, $totalBatches, (Short-Sha $headBeforeMerge), (Short-Sha $targetCommit))
      Write-Log -Kind Detail -Message "如果 Git 触发 partial clone lazy fetch，下面会直接打印 merge/fetch/index-pack 输出。"
      Invoke-GitStreaming -Args @("-C", $repoRoot, "merge", "--ff-only", $targetCommit) | Out-Null
      $headNow = Get-OneLine -GitArgs @("-C", $repoRoot, "rev-parse", "HEAD")
      if ($headNow -ne $targetCommit) {
        throw ("批次 {0} 后 HEAD 校验失败：HEAD={1}, target={2}" -f $batchIndex, (Short-Sha $headNow), (Short-Sha $targetCommit))
      }
      Write-Log -Kind Ok -Message ("批次 {0}/{1}：merge 完成，HEAD={2}，累计完成 {3}/{4} 个提交。" -f $batchIndex, $totalBatches, (Short-Sha $headNow), $completedAfterBatch, $totalCommits)
    }

    $completed = $completedAfterBatch
    Save-State -Path $statePath -Data @{
      status = "batch_completed"
      remote = $remoteToUse
      branch = $targetBranch
      batchSize = $BatchSize
      batchIndex = $batchIndex
      totalBatches = $totalBatches
      totalCommits = $totalCommits
      completedCommits = $completed
      lastCompletedCommit = $targetCommit
      remoteTip = $remoteTip
      fetchFilter = $fetchFilterToUse
      batchObjectFetch = $batchObjectFetchEnabled
      updatedAt = (Get-Date).ToString("s")
    }
  }

  Write-Phase -Index 6 -Total 6 -Title "收尾校验"
  if (-not $DryRun) {
    $headFinal = Get-OneLine -GitArgs @("-C", $repoRoot, "rev-parse", "HEAD")
    if ($headFinal -ne $remoteTip) {
      throw ("收尾校验失败：HEAD={0}, remoteTip={1}" -f (Short-Sha $headFinal), (Short-Sha $remoteTip))
    }
  }

  Restore-AutoStash -RepoRoot $repoRoot

  Save-State -Path $statePath -Data @{
    status = "completed"
    remote = $remoteToUse
    branch = $targetBranch
    batchSize = $BatchSize
    totalBatches = $totalBatches
    totalCommits = $totalCommits
    completedCommits = $totalCommits
    remoteTip = $remoteTip
    fetchFilter = $fetchFilterToUse
    batchObjectFetch = $batchObjectFetchEnabled
    updatedAt = (Get-Date).ToString("s")
  }

  if ($DryRun) {
    Write-Log -Kind Ok -Message "DryRun 完成；仓库没有被修改。"
  } else {
    Write-Log -Kind Ok -Message ("分阶段 pull 完成：{0} 个提交，{1} 批。" -f $totalCommits, $totalBatches)
  }
} catch {
  Write-Log -Kind Error -Message $_.Exception.Message
  if ($script:AutoStashCreated) {
    Write-Log -Kind Warn -Message ("AutoStash 已创建但未恢复，stash message: {0}" -f $script:AutoStashMessage)
    Write-Log -Kind Warn -Message "请在处理失败原因后检查 git stash list，并按需执行 git stash pop。"
  }
  exit 1
} finally {
  Pop-Location
}
