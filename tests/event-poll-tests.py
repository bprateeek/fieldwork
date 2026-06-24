#!/usr/bin/env python3
"""Tests for fieldwork-event-poll.

The poller is a shipped Bash script with Python internals. These tests drive
the real executable against temporary Git repos and linked worktrees; no GitHub
network calls are made.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
POLLER = ROOT / "lib/scripts/fieldwork-event-poll"


class EventPollTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="fieldwork-event-poll."))
        self.home = self.tmp / "home"
        self.projects = self.home / "projects"
        self.worktrees = self.home / "worktrees"
        self.notifications = self.tmp / "notifications"
        self.fake_bin = self.tmp / "bin"
        self.audit = self.tmp / "audit.jsonl"
        self.home.mkdir()
        self.projects.mkdir(parents=True)
        self.worktrees.mkdir()
        self.notifications.mkdir()
        self.fake_bin.mkdir()
        self._write_fake_gh()

    def tearDown(self) -> None:
        shutil.rmtree(self.tmp, ignore_errors=True)

    def git(self, *args: str, cwd: Path) -> None:
        subprocess.run(["git", *args], cwd=cwd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def make_repo(self, slug: str = "event-repo", with_default_branch: bool = True) -> tuple[Path, Path]:
        repo = self.projects / slug
        repo.mkdir()
        self.git("init", "-q", "-b", "main", cwd=repo)
        self.git("config", "user.email", "test@example.com", cwd=repo)
        self.git("config", "user.name", "Fieldwork Test", cwd=repo)
        (repo / ".fieldwork").mkdir()
        if with_default_branch:
            (repo / ".fieldwork/default-branch").write_text("main\n")
        (repo / "CLAUDE.md").write_text("Repo guidance\n")
        (repo / "REVIEW.md").write_text("Review checklist\n")
        (repo / "README.md").write_text("hello\n")
        self.git("add", ".", cwd=repo)
        self.git("commit", "-q", "-m", "init", cwd=repo)
        linked = self.worktrees / f"{slug}-change"
        self.git("worktree", "add", "-q", "-b", "fieldwork/test", str(linked), cwd=repo)
        (linked / "feature.txt").write_text("feature\n")
        self.git("add", "feature.txt", cwd=linked)
        self.git("commit", "-q", "-m", "add feature", cwd=linked)
        return repo, linked

    def add_worktree(self, repo: Path, slug: str, name: str, branch: str) -> Path:
        linked = self.worktrees / f"{slug}-{name}"
        self.git("worktree", "add", "-q", "-b", branch, str(linked), cwd=repo)
        (linked / f"{name}.txt").write_text(f"{name}\n")
        self.git("add", f"{name}.txt", cwd=linked)
        self.git("commit", "-q", "-m", f"add {name}", cwd=linked)
        return linked

    def _write_fake_gh(self) -> None:
        gh = self.fake_bin / "gh"
        gh.write_text(
            "#!/usr/bin/env bash\n"
            "printf '%s\\n' \"$*\" >> \"$FAKE_GH_LOG\"\n"
            "if [ \"$1 $2\" = \"pr list\" ]; then printf '[]\\n'; exit 0; fi\n"
            "if [ \"$1 $2\" = \"pr view\" ]; then\n"
            "  if [ \"${FAKE_GH_PR_STATE:-MERGED}\" = \"MERGED\" ]; then\n"
            "    printf '{\"state\":\"MERGED\",\"mergedAt\":\"2026-06-23T10:00:00Z\"}\\n'\n"
            "  else\n"
            "    printf '{\"state\":\"OPEN\",\"mergedAt\":null}\\n'\n"
            "  fi\n"
            "  exit 0\n"
            "fi\n"
            "exit 1\n"
        )
        gh.chmod(0o755)

    def run_poller(self, extra_env: dict | None = None) -> None:
        env = os.environ.copy()
        env.update({
            "HOME": str(self.home),
            "PATH": f"{self.fake_bin}:{env.get('PATH', '')}",
            "FIELDWORK_PROJECTS_ROOT": str(self.projects),
            "FIELDWORK_WORKTREES_ROOT": str(self.worktrees),
            "FIELDWORK_NOTIFICATIONS_DIR": str(self.notifications),
            "FIELDWORK_BROKER_AUDIT_LOG_PATH": str(self.audit),
            "FAKE_GH_LOG": str(self.tmp / "gh.log"),
        })
        if extra_env:
            env.update(extra_env)
        subprocess.run([str(POLLER)], cwd=ROOT, env=env, check=True)

    def test_worktree_state_journal_artifact_and_dedup(self) -> None:
        repo, linked = self.make_repo()

        self.run_poller()

        state_path = self.home / ".fieldwork/state/events/event-repo.json"
        state = json.loads(state_path.read_text())
        self.assertEqual(state["schema_version"], 1)
        linked_key = str(linked.resolve())
        self.assertIn(linked_key, state["worktrees"])
        self.assertEqual(state["worktrees"][linked_key]["branch"], "fieldwork/test")
        self.assertEqual(state["worktrees"][linked_key]["base_branch"], "main")
        self.assertEqual(state["worktrees"][linked_key]["latest_commit_subject"], "add feature")

        journal = self.home / ".fieldwork/project-journals/event-repo.md"
        journal_lines = journal.read_text().splitlines()
        self.assertTrue(any("fieldwork/test | add feature" in line for line in journal_lines))
        resume = self.home / ".fieldwork/state/resume-context/event-repo.md"
        resume_text = resume.read_text()
        self.assertIn("## Resume context for event-repo", resume_text)
        self.assertIn("Repo guidance", resume_text)
        self.assertIn("Review checklist", resume_text)
        self.assertIn("add feature", resume_text)

        notifications_after_first = sorted(self.notifications.glob("*.json"))
        self.assertGreaterEqual(len(notifications_after_first), 1)

        self.run_poller()

        self.assertEqual(journal.read_text().splitlines(), journal_lines)
        self.assertEqual(sorted(self.notifications.glob("*.json")), notifications_after_first)
        # Keep repo variable live so linters do not mistake setup for dead work.
        self.assertTrue((repo / ".git").exists())

    def test_pr_merge_detection_uses_stored_pr_number(self) -> None:
        self.make_repo()
        self.audit.write_text(
            json.dumps({
                "ts": "2026-06-23T09:00:00Z",
                "event": "pr_opened",
                "repo": "owner/event-repo",
                "repo_path_slug": "event-repo",
                "branch": "fieldwork/test",
                "base_branch": "main",
                "pr_url": "https://github.com/owner/event-repo/pull/7",
            })
            + "\n"
        )

        self.run_poller()

        state = json.loads((self.home / ".fieldwork/state/events/event-repo.json").read_text())
        pr = state["prs"]["fieldwork/test"]
        self.assertEqual(pr["number"], 7)
        self.assertEqual(pr["merged_at"], "2026-06-23T10:00:00Z")
        self.assertIn("fieldwork/test:pr_state", state["last_throttled_checks"])
        gh_log = (self.tmp / "gh.log").read_text()
        self.assertIn("pr view 7 --json state,mergedAt", gh_log)
        self.assertNotIn("--head", gh_log)
        notifications = [json.loads(path.read_text()) for path in self.notifications.glob("*.json")]
        self.assertTrue(any(item.get("event") == "pr_merged" for item in notifications))

    def test_base_branch_falls_back_to_audit_when_no_default_branch_file(self) -> None:
        repo, linked = self.make_repo(with_default_branch=False)
        self.audit.write_text(
            json.dumps({
                "ts": "2026-06-23T09:00:00Z",
                "event": "pr_opened",
                "repo": "owner/event-repo",
                "repo_path_slug": "event-repo",
                "branch": "fieldwork/test",
                "base_branch": "trunk",
                "pr_url": "https://github.com/owner/event-repo/pull/7",
            })
            + "\n"
        )

        self.run_poller(extra_env={"FAKE_GH_PR_STATE": "OPEN"})

        state = json.loads((self.home / ".fieldwork/state/events/event-repo.json").read_text())
        # No default-branch file and origin_head would yield "main"; "trunk" can
        # only come from the audit fallback.
        self.assertEqual(state["worktrees"][str(linked.resolve())]["base_branch"], "trunk")
        self.assertTrue((repo / ".git").exists())

    def test_base_branch_falls_back_to_origin_head(self) -> None:
        repo, linked = self.make_repo(with_default_branch=False)
        bare = self.tmp / "remote.git"
        self.git("init", "-q", "--bare", str(bare), cwd=self.tmp)
        self.git("remote", "add", "origin", str(bare), cwd=repo)
        self.git("branch", "release", "main", cwd=repo)
        self.git("push", "-q", "origin", "main", "release", cwd=repo)
        self.git("symbolic-ref", "HEAD", "refs/heads/release", cwd=bare)
        self.git("fetch", "-q", "origin", cwd=repo)
        self.git("remote", "set-head", "origin", "-a", cwd=repo)

        self.run_poller(extra_env={"FAKE_GH_PR_STATE": "OPEN"})

        state = json.loads((self.home / ".fieldwork/state/events/event-repo.json").read_text())
        self.assertEqual(state["worktrees"][str(linked.resolve())]["base_branch"], "release")
        self.assertTrue((repo / ".git").exists())

    def test_multiple_concurrent_branches_tracked_independently(self) -> None:
        repo, linked = self.make_repo()
        linked2 = self.add_worktree(repo, "event-repo", "change2", "fieldwork/test2")
        self.audit.write_text(
            "".join(
                json.dumps({
                    "ts": ts,
                    "event": "pr_opened",
                    "repo": "owner/event-repo",
                    "repo_path_slug": "event-repo",
                    "branch": branch,
                    "base_branch": "main",
                    "pr_url": url,
                })
                + "\n"
                for ts, branch, url in (
                    ("2026-06-23T09:00:00Z", "fieldwork/test", "https://github.com/owner/event-repo/pull/7"),
                    ("2026-06-23T09:05:00Z", "fieldwork/test2", "https://github.com/owner/event-repo/pull/9"),
                )
            )
        )

        self.run_poller(extra_env={"FAKE_GH_PR_STATE": "OPEN"})

        state = json.loads((self.home / ".fieldwork/state/events/event-repo.json").read_text())
        self.assertIn(str(linked.resolve()), state["worktrees"])
        self.assertIn(str(linked2.resolve()), state["worktrees"])
        self.assertEqual(state["prs"]["fieldwork/test"]["number"], 7)
        self.assertEqual(state["prs"]["fieldwork/test2"]["number"], 9)

    def test_unchanged_state_emits_no_notification(self) -> None:
        self.make_repo()
        self.run_poller()
        for path in self.notifications.glob("*.json"):
            path.unlink()
        journal = self.home / ".fieldwork/project-journals/event-repo.md"
        journal_before = journal.read_text()

        self.run_poller()

        self.assertEqual(sorted(self.notifications.glob("*.json")), [])
        self.assertEqual(journal.read_text(), journal_before)

    def test_merge_check_throttled_within_refresh_window(self) -> None:
        self.make_repo()
        self.audit.write_text(
            json.dumps({
                "ts": "2026-06-23T09:00:00Z",
                "event": "pr_opened",
                "repo": "owner/event-repo",
                "repo_path_slug": "event-repo",
                "branch": "fieldwork/test",
                "base_branch": "main",
                "pr_url": "https://github.com/owner/event-repo/pull/7",
            })
            + "\n"
        )

        # PR stays OPEN so merged_at never short-circuits the loop; only the
        # refresh-window throttle can suppress the second `gh pr view`.
        self.run_poller(extra_env={"FAKE_GH_PR_STATE": "OPEN"})
        self.run_poller(extra_env={"FAKE_GH_PR_STATE": "OPEN"})

        gh_log = (self.tmp / "gh.log").read_text().splitlines()
        pr_views = [line for line in gh_log if line.startswith("pr view ")]
        self.assertEqual(len(pr_views), 1)


if __name__ == "__main__":
    unittest.main()
