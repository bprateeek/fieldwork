#!/usr/bin/env python3
"""Reference protocol-v2 Unix-socket broker client. Standard library only.

Usage:
    python3 broker-client.py meta.json pack
    python3 broker-client.py --socket /run/fieldwork-pr-broker/fieldwork-pr.sock meta.json pack

Production agents should use the hardened two-call builder/uploader contract.
This example is for operators and integration authors who already have a v2
metadata object and a non-thin Git pack.
"""
from __future__ import annotations

import argparse
import json
import secrets
import socket
import sys
from pathlib import Path


DEFAULT_SOCKET = "/run/fieldwork-pr-broker/fieldwork-pr.sock"
MAX_META = 128 * 1024
MAX_PACK = 8 * 1024 * 1024


def multipart(meta: bytes, pack: bytes) -> tuple[bytes, str]:
    boundary = f"fieldwork-example-{secrets.token_hex(16)}"
    marker = boundary.encode("ascii")
    body = b"".join((
        b"--" + marker + b'\r\nContent-Disposition: form-data; name="meta"\r\n'
        b"Content-Type: application/json\r\n\r\n",
        meta,
        b"\r\n--" + marker + b'\r\nContent-Disposition: form-data; name="pack"\r\n'
        b"Content-Type: application/octet-stream\r\n\r\n",
        pack,
        b"\r\n--" + marker + b"--\r\n",
    ))
    return body, boundary


def submit(socket_path: str, meta: bytes, pack: bytes) -> tuple[int, dict[str, object]]:
    body, boundary = multipart(meta, pack)
    head = (
        "POST /pr HTTP/1.1\r\n"
        "Host: localhost\r\n"
        f"Content-Type: multipart/form-data; boundary={boundary}\r\n"
        f"Content-Length: {len(body)}\r\n"
        "Connection: close\r\n\r\n"
    ).encode("ascii")
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.settimeout(30)
        sock.connect(socket_path)
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
    head_bytes, separator, body_bytes = raw.partition(b"\r\n\r\n")
    if not separator:
        return 0, {"ok": False, "error": "broker returned no HTTP body"}
    status_fields = head_bytes.split(b"\r\n", 1)[0].split()
    status = int(status_fields[1]) if len(status_fields) > 1 and status_fields[1].isdigit() else 0
    try:
        payload = json.loads(body_bytes.decode("utf-8") or "{}")
    except (UnicodeError, json.JSONDecodeError):
        payload = {"ok": False, "error": "broker returned invalid JSON"}
    return status, payload if isinstance(payload, dict) else {"ok": False, "error": "broker response was not an object"}


def read_regular(path: str, maximum: int, label: str) -> bytes:
    candidate = Path(path)
    if candidate.is_symlink() or not candidate.is_file():
        raise ValueError(f"{label} must be a regular non-symlink file")
    data = candidate.read_bytes()
    if not data or len(data) > maximum:
        raise ValueError(f"{label} size is outside the protocol limit")
    return data


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("meta", help="Protocol-v2 meta.json")
    parser.add_argument("pack", help="Non-thin Git pack")
    parser.add_argument("--socket", default=DEFAULT_SOCKET)
    args = parser.parse_args()
    try:
        meta = read_regular(args.meta, MAX_META, "meta")
        pack = read_regular(args.pack, MAX_PACK, "pack")
        parsed = json.loads(meta)
        if not isinstance(parsed, dict) or parsed.get("schema_version") != 2:
            raise ValueError("meta must be a protocol-v2 JSON object")
        status, payload = submit(args.socket, meta, pack)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"broker client: {exc}", file=sys.stderr)
        return 2
    print(json.dumps(payload, sort_keys=True))
    return 0 if status == 200 and payload.get("ok") is True else 1


if __name__ == "__main__":
    raise SystemExit(main())
