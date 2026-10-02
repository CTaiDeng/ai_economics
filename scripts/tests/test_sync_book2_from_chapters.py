# SPDX-FileCopyrightText: 2026 GaoZheng
# SPDX-License-Identifier: MIT
# Full license: LICENSES/MIT.txt (repository root)

"""Check that book synchronization writes only the combined Markdown document.

Run through scripts/pycache_customize/run_python_with_config.ps1 with -B.
All fixtures and synchronization outputs are confined to a temporary workspace.
"""

import hashlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = (Path(__file__).resolve().parents[2] / "docs" / "book" / "book1"
          / "sync_book2_from_chapters.ps1")
PWSH = shutil.which("pwsh")


@unittest.skipUnless(PWSH, "PowerShell 7 is required")
class BookSyncTests(unittest.TestCase):
    def setUp(self):
        self.temp_parent = Path(tempfile.gettempdir()).resolve()
        self.temp = tempfile.TemporaryDirectory(
            prefix="book-sync-test-", dir=self.temp_parent
        )
        self.root = Path(self.temp.name).resolve()
        self.addCleanup(self.cleanup_workspace)
        self.book_dir = self.root / "economics with spaces" / "docs" / "book" / "book1"
        self.book_dir.mkdir(parents=True)
        self.script = self.book_dir / SCRIPT.name
        shutil.copy2(SCRIPT, self.script)
        self.chapters = self.book_dir / "百转千回"
        self.combined = self.book_dir / "百转千回.md"
        self.external = self.root / "antigravity_project"
        expected = ["# 百转千回", ""]
        for volume in range(1, 11):
            volume_title = f"第{volume}卷 测试卷{volume}"
            directory = self.chapters / volume_title
            directory.mkdir(parents=True)
            expected.extend([f"## {volume_title}", ""])
            for chapter in range(1, 11):
                title = f"第{chapter}章：测试章{volume}-{chapter}"
                first = f"卷{volume}章{chapter}：原文 <保留> & 符号。"
                second = "第二段正文。"
                (directory / f"{title}.md").write_bytes(
                    f"# {title}\n\n{first}\n同段续行。\n\n{second}\n".encode("utf-8")
                )
                expected.extend([f"### {title}", "", first + "同段续行。", "", second, ""])
        self.expected = ("\n".join(expected).rstrip("\n") + "\n").encode("utf-8")
        self.first_chapter = next(self.chapters.rglob("*.md"))

    def cleanup_workspace(self):
        # Verify the deletion boundary before TemporaryDirectory removes fixtures.
        if self.root.parent != self.temp_parent or not self.root.name.startswith("book-sync-test-"):
            raise RuntimeError(f"Unexpected test workspace: {self.root}")
        self.temp.cleanup()

    def snapshot(self):
        return {
            path.relative_to(self.root): (
                hashlib.sha256(path.read_bytes()).hexdigest(), path.stat().st_mtime_ns
            )
            for path in self.root.rglob("*") if path.is_file()
        }

    def run_sync(self, *args, expected=0):
        result = subprocess.run(
            [PWSH, "-NoProfile", "-File", str(self.script), *args],
            cwd=self.root, capture_output=True, text=True, encoding="utf-8",
            errors="replace", timeout=60,
        )
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result

    def test_preview_check_create_and_noop_without_external_workspace(self):
        before = self.snapshot()
        self.run_sync("-Preview")
        self.assertEqual(self.snapshot(), before)
        self.run_sync("-Check", expected=1)
        self.assertEqual(self.snapshot(), before)

        self.run_sync()
        self.assertEqual(self.combined.read_bytes(), self.expected)
        after = self.snapshot()
        self.assertEqual(set(after) - set(before), {self.combined.relative_to(self.root)})
        for path, state in before.items():
            self.assertEqual(after[path], state)
        self.assertFalse(self.external.exists())

        self.run_sync("-Check")
        self.run_sync()
        self.assertEqual(self.snapshot(), after)

    def test_update_preserves_external_xml_and_other_files(self):
        xml_dir = self.external / "http_srv" / "xml"
        xml_dir.mkdir(parents=True)
        for name in ("book2_001.xml", "chat2.xml", "unrelated.xml"):
            (xml_dir / name).write_bytes(b"external sentinel: do not read or change")
        (self.book_dir / "小说命名表.json").write_bytes(b"{}\n")
        self.combined.write_bytes("# 旧合订本\n".encode("utf-8"))
        before = self.snapshot()

        self.run_sync("-Preview")
        self.run_sync("-Check", expected=1)
        self.assertEqual(self.snapshot(), before)
        self.run_sync()

        self.assertEqual(self.combined.read_bytes(), self.expected)
        after = self.snapshot()
        self.assertEqual(set(after), set(before))
        changed = {path for path in before if before[path] != after[path]}
        self.assertEqual(changed, {self.combined.relative_to(self.root)})

    def test_invalid_title_or_encoding_leaves_all_files_untouched(self):
        self.combined.write_bytes("# 保留旧稿\n".encode("utf-8"))
        original = self.first_chapter.read_bytes()
        invalid_sources = {
            "title mismatch": "# 不匹配的章名\n\n正文。\n".encode("utf-8"),
            "UTF-8 BOM": b"\xef\xbb\xbf" + original,
            "CRLF": original.replace(b"\n", b"\r\n"),
            "invalid UTF-8": original + b"\xff",
        }
        for name, content in invalid_sources.items():
            with self.subTest(name=name):
                self.first_chapter.write_bytes(content)
                before = self.snapshot()
                self.run_sync(expected=1)
                self.assertEqual(self.snapshot(), before)

    def test_missing_chapter_leaves_existing_book_untouched(self):
        self.combined.write_bytes("# 保留旧稿\n".encode("utf-8"))
        self.first_chapter.unlink()
        before = self.snapshot()
        self.run_sync(expected=1)
        self.assertEqual(self.snapshot(), before)

    def test_conflicting_modes_do_not_write(self):
        before = self.snapshot()
        self.run_sync("-Check", "-Preview", expected=1)
        self.assertEqual(self.snapshot(), before)


if __name__ == "__main__":
    unittest.main(verbosity=2)
