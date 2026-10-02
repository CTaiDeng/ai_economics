# 自定义 Git Hooks 使用说明

本目录包含以下钩子与文件：

- `prepare-commit-msg`：当提交信息为空或为 `update` 时，基于已暂存改动自动生成提交信息（默认中文，可通过 `COMMIT_MSG_LANG=en` 输出英文）。当检测到“空信息”时，会先预填占位符 `update`，随后再触发自动生成。
- `commit-msg`：不会追加 AI 建议；仅负责清理历史版本产生的 `AI-SUGGESTION` 建议块（无论是否带 `#` 注释前缀），并在提交信息最终为空时写入默认 `update`。
- `pre-commit`：通过 `scripts/pycache_customize/run_python_with_config.ps1` 执行暂存文本的行尾/编码规范化，避免检查过程产生散落字节码。
- `post-merge` / `post-checkout` / `post-rewrite`：调用 `clean_out_and_pycache.ps1 -SkipOut` 清理散落的 `__pycache__/*.pyc`，保留权威缓存 `out/pycache`。
- `commit_template.txt`：为 `git commit` 打开编辑器时提供默认文本 `update`，方便触发自动生成。

启用步骤：

1) 将 hooks 目录指向本仓库中的 `.githooks`

```
git config core.hooksPath .githooks
```

2) 可选：设置提交模板（默认内容为 `update`）

```
 git config commit.template .githooks/commit_template.txt
```

3) Python 与缓存治理

- `pre-commit` 使用仓库治理启动器和 `pycache_governance.json` 中指定的 `.venv`，不会回退到任意系统 Python。
- `pre-commit` 优先使用 PowerShell 7，选择顺序为 `pwsh.exe`、`pwsh`、`powershell.exe`。最后一项为 Windows PowerShell 5.1 回退，Python 治理启动器兼容该入口。
- 在 Git Bash/WSL 中调用 Windows `.exe` 解释器时，先通过 `cygpath` 或 `wslpath` 转换脚本路径；原生 `pwsh` 使用原生路径。
- 详细约束和手动调用方法见 `scripts/pycache_customize/README.md`。

4) 可选：配置 Google Generative AI（Gemini）API（`prepare-commit-msg` 用，缺省走本地统计兜底）

```
# 任选其一
setx GEMINI_API_KEY "<your_key>"
setx GOOGLE_API_KEY "<your_key>"

# 可选：切换模型与语言
setx GEMINI_MODEL "gemini-1.5-flash"
setx COMMIT_MSG_LANG "zh"   # 或 "en"
```

说明：
- 无 API Key 或未安装 `google-generativeai` 时，`prepare-commit-msg` 将退化为本地汇总（基于 name-status 等）。
- 仅当提交信息为空或等于 `update`（不区分大小写）时才由 `prepare-commit-msg` 覆盖；其它情况保留原有信息。
- `commit-msg` 不会生成/追加建议，只做“清理 AI 建议块 + 兜底写入 update”。
- 散落缓存由根目录 `clean_out_and_pycache.ps1 -SkipOut` 清理；`out/pycache` 不参与该清理。
- `prepare-commit-msg` 内已显式导出 `GEMINI_API_KEY`/`GOOGLE_API_KEY` 到子进程环境；脚本会在 Key 存在时调用 Gemini，缺失则自动回退。
- Python 入口统一遵循 `scripts/pycache_customize/pycache_governance.json`。

### Windows 终端中文显示与编码建议

- 确保提交与日志均使用 UTF-8：
  - `git config --global i18n.commitEncoding utf-8`
  - `git config --global i18n.logOutputEncoding utf-8`
  - `git config --global core.quotepath false`（中文文件名不转义）
- CMD 显示 UTF-8：执行 `chcp 65001` 后再查看日志；或使用 Windows Terminal。
- PowerShell 建议使用新控制台（默认 UTF-8）；必要时 `chcp 65001`。
- 钩子内已设置 `PYTHONUTF8=1` 与 `PYTHONIOENCODING=UTF-8`，并为子进程提供 UTF-8 locale，避免写入的提交信息出现乱码。
