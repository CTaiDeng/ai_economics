#requires -Version 7.0
# SPDX-FileCopyrightText: 2026 GaoZheng
# SPDX-License-Identifier: MIT
# Full license: LICENSES/MIT.txt (repository root)
<#
.SYNOPSIS
扫描脚本所在目录的 JSON，按配置文件名顺序逐组合并文本。
.DESCRIPTION
每组使用其 JSON 中的 files 与 output_path，相对路径以 JSON 所在目录为基准。
支持任意扩展名的文本文件，输出为 UTF-8 无 BOM、LF 的 TXT。
某组失败后继续处理其他组；有任一失败时返回非零退出码。
.EXAMPLE
pwsh -NoProfile -File ./Merge-TexToTxt.ps1
.EXAMPLE
pwsh -NoProfile -File ./Merge-TexToTxt.ps1 -ConfigPath ./ai_economics.json
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$ConfigPath,

    [ValidateNotNullOrEmpty()]
    [string]$OutputPath,

    [ValidateSet('json', 'filename')]
    [string]$Order
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-ConfigRelativePath {
    param([string]$PathValue, [string]$BaseDirectory)
    return [IO.Path]::GetFullPath($PathValue, $BaseDirectory)
}

function Get-ConfigString {
    param([System.Collections.IDictionary]$Config, [string]$Key, [string]$DefaultValue)
    if (-not $Config.Contains($Key)) {
        return $DefaultValue
    }
    if ($Config[$Key] -isnot [string] -or [string]::IsNullOrWhiteSpace($Config[$Key])) {
        throw "JSON 字段 '$Key' 必须是非空字符串。"
    }
    return $Config[$Key]
}

function New-MergePlan {
    param(
        [IO.FileInfo]$ConfigItem,
        [bool]$OverrideOutput,
        [string]$OutputOverride,
        [bool]$OverrideOrder,
        [string]$OrderOverride
    )
    $configDirectory = $ConfigItem.DirectoryName
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    $config = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($ConfigItem.FullName, $utf8)) -AsHashtable
    if ($config -isnot [System.Collections.IDictionary]) {
        throw 'JSON 顶层必须是对象。'
    }
    if ($config.Contains('files') -and $config.Contains('tex_files')) {
        throw "JSON 不能同时设置 'files' 和兼容字段 'tex_files'。"
    }
    $listKey = if ($config.Contains('files')) { 'files' } else { 'tex_files' }
    if (-not $config.Contains($listKey) -or $config[$listKey] -isnot [array] -or $config[$listKey].Count -eq 0) {
        throw "JSON 字段 '$listKey' 必须是至少含一个文本文件路径的数组。"
    }
    $targetValue = if ($OverrideOutput) { $OutputOverride } else { Get-ConfigString $config 'output_path' $null }
    if ([string]::IsNullOrWhiteSpace($targetValue)) {
        throw "请在 JSON 中设置非空的 'output_path'，或在单配置模式中传入 -OutputPath。"
    }
    $fileOrder = if ($OverrideOrder) { $OrderOverride } else { Get-ConfigString $config 'order' 'json' }
    if ($fileOrder -notin @('json', 'filename')) {
        throw "排序方式仅支持 'json'（列表顺序）或 'filename'（文件名升序）。"
    }
    $destinationPath = Resolve-ConfigRelativePath $targetValue $configDirectory
    $destinationName = [IO.Path]::GetFileName($destinationPath)
    if ($destinationName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
        [IO.Path]::GetExtension($destinationPath) -ine '.txt') {
        throw 'output_path 必须是文件名合法的 .txt 文件路径。'
    }
    $files = [Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $config[$listKey].Count; $index++) {
        $entry = $config[$listKey][$index]
        if ($entry -isnot [string] -or [string]::IsNullOrWhiteSpace($entry)) {
            throw "$listKey 的第 $($index + 1) 项必须是非空路径字符串。"
        }
        $inputPath = Resolve-ConfigRelativePath $entry $configDirectory
        $inputItem = Get-Item -LiteralPath $inputPath -ErrorAction Stop
        if ($inputItem -isnot [IO.FileInfo]) {
            throw "文本路径必须指向文件：$entry"
        }
        $files.Add([pscustomobject]@{ Name = $inputItem.Name; Path = $inputItem.FullName; Index = $index })
    }
    $orderedFiles = $files.ToArray()
    if ($fileOrder -eq 'filename') {
        $orderedFiles = @($files | Sort-Object -Property Name, Index)
    }
    return [pscustomobject]@{
        ConfigPath = $ConfigItem.FullName
        ConfigName = $ConfigItem.Name
        OutputPath = $destinationPath
        Files = $orderedFiles
        Order = $fileOrder
    }
}

function Invoke-MergePlan {
    param([object]$Plan)
    $temporaryPath = $null
    $writer = $null
    try {
        $outputDirectory = [IO.Path]::GetDirectoryName($Plan.OutputPath)
        [void][IO.Directory]::CreateDirectory($outputDirectory)
        $temporaryPath = Join-Path $outputDirectory ('.text_merge_' + [Guid]::NewGuid().ToString('N') + '.tmp')
        $utf8 = [Text.UTF8Encoding]::new($false, $true)
        $writer = [IO.StreamWriter]::new($temporaryPath, $false, $utf8)
        for ($index = 0; $index -lt $Plan.Files.Count; $index++) {
            $file = $Plan.Files[$index]
            $content = [IO.File]::ReadAllText($file.Path, $utf8).Replace("`r`n", "`n").Replace("`r", "`n")
            $writer.Write($file.Name)
            $writer.Write("`n")
            $writer.Write($content)
            if ($content.Length -gt 0 -and -not $content.EndsWith("`n", [StringComparison]::Ordinal)) {
                $writer.Write("`n")
            }
            if ($index -lt $Plan.Files.Count - 1) {
                $writer.Write("`n")
            }
        }
        $writer.Dispose()
        $writer = $null
        [IO.File]::Move($temporaryPath, $Plan.OutputPath, $true)
        $temporaryPath = $null
        return $Plan.OutputPath
    }
    finally {
        if ($null -ne $writer) {
            $writer.Dispose()
        }
        if ($null -ne $temporaryPath -and [IO.File]::Exists($temporaryPath)) {
            [IO.File]::Delete($temporaryPath)
        }
    }
}

try {
    $singleConfig = $PSBoundParameters.ContainsKey('ConfigPath')
    $overrideOutput = $PSBoundParameters.ContainsKey('OutputPath')
    $overrideOrder = $PSBoundParameters.ContainsKey('Order')
    if ($overrideOutput -and -not $singleConfig) {
        throw '-OutputPath 仅支持与 -ConfigPath 一起使用；多组模式按各 JSON 的 output_path 导出。'
    }
    if ($singleConfig) {
        $configItem = Get-Item -LiteralPath $ConfigPath -ErrorAction Stop
        if ($configItem -isnot [IO.FileInfo]) {
            throw "配置路径必须指向文件：$ConfigPath"
        }
        $configItems = @($configItem)
    }
    else {
        [string[]]$configPaths = @(Get-ChildItem -LiteralPath $PSScriptRoot -File -Filter '*.json' -Force | ForEach-Object { $_.FullName })
        [Array]::Sort($configPaths, [StringComparer]::OrdinalIgnoreCase)
        if ($configPaths.Length -eq 0) {
            throw "脚本所在目录未找到 JSON 配置：$PSScriptRoot"
        }
        $configItems = @(foreach ($path in $configPaths) { Get-Item -LiteralPath $path })
    }

    $plans = [Collections.Generic.List[object]]::new()
    $failedConfigs = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $protectedPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $configItems) {
        [void]$protectedPaths.Add($item.FullName)
        try {
            $plan = New-MergePlan $item $overrideOutput $OutputPath $overrideOrder $Order
            $plans.Add($plan)
            foreach ($file in $plan.Files) { [void]$protectedPaths.Add($file.Path) }
        }
        catch {
            [void]$failedConfigs.Add($item.FullName)
            Write-Error "[$($item.Name)] 配置核验失败：$($_.Exception.Message)" -ErrorAction Continue
        }
    }

    # 写入前核查全部组的输出，避免相互覆盖或修改任意组的输入文件。
    $outputOwners = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($plan in $plans) {
        if (-not $outputOwners.ContainsKey($plan.OutputPath)) {
            $outputOwners.Add($plan.OutputPath, [Collections.Generic.List[object]]::new())
        }
        $outputOwners[$plan.OutputPath].Add($plan)
    }
    foreach ($owners in $outputOwners.Values) {
        if ($owners.Count -gt 1) {
            foreach ($plan in $owners) {
                [void]$failedConfigs.Add($plan.ConfigPath)
                Write-Error "[$($plan.ConfigName)] 多个配置指定同一输出路径：$($plan.OutputPath)" -ErrorAction Continue
            }
        }
    }
    foreach ($plan in $plans) {
        if (-not $failedConfigs.Contains($plan.ConfigPath) -and $protectedPaths.Contains($plan.OutputPath)) {
            [void]$failedConfigs.Add($plan.ConfigPath)
            Write-Error "[$($plan.ConfigName)] 输出路径与配置文件或任意组的输入文件相同：$($plan.OutputPath)" -ErrorAction Continue
        }
    }

    foreach ($plan in $plans) {
        if ($failedConfigs.Contains($plan.ConfigPath)) { continue }
        try {
            Invoke-MergePlan $plan
        }
        catch {
            [void]$failedConfigs.Add($plan.ConfigPath)
            Write-Error "[$($plan.ConfigName)] 合并失败：$($_.Exception.Message)" -ErrorAction Continue
        }
    }
    if ($failedConfigs.Count -gt 0) { exit 1 }
}
catch {
    Write-Error "合并失败：$($_.Exception.Message)" -ErrorAction Continue
    exit 1
}
