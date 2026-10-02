#!/usr/bin/env python
# -*- coding: utf-8 -*-
# SPDX-FileCopyrightText: 2026 GaoZheng
# SPDX-License-Identifier: MIT
# Full license: LICENSES/MIT.txt (repository root)

"""AI-assisted commit message suggester (Simplified Chinese, Conventional Commits).

Behavior:
- Reads staged diff and filenames, asks Google Gemini (if API key configured) for a succinct
  Conventional Commit subject and short body bullets (中文简体)。
- Appends suggestions as commented lines into the commit message file passed as argv[1].
- If API unavailable, falls back to a local heuristic summary.

Env:
- GOOGLE_API_KEY: Google Generative AI API Key. If absent, run offline fallback.
- GIT_AI_MODEL: model name (default: gemini-1.5-flash). Examples: gemini-1.5-pro
- GIT_AI_DISABLE: if set to "1", the caller hook should skip invoking this script.

Privacy:
- Sends a truncated unified diff (<= 24KB) and filename list to the API.
- Do NOT enable if your staged content is sensitive.
"""

from __future__ import annotations
import io
import json
import fnmatch
from pathlib import Path
import os
import subprocess as sp
import sys
from datetime import datetime


MAX_DIFF_BYTES = 24 * 1024


def _run(cmd: list[str]) -> str:
    try:
        out = sp.check_output(cmd, stderr=sp.DEVNULL)
        return out.decode("utf-8", errors="replace")
    except Exception:
        return ""


def _get_staged_summary() -> tuple[list[str], str]:
    files = _run(["git", "diff", "--cached", "--name-status"]).strip().splitlines()
    diff = _run(["git", "diff", "--cached", "--unified=0", "--no-color"]) or ""
    # truncate diff for safety
    if len(diff.encode("utf-8")) > MAX_DIFF_BYTES:
        encoded = diff.encode("utf-8")[:MAX_DIFF_BYTES]
        diff = encoded.decode("utf-8", errors="ignore") + "\n... [diff truncated]"
    # Apply excludes from scripts/docs_paths.json if present
    repo_root = Path(__file__).resolve().parent.parent
    excludes: list[str] = []
    try:
        cfg = repo_root / "scripts" / "docs_paths.json"
        if cfg.exists():
            data = json.loads(cfg.read_text(encoding="utf-8"))
            excludes = list(data.get("exclude_globs", []))
    except Exception:
        pass

    def _is_excluded(path: str) -> bool:
        try:
            rel = Path(path)
            if rel.is_absolute():
                rel = rel.relative_to(repo_root)
            rel_s = rel.as_posix()
        except Exception:
            rel_s = path.replace("\\", "/")
        return any(fnmatch.fnmatch(rel_s, pat) for pat in excludes)

    if excludes:
        files = [ln for ln in files if ln and not any(_is_excluded(p) for p in ln.split("\t")[1:])]
        if diff:
            lines = diff.splitlines()
            kept: list[str] = []
            i = 0
            while i < len(lines):
                ln = lines[i]
                if ln.startswith("diff --git "):
                    segs = ln.split()
                    a = ""; b = ""
                    if len(segs) >= 4:
                        if segs[2].startswith("a/"): a = segs[2][2:]
                        if segs[3].startswith("b/"): b = segs[3][2:]
                    excluded = any(_is_excluded(p) for p in (a, b) if p)
                    j = i + 1
                    while j < len(lines) and not lines[j].startswith("diff --git "):
                        j += 1
                    if not excluded:
                        kept.extend(lines[i:j])
                    i = j
                    continue
                kept.append(ln)
                i += 1
            diff = "\n".join(kept)
    return files, diff


def _read_msg(path: str) -> str:
    try:
        with io.open(path, "r", encoding="utf-8") as f:
            return f.read()
    except Exception:
        return ""


def _write_msg(path: str, text: str) -> None:
    with io.open(path, "w", encoding="utf-8") as f:
        f.write(text)


def _heuristic_suggestion(files: list[str]) -> str:
    kinds = {"A": "新增", "M": "修改", "D": "删除", "R": "重命名", "C": "复制"}
    items: list[str] = []
    for line in files[:15]:
        parts = line.split("\t")
        if not parts:
            continue
        tag = parts[0].split()[0]
        path = parts[-1]
        act = kinds.get(tag[:1], "变更")
        items.append(f"- {act}: {path}")
    subject = "chore(commit): 更新提交信息（AI 建议占位）"
    body = "\n".join(items) if items else "- 更新若干文件"
    return subject + "\n\n" + body


def _compose_prompt(files: list[str], diff: str) -> str:
    files_str = "\n".join(files[:30])
    return f"""
你是代码协作环境中的 Git 提交信息助手。请基于以下“已暂存改动”，输出一条符合 Conventional Commits 规范、中文简体的提交信息：

要求：
- 主题行（第一行）<= 72 字符，使用类型(scope)：简要动词描述（不加句号）。常见类型：feat, fix, docs, chore, refactor, perf, test, build, ci, style。
- 如需补充细节，请在正文使用 1-4 行要点（短句，避免重复代码）。
- 若为文档或配置调整，请尽量标注受影响文件/模块。
- 仅输出提交文本，不要解释。

文件列表：
{files_str}

统一 diff（可能截断）：
{diff}
""".strip()


def _call_gemini(prompt: str) -> str | None:
    api_key = os.getenv("GOOGLE_API_KEY")
    if not api_key:
        return None
    # Prefer google-generativeai SDK if available
    try:
        import google.generativeai as genai  # type: ignore
        model_name = os.getenv("GIT_AI_MODEL", "gemini-1.5-flash")
        genai.configure(api_key=api_key)
        model = genai.GenerativeModel(model_name)
        resp = model.generate_content(prompt, safety_settings=None)
        text = getattr(resp, "text", None)
        if isinstance(text, str) and text.strip():
            return text.strip()
    except Exception:
        pass
    # Fallback to REST via curl if available
    try:
        import json as _json
        import tempfile
        import shutil
        if shutil.which("curl") is None:
            return None
        url = "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-pro:generateContent?key=" + api_key
        payload = {
            "contents": [{"parts": [{"text": prompt}]}],
            "generationConfig": {"temperature": 0.3, "topP": 0.9}
        }
        p = sp.run(["curl", "-sS", "-X", "POST", url, "-H", "Content-Type: application/json",
                    "-d", _json.dumps(payload, ensure_ascii=False)],
                   stdout=sp.PIPE, stderr=sp.DEVNULL, check=False)
        data = p.stdout.decode("utf-8", errors="replace")
        if not data:
            return None
        obj = json.loads(data)
        # Typical path: candidates[0].content.parts[0].text
        cand = (obj.get("candidates") or [{}])[0]
        content = cand.get("content") or {}
        parts = content.get("parts") or []
        if parts and isinstance(parts[0], dict):
            text = parts[0].get("text")
            if isinstance(text, str) and text.strip():
                return text.strip()
    except Exception:
        return None
    return None


def main() -> int:
    if len(sys.argv) < 2:
        return 0
    msg_path = sys.argv[1]
    existing = _read_msg(msg_path)
    files, diff = _get_staged_summary()
    prompt = _compose_prompt(files, diff)
    suggestion = _call_gemini(prompt)
    if not suggestion:
        suggestion = _heuristic_suggestion(files)
        prefix = "AI-SUGGESTION (local):"
    else:
        prefix = "AI-SUGGESTION (Gemini):"

    # Append as plain lines (no Git comment prefix), so they真正进入提交正文
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    decorated = "\n" + prefix + f" {timestamp}\n" + suggestion.strip() + "\n"
    # Ensure file ends with newline
    if existing and not existing.endswith("\n"):
        existing += "\n"
    _write_msg(msg_path, (existing or "") + decorated)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
