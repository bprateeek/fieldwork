#!/usr/bin/env python3
"""PR-prepare schema validation smoke tests.

These tests exercise schema/pr-prepare-request.schema.json against a small
generic validator. They are static (no socket, no git, no FS scratch beyond
the schema itself).
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest
import uuid
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
SCHEMA_PATH = ROOT / "schema" / "pr-prepare-request.schema.json"
PREPARE_CLIENT = ROOT / "lib/scripts/fieldwork-pr-prepare"
SUBMIT_CLIENT = ROOT / "lib/scripts/fieldwork-pr-submit"


class SchemaError(Exception):
    """Raised when a request fails schema validation."""


def validate_against_schema(value: Any, schema: dict) -> None:
    """Minimal JSON Schema subset validator. Handles the rules the
    prepare runner's preflight relies on. Keep it dependency-free so
    tests pass on a bare Python 3 install."""
    expected_type = schema.get("type")
    if expected_type == "object":
        if not isinstance(value, dict):
            raise SchemaError("must be an object")
        required = schema.get("required", [])
        for field in required:
            if field not in value:
                raise SchemaError(f"missing required field: {field}")
        if schema.get("additionalProperties") is False:
            allowed = set(schema.get("properties", {}).keys())
            extras = sorted(set(value.keys()) - allowed)
            if extras:
                raise SchemaError(f"unexpected field: {extras[0]}")
        for field, rules in schema.get("properties", {}).items():
            if field in value:
                try:
                    validate_against_schema(value[field], rules)
                except SchemaError as exc:
                    raise SchemaError(f"{field}: {exc}") from None
    elif expected_type == "array":
        if not isinstance(value, list):
            raise SchemaError("must be an array")
        if "minItems" in schema and len(value) < schema["minItems"]:
            raise SchemaError(f"array shorter than minItems={schema['minItems']}")
        if "maxItems" in schema and len(value) > schema["maxItems"]:
            raise SchemaError(f"array longer than maxItems={schema['maxItems']}")
        item_schema = schema.get("items")
        if item_schema:
            for idx, item in enumerate(value):
                try:
                    validate_against_schema(item, item_schema)
                except SchemaError as exc:
                    raise SchemaError(f"[{idx}]: {exc}") from None
    elif expected_type == "string":
        if not isinstance(value, str):
            raise SchemaError("must be a string")
        if "minLength" in schema and len(value) < schema["minLength"]:
            raise SchemaError(f"too short (minLength={schema['minLength']})")
        if "maxLength" in schema and len(value) > schema["maxLength"]:
            raise SchemaError(f"too long (maxLength={schema['maxLength']})")
        pattern = schema.get("pattern")
        if pattern and not re.fullmatch(pattern, value):
            raise SchemaError(f"does not match pattern: {pattern}")


def load_schema() -> dict:
    return json.loads(SCHEMA_PATH.read_text())


def valid_request() -> dict:
    return {
        "request_id": str(uuid.uuid4()),
        "created_at": "2026-05-17T10:30:00Z",
        "repo_path": "/home/fieldwork/projects/fieldwork-smoke",
        "branch": "fieldwork/test-change",
        "paths": ["src/a.py", "src/b.py"],
        "message": "fix: tighten validation\n\nDescription of why.\n",
    }


class PrPrepareValidationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.schema = load_schema()

    def assertValid(self, req: dict) -> None:
        try:
            validate_against_schema(req, self.schema)
        except SchemaError as exc:
            self.fail(f"expected request to validate, got: {exc}")

    def assertRejects(self, req: dict, contains: str) -> None:
        with self.assertRaises(SchemaError) as ctx:
            validate_against_schema(req, self.schema)
        self.assertIn(contains, str(ctx.exception))

    # ----- positive ----------

    def test_valid_request_passes(self) -> None:
        self.assertValid(valid_request())

    def test_single_path_ok(self) -> None:
        req = valid_request()
        req["paths"] = ["only.py"]
        self.assertValid(req)

    def test_100_paths_ok(self) -> None:
        req = valid_request()
        req["paths"] = [f"f{i}.py" for i in range(100)]
        self.assertValid(req)

    # ----- missing required ----------

    def test_missing_request_id(self) -> None:
        req = valid_request(); del req["request_id"]
        self.assertRejects(req, "missing required field: request_id")

    def test_missing_branch(self) -> None:
        req = valid_request(); del req["branch"]
        self.assertRejects(req, "missing required field: branch")

    def test_missing_paths(self) -> None:
        req = valid_request(); del req["paths"]
        self.assertRejects(req, "missing required field: paths")

    def test_missing_message(self) -> None:
        req = valid_request(); del req["message"]
        self.assertRejects(req, "missing required field: message")

    # ----- additionalProperties ----------

    def test_extra_field_rejected(self) -> None:
        req = valid_request(); req["title"] = "no titles here"
        self.assertRejects(req, "unexpected field: title")

    # ----- request_id ----------

    def test_request_id_not_a_uuid(self) -> None:
        req = valid_request(); req["request_id"] = "not-a-uuid"
        self.assertRejects(req, "request_id")

    def test_request_id_wrong_version(self) -> None:
        # version digit must be 1-5 per the regex; 9 is rejected
        req = valid_request(); req["request_id"] = "11111111-2222-9333-8444-555555555555"
        self.assertRejects(req, "request_id")

    # ----- created_at ----------

    def test_created_at_not_utc(self) -> None:
        req = valid_request(); req["created_at"] = "2026-05-17T10:30:00+02:00"
        self.assertRejects(req, "created_at")

    def test_created_at_pre_2000(self) -> None:
        req = valid_request(); req["created_at"] = "1999-05-17T10:30:00Z"
        self.assertRejects(req, "created_at")

    # ----- repo_path ----------

    def test_repo_path_outside_root(self) -> None:
        req = valid_request(); req["repo_path"] = "/tmp/projects/foo"
        self.assertRejects(req, "repo_path")

    def test_repo_path_uppercase(self) -> None:
        req = valid_request(); req["repo_path"] = "/home/fieldwork/projects/FOO"
        self.assertRejects(req, "repo_path")

    def test_repo_path_trailing_slash(self) -> None:
        req = valid_request(); req["repo_path"] = "/home/fieldwork/projects/foo/"
        self.assertRejects(req, "repo_path")

    # ----- branch ----------

    def test_branch_wrong_prefix(self) -> None:
        req = valid_request(); req["branch"] = "claude/test-change"
        self.assertRejects(req, "branch")

    def test_branch_main(self) -> None:
        req = valid_request(); req["branch"] = "main"
        self.assertRejects(req, "branch")

    def test_branch_uppercase_segment(self) -> None:
        req = valid_request(); req["branch"] = "fieldwork/Test-Change"
        self.assertRejects(req, "branch")

    # ----- paths ----------

    def test_paths_empty_rejected(self) -> None:
        req = valid_request(); req["paths"] = []
        self.assertRejects(req, "paths")

    def test_paths_too_many(self) -> None:
        req = valid_request(); req["paths"] = [f"f{i}" for i in range(101)]
        self.assertRejects(req, "paths")

    def test_path_with_leading_slash_rejected(self) -> None:
        req = valid_request(); req["paths"] = ["/etc/passwd"]
        self.assertRejects(req, "paths")

    def test_path_with_newline_rejected(self) -> None:
        req = valid_request(); req["paths"] = ["a\nb.py"]
        self.assertRejects(req, "paths")

    def test_path_with_nul_rejected(self) -> None:
        req = valid_request(); req["paths"] = ["a\x00b.py"]
        self.assertRejects(req, "paths")

    def test_path_too_long(self) -> None:
        req = valid_request(); req["paths"] = ["a" * 257]
        self.assertRejects(req, "paths")

    def test_path_empty_string_rejected(self) -> None:
        req = valid_request(); req["paths"] = [""]
        self.assertRejects(req, "paths")

    # ----- message ----------

    def test_message_empty_rejected(self) -> None:
        req = valid_request(); req["message"] = ""
        self.assertRejects(req, "message")

    def test_message_too_long(self) -> None:
        req = valid_request(); req["message"] = "x" * 8193
        self.assertRejects(req, "message")


class DeliveryClientPathTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="fieldwork-delivery-client."))
        self.repo = self.tmp / "repo"
        self.repo.mkdir()
        self.git("init", "-q")
        (self.repo / ".fieldwork/local").mkdir(parents=True)
        (self.repo / ".claude/local").mkdir(parents=True)
        self.runtime = self.tmp / "runtime"
        self.runtime.mkdir()
        self.fake_bin = self.tmp / "bin"
        self.fake_bin.mkdir()
        realpath = self.fake_bin / "realpath"
        realpath.write_text(
            "#!/usr/bin/env bash\n"
            "if [ \"${1:-}\" = \"-e\" ]; then shift; fi\n"
            "python3 -c 'import os, sys; p=sys.argv[1]; sys.exit(1) if not os.path.exists(p) else print(os.path.realpath(p))' \"$1\"\n"
        )
        realpath.chmod(0o755)

    def tearDown(self) -> None:
        shutil.rmtree(self.tmp)

    def git(self, *args: str) -> None:
        subprocess.run(["git", *args], cwd=self.repo, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def run_client(self, script: Path, request_file: Path) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env["XDG_RUNTIME_DIR"] = str(self.runtime)
        env["FIELDWORK_BROKER_SOCKET"] = str(self.tmp / "missing-broker.sock")
        env["PATH"] = f"{self.fake_bin}:{env['PATH']}"
        return subprocess.run(
            [str(script), str(request_file)],
            cwd=self.repo,
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

    def write_prepare_request(self, directory: Path) -> Path:
        request_file = directory / "pr-prepare-request.json"
        request_file.write_text(json.dumps(valid_request()))
        return request_file

    def write_submit_request(self, directory: Path) -> Path:
        request_file = directory / "pr-request.json"
        request_file.write_text(json.dumps({
            "request_id": str(uuid.uuid4()),
            "created_at": "2026-05-17T10:30:00Z",
            "repo_path": "/home/fieldwork/projects/fieldwork-smoke",
            "branch": "fieldwork/test-change",
            "title": "Test change",
            "body": "Summary:\n- Test delivery client path validation.\n\nTests:\n- client path regression",
        }))
        return request_file

    def test_prepare_accepts_fieldwork_local_path_until_socket_lookup(self) -> None:
        result = self.run_client(PREPARE_CLIENT, self.write_prepare_request(self.repo / ".fieldwork/local"))
        self.assertEqual(result.returncode, 20)
        self.assertIn("runner socket not available", result.stderr)
        self.assertIn("fieldwork-pr-prepare.sock", result.stderr)
        self.assertNotIn("request must live under", result.stderr)

    def test_prepare_rejects_claude_local_path(self) -> None:
        result = self.run_client(PREPARE_CLIENT, self.write_prepare_request(self.repo / ".claude/local"))
        self.assertEqual(result.returncode, 20)
        self.assertIn("request must live under <repo>/.fieldwork/local/", result.stderr)
        self.assertNotIn("runner socket not available", result.stderr)

    def test_submit_accepts_fieldwork_local_path_until_broker_socket_lookup(self) -> None:
        result = self.run_client(SUBMIT_CLIENT, self.write_submit_request(self.repo / ".fieldwork/local"))
        self.assertEqual(result.returncode, 1)
        self.assertIn("broker socket missing", result.stderr)
        self.assertNotIn("request must live under", result.stderr)

    def test_submit_rejects_claude_local_path(self) -> None:
        result = self.run_client(SUBMIT_CLIENT, self.write_submit_request(self.repo / ".claude/local"))
        self.assertEqual(result.returncode, 1)
        self.assertIn("request must live under <repo>/.fieldwork/local/", result.stderr)
        self.assertNotIn("broker socket missing", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
