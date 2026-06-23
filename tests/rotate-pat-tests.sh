#!/usr/bin/env bash
# Unit tests for the PAT validation in lib/broker/rotate-pat.
# Sources rotate-pat in source-only mode (so the root check / token read are
# skipped) and exercises fieldwork_validate_pat with a stubbed `curl`. No
# network, no root.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# A stub `curl` keyed by URL. Liveness uses `-o /dev/null -w %{http_code}` so it
# prints only the code; the repo probe uses `-w \n%{http_code}` so it prints the
# body, a newline, then the code. *_FAIL=1 makes curl exit non-zero (network).
CURL_CALLED=0
curl() {
  CURL_CALLED=1
  case "$*" in
    *"/rate_limit"*)
      [ "${LIVENESS_FAIL:-0}" = "1" ] && return 1
      printf '%s' "${LIVENESS_CODE:-200}"
      return 0 ;;
    *"/repos/"*)
      [ "${REPO_FAIL:-0}" = "1" ] && return 1
      printf '%s\n%s' "${REPO_BODY:-}" "${REPO_CODE:-200}"
      return 0 ;;
  esac
  return 0
}

# shellcheck source=lib/broker/rotate-pat
FIELDWORK_ROTATE_PAT_SOURCE_ONLY=1 source "$ROOT/lib/broker/rotate-pat"
# rotate-pat runs `set -euo pipefail` at source time; relax it so a non-zero
# validation return doesn't abort the test runner.
set +e

fail=0
# Sets the given KEY=VAL scenario vars, runs fieldwork_validate_pat (already
# defined from the top-level source), captures the return code, then unsets them.
expect_rc() {
  local name="$1" want="$2"; shift 2
  local kv got
  for kv in "$@"; do export "${kv?}"; done
  fieldwork_validate_pat "github_pat_dummy"
  got=$?
  for kv in "$@"; do unset "${kv%%=*}"; done
  if [ "$got" = "$want" ]; then
    printf '  ok   %s (rc=%s)\n' "$name" "$got"
  else
    printf '  FAIL %s: got rc=%s want %s\n' "$name" "$got" "$want" >&2
    fail=1
  fi
}

echo "[rotate-pat] PAT validation"

expect_rc "liveness-200-no-repo" 0 LIVENESS_CODE=200
expect_rc "liveness-401-rejected" 1 LIVENESS_CODE=401
expect_rc "liveness-403-rejected" 1 LIVENESS_CODE=403
expect_rc "liveness-network-warn" 2 LIVENESS_FAIL=1
expect_rc "liveness-5xx-warn" 2 LIVENESS_CODE=500

expect_rc "repo-200-push-true" 0 \
  LIVENESS_CODE=200 FIELDWORK_PAT_PROBE_REPO=o/r REPO_CODE=200 'REPO_BODY={"permissions":{"push":true}}'
expect_rc "repo-200-push-false" 1 \
  LIVENESS_CODE=200 FIELDWORK_PAT_PROBE_REPO=o/r REPO_CODE=200 'REPO_BODY={"permissions":{"push":false}}'
expect_rc "repo-404-rejected" 1 \
  LIVENESS_CODE=200 FIELDWORK_PAT_PROBE_REPO=o/r REPO_CODE=404 'REPO_BODY={}'
expect_rc "repo-403-rejected" 1 \
  LIVENESS_CODE=200 FIELDWORK_PAT_PROBE_REPO=o/r REPO_CODE=403 'REPO_BODY={}'
expect_rc "repo-network-warn" 2 \
  LIVENESS_CODE=200 FIELDWORK_PAT_PROBE_REPO=o/r REPO_FAIL=1

# Non-github forge is skipped entirely (no curl call).
CURL_CALLED=0
FIELDWORK_FORGE=gitlab fieldwork_validate_pat "glpat-xxx"; rc=$?
if [ "$rc" = "0" ] && [ "$CURL_CALLED" = "0" ]; then
  echo "  ok   non-github-forge-skips (rc=0, no curl)"
else
  echo "  FAIL non-github-forge-skips: rc=$rc curl_called=$CURL_CALLED" >&2; fail=1
fi

echo "[rotate-pat] GitHub App validation"
if fieldwork_validate_github_app_ids 123 456; then
  echo "  ok   app-ids-numeric"
else
  echo "  FAIL app-ids-numeric" >&2; fail=1
fi
if fieldwork_validate_github_app_ids app 456 >/dev/null 2>&1; then
  echo "  FAIL app-id-rejects-nonnumeric" >&2; fail=1
else
  echo "  ok   app-id-rejects-nonnumeric"
fi
if fieldwork_validate_github_app_ids 123 "" >/dev/null 2>&1; then
  echo "  FAIL app-installation-rejects-empty" >&2; fail=1
else
  echo "  ok   app-installation-rejects-empty"
fi

if [ "$fail" = "0" ]; then
  echo "[rotate-pat] ok"
else
  echo "[rotate-pat] FAILED" >&2
  exit 1
fi
