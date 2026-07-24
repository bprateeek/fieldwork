#!/usr/bin/env python3
"""Adversarial tests for the managed Fieldwork Bash exclusion policy."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
POLICY = ROOT / "lib/scripts/fieldwork-bash-policy"
REQUEST_ID = "00000000-0000-4000-8000-000000000001"
DENIAL = b"fieldwork-excluded-client-policy: denied unsafe excluded-client command"


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
    def test_exact_excluded_client_forms_are_allowed(self) -> None:
        commands = (
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
            "printf fieldwork-probe-upload": (
                "/usr/local/bin/fieldwork-pr-upload --status "
                f"{REQUEST_ID}"
            ),
            "printf fieldwork-probe-verify": (
                "/usr/local/bin/fieldwork-verify /nonexistent-fieldwork-probe"
            ),
            "printf fieldwork-probe-prepare": (
                "/usr/local/bin/fieldwork-pr-prepare not-a-uuid"
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
        plain = invoke("printf fieldwork-probe-plain", probe=True)
        self.assertEqual(plain.returncode, 0)
        self.assertEqual(plain.stdout, b"")
        denied = invoke("printf fieldwork-probe-policy", probe=True)
        self.assertEqual(denied.returncode, 2)
        self.assertIn(DENIAL, denied.stderr)

    def test_every_composed_or_wrapped_client_form_is_denied(self) -> None:
        upload = f"/usr/local/bin/fieldwork-pr-upload {REQUEST_ID}"
        commands = (
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
