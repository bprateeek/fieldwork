#!/usr/bin/env python3
"""Reference client for the Fieldwork PR broker. stdlib only.

Reads a JSON request file matching schema/pr-request.schema.json and POSTs it
to the broker's Unix socket. Prints the PR URL on success, or the broker's
structured error and exits non-zero.

Usage:
    python3 broker-client.py request.json
    python3 broker-client.py --socket /run/fieldwork-pr-broker/fieldwork-pr.sock request.json

The broker holds the GitHub PAT; this client never sees one. Any process that
can connect to the socket can open PRs through it. The default socket group is
the agent user's primary group. See the advanced broker-only guide,
docs/broker-standalone.md, for the schema, the curl --unix-socket recipe, and
the trust model.
"""
from __future__ import annotations

import argparse
import json
import socket
import sys
from pathlib import Path

DEFAULT_SOCKET = "/run/fieldwork-pr-broker/fieldwork-pr.sock"


def submit(socket_path: str, request: dict) -> tuple[int, dict]:
    body = json.dumps(request).encode("utf-8")
    head = (
        f"POST /pr HTTP/1.1\r\n"
        f"Host: localhost\r\n"
        f"Content-Type: application/json\r\n"
        f"Content-Length: {len(body)}\r\n"
        f"Connection: close\r\n\r\n"
    ).encode("ascii")

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.connect(socket_path)
    except FileNotFoundError:
        raise SystemExit(f"broker socket not found: {socket_path}")
    except PermissionError:
        raise SystemExit(
            f"permission denied on {socket_path}. Is this user in the broker socket group?"
        )

    try:
        sock.sendall(head + body)
        chunks: list[bytes] = []
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                break
            chunks.append(chunk)
    finally:
        sock.close()

    raw = b"".join(chunks)
    head_bytes, _, body_bytes = raw.partition(b"\r\n\r\n")
    status_line = head_bytes.split(b"\r\n", 1)[0].decode("latin-1", errors="replace")
    parts = status_line.split(" ", 2)
    status = int(parts[1]) if len(parts) >= 2 and parts[1].isdigit() else 0
    try:
        payload = json.loads(body_bytes.decode("utf-8") or "{}")
    except json.JSONDecodeError:
        payload = {"ok": False, "error": f"non-JSON broker response: {body_bytes!r}"}
    return status, payload


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("request", help="Path to a JSON file matching pr-request.schema.json")
    parser.add_argument(
        "--socket", default=DEFAULT_SOCKET,
        help=f"Broker Unix socket path (default: {DEFAULT_SOCKET})",
    )
    args = parser.parse_args()

    try:
        request = json.loads(Path(args.request).read_text())
    except FileNotFoundError:
        print(f"request file not found: {args.request}", file=sys.stderr)
        return 2
    except json.JSONDecodeError as e:
        print(f"request file is not valid JSON: {e}", file=sys.stderr)
        return 2

    status, payload = submit(args.socket, request)
    if status == 200 and payload.get("ok"):
        if payload.get("queued"):
            print(f"queued for approval (expires {payload.get('expires_at', 'unknown')})")
        else:
            print(payload.get("url", "(no url in response)"))
        return 0
    error = payload.get("error", "(no error message)")
    print(f"broker rejected request (HTTP {status}): {error}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
