#!/usr/bin/env python3
"""Adversarial tests for the managed Fieldwork Bash exclusion policy."""

from __future__ import annotations

import ast
import json
import os
from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
POLICY = ROOT / "lib/scripts/fieldwork-bash-policy"
LOCAL_PROBE = ROOT / "lib/local/control/fieldwork-local-probe"
REQUEST_ID = "00000000-0000-4000-8000-000000000001"
DENIAL = b"fieldwork-excluded-client-policy: denied unsafe excluded-client command"


def literal_assignment(path: Path, name: str) -> object:
    tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    for node in tree.body:
        if not isinstance(node, ast.Assign):
            continue
        if not any(isinstance(target, ast.Name) and target.id == name for target in node.targets):
            continue
        value = node.value
        if (
            isinstance(value, ast.Call)
            and isinstance(value.func, ast.Name)
            and value.func.id == "frozenset"
            and len(value.args) == 1
        ):
            value = value.args[0]
        return ast.literal_eval(value)
    raise AssertionError(f"missing literal assignment {name} in {path}")


def invoke(
    command: str, *, probe: bool = False, **tool_input: object
) -> subprocess.CompletedProcess[bytes]:
    value = {"command": command, **tool_input}
    environment = os.environ.copy()
    environment.pop("FIELDWORK_SESSION_PROBE", None)
    if probe:
        environment["FIELDWORK_SESSION_PROBE"] = "1"
    return subprocess.run(
        [str(POLICY)],
        input=json.dumps({"tool_name": "Bash", "tool_input": value}).encode(),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=environment,
        check=False,
    )


class BashPolicyTests(unittest.TestCase):
    def test_local_probe_covers_every_root_owned_marker(self) -> None:
        commands = set(literal_assignment(LOCAL_PROBE, "probe_commands"))
        rewrites = set(literal_assignment(POLICY, "PROBE_REWRITES"))
        denials = set(literal_assignment(POLICY, "PROBE_DENIALS"))
        plain = literal_assignment(POLICY, "PROBE_PLAIN")
        probe_source = LOCAL_PROBE.read_text(encoding="utf-8")
        self.assertEqual(commands, rewrites | denials | {plain})
        self.assertEqual(len(commands), 18)
        self.assertTrue(all(command.startswith("printf fieldwork-probe-") for command in commands))
        self.assertIn('"verify": "[fieldwork-verify] OK" in verify', probe_source)

    def test_exact_excluded_client_forms_are_allowed(self) -> None:
        commands = (
            (
                "/usr/local/bin/fieldwork-pr-build "
                ".fieldwork/local/pr-build-request.json"
            ),
            f"/usr/local/bin/fieldwork-pr-upload {REQUEST_ID}",
            f"/usr/local/bin/fieldwork-pr-upload --status {REQUEST_ID}",
            f"/usr/local/bin/fieldwork-pr-prepare {REQUEST_ID}",
            "/usr/local/bin/fieldwork-pr-prepare not-a-uuid",
            '/usr/local/bin/fieldwork-verify "$PWD"',
            "/usr/local/bin/fieldwork-verify /nonexistent-fieldwork-probe",
        )
        for command in commands:
            with self.subTest(command=command):
                result = invoke(command)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, b"")
                self.assertEqual(result.stderr, b"")

    def test_ordinary_bash_is_unchanged(self) -> None:
        for command in (
            "git status --short",
            "npm test && echo done",
            "echo hello > result.txt",
            "printf fieldwork-probe-upload",
            "FIELDWORK_SESSION_PROBE=1 printf fieldwork-probe-upload",
        ):
            with self.subTest(command=command):
                result = invoke(command)
                self.assertEqual(result.returncode, 0)
                self.assertEqual(result.stdout, b"")

    def test_root_probe_mode_rewrites_exact_markers_and_denies_policy_marker(self) -> None:
        expected = {
            "printf fieldwork-probe-build": (
                "/usr/local/bin/fieldwork-pr-build "
                ".fieldwork/local/pr-build-request.json"
            ),
            "printf fieldwork-probe-upload": (
                "/usr/local/bin/fieldwork-pr-upload --status "
                f"{REQUEST_ID}"
            ),
            "printf fieldwork-probe-verify": (
                "/usr/local/bin/fieldwork-verify \"$PWD\""
            ),
            "printf fieldwork-probe-prepare": (
                "/usr/local/bin/fieldwork-pr-prepare not-a-uuid"
            ),
            "printf fieldwork-probe-network": (
                "/usr/bin/python3 -c 'import socket; "
                "socket.create_connection((\"127.0.0.1\",8377),2)' "
                "&& echo FIELDWORK_NETWORK_ESCAPE"
            ),
            "printf fieldwork-probe-dns": (
                "/usr/bin/python3 -c 'import socket; "
                "socket.getaddrinfo(\"example.com\",443)' && echo FIELDWORK_DNS_ESCAPE"
            ),
            "printf fieldwork-probe-public": (
                "/usr/bin/python3 -c 'import socket; "
                "socket.create_connection((\"1.1.1.1\",443),2)' "
                "&& echo FIELDWORK_PUBLIC_ESCAPE"
            ),
            "printf fieldwork-probe-bind": (
                "/usr/bin/python3 -c 'import socket; s=socket.socket(); "
                "s.bind((\"127.0.0.1\",0))' && echo FIELDWORK_BIND_ESCAPE"
            ),
            "printf fieldwork-probe-bearer": (
                "/bin/cat \"$HOME/.fieldwork/http-auth\" && echo FIELDWORK_BEARER_ESCAPE"
            ),
            "printf fieldwork-probe-docker": (
                "/usr/bin/env -i PATH=/usr/local/bin:/usr/bin:/bin docker version "
                "&& echo FIELDWORK_DOCKER_ESCAPE"
            ),
            "printf fieldwork-probe-systemd": (
                "systemd-run --user --wait /bin/echo FIELDWORK_SYSTEMD_ESCAPE"
            ),
            "printf fieldwork-probe-raw-http": (
                "/usr/bin/python3 -c 'import json,pathlib,socket; "
                "t=(pathlib.Path.home()/\".fieldwork/http-auth\").read_text().strip(); "
                "b=json.dumps({\"request_id\":\"00000000-0000-4000-8000-000000000001\"},"
                "separators=(\",\",\":\")).encode(); "
                "s=socket.create_connection((\"127.0.0.1\",8377),2); "
                "s.sendall((\"POST /pr-status HTTP/1.1\\r\\nHost: localhost\\r\\n"
                "X-Fieldwork-Local-Auth: \"+t+\"\\r\\nContent-Type: application/json\\r\\n"
                "Content-Length: \"+str(len(b))+\"\\r\\nConnection: close\\r\\n\\r\\n\").encode()+b)' "
                "&& echo FIELDWORK_RAW_HTTP_ESCAPE"
            ),
            "printf fieldwork-probe-oauth-env": (
                "/usr/bin/env | /usr/bin/grep -q '^CLAUDE_CODE_OAUTH_TOKEN=' "
                "&& echo FIELDWORK_OAUTH_ENV_ESCAPE"
            ),
            "printf fieldwork-probe-proc-env": (
                "/usr/bin/python3 -c 'import pathlib; "
                "print(pathlib.Path(\"/proc/1/environ\").read_bytes())' "
                "| /usr/bin/grep -q CLAUDE_CODE_OAUTH_TOKEN && echo FIELDWORK_PROC_ENV_ESCAPE"
            ),
        }
        for command, replacement in expected.items():
            with self.subTest(command=command):
                result = invoke(command, probe=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                output = json.loads(result.stdout)
                decision = output["hookSpecificOutput"]
                self.assertEqual(decision["hookEventName"], "PreToolUse")
                self.assertEqual(decision["permissionDecision"], "allow")
                self.assertEqual(
                    decision["updatedInput"], {"command": replacement}
                )
                syntax = subprocess.run(
                    ["bash", "-n", "-c", replacement],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    check=False,
                )
                self.assertEqual(syntax.returncode, 0, syntax.stderr)
        plain = invoke("printf fieldwork-probe-plain", probe=True)
        self.assertEqual(plain.returncode, 0)
        self.assertEqual(plain.stdout, b"")
        for command in (
            "printf fieldwork-probe-policy",
            "printf fieldwork-probe-composition",
            "printf fieldwork-probe-env-wrapper",
        ):
            with self.subTest(command=command):
                denied = invoke(command, probe=True)
                self.assertEqual(denied.returncode, 2)
                self.assertIn(DENIAL, denied.stderr)

    def test_every_composed_or_wrapped_client_form_is_denied(self) -> None:
        upload = f"/usr/local/bin/fieldwork-pr-upload {REQUEST_ID}"
        build = (
            "/usr/local/bin/fieldwork-pr-build "
            ".fieldwork/local/pr-build-request.json"
        )
        commands = (
            f"{build} ; echo escaped",
            "/usr/local/bin/fieldwork-pr-build request.json",
            "/usr/local/bin/fieldwork-pr-build .fieldwork/local/../request.json",
            f"{upload} ; echo escaped",
            f"{upload} && echo escaped",
            f"{upload} || echo escaped",
            f"{upload} | tee result",
            f"{upload} &",
            f"{upload}\necho escaped",
            f"{upload} > result",
            f"{upload} $(echo escaped)",
            f"VALUE=1 {upload}",
            f"timeout 30 {upload}",
            f"command {upload}",
            f"echo before; {upload}",
            f'echo "{upload}"',
            f"{upload} # comment",
            "/usr/local/bin/fieldwork-pr-upload --status not-a-uuid",
            "/usr/local/bin/fieldwork-verify $PWD",
            "/usr/local/bin/fieldwork-verify /tmp/repo",
            "/usr/local/bin/fieldwork-pr-prepare AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA",
        )
        for command in commands:
            with self.subTest(command=command):
                result = invoke(command)
                self.assertEqual(result.returncode, 2)
                self.assertIn(DENIAL, result.stderr)

    def test_background_and_malformed_hook_inputs_fail_closed(self) -> None:
        command = f"/usr/local/bin/fieldwork-pr-upload {REQUEST_ID}"
        self.assertEqual(invoke(command, run_in_background=True).returncode, 2)
        malformed = (
            b"",
            b"{",
            json.dumps([]).encode(),
            json.dumps({"tool_name": "Read", "tool_input": {"command": command}}).encode(),
            json.dumps({"tool_name": "Bash", "tool_input": {}}).encode(),
        )
        for raw in malformed:
            with self.subTest(raw=raw):
                result = subprocess.run(
                    [str(POLICY)],
                    input=raw,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    check=False,
                )
                self.assertEqual(result.returncode, 2)
                self.assertIn(DENIAL, result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
