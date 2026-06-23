#!/usr/bin/env python3
"""fieldwork-pr-broker server.

Listens on a systemd-managed Unix socket. Validates JSON PR requests, scans the
body for secrets via gitleaks, derives the HTTPS push URL from the repo's
.fieldwork/expected-origin, and pushes via a GIT_ASKPASS helper (token never
appears in argv or env passed to git). Then opens the PR via `gh pr create`.

The broker is agent-agnostic: it does not care which coding agent produced the
commit, only that the request satisfies the contract. Identities and paths
below are defaults and can be overridden via FIELDWORK_BROKER_* env vars.

Trust model:
- Runs as `fieldwork-pr-broker` user (not the agent user). PAT lives in
  /etc/fieldwork-pr-broker/gh-token.
- Receives requests from the agent user (different uid) over a SocketMode=0660
  socket whose installed SocketGroup defaults to the agent user's primary group
  so it stays reachable inside the agent sandbox user namespace.
- Reads the repo from /home/fieldwork/projects/<slug> via ProtectHome=read-only +
  ReadOnlyPaths=/home/fieldwork/projects (the broker can read but not write the
  agent user's home).
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
import json
import logging
import os
import re
import socket
import subprocess
import sys
import time
import uuid
from pathlib import Path

LOG_PATH = os.environ.get("FIELDWORK_BROKER_LOG_PATH", "/var/log/fieldwork-pr-broker.log")
TOKEN_PATH = os.environ.get("FIELDWORK_BROKER_TOKEN_PATH", "/etc/fieldwork-pr-broker/gh-token")
ASKPASS_PATH = os.environ.get("FIELDWORK_BROKER_ASKPASS_PATH", "/usr/local/lib/fieldwork-pr-broker/git-askpass")
PROJECTS_ROOT = os.environ.get("FIELDWORK_BROKER_PROJECTS_ROOT", "/home/fieldwork/projects")
LEDGER_DIR = os.environ.get("FIELDWORK_BROKER_LEDGER_DIR", "/var/lib/fieldwork-pr-broker/requests")
AUDIT_LOG_PATH = os.environ.get(
    "FIELDWORK_BROKER_AUDIT_LOG_PATH",
    "/var/lib/fieldwork-pr-broker/audit.jsonl",
)
AUDIT_READ_USER = os.environ.get("FIELDWORK_BROKER_AUDIT_READ_USER", "fieldwork").strip()
AUDIT_LOG_MAX_BYTES = int(
    os.environ.get("FIELDWORK_BROKER_AUDIT_LOG_MAX_BYTES", str(10 * 1024 * 1024))
)
AUDIT_LOG_BACKUPS = int(os.environ.get("FIELDWORK_BROKER_AUDIT_LOG_BACKUPS", "5"))
PENDING_DIR = os.environ.get(
    "FIELDWORK_BROKER_PENDING_DIR",
    "/var/lib/fieldwork-pr-broker/pending",
)
PENDING_EXPIRY_SECONDS = int(os.environ.get("FIELDWORK_BROKER_PENDING_EXPIRY", "86400"))
# Group that may read pending request files (the Telegram bot daemon's group).
# Best-effort chown. Failure is logged and ignored so the broker still starts
# on hosts where the bot has not been installed yet.
BOT_GROUP = os.environ.get("FIELDWORK_BROKER_BOT_GROUP", "fieldwork-bot")
# Optional broker lifecycle drops into the bot's notifications dir. Default
# off because approval decisions already edit the original Telegram prompt;
# enable a conservative event set with FIELDWORK_BROKER_NOTIFY_LIFECYCLE=1.
NOTIFICATIONS_DIR = os.environ.get(
    "FIELDWORK_BROKER_NOTIFICATIONS_DIR",
    "/var/lib/fieldwork-pr-broker/notifications",
)
NOTIFY_LIFECYCLE_RAW = os.environ.get("FIELDWORK_BROKER_NOTIFY_LIFECYCLE", "").strip()
NOTIFY_ON_PR_OPENED = os.environ.get("FIELDWORK_BROKER_NOTIFY_ON_PR_OPENED", "0") == "1"
NOTIFICATION_SCHEMA = 1
# Approve-socket path used to identify the second systemd-passed listening
# socket. Connections on any other listening socket are treated as agent
# requests and never see the /approve route.
APPROVE_SOCKET_PATH = os.environ.get(
    "FIELDWORK_BROKER_APPROVE_SOCKET_PATH",
    "/run/fieldwork-pr-broker/fieldwork-pr-approve.sock",
)
RATE_LIMIT_PER_HOUR = 6
# Branch prefix the broker will accept. Agents commit under <prefix>/... ; the
# broker refuses anything else (including the default branch).
BRANCH_PREFIX = os.environ.get("FIELDWORK_BROKER_BRANCH_PREFIX", "fieldwork")
DEFAULT_BRANCH = os.environ.get("FIELDWORK_BROKER_DEFAULT_BRANCH", "main")
# Marker file inside a repo that opts it into the approval gate. Presence is
# sufficient in v1; the file body is reserved for future per-repo policy.
APPROVAL_GATE_MARKER = ".fieldwork/approval-gate"
DEFAULT_BRANCH_FILE = ".fieldwork/default-branch"

SCHEMA_PATH = os.environ.get(
    "FIELDWORK_BROKER_SCHEMA_PATH",
    str(Path(__file__).with_name("pr-request.schema.json")),
)

REPO_PATH_RE = re.compile(rf"^{re.escape(PROJECTS_ROOT)}/[a-z0-9][a-z0-9-]{{0,30}}$")
BRANCH_RE = re.compile(rf"^{re.escape(BRANCH_PREFIX)}/[a-z0-9][a-z0-9/_-]{{1,80}}$")
BASE_BRANCH_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/-]{0,99}$")
OWNER_REPO_RE = re.compile(r"^([A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?)/([A-Za-z0-9._-]{1,100})$")
ORIGIN_RE = re.compile(r"^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+?)(\.git)?$")
SSH_ORIGIN_RE = re.compile(r"^git@[^:]+:([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+?)(\.git)?$")
TITLE_MAX = 200
BODY_MAX = 64 * 1024
CREATED_AT_RE = re.compile(r"^20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$")

logging.basicConfig(
    filename=LOG_PATH,
    format="%(asctime)s %(levelname)s %(message)s",
    level=logging.INFO,
)
log = logging.getLogger("fieldwork-pr-broker")

_recent_requests: dict[str, list[float]] = {}
_schema_cache: dict | None = None
_setfacl_available: bool | None = None
_audit_read_user_exists: bool | None = None


class RequestError(Exception):
    """Validation error; .message is sent to the client."""

    def __init__(self, message: str, status: int = 400, extra=None):
        super().__init__(message)
        self.message = message
        self.status = status
        # Optional structured fields merged into the JSON error response so
        # clients can react programmatically (e.g. an already-pending request).
        self.extra = extra or {}


@dataclass(frozen=True)
class ValidatedRequest:
    request_id: str
    created_at: str
    repo_path: str
    branch: str
    title: str
    body: str
    owner: str
    repo: str
    base_branch: str


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def repo_slug(repo_path: str | None) -> str | None:
    if not repo_path:
        return None
    try:
        return Path(repo_path).name
    except TypeError:
        return None


def _setfacl(path: Path, acl: str, *, default: bool = False) -> None:
    """Best-effort POSIX ACL grant for audit/notification read contracts."""
    global _setfacl_available
    if not AUDIT_READ_USER:
        return
    if _setfacl_available is False:
        return
    cmd = ["setfacl"]
    if default:
        cmd.append("-d")
    cmd.extend(["-m", acl, str(path)])
    try:
        subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        _setfacl_available = True
    except FileNotFoundError:
        _setfacl_available = False
    except (OSError, subprocess.CalledProcessError):
        log.debug("setfacl failed path=%s acl=%s default=%s", path, acl, default)


def _audit_reader_exists() -> bool:
    global _audit_read_user_exists
    if not AUDIT_READ_USER:
        return False
    if _audit_read_user_exists is not None:
        return _audit_read_user_exists
    try:
        subprocess.run(
            ["id", "-u", AUDIT_READ_USER],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        _audit_read_user_exists = True
    except (FileNotFoundError, OSError, subprocess.CalledProcessError):
        _audit_read_user_exists = False
    return _audit_read_user_exists


def _harden_audit_dir(path: Path) -> None:
    if not _audit_reader_exists():
        return
    # The agent/dashboard user may traverse the broker state dir to the known
    # audit path, but it must not gain list/read access to pending or requests.
    _setfacl(path, f"u:{AUDIT_READ_USER}:--x")
    # New audit.jsonl files created after rotation inherit read access; the
    # explicit chmod/ACL pass below keeps existing files aligned too.
    _setfacl(path, f"u:{AUDIT_READ_USER}:r--", default=True)


def _harden_audit_file(path: Path) -> None:
    try:
        os.chmod(path, 0o640)
    except OSError:
        pass
    if _audit_reader_exists():
        _setfacl(path, f"u:{AUDIT_READ_USER}:r--")


def audit_event(event: str, **fields: object) -> None:
    """Append a redacted broker audit event.

    The audit log intentionally records only routing/decision metadata. It
    excludes PR bodies, tokens, environment variables, private keys, and full
    paths beyond the repo_path_slug convenience field.
    """
    record: dict[str, object] = {
        "ts": utc_now(),
        "event": event,
    }
    allowed = {
        "request_id",
        "repo",
        "repo_path_slug",
        "branch",
        "base_branch",
        "actor",
        "transport",
        "decision",
        "pr_url",
        "error_category",
        "status",
        "expires_at",
    }
    for key in allowed:
        value = fields.get(key)
        if value is None or value == "":
            continue
        record[key] = value

    path = Path(AUDIT_LOG_PATH)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        _harden_audit_dir(path.parent)
        _rotate_audit_log(path)
        with open(path, "a") as f:
            json.dump(record, f, sort_keys=True)
            f.write("\n")
        _harden_audit_file(path)
    except OSError as e:
        log.warning("audit write failed event=%s: %s", event, e)


def _rotate_audit_log(path: Path) -> None:
    """Size-based rotation for the append-only audit log.

    Keeps AUDIT_LOG_BACKUPS rotated files (audit.jsonl.1 .. .N). Best effort:
    a rotation failure must never block the audit write that follows it.
    """
    if AUDIT_LOG_MAX_BYTES <= 0 or AUDIT_LOG_BACKUPS <= 0:
        return
    try:
        if path.stat().st_size < AUDIT_LOG_MAX_BYTES:
            return
    except OSError:
        return
    base = str(path)
    try:
        oldest = f"{base}.{AUDIT_LOG_BACKUPS}"
        if os.path.exists(oldest):
            os.remove(oldest)
        for i in range(AUDIT_LOG_BACKUPS - 1, 0, -1):
            src = f"{base}.{i}"
            if os.path.exists(src):
                os.replace(src, f"{base}.{i + 1}")
        os.replace(base, f"{base}.1")
        for i in range(1, AUDIT_LOG_BACKUPS + 1):
            rotated = Path(f"{base}.{i}")
            if rotated.exists():
                _harden_audit_file(rotated)
    except OSError as e:
        log.warning("audit rotate failed: %s", e)


def schema_path() -> Path:
    path = Path(SCHEMA_PATH)
    if path.is_file():
        return path
    repo_schema = Path(__file__).resolve().parents[2] / "schema" / "pr-request.schema.json"
    if repo_schema.is_file():
        return repo_schema
    return path


def load_schema() -> dict:
    global _schema_cache
    if _schema_cache is None:
        path = schema_path()
        try:
            _schema_cache = json.loads(path.read_text())
        except FileNotFoundError:
            raise RequestError("broker request schema is missing; reinstall the PR broker", status=503)
        except PermissionError:
            raise RequestError("broker cannot read its request schema; reinstall the PR broker", status=503)
        except json.JSONDecodeError:
            raise RequestError("broker request schema is invalid; reinstall the PR broker", status=503)
    return _schema_cache


def validate_json_schema(req: object) -> dict:
    """Small JSON Schema subset validator for schema/pr-request.schema.json.

    Avoids a runtime dependency on python-jsonschema while enforcing the
    documented contract: object type, required fields, no extra fields,
    string types, maxLength, and regex patterns.
    """
    schema = load_schema()
    if not isinstance(req, dict):
        raise RequestError("request body must be a JSON object")

    required = schema.get("required", [])
    for field in required:
        if field not in req:
            raise RequestError(f"schema validation failed: missing required field: {field}")

    allowed = set(schema.get("properties", {}).keys())
    extras = sorted(set(req.keys()) - allowed)
    if schema.get("additionalProperties") is False and extras:
        raise RequestError(f"schema validation failed: unexpected field: {extras[0]}")

    for field, rules in schema.get("properties", {}).items():
        if field not in req:
            continue
        value = req[field]
        if rules.get("type") == "string" and not isinstance(value, str):
            raise RequestError(f"schema validation failed: field must be string: {field}")
        if isinstance(value, str) and "maxLength" in rules and len(value) > int(rules["maxLength"]):
            raise RequestError(f"schema validation failed: field too long: {field}")
        pattern = rules.get("pattern")
        if field == "repo_path" and pattern:
            pattern = rf"{re.escape(PROJECTS_ROOT)}/[a-z0-9][a-z0-9-]{{0,30}}"
        if isinstance(value, str) and pattern and not re.fullmatch(pattern, value):
            raise RequestError(f"schema validation failed: field does not match pattern: {field}")
    return req


def normalize_github_origin(origin: str) -> tuple[str, str]:
    origin = origin.strip()
    m = ORIGIN_RE.match(origin)
    if m:
        return m.group(1), m.group(2)
    m = SSH_ORIGIN_RE.match(origin)
    if m:
        return m.group(1), m.group(2)
    raise RequestError("origin remote must be a GitHub HTTPS URL or git@github alias URL")


def ensure_readable_git_repo(repo_path: str) -> None:
    git_dir = Path(repo_path, ".git")
    try:
        is_git_dir = git_dir.is_dir()
    except PermissionError:
        raise RequestError(
            "broker cannot read repo checkout; repair projects directory permissions and rerun onboarding",
            status=403,
        )
    if not is_git_dir:
        raise RequestError(f"{repo_path} is not a git repository")


def read_expected_origin(repo_path: str) -> str:
    origin_file = Path(repo_path, ".fieldwork/expected-origin")
    try:
        if not origin_file.is_file():
            raise RequestError("missing .fieldwork/expected-origin")
        lines = origin_file.read_text().strip().splitlines()
    except PermissionError:
        raise RequestError(
            "broker cannot read .fieldwork/expected-origin; repair checkout permissions and rerun onboarding",
            status=403,
        )
    if not lines:
        raise RequestError("expected-origin is empty")
    return lines[0]


def validate_base_branch(value: str) -> str:
    branch = value.strip()
    if (
        not BASE_BRANCH_RE.fullmatch(branch)
        or branch.startswith("/")
        or branch.endswith("/")
        or ".." in branch
        or "@{" in branch
    ):
        raise RequestError("default branch name is invalid")
    return branch


def read_default_branch(repo_path: str) -> str:
    branch_file = Path(repo_path, DEFAULT_BRANCH_FILE)
    try:
        if branch_file.is_file():
            lines = branch_file.read_text().strip().splitlines()
            if not lines:
                raise RequestError("default-branch is empty")
            return validate_base_branch(lines[0])
    except PermissionError:
        raise RequestError(
            "broker cannot read .fieldwork/default-branch; repair checkout permissions and rerun onboarding",
            status=403,
        )
    return validate_base_branch(DEFAULT_BRANCH)


def validate_origin_remote(repo_path: str, owner: str, repo: str) -> None:
    try:
        result = subprocess.run(
            ["git", "-C", repo_path, "config", "--get", "remote.origin.url"],
            env=broker_git_env(repo_path),
            capture_output=True, text=True,
        )
    except FileNotFoundError:
        raise RequestError("git is missing in the broker environment", status=503)
    if result.returncode != 0 or not result.stdout.strip():
        raise RequestError("missing git remote origin")
    origin_owner, origin_repo = normalize_github_origin(result.stdout.strip())
    if (origin_owner, origin_repo) != (owner, repo):
        raise RequestError("origin remote does not match .fieldwork/expected-origin")


def validate_owner_repo(value: object) -> tuple[str, str]:
    if not isinstance(value, str):
        raise RequestError("repo must be a string like owner/repo")
    m = OWNER_REPO_RE.fullmatch(value)
    if not m or "--" in m.group(1):
        raise RequestError("repo must be a valid GitHub owner/repo")
    return m.group(1), m.group(2)


def broker_token() -> str:
    try:
        token = Path(TOKEN_PATH).read_text().strip()
    except FileNotFoundError:
        raise RequestError("broker GitHub PAT is not stored; run rotate-pat", status=503)
    except PermissionError:
        raise RequestError(f"broker cannot read its GitHub PAT; repair {TOKEN_PATH} ownership", status=503)
    if not token:
        raise RequestError("broker GitHub PAT is empty; run rotate-pat", status=503)
    return token


def github_env() -> dict[str, str]:
    return {
        "PATH": os.environ.get("FIELDWORK_BROKER_COMMAND_PATH", "/usr/bin:/usr/local/bin"),
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_ASKPASS": ASKPASS_PATH,
        "HOME": "/tmp",
    }


def broker_git_env(repo_path: str) -> dict[str, str]:
    env = github_env()
    env.update({
        "GIT_CONFIG_COUNT": "2",
        "GIT_CONFIG_KEY_0": "safe.directory",
        "GIT_CONFIG_VALUE_0": repo_path,
        "GIT_CONFIG_KEY_1": "core.hooksPath",
        "GIT_CONFIG_VALUE_1": "/dev/null",
    })
    return env


def preflight(req: object) -> dict[str, str]:
    if not isinstance(req, dict):
        raise RequestError("preflight request body must be a JSON object")
    extras = sorted(set(req.keys()) - {"repo"})
    if extras:
        raise RequestError(f"preflight request has unexpected field: {extras[0]}")
    if "repo" not in req:
        raise RequestError("preflight request missing required field: repo")

    owner, repo = validate_owner_repo(req["repo"])
    owner_repo = f"{owner}/{repo}"
    env = {**github_env(), "GH_TOKEN": broker_token()}
    try:
        out = subprocess.run(
            ["gh", "repo", "view", owner_repo, "--json", "defaultBranchRef,nameWithOwner,visibility"],
            env=env, check=True, timeout=30, capture_output=True, text=True,
        )
    except FileNotFoundError:
        raise RequestError("GitHub CLI is missing in the broker environment", status=503)
    except subprocess.TimeoutExpired:
        raise RequestError("broker GitHub preflight timed out", status=504)
    except subprocess.CalledProcessError as e:
        detail = f"{e.stdout or ''}\n{e.stderr or ''}".strip()
        lower = detail.lower()
        if "could not resolve to a repository" in lower or "not found" in lower or "404" in lower:
            raise RequestError(
                f"broker PAT cannot reach {owner_repo}; add this repository to the fine-grained PAT selected repositories",
                status=404,
            )
        if "resource not accessible by personal access token" in lower or "403" in lower:
            raise RequestError(
                f"broker PAT lacks required permissions for {owner_repo}; grant Metadata read, Contents read/write, and Pull requests read/write",
                status=403,
            )
        log.error("broker preflight failed for %s: %s", owner_repo, detail[:500])
        raise RequestError("broker GitHub preflight failed (see broker log)", status=502)

    try:
        info = json.loads(out.stdout)
    except json.JSONDecodeError:
        log.error("broker preflight returned invalid JSON for %s: %s", owner_repo, out.stdout[:500])
        raise RequestError("broker GitHub preflight returned invalid JSON", status=502)

    default_branch = ""
    if isinstance(info.get("defaultBranchRef"), dict):
        default_branch = str(info["defaultBranchRef"].get("name") or "")
    return {
        "repo": owner_repo,
        "nameWithOwner": str(info.get("nameWithOwner") or owner_repo),
        "defaultBranch": default_branch,
        "visibility": str(info.get("visibility") or ""),
    }


def validate(req: object) -> ValidatedRequest:
    req = validate_json_schema(req)

    request_id = req["request_id"].lower()
    if not UUID_RE.match(request_id):
        raise RequestError("request_id must be a UUID")

    created_at = req["created_at"]
    if not CREATED_AT_RE.match(created_at):
        raise RequestError("created_at must be UTC like 2026-05-11T10:30:00Z")
    try:
        datetime.strptime(created_at, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        raise RequestError("created_at must be a valid UTC timestamp")

    repo_path = req["repo_path"]
    if not REPO_PATH_RE.match(repo_path):
        raise RequestError(f"repo_path must match ^{PROJECTS_ROOT}/<slug>$")
    ensure_readable_git_repo(repo_path)

    branch = req["branch"]
    if not BRANCH_RE.match(branch):
        raise RequestError(
            f"branch must match ^{BRANCH_PREFIX}/[a-z0-9][a-z0-9/_-]{{1,80}}$"
        )

    title = req["title"]
    if len(title) > TITLE_MAX or "\n" in title:
        raise RequestError(f"title >{TITLE_MAX} chars or contains newline")

    body = req["body"]
    if len(body.encode("utf-8")) > BODY_MAX:
        raise RequestError(f"body >{BODY_MAX} bytes")

    origin = read_expected_origin(repo_path)
    m = ORIGIN_RE.match(origin)
    if not m:
        raise RequestError("expected-origin must be an https://github.com URL (HTTPS, not SSH)")
    owner, repo = m.group(1), m.group(2)
    validate_origin_remote(repo_path, owner, repo)
    base_branch = read_default_branch(repo_path)

    # Worktree must be clean.
    for cmd in (["git", "-C", repo_path, "diff", "--quiet"],
                ["git", "-C", repo_path, "diff", "--cached", "--quiet"]):
        if subprocess.run(cmd, env=broker_git_env(repo_path), capture_output=True).returncode != 0:
            raise RequestError("worktree not clean, commit before submitting")

    # Body secret scan via gitleaks (use `dir`, not `protect`).
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        body_file = Path(tmp, "body.md")
        body_file.write_text(body)
        try:
            result = subprocess.run(
                ["gitleaks", "dir", str(tmp), "--no-banner", "--redact", "--exit-code", "1"],
                capture_output=True, timeout=30,
            )
        except FileNotFoundError:
            raise RequestError("gitleaks is missing in the broker environment", status=503)
        except subprocess.TimeoutExpired:
            raise RequestError("gitleaks scan timed out", status=504)
    if result.returncode != 0:
        raise RequestError("body contains secret-shaped content (gitleaks)")

    return ValidatedRequest(request_id, created_at, repo_path, branch, title, body, owner, repo, base_branch)


def rate_limit(repo: str) -> None:
    now = time.time()
    cutoff = now - 3600
    bucket = [t for t in _recent_requests.get(repo, []) if t > cutoff]
    if len(bucket) >= RATE_LIMIT_PER_HOUR:
        raise RequestError(f"rate limit hit ({RATE_LIMIT_PER_HOUR}/hour) for {repo}", status=429)
    bucket.append(now)
    _recent_requests[repo] = bucket


def reserve_request_id(req: ValidatedRequest) -> None:
    ledger_dir = Path(LEDGER_DIR)
    ledger_dir.mkdir(parents=True, exist_ok=True)
    path = ledger_dir / f"{req.request_id}.json"
    record = {
        "request_id": req.request_id,
        "created_at": req.created_at,
        "repo": f"{req.owner}/{req.repo}",
        "repo_path": req.repo_path,
        "branch": req.branch,
        "base_branch": req.base_branch,
        "accepted_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        raise RequestError("duplicate request_id rejected (possible replay)", status=409)
    with os.fdopen(fd, "w") as f:
        json.dump(record, f, sort_keys=True)
        f.write("\n")


def approval_gate_enabled(repo_path: str) -> bool:
    """The repo opts into the human approval gate by committing the marker file."""
    return Path(repo_path, APPROVAL_GATE_MARKER).is_file()


def _chgrp_best_effort(path: Path, group: str) -> None:
    """chown -g to BOT_GROUP if it exists; tolerate missing group / non-root."""
    if not group:
        return
    try:
        import grp
        gid = grp.getgrnam(group).gr_gid
    except (KeyError, ImportError):
        return
    try:
        os.chown(path, -1, gid)
    except (PermissionError, OSError) as e:
        log.info("pending chown to group %s failed: %s", group, e)


def _notify_lifecycle_events() -> set[str]:
    raw = NOTIFY_LIFECYCLE_RAW.lower()
    if raw in ("", "0", "false", "no", "off"):
        events: set[str] = set()
    elif raw in ("1", "true", "yes", "on", "minimal"):
        events = {"request_queued", "pr_opened"}
    elif raw == "all":
        events = {"request_queued", "request_approved", "request_denied", "pr_opened"}
    else:
        events = {part.strip() for part in raw.split(",") if part.strip()}
    if NOTIFY_ON_PR_OPENED:
        events.add("pr_opened")
    return events


def notify_lifecycle(
    event: str,
    *,
    repo_slug_value: str | None = None,
    request_id: str | None = None,
    branch: str | None = None,
    pr_url: str | None = None,
    force: bool = False,
) -> None:
    """Best-effort broker lifecycle notification drop.

    The bot accepts this versioned envelope and still accepts legacy
    ``{"text": "..."}`` drops. Notification failure must not affect broker
    request handling.
    """
    if not force and event not in _notify_lifecycle_events():
        return
    slug = repo_slug_value or "unknown"
    if event == "pr_opened" and pr_url:
        text = f"🚀 {slug} PR opened: {pr_url}"
    elif event == "request_queued":
        text = f"Approval queued: {slug} @ {branch or '?'}"
    elif event == "request_approved":
        text = f"Approval approved: {slug} @ {branch or '?'}"
    elif event == "request_denied":
        text = f"Approval denied: {slug} @ {branch or '?'}"
    else:
        text = f"{event}: {slug} @ {branch or '?'}"
    dedupe_parts = [event, slug]
    if request_id:
        dedupe_parts.append(request_id)
    elif branch:
        dedupe_parts.append(branch)
    dedupe_key = ":".join(dedupe_parts)
    payload = {
        "schema": NOTIFICATION_SCHEMA,
        "kind": "broker_lifecycle",
        "source": "broker",
        "event": event,
        "repo_slug": slug,
        "request_id": request_id,
        "branch": branch,
        "dedupe_key": dedupe_key,
        "text": text,
    }
    try:
        out_dir = Path(NOTIFICATIONS_DIR)
        out_dir.mkdir(parents=True, exist_ok=True)
        uid = uuid.uuid4().hex
        tmp = out_dir / f".tmp-{uid}"
        final = out_dir / f"{uid}.json"
        with open(tmp, "w") as f:
            json.dump(payload, f, sort_keys=True)
            f.write("\n")
        try:
            os.chmod(tmp, 0o660)
        except OSError:
            pass
        os.replace(tmp, final)
        _chgrp_best_effort(final, BOT_GROUP)
    except (OSError, ValueError) as e:
        log.info("lifecycle notification drop failed event=%s: %s", event, e)


def queue_pending(req: ValidatedRequest) -> str:
    """Write the validated request to the pending dir; returns expires_at (UTC).

    Uses O_EXCL so a duplicate request_id (one already pending) is rejected
    here just like the replay ledger would reject it. The pending file is
    mode 0640 and group-readable by BOT_GROUP so the bot daemon can pick it
    up via inotify/scandir.
    """
    pending_dir = Path(PENDING_DIR)
    pending_dir.mkdir(parents=True, exist_ok=True)
    # Reject a second request for the same repo+branch that is already queued, so
    # a re-submitted onboard (which mints a fresh request_id each time) cannot
    # flood the approval queue with duplicates. Expired entries were already
    # dropped by sweep_expired_pending() before this call, so anything still here
    # is live. Surface the existing request_id/expires_at to the client.
    for entry in pending_dir.glob("*.json"):
        try:
            existing = json.loads(entry.read_text())
        except (OSError, ValueError):
            continue
        if existing.get("repo_path") == req.repo_path and existing.get("branch") == req.branch:
            raise RequestError(
                "a request for this branch is already pending",
                status=409,
                extra={
                    "already_pending": True,
                    "pending_request_id": existing.get("request_id"),
                    "expires_at": existing.get("expires_at"),
                },
            )
    now = datetime.now(timezone.utc)
    expires_at = (now + _timedelta_seconds(PENDING_EXPIRY_SECONDS)).strftime("%Y-%m-%dT%H:%M:%SZ")
    record = {
        "request_id": req.request_id,
        "created_at": req.created_at,
        "queued_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "expires_at": expires_at,
        "repo": f"{req.owner}/{req.repo}",
        "owner": req.owner,
        "repo_name": req.repo,
        "repo_path": req.repo_path,
        "branch": req.branch,
        "base_branch": req.base_branch,
        "title": req.title,
        "body": req.body,
    }
    path = pending_dir / f"{req.request_id}.json"
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o640)
    except FileExistsError:
        raise RequestError("duplicate request_id rejected (already pending)", status=409)
    with os.fdopen(fd, "w") as f:
        json.dump(record, f, sort_keys=True)
        f.write("\n")
    _chgrp_best_effort(path, BOT_GROUP)
    return expires_at


def _timedelta_seconds(seconds: int):
    from datetime import timedelta
    return timedelta(seconds=seconds)


def load_pending(request_id: str) -> dict:
    path = Path(PENDING_DIR) / f"{request_id}.json"
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        raise RequestError("no pending request for that request_id", status=404)
    except json.JSONDecodeError:
        log.error("pending file is not valid JSON: %s", path)
        raise RequestError("pending request is corrupt", status=500)


def remove_pending(request_id: str) -> None:
    pending_dir = Path(PENDING_DIR)
    for name in (f"{request_id}.json", f"{request_id}.json.notified"):
        try:
            (pending_dir / name).unlink()
        except FileNotFoundError:
            pass


def sweep_expired_pending() -> int:
    """Delete pending requests older than PENDING_EXPIRY_SECONDS.

    Returns the number of expired entries dropped. Expired ledger entries stay
    intact so the request_id cannot be reused.
    """
    pending_dir = Path(PENDING_DIR)
    if not pending_dir.is_dir():
        return 0
    dropped = 0
    now = datetime.now(timezone.utc)
    for entry in pending_dir.glob("*.json"):
        try:
            with open(entry) as f:
                record = json.load(f)
        except (OSError, json.JSONDecodeError):
            continue
        queued_at = record.get("queued_at") or record.get("created_at")
        try:
            queued_dt = datetime.strptime(queued_at, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        except (TypeError, ValueError):
            continue
        if (now - queued_dt).total_seconds() <= PENDING_EXPIRY_SECONDS:
            continue
        rid = record.get("request_id", entry.stem)
        log.info("rid=%s expired after %ds; dropping pending entry", rid, PENDING_EXPIRY_SECONDS)
        audit_event(
            "request_expired",
            request_id=rid,
            repo=record.get("repo"),
            repo_path_slug=repo_slug(record.get("repo_path")),
            branch=record.get("branch"),
            base_branch=record.get("base_branch"),
            actor="broker",
            transport="broker",
        )
        try:
            entry.unlink()
        except FileNotFoundError:
            pass
        sidecar = pending_dir / f"{entry.stem}.json.notified"
        try:
            sidecar.unlink()
        except FileNotFoundError:
            pass
        dropped += 1
    return dropped


def revalidate_pending_for_push(record: dict) -> ValidatedRequest:
    """Reconstruct a ValidatedRequest from a pending file and re-check pre-push state.

    The pending file was written after a full validate() pass, but the repo
    state may have changed between queue time and approve time. Re-run the
    parts that can drift: worktree cleanliness and origin remote match. Schema
    fields are trusted from the pending record itself (they were already
    validated by validate() at queue time, and the pending dir is broker-only
    writable).
    """
    try:
        rid = record["request_id"]
        repo_path = record["repo_path"]
        branch = record["branch"]
        title = record["title"]
        body = record["body"]
        owner = record["owner"]
        repo = record["repo_name"]
        created_at = record["created_at"]
        base_branch = record.get("base_branch") or read_default_branch(repo_path)
    except KeyError as e:
        raise RequestError(f"pending request missing field {e!s}", status=500)

    ensure_readable_git_repo(repo_path)
    validate_origin_remote(repo_path, owner, repo)
    base_branch = validate_base_branch(str(base_branch))
    for cmd in (["git", "-C", repo_path, "diff", "--quiet"],
                ["git", "-C", repo_path, "diff", "--cached", "--quiet"]):
        if subprocess.run(cmd, env=broker_git_env(repo_path), capture_output=True).returncode != 0:
            raise RequestError("worktree not clean, commit before submitting", status=409)
    return ValidatedRequest(rid, created_at, repo_path, branch, title, body, owner, repo, base_branch)


def approve(req: object) -> dict:
    if not isinstance(req, dict):
        raise RequestError("approve request body must be a JSON object")
    extras = sorted(set(req.keys()) - {"request_id", "decision", "chat_id"})
    if extras:
        raise RequestError(f"approve request has unexpected field: {extras[0]}")
    for field in ("request_id", "decision"):
        if field not in req:
            raise RequestError(f"approve request missing required field: {field}")

    request_id = req["request_id"]
    if not isinstance(request_id, str) or not UUID_RE.match(request_id):
        raise RequestError("approve request_id must be a UUID")
    decision = req["decision"]
    if decision not in ("approve", "deny"):
        raise RequestError("decision must be 'approve' or 'deny'")

    record = load_pending(request_id)

    queued_at = record.get("queued_at") or record.get("created_at", "")
    try:
        queued_dt = datetime.strptime(queued_at, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except (TypeError, ValueError):
        queued_dt = None
    if queued_dt is not None and (datetime.now(timezone.utc) - queued_dt).total_seconds() > PENDING_EXPIRY_SECONDS:
        remove_pending(request_id)
        audit_event(
            "request_expired",
            request_id=request_id,
            repo=record.get("repo"),
            repo_path_slug=repo_slug(record.get("repo_path")),
            branch=record.get("branch"),
            base_branch=record.get("base_branch"),
            actor=str(req.get("chat_id") or "approver"),
            transport="approve-socket",
            error_category="expired",
        )
        raise RequestError("pending request has expired", status=410)

    if decision == "deny":
        log.info("rid=%s denied via /approve", request_id)
        audit_event(
            "request_denied",
            request_id=request_id,
            repo=record.get("repo"),
            repo_path_slug=repo_slug(record.get("repo_path")),
            branch=record.get("branch"),
            base_branch=record.get("base_branch"),
            actor=str(req.get("chat_id") or "approver"),
            transport="approve-socket",
            decision="deny",
        )
        notify_lifecycle(
            "request_denied",
            repo_slug_value=repo_slug(record.get("repo_path")),
            request_id=request_id,
            branch=record.get("branch") if isinstance(record.get("branch"), str) else None,
        )
        remove_pending(request_id)
        return {"ok": True, "request_id": request_id, "decision": "deny"}

    validated = revalidate_pending_for_push(record)
    audit_event(
        "request_approved",
        request_id=request_id,
        repo=f"{validated.owner}/{validated.repo}",
        repo_path_slug=repo_slug(validated.repo_path),
        branch=validated.branch,
        base_branch=validated.base_branch,
        actor=str(req.get("chat_id") or "approver"),
        transport="approve-socket",
        decision="approve",
    )
    notify_lifecycle(
        "request_approved",
        repo_slug_value=repo_slug(validated.repo_path),
        request_id=request_id,
        branch=validated.branch,
    )
    pr_url = push_and_open_pr(validated)
    log.info("rid=%s approved -> %s", request_id, pr_url)
    remove_pending(request_id)
    return {"ok": True, "request_id": request_id, "decision": "approve", "url": pr_url}


def drop_pr_opened_notification(repo_path: str, pr_url: str) -> None:
    """Compatibility wrapper for the old PR-opened-only broker notifier."""
    notify_lifecycle(
        "pr_opened",
        repo_slug_value=repo_slug(repo_path),
        pr_url=pr_url,
        force=True,
    )


def push_and_open_pr(req: ValidatedRequest) -> str:
    """Returns the PR URL."""
    push_url = f"https://github.com/{req.owner}/{req.repo}.git"

    # `git push`: token reaches git ONLY via the askpass helper. Not in argv, not in env.
    push_env = broker_git_env(req.repo_path)
    log.info("rid=%s push %s -> %s", req.request_id, req.repo_path, req.branch)
    audit_event(
        "push_attempted",
        request_id=req.request_id,
        repo=f"{req.owner}/{req.repo}",
        repo_path_slug=repo_slug(req.repo_path),
        branch=req.branch,
        base_branch=req.base_branch,
        actor="broker",
        transport="github",
    )
    subprocess.run(
        ["git", "-C", req.repo_path, "push", "--no-verify", push_url, f"HEAD:refs/heads/{req.branch}"],
        env=push_env, check=True, timeout=120, capture_output=True,
    )

    # `gh pr create`: GH_TOKEN works for gh.
    gh_env = {**push_env, "GH_TOKEN": broker_token()}
    log.info(
        "rid=%s gh pr create %s/%s base=%s head=%s",
        req.request_id, req.owner, req.repo, req.base_branch, req.branch,
    )
    out = subprocess.run(
        ["gh", "pr", "create", "--repo", f"{req.owner}/{req.repo}",
         "--base", req.base_branch, "--head", req.branch,
         "--title", req.title, "--body", req.body],
        env=gh_env, check=True, timeout=120, capture_output=True, text=True,
    )
    pr_url = out.stdout.strip().splitlines()[-1]
    audit_event(
        "pr_opened",
        request_id=req.request_id,
        repo=f"{req.owner}/{req.repo}",
        repo_path_slug=repo_slug(req.repo_path),
        branch=req.branch,
        base_branch=req.base_branch,
        actor="broker",
        transport="github",
        pr_url=pr_url,
    )
    notify_lifecycle(
        "pr_opened",
        repo_slug_value=repo_slug(req.repo_path),
        request_id=req.request_id,
        branch=req.branch,
        pr_url=pr_url,
    )

    # Apply the "ready for review" label. The broker is the only entity in the
    # delivery flow that holds a gh write credential, so the labelling step
    # belongs here rather than in the agent. A label failure (label missing
    # on the repo, transient gh error, etc.) is non-fatal: the PR is already
    # open and review can proceed without it.
    try:
        subprocess.run(
            ["gh", "pr", "edit", pr_url, "--add-label", "ready for review"],
            env=gh_env, check=True, timeout=30, capture_output=True, text=True,
        )
        log.info("rid=%s label_applied pr=%s label=%s", req.request_id, pr_url, "ready for review")
    except subprocess.CalledProcessError as exc:
        log.warning(
            "rid=%s label_apply_failed pr=%s stderr=%s",
            req.request_id, pr_url, subprocess_stream_text(getattr(exc, "stderr", "")),
        )
    except subprocess.TimeoutExpired:
        log.warning("rid=%s label_apply_failed pr=%s reason=timeout", req.request_id, pr_url)

    return pr_url


def subprocess_stream_text(value: object) -> str:
    if isinstance(value, bytes):
        return value.decode(errors="replace")
    return str(value or "")


def broker_subprocess_error_message(e: subprocess.CalledProcessError) -> str:
    detail = f"{subprocess_stream_text(getattr(e, 'stdout', ''))}\n{subprocess_stream_text(getattr(e, 'stderr', ''))}".strip()
    lower = detail.lower()
    cmd = " ".join(str(part) for part in getattr(e, "cmd", []) or [])
    cmd_lower = cmd.lower()

    if "refusing to allow a personal access token to create or update workflow" in lower or "workflow scope" in lower:
        return (
            "broker PAT lacks Workflows read/write for workflow file changes; "
            "grant Workflows read/write or rerun onboarding with --no-workflows after resetting the init branch"
        )
    if "write access to repository not granted" in lower or "permission denied" in lower or "403" in lower:
        if "git" in cmd_lower and "push" in cmd_lower:
            return "broker PAT lacks Contents read/write or selected-repository access for git push"
        if "gh" in cmd_lower and "pr" in cmd_lower:
            return "broker PAT lacks Pull requests read/write for gh pr create"
        return "broker PAT lacks required GitHub write permissions"
    if "no commits between" in lower:
        return "GitHub reports no commits between the base branch and the requested branch"
    return "git/gh failure (see broker log)"


def handle(conn: socket.socket, socket_type: str = "agent") -> None:
    request_id = uuid.uuid4().hex[:12]
    audit_context: dict[str, object] = {
        "request_id": request_id,
        "actor": socket_type,
        "transport": "unix-socket",
    }
    try:
        # Curl holds the connection open waiting for a response, so a plain
        # recv-until-EOF loop deadlocks. Read headers, then exactly Content-Length
        # body bytes. Fall back to read-until-EOF only for non-HTTP raw clients.
        data = b""
        path = "/pr"
        while b"\r\n\r\n" not in data:
            chunk = conn.recv(8192)
            if not chunk:
                break
            data += chunk
            if len(data) > 65536:
                raise RequestError("headers >64KB")

        if data.startswith(b"POST ") or data.startswith(b"GET "):
            hdr_bytes, _, body = data.partition(b"\r\n\r\n")
            headers = hdr_bytes.decode("latin-1", errors="replace")
            request_line = headers.split("\r\n", 1)[0]
            request_parts = request_line.split()
            if len(request_parts) < 2:
                raise RequestError("invalid HTTP request line")
            method, path = request_parts[0], request_parts[1]
            if method != "POST":
                raise RequestError("broker accepts POST requests only", status=405)
            content_length = -1
            for line in headers.split("\r\n")[1:]:
                name, _, value = line.partition(":")
                if name.strip().lower() == "content-length":
                    try:
                        content_length = int(value.strip())
                    except ValueError:
                        raise RequestError("invalid Content-Length")
                    break
            if content_length < 0:
                raise RequestError("missing Content-Length")
            if content_length > 262144:
                raise RequestError("request >256KB")
            while len(body) < content_length:
                chunk = conn.recv(min(8192, content_length - len(body)))
                if not chunk:
                    raise RequestError("client closed before body complete")
                body += chunk
            data = body
        else:
            while True:
                chunk = conn.recv(8192)
                if not chunk:
                    break
                data += chunk
                if len(data) > 262144:
                    raise RequestError("request >256KB")

        try:
            req = json.loads(data)
        except json.JSONDecodeError:
            raise RequestError("invalid JSON")

        if isinstance(req, dict):
            raw_repo_path = req.get("repo_path")
            audit_context.update({
                "request_id": str(req.get("request_id") or request_id),
                "repo_path_slug": repo_slug(raw_repo_path if isinstance(raw_repo_path, str) else None),
                "branch": req.get("branch") if isinstance(req.get("branch"), str) else None,
            })

        if socket_type == "approve":
            if path != "/approve":
                raise RequestError("approve socket only serves /approve", status=404)
            result = approve(req)
            request_id = result.get("request_id", request_id)
            resp = json.dumps(result)
        elif path == "/preflight":
            result = preflight(req)
            log.info("rid=%s preflight ok repo=%s", request_id, result["repo"])
            resp = json.dumps({"ok": True, "request_id": request_id, **result})
        elif path == "/pr":
            validated = validate(req)
            request_id = validated.request_id
            audit_context.update({
                "request_id": request_id,
                "repo": f"{validated.owner}/{validated.repo}",
                "repo_path_slug": repo_slug(validated.repo_path),
                "branch": validated.branch,
                "base_branch": validated.base_branch,
            })
            audit_event("request_received", **audit_context)
            rate_limit(f"{validated.owner}/{validated.repo}")
            reserve_request_id(validated)
            log.info("rid=%s validated %s/%s branch=%s", request_id, validated.owner, validated.repo, validated.branch)

            sweep_expired_pending()
            if approval_gate_enabled(validated.repo_path):
                expires_at = queue_pending(validated)
                log.info("rid=%s queued for approval expires=%s", request_id, expires_at)
                audit_event(
                    "request_queued",
                    **audit_context,
                    status="queued",
                    expires_at=expires_at,
                )
                notify_lifecycle(
                    "request_queued",
                    repo_slug_value=repo_slug(validated.repo_path),
                    request_id=request_id,
                    branch=validated.branch,
                )
                resp = json.dumps({
                    "ok": True,
                    "queued": True,
                    "request_id": request_id,
                    "expires_at": expires_at,
                })
            else:
                pr_url = push_and_open_pr(validated)
                log.info("rid=%s success url=%s", request_id, pr_url)
                resp = json.dumps({"ok": True, "request_id": request_id, "url": pr_url})
        elif path == "/approve":
            raise RequestError("/approve is only available on the approve socket", status=404)
        else:
            raise RequestError("unknown broker path", status=404)
        conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n" + resp.encode())
    except RequestError as e:
        log.warning("rid=%s reject: %s", request_id, e.message)
        audit_context["request_id"] = request_id
        audit_event(
            "request_rejected",
            **audit_context,
            error_category=e.message.split(":", 1)[0][:120],
            status=e.status,
        )
        error_payload = {"ok": False, "request_id": request_id, "error": e.message}
        error_payload.update(e.extra)
        resp = json.dumps(error_payload)
        conn.sendall(f"HTTP/1.1 {e.status} ERROR\r\nContent-Type: application/json\r\n\r\n".encode() + resp.encode())
    except subprocess.CalledProcessError as e:
        log.error("rid=%s subprocess fail: %s stderr=%s", request_id, e, subprocess_stream_text(e.stderr)[:500])
        audit_context["request_id"] = request_id
        audit_event(
            "request_rejected",
            **audit_context,
            error_category=broker_subprocess_error_message(e),
            status=500,
        )
        resp = json.dumps({"ok": False, "request_id": request_id, "error": broker_subprocess_error_message(e)})
        conn.sendall(b"HTTP/1.1 500 ERROR\r\nContent-Type: application/json\r\n\r\n" + resp.encode())
    except subprocess.TimeoutExpired as e:
        log.error("rid=%s subprocess timeout: %s", request_id, e)
        audit_context["request_id"] = request_id
        audit_event(
            "request_rejected",
            **audit_context,
            error_category="timeout",
            status=504,
        )
        resp = json.dumps({"ok": False, "request_id": request_id, "error": "git/gh command timed out (see broker log)"})
        conn.sendall(b"HTTP/1.1 504 ERROR\r\nContent-Type: application/json\r\n\r\n" + resp.encode())
    except Exception as e:
        log.exception("rid=%s unhandled: %s", request_id, e)
        audit_context["request_id"] = request_id
        audit_event(
            "request_rejected",
            **audit_context,
            error_category="internal",
            status=500,
        )
        resp = json.dumps({"ok": False, "request_id": request_id, "error": "internal"})
        conn.sendall(b"HTTP/1.1 500 ERROR\r\nContent-Type: application/json\r\n\r\n" + resp.encode())
    finally:
        try: conn.shutdown(socket.SHUT_RDWR)
        except OSError: pass
        conn.close()


def _socket_type_for(sock: socket.socket) -> str:
    """Classify a listening socket as 'agent' or 'approve' by its bound path."""
    try:
        name = sock.getsockname()
    except OSError:
        return "agent"
    if isinstance(name, bytes):
        name = name.decode("utf-8", errors="replace")
    if isinstance(name, str) and os.path.basename(name) == os.path.basename(APPROVE_SOCKET_PATH):
        return "approve"
    return "agent"


def main() -> None:
    import selectors
    listen_fds = int(os.environ.get("LISTEN_FDS", "0"))
    if listen_fds < 1:
        print("expected systemd socket activation (LISTEN_FDS not set)", file=sys.stderr)
        sys.exit(2)

    sockets: list[tuple[socket.socket, str]] = []
    for i in range(listen_fds):
        sock = socket.socket(fileno=3 + i)
        kind = _socket_type_for(sock)
        sockets.append((sock, kind))
        log.info("broker listening on fd %d (%s)", 3 + i, kind)

    dropped = sweep_expired_pending()
    if dropped:
        log.info("startup sweep dropped %d expired pending entr%s", dropped, "y" if dropped == 1 else "ies")

    sel = selectors.DefaultSelector()
    for sock, kind in sockets:
        sel.register(sock, selectors.EVENT_READ, data=kind)

    try:
        while True:
            for key, _ in sel.select():
                listen_sock = key.fileobj
                kind = key.data
                conn, _addr = listen_sock.accept()
                handle(conn, kind)
    except KeyboardInterrupt:
        log.info("broker shutting down")


if __name__ == "__main__":
    main()
