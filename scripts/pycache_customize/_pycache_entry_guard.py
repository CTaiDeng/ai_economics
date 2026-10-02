# SPDX-FileCopyrightText: 2026 GaoZheng
# SPDX-License-Identifier: MIT
# Full license: LICENSES/MIT.txt (repository root)

from __future__ import annotations

import sys
from pathlib import Path

_MODULE_DIRECTORY = Path(__file__).resolve().parent
if str(_MODULE_DIRECTORY) not in sys.path:
    sys.path.insert(0, str(_MODULE_DIRECTORY))

from _pycache_governance import (  # noqa: E402
    PycacheGovernanceError,
    load_pycache_governance,
    normalize_path,
    runner_path,
)


def _guard_error(lines: list[str]) -> None:
    sys.dont_write_bytecode = True
    print(
        "[pycache_governance] Python bytecode cache governance error",
        file=sys.stderr,
    )
    for line in lines:
        print(f"[pycache_governance] {line}", file=sys.stderr)
    raise SystemExit(2)


def enforce_configured_pycache_prefix(
    entry_file: str,
    *,
    previous_dont_write_bytecode: bool,
) -> None:
    try:
        governance = load_pycache_governance(__file__)
    except PycacheGovernanceError as exc:
        _guard_error(
            [
                str(exc),
                f"entry_file={Path(entry_file).resolve(strict=False)}",
                f"runner={_MODULE_DIRECTORY / 'run_python_with_config.ps1'}",
            ]
        )
    actual = getattr(sys, "pycache_prefix", None)
    if actual is not None and normalize_path(actual) == normalize_path(
        governance.pycache_prefix
    ):
        sys.dont_write_bytecode = previous_dont_write_bytecode
        return
    actual_text = (
        "<not set>"
        if actual is None
        else str(Path(str(actual)).expanduser())
    )
    _guard_error(
        [
            "PYTHONPYCACHEPREFIX does not match the governed prefix.",
            f"config={governance.config_path}",
            f"expected={governance.pycache_prefix}",
            f"actual={actual_text}",
            f"runner={runner_path(governance)}",
        ]
    )
