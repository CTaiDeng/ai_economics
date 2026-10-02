<#
.SYNOPSIS
从百转千回分章目录生成同目录的百转千回.md合订本。
.DESCRIPTION
直接按数字卷章序读取十卷一百章；书名取自目录名，卷章名取自目录和文件。
只进行合订本排版及字数统计，不修改分章，不依赖额外配置文件或其他工作区。
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

function ConvertTo-LfText {
    param([AllowEmptyString()][string]$Text)
    return $Text.Replace("`r`n", "`n").Replace("`r", "`n")
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

function Read-ChapterMarkdown {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedTitle
    )
    $text = ConvertTo-LfText -Text (Read-Utf8Text -Path $Path)
    $lines = @($text -split "`n")
    while ($lines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($lines[$lines.Count - 1])) {
        if ($lines.Count -eq 1) {
            $lines = @()
        }
        else {
            $lines = @($lines[0..($lines.Count - 2)])
        }
    }
    if ($lines.Count -lt 2) {
        throw "分章稿必须包含首行章名和至少一段正文：$Path"
    }
    if ($lines[0] -notmatch '^#\s+\S') {
        throw "分章稿首行必须为一级Markdown章名：$Path"
    }
    $actualTitle = $lines[0].Trim() -replace '^#\s+', ''
    if ($actualTitle -cne $ExpectedTitle) {
        throw ('分章稿首行章名与文件名不一致：{0}；首行为“{1}”' -f $Path, $actualTitle)
    }
    $bodyText = (($lines | Select-Object -Skip 1) -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($bodyText)) {
        throw "分章稿正文不能为空：$Path"
    }
    $paragraphs = [System.Collections.Generic.List[string]]::new()
    foreach ($block in @([regex]::Split($bodyText, "`n[ `t]*`n+"))) {
        $joinedLines = @(
            $block -split "`n" |
                ForEach-Object { $_.Trim() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        ) -join ''
        if (-not [string]::IsNullOrWhiteSpace($joinedLines)) {
            if ($joinedLines -match '^#{1,6}\s') {
                throw "正文段落不得包含Markdown标题：$Path；$joinedLines"
            }
            $paragraphs.Add($joinedLines)
        }
    }
    if ($paragraphs.Count -eq 0) {
        throw "分章稿未解析出正文段落：$Path"
    }
    return [pscustomobject]@{
        Title = $actualTitle
        Paragraphs = @($paragraphs)
        Path = $Path
        SourceText = $text
    }
}

function Read-BookChapters {
    param([Parameter(Mandatory = $true)][string]$Directory)

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
        $chapters = @(foreach ($item in @(Get-ChildItem -LiteralPath $volume.Item.FullName -File -Filter '*.md')) {
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
            $record = Read-ChapterMarkdown -Path $chapter.Item.FullName -ExpectedTitle $chapter.Item.BaseName
            $wordCount = 0
            foreach ($paragraph in $record.Paragraphs) {
                $wordCount += Get-NovelWordCount -Text $paragraph
            }
            $record | Add-Member -NotePropertyName VolumeIndex -NotePropertyValue $volume.Index
            $record | Add-Member -NotePropertyName VolumeTitle -NotePropertyValue $volume.Item.Name
            $record | Add-Member -NotePropertyName ChapterIndex -NotePropertyValue $chapter.Index
            $record | Add-Member -NotePropertyName WordCount -NotePropertyValue $wordCount
            $record
        }
    }
}

$bookRoot = [System.IO.Path]::GetFullPath($PSScriptRoot)
$chapterDirectory = Join-Path $bookRoot '百转千回'
$combinedPath = Join-Path $bookRoot '百转千回.md'

if (-not (Test-Path -LiteralPath $chapterDirectory -PathType Container)) {
    throw "分章稿目录不存在：$chapterDirectory"
}
Assert-SyncPath -Path $combinedPath -Root $bookRoot
$bookTitle = Split-Path -Leaf $chapterDirectory
$chapterRecords = @(Read-BookChapters -Directory $chapterDirectory)

$combinedLines = [System.Collections.Generic.List[string]]::new()
$combinedLines.Add("# $bookTitle")
$combinedLines.Add('')
$bookWordCount = 0
for ($volumeIndex = 1; $volumeIndex -le 10; $volumeIndex++) {
    $volumeTitle = $chapterRecords[($volumeIndex - 1) * 10].VolumeTitle
    $combinedLines.Add("## $volumeTitle")
    $combinedLines.Add('')
    $volumeChapters = @($chapterRecords | Where-Object { [int]$_.VolumeIndex -eq $volumeIndex } | Sort-Object { [int]$_.ChapterIndex })
    if ($volumeChapters.Count -ne 10) {
        throw "第${volumeIndex}卷必须包含10章。"
    }
    foreach ($chapter in $volumeChapters) {
        $combinedLines.Add("### $($chapter.Title)")
        $combinedLines.Add('')
        foreach ($paragraph in @($chapter.Paragraphs)) {
            $combinedLines.Add([string]$paragraph)
            $combinedLines.Add('')
        }
        $bookWordCount += $chapter.WordCount
    }
}
$combinedContent = ($combinedLines -join "`n").TrimEnd("`n") + "`n"

$combinedExisted = Test-Path -LiteralPath $combinedPath -PathType Leaf
$currentCombinedText = if ($combinedExisted) { Read-Utf8Text -Path $combinedPath } else { '' }
$hasDifference = $combinedContent -cne $currentCombinedText

if ($Check -or $Preview) {
    if ($hasDifference) {
        Write-Host "待同步：$combinedPath"
        Write-Host '分章稿与合订本存在差异。'
        if ($Check) { exit 1 }
    }
    else {
        Write-Host "检查通过：10卷、100章分章稿与合订本完全同步；全书$($bookWordCount)字。"
    }
    if ($Preview) { Write-Host '预览完成，未写入文件。' }
    exit 0
}

if (-not $hasDifference) {
    Write-Host "无需写入：100章分章稿与合订本已经同步；全书$($bookWordCount)字。"
    exit 0
}

# 写入前复核全部来源及唯一目标，避免覆盖运行期间的编辑。
$currentChapters = @(Read-BookChapters -Directory $chapterDirectory)
for ($chapterOffset = 0; $chapterOffset -lt $chapterRecords.Count; $chapterOffset++) {
    if ($currentChapters[$chapterOffset].Path -cne $chapterRecords[$chapterOffset].Path -or
        $currentChapters[$chapterOffset].SourceText -cne $chapterRecords[$chapterOffset].SourceText) {
        throw "分章在同步期间发生变化，已停止写入：$($chapterRecords[$chapterOffset].Path)"
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

Write-Host "同步完成：10卷、100章、全书$($bookWordCount)字；已更新合订本：$combinedPath"
exit 0
