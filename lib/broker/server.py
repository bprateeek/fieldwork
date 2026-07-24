#!/usr/bin/env python3
"""Fieldwork credential broker, protocol v2.

The broker is deliberately checkout-blind.  A request consists of trusted
operator-owned policy plus untrusted metadata and a non-thin Git pack.  Every
object is reconstructed and validated in a broker-private bare repository
before an approval can cause a forge write.
"""

from __future__ import annotations

import base64
import contextlib
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
import fcntl
import hashlib
import hmac
import http.client
import io
import ipaddress
import json
import logging
import os
from pathlib import Path
import re
import resource
import queue
import selectors
import shutil
import socket
import ssl
import stat
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import uuid

# Isolated mode intentionally omits the script directory from sys.path. The
# broker directory is root-owned in production, so adding this exact resolved
# sibling directory is safe and keeps the shared policy module importable.
_BROKER_LIB = str(Path(__file__).resolve().parent)
if _BROKER_LIB not in sys.path:
    sys.path.insert(0, _BROKER_LIB)
from policy_writer import PolicyError, canonical_json, policy_digest, policy_lock, read_policy


def bounded_env_int(name: str, default: int, minimum: int, maximum: int) -> int:
    try:
        value = int(os.environ.get(name, str(default)))
    except ValueError:
        value = default
    return min(maximum, max(minimum, value))


LOG_PATH = os.environ.get("FIELDWORK_BROKER_LOG_PATH", "/var/log/fieldwork-pr-broker.log")
TOKEN_PATH = Path(os.environ.get("FIELDWORK_BROKER_TOKEN_PATH", "/etc/fieldwork-pr-broker/gh-token"))
ASKPASS_PATH = os.environ.get("FIELDWORK_BROKER_ASKPASS_PATH", "/usr/local/lib/fieldwork-pr-broker/git-askpass")
POLICY_DIR = Path(os.environ.get("FIELDWORK_BROKER_POLICY_DIR", "/var/lib/fieldwork-pr-broker/policy"))
CA_DIR = Path(os.environ.get("FIELDWORK_BROKER_CA_DIR", "/var/lib/fieldwork-pr-broker/ca"))
LEDGER_DIR = Path(os.environ.get("FIELDWORK_BROKER_LEDGER_DIR", "/var/lib/fieldwork-pr-broker/requests"))
PENDING_META_DIR = Path(os.environ.get("FIELDWORK_BROKER_PENDING_META_DIR", "/var/lib/fieldwork-pr-broker/pending-meta"))
PENDING_SIDECAR_DIR = Path(os.environ.get("FIELDWORK_BROKER_PENDING_SIDECAR_DIR", "/var/lib/fieldwork-pr-broker/pending-sidecar"))
PENDING_PACK_DIR = Path(os.environ.get("FIELDWORK_BROKER_PENDING_PACK_DIR", "/var/lib/fieldwork-pr-broker/pending-pack"))
TOMBSTONE_DIR = Path(os.environ.get("FIELDWORK_BROKER_TOMBSTONE_DIR", "/var/lib/fieldwork-pr-broker/tombstones"))
WORK_DIR = Path(os.environ.get("FIELDWORK_BROKER_WORK_DIR", "/var/lib/fieldwork-pr-broker/work"))
MAC_KEY_PATH = Path(os.environ.get("FIELDWORK_BROKER_PENDING_MAC_KEY_PATH", "/var/lib/fieldwork-pr-broker/keys/pending-mac.key"))
AUDIT_LOG_PATH = Path(os.environ.get("FIELDWORK_BROKER_AUDIT_LOG_PATH", "/var/lib/fieldwork-pr-broker/audit.jsonl"))
NOTIFICATIONS_DIR = Path(os.environ.get("FIELDWORK_BROKER_NOTIFICATIONS_DIR", "/var/lib/fieldwork-pr-broker/notifications"))
SCHEMA_PATH = Path(os.environ.get("FIELDWORK_BROKER_SCHEMA_PATH", str(Path(__file__).with_name("pr-request.schema.json"))))
APPROVE_SOCKET_PATH = os.environ.get("FIELDWORK_BROKER_APPROVE_SOCKET_PATH", "/run/fieldwork-pr-broker/fieldwork-pr-approve.sock")
MAINTENANCE_SOCKET_PATH = os.environ.get("FIELDWORK_BROKER_MAINTENANCE_SOCKET_PATH", "/run/fieldwork-pr-broker/maintenance.sock")
HTTP_AUTH_TOKEN_PATH = os.environ.get("FIELDWORK_BROKER_HTTP_AUTH_TOKEN_PATH", "")
MAINTENANCE = os.environ.get("FIELDWORK_BROKER_MAINTENANCE", "0") == "1"
GITHUB_CREDENTIAL_MODE = os.environ.get("FIELDWORK_GITHUB_CREDENTIAL_MODE", "pat").strip().lower() or "pat"
GITHUB_APP_ID = os.environ.get("FIELDWORK_GITHUB_APP_ID", "").strip()
GITHUB_APP_INSTALLATION_ID = os.environ.get("FIELDWORK_GITHUB_APP_INSTALLATION_ID", "").strip()
GITHUB_APP_PRIVATE_KEY_PATH = Path(os.environ.get("FIELDWORK_GITHUB_APP_PRIVATE_KEY_PATH", "/etc/fieldwork-pr-broker/github-app-private-key.pem"))
BOT_GROUP = os.environ.get("FIELDWORK_BROKER_BOT_GROUP", "fieldwork-bot")

PACK_MAX_INPUT = 8 * 1024 * 1024
PACK_MAX_OBJECTS = bounded_env_int("FIELDWORK_BROKER_PACK_MAX_OBJECTS", 2000, 1, 100000)
PACK_MAX_BYTES = bounded_env_int("FIELDWORK_BROKER_PACK_MAX_BYTES", 64 * 1024 * 1024, 1024, 2 * 1024 * 1024 * 1024)
PACK_MAX_OBJECT_BYTES = bounded_env_int("FIELDWORK_BROKER_PACK_MAX_OBJECT_BYTES", 16 * 1024 * 1024, 1024, 512 * 1024 * 1024)
PACK_MAX_DELTA_DEPTH = bounded_env_int("FIELDWORK_BROKER_PACK_MAX_DELTA_DEPTH", 50, 1, 1000)
SCAN_MAX_OBJECTS = bounded_env_int("FIELDWORK_BROKER_SCAN_MAX_OBJECTS", 1000, 1, 100000)
SCAN_MAX_BYTES = bounded_env_int("FIELDWORK_BROKER_SCAN_MAX_BYTES", 10 * 1024 * 1024, 1024, 1024 * 1024 * 1024)
SCAN_RANGE = os.environ.get("FIELDWORK_BROKER_SCAN_RANGE", "1") != "0"
RATE_LIMIT_PER_HOUR = bounded_env_int("FIELDWORK_BROKER_RATE_LIMIT_PER_HOUR", 12, 1, 120)
PENDING_EXPIRY_SECONDS = bounded_env_int("FIELDWORK_BROKER_PENDING_EXPIRY", 86400, 60, 30 * 86400)
TOMBSTONE_RETENTION_DAYS = bounded_env_int("FIELDWORK_BROKER_TOMBSTONE_RETENTION_DAYS", 30, 1, 3650)
PROCESSING_SECONDS = bounded_env_int("FIELDWORK_BROKER_PROCESSING_TIMEOUT", 360, 30, 1800)
TITLE_MAX = 200
BODY_MAX = 64 * 1024
UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$")
CREATED_AT_RE = re.compile(r"^20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,30}$")
BRANCH_RE = re.compile(r"^fieldwork/[a-z0-9][a-z0-9/_-]{1,80}$")
OID_RE = re.compile(r"^[0-9a-f]{40}$")
TERMINAL_STATES = {"done", "denied", "expired", "failed", "needs_operator"}
ACTIVE_STATES = {"queued", "approved", "pushed", "pr_created"}
NOTIFICATION_EVENTS = {"queued", "approved", "denied", "pushed", "pr_created", "error"}


logging.basicConfig(filename=LOG_PATH, format="%(asctime)s %(levelname)s %(message)s", level=logging.INFO)
log = logging.getLogger("fieldwork-pr-broker")
_schema_cache: dict[str, object] | None = None
_recent_requests: dict[str, list[float]] = {}


class RequestError(Exception):
    def __init__(self, code: str, status: int = 400, *, detail: str | None = None, extra: dict[str, object] | None = None):
        super().__init__(code)
        self.code = code
        self.status = status
        self.detail = detail
        self.extra = extra or {}


@dataclass(frozen=True)
class ValidatedRequest:
    schema_version: int
    request_id: str
    created_at: str
    slug: str
    branch: str
    title: str
    body: str
    head_oid: str
    common_base_oid: str | None


@dataclass
class Deadline:
    end: float

    @classmethod
    def start(cls) -> "Deadline":
        return cls(time.monotonic() + PROCESSING_SECONDS)

    def remaining(self, phase_cap: float) -> float:
        value = min(phase_cap, self.end - time.monotonic())
        if value <= 0:
            raise RequestError("processing_timeout", 504)
        return value


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _mkdir(path: Path, mode: int) -> None:
    path.mkdir(parents=True, exist_ok=True, mode=mode)
    try:
        os.chmod(path, mode)
    except PermissionError:
        pass


def initialize_state_dirs() -> None:
    for path, mode in (
        (POLICY_DIR, 0o750), (LEDGER_DIR, 0o700), (PENDING_META_DIR, 0o2750),
        (PENDING_SIDECAR_DIR, 0o2770), (PENDING_PACK_DIR, 0o700),
        (TOMBSTONE_DIR, 0o700), (WORK_DIR, 0o700), (NOTIFICATIONS_DIR, 0o2770),
    ):
        _mkdir(path, mode)


def _fsync_dir(path: Path) -> None:
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def atomic_write(path: Path, data: bytes, mode: int = 0o600) -> None:
    _mkdir(path.parent, stat.S_IMODE(path.parent.stat().st_mode) if path.parent.exists() else 0o700)
    temp = path.parent / f".{path.name}.{os.getpid()}.{uuid.uuid4().hex}.tmp"
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), mode)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp, path)
        os.chmod(path, mode)
        _fsync_dir(path.parent)
    except Exception:
        try:
            temp.unlink()
        except FileNotFoundError:
            pass
        raise


def atomic_json(path: Path, value: object, mode: int = 0o600) -> None:
    atomic_write(path, canonical_json(value) + b"\n", mode)


def read_bounded_regular(path: Path, maximum: int, *, minimum: int = 1) -> bytes:
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or not minimum <= info.st_size <= maximum:
            raise OSError("file is not a bounded regular file")
        data = bytearray()
        while len(data) < info.st_size:
            chunk = os.read(fd, info.st_size - len(data))
            if not chunk:
                break
            data.extend(chunk)
        if len(data) != info.st_size or os.read(fd, 1):
            raise OSError("file changed while reading")
        return bytes(data)
    finally:
        os.close(fd)


def audit_event(event: str, **fields: object) -> None:
    allowed = {
        "request_id", "slug", "project", "branch", "base_branch", "state",
        "actor", "transport", "decision", "pr_url", "error_code", "status",
    }
    record: dict[str, object] = {"ts": utc_now(), "event": event}
    for key, value in fields.items():
        if key in allowed and value not in (None, ""):
            record[key] = value
    try:
        _mkdir(AUDIT_LOG_PATH.parent, 0o750)
        fd = os.open(AUDIT_LOG_PATH, os.O_WRONLY | os.O_APPEND | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o640)
        with os.fdopen(fd, "ab") as handle:
            handle.write(canonical_json(record) + b"\n")
    except OSError as exc:
        log.warning("audit write failed event=%s: %s", event, exc)


def _chgrp(path: Path, group: str) -> None:
    if not group:
        return
    try:
        import grp
        os.chown(path, -1, grp.getgrnam(group).gr_gid)
    except (ImportError, KeyError, OSError):
        pass


def notify(event: str, request_id: str, slug: str, *, error_code: str | None = None) -> None:
    """Write only the typed notification contract; never producer text."""
    if event not in NOTIFICATION_EVENTS or not UUID_RE.fullmatch(request_id) or not SLUG_RE.fullmatch(slug):
        log.warning("refusing invalid notification event=%r rid=%r slug=%r", event, request_id, slug)
        return
    payload: dict[str, object] = {
        "schema_version": 1,
        "event": event,
        "request_id": request_id,
        "slug": slug,
    }
    if error_code is not None:
        if not re.fullmatch(r"[a-z][a-z0-9_]{0,63}", error_code):
            error_code = "internal"
        payload["error_code"] = error_code
    try:
        _mkdir(NOTIFICATIONS_DIR, 0o2770)
        name = f"{uuid.uuid4().hex}.json"
        atomic_json(NOTIFICATIONS_DIR / name, payload, 0o660)
        _chgrp(NOTIFICATIONS_DIR / name, BOT_GROUP)
    except OSError as exc:
        log.warning("notification write failed event=%s: %s", event, exc)


def schema_path() -> Path:
    if SCHEMA_PATH.is_file():
        return SCHEMA_PATH
    candidate = Path(__file__).resolve().parents[2] / "schema/pr-request.schema.json"
    return candidate


def load_schema() -> dict[str, object]:
    global _schema_cache
    if _schema_cache is None:
        try:
            value = json.loads(schema_path().read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as exc:
            raise RequestError("schema_unavailable", 503) from exc
        if not isinstance(value, dict):
            raise RequestError("schema_unavailable", 503)
        _schema_cache = value
    return _schema_cache


def _matches_type(value: object, expected: str) -> bool:
    if expected == "string":
        return isinstance(value, str)
    if expected == "object":
        return isinstance(value, dict)
    if expected == "null":
        return value is None
    if expected == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    return False


def validate_json_schema(value: object) -> dict[str, object]:
    schema = load_schema()
    if not isinstance(value, dict):
        raise RequestError("invalid_schema", detail="request body must be a JSON object")
    required = schema.get("required", [])
    if not isinstance(required, list):
        raise RequestError("schema_unavailable", 503)
    for field in required:
        if field not in value:
            raise RequestError("invalid_schema", detail=f"missing required field: {field}")
    properties = schema.get("properties", {})
    if not isinstance(properties, dict):
        raise RequestError("schema_unavailable", 503)
    extras = sorted(set(value) - set(properties))
    if schema.get("additionalProperties") is False and extras:
        raise RequestError("invalid_schema", detail=f"unexpected field: {extras[0]}")
    for field, rules_value in properties.items():
        if field not in value or not isinstance(rules_value, dict):
            continue
        item = value[field]
        if "const" in rules_value and item != rules_value["const"]:
            raise RequestError("invalid_schema", detail=f"field must equal {rules_value['const']}: {field}")
        expected = rules_value.get("type")
        if isinstance(expected, str) and not _matches_type(item, expected):
            raise RequestError("invalid_schema", detail=f"field has wrong type: {field}")
        one_of = rules_value.get("oneOf")
        if isinstance(one_of, list) and not any(
            isinstance(option, dict)
            and _matches_type(item, str(option.get("type")))
            and (not isinstance(item, str) or not option.get("pattern") or re.fullmatch(str(option["pattern"]), item))
            for option in one_of
        ):
            raise RequestError("invalid_schema", detail=f"field does not match oneOf: {field}")
        if isinstance(item, str):
            if "maxLength" in rules_value and len(item) > int(rules_value["maxLength"]):
                raise RequestError("invalid_schema", detail=f"field too long: {field}")
            if rules_value.get("pattern") and not re.fullmatch(str(rules_value["pattern"]), item):
                raise RequestError("invalid_schema", detail=f"field does not match pattern: {field}")
    return value


def validate_request(value: object) -> ValidatedRequest:
    req = validate_json_schema(value)
    request_id = str(req["request_id"]).lower()
    created_at = str(req["created_at"])
    try:
        datetime.strptime(created_at, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError as exc:
        raise RequestError("invalid_created_at") from exc
    title = str(req["title"])
    body = str(req["body"])
    if len(title) > TITLE_MAX or "\n" in title or "\r" in title:
        raise RequestError("invalid_title")
    if len(body.encode("utf-8")) > BODY_MAX:
        raise RequestError("body_too_large")
    branch = str(req["branch"])
    try:
        checked = subprocess.run(
            ["/usr/bin/git", "check-ref-format", "--branch", branch],
            env=broker_git_env(), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            timeout=5,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired) as exc:
        raise RequestError("git_unavailable", 503) from exc
    if checked.returncode != 0:
        raise RequestError("invalid_branch")
    common = req["common_base_oid"]
    return ValidatedRequest(
        2, request_id, created_at, str(req["slug"]), branch, title, body,
        str(req["head_oid"]), str(common) if common is not None else None,
    )


def rate_limit(slug: str) -> None:
    now = time.time()
    bucket = [stamp for stamp in _recent_requests.get(slug, []) if stamp > now - 3600]
    if len(bucket) >= RATE_LIMIT_PER_HOUR:
        raise RequestError("rate_limited", 429)
    bucket.append(now)
    _recent_requests[slug] = bucket


def broker_git_env(*, token_path: Path | None = None, allowed_host: str | None = None, forge: str = "github") -> dict[str, str]:
    env = {
        "HOME": "/tmp",
        "LANG": "C",
        "LC_ALL": "C",
        "PATH": "/usr/bin:/bin:/usr/local/bin",
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_SYSTEM": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_ATTR_NOSYSTEM": "1",
        "GIT_NO_REPLACE_OBJECTS": "1",
        "GIT_NO_LAZY_FETCH": "1",
        "GIT_ALTERNATE_OBJECT_DIRECTORIES": "",
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_PAGER": "cat",
        "GIT_ASKPASS": ASKPASS_PATH,
        "FIELDWORK_BROKER_ASKPASS_FORGE": forge,
    }
    if token_path is not None:
        env["FIELDWORK_BROKER_TOKEN_PATH"] = str(token_path)
    if allowed_host is not None:
        env["FIELDWORK_BROKER_ALLOWED_HOST"] = allowed_host
    return env


def _run_limits() -> None:
    try:
        resource.setrlimit(resource.RLIMIT_CPU, (180, 180))
        resource.setrlimit(resource.RLIMIT_AS, (1024 * 1024 * 1024, 1024 * 1024 * 1024))
        resource.setrlimit(resource.RLIMIT_FSIZE, (256 * 1024 * 1024, 256 * 1024 * 1024))
    except (ValueError, OSError):
        pass


def run_git(
    args: list[str], deadline: Deadline, *, cwd: Path | None = None,
    env: dict[str, str] | None = None, input_file=None, input_bytes: bytes | None = None,
    timeout_cap: float = 120, check: bool = True, text: bool = False,
) -> subprocess.CompletedProcess:
    try:
        result = subprocess.run(
            ["/usr/bin/git", *args], cwd=cwd, env=env or broker_git_env(),
            stdin=input_file, input=input_bytes if input_file is None else None,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
            timeout=deadline.remaining(timeout_cap), text=text, preexec_fn=_run_limits,
        )
    except FileNotFoundError as exc:
        raise RequestError("git_unavailable", 503) from exc
    except subprocess.TimeoutExpired as exc:
        raise RequestError("processing_timeout", 504) from exc
    if check and result.returncode != 0:
        detail_value = result.stderr if text else bytes(result.stderr).decode("utf-8", "replace")
        log.warning("git failed args=%s detail=%s", args[:4], detail_value[:500])
        raise RequestError("git_failed", 502)
    return result


def _parse_url(url: str) -> tuple[str, int, urllib.parse.SplitResult]:
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
        raise RequestError("unsafe_forge_url", 503)
    try:
        port = parsed.port or 443
    except ValueError as exc:
        raise RequestError("unsafe_forge_url", 503) from exc
    return parsed.hostname.lower(), port, parsed


def resolve_addresses(host: str, port: int, allow_private: bool, deadline: Deadline) -> list[str]:
    # libc DNS has no portable per-call timeout. Keep it off the serial broker
    # thread so a stuck resolver cannot defeat the processing deadline.
    result: queue.Queue[object] = queue.Queue(maxsize=1)
    def lookup() -> None:
        try:
            result.put(socket.getaddrinfo(host, port, type=socket.SOCK_STREAM))
        except BaseException as exc:
            result.put(exc)
    worker = threading.Thread(target=lookup, name="fieldwork-dns", daemon=True)
    worker.start()
    try:
        resolved = result.get(timeout=deadline.remaining(10))
    except queue.Empty as exc:
        raise RequestError("forge_dns_timeout", 504) from exc
    if isinstance(resolved, BaseException):
        if isinstance(resolved, socket.gaierror):
            raise RequestError("forge_dns_failed", 502) from resolved
        raise RequestError("forge_dns_failed", 502) from resolved
    answers = resolved
    addresses: list[str] = []
    for answer in answers:
        address = answer[4][0].split("%", 1)[0]
        if address not in addresses:
            addresses.append(address)
    if not addresses:
        raise RequestError("forge_dns_failed", 502)
    if not allow_private:
        for address in addresses:
            try:
                if not ipaddress.ip_address(address).is_global:
                    raise RequestError("private_network_rejected", 403)
            except ValueError as exc:
                raise RequestError("forge_dns_failed", 502) from exc
    return addresses


def ca_bundle(policy: dict[str, object]) -> Path | None:
    ref = policy.get("ca_bundle_ref")
    if ref is None:
        return None
    digest = str(ref).removeprefix("sha256:")
    path = CA_DIR / f"{digest}.pem"
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        with os.fdopen(fd, "rb") as handle:
            info = os.fstat(handle.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_size > 4 * 1024 * 1024:
                raise OSError("CA bundle is not a bounded regular file")
            data = handle.read(4 * 1024 * 1024 + 1)
    except OSError as exc:
        raise RequestError("ca_bundle_unavailable", 503) from exc
    if hashlib.sha256(data).hexdigest() != digest:
        raise RequestError("ca_bundle_tampered", 503)
    return path


class PinnedHTTPSConnection(http.client.HTTPSConnection):
    def __init__(self, host: str, port: int, address: str, context: ssl.SSLContext, timeout: float):
        super().__init__(host, port=port, context=context, timeout=timeout)
        self._address = address

    def connect(self) -> None:
        raw = socket.create_connection((self._address, self.port), self.timeout)
        peer = raw.getpeername()[0].split("%", 1)[0]
        if ipaddress.ip_address(peer) != ipaddress.ip_address(self._address):
            raw.close()
            raise OSError("connected peer does not match the DNS-pinned address")
        self.sock = self._context.wrap_socket(raw, server_hostname=self.host)


def api_json(
    policy: dict[str, object], method: str, url: str, deadline: Deadline, *,
    headers: dict[str, str] | None = None, payload: object | None = None,
    allowed_status: set[int] | None = None,
) -> tuple[int, object, dict[str, str]]:
    api_host, api_port, api_base = _parse_url(str(policy["api_base_url"]))
    host, port, parsed = _parse_url(url)
    if (host, port) != (api_host, api_port):
        raise RequestError("unsafe_forge_url", 503)
    base_path = api_base.path.rstrip("/")
    if base_path and not (parsed.path == base_path or parsed.path.startswith(base_path + "/")):
        raise RequestError("unsafe_forge_url", 503)
    addresses = resolve_addresses(host, port, bool(policy["allow_private_network"]), deadline)
    bundle = ca_bundle(policy)
    context = ssl.create_default_context(cafile=str(bundle) if bundle else None)
    body = None if payload is None else canonical_json(payload)
    request_headers = {"Accept": "application/json", "User-Agent": "fieldwork-pr-broker/2"}
    if body is not None:
        request_headers["Content-Type"] = "application/json"
    if headers:
        request_headers.update(headers)
    last_error: Exception | None = None
    for address in addresses:
        conn = PinnedHTTPSConnection(host, port, address, context, deadline.remaining(30))
        try:
            target = urllib.parse.urlunsplit(("", "", parsed.path or "/", parsed.query, ""))
            conn.request(method, target, body=body, headers=request_headers)
            response = conn.getresponse()
            raw = response.read(2 * 1024 * 1024 + 1)
            if len(raw) > 2 * 1024 * 1024:
                raise RequestError("forge_response_too_large", 502)
            if 300 <= response.status < 400:
                raise RequestError("forge_redirect_refused", 502)
            try:
                decoded = json.loads(raw) if raw else {}
            except json.JSONDecodeError as exc:
                raise RequestError("forge_invalid_json", 502) from exc
            allowed = allowed_status or set(range(200, 300))
            if response.status not in allowed:
                if response.status in (401, 403):
                    raise RequestError("forge_permission_denied", 403)
                if response.status == 404:
                    raise RequestError("forge_not_found", 404)
                raise RequestError("forge_request_failed", 502, extra={"forge_status": response.status})
            return response.status, decoded, {key.lower(): value for key, value in response.getheaders()}
        except RequestError:
            raise
        except (OSError, ssl.SSLError, http.client.HTTPException) as exc:
            last_error = exc
        finally:
            conn.close()
    raise RequestError("forge_unreachable", 502, detail=str(last_error) if last_error else None)


def _token_file_nonempty(path: Path) -> None:
    try:
        read_bounded_regular(path, 64 * 1024)
    except OSError as exc:
        raise RequestError("credential_unavailable", 503) from exc


def _github_app_jwt(deadline: Deadline) -> str:
    if not GITHUB_APP_ID.isdigit() or not GITHUB_APP_INSTALLATION_ID.isdigit() or not GITHUB_APP_PRIVATE_KEY_PATH.is_file():
        raise RequestError("github_app_unconfigured", 503)
    now = int(time.time())
    header = base64.urlsafe_b64encode(b'{"alg":"RS256","typ":"JWT"}').decode().rstrip("=")
    payload = base64.urlsafe_b64encode(canonical_json({"iat": now - 60, "exp": now + 540, "iss": GITHUB_APP_ID})).decode().rstrip("=")
    signing = f"{header}.{payload}".encode("ascii")
    try:
        result = subprocess.run(
            ["/usr/bin/openssl", "dgst", "-sha256", "-sign", str(GITHUB_APP_PRIVATE_KEY_PATH)],
            input=signing, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env={"PATH": "/usr/bin:/bin"}, timeout=deadline.remaining(10), check=True,
            preexec_fn=_run_limits,
        )
    except (FileNotFoundError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
        raise RequestError("github_app_sign_failed", 503) from exc
    signature = base64.urlsafe_b64encode(result.stdout).decode().rstrip("=")
    return f"{header}.{payload}.{signature}"


@contextlib.contextmanager
def credential(policy: dict[str, object], deadline: Deadline):
    if policy["forge"] != "github" or GITHUB_CREDENTIAL_MODE == "pat":
        _token_file_nonempty(TOKEN_PATH)
        yield TOKEN_PATH
        return
    if GITHUB_CREDENTIAL_MODE != "app":
        raise RequestError("credential_mode_unsupported", 503)
    jwt = _github_app_jwt(deadline)
    url = f"{policy['api_base_url']}/app/installations/{GITHUB_APP_INSTALLATION_ID}/access_tokens"
    _, response, _ = api_json(
        policy, "POST", url, deadline,
        headers={"Authorization": f"Bearer {jwt}", "Accept": "application/vnd.github+json"}, payload={},
    )
    if not isinstance(response, dict) or not isinstance(response.get("token"), str) or not response["token"]:
        raise RequestError("github_app_token_invalid", 502)
    _mkdir(WORK_DIR, 0o700)
    fd, name = tempfile.mkstemp(prefix=".app-token-", dir=WORK_DIR)
    path = Path(name)
    try:
        with os.fdopen(fd, "w", encoding="ascii") as handle:
            handle.write(response["token"] + "\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(path, 0o600)
        yield path
    finally:
        try:
            path.unlink()
        except FileNotFoundError:
            pass


def _git_resolve_arg(host: str, port: int, address: str) -> str:
    rendered = f"[{address}]" if ":" in address else address
    return f"http.curloptResolve={host}:{port}:{rendered}"


def network_git(
    policy: dict[str, object], args: list[str], url: str, token_path: Path,
    deadline: Deadline, *, cwd: Path | None = None, timeout_cap: float = 120,
) -> subprocess.CompletedProcess:
    host, port, _ = _parse_url(url)
    addresses = resolve_addresses(host, port, bool(policy["allow_private_network"]), deadline)
    env = broker_git_env(token_path=token_path, allowed_host=host, forge=str(policy["forge"]))
    bundle = ca_bundle(policy)
    if bundle:
        env["GIT_SSL_CAINFO"] = str(bundle)
    last: subprocess.CompletedProcess | None = None
    for address in addresses:
        full_args = [
            "-c", "http.followRedirects=false",
            "-c", _git_resolve_arg(host, port, address),
            "-c", "credential.helper=",
            *args,
        ]
        last = run_git(full_args, deadline, cwd=cwd, env=env, timeout_cap=timeout_cap, check=False)
        if last.returncode == 0:
            return last
    log.warning("network git failed args=%s stderr=%s", args[:3], bytes(last.stderr if last else b"").decode("utf-8", "replace")[:500])
    raise RequestError("git_forge_failed", 502)


def scan_directory(path: Path, deadline: Deadline) -> None:
    gitleaks = next(
        (candidate for candidate in ("/usr/local/bin/gitleaks", "/opt/homebrew/bin/gitleaks", "/usr/bin/gitleaks") if Path(candidate).is_file()),
        None,
    )
    if gitleaks is None:
        raise RequestError("scan_unavailable", 503)
    try:
        result = subprocess.run(
            [gitleaks, "dir", str(path), "--no-banner", "--redact", "--exit-code", "1"],
            env={"HOME": "/tmp", "PATH": "/usr/bin:/bin:/usr/local/bin", "LANG": "C", "LC_ALL": "C"},
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=deadline.remaining(30), preexec_fn=_run_limits,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired) as exc:
        raise RequestError("scan_unavailable", 503) from exc
    if result.returncode == 1:
        raise RequestError("secret_detected")
    if result.returncode != 0:
        raise RequestError("scan_unavailable", 503)


def scan_title_body(req: ValidatedRequest, deadline: Deadline) -> None:
    with tempfile.TemporaryDirectory(prefix="metadata-", dir=WORK_DIR) as name:
        path = Path(name)
        atomic_write(path / "title.txt", req.title.encode("utf-8"), 0o600)
        atomic_write(path / "body.txt", req.body.encode("utf-8"), 0o600)
        scan_directory(path, deadline)


def _object_lines(
    repo: Path, args: list[str], deadline: Deadline, maximum: int,
    error_code: str, *, input_file=None,
) -> list[str]:
    """Stream bounded line-oriented Git output and kill on the first excess line."""
    values: list[str] = []
    with tempfile.TemporaryFile() as errors:
        try:
            process = subprocess.Popen(
                ["/usr/bin/git", *args], cwd=repo, env=broker_git_env(),
                stdin=input_file if input_file is not None else subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=errors,
                preexec_fn=_run_limits,
            )
        except FileNotFoundError as exc:
            raise RequestError("git_unavailable", 503) from exc
        assert process.stdout is not None
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        buffered = bytearray()
        try:
            while True:
                events = selector.select(deadline.remaining(60))
                if not events:
                    raise RequestError("processing_timeout", 504)
                chunk = os.read(process.stdout.fileno(), 65536)
                if not chunk:
                    break
                buffered.extend(chunk)
                while b"\n" in buffered:
                    raw, _, remainder = buffered.partition(b"\n")
                    buffered = bytearray(remainder)
                    if len(raw) > 4096:
                        raise RequestError("invalid_pack")
                    if raw:
                        values.append(raw.decode("ascii", "strict"))
                        if len(values) > maximum:
                            raise RequestError(error_code, 413)
            if buffered:
                if len(buffered) > 4096:
                    raise RequestError("invalid_pack")
                values.append(bytes(buffered).decode("ascii", "strict"))
                if len(values) > maximum:
                    raise RequestError(error_code, 413)
            if process.wait(timeout=deadline.remaining(5)) != 0:
                errors.seek(0)
                log.warning("git stream failed args=%s detail=%s", args[:4], errors.read(500).decode("utf-8", "replace"))
                raise RequestError("git_failed", 502)
            return values
        except (UnicodeDecodeError, subprocess.TimeoutExpired) as exc:
            raise RequestError("invalid_pack" if isinstance(exc, UnicodeDecodeError) else "processing_timeout", 504 if isinstance(exc, subprocess.TimeoutExpired) else 400) from exc
        finally:
            selector.close()
            if process.poll() is None:
                process.kill()
                process.wait()
            process.stdout.close()


def _object_info(repo: Path, oids: list[str], deadline: Deadline, max_objects: int, max_bytes: int, error_code: str) -> dict[str, tuple[str, int]]:
    if len(oids) > max_objects:
        raise RequestError(error_code)
    payload = "".join(f"{oid}\n" for oid in oids).encode("ascii")
    result = run_git(
        ["cat-file", "--batch-check=%(objectname) %(objecttype) %(objectsize)"],
        deadline, cwd=repo, input_bytes=payload, timeout_cap=60,
    )
    info: dict[str, tuple[str, int]] = {}
    total = 0
    try:
        lines = bytes(result.stdout).decode("ascii", "strict").splitlines()
    except UnicodeDecodeError as exc:
        raise RequestError("invalid_pack") from exc
    for line in lines:
        parts = line.split()
        if len(parts) != 3 or not OID_RE.fullmatch(parts[0]) or not parts[2].isdigit():
            raise RequestError("invalid_pack")
        size = int(parts[2])
        total += size
        if len(info) >= max_objects or total > max_bytes:
            raise RequestError(error_code)
        info[parts[0]] = (parts[1], size)
    return info


def _parse_tree_names(raw: bytes) -> list[bytes]:
    names: list[bytes] = []
    cursor = 0
    while cursor < len(raw):
        space = raw.find(b" ", cursor)
        nul = raw.find(b"\0", space + 1)
        if space < 0 or nul < 0 or nul + 21 > len(raw):
            raise RequestError("invalid_tree")
        names.append(raw[space + 1:nul])
        cursor = nul + 21
    return names


def validate_pack_layout(raw: bytes, physical: list[str]) -> None:
    """Enforce per-object and delta-depth caps from verify-pack output."""
    verified_oids: set[str] = set()
    try:
        lines = raw.decode("ascii", "strict").splitlines()
    except UnicodeDecodeError as exc:
        raise RequestError("invalid_pack") from exc
    for line in lines:
        parts = line.split()
        if not parts or not OID_RE.fullmatch(parts[0]):
            continue
        if len(parts) not in (5, 7) or not parts[2].isdigit():
            raise RequestError("invalid_pack")
        if int(parts[2]) > PACK_MAX_OBJECT_BYTES:
            raise RequestError("pack_limits_exceeded", 413)
        if len(parts) == 7 and (not parts[5].isdigit() or int(parts[5]) > PACK_MAX_DELTA_DEPTH):
            raise RequestError("pack_limits_exceeded", 413)
        verified_oids.add(parts[0])
    if verified_oids != set(physical):
        raise RequestError("invalid_pack")


def scan_objects(repo: Path, object_info: dict[str, tuple[str, int]], deadline: Deadline) -> None:
    with tempfile.TemporaryDirectory(prefix="scan-", dir=WORK_DIR) as name:
        root = Path(name)
        blob_dir = root / "blobs"
        text_dir = root / "text"
        blob_dir.mkdir(mode=0o700)
        text_dir.mkdir(mode=0o700)
        blob_fd = os.open(blob_dir, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            tree_names = bytearray()
            commit_index = 0
            for oid, (kind, _size) in object_info.items():
                result = run_git(["cat-file", kind, oid], deadline, cwd=repo, timeout_cap=30)
                raw = bytes(result.stdout)
                if kind == "blob":
                    fd = os.open(oid, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600, dir_fd=blob_fd)
                    with os.fdopen(fd, "wb") as handle:
                        handle.write(raw)
                elif kind == "tree":
                    for item in _parse_tree_names(raw):
                        tree_names.extend(item.hex().encode("ascii") + b" " + item + b"\n")
                elif kind == "commit":
                    atomic_write(text_dir / f"commit-{commit_index:05d}.txt", raw, 0o600)
                    commit_index += 1
                else:
                    raise RequestError("unexpected_object_type")
            atomic_write(text_dir / "tree-names.txt", bytes(tree_names), 0o600)
        finally:
            os.close(blob_fd)
        scan_directory(root, deadline)


def pack_uses_sha256(pack_path: Path, parent: Path, deadline: Deadline) -> bool:
    """Identify a valid SHA-256 pack after SHA-1 indexing fails.

    Pack headers do not carry an object-format flag. A second bounded index in
    an explicitly verified SHA-256 repository is the deterministic test; it
    cannot turn a malformed pack into an accepted request.
    """
    probe = parent / "sha256-format-probe"
    initialized = run_git(
        ["init", "--bare", "--object-format=sha256", str(probe)],
        deadline, timeout_cap=20, check=False,
    )
    if initialized.returncode != 0:
        return False
    shown = run_git(["rev-parse", "--show-object-format"], deadline, cwd=probe, timeout_cap=5, check=False)
    if shown.returncode != 0 or bytes(shown.stdout).strip() != b"sha256":
        return False
    with open(pack_path, "rb") as pack_handle:
        indexed = run_git(
            ["-c", "pack.threads=1", "index-pack", "--stdin", "--strict", f"--max-input-size={PACK_MAX_INPUT}"],
            deadline, cwd=probe, input_file=pack_handle, timeout_cap=120, check=False,
        )
    if indexed.returncode != 0:
        return False
    output = bytes(indexed.stdout).decode("ascii", "replace").strip().splitlines()
    return bool(output and re.fullmatch(r"(?:pack\s+)?[0-9a-f]{64}", output[-1]))


@contextlib.contextmanager
def quarantine(
    req: ValidatedRequest, pack_path: Path, policy: dict[str, object], token_path: Path,
    deadline: Deadline,
):
    temp = Path(tempfile.mkdtemp(prefix="quarantine-", dir=WORK_DIR))
    try:
        run_git(["init", "--bare", str(temp)], deadline, timeout_cap=20)
        object_format = run_git(["rev-parse", "--show-object-format"], deadline, cwd=temp, timeout_cap=5)
        if bytes(object_format.stdout).decode("ascii", "replace").strip() != "sha1":
            raise RequestError("unsupported_object_format")
        base_url = f"{str(policy['git_base_url']).rstrip('/')}/{policy['project']}.git"
        network_git(
            policy,
            ["fetch", "--no-tags", base_url, f"refs/heads/{policy['base_branch']}:refs/fieldwork/base"],
            base_url, token_path, deadline, cwd=temp,
        )
        if req.common_base_oid is not None:
            ancestor = run_git(
                ["merge-base", "--is-ancestor", req.common_base_oid, "refs/fieldwork/base"],
                deadline, cwd=temp, timeout_cap=20, check=False,
            )
            if ancestor.returncode != 0:
                raise RequestError("stale_base", 409)
        try:
            info = pack_path.stat()
        except OSError as exc:
            raise RequestError("pack_missing") from exc
        if not stat.S_ISREG(info.st_mode) or info.st_size <= 0 or info.st_size > PACK_MAX_INPUT:
            raise RequestError("pack_too_large", 413)
        with open(pack_path, "rb") as pack_handle:
            indexed = run_git(
                ["-c", "pack.threads=1", "index-pack", "--stdin", "--strict", f"--max-input-size={PACK_MAX_INPUT}"],
                deadline, cwd=temp, input_file=pack_handle, timeout_cap=120, check=False,
            )
        if indexed.returncode != 0:
            detail = bytes(indexed.stderr).decode("utf-8", "replace").lower()
            if (
                "object format" in detail
                or "hash mismatch" in detail and "sha256" in detail
                or pack_uses_sha256(pack_path, temp, deadline)
            ):
                raise RequestError("unsupported_object_format")
            raise RequestError("invalid_pack")
        hash_text = bytes(indexed.stdout).decode("ascii", "replace").strip().splitlines()[-1].split()[-1]
        if not re.fullmatch(r"[0-9a-f]{40}", hash_text):
            raise RequestError("invalid_pack")
        index_path = temp / f"objects/pack/pack-{hash_text}.idx"
        if not index_path.is_file():
            raise RequestError("invalid_pack")
        with open(index_path, "rb") as index_handle:
            shown = _object_lines(
                temp, ["show-index"], deadline, PACK_MAX_OBJECTS,
                "pack_limits_exceeded", input_file=index_handle,
            )
        physical: list[str] = []
        for line in shown:
            parts = line.split()
            if len(parts) < 2 or not OID_RE.fullmatch(parts[1]):
                raise RequestError("invalid_pack")
            physical.append(parts[1])
        physical_info = _object_info(temp, physical, deadline, PACK_MAX_OBJECTS, PACK_MAX_BYTES, "pack_limits_exceeded")
        if any(size > PACK_MAX_OBJECT_BYTES for _kind, size in physical_info.values()):
            raise RequestError("pack_limits_exceeded", 413)
        verified = run_git(["verify-pack", "-v", str(index_path)], deadline, cwd=temp, timeout_cap=60)
        validate_pack_layout(bytes(verified.stdout), physical)
        if req.common_base_oid is not None:
            claimed = run_git(
                ["merge-base", "--is-ancestor", req.common_base_oid, req.head_oid],
                deadline, cwd=temp, timeout_cap=20, check=False,
            )
            if claimed.returncode != 0:
                raise RequestError("invalid_base_claim")
            expected_args = ["rev-list", "--objects", "--no-object-names", req.head_oid, "--not", req.common_base_oid]
        else:
            expected_args = ["rev-list", "--objects", "--no-object-names", req.head_oid]
        expected = set(_object_lines(temp, expected_args, deadline, PACK_MAX_OBJECTS + 1, "pack_limits_exceeded"))
        if not set(physical).issubset(expected):
            raise RequestError("unexpected_objects")
        kind = run_git(["cat-file", "-t", req.head_oid], deadline, cwd=temp, timeout_cap=10, check=False)
        if kind.returncode != 0 or bytes(kind.stdout).strip() != b"commit":
            raise RequestError("head_not_commit")
        related = run_git(["merge-base", "refs/fieldwork/base", req.head_oid], deadline, cwd=temp, timeout_cap=20, check=False)
        if related.returncode != 0 or not bytes(related.stdout).strip():
            raise RequestError("unrelated_history")
        delta = _object_lines(
            temp,
            ["rev-list", "--objects", "--no-object-names", req.head_oid, "--not", "refs/fieldwork/base"],
            deadline, SCAN_MAX_OBJECTS, "scan_range_too_large",
        )
        delta_info = _object_info(temp, delta, deadline, SCAN_MAX_OBJECTS, SCAN_MAX_BYTES, "scan_range_too_large")
        if SCAN_RANGE:
            scan_objects(temp, delta_info, deadline)
        yield temp
    finally:
        shutil.rmtree(temp, ignore_errors=True)


def _mac_key() -> bytes:
    try:
        data = read_bounded_regular(MAC_KEY_PATH, 4096, minimum=32)
    except OSError as exc:
        raise RequestError("mac_key_unavailable", 503) from exc
    return data


def sign_record(record: dict[str, object]) -> dict[str, object]:
    value = dict(record)
    value.pop("mac", None)
    value["mac"] = hmac.new(_mac_key(), canonical_json(value), hashlib.sha256).hexdigest()
    return value


def verify_record(value: object) -> dict[str, object]:
    if not isinstance(value, dict) or not isinstance(value.get("mac"), str):
        raise RequestError("metadata_tampered")
    expected = sign_record(value)["mac"]
    if not hmac.compare_digest(str(value["mac"]), str(expected)):
        raise RequestError("metadata_tampered")
    return value


def _record_path(request_id: str) -> Path:
    return PENDING_META_DIR / f"{request_id}.json"


def _pack_path(request_id: str) -> Path:
    return PENDING_PACK_DIR / f"{request_id}.pack"


def _tombstone_path(request_id: str) -> Path:
    return TOMBSTONE_DIR / f"{request_id}.json"


def load_json_file(path: Path, *, maximum: int = 256 * 1024) -> object:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags)
    try:
        handle = os.fdopen(fd, "r", encoding="utf-8")
        fd = -1
        with handle:
            info = os.fstat(handle.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_size > maximum:
                raise RequestError("metadata_tampered")
            return json.load(handle)
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise RequestError("metadata_tampered") from exc
    finally:
        if fd >= 0:
            try:
                os.close(fd)
            except OSError:
                pass


def load_record(request_id: str) -> dict[str, object]:
    try:
        return verify_record(load_json_file(_record_path(request_id)))
    except FileNotFoundError:
        try:
            return verify_record(load_json_file(_tombstone_path(request_id)))
        except FileNotFoundError as exc:
            raise RequestError("unknown_request", 404) from exc


def write_record(record: dict[str, object]) -> dict[str, object]:
    signed = sign_record(record)
    atomic_json(_record_path(str(signed["request_id"])), signed, 0o640)
    _chgrp(_record_path(str(signed["request_id"])), BOT_GROUP)
    return signed


def transition(record: dict[str, object], state: str, **fields: object) -> dict[str, object]:
    if state not in ACTIVE_STATES | TERMINAL_STATES:
        raise RequestError("invalid_state", 500)
    value = dict(record)
    value.pop("mac", None)
    value.update(fields)
    value["state"] = state
    value["updated_at"] = utc_now()
    return write_record(value)


def terminalize(record: dict[str, object], state: str, **fields: object) -> dict[str, object]:
    value = transition(record, state, **fields)
    request_id = str(value["request_id"])
    atomic_json(_tombstone_path(request_id), value, 0o600)
    try:
        _record_path(request_id).unlink()
        _fsync_dir(PENDING_META_DIR)
    except FileNotFoundError:
        pass
    try:
        _pack_path(request_id).unlink()
        _fsync_dir(PENDING_PACK_DIR)
    except FileNotFoundError:
        pass
    return value


def reserve_request_id(req: ValidatedRequest) -> None:
    _mkdir(LEDGER_DIR, 0o700)
    path = LEDGER_DIR / f"{req.request_id}.json"
    fd = None
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    except FileExistsError:
        try:
            record = load_record(req.request_id)
        except RequestError as exc:
            if exc.code == "unknown_request":
                raise RequestError("duplicate_expired", 409) from exc
            raise
        raise RequestError("duplicate_request", 409, extra=status_payload(record))
    try:
        data = canonical_json({"request_id": req.request_id, "accepted_at": utc_now()}) + b"\n"
        os.write(fd, data)
        os.fsync(fd)
    finally:
        if fd is not None:
            os.close(fd)
    _fsync_dir(LEDGER_DIR)


def rollback_reservation(request_id: str) -> None:
    """Roll back an acceptance that never reached its first durable state."""
    for path, parent in (
        (_record_path(request_id), PENDING_META_DIR),
        (_pack_path(request_id), PENDING_PACK_DIR),
        (LEDGER_DIR / f"{request_id}.json", LEDGER_DIR),
    ):
        try:
            path.unlink()
            _fsync_dir(parent)
        except FileNotFoundError:
            pass


def existing_request(request_id: str) -> dict[str, object] | None:
    """Return durable status for a replay before charging or forge I/O."""
    path = LEDGER_DIR / f"{request_id}.json"
    try:
        info = path.lstat()
    except FileNotFoundError:
        return None
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        raise RequestError("ledger_tampered", 503)
    try:
        return status_payload(load_record(request_id), ok=True)
    except RequestError as exc:
        if exc.code == "unknown_request":
            raise RequestError("duplicate_expired", 409) from exc
        raise


def persist_pack(request_id: str, source: Path, digest: str) -> None:
    target = _pack_path(request_id)
    temp = target.parent / f".{request_id}.{os.getpid()}.tmp"
    source_fd = os.open(source, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    out_fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    hasher = hashlib.sha256()
    try:
        while True:
            chunk = os.read(source_fd, 65536)
            if not chunk:
                break
            hasher.update(chunk)
            os.write(out_fd, chunk)
        os.fsync(out_fd)
    finally:
        os.close(source_fd)
        os.close(out_fd)
    if not hmac.compare_digest(hasher.hexdigest(), digest):
        temp.unlink(missing_ok=True)
        raise RequestError("pack_changed")
    os.replace(temp, target)
    _fsync_dir(target.parent)


def pack_digest(path: Path) -> str:
    hasher = hashlib.sha256()
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        while True:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            hasher.update(chunk)
    finally:
        os.close(fd)
    return hasher.hexdigest()


def verify_stored_pack(record: dict[str, object]) -> Path:
    path = _pack_path(str(record["request_id"]))
    try:
        digest = pack_digest(path)
    except OSError as exc:
        raise RequestError("metadata_tampered") from exc
    if not hmac.compare_digest(digest, str(record.get("pack_sha256", ""))):
        raise RequestError("metadata_tampered")
    return path


def request_from_record(record: dict[str, object]) -> ValidatedRequest:
    return validate_request({key: record[key] for key in (
        "schema_version", "request_id", "created_at", "slug", "branch", "title",
        "body", "head_oid", "common_base_oid",
    )})


def _auth_headers(policy: dict[str, object], token_path: Path) -> dict[str, str]:
    try:
        token = read_bounded_regular(token_path, 64 * 1024).decode("ascii", "strict").strip()
    except (OSError, UnicodeError) as exc:
        raise RequestError("credential_unavailable", 503) from exc
    if policy["forge"] == "github":
        return {
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        }
    return {"PRIVATE-TOKEN": token}


def remote_branch_oid(policy: dict[str, object], req: ValidatedRequest, token_path: Path, deadline: Deadline) -> str | None:
    url = f"{str(policy['git_base_url']).rstrip('/')}/{policy['project']}.git"
    expected_ref = f"refs/heads/{req.branch}"
    result = network_git(
        policy, ["ls-remote", "--heads", url, expected_ref],
        url, token_path, deadline, timeout_cap=60,
    )
    try:
        lines = bytes(result.stdout).decode("ascii", "strict").strip().splitlines()
    except UnicodeDecodeError as exc:
        raise RequestError("forge_invalid_ref", 502) from exc
    if not lines:
        return None
    fields = lines[0].split() if len(lines) == 1 else []
    if len(fields) != 2 or not OID_RE.fullmatch(fields[0]) or fields[1] != expected_ref:
        raise RequestError("forge_invalid_ref", 502)
    return fields[0]


def broker_preflight(value: object, deadline: Deadline) -> dict[str, object]:
    """Verify one wired repository through the broker-owned credential.

    Protocol v2 stays checkout-blind: the agent supplies only a policy slug,
    and the root-owned policy selects the forge project and base branch.
    """
    if not isinstance(value, dict) or set(value) != {"slug"}:
        raise RequestError("invalid_preflight_request")
    slug = value["slug"]
    if not isinstance(slug, str) or not SLUG_RE.fullmatch(slug):
        raise RequestError("invalid_preflight_request")
    try:
        with policy_lock(POLICY_DIR, slug):
            policy = read_policy(POLICY_DIR, slug)
            url = f"{str(policy['git_base_url']).rstrip('/')}/{policy['project']}.git"
            expected_ref = f"refs/heads/{policy['base_branch']}"
            with credential(policy, deadline) as token_path:
                result = network_git(
                    policy, ["ls-remote", "--heads", url, expected_ref],
                    url, token_path, deadline, timeout_cap=30,
                )
    except PolicyError as exc:
        if str(exc) == "repo_not_wired":
            raise RequestError("repo_not_wired", 404) from exc
        raise RequestError("policy_invalid", 503, detail=str(exc)) from exc
    try:
        lines = bytes(result.stdout).decode("ascii", "strict").strip().splitlines()
    except UnicodeDecodeError as exc:
        raise RequestError("forge_invalid_ref", 502) from exc
    fields = lines[0].split() if len(lines) == 1 else []
    if len(fields) != 2 or not OID_RE.fullmatch(fields[0]) or fields[1] != expected_ref:
        raise RequestError("base_branch_not_found", 404)
    return {"ok": True, "slug": slug, "state": "ready"}


def push_head(repo: Path, policy: dict[str, object], req: ValidatedRequest, token_path: Path, deadline: Deadline) -> None:
    url = f"{str(policy['git_base_url']).rstrip('/')}/{policy['project']}.git"
    network_git(
        policy,
        ["push", "--no-verify", url, f"{req.head_oid}:refs/heads/{req.branch}"],
        url, token_path, deadline, cwd=repo,
    )


def branch_update_is_fast_forward(repo: Path, existing_oid: str, req: ValidatedRequest, deadline: Deadline) -> bool:
    result = run_git(
        ["merge-base", "--is-ancestor", existing_oid, req.head_oid],
        deadline, cwd=repo, timeout_cap=20, check=False,
    )
    return result.returncode == 0


def find_pr(policy: dict[str, object], req: ValidatedRequest, token_path: Path, deadline: Deadline) -> str | None:
    headers = _auth_headers(policy, token_path)
    api = str(policy["api_base_url"]).rstrip("/")
    if policy["forge"] == "github":
        owner = str(policy["project"]).split("/", 1)[0]
        query = urllib.parse.urlencode({"state": "open", "head": f"{owner}:{req.branch}", "base": policy["base_branch"]})
        _, response, _ = api_json(policy, "GET", f"{api}/repos/{policy['project']}/pulls?{query}", deadline, headers=headers)
        if not isinstance(response, list):
            raise RequestError("forge_invalid_json", 502)
        matches = [str(item.get("html_url")) for item in response if isinstance(item, dict) and item.get("html_url")]
    else:
        project = urllib.parse.quote(str(policy["project"]), safe="")
        query = urllib.parse.urlencode({"state": "opened", "source_branch": req.branch, "target_branch": policy["base_branch"]})
        _, response, _ = api_json(policy, "GET", f"{api}/projects/{project}/merge_requests?{query}", deadline, headers=headers)
        if not isinstance(response, list):
            raise RequestError("forge_invalid_json", 502)
        matches = [str(item.get("web_url")) for item in response if isinstance(item, dict) and item.get("web_url")]
    if len(matches) > 1:
        raise RequestError("multiple_pull_requests", 409)
    return matches[0] if matches else None


def create_pr(policy: dict[str, object], req: ValidatedRequest, token_path: Path, deadline: Deadline) -> str:
    headers = _auth_headers(policy, token_path)
    api = str(policy["api_base_url"]).rstrip("/")
    if policy["forge"] == "github":
        payload = {"title": req.title, "body": req.body, "head": req.branch, "base": policy["base_branch"]}
        _, response, _ = api_json(policy, "POST", f"{api}/repos/{policy['project']}/pulls", deadline, headers=headers, payload=payload)
        if not isinstance(response, dict) or not response.get("html_url"):
            raise RequestError("forge_invalid_json", 502)
        url = str(response["html_url"])
        number = response.get("number")
        if isinstance(number, int):
            try:
                api_json(
                    policy, "POST", f"{api}/repos/{policy['project']}/issues/{number}/labels",
                    deadline, headers=headers, payload={"labels": ["ready for review"]},
                )
            except RequestError:
                log.warning("non-fatal ready-for-review label failure rid=%s", req.request_id)
        return url
    project = urllib.parse.quote(str(policy["project"]), safe="")
    payload = {
        "source_branch": req.branch, "target_branch": policy["base_branch"],
        "title": req.title, "description": req.body, "remove_source_branch": False,
    }
    status, response, _ = api_json(
        policy, "POST", f"{api}/projects/{project}/merge_requests", deadline,
        headers=headers, payload=payload, allowed_status=set(range(200, 300)) | {409},
    )
    if status == 409:
        existing = find_pr(policy, req, token_path, deadline)
        if existing:
            return existing
        raise RequestError("pull_request_conflict", 409)
    if not isinstance(response, dict) or not response.get("web_url"):
        raise RequestError("forge_invalid_json", 502)
    return str(response["web_url"])


def _fault(label: str) -> None:
    if os.environ.get("FIELDWORK_BROKER_FAULT") == label:
        raise RuntimeError(f"fault injection: {label}")


def process_record(request_id: str, deadline: Deadline) -> dict[str, object]:
    record = load_record(request_id)
    if record.get("state") in TERMINAL_STATES:
        return record
    slug = str(record["slug"])
    try:
        with policy_lock(POLICY_DIR, slug):
            policy = read_policy(POLICY_DIR, slug)
            if not hmac.compare_digest(policy_digest(policy), str(record.get("policy_digest", ""))):
                return terminalize(record, "needs_operator", error_code="policy_changed")
            req = request_from_record(record)
            pack = verify_stored_pack(record)
            scan_title_body(req, deadline)
            with credential(policy, deadline) as token_path:
                with quarantine(req, pack, policy, token_path, deadline) as repo:
                    if record["state"] == "approved":
                        existing_oid = remote_branch_oid(policy, req, token_path, deadline)
                        if existing_oid is not None and existing_oid != req.head_oid:
                            if not branch_update_is_fast_forward(repo, existing_oid, req, deadline):
                                return terminalize(record, "failed", error_code="branch_conflict")
                            _fault("before_push")
                            push_head(repo, policy, req, token_path, deadline)
                            _fault("after_push")
                        elif existing_oid is None:
                            _fault("before_push")
                            push_head(repo, policy, req, token_path, deadline)
                            _fault("after_push")
                        record = transition(record, "pushed")
                        notify("pushed", request_id, slug)
                    if record["state"] == "pushed":
                        url = find_pr(policy, req, token_path, deadline)
                        if url is None:
                            _fault("before_pr")
                            url = create_pr(policy, req, token_path, deadline)
                            _fault("after_pr")
                        record = transition(record, "pr_created", pr_url=url)
                        notify("pr_created", request_id, slug)
                    if record["state"] == "pr_created":
                        return terminalize(record, "done", pr_url=record.get("pr_url"))
    except PolicyError as exc:
        if str(exc) == "repo_not_wired":
            return terminalize(record, "needs_operator", error_code="repo_not_wired")
        return terminalize(record, "needs_operator", error_code="policy_invalid")
    except RequestError as exc:
        if exc.code in {"metadata_tampered", "policy_changed"}:
            return terminalize(record, "needs_operator", error_code=exc.code)
        return terminalize(record, "failed", error_code=exc.code)
    return load_record(request_id)


def submit_pr(req: ValidatedRequest, incoming_pack: Path, deadline: Deadline) -> dict[str, object]:
    previous = existing_request(req.request_id)
    if previous is not None:
        return previous
    try:
        with policy_lock(POLICY_DIR, req.slug):
            policy = read_policy(POLICY_DIR, req.slug)
            if incoming_pack.stat().st_size > PACK_MAX_INPUT:
                raise RequestError("pack_too_large", 413)
            rate_limit(req.slug)
            scan_title_body(req, deadline)
            with credential(policy, deadline) as token_path:
                with quarantine(req, incoming_pack, policy, token_path, deadline):
                    pass
            digest = pack_digest(incoming_pack)
            now = datetime.now(timezone.utc)
            state = "queued" if policy["approval"] == "require" else "approved"
            record: dict[str, object] = {
                "schema_version": 2,
                "request_id": req.request_id,
                "created_at": req.created_at,
                "slug": req.slug,
                "branch": req.branch,
                "title": req.title,
                "body": req.body,
                "head_oid": req.head_oid,
                "common_base_oid": req.common_base_oid,
                "project": policy["project"],
                "base_branch": policy["base_branch"],
                "policy_digest": policy_digest(policy),
                "pack_sha256": digest,
                "queued_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
                "expires_at": (now + timedelta(seconds=PENDING_EXPIRY_SECONDS)).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "state": state,
                "updated_at": utc_now(),
            }
            reserve_request_id(req)
            try:
                persist_pack(req.request_id, incoming_pack, digest)
                write_record(record)
            except Exception:
                rollback_reservation(req.request_id)
                raise
    except PolicyError as exc:
        if str(exc) == "repo_not_wired":
            raise RequestError("repo_not_wired", 404) from exc
        raise RequestError("policy_invalid", 503, detail=str(exc)) from exc
    audit_event("request_accepted", request_id=req.request_id, slug=req.slug, project=policy["project"], branch=req.branch, state=state)
    if state == "queued":
        notify("queued", req.request_id, req.slug)
        return {"ok": True, "request_id": req.request_id, "state": "queued", "queued": True, "expires_at": record["expires_at"]}
    result = process_record(req.request_id, deadline)
    return status_payload(result, ok=True)


def approve_request(value: object, deadline: Deadline) -> dict[str, object]:
    if not isinstance(value, dict) or set(value) - {"request_id", "decision", "chat_id"}:
        raise RequestError("invalid_approval")
    request_id = value.get("request_id")
    decision = value.get("decision")
    if not isinstance(request_id, str) or not UUID_RE.fullmatch(request_id) or decision not in ("approve", "deny"):
        raise RequestError("invalid_approval")
    record = load_record(request_id)
    if record.get("state") in TERMINAL_STATES:
        return status_payload(record, ok=True)
    if record.get("state") != "queued":
        raise RequestError("invalid_state", 409)
    try:
        expires = datetime.strptime(str(record["expires_at"]), "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except (KeyError, ValueError) as exc:
        raise RequestError("metadata_tampered") from exc
    if expires <= datetime.now(timezone.utc):
        record = terminalize(record, "expired", error_code="expired")
        return status_payload(record, ok=True)
    if decision == "deny":
        record = terminalize(record, "denied")
        notify("denied", request_id, str(record["slug"]))
        audit_event("request_denied", request_id=request_id, slug=record["slug"], decision="deny", actor=value.get("chat_id"))
        return status_payload(record, ok=True)
    # Durable approval is committed before any forge write.
    record = transition(record, "approved", approved_at=utc_now())
    notify("approved", request_id, str(record["slug"]))
    audit_event("request_approved", request_id=request_id, slug=record["slug"], decision="approve", actor=value.get("chat_id"))
    return status_payload(process_record(request_id, deadline), ok=True)


def status_payload(record: dict[str, object], *, ok: bool = True) -> dict[str, object]:
    payload: dict[str, object] = {
        "ok": ok,
        "request_id": record.get("request_id"),
        "state": record.get("state"),
    }
    if record.get("pr_url"):
        payload["url"] = record["pr_url"]
    if record.get("error_code"):
        payload["error"] = record["error_code"]
    if record.get("expires_at") and record.get("state") == "queued":
        payload["expires_at"] = record["expires_at"]
    return payload


def pr_status(value: object) -> dict[str, object]:
    if not isinstance(value, dict) or set(value) != {"request_id"}:
        raise RequestError("invalid_status_request")
    request_id = value["request_id"]
    if not isinstance(request_id, str) or not UUID_RE.fullmatch(request_id):
        raise RequestError("invalid_status_request")
    record = load_record(request_id)
    if record.get("state") == "queued":
        try:
            expires = datetime.strptime(str(record["expires_at"]), "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        except (KeyError, ValueError) as exc:
            raise RequestError("metadata_tampered") from exc
        if expires <= datetime.now(timezone.utc):
            record = terminalize(record, "expired", error_code="expired")
    return status_payload(record)


def sweep_state() -> None:
    now = datetime.now(timezone.utc)
    for path in list(PENDING_META_DIR.glob("*.json")):
        request_id = path.stem
        try:
            record = load_record(request_id)
            if record.get("state") == "queued":
                expires = datetime.strptime(str(record["expires_at"]), "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
                if expires <= now:
                    terminalize(record, "expired", error_code="expired")
            elif record.get("state") in {"approved", "pushed", "pr_created"}:
                process_record(request_id, Deadline.start())
            elif record.get("state") in TERMINAL_STATES:
                # A kill can land after the fsynced terminal transition but
                # before tombstone publication/pending cleanup. Re-running the
                # terminalization is safe and completes that transaction.
                terminalize(record, str(record["state"]))
        except RequestError as exc:
            log.error("reconciliation failed rid=%s: %s", request_id, exc)
            if exc.code == "metadata_tampered":
                try:
                    path.unlink()
                    _pack_path(request_id).unlink(missing_ok=True)
                    _fsync_dir(PENDING_META_DIR)
                    _fsync_dir(PENDING_PACK_DIR)
                except OSError:
                    pass
        except Exception as exc:
            # A crash/fault after push or PR creation must remain recoverable.
            # Only a proven malformed/MAC-invalid record is discarded above.
            log.exception("unexpected reconciliation failure preserved rid=%s: %s", request_id, exc)
    cutoff = now - timedelta(days=TOMBSTONE_RETENTION_DAYS)
    for path in TOMBSTONE_DIR.glob("*.json"):
        try:
            if datetime.fromtimestamp(path.stat().st_mtime, timezone.utc) < cutoff:
                path.unlink()
                _fsync_dir(TOMBSTONE_DIR)
        except OSError:
            pass
    active_packs = {path.stem for path in PENDING_META_DIR.glob("*.json")}
    for path in PENDING_PACK_DIR.glob("*.pack"):
        if path.stem not in active_packs:
            try:
                path.unlink()
                _fsync_dir(PENDING_PACK_DIR)
            except OSError:
                pass


def _read_until_boundary(source, output, boundary: bytes, cap: int) -> bool:
    marker = b"\r\n--" + boundary
    buffer = b""
    written = 0
    while True:
        chunk = source.read(65536)
        if not chunk:
            raise RequestError("malformed_multipart")
        buffer += chunk
        index = buffer.find(marker)
        if index >= 0:
            data = buffer[:index]
            written += len(data)
            if written > cap:
                raise RequestError("pack_too_large" if cap == PACK_MAX_INPUT else "metadata_too_large", 413)
            output.write(data)
            remainder = buffer[index + len(marker):]
            while len(remainder) < 2:
                more = source.read(2 - len(remainder))
                if not more:
                    raise RequestError("malformed_multipart")
                remainder += more
            suffix = remainder[:2]
            unread = remainder[2:]
            if unread:
                source.seek(-len(unread), os.SEEK_CUR)
            if suffix == b"--":
                # The closing boundary is terminal. Read one byte beyond the
                # optional CRLF so request smuggling/trailing parts fail closed.
                tail = source.read(3)
                if tail not in (b"", b"\r\n"):
                    raise RequestError("malformed_multipart")
                return True
            if suffix == b"\r\n":
                return False
            raise RequestError("malformed_multipart")
        keep = len(marker) + 2
        if len(buffer) > keep:
            data = buffer[:-keep]
            written += len(data)
            if written > cap:
                raise RequestError("pack_too_large" if cap == PACK_MAX_INPUT else "metadata_too_large", 413)
            output.write(data)
            buffer = buffer[-keep:]


def parse_multipart(body_path: Path, content_type: str) -> tuple[dict[str, object], Path]:
    match = re.fullmatch(r"multipart/form-data;\s*boundary=(?:\"([^\"]+)\"|([^;\s]+))", content_type, re.IGNORECASE)
    boundary_text = (match.group(1) or match.group(2)) if match else ""
    if not boundary_text or len(boundary_text) > 70 or not re.fullmatch(r"[0-9A-Za-z'()+_,./:=?-]+", boundary_text):
        raise RequestError("malformed_multipart")
    boundary = boundary_text.encode("ascii")
    pack_fd, pack_name = tempfile.mkstemp(prefix="upload-pack-", dir=WORK_DIR)
    os.chmod(pack_name, 0o600)
    pack_path = Path(pack_name)
    seen: set[str] = set()
    meta_bytes = io.BytesIO()
    try:
        with open(body_path, "rb") as source, os.fdopen(pack_fd, "wb") as pack_output:
            if source.readline(256) != b"--" + boundary + b"\r\n":
                raise RequestError("malformed_multipart")
            final = False
            while not final:
                headers: dict[str, str] = {}
                header_bytes = 0
                while True:
                    line = source.readline(8193)
                    header_bytes += len(line)
                    if not line or len(line) > 8192 or header_bytes > 8192:
                        raise RequestError("malformed_multipart")
                    if line == b"\r\n":
                        break
                    if not line.endswith(b"\r\n") or b":" not in line:
                        raise RequestError("malformed_multipart")
                    name, value = line[:-2].split(b":", 1)
                    try:
                        key = name.decode("ascii", "strict").strip().lower()
                    except UnicodeDecodeError as exc:
                        raise RequestError("malformed_multipart") from exc
                    if key not in {"content-disposition", "content-type"}:
                        raise RequestError("malformed_multipart")
                    if key in headers:
                        raise RequestError("malformed_multipart")
                    headers[key] = value.decode("latin-1").strip()
                disposition = headers.get("content-disposition", "")
                found = re.fullmatch(r"form-data;\s*name=\"(meta|pack)\"", disposition, re.IGNORECASE)
                if not found:
                    raise RequestError("unknown_multipart_part")
                name = found.group(1).lower()
                if name in seen:
                    raise RequestError("duplicate_multipart_part")
                seen.add(name)
                expected_type = "application/json" if name == "meta" else "application/octet-stream"
                if headers.get("content-type", "").lower() != expected_type:
                    raise RequestError("malformed_multipart")
                if name == "meta":
                    final = _read_until_boundary(source, meta_bytes, boundary, 128 * 1024)
                else:
                    final = _read_until_boundary(source, pack_output, boundary, PACK_MAX_INPUT)
            pack_output.flush()
            os.fsync(pack_output.fileno())
        if seen != {"meta", "pack"} or pack_path.stat().st_size <= 0:
            raise RequestError("malformed_multipart")
        try:
            meta = json.loads(meta_bytes.getvalue())
        except (UnicodeError, json.JSONDecodeError) as exc:
            raise RequestError("invalid_json") from exc
        if not isinstance(meta, dict):
            raise RequestError("invalid_schema")
        return meta, pack_path
    except Exception:
        try:
            os.close(pack_fd)
        except OSError:
            pass
        pack_path.unlink(missing_ok=True)
        raise


def _recv_with_deadline(conn: socket.socket, size: int, end: float) -> bytes:
    remaining = end - time.monotonic()
    if remaining <= 0:
        raise RequestError("ingress_timeout", 408)
    conn.settimeout(remaining)
    try:
        return conn.recv(size)
    except socket.timeout as exc:
        raise RequestError("ingress_timeout", 408) from exc


def _http_auth_token() -> bytes:
    if not HTTP_AUTH_TOKEN_PATH:
        raise RequestError("http_auth_unconfigured", 503)
    try:
        token = read_bounded_regular(Path(HTTP_AUTH_TOKEN_PATH), 4096).strip()
    except OSError as exc:
        raise RequestError("http_auth_unconfigured", 503) from exc
    if not token:
        raise RequestError("http_auth_unconfigured", 503)
    return token


def read_http_request(conn: socket.socket, socket_type: str, ingress_end: float) -> tuple[str, dict[str, str], Path]:
    header_end = min(ingress_end, time.monotonic() + 5)
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = _recv_with_deadline(conn, 8192, header_end)
        if not chunk:
            raise RequestError("malformed_request")
        data += chunk
        if len(data) > 8192:
            raise RequestError("malformed_request")
    raw_headers, _, initial = data.partition(b"\r\n\r\n")
    try:
        lines = raw_headers.decode("latin-1").split("\r\n")
    except UnicodeError as exc:
        raise RequestError("malformed_request") from exc
    request_line = lines[0].split()
    if len(request_line) != 3 or request_line[0] != "POST" or not request_line[2].startswith("HTTP/1."):
        raise RequestError("malformed_request", 405)
    path = request_line[1]
    headers: dict[str, str] = {}
    counts: dict[str, int] = {}
    for line in lines[1:]:
        if ":" not in line:
            raise RequestError("malformed_request")
        name, value = line.split(":", 1)
        key = name.strip().lower()
        counts[key] = counts.get(key, 0) + 1
        if counts[key] > 1:
            raise RequestError("malformed_request")
        headers[key] = value.strip()
    if "transfer-encoding" in headers or counts.get("content-length") != 1:
        raise RequestError("malformed_request")
    if socket_type == "tcp":
        supplied = headers.get("x-fieldwork-local-auth", "").encode("utf-8")
        if not hmac.compare_digest(supplied, _http_auth_token()):
            raise RequestError("unauthorized", 401)
    try:
        length = int(headers["content-length"])
    except ValueError as exc:
        raise RequestError("malformed_request") from exc
    cap = 12 * 1024 * 1024 if path in {"/pr", "/maintenance-pr"} else 256 * 1024
    if length < 0 or length > cap or len(initial) > length:
        raise RequestError("request_too_large", 413)
    fd, name = tempfile.mkstemp(prefix="http-body-", dir=WORK_DIR)
    body_path = Path(name)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(initial)
            received = len(initial)
            while received < length:
                chunk = _recv_with_deadline(conn, min(65536, length - received), ingress_end)
                if not chunk:
                    raise RequestError("malformed_request")
                handle.write(chunk)
                received += len(chunk)
        return path, headers, body_path
    except Exception:
        body_path.unlink(missing_ok=True)
        raise


def _json_body(path: Path) -> object:
    try:
        return json.loads(path.read_bytes())
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise RequestError("invalid_json") from exc


def send_response(conn: socket.socket, status: int, payload: dict[str, object]) -> None:
    body = canonical_json(payload) + b"\n"
    reason = {200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 408: "Request Timeout", 409: "Conflict", 410: "Gone", 413: "Payload Too Large", 429: "Too Many Requests", 500: "Internal Server Error", 502: "Bad Gateway", 503: "Service Unavailable", 504: "Gateway Timeout"}.get(status, "Error")
    headers = (
        f"HTTP/1.1 {status} {reason}\r\n"
        "Content-Type: application/json\r\n"
        f"Content-Length: {len(body)}\r\n"
        "Connection: close\r\n\r\n"
    ).encode("ascii")
    conn.sendall(headers + body)


def handle(conn: socket.socket, socket_type: str = "agent") -> None:
    started = time.monotonic()
    request_id = uuid.uuid4().hex[:12]
    body_path: Path | None = None
    pack_path: Path | None = None
    try:
        path, headers, body_path = read_http_request(conn, socket_type, started + 30)
        # The processing budget begins when the connection is accepted; slow
        # ingress therefore cannot extend the total lifetime of a request.
        deadline = Deadline(started + PROCESSING_SECONDS)
        if socket_type == "maintenance" and not MAINTENANCE:
            raise RequestError("route_not_available", 404)
        if MAINTENANCE and path in {"/pr", "/approve"} and socket_type != "maintenance":
            raise RequestError("maintenance", 503)
        if path == "/maintenance-pr":
            if not MAINTENANCE or socket_type != "tcp" or headers.get("x-fieldwork-maintenance") != "container-exec-v1":
                raise RequestError("route_not_available", 404)
            path = "/pr"
        if path == "/pr":
            if socket_type == "approve":
                raise RequestError("route_not_available", 404)
            content_type = headers.get("content-type", "")
            meta, pack_path = parse_multipart(body_path, content_type)
            req = validate_request(meta)
            request_id = req.request_id
            result = submit_pr(req, pack_path, deadline)
        elif path == "/approve":
            if socket_type != "approve":
                raise RequestError("route_not_available", 404)
            result = approve_request(_json_body(body_path), deadline)
            request_id = str(result.get("request_id", request_id))
        elif path == "/pr-status":
            result = pr_status(_json_body(body_path))
            request_id = str(result.get("request_id", request_id))
        elif path == "/preflight":
            if socket_type == "approve":
                raise RequestError("route_not_available", 404)
            result = broker_preflight(_json_body(body_path), deadline)
        else:
            raise RequestError("route_not_available", 404)
        audit_event("request_complete", request_id=request_id, transport=socket_type, status=200, state=result.get("state"))
        send_response(conn, 200, result)
    except RequestError as exc:
        payload: dict[str, object] = {"ok": False, "request_id": request_id, "error": exc.code}
        if exc.detail:
            payload["detail"] = exc.detail
        payload.update(exc.extra)
        audit_event("request_rejected", request_id=request_id, transport=socket_type, status=exc.status, error_code=exc.code)
        try:
            send_response(conn, exc.status, payload)
        except OSError:
            pass
    except Exception as exc:
        log.exception("unhandled request error rid=%s: %s", request_id, exc)
        audit_event("request_rejected", request_id=request_id, transport=socket_type, status=500, error_code="internal")
        try:
            send_response(conn, 500, {"ok": False, "request_id": request_id, "error": "internal"})
        except OSError:
            pass
    finally:
        for path in (pack_path, body_path):
            if path is not None:
                path.unlink(missing_ok=True)
        try:
            conn.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        conn.close()


def _socket_type_for(sock: socket.socket) -> str:
    try:
        name = sock.getsockname()
    except OSError:
        return "agent"
    if isinstance(name, bytes):
        name = name.decode("utf-8", "replace")
    if isinstance(name, tuple):
        return "tcp"
    basename = os.path.basename(str(name))
    if basename == os.path.basename(APPROVE_SOCKET_PATH):
        return "approve"
    if basename == os.path.basename(MAINTENANCE_SOCKET_PATH):
        return "maintenance"
    return "agent"


def _container_sockets() -> list[tuple[socket.socket, str]]:
    _http_auth_token()
    tcp = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    tcp.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    tcp.bind(("0.0.0.0", 8377))
    tcp.listen(16)
    approve_path = Path(APPROVE_SOCKET_PATH)
    _mkdir(approve_path.parent, 0o2770)
    approve_path.unlink(missing_ok=True)
    approve = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    approve.bind(str(approve_path))
    os.chmod(approve_path, 0o660)
    _chgrp(approve_path, BOT_GROUP)
    approve.listen(16)
    return [(tcp, "tcp"), (approve, "approve")]


def main() -> None:
    initialize_state_dirs()
    _mac_key()
    listen_fds = int(os.environ.get("LISTEN_FDS", "0"))
    sockets: list[tuple[socket.socket, str]] = []
    if listen_fds:
        for offset in range(listen_fds):
            sock = socket.socket(fileno=3 + offset)
            sockets.append((sock, _socket_type_for(sock)))
    else:
        sockets = _container_sockets()
    sweep_state()
    selector = selectors.DefaultSelector()
    for sock, kind in sockets:
        selector.register(sock, selectors.EVENT_READ, kind)
        log.info("broker listening transport=%s", kind)
    try:
        while True:
            for key, _ in selector.select():
                connection, _address = key.fileobj.accept()
                handle(connection, str(key.data))
    except KeyboardInterrupt:
        pass
    finally:
        for sock, _ in sockets:
            try:
                path = sock.getsockname()
                sock.close()
                if isinstance(path, str) and path == APPROVE_SOCKET_PATH and not listen_fds:
                    Path(path).unlink(missing_ok=True)
            except OSError:
                pass


if __name__ == "__main__":
    main()
