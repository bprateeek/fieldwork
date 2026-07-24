#!/usr/bin/env python3
"""Protocol-v2 broker security and lifecycle tests."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import uuid
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
BROKER_DIR = ROOT / "lib/broker"
SCHEMA = ROOT / "schema/pr-request.schema.json"
ASKPASS = BROKER_DIR / "git-askpass"
MIGRATOR = BROKER_DIR / "migrate-instructions"
IMPORT_STATE = tempfile.TemporaryDirectory(prefix="fieldwork-broker-import-")
IMPORT_ROOT = Path(IMPORT_STATE.name)
os.environ.update({
    "FIELDWORK_BROKER_LOG_PATH": str(IMPORT_ROOT / "broker.log"),
    "FIELDWORK_BROKER_SCHEMA_PATH": str(SCHEMA),
    "FIELDWORK_BROKER_POLICY_DIR": str(IMPORT_ROOT / "policy"),
    "FIELDWORK_BROKER_CA_DIR": str(IMPORT_ROOT / "ca"),
    "FIELDWORK_BROKER_LEDGER_DIR": str(IMPORT_ROOT / "ledger"),
    "FIELDWORK_BROKER_PENDING_META_DIR": str(IMPORT_ROOT / "meta"),
    "FIELDWORK_BROKER_PENDING_SIDECAR_DIR": str(IMPORT_ROOT / "sidecar"),
    "FIELDWORK_BROKER_PENDING_PACK_DIR": str(IMPORT_ROOT / "pack"),
    "FIELDWORK_BROKER_TOMBSTONE_DIR": str(IMPORT_ROOT / "tombstones"),
    "FIELDWORK_BROKER_WORK_DIR": str(IMPORT_ROOT / "work"),
    "FIELDWORK_BROKER_PENDING_MAC_KEY_PATH": str(IMPORT_ROOT / "mac.key"),
    "FIELDWORK_BROKER_TOKEN_PATH": str(IMPORT_ROOT / "token"),
    "FIELDWORK_BROKER_NOTIFICATIONS_DIR": str(IMPORT_ROOT / "notifications"),
})
sys.path.insert(0, str(BROKER_DIR))


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


server = load("fieldwork_broker_v2", BROKER_DIR / "server.py")
policy_writer = load("fieldwork_policy_writer_v2", BROKER_DIR / "policy_writer.py")
originnorm = load("fieldwork_originnorm_v2", BROKER_DIR / "originnorm.py")


def git(cwd: Path, *args: str, input_bytes: bytes | None = None) -> bytes:
    result = subprocess.run(
        ["/usr/bin/git", *args], cwd=cwd, input=input_bytes,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True,
        env={"PATH": "/usr/bin:/bin", "HOME": str(cwd), "LANG": "C", "LC_ALL": "C"},
    )
    return result.stdout


class BrokerV2Tests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="fieldwork-broker-v2-")
        self.root = Path(self.temp.name)
        for attribute, child in (
            ("POLICY_DIR", "policy"), ("CA_DIR", "ca"), ("LEDGER_DIR", "ledger"),
            ("PENDING_META_DIR", "meta"), ("PENDING_SIDECAR_DIR", "sidecar"),
            ("PENDING_PACK_DIR", "packs"), ("TOMBSTONE_DIR", "tombstones"),
            ("WORK_DIR", "work"), ("NOTIFICATIONS_DIR", "notifications"),
        ):
            path = self.root / child
            path.mkdir(mode=0o700)
            setattr(server, attribute, path)
        server.MAC_KEY_PATH = self.root / "mac.key"
        server.MAC_KEY_PATH.write_bytes(os.urandom(64))
        server.TOKEN_PATH = self.root / "token"
        server.TOKEN_PATH.write_text("github_pat_test\n")
        server.SCHEMA_PATH = SCHEMA
        server._schema_cache = None
        server._recent_requests.clear()
        server.initialize_state_dirs()

    def tearDown(self):
        self.temp.cleanup()

    def request(self, **updates):
        value = {
            "schema_version": 2,
            "request_id": str(uuid.uuid4()),
            "created_at": "2026-07-18T12:00:00Z",
            "slug": "demo",
            "branch": "fieldwork/test-change",
            "title": "Test change",
            "body": "A safe body",
            "head_oid": "1" * 40,
            "common_base_oid": "2" * 40,
        }
        value.update(updates)
        return value

    def policy(self, **updates):
        value = {
            "schema_version": 1,
            "forge": "github",
            "project": "owner/repo",
            "api_base_url": "https://api.github.com",
            "git_base_url": "https://github.com",
            "base_branch": "main",
            "approval": "require",
            "allow_private_network": False,
            "ca_bundle_ref": None,
        }
        value.update(updates)
        return value

    def wire(self, **updates):
        return policy_writer.write_policy(server.POLICY_DIR, "demo", self.policy(**updates))

    @contextlib.contextmanager
    def fake_credential(self, _policy, _deadline):
        yield server.TOKEN_PATH

    @contextlib.contextmanager
    def fake_quarantine(self, _req, _pack, _policy, _token, _deadline):
        yield self.root

    def test_v2_schema_accepts_exact_contract(self):
        req = server.validate_request(self.request())
        self.assertEqual(req.schema_version, 2)
        self.assertEqual(req.slug, "demo")

    def test_v1_checkout_field_is_rejected(self):
        value = self.request(repo_path="/home/fieldwork/projects/demo")
        with self.assertRaisesRegex(server.RequestError, "invalid_schema"):
            server.validate_request(value)

    def test_schema_rejects_sha256_and_bad_ref_shapes(self):
        for updates in (
            {"head_oid": "a" * 64},
            {"branch": "main"},
            {"branch": "fieldwork/bad//name"},
            {"slug": "Bad"},
            {"title": "bad\nline"},
        ):
            with self.subTest(updates=updates), self.assertRaises(server.RequestError):
                server.validate_request(self.request(**updates))

    def test_body_limit_is_utf8_bytes(self):
        with self.assertRaisesRegex(server.RequestError, "body_too_large"):
            server.validate_request(self.request(body="é" * 40000))

    def test_policy_github_constants_and_default_gate(self):
        written = self.wire()
        self.assertEqual(written["approval"], "require")
        with self.assertRaises(policy_writer.PolicyError):
            policy_writer.validate_policy(self.policy(api_base_url="https://example.test"))

    def test_policy_gitlab_requires_https_same_endpoint(self):
        valid = self.policy(
            forge="gitlab", project="group/sub/repo",
            api_base_url="https://gitlab.example:8443/api/v4",
            git_base_url="https://gitlab.example:8443",
        )
        self.assertEqual(policy_writer.validate_policy(valid)["project"], "group/sub/repo")
        with self.assertRaises(policy_writer.PolicyError):
            policy_writer.validate_policy({**valid, "git_base_url": "https://other.example:8443"})
        with self.assertRaises(policy_writer.PolicyError):
            policy_writer.validate_policy({**valid, "api_base_url": "http://gitlab.example:8443/api/v4"})

    def test_policy_writer_refuses_symlink_target(self):
        target = self.root / "outside"
        target.write_text("unchanged")
        (server.POLICY_DIR / "demo.json").symlink_to(target)
        with self.assertRaises(policy_writer.PolicyError):
            self.wire()
        self.assertEqual(target.read_text(), "unchanged")

    def test_ca_bundle_is_copied_and_content_addressed(self):
        source = self.root / "ca.pem"
        source.write_text("-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n")
        ref = policy_writer.copy_ca_bundle(source, server.CA_DIR)
        self.assertRegex(ref, r"^sha256:[0-9a-f]{64}$")
        self.assertEqual(len(list(server.CA_DIR.glob("*.pem"))), 1)

    def test_ca_bundle_refuses_existing_symlink_target(self):
        source = self.root / "ca.pem"
        data = b"-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n"
        source.write_bytes(data)
        digest = policy_writer.hashlib.sha256(data).hexdigest()
        outside = self.root / "outside.pem"
        outside.write_text("unchanged")
        (server.CA_DIR / f"{digest}.pem").symlink_to(outside)
        with self.assertRaisesRegex(policy_writer.PolicyError, "unsafe"):
            policy_writer.copy_ca_bundle(source, server.CA_DIR)
        self.assertEqual(outside.read_text(), "unchanged")

    def test_broker_refuses_symlinked_ca_bundle(self):
        data = b"-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n"
        digest = policy_writer.hashlib.sha256(data).hexdigest()
        outside = self.root / "outside.pem"
        outside.write_bytes(data)
        (server.CA_DIR / f"{digest}.pem").symlink_to(outside)
        with self.assertRaisesRegex(server.RequestError, "ca_bundle_unavailable"):
            server.ca_bundle(self.policy(
                forge="gitlab", project="group/repo",
                api_base_url="https://gitlab.example/api/v4",
                git_base_url="https://gitlab.example",
                ca_bundle_ref=f"sha256:{digest}",
            ))

    def test_policy_writer_children_inherit_store_owner_and_private_modes(self):
        with policy_writer.policy_lock(server.POLICY_DIR, "demo"):
            self.wire()
        lock = server.POLICY_DIR / ".locks" / "demo.lock"
        policy = server.POLICY_DIR / "demo.json"
        parent = server.POLICY_DIR.stat()
        for path in (server.POLICY_DIR / ".locks", lock, policy):
            with self.subTest(path=path):
                info = path.stat()
                self.assertEqual((info.st_uid, info.st_gid), (parent.st_uid, parent.st_gid))
                self.assertEqual(info.st_mode & 0o022, 0)

    def test_origin_normalization_vectors(self):
        self.assertEqual(originnorm.normalize_origin("github", "git@github.com:Owner/repo.git"), ("github.com", "Owner/repo"))
        self.assertEqual(originnorm.normalize_origin("gitlab", "https://gitlab.example:8443/group/repo.git", expected_host="gitlab.example:8443"), ("gitlab.example:8443", "group/repo"))
        for value in ("http://github.com/o/r", "https://user:pass@github.com/o/r", "https://evil.test/o/r"):
            with self.subTest(value=value), self.assertRaises(originnorm.OriginError):
                originnorm.normalize_origin("github", value)

    def test_instruction_migrator_refuses_symlinked_instruction_file(self):
        repo = self.root / "migration-repo"; repo.mkdir()
        git(repo, "init", "-b", "main")
        git(repo, "config", "user.email", "test@example.test"); git(repo, "config", "user.name", "Test")
        outside = self.root / "outside-instructions"
        outside.write_text("## Fieldwork Delivery Workflow\nprotected\n")
        (repo / "AGENTS.md").symlink_to(outside)
        git(repo, "add", "AGENTS.md"); git(repo, "commit", "-m", "old instructions")
        result = subprocess.run(
            ["/usr/bin/python3", "-I", str(MIGRATOR), str(repo)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env={"PATH": "/usr/bin:/bin", "HOME": str(self.root)},
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn(b"refusing a symlink", result.stderr)
        self.assertEqual(outside.read_text(), "## Fieldwork Delivery Workflow\nprotected\n")

    def test_git_environment_scrubs_ambient_configuration(self):
        env = server.broker_git_env()
        for key in ("GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_TERMINAL_PROMPT"):
            self.assertIn(key, env)
        for key in ("HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "GIT_DIR", "GIT_WORK_TREE"):
            self.assertNotIn(key, env)

    @mock.patch("socket.getaddrinfo")
    def test_ssrf_rejects_if_any_dns_answer_is_private(self, lookup):
        lookup.return_value = [
            (socket.AF_INET, socket.SOCK_STREAM, 6, "", ("203.0.113.10", 443)),
            (socket.AF_INET, socket.SOCK_STREAM, 6, "", ("127.0.0.1", 443)),
        ]
        with self.assertRaisesRegex(server.RequestError, "private_network_rejected"):
            server.resolve_addresses("forge.test", 443, False, server.Deadline.start())
        self.assertEqual(server.resolve_addresses("forge.test", 443, True, server.Deadline.start()), ["203.0.113.10", "127.0.0.1"])

    def test_git_dns_pin_uses_policy_port_and_ipv6_brackets(self):
        self.assertEqual(server._git_resolve_arg("gitlab.test", 8443, "2001:db8::1"), "http.curloptResolve=gitlab.test:8443:[2001:db8::1]")

    def test_dns_resolution_obeys_processing_deadline(self):
        def stuck(*_args, **_kwargs):
            time.sleep(0.1)
            return []
        with mock.patch("socket.getaddrinfo", side_effect=stuck):
            with self.assertRaisesRegex(server.RequestError, "forge_dns_timeout"):
                server.resolve_addresses("forge.test", 443, False, server.Deadline(time.monotonic() + 0.01))

    def test_askpass_releases_secret_only_to_pinned_host(self):
        token = self.root / "askpass-token"
        token.write_text("github_pat_not_logged\n")
        env = {
            "PATH": "/usr/bin:/bin", "FIELDWORK_BROKER_ALLOWED_HOST": "github.com",
            "FIELDWORK_BROKER_TOKEN_PATH": str(token), "FIELDWORK_BROKER_ASKPASS_FORGE": "github",
        }
        good = subprocess.run(["/bin/bash", str(ASKPASS), "Password for 'https://x-access-token@github.com/owner/repo.git':"], env=env, capture_output=True, text=True)
        self.assertEqual(good.returncode, 0)
        self.assertEqual(good.stdout.strip(), "github_pat_not_logged")
        bad = subprocess.run(["/bin/bash", str(ASKPASS), "Password for 'https://evil.test/owner/repo.git':"], env=env, capture_output=True, text=True)
        self.assertNotEqual(bad.returncode, 0)
        self.assertNotIn("github_pat_not_logged", bad.stdout + bad.stderr)

    def multipart(self, parts):
        boundary = b"fieldwork-test-boundary"
        body = bytearray()
        for name, value in parts:
            content_type = b"application/json" if name == "meta" else b"application/octet-stream"
            body += b"--" + boundary + b'\r\nContent-Disposition: form-data; name="' + name.encode() + b'"\r\nContent-Type: ' + content_type + b"\r\n\r\n" + value + b"\r\n"
        body += b"--" + boundary + b"--\r\n"
        path = self.root / f"body-{uuid.uuid4().hex}"
        path.write_bytes(body)
        return path, "multipart/form-data; boundary=fieldwork-test-boundary"

    def test_multipart_accepts_exact_meta_and_pack(self):
        path, content_type = self.multipart([("meta", json.dumps(self.request()).encode()), ("pack", b"PACKdata")])
        meta, pack = server.parse_multipart(path, content_type)
        self.assertEqual(meta["slug"], "demo")
        self.assertEqual(pack.read_bytes(), b"PACKdata")

    def test_multipart_rejects_duplicate_unknown_and_long_boundary(self):
        cases = [
            self.multipart([("meta", b"{}"), ("meta", b"{}"), ("pack", b"PACK")]),
            self.multipart([("meta", b"{}"), ("other", b"x"), ("pack", b"PACK")]),
        ]
        for path, content_type in cases:
            with self.subTest(path=path), self.assertRaises(server.RequestError):
                server.parse_multipart(path, content_type)
        with self.assertRaises(server.RequestError):
            server.parse_multipart(cases[0][0], "multipart/form-data; boundary=" + "x" * 71)

    def test_multipart_rejects_trailing_bytes_and_unknown_headers(self):
        path, content_type = self.multipart([("meta", b"{}"), ("pack", b"PACK")])
        path.write_bytes(path.read_bytes() + b"smuggled")
        with self.assertRaisesRegex(server.RequestError, "malformed_multipart"):
            server.parse_multipart(path, content_type)
        raw = self.root / "body-unknown-header"
        raw.write_bytes(
            b'--x\r\nContent-Disposition: form-data; name="meta"\r\nContent-Type: application/json\r\nX-Evil: yes\r\n\r\n{}\r\n'
            b'--x\r\nContent-Disposition: form-data; name="pack"\r\nContent-Type: application/octet-stream\r\n\r\nPACK\r\n--x--\r\n'
        )
        with self.assertRaisesRegex(server.RequestError, "malformed_multipart"):
            server.parse_multipart(raw, "multipart/form-data; boundary=x")
        invalid_meta, invalid_type = self.multipart([("meta", b"\xff"), ("pack", b"PACK")])
        with self.assertRaisesRegex(server.RequestError, "invalid_json"):
            server.parse_multipart(invalid_meta, invalid_type)

    def test_tcp_auth_is_checked_before_body_receipt(self):
        auth = self.root / "http-auth"
        auth.write_text("correct")
        server.HTTP_AUTH_TOKEN_PATH = str(auth)
        left, right = socket.socketpair()
        try:
            left.sendall(b"POST /pr-status HTTP/1.1\r\nContent-Length: 100\r\nX-Fieldwork-Local-Auth: wrong\r\n\r\n")
            with self.assertRaisesRegex(server.RequestError, "unauthorized"):
                server.read_http_request(right, "tcp", time.monotonic() + 1)
        finally:
            left.close(); right.close()

    def test_ingress_deadline_rejects_a_drip_feed(self):
        left, right = socket.socketpair()
        try:
            with self.assertRaisesRegex(server.RequestError, "ingress_timeout"):
                server._recv_with_deadline(right, 1, time.monotonic() + 0.01)
        finally:
            left.close(); right.close()

    def test_rest_redirects_and_cross_endpoint_urls_are_refused(self):
        class Response:
            status = 302
            def read(self, _maximum): return b"{}"
            def getheaders(self): return [("Location", "https://example.test/")]
        class Connection:
            def __init__(self, *_args, **_kwargs): pass
            def request(self, *_args, **_kwargs): pass
            def getresponse(self): return Response()
            def close(self): pass
        with mock.patch.object(server, "resolve_addresses", return_value=["192.0.2.1"]), \
             mock.patch.object(server, "PinnedHTTPSConnection", Connection), \
             mock.patch.object(server.ssl, "create_default_context", return_value=object()):
            with self.assertRaisesRegex(server.RequestError, "forge_redirect_refused"):
                server.api_json(self.policy(), "GET", "https://api.github.com/repos/owner/repo", server.Deadline.start())
        with self.assertRaisesRegex(server.RequestError, "unsafe_forge_url"):
            server.api_json(self.policy(), "GET", "https://example.test/repos/owner/repo", server.Deadline.start())

    def test_maintenance_socket_is_closed_outside_maintenance_phase(self):
        body = self.root / "maintenance-body"
        body.write_bytes(b"{}")
        left, right = socket.socketpair()
        try:
            with mock.patch.object(server, "MAINTENANCE", False), \
                 mock.patch.object(server, "read_http_request", return_value=("/pr", {}, body)):
                server.handle(right, "maintenance")
            response = left.recv(4096)
            self.assertIn(b"HTTP/1.1 404", response)
            self.assertIn(b'"error":"route_not_available"', response)
        finally:
            left.close()

    def test_maintenance_contract_blocks_intake_but_keeps_status(self):
        body = self.root / "maintenance-contract-body"
        body.write_bytes(b"{}")
        cases = (("/pr", "agent"), ("/approve", "approve"))
        for route, transport in cases:
            left, right = socket.socketpair()
            try:
                with self.subTest(route=route), mock.patch.object(server, "MAINTENANCE", True), \
                     mock.patch.object(server, "read_http_request", return_value=(route, {}, body)):
                    server.handle(right, transport)
                response = left.recv(4096)
                self.assertIn(b"HTTP/1.1 503", response)
                self.assertIn(b'"error":"maintenance"', response)
            finally:
                left.close()
        request_id = str(uuid.uuid4())
        body.write_text(json.dumps({"request_id": request_id}))
        left, right = socket.socketpair()
        try:
            with mock.patch.object(server, "MAINTENANCE", True), \
                 mock.patch.object(server, "read_http_request", return_value=("/pr-status", {}, body)), \
                 mock.patch.object(server, "pr_status", return_value={"ok": True, "request_id": request_id, "state": "queued"}) as status:
                server.handle(right, "agent")
            response = left.recv(4096)
            self.assertIn(b"HTTP/1.1 200", response)
            self.assertIn(b'"state":"queued"', response)
            status.assert_called_once()
        finally:
            left.close()

    def test_preflight_is_checkout_blind_and_validates_broker_credential(self):
        self.wire()
        expected_ref = "refs/heads/main"

        def reachable(_policy, args, url, token, _deadline, *, cwd=None, timeout_cap=120):
            self.assertEqual(args, ["ls-remote", "--heads", url, expected_ref])
            self.assertEqual(token, server.TOKEN_PATH)
            self.assertIsNone(cwd)
            return subprocess.CompletedProcess(args, 0, stdout=(("a" * 40) + f"\t{expected_ref}\n").encode(), stderr=b"")

        with mock.patch.object(server, "credential", self.fake_credential), \
             mock.patch.object(server, "network_git", reachable):
            result = server.broker_preflight({"slug": "demo"}, server.Deadline.start())
        self.assertEqual(result, {"ok": True, "slug": "demo", "state": "ready"})

    def test_preflight_rejects_invalid_unwired_and_missing_base_requests(self):
        for value in ({}, {"slug": "Bad"}, {"slug": "demo", "repo": "/tmp/demo"}):
            with self.subTest(value=value), self.assertRaisesRegex(server.RequestError, "invalid_preflight_request"):
                server.broker_preflight(value, server.Deadline.start())
        with self.assertRaisesRegex(server.RequestError, "repo_not_wired"):
            server.broker_preflight({"slug": "demo"}, server.Deadline.start())
        self.wire()
        missing = subprocess.CompletedProcess([], 0, stdout=b"", stderr=b"")
        with mock.patch.object(server, "credential", self.fake_credential), \
             mock.patch.object(server, "network_git", return_value=missing), \
             self.assertRaisesRegex(server.RequestError, "base_branch_not_found"):
            server.broker_preflight({"slug": "demo"}, server.Deadline.start())

    def test_preflight_route_exposes_the_current_contract(self):
        body = self.root / "preflight-contract-body"
        body.write_text("{}")
        left, right = socket.socketpair()
        try:
            with mock.patch.object(server, "read_http_request", return_value=("/preflight", {}, body)):
                server.handle(right, "agent")
            response = left.recv(4096)
            self.assertIn(b"HTTP/1.1 400", response)
            self.assertIn(b'"error":"invalid_preflight_request"', response)
        finally:
            left.close()

    def test_title_and_body_are_both_scanned(self):
        captured = {}
        def inspect(path, _deadline):
            captured.update({item.name: item.read_text() for item in path.iterdir()})
        with mock.patch.object(server, "scan_directory", inspect):
            server.scan_title_body(server.validate_request(self.request()), server.Deadline.start())
        self.assertEqual(captured, {"title.txt": "Test change", "body.txt": "A safe body"})

    def test_typed_notification_preserves_setgid_queue_mode(self):
        request_id = str(uuid.uuid4())
        requested_modes = []
        real_mkdir = server._mkdir
        def capture_mode(path, mode):
            requested_modes.append((path, mode))
            real_mkdir(path, mode)
        with mock.patch.object(server, "_mkdir", side_effect=capture_mode):
            server.notify("queued", request_id, "demo")
        # Darwin clears setgid on unprivileged temporary directories, so assert
        # the broker requests the production mode rather than the host result.
        self.assertIn((server.NOTIFICATIONS_DIR, 0o2770), requested_modes)
        payloads = [json.loads(item.read_text()) for item in server.NOTIFICATIONS_DIR.glob("*.json")]
        self.assertEqual(payloads, [{"schema_version": 1, "event": "queued", "request_id": request_id, "slug": "demo"}])

    def test_pending_metadata_preserves_setgid_group_inheritance(self):
        requested_modes = []
        real_mkdir = server._mkdir

        def capture_mode(path, mode):
            requested_modes.append((path, mode))
            real_mkdir(path, mode)

        with mock.patch.object(server, "_mkdir", side_effect=capture_mode):
            server.initialize_state_dirs()
        # The broker is not a member of the bot group on the VPS. New metadata
        # files therefore depend on the directory's setgid bit to inherit the
        # bot-readable group instead of the broker's primary group.
        self.assertIn((server.PENDING_META_DIR, 0o2750), requested_modes)

    def test_object_scan_covers_tree_names_commit_identity_signature_and_flat_blobs(self):
        blob_oid, tree_oid, commit_oid = "a" * 40, "b" * 40, "c" * 40
        objects = {
            blob_oid: ("blob", 24), tree_oid: ("tree", 64), commit_oid: ("commit", 256),
        }
        raw = {
            blob_oid: b"SECRET_SHAPED_BLOB\n",
            tree_oid: b"100644 SECRET_SHAPED_FILENAME\0" + bytes.fromhex(blob_oid),
            commit_oid: (
                b"tree " + tree_oid.encode() + b"\n"
                b"author Fieldwork <SECRET_SHAPED_EMAIL> 1 +0000\n"
                b"committer Fieldwork <safe@example.test> 1 +0000\n"
                b"gpgsig SECRET_SHAPED_SIGNATURE\n\nSECRET_SHAPED_MESSAGE\n"
            ),
        }
        def fake_git(args, *_positional, **_keywords):
            return subprocess.CompletedProcess(args, 0, stdout=raw[args[-1]], stderr=b"")
        def inspect(path, _deadline):
            blob_dir, text_dir = path / "blobs", path / "text"
            self.assertEqual({item.name for item in blob_dir.iterdir()}, {blob_oid})
            self.assertEqual((blob_dir / blob_oid).read_bytes(), raw[blob_oid])
            tree_text = (text_dir / "tree-names.txt").read_bytes()
            self.assertIn(b"SECRET_SHAPED_FILENAME", tree_text)
            self.assertIn(b"5345435245545f5348415045445f46494c454e414d45", tree_text)
            commit_text = b"".join(item.read_bytes() for item in text_dir.glob("commit-*.txt"))
            for marker in (b"SECRET_SHAPED_EMAIL", b"SECRET_SHAPED_SIGNATURE", b"SECRET_SHAPED_MESSAGE"):
                self.assertIn(marker, commit_text)
        with mock.patch.object(server, "run_git", side_effect=fake_git), mock.patch.object(server, "scan_directory", side_effect=inspect):
            server.scan_objects(self.root, objects, server.Deadline.start())

    def test_require_gate_persists_without_forge_write(self):
        self.wire(approval="require")
        pack = self.root / "incoming.pack"; pack.write_bytes(b"PACK-test")
        req = server.validate_request(self.request())
        with mock.patch.object(server, "scan_title_body"), \
             mock.patch.object(server, "credential", self.fake_credential), \
             mock.patch.object(server, "quarantine", self.fake_quarantine), \
             mock.patch.object(server, "push_head") as push, \
             mock.patch.object(server, "create_pr") as create:
            result = server.submit_pr(req, pack, server.Deadline.start())
        self.assertEqual(result["state"], "queued")
        push.assert_not_called(); create.assert_not_called()
        self.assertTrue((server.PENDING_PACK_DIR / f"{req.request_id}.pack").is_file())

    def test_auto_is_durable_before_processing(self):
        self.wire(approval="auto")
        pack = self.root / "incoming.pack"; pack.write_bytes(b"PACK-test")
        req = server.validate_request(self.request())
        observed = {}
        def process(request_id, _deadline):
            observed.update(server.load_record(request_id))
            return server.load_record(request_id)
        with mock.patch.object(server, "scan_title_body"), \
             mock.patch.object(server, "credential", self.fake_credential), \
             mock.patch.object(server, "quarantine", self.fake_quarantine), \
             mock.patch.object(server, "process_record", process):
            server.submit_pr(req, pack, server.Deadline.start())
        self.assertEqual(observed["state"], "approved")
        self.assertTrue((server.PENDING_PACK_DIR / f"{req.request_id}.pack").is_file())

    def test_failed_first_persistence_rolls_back_replay_reservation(self):
        self.wire(approval="require")
        pack = self.root / "incoming.pack"; pack.write_bytes(b"PACK-test")
        req = server.validate_request(self.request())
        with mock.patch.object(server, "scan_title_body"), \
             mock.patch.object(server, "credential", self.fake_credential), \
             mock.patch.object(server, "quarantine", self.fake_quarantine), \
             mock.patch.object(server, "persist_pack", side_effect=OSError("disk full")):
            with self.assertRaisesRegex(OSError, "disk full"):
                server.submit_pr(req, pack, server.Deadline.start())
        self.assertFalse((server.LEDGER_DIR / f"{req.request_id}.json").exists())
        self.assertFalse((server.PENDING_PACK_DIR / f"{req.request_id}.pack").exists())

    def queued(self):
        self.wire(approval="require")
        pack = self.root / f"incoming-{uuid.uuid4().hex}.pack"; pack.write_bytes(b"PACK-test")
        req = server.validate_request(self.request())
        with mock.patch.object(server, "scan_title_body"), mock.patch.object(server, "credential", self.fake_credential), mock.patch.object(server, "quarantine", self.fake_quarantine):
            server.submit_pr(req, pack, server.Deadline.start())
        return req

    def test_record_mac_and_pack_digest_fail_closed(self):
        req = self.queued()
        path = server.PENDING_META_DIR / f"{req.request_id}.json"
        value = json.loads(path.read_text()); value["title"] = "tampered"; path.write_text(json.dumps(value))
        with self.assertRaisesRegex(server.RequestError, "metadata_tampered"):
            server.load_record(req.request_id)
        # Restore a new request and corrupt only its stored pack.
        req = self.queued()
        (server.PENDING_PACK_DIR / f"{req.request_id}.pack").write_bytes(b"changed")
        with self.assertRaisesRegex(server.RequestError, "metadata_tampered"):
            server.verify_stored_pack(server.load_record(req.request_id))

    def test_authority_file_readers_refuse_symlinks_and_oversized_files(self):
        outside = self.root / "outside-key"; outside.write_bytes(os.urandom(64))
        server.MAC_KEY_PATH.unlink(); server.MAC_KEY_PATH.symlink_to(outside)
        with self.assertRaisesRegex(server.RequestError, "mac_key_unavailable"):
            server._mac_key()
        auth = self.root / "http-auth"; auth.write_bytes(b"x" * 4097)
        old_auth = server.HTTP_AUTH_TOKEN_PATH
        try:
            server.HTTP_AUTH_TOKEN_PATH = str(auth)
            with self.assertRaisesRegex(server.RequestError, "http_auth_unconfigured"):
                server._http_auth_token()
        finally:
            server.HTTP_AUTH_TOKEN_PATH = old_auth

    def test_policy_drift_moves_request_to_needs_operator(self):
        req = self.queued()
        self.wire(approval="auto")
        result = server.process_record(req.request_id, server.Deadline.start())
        self.assertEqual(result["state"], "needs_operator")
        self.assertEqual(result["error_code"], "policy_changed")

    def test_deny_is_terminal_and_replay_returns_tombstone(self):
        req = self.queued()
        result = server.approve_request({"request_id": req.request_id, "decision": "deny"}, server.Deadline.start())
        self.assertEqual(result["state"], "denied")
        self.assertFalse((server.PENDING_PACK_DIR / f"{req.request_id}.pack").exists())
        self.assertEqual(server.existing_request(req.request_id)["state"], "denied")
        self.assertEqual(server.pr_status({"request_id": req.request_id})["state"], "denied")

    def test_status_expires_queued_request_durably(self):
        req = self.queued()
        record = server.load_record(req.request_id)
        record["expires_at"] = "2020-01-01T00:00:00Z"
        server.write_record({key: value for key, value in record.items() if key != "mac"})
        self.assertEqual(server.pr_status({"request_id": req.request_id})["state"], "expired")
        self.assertTrue((server.TOMBSTONE_DIR / f"{req.request_id}.json").is_file())

    def test_sweep_preserves_valid_record_after_unexpected_reconcile_fault(self):
        req = self.queued()
        record = server.load_record(req.request_id)
        server.transition(record, "approved")
        with mock.patch.object(server, "process_record", side_effect=RuntimeError("crash after push")):
            server.sweep_state()
        self.assertTrue((server.PENDING_META_DIR / f"{req.request_id}.json").is_file())
        self.assertTrue((server.PENDING_PACK_DIR / f"{req.request_id}.pack").is_file())

    def test_sweep_finishes_interrupted_terminalization(self):
        req = self.queued()
        record = server.transition(server.load_record(req.request_id), "denied")
        self.assertTrue((server.PENDING_META_DIR / f"{req.request_id}.json").is_file())
        server.sweep_state()
        self.assertFalse((server.PENDING_META_DIR / f"{req.request_id}.json").exists())
        self.assertFalse((server.PENDING_PACK_DIR / f"{req.request_id}.pack").exists())
        self.assertEqual(server.load_record(req.request_id)["state"], record["state"])

    def test_reconciliation_is_idempotent_when_branch_and_pr_exist(self):
        self.wire(approval="auto")
        pack = self.root / "incoming.pack"; pack.write_bytes(b"PACK-test")
        req = server.validate_request(self.request())
        with mock.patch.object(server, "scan_title_body"), mock.patch.object(server, "credential", self.fake_credential), mock.patch.object(server, "quarantine", self.fake_quarantine), mock.patch.object(server, "process_record", lambda rid, dl: server.load_record(rid)):
            server.submit_pr(req, pack, server.Deadline.start())
        with mock.patch.object(server, "scan_title_body"), \
             mock.patch.object(server, "credential", self.fake_credential), \
             mock.patch.object(server, "quarantine", self.fake_quarantine), \
             mock.patch.object(server, "remote_branch_oid", return_value=req.head_oid), \
             mock.patch.object(server, "find_pr", return_value="https://example.test/pr/1"), \
             mock.patch.object(server, "push_head") as push, \
             mock.patch.object(server, "create_pr") as create:
            result = server.process_record(req.request_id, server.Deadline.start())
        self.assertEqual(result["state"], "done")
        push.assert_not_called(); create.assert_not_called()

    def test_existing_pr_branch_accepts_only_fast_forward_updates(self):
        existing_oid = "3" * 40
        for fast_forward in (True, False):
            with self.subTest(fast_forward=fast_forward):
                req = self.durable_approved_request()
                with mock.patch.object(server, "scan_title_body"), \
                     mock.patch.object(server, "credential", self.fake_credential), \
                     mock.patch.object(server, "quarantine", self.fake_quarantine), \
                     mock.patch.object(server, "remote_branch_oid", return_value=existing_oid), \
                     mock.patch.object(server, "branch_update_is_fast_forward", return_value=fast_forward) as check, \
                     mock.patch.object(server, "find_pr", return_value="https://example.test/pr/1"), \
                     mock.patch.object(server, "push_head") as push, \
                     mock.patch.object(server, "create_pr") as create:
                    result = server.process_record(req.request_id, server.Deadline.start())
                check.assert_called_once()
                if fast_forward:
                    self.assertEqual(result["state"], "done")
                    push.assert_called_once()
                    create.assert_not_called()
                else:
                    self.assertEqual(result["state"], "failed")
                    self.assertEqual(result["error_code"], "branch_conflict")
                    push.assert_not_called()
                    create.assert_not_called()

    def durable_approved_request(self):
        self.wire(approval="auto")
        pack = self.root / f"incoming-{uuid.uuid4().hex}.pack"; pack.write_bytes(b"PACK-test")
        req = server.validate_request(self.request())
        with mock.patch.object(server, "scan_title_body"), mock.patch.object(server, "credential", self.fake_credential), \
             mock.patch.object(server, "quarantine", self.fake_quarantine), \
             mock.patch.object(server, "process_record", lambda rid, dl: server.load_record(rid)):
            server.submit_pr(req, pack, server.Deadline.start())
        return req

    def test_fault_boundaries_resume_without_duplicate_forge_writes(self):
        for label in ("before_push", "after_push"):
            with self.subTest(label=label):
                req = self.durable_approved_request()
                with mock.patch.dict(os.environ, {"FIELDWORK_BROKER_FAULT": label}), \
                     mock.patch.object(server, "scan_title_body"), mock.patch.object(server, "credential", self.fake_credential), \
                     mock.patch.object(server, "quarantine", self.fake_quarantine), \
                     mock.patch.object(server, "remote_branch_oid", return_value=None), \
                     mock.patch.object(server, "push_head") as first_push:
                    with self.assertRaisesRegex(RuntimeError, label):
                        server.process_record(req.request_id, server.Deadline.start())
                self.assertEqual(first_push.call_count, 0 if label == "before_push" else 1)
                retry_remote = None if label == "before_push" else req.head_oid
                with mock.patch.dict(os.environ, {}, clear=False), \
                     mock.patch.object(server, "scan_title_body"), mock.patch.object(server, "credential", self.fake_credential), \
                     mock.patch.object(server, "quarantine", self.fake_quarantine), \
                     mock.patch.object(server, "remote_branch_oid", return_value=retry_remote), \
                     mock.patch.object(server, "find_pr", return_value=None), \
                     mock.patch.object(server, "push_head") as retry_push, \
                     mock.patch.object(server, "create_pr", return_value="https://example.test/pr/1") as create:
                    os.environ.pop("FIELDWORK_BROKER_FAULT", None)
                    result = server.process_record(req.request_id, server.Deadline.start())
                self.assertEqual(result["state"], "done")
                self.assertEqual(retry_push.call_count, 1 if label == "before_push" else 0)
                create.assert_called_once()

        for label in ("before_pr", "after_pr"):
            with self.subTest(label=label):
                req = self.durable_approved_request()
                server.transition(server.load_record(req.request_id), "pushed")
                with mock.patch.dict(os.environ, {"FIELDWORK_BROKER_FAULT": label}), \
                     mock.patch.object(server, "scan_title_body"), mock.patch.object(server, "credential", self.fake_credential), \
                     mock.patch.object(server, "quarantine", self.fake_quarantine), \
                     mock.patch.object(server, "find_pr", return_value=None), \
                     mock.patch.object(server, "create_pr", return_value="https://example.test/pr/1") as first_create:
                    with self.assertRaisesRegex(RuntimeError, label):
                        server.process_record(req.request_id, server.Deadline.start())
                self.assertEqual(first_create.call_count, 0 if label == "before_pr" else 1)
                retry_url = None if label == "before_pr" else "https://example.test/pr/1"
                with mock.patch.dict(os.environ, {}, clear=False), \
                     mock.patch.object(server, "scan_title_body"), mock.patch.object(server, "credential", self.fake_credential), \
                     mock.patch.object(server, "quarantine", self.fake_quarantine), \
                     mock.patch.object(server, "find_pr", return_value=retry_url), \
                     mock.patch.object(server, "create_pr", return_value="https://example.test/pr/1") as retry_create:
                    os.environ.pop("FIELDWORK_BROKER_FAULT", None)
                    result = server.process_record(req.request_id, server.Deadline.start())
                self.assertEqual(result["state"], "done")
                self.assertEqual(retry_create.call_count, 1 if label == "before_pr" else 0)

    def test_policy_writer_waits_for_the_processing_lock(self):
        self.wire()
        started, finished = threading.Event(), threading.Event()
        def replace_policy():
            started.set()
            with policy_writer.policy_lock(server.POLICY_DIR, "demo"):
                policy_writer.write_policy(server.POLICY_DIR, "demo", self.policy(approval="auto"))
            finished.set()
        with policy_writer.policy_lock(server.POLICY_DIR, "demo"):
            worker = threading.Thread(target=replace_policy, daemon=True)
            worker.start()
            self.assertTrue(started.wait(1))
            self.assertFalse(finished.wait(0.05))
            self.assertEqual(server.read_policy(server.POLICY_DIR, "demo")["approval"], "require")
        self.assertTrue(finished.wait(1))
        worker.join(1)
        self.assertEqual(server.read_policy(server.POLICY_DIR, "demo")["approval"], "auto")

    def git_fixture(self):
        seed = self.root / f"seed-{uuid.uuid4().hex}"; seed.mkdir()
        git(seed, "init", "-b", "main")
        git(seed, "config", "user.email", "test@example.test")
        git(seed, "config", "user.name", "Test")
        (seed / "base.txt").write_text("base\n")
        git(seed, "add", "base.txt"); git(seed, "commit", "-m", "base")
        base = git(seed, "rev-parse", "HEAD").decode().strip()
        remote = self.root / f"remote-{uuid.uuid4().hex}.git"
        git(self.root, "clone", "--bare", str(seed), str(remote))
        work = self.root / f"work-{uuid.uuid4().hex}"
        git(self.root, "clone", str(remote), str(work))
        git(work, "config", "user.email", "test@example.test"); git(work, "config", "user.name", "Test")
        git(work, "checkout", "-b", "fieldwork/test-change")
        (work / "change.txt").write_text("safe change\n")
        git(work, "add", "change.txt"); git(work, "commit", "-m", "change")
        head = git(work, "rev-parse", "HEAD").decode().strip()
        return remote, work, base, head

    def pack(self, work: Path, revs: str, *, thin: bool = False) -> Path:
        args = ["pack-objects", "--revs", "--stdout"]
        if thin:
            args.insert(1, "--thin")
        data = git(work, *args, input_bytes=revs.encode())
        path = self.root / f"pack-{uuid.uuid4().hex}"
        path.write_bytes(data)
        return path

    def quarantine_request(self, head, common):
        return server.validate_request(self.request(head_oid=head, common_base_oid=common))

    def fake_fetch(self, remote: Path):
        def run(_policy, args, _url, _token, _deadline, *, cwd=None, timeout_cap=120):
            translated = [str(remote) if isinstance(arg, str) and arg.startswith("https://") else arg for arg in args]
            result = subprocess.run(["/usr/bin/git", *translated], cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if result.returncode:
                raise server.RequestError("git_forge_failed", 502)
            return result
        return run

    def test_quarantine_accepts_normal_and_full_non_thin_packs(self):
        remote, work, base, head = self.git_fixture()
        for common, revs in ((base, f"{head}\n^{base}\n"), (None, f"{head}\n")):
            with self.subTest(common=common), mock.patch.object(server, "network_git", self.fake_fetch(remote)), mock.patch.object(server, "scan_objects"):
                with server.quarantine(self.quarantine_request(head, common), self.pack(work, revs), self.policy(), server.TOKEN_PATH, server.Deadline.start()) as repo:
                    self.assertTrue((repo / "objects").is_dir())

    def test_quarantine_rejects_thin_pack(self):
        seed = self.root / "thin-seed"; seed.mkdir()
        git(seed, "init", "-b", "main")
        git(seed, "config", "user.email", "test@example.test"); git(seed, "config", "user.name", "Test")
        (seed / "large.txt").write_text("base-line\n" * 20000)
        git(seed, "add", "large.txt"); git(seed, "commit", "-m", "base")
        base = git(seed, "rev-parse", "HEAD").decode().strip()
        remote = self.root / "thin-remote.git"
        git(self.root, "clone", "--bare", str(seed), str(remote))
        work = self.root / "thin-work"
        git(self.root, "clone", str(remote), str(work))
        git(work, "config", "user.email", "test@example.test"); git(work, "config", "user.name", "Test")
        git(work, "checkout", "-b", "fieldwork/test-change")
        lines = (work / "large.txt").read_text().splitlines()
        lines[10000] = "changed-line"
        (work / "large.txt").write_text("\n".join(lines) + "\n")
        git(work, "add", "large.txt"); git(work, "commit", "-m", "change")
        head = git(work, "rev-parse", "HEAD").decode().strip()
        thin = self.pack(work, f"{head}\n^{base}\n", thin=True)
        with mock.patch.object(server, "network_git", self.fake_fetch(remote)), mock.patch.object(server, "scan_objects"):
            with self.assertRaisesRegex(server.RequestError, "invalid_pack"):
                with server.quarantine(self.quarantine_request(head, base), thin, self.policy(), server.TOKEN_PATH, server.Deadline.start()):
                    pass

    def test_quarantine_maps_sha256_pack_to_unsupported_format(self):
        probe = self.root / "sha256-work"
        initialized = subprocess.run(
            ["/usr/bin/git", "init", "--object-format=sha256", "-b", "main", str(probe)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env={"PATH": "/usr/bin:/bin", "HOME": str(self.root)},
        )
        if initialized.returncode != 0 or git(probe, "rev-parse", "--show-object-format").strip() != b"sha256":
            self.skipTest("installed Git does not support SHA-256 repositories")
        git(probe, "config", "user.email", "test@example.test"); git(probe, "config", "user.name", "Test")
        (probe / "file.txt").write_text("sha256 object format\n")
        git(probe, "add", "file.txt"); git(probe, "commit", "-m", "sha256")
        sha_head = git(probe, "rev-parse", "HEAD").decode().strip()
        sha_pack = self.pack(probe, f"{sha_head}\n")
        remote, _work, _base, _head = self.git_fixture()
        request = self.quarantine_request("1" * 40, None)
        with mock.patch.object(server, "network_git", self.fake_fetch(remote)), mock.patch.object(server, "scan_objects"):
            with self.assertRaisesRegex(server.RequestError, "unsupported_object_format"):
                with server.quarantine(request, sha_pack, self.policy(), server.TOKEN_PATH, server.Deadline.start()):
                    pass

    def test_quarantine_rejects_stuffed_pack(self):
        remote, work, base, head = self.git_fixture()
        git(work, "checkout", "--orphan", "stuff")
        git(work, "rm", "-rf", ".")
        (work / "stuff.txt").write_text("extra\n")
        git(work, "add", "stuff.txt"); git(work, "commit", "-m", "stuff")
        extra = git(work, "rev-parse", "HEAD").decode().strip()
        stuffed = self.pack(work, f"{head}\n^{base}\n{extra}\n")
        with mock.patch.object(server, "network_git", self.fake_fetch(remote)), mock.patch.object(server, "scan_objects"):
            with self.assertRaisesRegex(server.RequestError, "unexpected_objects"):
                with server.quarantine(self.quarantine_request(head, base), stuffed, self.policy(), server.TOKEN_PATH, server.Deadline.start()):
                    pass

    def test_quarantine_rejects_stale_invalid_and_unrelated_histories(self):
        remote, work, base, head = self.git_fixture()
        unrelated = self.root / "unrelated"; unrelated.mkdir()
        git(unrelated, "init", "-b", "main")
        git(unrelated, "config", "user.email", "test@example.test"); git(unrelated, "config", "user.name", "Test")
        (unrelated / "other.txt").write_text("other\n")
        git(unrelated, "add", "other.txt"); git(unrelated, "commit", "-m", "other")
        unrelated_head = git(unrelated, "rev-parse", "HEAD").decode().strip()
        unrelated_pack = self.pack(unrelated, f"{unrelated_head}\n")
        with mock.patch.object(server, "network_git", self.fake_fetch(remote)), mock.patch.object(server, "scan_objects"):
            with self.assertRaisesRegex(server.RequestError, "unrelated_history"):
                with server.quarantine(self.quarantine_request(unrelated_head, None), unrelated_pack, self.policy(), server.TOKEN_PATH, server.Deadline.start()):
                    pass
            with self.assertRaisesRegex(server.RequestError, "invalid_base_claim"):
                with server.quarantine(self.quarantine_request(unrelated_head, base), unrelated_pack, self.policy(), server.TOKEN_PATH, server.Deadline.start()):
                    pass
            missing_ancestor = "d" * 40
            with self.assertRaisesRegex(server.RequestError, "stale_base"):
                with server.quarantine(self.quarantine_request(head, missing_ancestor), self.pack(work, f"{head}\n^{base}\n"), self.policy(), server.TOKEN_PATH, server.Deadline.start()):
                    pass

    def test_quarantine_enforces_policy_delta_cap(self):
        remote, work, base, head = self.git_fixture()
        pack = self.pack(work, f"{head}\n^{base}\n")
        old = server.SCAN_MAX_OBJECTS; server.SCAN_MAX_OBJECTS = 1
        try:
            with mock.patch.object(server, "network_git", self.fake_fetch(remote)), mock.patch.object(server, "scan_objects"):
                with self.assertRaisesRegex(server.RequestError, "scan_range_too_large"):
                    with server.quarantine(self.quarantine_request(head, base), pack, self.policy(), server.TOKEN_PATH, server.Deadline.start()):
                        pass
        finally:
            server.SCAN_MAX_OBJECTS = old

    def test_quarantine_enforces_physical_object_cap(self):
        remote, work, base, head = self.git_fixture()
        pack = self.pack(work, f"{head}\n^{base}\n")
        old = server.PACK_MAX_OBJECTS; server.PACK_MAX_OBJECTS = 1
        try:
            with mock.patch.object(server, "network_git", self.fake_fetch(remote)), mock.patch.object(server, "scan_objects"):
                with self.assertRaisesRegex(server.RequestError, "pack_limits_exceeded"):
                    with server.quarantine(self.quarantine_request(head, base), pack, self.policy(), server.TOKEN_PATH, server.Deadline.start()):
                        pass
        finally:
            server.PACK_MAX_OBJECTS = old

    def test_verify_pack_layout_enforces_object_and_delta_caps(self):
        oid = "a" * 40
        base = "b" * 40
        old_size, old_depth = server.PACK_MAX_OBJECT_BYTES, server.PACK_MAX_DELTA_DEPTH
        try:
            server.PACK_MAX_OBJECT_BYTES = 10
            with self.assertRaisesRegex(server.RequestError, "pack_limits_exceeded"):
                server.validate_pack_layout(f"{oid} blob 11 8 12\n".encode(), [oid])
            server.PACK_MAX_OBJECT_BYTES = 100
            server.PACK_MAX_DELTA_DEPTH = 2
            with self.assertRaisesRegex(server.RequestError, "pack_limits_exceeded"):
                server.validate_pack_layout(f"{oid} blob 9 8 12 3 {base}\n".encode(), [oid])
            with self.assertRaisesRegex(server.RequestError, "invalid_pack"):
                server.validate_pack_layout(b"\xff", [oid])
        finally:
            server.PACK_MAX_OBJECT_BYTES, server.PACK_MAX_DELTA_DEPTH = old_size, old_depth


if __name__ == "__main__":
    unittest.main(verbosity=2)
