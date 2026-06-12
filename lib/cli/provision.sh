#!/usr/bin/env bash
# Sourced by bin/fieldwork. Do not execute directly.
#
# `fieldwork provision <provider>` creates the VPS that the rest of Fieldwork
# already knows how to configure. It sits on the Slice 1 config seam: server
# name, ssh-key name, and labels all derive from the resolved FIELDWORK_*
# fields, and the only thing it leaves behind is a managed ~/.ssh/config alias.
#
# It is deliberately thin. cloud-init creates the remote user + installs the SSH
# key + drops the temporary passwordless-sudo rule that `fieldwork setup` already
# expects; everything else (bootstrap, broker, PAT) stays with `fieldwork setup`.
# Fieldwork never reads or stores the Hetzner API token. That lives entirely in
# `hcloud` (HCLOUD_TOKEN env or the active hcloud context).

PROVISION_DEFAULT_TYPE="cx23"
PROVISION_DEFAULT_LOCATION="nbg1"
PROVISION_IMAGE="ubuntu-24.04"

# Validates FIELDWORK_SSH_HOST as a Hetzner server name (a hostname label set:
# alphanumerics, dots and hyphens, starting and ending alphanumeric, <=63 chars).
# Prints the validated name, or fails with an actionable message. We reject
# rather than silently rewrite so two different ssh_hosts can never collapse to
# the same server.
provision_server_name() {
  local host="$1"
  case "$host" in
    "" ) echo "[fieldwork provision] ssh_host is empty; set ssh_host or pass --name" >&2; return 1 ;;
  esac
  if [ "${#host}" -gt 63 ]; then
    echo "[fieldwork provision] '$host' is too long for a server name (max 63); pass --name" >&2
    return 1
  fi
  case "$host" in
    *[!a-zA-Z0-9.-]* | [!a-zA-Z0-9]* | *[!a-zA-Z0-9] )
      echo "[fieldwork provision] '$host' is not a valid server name (letters, digits, '.', '-'; must start and end alphanumeric)." >&2
      echo "                      Fix ssh_host in fieldwork.toml or pass --name <server-name>." >&2
      return 1 ;;
  esac
  printf '%s\n' "$host"
}

provision_validate_remote_user() {
  local user="$1"
  case "$user" in
    [a-z_]*[!a-z0-9_-]* | "" | [!a-z_]* )
      echo "[fieldwork provision] remote_user '$user' is not a valid Linux username." >&2
      return 1 ;;
  esac
  printf '%s\n' "$user"
}

# The label set that scopes every Fieldwork-owned object. Used both as repeated
# `--label k=v` create args and as a single `-l k=v,...` list selector.
provision_label_pairs() {
  printf 'managed-by=fieldwork\n'
  printf 'fieldwork-profile=%s\n' "$FIELDWORK_PROFILE"
  printf 'fieldwork-ssh-host=%s\n' "$FIELDWORK_SSH_HOST"
}

provision_label_selector() {
  provision_label_pairs | paste -sd, -
}

# Renders the minimal cloud-init user-data. Mirrors what setup's assisted root
# bootstrap does today: the remote user with sudo + key, plus the temporary
# passwordless-sudo rule at /etc/sudoers.d/fieldwork-<user> that setup's final
# handoff later removes.
provision_render_cloud_init() {
  local user="$1" pubkey="$2"
  cat <<EOF
#cloud-config
users:
  - name: $user
    groups: [sudo]
    shell: /bin/bash
    ssh_authorized_keys:
      - $pubkey
write_files:
  - path: /etc/sudoers.d/fieldwork-$user
    permissions: '0440'
    content: "$user ALL=(ALL) NOPASSWD:ALL\\n"
EOF
}

# Collapses a public-key line to type + comment + fingerprint so --dry-run output
# stays readable and doesn't dump the full blob. Public keys aren't secret, but
# printing them in full is noise.
provision_redact_pubkey() {
  local keyfile="$1"
  local line type comment fp
  line="$(cat "$keyfile")"
  type="${line%% *}"
  comment="${line##* }"
  case "$line" in
    *" "*" "*) ;;          # has a comment field
    *) comment="(no comment)" ;;
  esac
  fp="$(ssh-keygen -lf "$keyfile" 2>/dev/null | awk '{print $2}')"
  [ -n "$fp" ] || fp="SHA256:unknown"
  printf '<your SSH public key: %s … %s (%s)>\n' "$type" "$comment" "$fp"
}

provision_preflight_hcloud() {
  if ! command -v hcloud >/dev/null 2>&1; then
    echo "[fieldwork provision] hcloud CLI not found." >&2
    echo "                      Install it (macOS: brew install hcloud) and configure access:" >&2
    echo "                        hcloud context create fieldwork   # paste a Hetzner Cloud API token" >&2
    echo "                      or export HCLOUD_TOKEN=<token>. See docs/first-time-infrastructure.md." >&2
    return 2
  fi
  if ! hcloud server list -o noheader >/dev/null 2>&1; then
    echo "[fieldwork provision] hcloud cannot reach Hetzner (no active context and no HCLOUD_TOKEN)." >&2
    echo "                      Run 'hcloud context create fieldwork' or export HCLOUD_TOKEN." >&2
    return 2
  fi
}

# Writes the managed SSH alias for the new box. Same BEGIN/END markers that
# `fieldwork uninstall` removes, plus accept-new so the first connect to a fresh
# host key succeeds without an interactive prompt.
provision_write_ssh_alias() {
  local ip="$1"
  local rc=0
  ssh_config_write_managed_block "$FIELDWORK_SSH_HOST" "$ip" "~/.ssh/id_ed25519" \
    "StrictHostKeyChecking accept-new" || rc=$?
  case "$rc" in
    0) status_ok_line "Added SSH alias: $FIELDWORK_SSH_HOST -> $ip" ;;
    11)
      fieldwork_warn "Host $FIELDWORK_SSH_HOST already exists in ~/.ssh/config (not Fieldwork-managed); not modifying it."
      info_row "Server IP" "$ip"
      info_row "Reconcile" "ensure HostName is $ip and User is $FIELDWORK_REMOTE_USER"
      ;;
    10)
      fieldwork_warn "~/.ssh/config is a symlink; not modifying it." \
        "add the alias by hand: HostName $ip, User $FIELDWORK_REMOTE_USER" "docs/setup.md#ssh-config"
      ;;
    12)
      fieldwork_warn "multiple Fieldwork-managed blocks for $FIELDWORK_SSH_HOST; not modifying it." \
        "remove the duplicates, leaving one, then rerun" "docs/setup.md#ssh-config"
      ;;
    *)
      fieldwork_warn "could not write the SSH alias for $FIELDWORK_SSH_HOST -> $ip." \
        "add it to ~/.ssh/config by hand" "docs/setup.md#ssh-config"
      ;;
  esac
  return 0
}

provision_hetzner_create() {
  local server_type="$1" location="$2" name="$3" keyfile="$4" dry_run="$5" show_key="$6"
  local user keyname pubkey
  user="$(provision_validate_remote_user "$FIELDWORK_REMOTE_USER")" || return 1
  keyname="$name"

  if [ ! -s "$keyfile" ]; then
    echo "[fieldwork provision] SSH public key not found: $keyfile" >&2
    echo "                      Create one with: ssh-keygen -t ed25519 -C \"fieldwork\"" >&2
    return 1
  fi
  pubkey="$(cat "$keyfile")"

  local pubkey_display="$pubkey"
  if [ "$show_key" != "1" ]; then
    pubkey_display="$(provision_redact_pubkey "$keyfile")"
  fi

  local label_args=()
  local pair
  while IFS= read -r pair; do
    label_args+=(--label "$pair")
  done < <(provision_label_pairs)

  if [ "$dry_run" = "1" ]; then
    info_heading "Provision plan (dry run)"
    info_row "Provider" "hetzner"
    info_row "Server name" "$name"
    info_row "Type" "$server_type"
    info_row "Image" "$PROVISION_IMAGE"
    info_row "Location" "$location"
    info_row "SSH key" "$keyname (from $keyfile)"
    info_row "Labels" "$(provision_label_selector)"
    echo
    label_line "cloud-init user-data"
    provision_render_cloud_init "$user" "$pubkey_display"
    return 0
  fi

  provision_preflight_hcloud || return $?

  if hcloud server describe "$name" -o noheader >/dev/null 2>&1; then
    status_ok_line "Server $name already exists; reusing it"
  else
    if ! hcloud ssh-key describe "$keyname" -o noheader >/dev/null 2>&1; then
      hcloud ssh-key create --name "$keyname" --public-key-from-file "$keyfile" \
        "${label_args[@]+"${label_args[@]}"}" >/dev/null
      status_ok_line "Uploaded SSH key: $keyname"
    fi
    local userdata
    userdata="$(mktemp "${TMPDIR:-/tmp}/fieldwork-cloud-init.XXXXXX")"
    provision_render_cloud_init "$user" "$pubkey" >"$userdata"
    if ! hcloud server create --name "$name" --type "$server_type" --image "$PROVISION_IMAGE" \
        --location "$location" --ssh-key "$keyname" --user-data-from-file "$userdata" \
        "${label_args[@]+"${label_args[@]}"}" >/dev/null; then
      rm -f "$userdata"
      echo "[fieldwork provision] hcloud server create failed." >&2
      return 1
    fi
    rm -f "$userdata"
    status_ok_line "Created server: $name ($server_type, $location)"
  fi

  local ip
  ip="$(hcloud server ip "$name" 2>/dev/null)"
  if [ -z "$ip" ]; then
    echo "[fieldwork provision] could not resolve the server IP; check 'hcloud server describe $name'." >&2
    return 1
  fi
  provision_write_ssh_alias "$ip"

  info_heading "Next steps"
  info_row "1" "wait ~30s for cloud-init, then: ssh $FIELDWORK_SSH_HOST whoami  (expect: $user)"
  info_row "2" "fieldwork sync-vps"
  info_row "3" "fieldwork setup"
  echo
  label_line "Teardown"
  echo "  fieldwork provision hetzner --destroy"
}

provision_hetzner_destroy() {
  local name_override="$1" assume_yes="$2"
  provision_preflight_hcloud || return $?

  local selector name names count
  selector="$(provision_label_selector)"
  if [ -n "$name_override" ]; then
    name="$name_override"
  else
    names="$(hcloud server list -l "$selector" -o noheader -o columns=name 2>/dev/null || true)"
    count="$(printf '%s' "$names" | grep -c . || true)"
    if [ "$count" = "0" ]; then
      echo "[fieldwork provision] no Fieldwork-managed server found for profile '$FIELDWORK_PROFILE' (ssh_host $FIELDWORK_SSH_HOST)." >&2
      return 0
    fi
    if [ "$count" != "1" ]; then
      echo "[fieldwork provision] $count servers match this profile; refusing to guess. Pass --name <server>:" >&2
      printf '%s\n' "$names" | sed 's/^/  /' >&2
      return 2
    fi
    name="$(printf '%s' "$names" | tr -d '[:space:]')"
  fi

  info_heading "Destroy plan"
  info_row "Server" "$name"
  info_row "Labels" "$selector"
  echo
  if ! confirm "[fieldwork provision] Permanently delete server '$name'?" "$assume_yes"; then
    echo "  Cancelled."
    return 0
  fi
  if ! hcloud server delete "$name" >/dev/null 2>&1; then
    echo "[fieldwork provision] hcloud server delete failed for '$name'." >&2
    return 1
  fi
  status_ok_line "Deleted server: $name"

  local keyname
  keyname="$name"
  if hcloud ssh-key describe "$keyname" -o json 2>/dev/null | grep -q '"managed-by"[[:space:]]*:[[:space:]]*"fieldwork"'; then
    hcloud ssh-key delete "$keyname" >/dev/null 2>&1 && status_ok_line "Deleted SSH key: $keyname"
  fi

  echo
  info_row "Note" "the ~/.ssh/config alias for $FIELDWORK_SSH_HOST was left in place; 'fieldwork uninstall' removes it"
}

provision_usage() {
  cat <<EOF
usage: fieldwork provision hetzner [options]
       fieldwork provision hetzner --destroy [--name <server>] [--yes]

Create a Hetzner VPS (via the hcloud CLI), wire up the SSH alias, and hand off
to 'fieldwork setup'. BYO-VPS stays fully supported; this is additive.

Options
  --type <type>       Hetzner server type (default: $PROVISION_DEFAULT_TYPE)
  --location <loc>    Hetzner location (default: $PROVISION_DEFAULT_LOCATION)
  --name <name>       override the server name (default: ssh_host)
  --ssh-key-file <p>  public key to install (default: ~/.ssh/id_ed25519.pub)
  --dry-run           print the plan + cloud-init without creating anything
  --show-key          with --dry-run, print the full public key (not redacted)
  --destroy           delete the Fieldwork-managed server for this profile
  --yes               skip the destroy confirmation
  -h, --help          show this help

Hetzner access uses the hcloud CLI (HCLOUD_TOKEN or an active hcloud context).
Fieldwork never reads or stores the token.
EOF
}

provision() {
  local provider="${1:-}"
  case "$provider" in
    ""|-h|--help) provision_usage; return 0 ;;
    hetzner) shift ;;
    *) echo "[fieldwork provision] unknown provider: $provider (supported: hetzner)" >&2; return 2 ;;
  esac

  local server_type="$PROVISION_DEFAULT_TYPE"
  local location="$PROVISION_DEFAULT_LOCATION"
  local name_override="" keyfile="$HOME/.ssh/id_ed25519.pub"
  local destroy=0 dry_run=0 show_key=0 assume_yes=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --type) server_type="${2:?--type requires a value}"; shift 2 ;;
      --location) location="${2:?--location requires a value}"; shift 2 ;;
      --name) name_override="${2:?--name requires a value}"; shift 2 ;;
      --ssh-key-file) keyfile="${2:?--ssh-key-file requires a path}"; shift 2 ;;
      --destroy) destroy=1; shift ;;
      --dry-run) dry_run=1; shift ;;
      --show-key) show_key=1; shift ;;
      --yes|-y) assume_yes=1; shift ;;
      -h|--help) provision_usage; return 0 ;;
      *) echo "[fieldwork provision] unknown argument: $1" >&2; return 2 ;;
    esac
  done

  if [ "$destroy" = "1" ]; then
    provision_hetzner_destroy "$name_override" "$assume_yes"
    return $?
  fi

  local name
  if [ -n "$name_override" ]; then
    name="$(provision_server_name "$name_override")" || return 1
  else
    name="$(provision_server_name "$FIELDWORK_SSH_HOST")" || return 1
  fi
  provision_hetzner_create "$server_type" "$location" "$name" "$keyfile" "$dry_run" "$show_key"
}
