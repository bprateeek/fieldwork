#!/usr/bin/env bash
set -euo pipefail

initialize_broker() {
  for spec in \
    /data/token:0700:10001:10001 \
    /data/policy:0750:10001:10001 \
    /data/policy-ca:0700:10001:10001 \
    /data/keys:0700:10001:10001 \
    /data/state:0700:10001:10001 \
    /data/pending-meta:2750:10001:10002 \
    /data/pending-sidecar:2770:10001:10002 \
    /data/pending-pack:0700:10001:10001 \
    /data/auth:0700:10001:10001 \
    /data/approve:2770:10001:10002 \
    /data/notifications:2770:10001:10002; do
    path="${spec%%:*}"; rest="${spec#*:}"; mode="${rest%%:*}"; rest="${rest#*:}"; owner="${rest%%:*}"; group="${rest##*:}"
    /usr/bin/install -d -m "$mode" -o "$owner" -g "$group" "$path"
  done
  if [ -L /data/keys/pending-mac.key ] \
    || { [ -e /data/keys/pending-mac.key ] && ! [ -f /data/keys/pending-mac.key ]; }; then
    echo "unsafe pending MAC-key path" >&2
    exit 1
  fi
  if [ ! -e /data/keys/pending-mac.key ]; then
    umask 077
    key_temp="$(mktemp /data/keys/.pending-mac.XXXXXX)"
    /usr/bin/openssl rand 64 >"$key_temp"
    chown 10001:10001 "$key_temp"; chmod 0600 "$key_temp"
    mv "$key_temp" /data/keys/pending-mac.key
  fi
  if [ -L /data/auth/http-auth ] \
    || { [ -e /data/auth/http-auth ] && ! [ -f /data/auth/http-auth ]; }; then
    echo "unsafe local bearer path" >&2
    exit 1
  fi
  if [ ! -e /data/auth/http-auth ]; then
    umask 077
    auth_temp="$(mktemp /data/auth/.http-auth.XXXXXX)"
    /usr/bin/openssl rand -hex 32 >"$auth_temp"
    chown 10001:10001 "$auth_temp"; chmod 0600 "$auth_temp"
    mv "$auth_temp" /data/auth/http-auth
  fi
  [ "$(wc -c </data/keys/pending-mac.key)" -ge 32 ] || { echo "pending MAC key is too short" >&2; exit 1; }
  [ -s /data/auth/http-auth ] || { echo "local bearer is empty" >&2; exit 1; }
  chown 10001:10001 /data/keys/pending-mac.key /data/auth/http-auth
  chmod 0600 /data/keys/pending-mac.key /data/auth/http-auth
}

case "${1:-broker}" in
  broker)
    initialize_broker
    exec /usr/bin/setpriv --reuid=10001 --regid=10001 --groups=10002 \
      /usr/local/bin/python3 -I /usr/local/lib/fieldwork-pr-broker/server.py
    ;;
  bot)
    for required in /data/telegram/config.toml /data/telegram/secret; do
      [ -s "$required" ] || { echo "missing Telegram configuration: $required" >&2; exit 1; }
    done
    /usr/bin/install -d -m 0700 -o 10002 -g 10002 /data/bot-state
    exec /usr/bin/setpriv --reuid=10002 --regid=10002 --clear-groups /usr/local/bin/fieldwork-bot
    ;;
  read-http-auth)
    [ "$(id -u)" -eq 0 ] || exit 1
    /bin/cat /data/auth/http-auth
    ;;
  rotate-token)
    [ "$(id -u)" -eq 0 ] || exit 1
    exec /usr/local/bin/fieldwork-local-rotate-token
    ;;
  configure-telegram)
    [ "$(id -u)" -eq 0 ] && [ -t 0 ] && [ -t 1 ] || { echo "Telegram configuration requires a root interactive TTY" >&2; exit 1; }
    printf 'Telegram bot token: ' >&2; stty -echo; IFS= read -r bot_token </dev/tty; stty echo; printf '\n' >&2
    printf 'Allowed numeric chat ID: ' >&2; IFS= read -r chat_id </dev/tty
    case "$chat_id" in -[0-9]*|[0-9]*) ;; *) echo "invalid chat ID" >&2; exit 1 ;; esac
    case "$chat_id" in *[!0-9-]*|--*|*-) echo "invalid chat ID" >&2; exit 1 ;; esac
    case "$bot_token" in [0-9]*:[A-Za-z0-9_-]*) ;; *) echo "invalid Telegram bot token shape" >&2; exit 1 ;; esac
    case "$bot_token" in *[!A-Za-z0-9_:-]*) echo "invalid Telegram bot token shape" >&2; exit 1 ;; esac
    /usr/bin/install -d -m 0700 -o 10002 -g 10002 /data/telegram
    umask 077
    printf 'bot_token = "%s"\nallowed_chat_ids = [%s]\n' "$bot_token" "$chat_id" >/data/telegram/config.toml
    /usr/bin/openssl rand 64 >/data/telegram/secret
    chown 10002:10002 /data/telegram/config.toml /data/telegram/secret
    chmod 0600 /data/telegram/config.toml /data/telegram/secret
    echo "Telegram configuration stored"
    ;;
  *)
    echo "unknown local entrypoint command: $1" >&2
    exit 2
    ;;
esac
