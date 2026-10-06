# 多组文本文件合并为 TXT

本目录提供 `Merge-TexToTxt.ps1` 与多份 JSON 配置，使用 PowerShell 7，无需额外依赖。工具支持任意扩展名的文本文件。

## 默认扫描与逐组导出

不传参数时，脚本扫描 **脚本所在目录顶层的全部 `*.json` 文件**，按不区分大小写的配置文件名字典序依次执行。不会递归扫描子目录。

每份 JSON 是独立的一组任务，使用自己的输入清单、`order` 和 `output_path`，分别生成一个 TXT。新增配置只需在本目录放入新的 JSON，无需修改脚本。

当前配置：

| JSON | 输入文件数 | 输出目标（仓库相对路径） |
| --- | ---: | --- |
| [ai_economics.json](ai_economics.json) | 7 | `res/ai_economics.txt` |
| [G_Framework.json](G_Framework.json) | 38 | `res/G_Framework.txt` |

在仓库根目录运行：

```powershell
pwsh -NoProfile -File ./scripts/tex_to_txt/Merge-TexToTxt.ps1
```

脚本对每个导出成功的文件仅打印完整路径，每条路径独占一行。失败时仍报告错误并返回非零退出码。

## JSON 配置

本目录内每份 JSON 都应使用如下结构；示例中的路径需替换为实际文件：

```json
{
  "output_path": "../../res/exports/group_a.txt",
  "order": "json",
  "files": [
    "../../docs/example.tex",
    "../../src/example.md"
  ]
}
```

- `output_path`：完整的 TXT 目标路径，含目录和文件名，必须以 `.txt` 结尾。每组配置使用独立输出路径；目标目录不存在时自动创建。
- `files`：非空的文本文件路径数组，支持 `.tex`、`.md`、`.json`、`.txt`、`.csv`、无扩展名等按 UTF-8 读取的文本文件。
- `order`：默认 `json`，按数组从上到下的顺序合并；重复路径也按对应位置重复写入。设置为 `filename` 时按文件名升序，同名文件保持列表顺序。

兼容旧输入字段 `tex_files`，其内容也支持任意扩展名；一份配置只能设置 `files` 或 `tex_files` 中的一个字段。输出目录与文件名由 `output_path` 统一管理。

## 路径与单组执行

JSON 中的所有相对路径均以 **该 JSON 文件所在目录** 为基准，支持绝对路径。Windows 路径在 JSON 中建议使用 `/`，使用 `\` 时需写成 `\\`。

指定 `-ConfigPath` 时只执行这一份配置，不扫描其他 JSON：

```powershell
pwsh -NoProfile -File ./scripts/tex_to_txt/Merge-TexToTxt.ps1 -ConfigPath ./scripts/tex_to_txt/ai_economics.json
```

`-ConfigPath` 的相对路径以当前工作目录为基准。临时覆盖输出路径时，必须同时指定 `-ConfigPath`：

```powershell
pwsh -NoProfile -File ./scripts/tex_to_txt/Merge-TexToTxt.ps1 -ConfigPath ./scripts/tex_to_txt/ai_economics.json -OutputPath ../../res/exports/ai_economics.txt
```

`-OutputPath` 的相对路径以所选 JSON 所在目录为基准，不改写 JSON。默认多组模式使用各组自身的 `output_path`。`-Order filename` 可以覆盖所执行各组的文件排序方式。

## 出错与冲突处理

脚本先核验配置与输入路径，检查所有组的输出冲突，再按配置文件名顺序执行可用任务。

- 某组配置或读取失败时，报告对应配置名，继续处理其他组。
- 多份配置指定同一输出路径时，跳过这些冲突组，保留已有 TXT。
- 输出路径与所扫描的配置文件或其他可用组的输入文件相同时，跳过对应输出组，避免改写来源内容。
- 每组先写临时文件，全部内容写入成功后再替换该组 TXT；失败时保留旧 TXT，并清除临时文件。
- 成功组的导出结果保留；只要任一组失败，整体退出码为非零。目录中没有 JSON 配置时也返回非零退出码。

## 输出格式

```text
文件一.tex
文件一的完整内容

文件二.md
文件二的完整内容

文件三.json
文件三的完整内容
```

标题行只写文件名（保留扩展名），文件块之间增加一个空行。正文完整保留，行尾统一为 LF；内容末尾没有换行时补上换行，已有尾部空行保留。空文件也写入文件名。TeX 命令、Markdown 与 JSON 均以源文本合并。

输入支持 UTF-8 BOM；输出采用 UTF-8 无 BOM、LF，末尾保留换行。

## 脚本许可

`Merge-TexToTxt.ps1` 采用 [MIT 许可](../../LICENSES/MIT.txt)。输入文稿及合并内容保留各自来源的许可与版权约定。
