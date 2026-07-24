#!/usr/bin/python3 -I
"""Root/operator-only writer for broker-owned protocol-v2 policy records."""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import stat
import sys
import urllib.parse

_BROKER_LIB = Path(__file__).resolve().parent
if not (_BROKER_LIB / "originnorm.py").is_file():
    _BROKER_LIB = Path("/usr/local/lib/fieldwork-pr-broker")
if str(_BROKER_LIB) not in sys.path:
    sys.path.insert(0, str(_BROKER_LIB))
from originnorm import OriginError, normalize_project


POLICY_SCHEMA_VERSION = 1
GITHUB_API_BASE = "https://api.github.com"
GITHUB_GIT_BASE = "https://github.com"
GITLAB_API_BASE = "https://gitlab.com/api/v4"
GITLAB_GIT_BASE = "https://gitlab.com"
SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,30}$")
BASE_BRANCH_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/-]{0,99}$")
POLICY_FIELDS = {
    "schema_version",
    "forge",
    "project",
    "api_base_url",
    "git_base_url",
    "base_branch",
    "approval",
    "allow_private_network",
    "ca_bundle_ref",
}


class PolicyError(ValueError):
    pass


def canonical_json(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def policy_digest(record: dict[str, object]) -> str:
    return hashlib.sha256(canonical_json(record)).hexdigest()


def validate_slug(slug: str) -> str:
    if not isinstance(slug, str) or not SLUG_RE.fullmatch(slug):
        raise PolicyError("slug must match ^[a-z0-9][a-z0-9-]{0,30}$")
    return slug


def validate_base_branch(branch: object) -> str:
    if not isinstance(branch, str):
        raise PolicyError("base_branch must be a string")
    value = branch.strip()
    if (
        not BASE_BRANCH_RE.fullmatch(value)
        or value.startswith("/")
        or value.endswith("/")
        or "//" in value
        or ".." in value
        or "@{" in value
        or value.endswith(".")
    ):
        raise PolicyError("base_branch is invalid")
    return value


def _url(value: object, *, field: str, allow_path: bool) -> urllib.parse.SplitResult:
    if not isinstance(value, str):
        raise PolicyError(f"{field} must be a string")
    parsed = urllib.parse.urlsplit(value)
    if parsed.scheme != "https":
        raise PolicyError(f"{field} must use https")
    if parsed.username or parsed.password or "@" in parsed.netloc:
        raise PolicyError(f"{field} must not contain credentials")
    if parsed.query or parsed.fragment or not parsed.hostname:
        raise PolicyError(f"{field} must be an HTTPS URL without query or fragment")
    try:
        port = parsed.port
    except ValueError as exc:
        raise PolicyError(f"{field} port is invalid") from exc
    if port is not None and not 1 <= port <= 65535:
        raise PolicyError(f"{field} port is invalid")
    if not allow_path and parsed.path not in ("", "/"):
        raise PolicyError(f"{field} must not contain a path")
    return parsed


def _same_endpoint(left: urllib.parse.SplitResult, right: urllib.parse.SplitResult) -> bool:
    return (left.hostname or "").lower() == (right.hostname or "").lower() and (left.port or 443) == (right.port or 443)


def address_is_private(address: str) -> bool:
    ip = ipaddress.ip_address(address.split("%", 1)[0])
    return not ip.is_global


def validate_policy(record: object) -> dict[str, object]:
    if not isinstance(record, dict):
        raise PolicyError("policy must be a JSON object")
    extras = sorted(set(record) - POLICY_FIELDS)
    missing = sorted(POLICY_FIELDS - set(record))
    if extras:
        raise PolicyError(f"unexpected policy field: {extras[0]}")
    if missing:
        raise PolicyError(f"missing policy field: {missing[0]}")
    if record.get("schema_version") != POLICY_SCHEMA_VERSION:
        raise PolicyError("schema_version must be 1")
    forge = record.get("forge")
    if forge not in ("github", "gitlab"):
        raise PolicyError("forge must be github or gitlab")
    if not isinstance(record.get("project"), str):
        raise PolicyError("project must be a string")
    try:
        project = normalize_project(str(forge), str(record["project"]))
    except OriginError as exc:
        raise PolicyError(str(exc)) from exc
    approval = record.get("approval")
    if approval not in ("require", "auto"):
        raise PolicyError("approval must be require or auto")
    if type(record.get("allow_private_network")) is not bool:
        raise PolicyError("allow_private_network must be boolean")
    ca_ref = record.get("ca_bundle_ref")
    if ca_ref is not None and (not isinstance(ca_ref, str) or not re.fullmatch(r"sha256:[0-9a-f]{64}", ca_ref)):
        raise PolicyError("ca_bundle_ref must be null or sha256:<64 lowercase hex>")

    api = _url(record.get("api_base_url"), field="api_base_url", allow_path=True)
    git = _url(record.get("git_base_url"), field="git_base_url", allow_path=False)
    api_value = str(record["api_base_url"]).rstrip("/")
    git_value = str(record["git_base_url"]).rstrip("/")
    if forge == "github":
        if api_value != GITHUB_API_BASE or git_value != GITHUB_GIT_BASE:
            raise PolicyError("GitHub.com policy must use the compiled API and git URLs")
        if ca_ref is not None or record["allow_private_network"]:
            raise PolicyError("GitHub.com policy cannot use a private CA or private-network opt-in")
    else:
        if not _same_endpoint(api, git):
            raise PolicyError("GitLab API and git URLs must use the same host and port")
        if api.path.rstrip("/") != "/api/v4":
            raise PolicyError("GitLab api_base_url path must be exactly /api/v4")

    return {
        "schema_version": POLICY_SCHEMA_VERSION,
        "forge": forge,
        "project": project,
        "api_base_url": api_value,
        "git_base_url": git_value,
        "base_branch": validate_base_branch(record.get("base_branch")),
        "approval": approval,
        "allow_private_network": record["allow_private_network"],
        "ca_bundle_ref": ca_ref,
    }


def _assert_directory(path: Path, *, create: bool = False, mode: int = 0o750) -> None:
    if create:
        path.mkdir(parents=True, mode=mode, exist_ok=True)
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        raise PolicyError(f"refusing non-directory or symlink path: {path}")


def _inherit_owner_info(fd: int, parent_info: os.stat_result, mode: int) -> None:
    if os.geteuid() == 0:
        os.fchown(fd, parent_info.st_uid, parent_info.st_gid)
    os.fchmod(fd, mode)


@contextlib.contextmanager
def policy_lock(policy_dir: Path, slug: str, *, exclusive: bool = True):
    validate_slug(slug)
    _assert_directory(policy_dir, create=True)
    directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    policy_fd = os.open(policy_dir, directory_flags)
    lock_fd = -1
    fd = -1
    try:
        policy_info = os.fstat(policy_fd)
        if not stat.S_ISDIR(policy_info.st_mode):
            raise PolicyError("policy path changed during lock acquisition")
        try:
            os.mkdir(".locks", 0o700, dir_fd=policy_fd)
        except FileExistsError:
            pass
        lock_fd = os.open(".locks", directory_flags, dir_fd=policy_fd)
        lock_info = os.fstat(lock_fd)
        if not stat.S_ISDIR(lock_info.st_mode):
            raise PolicyError("policy lock path is unsafe")
        if os.geteuid() == 0:
            os.fchown(lock_fd, policy_info.st_uid, policy_info.st_gid)
        os.fchmod(lock_fd, 0o700)
        flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
        fd = os.open(f"{slug}.lock", flags, 0o600, dir_fd=lock_fd)
        _inherit_owner_info(fd, policy_info, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH)
        yield
    finally:
        if fd >= 0:
            fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)
        if lock_fd >= 0:
            os.close(lock_fd)
        os.close(policy_fd)


def read_policy(policy_dir: Path, slug: str) -> dict[str, object]:
    validate_slug(slug)
    _assert_directory(policy_dir)
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        fd = os.open(policy_dir / f"{slug}.json", flags)
    except FileNotFoundError as exc:
        raise PolicyError("repo_not_wired") from exc
    try:
        handle = os.fdopen(fd, "r", encoding="utf-8")
        fd = -1
        with handle:
            info = os.fstat(handle.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_size > 64 * 1024:
                raise PolicyError("policy record must be a small regular file")
            value = json.load(handle)
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise PolicyError("policy record is invalid JSON") from exc
    finally:
        if fd >= 0:
            os.close(fd)
    return validate_policy(value)


def _fsync_dir(path: Path) -> None:
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def write_policy(policy_dir: Path, slug: str, record: object) -> dict[str, object]:
    slug = validate_slug(slug)
    value = validate_policy(record)
    _assert_directory(policy_dir, create=True)
    target = f"{slug}.json"
    temp = f".{slug}.{os.getpid()}.{secrets.token_hex(8)}.tmp"
    directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    directory_fd = os.open(policy_dir, directory_flags)
    try:
        parent_info = os.fstat(directory_fd)
        try:
            target_info = os.stat(target, dir_fd=directory_fd, follow_symlinks=False)
        except FileNotFoundError:
            target_info = None
        if target_info is not None and stat.S_ISLNK(target_info.st_mode):
            raise PolicyError(f"refusing symlink policy target: {policy_dir / target}")
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
        fd = os.open(temp, flags, 0o600, dir_fd=directory_fd)
        _inherit_owner_info(fd, parent_info, 0o600)
        with os.fdopen(fd, "wb") as handle:
            handle.write(canonical_json(value) + b"\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp, target, src_dir_fd=directory_fd, dst_dir_fd=directory_fd)
        os.fsync(directory_fd)
    except Exception:
        try:
            os.unlink(temp, dir_fd=directory_fd)
        except FileNotFoundError:
            pass
        raise
    finally:
        os.close(directory_fd)
    return value


def copy_ca_bundle(source: Path, ca_dir: Path) -> str:
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(source, flags)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_size > 4 * 1024 * 1024:
            raise PolicyError("CA bundle must be a regular file no larger than 4 MiB")
        data = b""
        while True:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            data += chunk
    finally:
        os.close(fd)
    if b"BEGIN CERTIFICATE" not in data:
        raise PolicyError("CA bundle does not contain a PEM certificate")
    digest = hashlib.sha256(data).hexdigest()
    _assert_directory(ca_dir, create=True, mode=0o700)
    target = f"{digest}.pem"
    directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    directory_fd = os.open(ca_dir, directory_flags)
    try:
        parent_info = os.fstat(directory_fd)
        try:
            existing_fd = os.open(target, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=directory_fd)
        except FileNotFoundError:
            existing_fd = -1
        except OSError as exc:
            raise PolicyError("existing content-addressed CA target is unsafe") from exc
        if existing_fd >= 0:
            try:
                existing_info = os.fstat(existing_fd)
                existing = b""
                if stat.S_ISREG(existing_info.st_mode) and existing_info.st_size <= 4 * 1024 * 1024:
                    while len(existing) < existing_info.st_size:
                        chunk = os.read(existing_fd, existing_info.st_size - len(existing))
                        if not chunk:
                            break
                        existing += chunk
                if len(existing) != existing_info.st_size or hashlib.sha256(existing).hexdigest() != digest:
                    raise PolicyError("existing content-addressed CA target is unsafe")
            finally:
                os.close(existing_fd)
        else:
            temp = f".{digest}.{os.getpid()}.{secrets.token_hex(8)}.tmp"
            out = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600, dir_fd=directory_fd)
            try:
                _inherit_owner_info(out, parent_info, 0o600)
                with os.fdopen(out, "wb") as handle:
                    handle.write(data)
                    handle.flush()
                    os.fsync(handle.fileno())
                os.replace(temp, target, src_dir_fd=directory_fd, dst_dir_fd=directory_fd)
                os.fsync(directory_fd)
            except Exception:
                try:
                    os.unlink(temp, dir_fd=directory_fd)
                except FileNotFoundError:
                    pass
                raise
    finally:
        os.close(directory_fd)
    return f"sha256:{digest}"


def build_record(args: argparse.Namespace) -> dict[str, object]:
    forge = args.forge
    if forge == "github":
        api, git = GITHUB_API_BASE, GITHUB_GIT_BASE
    else:
        api = (args.api_base_url or GITLAB_API_BASE).rstrip("/")
        git = (args.git_base_url or GITLAB_GIT_BASE).rstrip("/")
    ca_ref = None
    if args.ca_bundle:
        ca_ref = copy_ca_bundle(Path(args.ca_bundle), Path(args.ca_dir))
    return validate_policy({
        "schema_version": 1,
        "forge": forge,
        "project": args.project,
        "api_base_url": api,
        "git_base_url": git,
        "base_branch": args.base_branch,
        "approval": args.approval,
        "allow_private_network": args.allow_private_network,
        "ca_bundle_ref": ca_ref,
    })


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="write a broker-owned Fieldwork repository policy")
    parser.add_argument("--policy-dir", default=os.environ.get("FIELDWORK_BROKER_POLICY_DIR", "/var/lib/fieldwork-pr-broker/policy"))
    parser.add_argument("--ca-dir", default=os.environ.get("FIELDWORK_BROKER_CA_DIR", "/var/lib/fieldwork-pr-broker/ca"))
    parser.add_argument("--slug", required=True)
    parser.add_argument("--forge", choices=("github", "gitlab"), default="github")
    parser.add_argument("--project", required=True)
    parser.add_argument("--base-branch", required=True)
    parser.add_argument("--approval", choices=("require", "auto"), default="require")
    parser.add_argument("--api-base-url")
    parser.add_argument("--git-base-url")
    parser.add_argument("--allow-private-network", action="store_true")
    parser.add_argument("--ca-bundle")
    args = parser.parse_args(argv)
    try:
        record = build_record(args)
        policy_dir = Path(args.policy_dir)
        with policy_lock(policy_dir, args.slug):
            written = write_policy(policy_dir, args.slug, record)
    except (OSError, PolicyError) as exc:
        print(f"policy write failed: {exc}", file=sys.stderr)
        return 1
    print(json.dumps({"ok": True, "slug": args.slug, "digest": policy_digest(written)}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
