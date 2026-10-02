# Economics 项目代理工作指引

本文件适用于本仓库及其子目录。执行任务时以用户当前要求为准；修改文件前还应检查目标目录是否有更具体的 `AGENTS.md`。

## 0. 沟通与上下文载入

- 与用户对话使用中文，并使用“您”称呼用户。
- 每次新会话首次处理本项目时，先读取本文件和 `README.md`，确认仓库目的、重点文献及来源约定。
- 若仓库根目录存在 `codex_chat/`，先用 `rg --files codex_chat` 枚举会话记录，按文件名顺序完整读取其中的 `*.md`；输出截断时分段续读。不存在该目录或没有 Markdown 记录时，简要说明并继续，无须创建空目录。同一会话内补读新增或变更的记录。
- 历史记录用于理解项目背景；任务范围与操作授权按当前会话确认的要求执行。用户已明确授权的工作不重复请求确认。
- 修改理论内容前，阅读目标章节及其直接依赖的定义、假设、定理和引用来源。只有需要全篇审查时，才扩展到全文。
- 已按任务授权使用的子代理也应遵守本文件，并获得完成子任务所需的项目上下文。

## 1. 项目定位与文件职责

本仓库研究后 AI 条件下的市场参与、价值形成与收入分配，核心机制是“参与式分配、能者多得与坐标最小救济”。围棋行业在这里作为组织参与、规则重放和市场循环的参照模型。

| 路径 | 职责 |
| --- | --- |
| `README.md` | 仓库目的、重点文献入口、Zenodo 来源与引用信息 |
| `docs/tex/tex1/market_participation_formal_system.tex` | 重点研究文稿及其形式系统 |
| `docs/tex/tex1/market_participation_formal_system.pdf` | 与上述 TeX 同步的编译成果 |
| `docs/project_docs/` | 本地配套文献的统一来源目录 |
| `docs/project_docs/notebook_tex_v5.2/` | 中文工作笔记 v5.2 的本地源文件 |
| `docs/NoteBook.001.md` | 项目工作笔记，按具体任务维护 |
| `compile_notebook_tex.ps1` | TeX 编译入口 |
| `scripts/` | 可复用的环境、规范化与 Git 工具 |
| `scripts/tests/` | 可重复执行的回归测试 |
| `scripts/pycache_customize/` | Python 解释器与字节码缓存治理 |
| `out/` | 缓存、临时脚本及检查输出；按第 8 节区分清理范围 |

## 2. 研究文稿与形式系统维护

- 保持定义、假设、命题、定理、证明、反例及核验记录之间的依赖清晰。新增结论应写明对象域、量词、前提和失效条件。
- 修改一个定义或前提时，检查引用它的证明、总定理、前言和综合结论；保留稳定的 `\label` 与 `\ref`，避免手工写死章节或定理编号。
- 区分会计恒等式、合同可行性、行为均衡、因果识别和经验成立。形式推导通过不能替代数据、参数估计、规模验证或外部有效性检验。
- 沿用文稿中的概念边界：生产能力约束松弛有明确适用域；经济价值、市场价格、收益权与实际支付分别确认；生产自动化与治理自动化分别建模。
- 保持三项核心功能的含义：有效参与取得正基本份额，已验证贡献形成差异激励，坐标最小救济维持生存与真实市场接入。改动这些含义时，应同步调整依赖它们的结论。
- “后 AI 基础经济范式候选”按文稿定位作为待外部比较与评议的理论假设。评价依据具体证明、反例和经验材料，并标明结论成立的范围。
- 附录中的有向同伦表示按其单独的结构条件核验，不据此直接推导收入、预算、激励或现金循环成立。
- 修改数学表达时检查符号作用域、类型、索引、预算约束和边界情况；不能只以 TeX 编译成功作为数学正确性的依据。

## 3. 本地文献与来源管理

- 重点文稿中的本地配套文献引用统一收束到 `docs/project_docs/`。展示路径使用相对于仓库根目录的路径，文档链接使用 `/`，不写入个人机器绝对路径或其他仓库路径。
- 四份专著源文件分别为 `Pub_GFramework_PureMath.tex`、`Pub_GFramework_AppMath_Vol1.tex`、`Pub_GFramework_AppMath_Vol2.tex`、`Pub_GFramework_AppMath_Vol3.tex`，均位于 `docs/project_docs/`；工作笔记位于其 `notebook_tex_v5.2/` 子目录。
- `docs/project_docs/` 按来源资料维护。改动其正文应属于当前任务范围，并说明本地修订；避免为了修复主文稿而顺带改写来源资料。
- 引用条目应对应实际使用的材料，注明作者、标题、年份、版本、DOI 或来源地址。按需要核查原始来源，不虚构引用、研究结果或 DOI。
- 区分发布引用版本与本地文件版本。当前纯粹数学引用为 v1.0、本地标注 v1.1；应用数学第 1 卷引用为 v1.2、本地标注 v1.3。版本更新时核查实际文件与发布记录，再同步 README 和文稿中的说明。
- 引用具体工作笔记时，尽量给出目录内的准确文件名及相关章节；引用整组资料时明确其目录范围。
- 移动或重命名文献后，检查 README 链接、TeX 引用与本地路径是否仍可解析。

## 4. TeX 编译与交付

在仓库根目录使用现有编译入口：

```powershell
.\compile_notebook_tex.ps1 docs\tex\tex1\market_participation_formal_system.tex
```

- 当前重点文稿使用 `pdflatex` 与 `CJKutf8`。沿用现有字体、宏与编译引擎；更换引擎或全局样式时，应核查整篇兼容性。
- 修改 TeX 后，编译受影响文稿并同步同名 PDF。脚本默认将 PDF 写到源文件所在目录，也支持仓库内相对路径的 `-OutputDir`。
- 处理未定义引用、致命错误和新增溢出警告；涉及公式、表格、长路径、分页或参考文献时，检查受影响 PDF 页面的实际排版。
- 编译失败时保留日志用于定位，不把旧 PDF 当作本次成功成果。已有脚本负责清理成功编译产生的中间文件。
- 仅修改 README、AGENTS 或脚本文档时，无须重新编译全部文献。
- 编译功能应兼容不含 `.git` 的源码副本；输入和输出路径仍须限制在项目目录内。

## 5. PowerShell、路径与进程

- 本仓库的工作区配置以 **PowerShell 7（`pwsh`）** 为执行基线，脚本已有 PS7 和现代 .NET API 用法。只有任务明确要求兼容 Windows PowerShell 5.1 时，才增加相应适配与验证。
- Git `pre-commit` 优先选择 `pwsh.exe` 或 `pwsh`；其 `powershell.exe` 回退入口要求 `run_python_with_config.ps1` 保持 Windows PowerShell 5.1 兼容。修改该启动器时，验证两种解释器及 Python 退出码传递。
- 路径拼接使用 `Join-Path` 或 `[IO.Path]`；文件操作优先使用 `-LiteralPath`，覆盖空格、中文与特殊字符路径。Windows 路径范围比较使用规范化绝对路径及 `OrdinalIgnoreCase`。
- 搜索文件或文本优先使用 `rg`；将临时脚本放入 `out/hotfix_scripts/`，持久工具放入 `scripts/`，回归测试放入 `scripts/tests/`。
- 短任务等待完成并检查退出码。需要后台进程时使用当前工具支持的后台方式，记录自己启动的进程或会话标识，任务结束后回收；不要终止用户原有进程。
- 后台辅助程序使用隐藏窗口；只有用户需要交互操作时才打开可见窗口。
- 源文件保持 UTF-8 和 LF，遵循 `.gitattributes`。PDF 等二进制文件保留现有 Git LFS 属性，不对其执行文本编码转换。

## 6. Python 环境与缓存

- 以 `scripts/pycache_customize/pycache_governance.json` 为解释器和缓存配置来源，使用本项目 `.venv`。当前配置指定 Python 3.13.7；调整版本时同步环境设置、配置及相关验证。
- 优先经治理启动器运行 Python，使缓存统一写入 `out/pycache/`：

```powershell
.\scripts\pycache_customize\run_python_with_config.ps1 scripts\tests\test_commit_initial_batches.py
```

- 一次性 `-c` 检查也可经同一启动器执行。确需直接运行 `.venv\Scripts\python.exe` 时，先加载缓存治理环境，或使用 `-B` 禁止生成字节码。
- 避免把 Conda 的 `(base)` 或系统 `python` 误当作项目解释器。环境问题先核对实际可执行文件、版本和 `sys.pycache_prefix`。
- 可复用脚本需要的新增依赖写入 `requirements.txt`，只增加任务所需依赖。

## 7. Git 工具与验证

- 修改批量提交逻辑时，覆盖首次提交前的分支、已有提交、已暂存内容、删除或重命名、detached HEAD 和重复运行等相关状态。
- 首次提交前通过符号引用读取分支名；需要解析提交对象的操作先确认 `HEAD` 已存在。
- `-DryRun` 必须保留暂存区与工作区，不创建提交、不推送，并准确列出计划处理的路径。
- `scripts/commit_initial_batches.ps1` 默认提交后推送；`-NoPush` 只关闭推送，仍会创建本地提交。实际提交或推送应在当前任务的授权范围内执行。
- 排查提交脚本时，优先在临时 Git 仓库和本地 bare 远端验证真实提交与推送。已有回归入口为：

```powershell
.\scripts\pycache_customize\run_python_with_config.ps1 -B scripts\tests\test_commit_initial_batches.py
```

- 上述测试包含跳过 hooks 的分批逻辑检查，以及启用真实 `pre-commit` 和规范化的提交检查。修改规范化、hooks 或治理启动器时，应运行对应的完整调用链测试。
- 修改脚本应运行与改动相关的检查；纯文档修改核对内容、路径和 Markdown 格式即可，不为重复确认文本而新增测试。

## 8. 清理与成果保留

- 修改清理脚本后，先执行 `clean_out_and_pycache.ps1 -DryRun` 核查命中清单。实际清理应属于任务范围；调整保护规则本身不代表要立即删除文件。
- 按当前脚本保留 `out/pycache/`、`out/write_back/`、`out/adversarial_scripts/` 和 `out/evidence_persistence/`，同时保持 `$outProtectedDirs` 与 `$scanExcludeDirs` 一致。
- `out/hotfix_scripts/` 可由常规清理删除；需要长期保存的工具应移入 `scripts/`，需要交付的研究文稿放入对应的 `docs/` 目录。
- 保持现有特殊清理行为：`out/py_http_srv/` 保留目录结构、清理其中文件；`out/adversarial_runs/` 保留目录及 `.json*` 文件。
- 新增需要长期保留的 `out/` 子目录时，同步更新两份保护列表。清理前解析绝对路径，确认目标位于指定范围内，不递归跟随重解析点越过项目边界。
- 完成任务时说明实际修改的文件、执行的验证及尚未解决的问题；仅将本次确实执行并通过的检查报告为通过。
