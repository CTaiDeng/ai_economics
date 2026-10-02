#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# SPDX-FileCopyrightText: 2026 GaoZheng
# SPDX-License-Identifier: MIT
# Full license: LICENSES/MIT.txt (repository root)

"""
Normalize staged text files according to .gitattributes:
- Enforce LF line endings
- Enforce UTF-8 (no BOM)

Usage:
  scripts/pycache_customize/run_python_with_config.ps1 \
    scripts/normalize_eol_and_encoding.py --staged [--check-only]

Notes:
- Detects which files to process based on `git check-attr` (eol/text/binary).
- Automatically restages files it modifies.
"""

from __future__ import annotations

import sys

_previous_dont_write_bytecode = sys.dont_write_bytecode
sys.dont_write_bytecode = True

from pathlib import Path

_governance_directory = Path(__file__).resolve().parent / "pycache_customize"
if str(_governance_directory) not in sys.path:
    sys.path.insert(0, str(_governance_directory))

from _pycache_entry_guard import enforce_configured_pycache_prefix

enforce_configured_pycache_prefix(
    __file__, previous_dont_write_bytecode=_previous_dont_write_bytecode
)

import argparse
import os
import subprocess
from dataclasses import dataclass
from typing import Dict, Iterable, List, Tuple


def run(cmd: List[str], *, cwd: str | None = None, input_bytes: bytes | None = None) -> Tuple[int, bytes, bytes]:
    proc = subprocess.Popen(
        cmd,
        cwd=cwd,
        stdin=subprocess.PIPE if input_bytes is not None else None,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        shell=False,
    )
    out, err = proc.communicate(input_bytes)
    return proc.returncode, out, err


def decode_git_path_output(data: bytes) -> List[str]:
    if not data:
        return []
    text = data.decode("utf-8", errors="surrogateescape")
    return [p for p in text.split("\0") if p]


def get_staged_files() -> List[str]:
    code, out, err = run(["git", "-c", "core.quotePath=false", "diff", "--cached", "-z", "--name-only", "--diff-filter=ACM"])
    if code != 0:
        print("[normalize] failed to get staged file list:", err.decode(errors="ignore"), file=sys.stderr)
        sys.exit(2)
    files = decode_git_path_output(out)
    return [f for f in files if os.path.isfile(f)]


@dataclass
class Attrs:
    text: str | None = None  # set|unset|unspecified
    eol: str | None = None   # lf|crlf|native|unspecified
    binary: str | None = None  # set|unspecified


def parse_check_attr(output: str) -> Dict[str, Attrs]:
    result: Dict[str, Attrs] = {}
    for line in output.splitlines():
        # format:  path: attr: value
        try:
            path, rest = line.split(": ", 1)
            attr, value = rest.split(": ", 1)
        except ValueError:
            # unexpected, ignore
            continue
        entry = result.setdefault(path, Attrs())
        if attr == "text":
            entry.text = value
        elif attr == "eol":
            entry.eol = value
        elif attr == "binary":
            entry.binary = value
    return result


def get_git_attrs(paths: List[str]) -> Dict[str, Attrs]:
    if not paths:
        return {}
    # --stdin works only when not quoting paths; join with \n
    code, out, err = run(
        ["git", "-c", "core.quotePath=false", "check-attr", "-a", "--stdin"],
        input_bytes=("\n".join(paths)).encode("utf-8", errors="surrogateescape"),
    )
    if code != 0:
        print("[normalize] git check-attr failed:", err.decode(errors="ignore"), file=sys.stderr)
        sys.exit(2)
    return parse_check_attr(out.decode("utf-8", errors="surrogateescape"))


TEXT_EXTS = {
    ".md", ".txt", ".py", ".ps1", ".sh", ".cmd", ".bat",
    ".json", ".yml", ".yaml", ".toml", ".ini",
    ".xml", ".html", ".css", ".js", ".ts", ".tsx", ".jsx",
    ".cs", ".c", ".h", ".cpp", ".hpp", ".cc",
    ".java", ".kt", ".rs", ".go", ".rb", ".php",
}

BINARY_EXTS = {
    ".bmp", ".cer", ".dat", ".der", ".dll", ".exe", ".gif", ".gz",
    ".ico", ".jpeg", ".jpg", ".pdf", ".pfx", ".p12", ".png", ".snk",
    ".tif", ".tiff", ".webp", ".zip",
}


def is_probably_text(path: str) -> bool:
    ext = os.path.splitext(path)[1].lower()
    return ext in TEXT_EXTS


def is_known_binary(path: str) -> bool:
    ext = os.path.splitext(path)[1].lower()
    return ext in BINARY_EXTS


def attr_value(value: str | None) -> str | None:
    if value is None:
        return None
    return value.strip()


def should_process(path: str, a: Attrs) -> bool:
    text_attr = attr_value(a.text)
    eol_attr = attr_value(a.eol)
    binary_attr = attr_value(a.binary)

    # Explicit -text must win over inherited eol/encoding rules.
    if text_attr == "unset":
        return False
    # Skip binaries
    if binary_attr == "set":
        return False
    # If .gitattributes explicitly sets CRLF, do not override
    if eol_attr == "crlf":
        return False
    # text=auto can coexist with eol=lf on binary assets in upstream trees.
    if text_attr != "set" and is_known_binary(path):
        return False
    # If .gitattributes says LF -> process
    if eol_attr == "lf":
        return True
    # If marked as text -> process
    if text_attr == "set":
        return True
    # Fallback by extension heuristic
    return is_probably_text(path)


@dataclass
class FixStats:
    processed: int = 0
    changed: int = 0
    removed_bom: int = 0
    converted_crlf: int = 0
    converted_cr: int = 0
    non_utf8: int = 0


def restage_files(paths: List[str]) -> bool:
    for start in range(0, len(paths), 100):
        chunk = paths[start:start + 100]
        code, _, err = run(["git", "-c", "core.quotePath=false", "add", "--", *chunk])
        if code != 0:
            print(
                f"[normalize] git add failed for changed file chunk {start // 100 + 1}: {err.decode(errors='ignore')}",
                file=sys.stderr,
            )
            return False
    return True


def normalize_file(path: str, check_only: bool) -> Tuple[bool, FixStats]:
    st = FixStats(processed=1)
    try:
        data = open(path, "rb").read()
    except Exception as e:
        print(f"[normalize] read failed: {path}: {e}", file=sys.stderr)
        return False, st

    removed_bom = False
    if data.startswith(b"\xEF\xBB\xBF"):
        data = data[3:]
        st.removed_bom = 1
        removed_bom = True

    # quick CRLF/CR checks on bytes
    had_crlf = b"\r\n" in data
    had_cr = (b"\r" in data) and not had_crlf
    if had_crlf:
        data = data.replace(b"\r\n", b"\n")
        st.converted_crlf = 1
    if had_cr:
        data = data.replace(b"\r", b"\n")
        st.converted_cr = 1

    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        st.non_utf8 = 1
        print(f"[normalize] non-UTF-8 file skipped; manual handling required: {path}", file=sys.stderr)
        return False, st

    # Normalize any accidental CR again after decode (safety)
    new_text = text.replace("\r\n", "\n").replace("\r", "\n")

    changed = removed_bom or had_crlf or had_cr or (new_text != text)
    if changed and not check_only:
        try:
            with open(path, "wb") as f:
                f.write(new_text.encode("utf-8"))
        except Exception as e:
            print(f"[normalize] write failed: {path}: {e}", file=sys.stderr)
            return False, st
    st.changed = 1 if changed else 0
    return True, st


def main() -> int:
    parser = argparse.ArgumentParser(description="Normalize staged files to UTF-8 LF (no BOM) guided by .gitattributes")
    parser.add_argument("--staged", action="store_true", help="process staged files only")
    parser.add_argument("--check-only", action="store_true", help="check only; do not write")
    args = parser.parse_args()

    if not args.staged:
        print("[normalize] --staged not specified; defaulting to staged files only", file=sys.stderr)

    files = get_staged_files()
    if not files:
        return 0

    attrs_map = get_git_attrs(files)

    total = FixStats()
    failed_any = False
    changed_paths: List[str] = []
    processed_paths: List[str] = []

    for p in files:
        a = attrs_map.get(p, Attrs())
        if not should_process(p, a):
            continue
        processed_paths.append(p)
        ok, st = normalize_file(p, args.check_only)
        if ok and st.changed and not args.check_only:
            changed_paths.append(p)
        total.processed += st.processed
        total.changed += st.changed
        total.removed_bom += st.removed_bom
        total.converted_crlf += st.converted_crlf
        total.converted_cr += st.converted_cr
        total.non_utf8 += st.non_utf8
        if not ok:
            failed_any = True

    if processed_paths and not args.check_only:
        if not restage_files(processed_paths):
            failed_any = True

    if total.changed or total.removed_bom or total.converted_crlf or total.converted_cr:
        print(
            f"[normalize] stats: changed {total.changed} file(s); removed BOM {total.removed_bom}; CRLF->LF {total.converted_crlf}; CR->LF {total.converted_cr}"
        )

    if total.non_utf8:
        print(f"[normalize] warning: found {total.non_utf8} non-UTF-8 file(s); skipped.", file=sys.stderr)
        failed_any = True

    return 1 if failed_any and not args.check_only else 0


if __name__ == "__main__":
    sys.exit(main())
