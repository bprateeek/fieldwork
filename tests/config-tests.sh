#!/usr/bin/env bash
# Unit tests for the control-plane config loader (lib/cli/config.sh).
# Sources the loader directly so it runs without the bin/fieldwork entrypoint.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Start from a clean slate so inherited env never masks a case's intent.
unset FIELDWORK_CONFIG FIELDWORK_PROFILE FIELDWORK_FORGE \
  FIELDWORK_SSH_HOST FIELDWORK_REMOTE_USER FIELDWORK_PROJECTS_DIR \
  FIELDWORK_DEFAULT_BRANCH FIELDWORK_NOTIFY_PROVIDER 2>/dev/null || true

# shellcheck source=lib/cli/config.sh
source "$ROOT/lib/cli/config.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/fieldwork-config-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

cat > "$work/flat.toml" <<'EOF'
ssh_host = "vps-flat"
remote_user = "userflat"
projects_dir = "/p/flat"
default_branch = "trunk"
notify_provider = "telegram"
EOF

cat > "$work/profiles.toml" <<'EOF'
ssh_host = "vps-flat"
remote_user = "userflat"
default_profile = "work"

[profile.work]
ssh_host = "vps-work"
projects_dir = "/p/work"

[profile.other]
ssh_host = "vps-other"
EOF

cat > "$work/forge.toml" <<'EOF'
forge = "gitlab"
EOF

fail=0
check() {
  local name="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    printf '  ok   %s\n' "$name"
  else
    printf '  FAIL %s: got [%s] want [%s]\n' "$name" "$got" "$want" >&2
    fail=1
  fi
}

# Resolves config in the current (sub)shell and prints the fields, pipe-joined:
#   profile|forge|ssh_host|remote_user|projects_dir|default_branch|notify_provider
resolve() {
  fieldwork_load_config
  printf '%s|%s|%s|%s|%s|%s|%s\n' \
    "$FIELDWORK_PROFILE" "$FIELDWORK_FORGE" "$FIELDWORK_SSH_HOST" \
    "$FIELDWORK_REMOTE_USER" "$FIELDWORK_PROJECTS_DIR" \
    "$FIELDWORK_DEFAULT_BRANCH" "$FIELDWORK_NOTIFY_PROVIDER"
}

echo "[config] a. flat config resolves all flat keys"
out="$(FIELDWORK_CONFIG="$work/flat.toml" resolve)"
check "flat" "$out" "default|github|vps-flat|userflat|/p/flat|trunk|telegram"

echo "[config] b. env overrides the file"
out="$(FIELDWORK_CONFIG="$work/flat.toml" FIELDWORK_SSH_HOST="envhost" resolve)"
check "env-wins" "$out" "default|github|envhost|userflat|/p/flat|trunk|telegram"

echo "[config] c. FIELDWORK_PROFILE selects a profile over flat keys"
# work profile overrides ssh_host + projects_dir; remote_user falls back to flat;
# default_branch + notify_provider fall back to hardcoded defaults.
out="$(FIELDWORK_CONFIG="$work/profiles.toml" FIELDWORK_PROFILE="work" resolve)"
check "profile-env" "$out" "work|github|vps-work|userflat|/p/work|main|ntfy"

echo "[config] d. default_profile key selects; env beats the key"
out="$(FIELDWORK_CONFIG="$work/profiles.toml" resolve)"
check "default_profile-key" "$out" "work|github|vps-work|userflat|/p/work|main|ntfy"
out="$(FIELDWORK_CONFIG="$work/profiles.toml" FIELDWORK_PROFILE="other" resolve)"
check "env-beats-key" "$out" "other|github|vps-other|userflat|/home/fieldwork/projects|main|ntfy"

echo "[config] e. missing selected profile warns and falls back to flat"
err="$work/e.err"
out="$(FIELDWORK_CONFIG="$work/flat.toml" FIELDWORK_PROFILE="ghost" resolve 2>"$err")"
check "missing-profile-fallback" "$out" "ghost|github|vps-flat|userflat|/p/flat|trunk|telegram"
if grep -q 'profile "ghost" not found' "$err"; then
  echo "  ok   missing-profile-warns"
else
  echo "  FAIL missing-profile-warns: no warning on stderr" >&2; fail=1
fi

echo "[config] f. forge defaults to github; reads forge from file when set"
out="$(FIELDWORK_CONFIG="$work/forge.toml" resolve)"
check "forge-from-file" "$out" "default|gitlab|fieldwork-vps|fieldwork|/home/fieldwork/projects|main|ntfy"

echo "[config] g. no config file -> hardcoded defaults"
out="$(FIELDWORK_CONFIG="$work/does-not-exist.toml" resolve)"
check "defaults" "$out" "default|github|fieldwork-vps|fieldwork|/home/fieldwork/projects|main|ntfy"

if [ "$fail" = "0" ]; then
  echo "[config] ok"
else
  echo "[config] FAILED" >&2
  exit 1
fi
