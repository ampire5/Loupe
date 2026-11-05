#!/usr/bin/env python3
"""Run with python3 scripts/test-kits-check.py; fixtures use only local Git repositories."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


class KitsCheckTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / "App"
        self.kit = self.root / "ExampleKit"
        for repo in (self.app, self.kit):
            repo.mkdir()
            self.git(repo, "init", "--quiet", "--initial-branch=main")
            self.git(repo, "config", "user.name", "Test User")
            self.git(repo, "config", "user.email", "test@example.invalid")
            self.git(repo, "commit", "--quiet", "--allow-empty", "-m", "Initial")
        (self.app / "scripts").mkdir()
        shutil.copyfile(Path(__file__).with_name("kits-check.py"), self.app / "scripts/kits-check.py")
        (self.app / "Package.swift").write_text('.package(url: "https://example.invalid/ExampleKit.git", from: "0.2.0")')
        self.old = self.git(self.kit, "rev-parse", "HEAD")
        self.git(self.kit, "tag", "0.1.0")
        self.git(self.kit, "commit", "--quiet", "--allow-empty", "-m", "Release")
        self.head = self.git(self.kit, "rev-parse", "HEAD")
        self.git(self.kit, "update-ref", "refs/remotes/origin/main", self.head)

    def git(self, repo, *args):
        return subprocess.check_output(["git", "-C", str(repo), *args], text=True).strip()

    def check(self, revision=None):
        pins = {"pins": [{"identity": "examplekit", "state": {"version": "0.2.0", "revision": revision or self.head}}]}
        (self.app / "Package.resolved").write_text(json.dumps(pins))
        return subprocess.run([sys.executable, str(self.app / "scripts/kits-check.py"), "--no-fetch"], text=True, capture_output=True)

    def test_numeric_tag(self):
        self.git(self.kit, "tag", "0.2.0")
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_prefixed_tag_is_also_the_latest_release(self):
        self.git(self.kit, "tag", "-a", "v0.2.0", "-m", "Release 0.2.0")
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("is released,", result.stdout)
        self.assertNotIn("not released:", result.stdout)

    def test_prefixed_tag_must_match_the_pinned_revision(self):
        self.git(self.kit, "tag", "v0.2.0", self.old)
        result = self.check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("Package.resolved pins", result.stdout)

    def test_a_branch_named_like_a_version_is_not_a_release(self):
        self.git(self.kit, "branch", "0.2.0")
        result = self.check()
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("not a tag", result.stdout)


if __name__ == "__main__":
    unittest.main()
