# SPDX-FileCopyrightText: 2026 GaoZheng
# SPDX-License-Identifier: MIT
# Full license: LICENSES/MIT.txt (repository root)

<#
.SYNOPSIS
从百转千回分章目录生成同目录的百转千回.md合订本。
.DESCRIPTION
按序章、十卷一百章和尾声读取；每卷的卷首.md保存完整卷题与棋势说明。
卷目录保留原卷名，章名取自文件名；正文换行及数学块原样保留。
只合订及统计非空白文本元素，不修改分章，不依赖命名表或其他工作区。
核对时仅统一连续空行及文末空行；内容一致时保留已有合订本的排版。
唯一写入目标为脚本所在目录的百转千回.md。
默认同步；-Check只读核对，存在差异时退出码为1；-Preview只读预览。
#>
[CmdletBinding()]
param(
    [switch]$Check,
    [switch]$Preview
)

$ErrorActionPreference = 'Stop'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$utf8Strict = [System.Text.UTF8Encoding]::new($false, $true)
if ($Check -and $Preview) { throw '-Check与-Preview不能同时使用。' }

function Test-PathWithinRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )
    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    $resolvedRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    if ($resolvedPath.Equals($resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    return $resolvedPath.StartsWith($resolvedRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-SyncPath {
    param([string]$Path, [string]$Root)
    if (-not (Test-PathWithinRoot -Path $Path -Root $Root)) {
        throw "同步路径超出项目边界：$Path"
    }
    # 拒绝符号链接、目录联接和非普通文件，防止合订本写入越界。
    $candidate = [System.IO.Path]::GetFullPath($Path)
    if ((Test-Path -LiteralPath $candidate) -and -not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "同步目标必须为普通文件：$candidate"
    }
    while (-not [string]::IsNullOrEmpty($candidate)) {
        if (Test-Path -LiteralPath $candidate) {
            $item = Get-Item -LiteralPath $candidate -Force
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "同步路径不得经过链接：$candidate"
            }
        }
        $candidate = Split-Path -Parent $candidate
    }
}

function ConvertTo-ComparableLayout {
    param([AllowEmptyString()][string]$Text)
    return [regex]::Replace($Text, "`n{3,}", "`n`n").TrimEnd("`n") + "`n"
}

function Read-Utf8Text {
    param([Parameter(Mandatory = $true)][string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        throw "文件不得包含UTF-8 BOM：$Path"
    }
    if ([Array]::IndexOf($bytes, [byte]13) -ge 0) {
        throw "文件必须使用LF换行，不得包含CR：$Path"
    }
    return $utf8Strict.GetString($bytes)
}

function Get-NovelWordCount {
    param([AllowEmptyString()][string]$Text)
    $textElements = [System.Globalization.StringInfo]::GetTextElementEnumerator($Text)
    $count = 0
    while ($textElements.MoveNext()) {
        if (-not [string]::IsNullOrWhiteSpace($textElements.GetTextElement())) {
            $count++
        }
    }
    return $count
}

function Read-BookPartMarkdown {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$ExpectedTitle,
        [Parameter(Mandatory = $true)][ValidateSet('序章', '卷首', '章', '尾声')][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Root
    )
    Assert-SyncPath -Path $Path -Root $Root
    $text = Read-Utf8Text -Path $Path
    if ($text -cnotmatch '\A# (?<Title>[^\n]+)\n\n(?<Body>[\s\S]+)\z') {
        throw "分章稿必须以一级Markdown题名、空行和正文开头：$Path"
    }
    $actualTitle = $Matches.Title
    $bodyText = $Matches.Body.TrimEnd("`n")
    if ($ExpectedTitle -and $actualTitle -cne $ExpectedTitle) {
        throw ('分章稿首行题名不符：{0}；应为“{1}”，实际为“{2}”' -f $Path, $ExpectedTitle, $actualTitle)
    }
    if ([string]::IsNullOrWhiteSpace($bodyText)) {
        throw "分章稿正文不能为空：$Path"
    }
    if ($bodyText -match '(?m)^#{1,6}\s') {
        throw "分章稿正文不得包含其他Markdown标题：$Path"
    }
    return [pscustomobject]@{
        Title = $actualTitle
        Body = $bodyText
        Kind = $Kind
        WordCount = Get-NovelWordCount -Text $bodyText
        Path = $Path
        SourceText = $text
    }
}

function Read-BookParts {
    param([Parameter(Mandatory = $true)][string]$Directory)

    $standalone = @(Get-ChildItem -LiteralPath $Directory -File -Filter '*.md')
    $prologues = @($standalone | Where-Object { $_.BaseName -cmatch '^序章：\S.*$' })
    $epilogues = @($standalone | Where-Object { $_.BaseName -cmatch '^尾声：\S.*$' })
    if ($standalone.Count -ne 2 -or $prologues.Count -ne 1 -or $epilogues.Count -ne 1) {
        throw '分章根目录必须且只能包含一份序章：题名.md与一份尾声：题名.md。'
    }
    Read-BookPartMarkdown -Path $prologues[0].FullName -ExpectedTitle $prologues[0].BaseName -Kind 序章 -Root $Directory

    $volumes = @(foreach ($item in @(Get-ChildItem -LiteralPath $Directory -Directory)) {
        if ($item.Name -notlike '第*卷*') { continue }
        if ($item.Name -notmatch '^第([1-9][0-9]*)卷 \S.*$') {
            throw "卷目录名称须包含阿拉伯数字卷序和题名：$($item.Name)"
        }
        [pscustomobject]@{ Index = [int]$Matches[1]; Item = $item }
    })
    $volumes = @($volumes | Sort-Object Index)
    if ($volumes.Count -ne 10) {
        throw "本书须包含10个卷目录，当前为$($volumes.Count)个。"
    }

    for ($volumeOffset = 0; $volumeOffset -lt $volumes.Count; $volumeOffset++) {
        $volume = $volumes[$volumeOffset]
        if ($volume.Index -ne ($volumeOffset + 1)) {
            throw "卷序必须为1至10，不得重复或缺卷：$($volume.Item.Name)"
        }
        $introPath = Join-Path $volume.Item.FullName '卷首.md'
        if (-not (Test-Path -LiteralPath $introPath -PathType Leaf)) {
            throw "每卷必须包含卷首.md，保存完整卷题与棋势说明：$introPath"
        }
        $intro = Read-BookPartMarkdown -Path $introPath -Kind 卷首 -Root $Directory
        if ($intro.Title -cnotmatch ('\A' + [regex]::Escape($volume.Item.Name) + '｜\S.*\z')) {
            throw "卷首题名须为卷目录名加｜棋势副题：$introPath"
        }
        if ($intro.Body -cnotmatch '\A棋势[一二三四五六七八九十]+·第[1-9][0-9]*—[1-9][0-9]*手：\S') {
            throw "卷首正文须以棋势及手数范围开头：$introPath"
        }
        $intro
        $chapters = @(foreach ($item in @(Get-ChildItem -LiteralPath $volume.Item.FullName -File -Filter '*.md')) {
            if ($item.Name -ceq '卷首.md') { continue }
            if ($item.BaseName -notmatch '^第([1-9][0-9]*)章：\S.*$') {
                throw "分章文件名须采用第N章：题名.md格式：$($item.Name)"
            }
            [pscustomobject]@{ Index = [int]$Matches[1]; Item = $item }
        })
        $chapters = @($chapters | Sort-Object Index)
        if ($chapters.Count -ne 10) {
            throw "$($volume.Item.Name)须包含10章，当前为$($chapters.Count)章。"
        }
        for ($chapterOffset = 0; $chapterOffset -lt $chapters.Count; $chapterOffset++) {
            $chapter = $chapters[$chapterOffset]
            if ($chapter.Index -ne ($chapterOffset + 1)) {
                throw "每卷章序必须为1至10，不得重复或缺章：$($chapter.Item.Name)"
            }
            Read-BookPartMarkdown -Path $chapter.Item.FullName -ExpectedTitle $chapter.Item.BaseName -Kind 章 -Root $Directory
        }
    }
    Read-BookPartMarkdown -Path $epilogues[0].FullName -ExpectedTitle $epilogues[0].BaseName -Kind 尾声 -Root $Directory
}

$bookRoot = [System.IO.Path]::GetFullPath($PSScriptRoot)
$chapterDirectory = Join-Path $bookRoot '百转千回'
$combinedPath = Join-Path $bookRoot '百转千回.md'

if (-not (Test-Path -LiteralPath $chapterDirectory -PathType Container)) {
    throw "分章稿目录不存在：$chapterDirectory"
}
Assert-SyncPath -Path $combinedPath -Root $bookRoot
$bookTitle = Split-Path -Leaf $chapterDirectory
$partRecords = @(Read-BookParts -Directory $chapterDirectory)

$combinedLines = [System.Collections.Generic.List[string]]::new()
$combinedLines.Add("# $bookTitle")
$combinedLines.Add('')
$bookWordCount = 0
foreach ($part in $partRecords) {
    $headingPrefix = if ($part.Kind -ceq '章') { '###' } else { '##' }
    $combinedLines.Add("$headingPrefix $($part.Title)")
    $combinedLines.Add('')
    $combinedLines.Add($part.Body)
    $combinedLines.Add('')
    $bookWordCount += $part.WordCount
}
$combinedContent = ($combinedLines -join "`n").TrimEnd("`n") + "`n"

$combinedExisted = Test-Path -LiteralPath $combinedPath -PathType Leaf
$currentCombinedText = if ($combinedExisted) { Read-Utf8Text -Path $combinedPath } else { '' }
$hasDifference = (ConvertTo-ComparableLayout -Text $combinedContent) -cne (ConvertTo-ComparableLayout -Text $currentCombinedText)

if ($Check -or $Preview) {
    if ($hasDifference) {
        Write-Host "待同步：$combinedPath"
        Write-Host '分章稿与合订本存在差异。'
        if ($Check) { exit 1 }
    }
    else {
        Write-Host "检查通过：序章、10份卷首、100章与尾声的正文及结构同步（仅统一空行数量）；全书$($bookWordCount)个非空白文本元素。"
    }
    if ($Preview) { Write-Host '预览完成，未写入文件。' }
    exit 0
}

if (-not $hasDifference) {
    Write-Host "无需写入：序章、10份卷首、100章与尾声已经同步；全书$($bookWordCount)个非空白文本元素。"
    exit 0
}

# 写入前复核全部来源及唯一目标，避免覆盖运行期间的编辑。
$currentParts = @(Read-BookParts -Directory $chapterDirectory)
if ($currentParts.Count -ne $partRecords.Count) { throw '分章结构在同步期间发生变化，已停止写入。' }
for ($partOffset = 0; $partOffset -lt $partRecords.Count; $partOffset++) {
    if ($currentParts[$partOffset].Path -cne $partRecords[$partOffset].Path -or
        $currentParts[$partOffset].SourceText -cne $partRecords[$partOffset].SourceText) {
        throw "分章在同步期间发生变化，已停止写入：$($partRecords[$partOffset].Path)"
    }
}
Assert-SyncPath -Path $combinedPath -Root $bookRoot
if ((Test-Path -LiteralPath $combinedPath -PathType Leaf) -ne $combinedExisted) {
    throw "合订本在同步期间新增或移除：$combinedPath"
}
$latestCombinedText = if ($combinedExisted) { Read-Utf8Text -Path $combinedPath } else { '' }
if ($latestCombinedText -cne $currentCombinedText) {
    throw "合订本在同步期间发生变化：$combinedPath"
}

Write-Host "同步：$combinedPath"
try {
    [System.IO.File]::WriteAllText($combinedPath, $combinedContent, $utf8NoBom)
    if ((Read-Utf8Text -Path $combinedPath) -cne $combinedContent) {
        throw "合订本写回校验失败：$combinedPath"
    }
}
catch {
    $writeError = $_
    try {
        Assert-SyncPath -Path $combinedPath -Root $bookRoot
        if ($combinedExisted) {
            $originalBytes = $utf8NoBom.GetBytes($currentCombinedText)
            $currentBytes = if ([System.IO.File]::Exists($combinedPath)) { [System.IO.File]::ReadAllBytes($combinedPath) } else { [byte[]]@() }
            if (-not [System.IO.File]::Exists($combinedPath) -or
                [Convert]::ToBase64String($currentBytes) -cne [Convert]::ToBase64String($originalBytes)) {
                [System.IO.File]::WriteAllBytes($combinedPath, $originalBytes)
            }
        }
        elseif (Test-Path -LiteralPath $combinedPath -PathType Leaf) {
            Remove-Item -LiteralPath $combinedPath
        }
    }
    catch {
        throw "同步失败：$writeError；合订本回滚失败：$_"
    }
    throw $writeError
}

Write-Host "同步完成：序章、10份卷首、100章与尾声；全书$($bookWordCount)个非空白文本元素；已更新合订本：$combinedPath"
exit 0
