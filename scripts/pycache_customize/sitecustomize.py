# SPDX-FileCopyrightText: 2026 GaoZheng
# SPDX-License-Identifier: MIT
# Full license: LICENSES/MIT.txt (repository root)

from __future__ import annotations

import os
import sys
from pathlib import Path

from _pycache_governance import (
    PycacheGovernanceError,
    load_pycache_governance,
    normalize_path,
    runner_path,
)


def _exit_with_error(lines: list[str]) -> None:
    sys.dont_write_bytecode = True
    sys.stderr.write(
        "[pycache_governance] Python bytecode cache governance error\n"
    )
    for line in lines:
        sys.stderr.write(f"[pycache_governance] {line}\n")
    sys.stderr.flush()
    os._exit(2)


def _enforce_pycache_prefix() -> None:
    try:
        governance = load_pycache_governance(__file__)
    except PycacheGovernanceError as exc:
        _exit_with_error(
            [
                str(exc),
                f"runner={Path(__file__).resolve().parent / 'run_python_with_config.ps1'}",
            ]
        )
    actual = getattr(sys, "pycache_prefix", None)
    if actual is not None and normalize_path(actual) == normalize_path(
        governance.pycache_prefix
    ):
        return
    actual_text = (
        "<not set>"
        if actual is None
        else str(Path(str(actual)).expanduser())
    )
    _exit_with_error(
        [
            "PYTHONPYCACHEPREFIX does not match the governed prefix.",
            f"config={governance.config_path}",
            f"expected={governance.pycache_prefix}",
            f"actual={actual_text}",
            f"runner={runner_path(governance)}",
        ]
    )


_enforce_pycache_prefix()
