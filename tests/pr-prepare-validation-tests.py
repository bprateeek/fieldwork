#!/usr/bin/env python3
"""Prepare schema plus protocol-v2 builder/uploader tests."""

from __future__ import annotations

import importlib.util
from importlib.machinery import SourceFileLoader
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import tempfile
import threading
import unittest
import uuid
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
PREPARE_SCHEMA = ROOT / "schema/pr-prepare-request.schema.json"


class SchemaError(Exception):
    pass


def validate(value, schema):
    expected = schema.get("type")
    if expected == "object":
        if not isinstance(value, dict): raise SchemaError("must be object")
        for field in schema.get("required", []):
            if field not in value: raise SchemaError(f"missing {field}")
        if schema.get("additionalProperties") is False:
            extras = set(value) - set(schema.get("properties", {}))
            if extras: raise SchemaError(f"unexpected {sorted(extras)[0]}")
        for field, rules in schema.get("properties", {}).items():
            if field in value:
                try: validate(value[field], rules)
                except SchemaError as exc: raise SchemaError(f"{field}: {exc}") from None
    elif expected == "array":
        if not isinstance(value, list): raise SchemaError("must be array")
        if len(value) < schema.get("minItems", 0) or len(value) > schema.get("maxItems", 1 << 30): raise SchemaError("array length")
        for item in value: validate(item, schema.get("items", {}))
    elif expected == "string":
        if not isinstance(value, str): raise SchemaError("must be string")
        if len(value) < schema.get("minLength", 0) or len(value) > schema.get("maxLength", 1 << 30): raise SchemaError("string length")
        if schema.get("pattern") and not re.fullmatch(schema["pattern"], value): raise SchemaError("pattern")


def prepare_request():
    return {
        "request_id": str(uuid.uuid4()), "created_at": "2026-07-18T12:00:00Z",
        "repo_path": "/home/fieldwork/projects/demo", "branch": "fieldwork/test-change",
        "paths": ["src/a.py"], "message": "fix: safe change\n",
    }


class PrepareSchemaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.schema = json.loads(PREPARE_SCHEMA.read_text())

    def test_valid_request(self):
        validate(prepare_request(), self.schema)

    def test_required_fields_and_extras(self):
        for field in prepare_request():
            value = prepare_request(); del value[field]
            with self.subTest(field=field), self.assertRaises(SchemaError): validate(value, self.schema)
        value = prepare_request(); value["title"] = "extra"
        with self.assertRaises(SchemaError): validate(value, self.schema)

    def test_field_constraints(self):
        cases = [
            ("request_id", "not-a-uuid"), ("created_at", "2026-07-18T12:00:00+01:00"),
            ("repo_path", "/tmp/demo"), ("branch", "main"), ("branch", "fieldwork/Upper"),
            ("paths", []), ("paths", [f"f{i}" for i in range(101)]),
            ("paths", ["/etc/passwd"]), ("paths", ["bad\nname"]),
            ("message", ""), ("message", "x" * 8193),
        ]
        for field, replacement in cases:
            value = prepare_request(); value[field] = replacement
            with self.subTest(field=field, replacement=replacement), self.assertRaises(SchemaError): validate(value, self.schema)


def load_script(name: str, path: Path):
    spec = importlib.util.spec_from_loader(name, SourceFileLoader(name, str(path)))
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


builder = load_script("fieldwork_pr_build_tests", ROOT / "lib/scripts/fieldwork-pr-build")
uploader = load_script("fieldwork_pr_upload_tests", ROOT / "lib/scripts/fieldwork-pr-upload")


class ProtocolV2ClientTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="fieldwork-v2-clients-")
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"; self.repo.mkdir()
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "test@example.test"); self.git("config", "user.name", "Test")
        (self.repo / "base.txt").write_text("base\n")
        (self.repo / ".gitignore").write_text(".fieldwork/local/\n")
        self.git("add", "base.txt", ".gitignore"); self.git("commit", "-q", "-m", "base")
        self.base = self.git_output("rev-parse", "HEAD")
        self.git("checkout", "-q", "-b", "fieldwork/test-change")
        (self.repo / "change.txt").write_text("change\n"); self.git("add", "change.txt"); self.git("commit", "-q", "-m", "change")
        (self.repo / ".fieldwork/local").mkdir(parents=True)
        self.spool = self.root / "spool"; self.spool.mkdir(mode=0o700)

    def tearDown(self):
        self.temp.cleanup()

    def git(self, *args):
        subprocess.run(["/usr/bin/git", *args], cwd=self.repo, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def git_output(self, *args):
        return subprocess.check_output(["/usr/bin/git", *args], cwd=self.repo, text=True).strip()

    def request_file(self, **updates):
        value = {
            "schema_version": 2, "slug": "demo", "branch": "fieldwork/test-change",
            "title": "Test change", "body": "Protocol-v2 client test", "common_base_oid": self.base,
        }
        value.update(updates)
        path = self.repo / ".fieldwork/local" / f"request-{uuid.uuid4().hex}.json"
        path.write_text(json.dumps(value))
        return path

    def build(self, **updates):
        old = Path.cwd(); os.chdir(self.repo)
        try: return builder.build(self.request_file(**updates), parent=self.spool)
        finally: os.chdir(old)

    def test_builder_publishes_only_meta_and_nonthin_pack(self):
        request_id = self.build()
        directory = self.spool / request_id
        self.assertEqual({p.name for p in directory.iterdir()}, {"meta.json", "pack"})
        meta = json.loads((directory / "meta.json").read_text())
        self.assertEqual(meta["head_oid"], self.git_output("rev-parse", "HEAD"))
        bare = self.root / "bare.git"
        subprocess.run(["/usr/bin/git", "init", "--bare", str(bare)], check=True, stdout=subprocess.DEVNULL)
        subprocess.run(["/usr/bin/git", "-C", str(bare), "fetch", str(self.repo), self.base], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        with (directory / "pack").open("rb") as handle:
            result = subprocess.run(["/usr/bin/git", "-C", str(bare), "index-pack", "--stdin", "--strict"], stdin=handle, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))

    def test_builder_rejects_dirty_ref_and_alternates(self):
        (self.repo / "untracked").write_text("dirty")
        with self.assertRaisesRegex(builder.BuildError, "repository is not clean"): self.build()
        (self.repo / "untracked").unlink()
        with self.assertRaisesRegex(builder.BuildError, "valid Git branch"): self.build(branch="fieldwork/bad//name")
        alternates = Path(self.git_output("rev-parse", "--absolute-git-dir")) / "objects/info/alternates"
        alternates.write_text(str(self.root / "other-objects"))
        with self.assertRaisesRegex(builder.BuildError, "alternates"): self.build()

    def test_builder_environment_is_scrubbed(self):
        with mock.patch.dict(os.environ, {"GIT_DIR": "/tmp/evil", "HTTPS_PROXY": "http://evil", "GIT_CONFIG_COUNT": "1"}): env = builder.fixed_git_env()
        for key in ("GIT_DIR", "HTTPS_PROXY", "GIT_CONFIG_COUNT"): self.assertNotIn(key, env)
        self.assertEqual(env["GIT_CONFIG_GLOBAL"], "/dev/null")

    def test_builder_rejects_sha256_object_format_client_side(self):
        real_git_text = builder.git_text
        def object_format(*args):
            if args == ("rev-parse", "--show-object-format"):
                return "sha256"
            return real_git_text(*args)
        old = Path.cwd(); os.chdir(self.repo)
        try:
            with mock.patch.object(builder, "git_text", side_effect=object_format):
                with self.assertRaisesRegex(builder.BuildError, "SHA-256"):
                    builder.build(self.request_file(), parent=self.spool)
        finally:
            os.chdir(old)

    def test_builder_removes_incomplete_request_directory(self):
        request_id = str(uuid.uuid4())
        real_run = subprocess.run
        def fail_pack(args, *positional, **keywords):
            if len(args) > 1 and args[1] == "pack-objects":
                return subprocess.CompletedProcess(args, 1, stderr=b"synthetic pack failure")
            return real_run(args, *positional, **keywords)
        old = Path.cwd(); os.chdir(self.repo)
        try:
            with mock.patch.object(builder.subprocess, "run", side_effect=fail_pack):
                with self.assertRaisesRegex(builder.BuildError, "synthetic pack failure"):
                    builder.build(self.request_file(request_id=request_id), parent=self.spool)
        finally:
            os.chdir(old)
        self.assertFalse((self.spool / request_id).exists())

    def test_uploader_directory_walk_refuses_symlink(self):
        safe = self.root / "safe"
        safe.mkdir(mode=0o700)
        link = self.root / "link"
        link.symlink_to(safe, target_is_directory=True)
        with self.assertRaises(OSError):
            uploader._open_dir(link, os.getuid())

    def fake_broker(self, captured: dict, state="queued"):
        client, accepted = socket.socketpair()
        def serve():
            with accepted:
                data = b""
                while b"\r\n\r\n" not in data: data += accepted.recv(4096)
                head, _, body = data.partition(b"\r\n\r\n")
                length = int(next(line.split(b":", 1)[1] for line in head.split(b"\r\n") if line.lower().startswith(b"content-length:")))
                while len(body) < length: body += accepted.recv(65536)
                captured["request"] = head + b"\r\n\r\n" + body[:length]
                payload = json.dumps({"ok": True, "request_id": captured["request_id"], "state": state}).encode() + b"\n"
                accepted.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: " + str(len(payload)).encode() + b"\r\nConnection: close\r\n\r\n" + payload)
        thread = threading.Thread(target=serve, daemon=True); thread.start(); return thread, client

    def test_uploader_streams_exact_spool_without_subprocess(self):
        request_id = self.build(); captured = {"request_id": request_id}
        thread, client = self.fake_broker(captured)
        with mock.patch.object(uploader, "_open_dir", return_value=os.open(self.spool, os.O_RDONLY)), mock.patch.object(uploader, "_connect", return_value=client), mock.patch("subprocess.run", side_effect=AssertionError("no subprocess")):
            result = uploader.upload(request_id)
        thread.join(2)
        self.assertEqual(result["state"], "queued")
        self.assertIn(b'name="meta"', captured["request"]); self.assertIn(b'name="pack"', captured["request"])
        self.assertNotIn(b"repo_path", captured["request"])

    def test_status_uses_post_contract(self):
        request_id = str(uuid.uuid4()); captured = {"request_id": request_id}
        thread, client = self.fake_broker(captured, "done")
        with mock.patch.object(uploader, "_connect", return_value=client): result = uploader.status(request_id)
        thread.join(2)
        self.assertEqual(result["state"], "done")
        self.assertTrue(captured["request"].startswith(b"POST /pr-status HTTP/1.1"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
