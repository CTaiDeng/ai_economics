# SPDX-FileCopyrightText: 2026 GaoZheng
# SPDX-License-Identifier: MIT
# Full license: LICENSES/MIT.txt (repository root)

"""Integration checks using disposable Git repositories and a local bare remote.

Run with: python -B scripts/tests/test_commit_initial_batches.py
Requires Git and PowerShell 7. Includes isolated batching checks, real pre-commit
normalization, and runner checks under available PowerShell versions.
"""

import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "commit_initial_batches.ps1"
PWSH = shutil.which("pwsh")
GIT = shutil.which("git")
WINDOWS_POWERSHELL = shutil.which("powershell.exe")


@unittest.skipUnless(PWSH and GIT, "Git and PowerShell 7 are required")
class CommitInitialBatchesTests(unittest.TestCase):
    def setUp(self):
        self.temp_parent = Path(tempfile.gettempdir()).resolve()
        self.temp = tempfile.TemporaryDirectory(
            prefix="commit-batches-test-", dir=self.temp_parent
        )
        self.root = Path(self.temp.name).resolve()
        self.addCleanup(self.cleanup_repository)
        self.repo = self.root / "work"
        self.repo.mkdir()
        self.env = os.environ.copy()
        self.env.update(
            GIT_CONFIG_NOSYSTEM="1",
            GIT_CONFIG_GLOBAL=os.devnull,
            GIT_TERMINAL_PROMPT="0",
        )
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "Batch Test")
        self.git("config", "user.email", "batch-test@example.invalid")
        self.git("config", "commit.gpgSign", "false")
        self.git("config", "core.autocrlf", "false")
        self.git("config", "core.hooksPath", str(self.root / "no-hooks"))
        (self.repo / "scripts").mkdir()
        shutil.copy2(SCRIPT, self.repo / "scripts" / SCRIPT.name)
        (self.repo / ".git" / "info" / "exclude").write_text(
            "/scripts/\n", encoding="utf-8"
        )

    def cleanup_repository(self):
        # Validate the exact deletion boundary before TemporaryDirectory recurses.
        if self.root.parent != self.temp_parent or not self.root.name.startswith(
            "commit-batches-test-"
        ):
            raise RuntimeError(f"Unexpected test directory: {self.root}")
        self.temp.cleanup()

    def run_process(self, args, expected=0):
        result = subprocess.run(
            args, cwd=self.repo, env=self.env, capture_output=True,
            text=True, encoding="utf-8", errors="replace", timeout=60,
        )
        if expected is not None:
            self.assertEqual(
                result.returncode, expected, result.stdout + result.stderr
            )
        return result

    def git(self, *args, expected=0):
        return self.run_process([GIT, *args], expected=expected).stdout.strip()

    def run_batches(self, *args, expected=0, verify=False):
        return self.run_process(
            [PWSH, "-NoProfile", "-File",
             str(self.repo / "scripts" / SCRIPT.name),
             *([] if verify else ["-NoVerify"]), *args],
            expected=expected,
        )

    def install_real_precommit(self):
        source_root = SCRIPT.parent.parent
        governance_dir = self.repo / "scripts" / "pycache_customize"
        shutil.copytree(
            source_root / "scripts" / "pycache_customize", governance_dir,
            ignore=shutil.ignore_patterns("__pycache__", "*.pyc"),
        )
        shutil.copy2(
            source_root / "scripts" / "normalize_eol_and_encoding.py",
            self.repo / "scripts" / "normalize_eol_and_encoding.py",
        )
        config_path = governance_dir / "pycache_governance.json"
        config_path.write_text(json.dumps({
            "runtime_paths": {
                "workspace_root": "../..", "pycache_prefix": "out/pycache",
            },
            "python": {
                "executable": sys.executable,
                "required_version": platform.python_version(),
            },
            "policy": {"allow_external_prefix": False, "create_prefix": True},
        }) + "\n", encoding="utf-8", newline="\n")
        hooks_dir = self.repo / ".githooks"
        hooks_dir.mkdir()
        hook = hooks_dir / "pre-commit"
        shutil.copy2(source_root / ".githooks" / "pre-commit", hook)
        hook.chmod(0o755)
        with (self.repo / ".git" / "info" / "exclude").open("a", encoding="utf-8") as file:
            file.write("/.githooks/\n/out/\n")
        self.git("config", "core.hooksPath", ".githooks")
        self.env.update(
            PYCACHE_GOVERNANCE_CONFIG=str(config_path),
            PYTHONPYCACHEPREFIX=str(self.repo / "out" / "pycache"),
            PYTHONPATH=os.pathsep.join((str(governance_dir), str(self.repo))),
            PATH=str(Path(sys.executable).parent) + os.pathsep + self.env["PATH"],
        )
        return governance_dir / "run_python_with_config.ps1"

    def write(self, name, text="test\n"):
        (self.repo / name).write_text(text, encoding="utf-8")

    def add_remote(self):
        remote = self.root / "remote.git"
        self.git("init", "--bare", "-q", str(remote))
        self.git("-C", str(remote), "config", "core.logAllRefUpdates", "true")
        self.git("remote", "add", "origin", str(remote))
        return remote

    def make_initial_commit(self):
        self.write("existing.txt")
        self.git("add", "existing.txt")
        self.git("commit", "-q", "-m", "seed")

    def test_unborn_branch_with_staged_files_creates_and_pushes_batches(self):
        remote = self.add_remote()
        for name in ("first.txt", "second file.txt", "中文.txt"):
            self.write(name)
        self.git("add", "first.txt")

        result = self.run_batches("-BatchSize", "2")

        self.assertIn("All created commits were pushed successfully.", result.stdout)
        self.assertEqual(self.git("rev-list", "--count", "HEAD"), "2")
        self.assertEqual(
            self.git("-C", str(remote), "rev-parse", "refs/heads/main"),
            self.git("rev-parse", "HEAD"),
        )
        self.assertEqual(
            len(self.git("-C", str(remote), "reflog", "show", "--format=%H",
                         "refs/heads/main").splitlines()),
            2,
        )
        self.assertEqual(self.git("status", "--porcelain"), "")
        rerun = self.run_batches()
        self.assertIn("No pending files found.", rerun.stdout)
        self.assertIn("already contains commit", rerun.stdout)

    def test_unborn_dry_run_preserves_staged_content_and_worktree(self):
        self.write("staged.txt", "staged version\n")
        self.git("add", "staged.txt")
        self.write("staged.txt", "working version\n")
        self.write("untracked.txt")
        index_before = (self.repo / ".git" / "index").read_bytes()

        result = self.run_batches("-DryRun")

        self.assertIn("Found 2 pending file(s).", result.stdout)
        self.assertEqual((self.repo / ".git" / "index").read_bytes(), index_before)
        self.assertEqual(self.git("show", ":staged.txt"), "staged version")
        self.assertEqual((self.repo / "staged.txt").read_text(), "working version\n")
        self.git("rev-parse", "--verify", "--quiet", "HEAD", expected=1)

    def test_empty_unborn_repository_has_nothing_to_push(self):
        result = self.run_batches()
        self.assertIn("No local commits exist yet. Nothing to push.", result.stdout)
        self.git("rev-parse", "--verify", "--quiet", "HEAD", expected=1)

    def test_existing_branch_handles_staged_deletions_and_new_files(self):
        self.make_initial_commit()
        self.git("rm", "existing.txt")
        self.write("replacement.txt")
        self.git("add", "replacement.txt")
        index_before = (self.repo / ".git" / "index").read_bytes()

        result = self.run_batches("-DryRun", "-NoPush")
        self.assertIn("Found 2 pending file(s).", result.stdout)
        self.assertEqual((self.repo / ".git" / "index").read_bytes(), index_before)

        self.run_batches("-NoPush")
        self.assertEqual(self.git("rev-list", "--count", "HEAD"), "2")
        self.assertEqual(self.git("ls-tree", "--name-only", "HEAD"), "replacement.txt")
        self.assertEqual(self.git("status", "--porcelain"), "")

    def test_detached_head_requires_an_explicit_push_branch(self):
        self.make_initial_commit()
        self.git("checkout", "--detach", "-q")
        self.write("new.txt")

        result = self.run_batches(expected=None)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Cannot infer push branch from detached HEAD.", result.stderr)
        self.assertEqual(self.git("rev-list", "--count", "HEAD"), "1")

    def test_detached_head_accepts_an_explicit_push_branch(self):
        self.make_initial_commit()
        self.git("checkout", "--detach", "-q")
        self.write("new.txt")
        remote = self.add_remote()

        self.run_batches("-PushBranch", "published")

        self.assertEqual(
            self.git("-C", str(remote), "rev-parse", "refs/heads/published"),
            self.git("rev-parse", "HEAD"),
        )
        self.assertEqual(self.git("rev-list", "--count", "HEAD"), "2")

    def test_real_precommit_normalizes_and_restages_before_commit(self):
        self.install_real_precommit()
        document = self.repo / "资料 note.txt"
        document.write_bytes(b"\xef\xbb\xbfline one\r\nline two\r\n")
        self.git("add", "--", document.name)

        result = self.run_process([GIT, "commit", "-m", "hook normalization"])

        self.assertIn("[normalize] stats: changed 1 file(s)", result.stdout + result.stderr)
        expected = b"line one\nline two\n"
        self.assertEqual(document.read_bytes(), expected)
        committed = subprocess.check_output(
            [GIT, "show", "HEAD:" + document.name], cwd=self.repo, env=self.env,
        )
        self.assertEqual(committed, expected)
        self.assertEqual(self.git("status", "--porcelain"), "")

    def test_initial_batch_commit_with_real_normalization_and_hook(self):
        self.install_real_precommit()
        document = self.repo / "example.txt"
        document.write_bytes(b"\xef\xbb\xbfexample\r\n")
        self.git("add", document.name)
        self.env["GIT_TRACE"] = "1"

        result = self.run_batches("-NoPush", verify=True)

        self.assertIn("Normalizing staged EOL/encoding before commit...", result.stdout)
        self.assertIn(".githooks/pre-commit", result.stderr)
        self.assertIn("All batches committed successfully.", result.stdout)
        self.assertEqual(document.read_bytes(), b"example\n")
        self.assertEqual(self.git("rev-list", "--count", "HEAD"), "1")
        self.assertEqual(self.git("status", "--porcelain"), "")

    def test_governed_runner_preserves_python_environment_and_exit_codes(self):
        runner = self.install_real_precommit()
        shells = [PWSH]
        if WINDOWS_POWERSHELL:
            shells.append(WINDOWS_POWERSHELL)
        for shell in shells:
            with self.subTest(shell=shell):
                command = [shell, "-NoProfile", "-ExecutionPolicy", "Bypass",
                           "-File", str(runner), "-B", "-c"]
                result = self.run_process(command + [
                    "import json, sys; print(json.dumps({"
                    "'executable': sys.executable, 'prefix': sys.pycache_prefix}))"
                ])
                actual = json.loads(result.stdout)
                self.assertEqual(Path(actual["executable"]).resolve(), Path(sys.executable).resolve())
                self.assertEqual(Path(actual["prefix"]).resolve(), self.repo / "out" / "pycache")
                self.run_process(command + ["import sys; sys.exit(7)"], expected=7)


if __name__ == "__main__":
    unittest.main(verbosity=2)
