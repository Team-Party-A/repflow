import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from ci_scope import needs_checks


class ScopeTest(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        previous = Path.cwd()
        os.chdir(directory.name)
        self.addCleanup(os.chdir, previous)
        self.git("init", "-q")
        self.git("config", "user.name", "CI scope test")
        self.git("config", "user.email", "ci@example.invalid")
        self.write("apps/apple/example.swift")
        self.base = self.commit()

    @staticmethod
    def git(*args):
        return subprocess.check_output(["git", *args], text=True).strip()

    @staticmethod
    def write(name):
        path = Path(name)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("fixture\n", encoding="utf-8")

    def commit(self):
        self.git("add", "--all")
        self.git("commit", "-qm", "test fixture")
        return self.git("rev-parse", "HEAD")

    def test_docs_only_pr_skips_both(self):
        self.write("docs/说明\n换行.md")
        head = self.commit()
        event = {"pull_request": {"base": {"sha": self.base}}}
        for module in ("apple", "backend"):
            self.assertFalse(needs_checks(module, "pull_request", event, head))

    def test_merge_group_checks_combined_tree_including_renames(self):
        Path("apps/apple/example.swift").rename("moved.swift")
        self.commit()
        self.write("deploy/example.conf")
        head = self.commit()
        for module in ("apple", "backend"):
            self.assertTrue(
                needs_checks(
                    module,
                    "merge_group",
                    {"merge_group": {"base_sha": self.base}},
                    head,
                )
            )

    def test_backend_change_and_shared_workflow_logic(self):
        self.write("backend/example.py")
        head = self.commit()
        event = {"before": self.base}
        self.assertTrue(needs_checks("backend", "push", event, head))
        self.assertFalse(needs_checks("apple", "push", event, head))
        self.write("scripts/ci_scope.py")
        next_head = self.commit()
        for module in ("apple", "backend"):
            self.assertTrue(needs_checks(module, "push", {"before": head}, next_head))

    def test_first_push_runs_checks_and_wrong_checkout_fails(self):
        self.assertTrue(
            needs_checks("backend", "push", {"before": "0" * 40}, self.base)
        )
        with self.assertRaises(ValueError):
            needs_checks("backend", "push", {"before": self.base}, "1" * 40)
