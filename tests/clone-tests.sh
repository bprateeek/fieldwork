#!/usr/bin/env bash
# Hermetic regression tests for repo-scoped deploy-key SSH aliases.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/fieldwork-clone-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/.ssh"
cat >"$work/.ssh/config" <<'EOF'
Host github-fieldwork-smoke
  HostName github.com
EOF

HOME="$work" "$ROOT/lib/scripts/fieldwork-clone" \
  --prepare-deploy-key bprateeek/fieldwork >/dev/null

test "$(grep -Fxc 'Host github-fieldwork' "$work/.ssh/config")" -eq 1
test "$(grep -Fxc 'Host github-fieldwork-smoke' "$work/.ssh/config")" -eq 1
grep -Fqx '  IdentityFile '"$work"'/.ssh/id_ed25519_fieldwork' \
  "$work/.ssh/config"

echo "[clone] exact SSH alias matching: ok"
