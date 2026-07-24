#!/usr/bin/env bash
# Closed notification producer used by root-installed lifecycle hooks.
# Hook payload, branch names, filenames, commit messages, and stderr are read
# and discarded; only the typed event contract can reach Telegram.
set -euo pipefail

event="${1:-error}"
slug="${2:-unknown}"
request_id="${3:-}"
error_code="${4:-}"
case "$event" in queued|approved|denied|pushed|pr_created|error) ;; *) exit 0 ;; esac
case "$slug" in ""|*[!a-z0-9-]*|-*) exit 0 ;; esac
[ "${#slug}" -le 31 ] || exit 0
case "$request_id" in
  ????????-????-????-????-????????????) ;;
  *) exit 0 ;;
esac
case "$error_code" in ""|*[!a-z0-9_]*) error_code="internal" ;; esac

# Consume hook input without retaining or rendering it.
/bin/cat >/dev/null 2>&1 || true
drop="/var/lib/fieldwork-pr-broker/notifications"
[ -d "$drop" ] && [ -w "$drop" ] || exit 0
nonce="$(/usr/bin/python3 -I -c 'import secrets; print(secrets.token_hex(16))')"
tmp="$drop/.tmp-$nonce"
out="$drop/$nonce.json"
FW_EVENT="$event" FW_SLUG="$slug" FW_REQUEST_ID="$request_id" FW_ERROR_CODE="$error_code" \
/usr/bin/python3 -I - "$tmp" <<'PY'
import json, os, re, sys
payload = {
    "schema_version": 1,
    "event": os.environ["FW_EVENT"],
    "request_id": os.environ["FW_REQUEST_ID"],
    "slug": os.environ["FW_SLUG"],
}
if not re.fullmatch(
    r"[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}",
    payload["request_id"],
):
    raise SystemExit(0)
if payload["event"] == "error":
    payload["error_code"] = os.environ.get("FW_ERROR_CODE") or "internal"
with open(sys.argv[1], "x", encoding="utf-8") as handle:
    json.dump(payload, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
PY
[ -f "$tmp" ] || exit 0
chmod 660 "$tmp"
mv "$tmp" "$out"
