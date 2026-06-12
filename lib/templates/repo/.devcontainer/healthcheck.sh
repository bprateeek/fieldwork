#!/usr/bin/env bash
# /etc/devcontainer/healthcheck.sh, runs at container start; copied here as the
# template. The Dockerfile installs this to /etc/devcontainer/ with chmod 755.
#
# Fails (exit 1) if any hardening invariant is loose. The container won't come
# up until the dockerfile is fixed.
set -euo pipefail

fail() { echo "[healthcheck] FAIL: $*" >&2; exit 1; }
ok()   { echo "[healthcheck] ok: $*"; }

# 1. Running as non-root.
[ "$(id -u)" -ne 0 ] || fail "running as root (must be uid 1000 vscode)"
ok "non-root: $(id -un) uid=$(id -u)"

# 2. No docker socket present.
[ ! -S /var/run/docker.sock ] || fail "/var/run/docker.sock is mounted"
ok "no docker socket"

# 3. No SSH agent forwarded.
[ -z "${SSH_AUTH_SOCK:-}" ] || fail "SSH_AUTH_SOCK is set ($SSH_AUTH_SOCK)"
ok "no SSH agent forward"

# 4. Host home not mounted (heuristic: /home/<user>/.aws or /home/<user>/.ssh present).
for path in /home/vscode/.aws /home/vscode/.ssh /home/vscode/.config/gh /home/vscode/.npmrc /home/vscode/.gnupg; do
  [ ! -e "$path" ] || fail "host secret path leaked into container: $path"
done
ok "no host home leak"

# 5. CapEff minimal: bit pattern check via /proc/self/status.
capeff="$(grep '^CapEff:' /proc/self/status | awk '{print $2}')"
# 0000000000000000 means full drop. Anything else means caps survived.
[ "$capeff" = "0000000000000000" ] || fail "CapEff=$capeff (expected 0000000000000000. runArgs missing --cap-drop=ALL?)"
ok "capeff=0 (all caps dropped)"

# 6. No-new-privs in effect.
nnp="$(grep '^NoNewPrivs:' /proc/self/status | awk '{print $2}')"
[ "$nnp" = "1" ] || fail "NoNewPrivs=$nnp (expected 1. runArgs missing --security-opt=no-new-privileges?)"
ok "NoNewPrivs=1"

echo "[healthcheck] all invariants OK"
