#!/usr/bin/env bash
# Unit tests for the PAT validation in lib/broker/rotate-pat.
# Sources rotate-pat in source-only mode (so the root check / token read are
# skipped) and exercises fieldwork_validate_pat with a stubbed `python3`. No
# network, no root.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/fieldwork-rotate-pat-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
TEST_PYTHON_LOG="$work/python.log"

# A stub `python3` keyed by URL. rotate-pat passes the token on stdin to a
# urllib helper, never in argv.
PYTHON_CALLED=0
PYTHON_ARGV_LOG=""
python3() {
  PYTHON_CALLED=1
  PYTHON_ARGV_LOG="$*"
  printf '%s\n' "$*" >>"$TEST_PYTHON_LOG"
  local token
  token="$(cat)"
  case "$*" in
    *"/rate_limit"*)
      case "$PYTHON_ARGV_LOG" in *"$token"*) return 9 ;; esac
      [ "${LIVENESS_FAIL:-0}" = "1" ] && return 1
      printf '\n%s\n' "${LIVENESS_CODE:-200}"
      return 0 ;;
    *"/repos/"*)
      case "$PYTHON_ARGV_LOG" in *"$token"*) return 9 ;; esac
      [ "${REPO_FAIL:-0}" = "1" ] && return 1
      printf '%s\n%s' "${REPO_BODY:-}" "${REPO_CODE:-200}"
      return 0 ;;
    *"/user"*)
      case "$PYTHON_ARGV_LOG" in *"$token"*) return 9 ;; esac
      [ "${GITLAB_FAIL:-0}" = "1" ] && return 1
      printf '\n%s\n' "${GITLAB_CODE:-200}"
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

PYTHON_CALLED=0
>"$TEST_PYTHON_LOG"
FIELDWORK_FORGE=gitlab
GITLAB_CODE=200
fieldwork_validate_pat "not-prefixed"; rc=$?
if [ "$rc" = "0" ] && [ -s "$TEST_PYTHON_LOG" ] && ! grep -Fq "not-prefixed" "$TEST_PYTHON_LOG"; then
  echo "  ok   gitlab-liveness-200-no-prefix"
else
  echo "  FAIL gitlab-liveness-200-no-prefix: rc=$rc python_log=$(cat "$TEST_PYTHON_LOG" 2>/dev/null)" >&2; fail=1
fi
GITLAB_CODE=403
fieldwork_validate_pat "not-prefixed"; rc=$?
[ "$rc" = "1" ] && echo "  ok   gitlab-liveness-403-rejected" || { echo "  FAIL gitlab-liveness-403-rejected: rc=$rc" >&2; fail=1; }
unset FIELDWORK_FORGE GITLAB_CODE

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
