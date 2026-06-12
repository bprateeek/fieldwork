#!/usr/bin/env bash
# Unit tests for the managed ~/.ssh/config writer (lib/cli/ssh-config.sh) plus a
# PAT-isolation guard. Sources the libs directly with an isolated HOME so the
# writer only ever touches the temp dir.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export NO_COLOR=1
export FIELDWORK_SSH_HOST="fieldwork-vps"
export FIELDWORK_REMOTE_USER="fieldwork"
# shellcheck source=lib/cli/messaging.sh
source "$ROOT/lib/cli/messaging.sh"
# shellcheck source=lib/cli/ssh-config.sh
source "$ROOT/lib/cli/ssh-config.sh"

fail=0
check() {
  local name="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then printf '  ok   %s\n' "$name"
  else printf '  FAIL %s: got [%s] want [%s]\n' "$name" "$got" "$want" >&2; fail=1; fi
}
contains() {
  local name="$1" file="$2" needle="$3"
  if grep -qF "$needle" "$file"; then printf '  ok   %s\n' "$name"
  else printf '  FAIL %s: %s missing [%s]\n' "$name" "$file" "$needle" >&2; fail=1; fi
}
file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fieldwork-sshcfg-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fresh_home() {
  rm -rf "$WORK/h"
  mkdir -p "$WORK/h/.ssh"
  chmod 700 "$WORK/h/.ssh"
  export HOME="$WORK/h"
}
cfg() { printf '%s/.ssh/config\n' "$HOME"; }
write_rc() {
  # write_rc <hostname> [extra] -> sets RC
  RC=0
  ssh_config_write_managed_block "$FIELDWORK_SSH_HOST" "$1" "~/.ssh/id_ed25519" "${2:-}" || RC=$?
}

# --- append into a fresh config (mode 0600) -----------------------------------
fresh_home
write_rc 203.0.113.5
check "append rc" "$RC" "0"
contains "append begin" "$(cfg)" "# BEGIN FIELDWORK SSH CONFIG: fieldwork-vps"
contains "append host"  "$(cfg)" "HostName 203.0.113.5"
check "append mode 0600" "$(file_mode "$(cfg)")" "600"
check "append one block" "$(ssh_config_managed_block_count "$FIELDWORK_SSH_HOST")" "1"

# --- refresh a stale managed block in place (backup made, still one block) -----
write_rc 198.51.100.9
check "refresh rc" "$RC" "0"
contains "refresh new ip" "$(cfg)" "HostName 198.51.100.9"
check "refresh no stale ip" "$(grep -c '203.0.113.5' "$(cfg)" || true)" "0"
check "refresh still one block" "$(ssh_config_managed_block_count "$FIELDWORK_SSH_HOST")" "1"
check "refresh made a backup" "$(ls "$HOME/.ssh/"config.fieldwork.*.bak >/dev/null 2>&1 && echo yes || echo no)" "yes"

# --- identical rewrite is a no-op (no extra backup) ---------------------------
backups_before="$(ls -1 "$HOME/.ssh/"config.fieldwork.*.bak 2>/dev/null | wc -l | tr -d ' ')"
write_rc 198.51.100.9
check "identical rc" "$RC" "0"
backups_after="$(ls -1 "$HOME/.ssh/"config.fieldwork.*.bak 2>/dev/null | wc -l | tr -d ' ')"
check "identical no new backup" "$backups_after" "$backups_before"

# --- hand-authored Host block: refuse, leave file byte-identical --------------
fresh_home
{
  printf 'Host fieldwork-vps\n  HostName 10.0.0.1\n  User someone\n'
  printf 'Host other\n  HostName 10.0.0.2\n'
} > "$(cfg)"
before="$(cksum "$(cfg)")"
write_rc 203.0.113.5
check "hand-authored rc" "$RC" "11"
check "hand-authored byte-identical" "$(cksum "$(cfg)")" "$before"

# --- duplicate managed blocks: refuse -----------------------------------------
fresh_home
for ip in 1.1.1.1 2.2.2.2; do
  {
    echo "# BEGIN FIELDWORK SSH CONFIG: fieldwork-vps"
    printf 'Host fieldwork-vps\n  HostName %s\n' "$ip"
    echo "# END FIELDWORK SSH CONFIG: fieldwork-vps"
  } >> "$(cfg)"
done
before="$(cksum "$(cfg)")"
write_rc 203.0.113.5
check "duplicate rc" "$RC" "12"
check "duplicate byte-identical" "$(cksum "$(cfg)")" "$before"

# --- symlinked config: refuse, do not follow ----------------------------------
fresh_home
real="$WORK/real-config"
printf 'Host keep\n  HostName 9.9.9.9\n' > "$real"
ln -s "$real" "$(cfg)"
before="$(cksum "$real")"
write_rc 203.0.113.5
check "symlink rc" "$RC" "10"
check "symlink target untouched" "$(cksum "$real")" "$before"

# --- PAT-isolation guard (code paths only; docs may mention the var) ----------
if grep -rIn "FIELDWORK_BROKER_PAT" "$ROOT/bin/fieldwork" "$ROOT/lib" >/dev/null 2>&1; then
  printf '  FAIL pat-isolation: FIELDWORK_BROKER_PAT appears in code\n' >&2; fail=1
else
  printf '  ok   pat-isolation: no FIELDWORK_BROKER_PAT in code\n'
fi
if grep -q 'ssh -t' "$ROOT/lib/cli/setup.sh"; then
  printf '  ok   pat-isolation: store_broker_pat still uses ssh -t\n'
else
  printf '  FAIL pat-isolation: setup.sh no longer uses ssh -t for the PAT\n' >&2; fail=1
fi

exit "$fail"
