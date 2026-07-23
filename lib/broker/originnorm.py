#!/usr/bin/env python3
"""Strict forge origin normalization shared by Fieldwork operator tooling.

The broker never reads a checkout in protocol v2.  These helpers therefore
belong to the trusted wiring/onboarding path, not request validation.
"""

from __future__ import annotations

import re
import urllib.parse


class OriginError(ValueError):
    pass


_GITHUB_PROJECT = re.compile(
    r"^([A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?)/"
    r"([A-Za-z0-9._-]{1,100})$"
)
_GITLAB_SEGMENT = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
_SCP = re.compile(r"^git@([^:]+):(.+?)(?:\.git)?$")


def normalize_project(forge: str, value: str) -> str:
    forge = forge.strip().lower()
    project = value.strip().strip("/")
    if project.endswith(".git"):
        project = project[:-4]
    if forge == "github":
        match = _GITHUB_PROJECT.fullmatch(project)
        if not match or "--" in match.group(1):
            raise OriginError("GitHub project must be a valid owner/repo")
        return f"{match.group(1)}/{match.group(2)}"
    if forge == "gitlab":
        parts = project.split("/")
        if len(parts) < 2 or any(not _GITLAB_SEGMENT.fullmatch(part) for part in parts):
            raise OriginError("GitLab project must be a valid group/project path")
        return "/".join(parts)
    raise OriginError(f"unsupported forge: {forge}")


def normalize_origin(forge: str, origin: str, *, expected_host: str | None = None) -> tuple[str, str]:
    """Return ``(host[:port], project)`` for an HTTPS or git@ origin."""
    value = origin.strip()
    scp = _SCP.fullmatch(value)
    if scp:
        host = scp.group(1).lower()
        project = normalize_project(forge, scp.group(2))
    else:
        parsed = urllib.parse.urlsplit(value)
        if parsed.scheme != "https":
            raise OriginError("origin must use HTTPS or the git@host:path form")
        if parsed.username or parsed.password or "@" in parsed.netloc:
            raise OriginError("origin must not contain credentials")
        if parsed.query or parsed.fragment:
            raise OriginError("origin must not contain a query or fragment")
        if not parsed.hostname:
            raise OriginError("origin host is empty")
        try:
            port = parsed.port
        except ValueError as exc:
            raise OriginError("origin port is invalid") from exc
        host = parsed.hostname.lower()
        if port is not None:
            host = f"{host}:{port}"
        project = normalize_project(forge, urllib.parse.unquote(parsed.path))
    if expected_host and host != expected_host.lower():
        raise OriginError("origin host does not match the wired forge host")
    if forge == "github" and host not in {"github.com", "ssh.github.com:443"}:
        raise OriginError("GitHub.com origins must use github.com")
    return host, project


def https_origin(forge: str, project: str, *, git_base_url: str | None = None) -> str:
    project = normalize_project(forge, project)
    base = git_base_url or ("https://github.com" if forge == "github" else "https://gitlab.com")
    parsed = urllib.parse.urlsplit(base)
    if parsed.scheme != "https" or not parsed.netloc or parsed.path not in ("", "/"):
        raise OriginError("git base URL must be an HTTPS origin without a path")
    return f"{base.rstrip('/')}/{project}.git"


__all__ = ["OriginError", "https_origin", "normalize_origin", "normalize_project"]
