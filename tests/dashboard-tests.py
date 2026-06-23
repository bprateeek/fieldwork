#!/usr/bin/env python3
"""Tests for the read-only Fieldwork dashboard helpers."""

from __future__ import annotations

import importlib.machinery
import importlib.util
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SNAPSHOT = ROOT / "lib/scripts/fieldwork-status-snapshot"
DASHBOARD = ROOT / "lib/scripts/fieldwork-dashboard-server"


def load_dashboard_module():
    loader = importlib.machinery.SourceFileLoader("fieldwork_dashboard_server", str(DASHBOARD))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    assert spec is not None
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class DashboardTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="fieldwork-dashboard."))
        self.home = self.tmp / "home"
        self.projects = self.home / "projects"
        self.state = self.home / ".fieldwork/state"
        self.events = self.state / "events"
        self.resume = self.state / "resume-context"
        self.journals = self.home / ".fieldwork/project-journals"
        self.audit = self.tmp / "audit.jsonl"
        for path in (self.projects, self.events, self.resume, self.journals):
            path.mkdir(parents=True, exist_ok=True)
        repo = self.projects / "demo"
        (repo / ".git").mkdir(parents=True)

    def tearDown(self) -> None:
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_snapshot(self) -> dict:
        env = os.environ.copy()
        env.update({
            "HOME": str(self.home),
            "FIELDWORK_PROJECTS_ROOT": str(self.projects),
            "FIELDWORK_EVENT_STATE_DIR": str(self.state),
            "FIELDWORK_JOURNAL_DIR": str(self.journals),
            "FIELDWORK_BROKER_AUDIT_LOG_PATH": str(self.audit),
        })
        out = subprocess.run([str(SNAPSHOT)], env=env, check=True, text=True, stdout=subprocess.PIPE).stdout
        return json.loads(out)

    def test_snapshot_reads_state_journal_and_audit_without_rendering(self) -> None:
        branch = 'fieldwork/<script>alert("x")</script>'
        (self.events / "demo.json").write_text(json.dumps({
            "schema_version": 1,
            "repo_slug": "demo",
            "worktrees": {
                "/home/fieldwork/worktrees/demo-change": {
                    "branch": branch,
                    "rev": "abcdef1234567890",
                    "dirty_count": 1,
                },
            },
            "prs": {},
            "last_throttled_checks": {"fieldwork/x:pr_state": "2026-06-23T12:00:00Z"},
        }))
        (self.resume / "demo.md").write_text("resume context\n")
        hostile_line = "<img src=x onerror=alert(1)>"
        (self.journals / "demo.md").write_text(f"older\n{hostile_line}\n")
        self.audit.write_text(
            json.dumps({
                "ts": "2026-06-23T12:00:00Z",
                "event": "pr_opened",
                "repo_path_slug": "demo",
                "branch": branch,
                "base_branch": "main",
                "pr_url": "https://github.com/example/demo/pull/4",
            })
            + "\n"
        )

        snapshot = self.run_snapshot()

        self.assertTrue(snapshot["audit_readable"])
        self.assertEqual(snapshot["projects_root"], str(self.projects))
        repo = snapshot["repos"][0]
        self.assertEqual(repo["slug"], "demo")
        self.assertTrue(repo["state_present"])
        self.assertTrue(repo["resume_context_present"])
        self.assertIn(hostile_line, repo["journal_tail"])
        self.assertEqual(repo["latest_audit_event"]["branch"], branch)
        self.assertEqual(
            repo["worktrees"]["/home/fieldwork/worktrees/demo-change"]["branch"],
            branch,
        )

    def test_dashboard_handler_is_get_only_and_uses_safe_dom_api(self) -> None:
        fake_snapshot = self.tmp / "fake-snapshot"
        fake_snapshot.write_text(
            "#!/usr/bin/env python3\n"
            "import json\n"
            "print(json.dumps({'schema_version': 1, 'generated_at': '2026-06-23T12:00:00Z', 'repos': []}))\n"
        )
        fake_snapshot.chmod(0o755)

        module = load_dashboard_module()
        module.SNAPSHOT = str(fake_snapshot)

        def call(path: str, method: str = "GET") -> tuple[int, str, bytes]:
            handler = module.DashboardHandler.__new__(module.DashboardHandler)
            handler.path = path
            captured: list[tuple[int, str, bytes]] = []
            handler.send_bytes = lambda status, content_type, body: captured.append((status, content_type, body))
            if method == "GET":
                handler.do_GET()
            elif method == "POST":
                handler.do_POST()
            else:
                raise AssertionError(method)
            self.assertEqual(len(captured), 1)
            return captured[0]

        status, content_type, body = call("/api/status")
        self.assertEqual(status, 200)
        self.assertEqual(content_type, "application/json; charset=utf-8")
        payload = json.loads(body.decode("utf-8"))
        self.assertEqual(payload["schema_version"], 1)

        status, content_type, body = call("/")
        self.assertEqual(status, 200)
        self.assertEqual(content_type, "text/html; charset=utf-8")
        html = body.decode("utf-8")
        self.assertIn("replaceChildren", html)
        self.assertIn("textContent", html)
        self.assertNotIn("innerHTML", html)

        status, content_type, body = call("/api/status", method="POST")
        self.assertEqual(status, 405)
        self.assertEqual(content_type, "application/json; charset=utf-8")
        self.assertEqual(json.loads(body.decode("utf-8"))["error"], "GET only")


if __name__ == "__main__":
    unittest.main()
