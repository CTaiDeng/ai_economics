<#
  按文件批量提交，并默认把远端缺失提交从旧到新逐个 fast-forward 推送。
  若 push 中途失败，可重跑本脚本继续推送尚未到达远端的提交。

  示例：
    .\scripts\commit_initial_batches.ps1
    .\scripts\commit_initial_batches.ps1 -BatchSize 20
    .\scripts\commit_initial_batches.ps1 -MaxPushBatchMB 90
    .\scripts\commit_initial_batches.ps1 -NoPush
    .\scripts\commit_initial_batches.ps1 -PushRetryCount 5 -PushRetryDelaySeconds 30
#>

param(
    [int]$BatchSize = 100,
    [ValidateRange(1, 102400)]
    [int]$MaxPushBatchMB = 90,
    [string]$Message = "initial",
    [switch]$DryRun,
    [switch]$NoVerify,
    [switch]$NoAutoAttributes,
    [Alias("Push")]
    [switch]$PushEachCommit,
    [switch]$NoPush,
    [string]$PushRemote = "",
    [string]$PushBranch = "",
    [ValidateRange(1, 20)]
    [int]$PushRetryCount = 3,
    [ValidateRange(0, 600)]
    [int]$PushRetryDelaySeconds = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom

if ($BatchSize -le 0) {
    throw "BatchSize must be greater than 0."
}

$maxPushBatchBytes = [int64]$MaxPushBatchMB * 1000 * 1000
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

function Invoke-Git {
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
        [string[]]$Arguments
    )

    & git -C $repoRoot -c core.quotePath=false -c i18n.logOutputEncoding=UTF-8 @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
    }
}

function Invoke-GitUtf8Output {
    param([string[]]$Arguments)

    $processInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $processInfo.FileName = "git"
    $processInfo.UseShellExecute = $false
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError = $true
    $processInfo.StandardOutputEncoding = $utf8NoBom
    $processInfo.StandardErrorEncoding = $utf8NoBom
    foreach ($argument in @("-C", $repoRoot, "-c", "core.quotePath=false", "-c", "i18n.logOutputEncoding=UTF-8") + $Arguments) {
        [void]$processInfo.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::Start($processInfo)
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) {
        throw "git $($Arguments -join ' ') failed with exit code $($process.ExitCode): $stderr"
    }

    return $stdout
}

function Get-GitConfigValue {
    param([string]$Key)

    $output = & git -C $repoRoot -c core.quotePath=false -c i18n.logOutputEncoding=UTF-8 config --get $Key
    if ($LASTEXITCODE -eq 0) {
        return (($output -join "`n").Trim())
    }
    if ($LASTEXITCODE -eq 1) {
        return ""
    }
    throw "git config --get $Key failed with exit code $LASTEXITCODE"
}

function Get-CurrentBranchName {
    # A symbolic HEAD has a branch name even before the first commit exists.
    $branch = & git -C $repoRoot symbolic-ref --quiet --short HEAD
    if ($LASTEXITCODE -eq 0) {
        return (($branch -join "`n").Trim())
    }
    if ($LASTEXITCODE -eq 1) {
        return "HEAD"
    }
    throw "Unable to determine the current branch: git symbolic-ref failed with exit code $LASTEXITCODE."
}

function Test-HeadCommit {
    & git -C $repoRoot rev-parse --verify --quiet "HEAD^{commit}" >$null
    if ($LASTEXITCODE -eq 0) {
        return $true
    }
    if ($LASTEXITCODE -eq 1) {
        return $false
    }
    throw "Unable to inspect HEAD: git rev-parse failed with exit code $LASTEXITCODE."
}

function Get-NormalizedDestinationRef {
    param([string]$Branch)

    if ([string]::IsNullOrWhiteSpace($Branch)) {
        throw "Push branch cannot be empty."
    }
    if ($Branch.StartsWith("refs/")) {
        return $Branch
    }
    return "refs/heads/$Branch"
}

function Get-PushDestination {
    $currentBranch = Get-CurrentBranchName
    $remote = $PushRemote.Trim()
    $branch = $PushBranch.Trim()

    if ([string]::IsNullOrWhiteSpace($remote)) {
        if ($currentBranch -ne "HEAD") {
            $remote = Get-GitConfigValue -Key "branch.$currentBranch.remote"
        }
        if ([string]::IsNullOrWhiteSpace($remote)) {
            $remote = "origin"
        }
    }

    if ([string]::IsNullOrWhiteSpace($branch)) {
        if ($currentBranch -eq "HEAD") {
            throw "Cannot infer push branch from detached HEAD. Pass -PushBranch explicitly."
        }

        $mergeRef = Get-GitConfigValue -Key "branch.$currentBranch.merge"
        if ($mergeRef -match "^refs/heads/(.+)$") {
            $branch = $Matches[1]
        } else {
            $branch = $currentBranch
        }
    }

    $destinationRef = Get-NormalizedDestinationRef -Branch $branch
    $displayBranch = $branch
    if ($displayBranch.StartsWith("refs/heads/")) {
        $displayBranch = $displayBranch.Substring("refs/heads/".Length)
    }

    return [pscustomobject]@{
        Remote = $remote
        DestinationRef = $destinationRef
        RefSpec = "HEAD:$destinationRef"
        Display = "$remote/$displayBranch"
    }
}

function Test-LocalCommitObject {
    param([string]$CommitHash)

    & git -C $repoRoot cat-file -e "$CommitHash^{commit}" 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Get-RemoteTipHash {
    param([pscustomobject]$Destination)

    $output = Invoke-GitUtf8Output -Arguments @("ls-remote", $Destination.Remote, $Destination.DestinationRef)
    $line = @($output -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
    if ($line.Count -eq 0) {
        return ""
    }

    $hash = (($line[0] -split "\s+")[0]).Trim()
    if ([string]::IsNullOrWhiteSpace($hash)) {
        return ""
    }

    if (-not (Test-LocalCommitObject -CommitHash $hash)) {
        Write-Host "Fetching remote base $($Destination.DestinationRef) from $($Destination.Remote)..."
        Invoke-Git fetch --no-tags $Destination.Remote $Destination.DestinationRef
    }

    if (-not (Test-LocalCommitObject -CommitHash $hash)) {
        throw "Remote tip $hash for $($Destination.Display) is not available locally after fetch."
    }

    return $hash
}

function Get-IncrementalPushCommits {
    param(
        [pscustomobject]$Destination,
        [string]$TargetCommit
    )

    $remoteTip = Get-RemoteTipHash -Destination $Destination
    if ([string]::IsNullOrWhiteSpace($remoteTip)) {
        Write-Host "Remote destination $($Destination.Display) does not exist. The first push will create it."
        $all = (Invoke-GitUtf8Output -Arguments @("rev-list", "--reverse", $TargetCommit)).Trim()
        if ([string]::IsNullOrWhiteSpace($all)) {
            return @()
        }
        return @($all -split "`n" | Where-Object { $_.Trim() })
    }

    & git -C $repoRoot merge-base --is-ancestor $remoteTip $TargetCommit
    if ($LASTEXITCODE -eq 1) {
        throw "Remote $($Destination.Display) is not an ancestor of target commit $TargetCommit. Fetch/rebase or resolve divergence before pushing."
    }
    if ($LASTEXITCODE -ne 0) {
        throw "git merge-base --is-ancestor $remoteTip $TargetCommit failed with exit code $LASTEXITCODE"
    }

    $missing = (Invoke-GitUtf8Output -Arguments @("rev-list", "--reverse", "$remoteTip..$TargetCommit")).Trim()
    if ([string]::IsNullOrWhiteSpace($missing)) {
        return @()
    }
    return @($missing -split "`n" | Where-Object { $_.Trim() })
}

function Invoke-GitWithRetry {
    param(
        [string[]]$Arguments,
        [string]$Description
    )

    for ($attempt = 1; $attempt -le $PushRetryCount; $attempt++) {
        try {
            Invoke-Git @Arguments
            return
        } catch {
            if ($attempt -ge $PushRetryCount) {
                throw
            }
            Write-Host "$Description failed on attempt $attempt/$PushRetryCount. Retrying in $PushRetryDelaySeconds second(s)..."
            if ($PushRetryDelaySeconds -gt 0) {
                Start-Sleep -Seconds $PushRetryDelaySeconds
            }
        }
    }
}

function Invoke-PushCurrentHead {
    param(
        [pscustomobject]$Destination,
        [string]$CommitHash
    )

    $targetCommit = (Invoke-GitUtf8Output -Arguments @("rev-parse", "$CommitHash^{commit}")).Trim()
    $commitsToPush = @(Get-IncrementalPushCommits -Destination $Destination -TargetCommit $targetCommit)
    if ($commitsToPush.Count -eq 0) {
        Write-Host "Remote $($Destination.Display) already contains commit $CommitHash."
        return
    }

    Write-Host "Pushing $($commitsToPush.Count) missing commit(s) incrementally to $($Destination.Display)..."
    for ($i = 0; $i -lt $commitsToPush.Count; $i++) {
        $commit = $commitsToPush[$i].Trim()
        if ([string]::IsNullOrWhiteSpace($commit)) {
            continue
        }
        $short = (Invoke-GitUtf8Output -Arguments @("rev-parse", "--short=12", $commit)).Trim()
        Write-Host "  push [$($i + 1)/$($commitsToPush.Count)] $short -> $($Destination.DestinationRef)"
        Invoke-GitWithRetry `
            -Arguments @("push", $Destination.Remote, "$commit`:$($Destination.DestinationRef)") `
            -Description "git push $short"
    }
}

function Invoke-GitNullSeparatedOutput {
    param([string[]]$Arguments)

    $joined = Invoke-GitUtf8Output -Arguments $Arguments
    if ([string]::IsNullOrEmpty($joined)) {
        return @()
    }

    return @($joined -split [char]0 | Where-Object { $_ })
}

$script:TrackedPathSet = $null

function Get-TrackedPathSet {
    if ($null -ne $script:TrackedPathSet) {
        return $script:TrackedPathSet
    }

    $set = @{}
    foreach ($path in (Invoke-GitNullSeparatedOutput -Arguments @("ls-files", "-z"))) {
        $set[$path] = $true
    }
    $script:TrackedPathSet = $set
    return $script:TrackedPathSet
}

function Test-GitTrackedPath {
    param([string]$Path)
    return (Get-TrackedPathSet).ContainsKey($Path)
}

function Get-AddablePaths {
    param([string[]]$Paths)

    $addable = New-Object System.Collections.Generic.List[string]
    $skipped = New-Object System.Collections.Generic.List[string]

    foreach ($path in $Paths) {
        $absolutePath = Join-Path $repoRoot $path
        if ((Test-Path -LiteralPath $absolutePath) -or (Test-GitTrackedPath -Path $path)) {
            $addable.Add($path)
        } else {
            $skipped.Add($path)
        }
    }

    return [pscustomobject]@{
        Addable = @($addable)
        Skipped = @($skipped)
    }
}

function Clear-StagedChanges {
    & git -C $repoRoot diff --cached --quiet
    if ($LASTEXITCODE -eq 0) {
        return
    }
    if ($LASTEXITCODE -eq 1) {
        if ($DryRun) {
            Write-Host "Dry run: existing staged changes would be unstaged before batching."
            return
        }
        Write-Host "The staging area is not empty. Unstaging existing changes first..."
        if (Test-HeadCommit) {
            Invoke-Git restore --staged -- .
        } else {
            # Without a first commit there is no tree to restore from. Clear only the index.
            Invoke-Git read-tree --empty
        }
        return
    }
    throw "Unable to inspect staged changes."
}

function Get-PendingPaths {
    $ordered = [ordered]@{}
    $commands = @(
        @("diff", "--no-renames", "-z", "--name-only", "--diff-filter=ACDMRTUXB"),
        @("diff", "--cached", "--no-renames", "-z", "--name-only", "--diff-filter=ACDMRTUXB"),
        @("ls-files", "-z", "--others", "--exclude-standard")
    )

    foreach ($command in $commands) {
        $paths = Invoke-GitNullSeparatedOutput -Arguments $command
        foreach ($path in $paths) {
            if ($path -and -not $ordered.Contains($path)) {
                $ordered[$path] = $true
            }
        }
    }

    return @($ordered.Keys | Sort-Object)
}

function ConvertTo-RepoPath {
    param([string]$Path)
    return ($Path -replace "\\", "/")
}

function Test-Utf8File {
    param([string]$Path)

    try {
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $repoRoot $Path))
        $strictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
        [void]$strictUtf8.GetString($bytes)
        return $true
    } catch {
        return $false
    }
}

function Get-AttrMap {
    param([string[]]$Paths)

    $attrMap = @{}
    if ($Paths.Count -eq 0) {
        return $attrMap
    }

    for ($start = 0; $start -lt $Paths.Count; $start += 50) {
        $end = [Math]::Min($start + 49, $Paths.Count - 1)
        $chunk = @($Paths[$start..$end])
        $output = Invoke-GitUtf8Output -Arguments (@("check-attr", "text", "eol", "binary", "--") + $chunk)

        foreach ($line in ($output -split "`n")) {
            $parts = $line -split ": ", 3
            if ($parts.Count -ne 3) {
                continue
            }
            $path = ConvertTo-RepoPath ($parts[0].TrimEnd("`r"))
            $attr = $parts[1]
            $value = $parts[2]
            if (-not $attrMap.ContainsKey($path)) {
                $attrMap[$path] = @{}
            }
            $attrMap[$path][$attr] = $value
        }
    }

    return $attrMap
}

function Test-ShouldNormalize {
    param(
        [hashtable]$Attrs,
        [string]$Path
    )

    $text = $Attrs["text"]
    $eol = $Attrs["eol"]
    $binary = $Attrs["binary"]
    if ($text -eq "unset") {
        return $false
    }
    if ($binary -eq "set") {
        return $false
    }
    if ($eol -eq "crlf") {
        return $false
    }
    if ($eol -eq "lf") {
        return $true
    }
    if ($text -eq "set") {
        return $true
    }

    $textExts = @(
        ".md", ".txt", ".py", ".ps1", ".sh", ".cmd", ".bat",
        ".json", ".yml", ".yaml", ".toml", ".ini",
        ".xml", ".html", ".css", ".js", ".ts", ".tsx", ".jsx",
        ".cs", ".c", ".h", ".cpp", ".hpp", ".cc",
        ".java", ".kt", ".rs", ".go", ".rb", ".php"
    )
    return $textExts -contains ([System.IO.Path]::GetExtension($Path).ToLowerInvariant())
}

function Get-AttributeRuleForNonUtf8Path {
    param([string]$Path)

    $repoPath = ConvertTo-RepoPath $Path
    $ext = [System.IO.Path]::GetExtension($repoPath).ToLowerInvariant()
    $binaryTypeExts = @(".snk", ".pfx", ".p12", ".cer", ".der", ".dat")
    $textTypeExts = @(
        ".md", ".txt", ".py", ".ps1", ".sh", ".cmd", ".bat",
        ".json", ".yml", ".yaml", ".toml", ".ini",
        ".xml", ".html", ".css", ".js", ".ts", ".tsx", ".jsx",
        ".cs", ".c", ".h", ".cpp", ".hpp", ".cc",
        ".java", ".kt", ".rs", ".go", ".rb", ".php"
    )

    if ($binaryTypeExts -contains $ext) {
        return "*$ext   -text"
    }
    if ($textTypeExts -contains $ext) {
        return "$repoPath -text"
    }
    if ($ext) {
        return "*$ext   -text"
    }
    return "$repoPath -text"
}

function Add-NonUtf8AttributeExclusions {
    param([string[]]$Paths)

    if ($NoAutoAttributes -or $Paths.Count -eq 0) {
        return $false
    }

    $attrs = Get-AttrMap -Paths $Paths
    $gitattributesPath = Join-Path $repoRoot ".gitattributes"
    $existing = @()
    if (Test-Path -LiteralPath $gitattributesPath) {
        $existing = @(Get-Content -LiteralPath $gitattributesPath)
    }

    $existingSet = @{}
    foreach ($line in $existing) {
        $existingSet[$line.Trim()] = $true
    }

    $rulesToAdd = New-Object System.Collections.Generic.List[string]
    foreach ($path in $Paths) {
        if (-not (Test-Path -LiteralPath (Join-Path $repoRoot $path) -PathType Leaf)) {
            continue
        }
        $repoPath = ConvertTo-RepoPath $path
        $pathAttrs = @{}
        if ($attrs.ContainsKey($repoPath)) {
            $pathAttrs = $attrs[$repoPath]
        } elseif ($attrs.ContainsKey($path)) {
            $pathAttrs = $attrs[$path]
        }
        if (-not (Test-ShouldNormalize -Attrs $pathAttrs -Path $path)) {
            continue
        }
        if (Test-Utf8File -Path $path) {
            continue
        }

        $rule = Get-AttributeRuleForNonUtf8Path -Path $path
        if (-not $existingSet.ContainsKey($rule) -and -not $rulesToAdd.Contains($rule)) {
            $rulesToAdd.Add($rule)
        }
    }

    if ($rulesToAdd.Count -eq 0) {
        return $false
    }

    if ($DryRun) {
        Write-Host "Would add .gitattributes exclusions for $($rulesToAdd.Count) non-UTF-8 file rule(s)."
        foreach ($rule in $rulesToAdd) {
            Write-Host "  $rule"
        }
        return $false
    }

    Write-Host "Adding .gitattributes exclusions for $($rulesToAdd.Count) non-UTF-8 file rule(s)."
    $header = "# Auto-added non-UTF-8 exclusions for upstream/vendor files."
    if (-not $existingSet.ContainsKey($header)) {
        Add-Content -LiteralPath $gitattributesPath -Value ""
        Add-Content -LiteralPath $gitattributesPath -Value $header
    }
    foreach ($rule in $rulesToAdd) {
        Add-Content -LiteralPath $gitattributesPath -Value $rule
        Write-Host "  $rule"
    }
    return $true
}

function Invoke-StagedNormalization {
    if ($NoVerify) {
        return
    }

    $normalizer = Join-Path $repoRoot "scripts/normalize_eol_and_encoding.py"
    if (-not (Test-Path -LiteralPath $normalizer)) {
        throw "Normalizer script not found: scripts/normalize_eol_and_encoding.py"
    }

    $pythonCommand = Get-Command python -ErrorAction SilentlyContinue
    $pythonArgs = @()
    if ($null -ne $pythonCommand) {
        $pythonExe = $pythonCommand.Source
    } else {
        $pyCommand = Get-Command py -ErrorAction SilentlyContinue
        if ($null -eq $pyCommand) {
            throw "Python 3 is required for staged EOL/encoding normalization."
        }
        $pythonExe = $pyCommand.Source
        $pythonArgs += "-3"
    }

    Write-Host "Normalizing staged EOL/encoding before commit..."
    & $pythonExe @pythonArgs $normalizer --staged
    if ($LASTEXITCODE -ne 0) {
        throw "Staged EOL/encoding normalization failed with exit code $LASTEXITCODE"
    }
}

function Get-PathEstimatedBytes {
    param([string]$Path)

    $absolutePath = Join-Path $repoRoot $Path
    if (Test-Path -LiteralPath $absolutePath -PathType Leaf) {
        return ([System.IO.FileInfo]::new($absolutePath)).Length
    }

    return 0
}

function Format-ByteCountMB {
    param([int64]$Bytes)

    return ([Math]::Round($Bytes / 1000 / 1000, 2))
}

function Get-Batches {
    param(
        [string[]]$Paths,
        [int]$Size,
        [int64]$MaxBytes
    )

    $batches = New-Object System.Collections.Generic.List[object]
    $currentPaths = New-Object System.Collections.Generic.List[string]
    $currentBytes = [int64]0

    foreach ($path in $Paths) {
        $pathBytes = [int64](Get-PathEstimatedBytes -Path $path)
        $fileCountLimitReached = $currentPaths.Count -ge $Size
        $byteLimitReached = ($currentPaths.Count -gt 0) -and (($currentBytes + $pathBytes) -gt $MaxBytes)
        if ($fileCountLimitReached -or $byteLimitReached) {
            $batches.Add([pscustomobject]@{
                Paths = [string[]]($currentPaths.ToArray())
                EstimatedBytes = $currentBytes
            })
            $currentPaths.Clear()
            $currentBytes = [int64]0
        }

        if ($pathBytes -gt $MaxBytes) {
            Write-Warning "Single file exceeds MaxPushBatchMB: $path ($([Math]::Round($pathBytes / 1000 / 1000, 2)) MB > $MaxPushBatchMB MB)."
        }

        $currentPaths.Add($path)
        $currentBytes += $pathBytes
    }

    if ($currentPaths.Count -gt 0) {
        $batches.Add([pscustomobject]@{
            Paths = [string[]]($currentPaths.ToArray())
            EstimatedBytes = $currentBytes
        })
    }

    return $batches.ToArray()
}

function Invoke-GitPathChunks {
    param(
        [string[]]$PrefixArguments,
        [string[]]$Paths,
        [int]$ChunkSize = 100
    )

    if ($Paths.Count -eq 0) {
        return
    }

    for ($start = 0; $start -lt $Paths.Count; $start += $ChunkSize) {
        $end = [Math]::Min($start + $ChunkSize - 1, $Paths.Count - 1)
        $chunk = @($Paths[$start..$end])
        Invoke-Git @($PrefixArguments + $chunk)
    }
}

$pushDestination = $null
$shouldPushEachCommit = -not $NoPush
if ($PushEachCommit -and $NoPush) {
    throw "Use either -Push/-PushEachCommit or -NoPush, not both."
}

Clear-StagedChanges
Write-Host "Collecting pending files..."
$pendingPaths = @(Get-PendingPaths)

if ($pendingPaths.Count -eq 0) {
    Write-Host "No pending files found."
    if ($shouldPushEachCommit) {
        if (-not (Test-HeadCommit)) {
            Write-Host "No local commits exist yet. Nothing to push."
        } elseif ($DryRun) {
            Write-Host "Dry run: existing unpushed commits would be pushed incrementally."
        } else {
            $pushDestination = Get-PushDestination
            $commitHash = (Invoke-GitUtf8Output -Arguments @("rev-parse", "--short=12", "HEAD")).Trim()
            Invoke-PushCurrentHead -Destination $pushDestination -CommitHash $commitHash
        }
    } else {
        Write-Host "Per-commit push disabled by -NoPush."
    }
    exit 0
}

$batches = @(Get-Batches -Paths $pendingPaths -Size $BatchSize -MaxBytes $maxPushBatchBytes)
Write-Host "Found $($pendingPaths.Count) pending file(s)."
Write-Host "Will create $($batches.Count) commit(s), up to $BatchSize file(s) and $MaxPushBatchMB MB estimated raw blob bytes per commit, message '$Message'."
if (-not $NoAutoAttributes) {
    Write-Host "Non-UTF-8 attribute exclusions will be checked per batch."
}

if ($shouldPushEachCommit) {
    if ($DryRun) {
        Write-Host "Dry run: each successful commit would be pushed incrementally after creation."
    } else {
        $pushDestination = Get-PushDestination
        Write-Host "Each successful commit will be pushed incrementally to $($pushDestination.Display)."
    }
} else {
    Write-Host "Per-commit push disabled by -NoPush."
}

for ($i = 0; $i -lt $batches.Count; $i++) {
    $batchInfo = $batches[$i]
    $batch = @($batchInfo.Paths)
    $estimatedMB = Format-ByteCountMB -Bytes ([int64]$batchInfo.EstimatedBytes)
    Write-Host ""
    Write-Host "[$($i + 1)/$($batches.Count)] $($batch.Count) file(s), estimated $estimatedMB MB raw blob bytes"
    foreach ($path in $batch) {
        Write-Host "  $path"
    }

    if ($DryRun) {
        continue
    }

    $pathSelection = Get-AddablePaths -Paths $batch
    foreach ($path in $pathSelection.Skipped) {
        Write-Host "Skipping stale missing untracked path: $path"
    }

    $activeBatch = @($pathSelection.Addable)
    if ($activeBatch.Count -eq 0) {
        Write-Host "Batch has no addable paths after stale-path filtering."
        continue
    }

    $existingAddPaths = @($activeBatch | Where-Object {
        Test-Path -LiteralPath (Join-Path $repoRoot $_)
    })
    $deletedTrackedPaths = @($activeBatch | Where-Object {
        (-not (Test-Path -LiteralPath (Join-Path $repoRoot $_))) -and (Test-GitTrackedPath -Path $_)
    })

    $attrChanged = Add-NonUtf8AttributeExclusions -Paths $existingAddPaths
    $addPaths = @($existingAddPaths)
    if ($attrChanged -and -not ($addPaths -contains ".gitattributes")) {
        $addPaths += ".gitattributes"
    }

    Invoke-GitPathChunks -PrefixArguments @("add", "-A", "--") -Paths $addPaths
    Invoke-GitPathChunks -PrefixArguments @("update-index", "--force-remove", "--") -Paths $deletedTrackedPaths
    Invoke-StagedNormalization
    $existingAddPaths = @($addPaths | Where-Object {
        Test-Path -LiteralPath (Join-Path $repoRoot $_)
    })
    Invoke-GitPathChunks -PrefixArguments @("add", "-A", "--") -Paths $existingAddPaths

    $commitArgs = @("commit", "-m", $Message)
    if ($NoVerify) {
        $commitArgs += "--no-verify"
    }
    Invoke-Git @commitArgs
    if ($shouldPushEachCommit) {
        $commitHash = (Invoke-GitUtf8Output -Arguments @("rev-parse", "--short=12", "HEAD")).Trim()
        Invoke-PushCurrentHead -Destination $pushDestination -CommitHash $commitHash
    }
}

if ($DryRun) {
    Write-Host ""
    Write-Host "Dry run complete. No commits were created."
} else {
    Write-Host ""
    Write-Host "All batches committed successfully."
    if ($shouldPushEachCommit) {
        Write-Host "All created commits were pushed successfully."
    }
}
