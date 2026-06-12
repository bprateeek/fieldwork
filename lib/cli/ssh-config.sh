# shellcheck shell=bash
# Fieldwork managed ~/.ssh/config helpers, shared by `fieldwork setup` and
# `fieldwork provision` so both write (and rewrite) the managed alias block the
# same way. Sourceable on its own; depends only on $FIELDWORK_SSH_HOST /
# $FIELDWORK_REMOTE_USER and the message helpers in messaging.sh.
#
# A Fieldwork-managed block is delimited by:
#   # BEGIN FIELDWORK SSH CONFIG: <host>
#   …
#   # END FIELDWORK SSH CONFIG: <host>
# which is also what `fieldwork uninstall` removes.

print_ssh_config_snippet() {
  local hostname="${1:-<vps-ip-or-tailnet-name>}"
  local identity_file="${2:-~/.ssh/id_ed25519}"
  cat <<EOF
Host $FIELDWORK_SSH_HOST
  HostName $hostname
  User $FIELDWORK_REMOTE_USER
  IdentityFile $identity_file
  IdentitiesOnly yes
EOF
}

# True if any `Host` stanza (managed or hand-authored) declares the alias.
ssh_config_has_host() {
  local alias="$1"
  local config="$HOME/.ssh/config"
  [ -f "$config" ] || return 1
  awk -v alias="$alias" '
    /^[[:space:]]*[#]/ { next }
    tolower($1) == "host" {
      for (i = 2; i <= NF; i++) {
        if ($i == alias) found = 1
      }
    }
    END { exit found ? 0 : 1 }
  ' "$config"
}

# Count Fieldwork-managed blocks for the given host (by BEGIN marker).
ssh_config_managed_block_count() {
  local host="$1"
  local config="$HOME/.ssh/config" n
  [ -f "$config" ] || { printf '0\n'; return 0; }
  # grep -c prints the count even when it is 0, but then exits 1; `|| true`
  # keeps that single "0" without appending a second one.
  n="$(grep -c "^# BEGIN FIELDWORK SSH CONFIG: ${host}\$" "$config" 2>/dev/null || true)"
  [ -n "$n" ] || n=0
  printf '%s\n' "$n"
}

# Print the existing managed block (inclusive of markers) for the host, if any.
ssh_config_extract_managed_block() {
  local host="$1"
  local config="$HOME/.ssh/config"
  [ -f "$config" ] || return 0
  awk -v b="# BEGIN FIELDWORK SSH CONFIG: $host" -v e="# END FIELDWORK SSH CONFIG: $host" '
    $0 == b { inblk = 1 }
    inblk { print }
    $0 == e { inblk = 0 }
  ' "$config"
}

# Write or refresh the managed alias block.
#   ssh_config_write_managed_block <host> <hostname> <identity_file> [extra_line]
# Return codes:
#   0  wrote a new block, refreshed a stale one, or it was already current
#   10 refused: ~/.ssh/config is a symlink (won't follow)
#   11 refused: a hand-authored (non-managed) Host block exists for this host
#   12 refused: multiple managed blocks for this host (ambiguous)
#   1  internal error (could not create temp file)
ssh_config_write_managed_block() {
  local host="$1" hostname="$2" identity="$3" extra="${4:-}"
  local config="$HOME/.ssh/config" ssh_dir="$HOME/.ssh"
  local managed_count block existing backup tmp

  [ ! -L "$config" ] || return 10

  managed_count="$(ssh_config_managed_block_count "$host")"
  [ "$managed_count" -lt 2 ] || return 12
  if [ "$managed_count" -eq 0 ] && ssh_config_has_host "$host"; then
    return 11
  fi

  block="$(
    echo "# BEGIN FIELDWORK SSH CONFIG: $host"
    print_ssh_config_snippet "$hostname" "$identity"
    [ -n "$extra" ] && echo "  $extra"
    echo "# END FIELDWORK SSH CONFIG: $host"
  )"

  mkdir -p "$ssh_dir"
  chmod 700 "$ssh_dir"

  if [ "$managed_count" -eq 0 ]; then
    touch "$config"
    chmod 600 "$config"
    {
      echo
      printf '%s\n' "$block"
    } >>"$config"
    return 0
  fi

  # Exactly one managed block: refresh in place, but no-op (and no backup) when
  # it already matches so re-running setup doesn't churn backups.
  existing="$(ssh_config_extract_managed_block "$host")"
  if [ "$existing" = "$block" ]; then
    return 0
  fi

  backup="${config}.fieldwork.$(date -u +%Y%m%dT%H%M%SZ).bak"
  cp "$config" "$backup"
  tmp="$(mktemp "$ssh_dir/.config.fieldwork.XXXXXX")" || return 1
  FIELDWORK_SSH_BLOCK="$block" awk \
    -v b="# BEGIN FIELDWORK SSH CONFIG: $host" \
    -v e="# END FIELDWORK SSH CONFIG: $host" '
    $0 == b { print ENVIRON["FIELDWORK_SSH_BLOCK"]; inblk = 1; next }
    inblk { if ($0 == e) inblk = 0; next }
    { print }
  ' "$config" >"$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$config"
  return 0
}
