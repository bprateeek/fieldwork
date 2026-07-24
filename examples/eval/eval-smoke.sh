#!/usr/bin/env bash
set -euo pipefail

# Hermetic protocol-v2 evaluation: exercise real Git pack quarantine and the
# durable approval lifecycle without a forge credential or network access.
cd /workspace
export PYTHONDONTWRITEBYTECODE=1

python3 - <<'PY'
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest

root = Path("/workspace")
path = root / "tests/broker-validation-tests.py"
spec = importlib.util.spec_from_file_location("fieldwork_eval_broker_tests", path)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)

# Exercise the scanner subprocess itself in addition to the quarantine tests,
# which mock only forge transport. The eval image installs a deterministic
# gitleaks-compatible scanner at the production path.
with tempfile.TemporaryDirectory(prefix="fieldwork-eval-scan-") as scan_name:
    scan_path = Path(scan_name)
    (scan_path / "finding.txt").write_text("SECRET_SHAPED_TOKEN\n")
    try:
        module.server.scan_directory(scan_path, module.server.Deadline.start())
    except module.server.RequestError as exc:
        if exc.code != "secret_detected":
            raise
    else:
        raise RuntimeError("eval scanner did not fail closed on its deterministic finding")

names = [
    "test_quarantine_accepts_normal_and_full_non_thin_packs",
    "test_quarantine_rejects_thin_pack",
    "test_quarantine_rejects_stuffed_pack",
    "test_quarantine_enforces_policy_delta_cap",
    "test_require_gate_persists_without_forge_write",
    "test_auto_is_durable_before_processing",
    "test_deny_is_terminal_and_replay_returns_tombstone",
    "test_record_mac_and_pack_digest_fail_closed",
    "test_fault_boundaries_resume_without_duplicate_forge_writes",
    "test_reconciliation_is_idempotent_when_branch_and_pr_exist",
    "test_ssrf_rejects_if_any_dns_answer_is_private",
    "test_rest_redirects_and_cross_endpoint_urls_are_refused",
]
suite = unittest.TestSuite(module.BrokerV2Tests(name) for name in names)
transcript = io.StringIO()
result = unittest.TextTestRunner(stream=transcript, verbosity=2).run(suite)
if not result.wasSuccessful():
    print(transcript.getvalue(), file=sys.stderr)
    raise SystemExit(1)
print(json.dumps({
    "ok": True,
    "mode": "eval",
    "protocol": 2,
    "checkout_blind": True,
    "scanner": "fail_closed",
    "tests": names,
}, sort_keys=True))
PY
