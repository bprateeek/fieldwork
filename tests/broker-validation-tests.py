#!/usr/bin/env python3
"""Broker validation smoke tests.

These tests run entirely in a temporary projects root. They do not contact
GitHub, do not need a broker socket, and do not use a real PAT.
"""

from __future__ import annotations

import importlib.util
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import unittest
import uuid
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class BrokerValidationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.tmp = Path(tempfile.mkdtemp(prefix="fieldwork-broker-tests."))
        cls.projects = cls.tmp / "projects"
        cls.ledger = cls.tmp / "ledger"
        cls.audit = cls.tmp / "audit.jsonl"
        cls.pending = cls.tmp / "pending"
        cls.fake_bin = cls.tmp / "bin"
        cls.projects.mkdir()
        cls.ledger.mkdir()
        cls.pending.mkdir()
        cls.fake_bin.mkdir()

        gitleaks = cls.fake_bin / "gitleaks"
        gitleaks.write_text(
            "#!/usr/bin/env bash\n"
            "if grep -R -q 'SECRET_SHAPED_TOKEN' \"${2:-}\" 2>/dev/null; then exit 1; fi\n"
            "exit 0\n"
        )
        gitleaks.chmod(0o755)

        os.environ["PATH"] = f"{cls.fake_bin}:{os.environ['PATH']}"
        os.environ["FIELDWORK_BROKER_COMMAND_PATH"] = os.environ["PATH"]
        os.environ["FIELDWORK_BROKER_PROJECTS_ROOT"] = str(cls.projects)
        os.environ["FIELDWORK_BROKER_LEDGER_DIR"] = str(cls.ledger)
        os.environ["FIELDWORK_BROKER_AUDIT_LOG_PATH"] = str(cls.audit)
        os.environ["FIELDWORK_BROKER_PENDING_DIR"] = str(cls.pending)
        os.environ["FIELDWORK_BROKER_SCHEMA_PATH"] = str(ROOT / "schema/pr-request.schema.json")
        os.environ["FIELDWORK_BROKER_LOG_PATH"] = str(cls.tmp / "broker.log")
        os.environ["FIELDWORK_BROKER_TOKEN_PATH"] = str(cls.tmp / "gh-token")
        os.environ["FIELDWORK_BROKER_ASKPASS_PATH"] = str(cls.tmp / "git-askpass")

        spec = importlib.util.spec_from_file_location("fieldwork_broker_server", ROOT / "lib/broker/server.py")
        assert spec and spec.loader
        cls.server = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = cls.server
        spec.loader.exec_module(cls.server)

    @classmethod
    def tearDownClass(cls) -> None:
        shutil.rmtree(cls.tmp)

    def setUp(self) -> None:
        self.server._recent_requests.clear()
        for item in self.ledger.glob("*.json"):
            item.unlink()
        for item in self.pending.glob("*"):
            item.unlink()
        gh = self.fake_bin / "gh"
        if gh.exists():
            gh.unlink()
        token = self.tmp / "gh-token"
        if token.exists():
            token.unlink()
        if self.audit.exists():
            self.audit.unlink()

    def git(self, *args: str, cwd: Path) -> None:
        subprocess.run(["git", *args], cwd=cwd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def write_fake_gh(self, body: str) -> None:
        gh = self.fake_bin / "gh"
        gh.write_text(body)
        gh.chmod(0o755)

    def make_repo(
        self,
        slug: str = "fieldwork-smoke",
        owner: str = "owner",
        repo: str = "fieldwork-smoke",
        expected_owner: str | None = None,
        expected_repo: str | None = None,
        origin_owner: str | None = None,
        origin_repo: str | None = None,
        missing_expected_origin: bool = False,
        dirty: bool = False,
    ) -> Path:
        path = self.projects / slug
        if path.exists():
            shutil.rmtree(path)
        path.mkdir()
        self.git("init", "-q", cwd=path)
        self.git("config", "user.email", "test@example.com", cwd=path)
        self.git("config", "user.name", "Fieldwork Test", cwd=path)
        (path / "README.md").write_text("hello\n")
        (path / ".claude").mkdir()
        (path / ".fieldwork").mkdir()
        if not missing_expected_origin:
            exp_owner = expected_owner or owner
            exp_repo = expected_repo or repo
            (path / ".fieldwork/expected-origin").write_text(f"https://github.com/{exp_owner}/{exp_repo}.git\n")
        remote_owner = origin_owner or owner
        remote_repo = origin_repo or repo
        self.git("remote", "add", "origin", f"git@github-{slug}:{remote_owner}/{remote_repo}.git", cwd=path)
        self.git("add", ".", cwd=path)
        self.git("commit", "-m", "init", cwd=path)
        if dirty:
            (path / "README.md").write_text("dirty\n")
        return path

    def request(self, path: Path, **overrides: object) -> dict:
        req = {
            "request_id": str(uuid.uuid4()),
            "created_at": "2026-05-11T10:30:00Z",
            "repo_path": str(path),
            "branch": "fieldwork/test-change",
            "title": "Test change",
            "body": "Summary:\n- Test broker validation.\n\nTests:\n- broker unit tests",
        }
        req.update(overrides)
        return req

    def audit_events(self) -> list[dict]:
        if not self.audit.exists():
            return []
        return [json.loads(line) for line in self.audit.read_text().splitlines() if line.strip()]

    def assert_rejects(self, req: object, expected: str) -> None:
        with self.assertRaises(self.server.RequestError) as ctx:
            self.server.validate(req)
        self.assertIn(expected, ctx.exception.message)

    def test_valid_request_accepted(self) -> None:
        repo = self.make_repo()
        validated = self.server.validate(self.request(repo))
        self.assertEqual(validated.owner, "owner")
        self.assertEqual(validated.repo, "fieldwork-smoke")
        self.assertEqual(validated.base_branch, "main")

    def test_default_branch_file_sets_pr_base(self) -> None:
        repo = self.make_repo()
        (repo / ".fieldwork/default-branch").write_text("trunk\n")
        self.git("add", ".fieldwork/default-branch", cwd=repo)
        self.git("commit", "-m", "set default branch", cwd=repo)
        validated = self.server.validate(self.request(repo))
        self.assertEqual(validated.base_branch, "trunk")

    def test_invalid_default_branch_file_rejected(self) -> None:
        repo = self.make_repo()
        (repo / ".fieldwork/default-branch").write_text("../main\n")
        self.git("add", ".fieldwork/default-branch", cwd=repo)
        self.git("commit", "-m", "set invalid default branch", cwd=repo)
        self.assert_rejects(self.request(repo), "default branch")

    def test_invalid_json_rejected_by_handler(self) -> None:
        left, right = socket.socketpair()
        thread = threading.Thread(target=self.server.handle, args=(right,))
        thread.start()
        left.sendall(b"{not-json")
        left.shutdown(socket.SHUT_WR)
        response = left.recv(4096).decode()
        thread.join(timeout=5)
        left.close()
        self.assertIn('"ok": false', response)
        self.assertIn("invalid JSON", response)

    def test_preflight_accepts_reachable_repo(self) -> None:
        (self.tmp / "gh-token").write_text("github_pat_test\n")
        self.write_fake_gh(
            "#!/usr/bin/env bash\n"
            "test \"$GH_TOKEN\" = github_pat_test\n"
            "printf '%s\\n' '{\"nameWithOwner\":\"owner/fieldwork-smoke\",\"defaultBranchRef\":{\"name\":\"main\"},\"visibility\":\"PRIVATE\"}'\n"
        )
        result = self.server.preflight({"repo": "owner/fieldwork-smoke"})
        self.assertEqual(result["repo"], "owner/fieldwork-smoke")
        self.assertEqual(result["defaultBranch"], "main")
        self.assertEqual(result["visibility"], "PRIVATE")

    def test_preflight_reports_missing_token(self) -> None:
        with self.assertRaises(self.server.RequestError) as ctx:
            self.server.preflight({"repo": "owner/fieldwork-smoke"})
        self.assertEqual(ctx.exception.status, 503)
        self.assertIn("PAT is not stored", ctx.exception.message)

    def test_preflight_reports_selected_repo_scope(self) -> None:
        (self.tmp / "gh-token").write_text("github_pat_test\n")
        self.write_fake_gh(
            "#!/usr/bin/env bash\n"
            "echo 'GraphQL: Could not resolve to a Repository with the name owner/fieldwork-smoke.' >&2\n"
            "exit 1\n"
        )
        with self.assertRaises(self.server.RequestError) as ctx:
            self.server.preflight({"repo": "owner/fieldwork-smoke"})
        self.assertEqual(ctx.exception.status, 404)
        self.assertIn("selected repositories", ctx.exception.message)

    def test_preflight_handler_routes_without_pr_validation(self) -> None:
        (self.tmp / "gh-token").write_text("github_pat_test\n")
        self.write_fake_gh(
            "#!/usr/bin/env bash\n"
            "printf '%s\\n' '{\"nameWithOwner\":\"owner/fieldwork-smoke\",\"defaultBranchRef\":{\"name\":\"main\"},\"visibility\":\"PRIVATE\"}'\n"
        )
        body = b'{"repo":"owner/fieldwork-smoke"}'
        req = (
            b"POST /preflight HTTP/1.1\r\n"
            b"Host: localhost\r\n"
            b"Content-Type: application/json\r\n"
            + f"Content-Length: {len(body)}\r\n\r\n".encode()
            + body
        )
        left, right = socket.socketpair()
        thread = threading.Thread(target=self.server.handle, args=(right,))
        thread.start()
        left.sendall(req)
        response = left.recv(4096).decode()
        thread.join(timeout=5)
        left.close()
        self.assertIn("HTTP/1.1 200 OK", response)
        self.assertIn('"ok": true', response)
        self.assertIn('"repo": "owner/fieldwork-smoke"', response)

    def test_missing_required_field_rejected(self) -> None:
        repo = self.make_repo()
        req = self.request(repo)
        del req["body"]
        self.assert_rejects(req, "missing required field: body")

    def test_unexpected_field_rejected(self) -> None:
        repo = self.make_repo()
        self.assert_rejects(self.request(repo, extra="nope"), "unexpected field: extra")

    def test_invalid_request_id_rejected(self) -> None:
        repo = self.make_repo()
        self.assert_rejects(self.request(repo, request_id="not-a-uuid"), "request_id")

    def test_invalid_created_at_rejected(self) -> None:
        repo = self.make_repo()
        self.assert_rejects(self.request(repo, created_at="2026-05-11 10:30:00"), "created_at")

    def test_repo_outside_projects_root_rejected(self) -> None:
        repo = self.make_repo()
        req = self.request(repo, repo_path="/tmp/fieldwork-smoke")
        self.assert_rejects(req, "repo_path")

    def test_branch_main_rejected(self) -> None:
        repo = self.make_repo()
        self.assert_rejects(self.request(repo, branch="main"), "branch")

    def test_branch_not_under_prefix_rejected(self) -> None:
        repo = self.make_repo()
        self.assert_rejects(self.request(repo, branch="feature/test"), "branch")

    def test_branch_prefix_is_configurable(self) -> None:
        repo = self.make_repo()
        # The default prefix is "fieldwork"; a "claude/" branch is now rejected
        # unless FIELDWORK_BROKER_BRANCH_PREFIX is overridden.
        self.assert_rejects(self.request(repo, branch="claude/test"), "branch")

    def test_title_with_newline_rejected(self) -> None:
        repo = self.make_repo()
        self.assert_rejects(self.request(repo, title="Bad\ntitle"), "title")

    def test_oversized_body_rejected(self) -> None:
        repo = self.make_repo()
        self.assert_rejects(self.request(repo, body="x" * (64 * 1024 + 1)), "body")

    def test_missing_expected_origin_rejected(self) -> None:
        repo = self.make_repo(missing_expected_origin=True)
        self.assert_rejects(self.request(repo), "missing .fieldwork/expected-origin")

    def test_empty_expected_origin_rejected(self) -> None:
        repo = self.make_repo()
        (repo / ".fieldwork/expected-origin").write_text("")
        self.git("add", ".fieldwork/expected-origin", cwd=repo)
        self.git("commit", "-m", "empty expected origin", cwd=repo)
        self.assert_rejects(self.request(repo), "expected-origin is empty")

    def test_dirty_worktree_rejected(self) -> None:
        repo = self.make_repo(dirty=True)
        self.assert_rejects(self.request(repo), "worktree not clean")

    def test_origin_spoofing_rejected(self) -> None:
        repo = self.make_repo(expected_owner="attacker", expected_repo="target")
        self.assert_rejects(self.request(repo), "origin remote does not match")

    def test_secret_shaped_body_rejected(self) -> None:
        repo = self.make_repo()
        self.assert_rejects(self.request(repo, body="SECRET_SHAPED_TOKEN"), "secret-shaped")

    def test_replay_request_id_rejected(self) -> None:
        repo = self.make_repo()
        validated = self.server.validate(self.request(repo))
        self.server.reserve_request_id(validated)
        with self.assertRaises(self.server.RequestError) as ctx:
            self.server.reserve_request_id(validated)
        self.assertEqual(ctx.exception.status, 409)
        self.assertIn("duplicate request_id", ctx.exception.message)

    def test_rate_limit_rejected(self) -> None:
        repo_key = "owner/fieldwork-smoke"
        for _ in range(self.server.RATE_LIMIT_PER_HOUR):
            self.server.rate_limit(repo_key)
        with self.assertRaises(self.server.RequestError) as ctx:
            self.server.rate_limit(repo_key)
        self.assertEqual(ctx.exception.status, 429)
        self.assertIn("rate limit hit", ctx.exception.message)

    def test_workflow_push_error_is_actionable(self) -> None:
        err = subprocess.CalledProcessError(
            1,
            ["git", "push"],
            stderr=(
                b"refusing to allow a Personal Access Token to create or update workflow "
                b"'.github/workflows/ci.yml' without 'workflow' scope"
            ),
        )
        message = self.server.broker_subprocess_error_message(err)
        self.assertIn("Workflows read/write", message)
        self.assertIn("--no-workflows", message)

    def test_pr_permission_error_is_actionable(self) -> None:
        err = subprocess.CalledProcessError(
            1,
            ["gh", "pr", "create"],
            stderr="HTTP 403: Resource not accessible by personal access token",
        )
        message = self.server.broker_subprocess_error_message(err)
        self.assertIn("Pull requests read/write", message)

    def enable_gate(self, path: Path) -> None:
        (path / ".fieldwork/approval-gate").write_text("")
        self.git("add", ".fieldwork/approval-gate", cwd=path)
        self.git("commit", "-m", "enable approval gate", cwd=path)

    def test_queued_when_approval_gate_present(self) -> None:
        repo = self.make_repo()
        self.enable_gate(repo)

        req = self.request(repo)
        body = json.dumps(req).encode()
        http = (
            b"POST /pr HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n"
            + f"Content-Length: {len(body)}\r\n\r\n".encode()
            + body
        )
        left, right = socket.socketpair()
        thread = threading.Thread(target=self.server.handle, args=(right, "agent"))
        thread.start()
        left.sendall(http)
        response = left.recv(8192).decode()
        thread.join(timeout=5)
        left.close()

        self.assertIn("HTTP/1.1 200 OK", response)
        self.assertIn('"ok": true', response)
        self.assertIn('"queued": true', response)
        self.assertIn('"expires_at"', response)

        pending_files = list(self.pending.glob("*.json"))
        self.assertEqual(len(pending_files), 1, f"expected 1 pending file, got {pending_files}")
        record = json.loads(pending_files[0].read_text())
        self.assertEqual(record["request_id"], req["request_id"])
        self.assertEqual(record["branch"], req["branch"])
        self.assertEqual(record["repo"], "owner/fieldwork-smoke")

        ledger_files = list(self.ledger.glob("*.json"))
        self.assertEqual(len(ledger_files), 1, "ledger entry must be reserved at queue time")
        events = self.audit_events()
        self.assertIn("request_received", [event["event"] for event in events])
        self.assertIn("request_queued", [event["event"] for event in events])
        queued = [event for event in events if event["event"] == "request_queued"][-1]
        self.assertEqual(queued["repo"], "owner/fieldwork-smoke")
        self.assertEqual(queued["repo_path_slug"], "fieldwork-smoke")
        self.assertNotIn("body", queued)

    def test_duplicate_branch_request_rejected_while_pending(self) -> None:
        repo = self.make_repo()
        self.enable_gate(repo)

        def post_pr(req: dict) -> str:
            body = json.dumps(req).encode()
            http = (
                b"POST /pr HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n"
                + f"Content-Length: {len(body)}\r\n\r\n".encode()
                + body
            )
            left, right = socket.socketpair()
            thread = threading.Thread(target=self.server.handle, args=(right, "agent"))
            thread.start()
            left.sendall(http)
            response = left.recv(8192).decode()
            thread.join(timeout=5)
            left.close()
            return response

        first = self.request(repo)
        self.assertIn('"queued": true', post_pr(first))

        # A re-submit for the same branch (fresh request_id) must be rejected
        # while the first is still pending, instead of queuing a duplicate.
        second = self.request(repo)
        self.assertNotEqual(second["request_id"], first["request_id"])
        second_resp = post_pr(second)
        self.assertIn("HTTP/1.1 409 ERROR", second_resp)
        self.assertIn('"already_pending": true', second_resp)
        self.assertIn(first["request_id"], second_resp)

        pending_files = list(self.pending.glob("*.json"))
        self.assertEqual(len(pending_files), 1, f"expected 1 pending file, got {pending_files}")

    def test_approve_route_pushes_and_clears_pending(self) -> None:
        repo = self.make_repo()
        self.enable_gate(repo)
        validated = self.server.validate(self.request(repo))
        self.server.reserve_request_id(validated)
        self.server.queue_pending(validated)

        push_calls: list[list[str]] = []

        def fake_push_and_open_pr(req: object) -> str:
            push_calls.append(["push_and_open_pr", req.request_id])
            return "https://github.com/owner/fieldwork-smoke/pull/1"

        original = self.server.push_and_open_pr
        self.server.push_and_open_pr = fake_push_and_open_pr
        try:
            result = self.server.approve({
                "request_id": validated.request_id,
                "decision": "approve",
            })
        finally:
            self.server.push_and_open_pr = original

        self.assertEqual(result["url"], "https://github.com/owner/fieldwork-smoke/pull/1")
        self.assertEqual(result["decision"], "approve")
        self.assertEqual(len(push_calls), 1)
        self.assertEqual(list(self.pending.glob("*.json")), [])
        events = self.audit_events()
        self.assertIn("request_approved", [event["event"] for event in events])

    def test_approve_route_deny_removes_pending(self) -> None:
        repo = self.make_repo()
        self.enable_gate(repo)
        validated = self.server.validate(self.request(repo))
        self.server.reserve_request_id(validated)
        self.server.queue_pending(validated)
        self.assertEqual(len(list(self.pending.glob("*.json"))), 1)

        result = self.server.approve({
            "request_id": validated.request_id,
            "decision": "deny",
        })
        self.assertEqual(result["decision"], "deny")
        self.assertEqual(list(self.pending.glob("*.json")), [])
        events = self.audit_events()
        self.assertIn("request_denied", [event["event"] for event in events])

        # Ledger entry persists. Denied request_id cannot be replayed.
        ledger_files = list(self.ledger.glob("*.json"))
        self.assertEqual(len(ledger_files), 1)

    def test_approve_route_rejected_on_agent_socket(self) -> None:
        body = b'{"request_id":"deadbeef-dead-4dad-bdad-deadbeefdead","decision":"approve"}'
        http = (
            b"POST /approve HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n"
            + f"Content-Length: {len(body)}\r\n\r\n".encode()
            + body
        )
        left, right = socket.socketpair()
        thread = threading.Thread(target=self.server.handle, args=(right, "agent"))
        thread.start()
        left.sendall(http)
        response = left.recv(8192).decode()
        thread.join(timeout=5)
        left.close()

        self.assertIn("HTTP/1.1 404", response)
        self.assertIn("/approve is only available on the approve socket", response)

    def test_pr_route_rejected_on_approve_socket(self) -> None:
        body = b'{"repo":"owner/repo"}'
        http = (
            b"POST /pr HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n"
            + f"Content-Length: {len(body)}\r\n\r\n".encode()
            + body
        )
        left, right = socket.socketpair()
        thread = threading.Thread(target=self.server.handle, args=(right, "approve"))
        thread.start()
        left.sendall(http)
        response = left.recv(8192).decode()
        thread.join(timeout=5)
        left.close()

        self.assertIn("HTTP/1.1 404", response)
        self.assertIn("approve socket only serves /approve", response)

    def test_approve_unknown_request_id_404(self) -> None:
        with self.assertRaises(self.server.RequestError) as ctx:
            self.server.approve({
                "request_id": "deadbeef-dead-4dad-bdad-deadbeefdead",
                "decision": "approve",
            })
        self.assertEqual(ctx.exception.status, 404)
        self.assertIn("no pending request", ctx.exception.message)

    def test_approve_rejects_invalid_decision(self) -> None:
        with self.assertRaises(self.server.RequestError) as ctx:
            self.server.approve({
                "request_id": "deadbeef-dead-4dad-bdad-deadbeefdead",
                "decision": "maybe",
            })
        self.assertIn("decision must be", ctx.exception.message)

    def test_expiry_sweep_drops_old_pending(self) -> None:
        repo = self.make_repo()
        self.enable_gate(repo)
        validated = self.server.validate(self.request(repo))
        self.server.reserve_request_id(validated)
        self.server.queue_pending(validated)

        # Rewrite queued_at to be older than the expiry window.
        pending_file = self.pending / f"{validated.request_id}.json"
        record = json.loads(pending_file.read_text())
        record["queued_at"] = "2020-01-01T00:00:00Z"
        pending_file.write_text(json.dumps(record))

        dropped = self.server.sweep_expired_pending()
        self.assertEqual(dropped, 1)
        self.assertEqual(list(self.pending.glob("*.json")), [])
        self.assertIn("request_expired", [event["event"] for event in self.audit_events()])

        # Replay protection survives expiry. Same request_id is rejected.
        with self.assertRaises(self.server.RequestError) as ctx:
            self.server.reserve_request_id(validated)
        self.assertEqual(ctx.exception.status, 409)

    def test_expired_pending_rejected_on_approve(self) -> None:
        repo = self.make_repo()
        self.enable_gate(repo)
        validated = self.server.validate(self.request(repo))
        self.server.reserve_request_id(validated)
        self.server.queue_pending(validated)

        pending_file = self.pending / f"{validated.request_id}.json"
        record = json.loads(pending_file.read_text())
        record["queued_at"] = "2020-01-01T00:00:00Z"
        pending_file.write_text(json.dumps(record))

        with self.assertRaises(self.server.RequestError) as ctx:
            self.server.approve({
                "request_id": validated.request_id,
                "decision": "approve",
            })
        self.assertEqual(ctx.exception.status, 410)
        self.assertEqual(list(self.pending.glob("*.json")), [])

    def test_non_gated_repo_still_pushes_immediately(self) -> None:
        repo = self.make_repo(slug="ungated-smoke")
        validated = self.server.validate(self.request(repo))
        # No .fieldwork/approval-gate present.
        self.assertFalse(self.server.approval_gate_enabled(str(repo)))
        self.assertEqual(list(self.pending.glob("*.json")), [])

    def _run_push_with_subprocess_stub(self, gh_edit_returncode: int = 0,
                                       gh_edit_stderr: bytes = b"") -> tuple[str, list[list[str]]]:
        """Drive push_and_open_pr with subprocess.run stubbed.

        Returns (pr_url, recorded_calls). The stub answers in order:
        - git push  -> ok
        - gh pr create -> stdout = "https://github.com/owner/repo/pull/42\n"
        - gh pr edit --add-label -> exit code per gh_edit_returncode
        Anything else is recorded but unmocked is a test bug.
        """
        repo = self.make_repo()
        (self.tmp / "gh-token").write_text("github_pat_test\n")
        validated = self.server.validate(self.request(repo))

        calls: list[list[str]] = []
        from unittest.mock import patch

        def fake_run(argv, *args, **kwargs):
            calls.append(list(argv))
            class _R:
                returncode = 0
                stdout = ""
                stderr = ""
            r = _R()
            # git push: ok
            if argv[:2] == ["git", "-C"] and "push" in argv:
                return r
            # gh pr create
            if argv[:3] == ["gh", "pr", "create"]:
                r.stdout = "https://github.com/owner/fieldwork-smoke/pull/42\n"
                r.returncode = 0
                return r
            # gh pr edit ... --add-label
            if argv[:3] == ["gh", "pr", "edit"]:
                if gh_edit_returncode != 0:
                    raise subprocess.CalledProcessError(
                        returncode=gh_edit_returncode,
                        cmd=argv,
                        output=b"",
                        stderr=gh_edit_stderr,
                    )
                return r
            raise AssertionError(f"unexpected subprocess.run call: {argv}")

        with patch.object(self.server.subprocess, "run", side_effect=fake_run):
            pr_url = self.server.push_and_open_pr(validated)
        return pr_url, calls

    def test_push_applies_ready_for_review_label(self) -> None:
        pr_url, calls = self._run_push_with_subprocess_stub()
        self.assertEqual(pr_url, "https://github.com/owner/fieldwork-smoke/pull/42")
        creates = [c for c in calls if c[:3] == ["gh", "pr", "create"]]
        self.assertEqual(len(creates), 1)
        base_index = creates[0].index("--base")
        self.assertEqual(creates[0][base_index + 1], "main")
        edits = [c for c in calls if c[:3] == ["gh", "pr", "edit"]]
        self.assertEqual(len(edits), 1, f"expected one gh pr edit call, got: {edits}")
        edit = edits[0]
        self.assertIn(pr_url, edit)
        self.assertIn("--add-label", edit)
        self.assertIn("ready for review", edit)
        events = self.audit_events()
        names = [event["event"] for event in events]
        self.assertIn("push_attempted", names)
        self.assertIn("pr_opened", names)
        opened = [event for event in events if event["event"] == "pr_opened"][-1]
        self.assertEqual(opened["pr_url"], pr_url)

    def test_push_succeeds_when_label_apply_fails(self) -> None:
        # gh pr edit returns nonzero (e.g. label not defined on the repo).
        # push_and_open_pr must still return the PR url; label is non-fatal.
        pr_url, calls = self._run_push_with_subprocess_stub(
            gh_edit_returncode=1,
            gh_edit_stderr=b"label 'ready for review' not found\n",
        )
        self.assertEqual(pr_url, "https://github.com/owner/fieldwork-smoke/pull/42")
        # The label call was still attempted.
        self.assertTrue(any(c[:3] == ["gh", "pr", "edit"] for c in calls))

    def test_notify_lifecycle_writes_versioned_envelope(self) -> None:
        notifications = self.tmp / "notifications"
        notifications.mkdir(exist_ok=True)
        for item in notifications.glob("*"):
            item.unlink()
        saved = (
            self.server.NOTIFICATIONS_DIR,
            self.server.NOTIFY_LIFECYCLE_RAW,
            self.server.NOTIFY_ON_PR_OPENED,
        )
        self.server.NOTIFICATIONS_DIR = str(notifications)
        self.server.NOTIFY_LIFECYCLE_RAW = "1"
        self.server.NOTIFY_ON_PR_OPENED = False
        try:
            self.server.notify_lifecycle(
                "request_queued",
                repo_slug_value="fieldwork-smoke",
                request_id="11111111-1111-4111-8111-111111111111",
                branch="fieldwork/test",
            )
        finally:
            (
                self.server.NOTIFICATIONS_DIR,
                self.server.NOTIFY_LIFECYCLE_RAW,
                self.server.NOTIFY_ON_PR_OPENED,
            ) = saved

        drops = list(notifications.glob("*.json"))
        self.assertEqual(len(drops), 1)
        payload = json.loads(drops[0].read_text())
        self.assertEqual(payload["schema"], 1)
        self.assertEqual(payload["kind"], "broker_lifecycle")
        self.assertEqual(payload["source"], "broker")
        self.assertEqual(payload["event"], "request_queued")
        self.assertEqual(payload["repo_slug"], "fieldwork-smoke")
        self.assertEqual(payload["request_id"], "11111111-1111-4111-8111-111111111111")
        self.assertEqual(payload["branch"], "fieldwork/test")
        self.assertIn("dedupe_key", payload)
        rendered = json.dumps(payload)
        self.assertNotIn("github_pat_", rendered)
        self.assertNotIn("ghp_", rendered)

    def test_runs_with_neutral_user_and_arbitrary_projects_root(self) -> None:
        # The whole test class already runs the broker module with a tmpdir
        # projects root and no privileged identities. This is the standalone
        # broker mode in microcosm. Lock that in: validation must accept a
        # request whose repo_path is under the arbitrary projects root the
        # broker was configured with at import time, and the runtime regex
        # must reflect that root rather than the /home/fieldwork default.
        self.assertNotEqual(self.server.PROJECTS_ROOT, "/home/fieldwork/projects")
        self.assertTrue(
            self.server.REPO_PATH_RE.pattern.startswith("^"),
            "REPO_PATH_RE must be anchored at start"
        )
        import re as _re
        self.assertIn(_re.escape(str(self.projects)), self.server.REPO_PATH_RE.pattern)
        repo = self.make_repo(slug="standalone-smoke")
        validated = self.server.validate(self.request(repo))
        self.assertTrue(str(validated.repo_path).startswith(str(self.projects)))


class AuditLogRotationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.tmp = Path(tempfile.mkdtemp(prefix="fieldwork-audit-rotate."))
        os.environ["FIELDWORK_BROKER_LOG_PATH"] = str(cls.tmp / "broker.log")
        os.environ["FIELDWORK_BROKER_AUDIT_LOG_PATH"] = str(cls.tmp / "audit.jsonl")
        spec = importlib.util.spec_from_file_location(
            "fieldwork_broker_server_rotation", ROOT / "lib/broker/server.py"
        )
        assert spec and spec.loader
        cls.server = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = cls.server
        spec.loader.exec_module(cls.server)

    @classmethod
    def tearDownClass(cls) -> None:
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_audit_log_rotates_by_size(self) -> None:
        tmp = self.tmp / "rotate"
        tmp.mkdir(parents=True, exist_ok=True)
        audit = tmp / "audit.jsonl"

        srv = self.server
        saved = (srv.AUDIT_LOG_PATH, srv.AUDIT_LOG_MAX_BYTES, srv.AUDIT_LOG_BACKUPS)
        srv.AUDIT_LOG_PATH = str(audit)
        srv.AUDIT_LOG_MAX_BYTES = 200
        srv.AUDIT_LOG_BACKUPS = 2
        try:
            for _ in range(50):
                srv.audit_event(
                    "request_received", request_id="x" * 20, branch="fieldwork/rotate"
                )
        finally:
            srv.AUDIT_LOG_PATH, srv.AUDIT_LOG_MAX_BYTES, srv.AUDIT_LOG_BACKUPS = saved

        self.assertTrue(audit.exists(), "active audit log must exist after rotation")
        self.assertTrue((tmp / "audit.jsonl.1").exists(), "expected a rotated backup")
        self.assertFalse(
            (tmp / "audit.jsonl.3").exists(),
            "backups must be capped at AUDIT_LOG_BACKUPS",
        )
        self.assertEqual(audit.stat().st_mode & 0o777, 0o640)
        self.assertEqual((tmp / "audit.jsonl.1").stat().st_mode & 0o777, 0o640)


if __name__ == "__main__":
    unittest.main()
