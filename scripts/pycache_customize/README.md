# Python 字节码缓存治理

本目录将工作区 Python 字节码统一写入 `out/pycache`，避免在
`scripts`、项目文档目录或源码包旁生成 `__pycache__`。

## 生效入口

- `enable_pycache_governance.ps1`：为当前 PowerShell 进程设置
  `PYTHONPYCACHEPREFIX`、`PYCACHE_GOVERNANCE_CONFIG`。
- `install_venv_pycache_hook.ps1`：向 `.venv` 安装启动 `.pth`，覆盖
  VS Code、`python -m ...`、直接调用 `.venv` 解释器等入口。
- `run_python_with_config.ps1`：使用治理配置指定的解释器运行一次命令。
- `sitecustomize.py` 与 `_pycache_entry_guard.py`：检查启动前缀是否与
  `pycache_governance.json` 一致。

治理启动器支持 PowerShell 7 和 Windows PowerShell 5.1，均保留 Python 的退出码。
Git `pre-commit` 优先调用 PowerShell 7，缺少该入口时才回退到 Windows PowerShell 5.1。

`economics.code-workspace` 还会在集成终端创建之前注入相同的两个环境
变量；`activate_venv.ps1` 会在手动激活时再次校验并加载配置。

不要在 `scripts` 根目录放置 `sitecustomize.py`：Python 可能在该模块有
机会设置缓存前缀之前，先把它编译到 `scripts/__pycache__`。

## 初始化或修复

```powershell
.\scripts\pycache_customize\install_venv_pycache_hook.ps1
.\activate_venv.ps1
```

验证：

```powershell
python -c "import sys; print(sys.pycache_prefix)"
```

期望输出为仓库根目录下的 `out\pycache`。
