# SPDX-FileCopyrightText: 2026 GaoZheng
# SPDX-License-Identifier: MIT
# Full license: LICENSES/MIT.txt (repository root)

from __future__ import annotations

from dataclasses import dataclass
import json
import os
from pathlib import Path
from typing import Mapping


CONFIG_ENVIRONMENT_VARIABLE = "PYCACHE_GOVERNANCE_CONFIG"
DEFAULT_CONFIG_NAME = "pycache_governance.json"


class PycacheGovernanceError(ValueError):
    """Raised when the pycache governance contract is missing or invalid."""


@dataclass(frozen=True)
class PycacheGovernance:
    config_path: Path
    workspace_root: Path
    pycache_prefix: Path
    allow_external_prefix: bool
    create_prefix: bool


def normalize_path(raw: object) -> str:
    path = Path(str(raw)).expanduser().resolve(strict=False)
    return os.path.normcase(os.path.normpath(str(path)))


def _read_json_lf(path: Path) -> dict[str, object]:
    try:
        raw = path.read_bytes()
    except OSError as exc:
        raise PycacheGovernanceError(
            f"cannot read governance file {path}: {exc}"
        ) from exc
    if raw.startswith(b"\xef\xbb\xbf") or b"\r" in raw:
        raise PycacheGovernanceError(
            f"governance file must be UTF-8 without BOM and LF-only: {path}"
        )
    try:
        payload = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise PycacheGovernanceError(
            f"invalid governance JSON {path}: {exc}"
        ) from exc
    if not isinstance(payload, dict):
        raise PycacheGovernanceError("governance JSON root must be an object")
    return payload


def _discover_workspace_root(config_directory: Path) -> Path:
    for candidate in (config_directory, *config_directory.parents):
        if (candidate / ".git").exists():
            return candidate.resolve(strict=False)
    return config_directory.resolve(strict=False)


def _resolve_path(raw: str, base: Path) -> Path:
    expanded = os.path.expandvars(os.path.expanduser(raw.strip()))
    candidate = Path(expanded)
    if not candidate.is_absolute():
        candidate = base / candidate
    return candidate.resolve(strict=False)


def _optional_bool(
    payload: Mapping[str, object], name: str, default: bool
) -> bool:
    if name not in payload:
        return default
    value = payload[name]
    if not isinstance(value, bool):
        raise PycacheGovernanceError(f"policy.{name} must be boolean")
    return value


def _strict_descendant(path: Path, root: Path) -> bool:
    try:
        common = os.path.commonpath((normalize_path(path), normalize_path(root)))
    except ValueError:
        return False
    normalized_path = normalize_path(path)
    normalized_root = normalize_path(root)
    return common == normalized_root and normalized_path != normalized_root


def default_config_path(module_file: str | Path) -> Path:
    configured = os.environ.get(CONFIG_ENVIRONMENT_VARIABLE, "").strip()
    if configured:
        return Path(os.path.expandvars(os.path.expanduser(configured))).resolve(
            strict=False
        )
    return Path(module_file).resolve().parent / DEFAULT_CONFIG_NAME


def load_pycache_governance(
    module_file: str | Path,
    *,
    config_path: str | Path | None = None,
) -> PycacheGovernance:
    resolved_config = (
        Path(config_path).expanduser().resolve(strict=False)
        if config_path is not None
        else default_config_path(module_file)
    )
    payload = _read_json_lf(resolved_config)
    runtime_paths = payload.get("runtime_paths")
    if not isinstance(runtime_paths, dict):
        raise PycacheGovernanceError("runtime_paths must be an object")
    raw_prefix = runtime_paths.get("pycache_prefix")
    if not isinstance(raw_prefix, str) or not raw_prefix.strip():
        raise PycacheGovernanceError(
            "runtime_paths.pycache_prefix must be a non-empty string"
        )

    raw_workspace = runtime_paths.get("workspace_root")
    if raw_workspace is None:
        workspace_root = _discover_workspace_root(resolved_config.parent)
    elif isinstance(raw_workspace, str) and raw_workspace.strip():
        workspace_root = _resolve_path(raw_workspace, resolved_config.parent)
    else:
        raise PycacheGovernanceError(
            "runtime_paths.workspace_root must be a non-empty string when present"
        )

    policy = payload.get("policy", {})
    if not isinstance(policy, dict):
        raise PycacheGovernanceError("policy must be an object when present")
    allow_external = _optional_bool(
        policy, "allow_external_prefix", False
    )
    create_prefix = _optional_bool(policy, "create_prefix", True)
    pycache_prefix = _resolve_path(raw_prefix, workspace_root)
    if not allow_external and not _strict_descendant(
        pycache_prefix, workspace_root
    ):
        raise PycacheGovernanceError(
            "runtime_paths.pycache_prefix must be below the workspace root "
            f"unless policy.allow_external_prefix is true: {pycache_prefix}"
        )
    return PycacheGovernance(
        config_path=resolved_config,
        workspace_root=workspace_root,
        pycache_prefix=pycache_prefix,
        allow_external_prefix=allow_external,
        create_prefix=create_prefix,
    )


def runner_path(governance: PycacheGovernance) -> Path:
    return governance.config_path.parent / "run_python_with_config.ps1"
