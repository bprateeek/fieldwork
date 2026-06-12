#!/usr/bin/env bash
# Sourced by bin/fieldwork. Do not execute directly.
# Contains verify-security command handler only.

verify_security() {
  local slug=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --remote)
        # verify-security is remote-only; accept the explicit form for
        # consistency with doctor and other setup diagnostics.
        shift
        ;;
      --help)
        cat <<'EOF'
usage: fieldwork verify-security [--remote] [repo-slug]

Checks Fieldwork's remote security posture: broker token permissions, broker
socket permissions, broker hardening directives, notification isolation, and
optional per-repo origin checks. It does not mutate the VPS. --remote is
accepted explicitly, but remote checks are the only mode.
EOF
        return 0
        ;;
      --*) echo "unknown verify-security argument: $1" >&2; return 2 ;;
      *)
        [ -z "$slug" ] || { echo "verify-security accepts at most one repo slug" >&2; return 2; }
        slug="$1"
        shift
        ;;
    esac
  done

  if [ -n "$slug" ]; then
    valid_slug "$slug" || { echo "invalid repo slug: $slug" >&2; return 2; }
  fi

  echo "Fieldwork verify-security"
  info_row "remote" "$FIELDWORK_SSH_HOST"
  [ -z "$slug" ] || info_row "repo" "$slug"

  local failed=0
  local next_action=""
  security_next() {
    [ -n "$next_action" ] || next_action="$1"
  }
  security_ok() {
    status_ok_line "$1"
  }
  security_info() {
    echo "  info: $1"
  }
  security_manual() {
    local label="$1"
    local next="$2"
    setup_status_line manual "$label"
    echo "    $next"
    security_next "$next"
  }
  security_fail() {
    local label="$1"
    local next="$2"
    setup_status_line blocked "$label"
    echo "    $next"
    failed=1
    security_next "$next"
  }

  phase_section "SSH"
  if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$FIELDWORK_SSH_HOST" "true" >/dev/null 2>&1; then
    security_fail "cannot reach VPS over SSH" "Fix Host $FIELDWORK_SSH_HOST in ~/.ssh/config, then rerun fieldwork verify-security."
    echo
    label_line "Next action"
    echo "  $next_action"
    return "$failed"
  fi
  security_ok "VPS reachable over SSH"
  local security_agents
  security_agents="$(remote_agents_value)"

  phase_section "Privilege Boundary"
  if temporary_passwordless_sudo_present; then
    security_fail "temporary passwordless sudo is still enabled" "Run: $(remote_sudo_ssh_command "rm -f $(shell_quote "$(fieldwork_sudoers_path)")") after broker setup is working."
  else
    security_ok "temporary passwordless sudo rule is absent"
  fi

  local pat_meta=""
  pat_meta="$(ssh "$FIELDWORK_SSH_HOST" "sudo -n stat -c '%U:%G %a' /etc/fieldwork-pr-broker/gh-token 2>/dev/null" || true)"
  if [ -z "$pat_meta" ]; then
    security_manual "broker PAT file metadata needs sudo inspection" "Run: $(remote_sudo_ssh_command "stat -c '%U:%G %a' /etc/fieldwork-pr-broker/gh-token")"
  elif [ "$pat_meta" = "fieldwork-pr-broker:fieldwork-pr-broker 600" ]; then
    security_ok "broker PAT file owner/mode is fieldwork-pr-broker:fieldwork-pr-broker 600"
  else
    security_fail "broker PAT file owner/mode is $pat_meta" "Run: $(remote_sudo_ssh_command "env FIELDWORK_ROTATE_PAT_TTY=1 /usr/local/sbin/rotate-pat")"
  fi

  if ssh "$FIELDWORK_SSH_HOST" "test ! -r /etc/fieldwork-pr-broker/gh-token" >/dev/null 2>&1; then
    security_ok "agent user cannot read broker PAT"
  else
    security_fail "agent user can read broker PAT" "Run: $(remote_sudo_ssh_command "chown fieldwork-pr-broker:fieldwork-pr-broker /etc/fieldwork-pr-broker/gh-token && $(remote_sudo_prefix) chmod 600 /etc/fieldwork-pr-broker/gh-token")"
  fi
  if agents_include "$security_agents" codex; then
    if ssh "$FIELDWORK_SSH_HOST" "test \"\$(id -un)\" = $(shell_quote "$FIELDWORK_REMOTE_USER")" >/dev/null 2>&1; then
      security_ok "Codex SSH identity is $FIELDWORK_REMOTE_USER"
    else
      security_fail "Codex SSH identity is not $FIELDWORK_REMOTE_USER" "Fix Host $FIELDWORK_SSH_HOST User in ~/.ssh/config; Codex Desktop must connect as the Fieldwork Linux user."
    fi
    if ssh "$FIELDWORK_SSH_HOST" "test ! -r /etc/fieldwork-pr-broker/gh-token" >/dev/null 2>&1; then
      security_ok "Codex SSH identity cannot read broker PAT"
    else
      security_fail "Codex SSH identity can read broker PAT" "Run: $(remote_sudo_ssh_command "chown fieldwork-pr-broker:fieldwork-pr-broker /etc/fieldwork-pr-broker/gh-token && $(remote_sudo_prefix) chmod 600 /etc/fieldwork-pr-broker/gh-token")"
    fi
  fi

  phase_section "Broker Socket And Storage"
  local socket_meta=""
  local socket_primary_group=""
  local socket_unit_group=""
  local socket_expected_group=""
  local submit_socket_group=""
  socket_primary_group="$(ssh "$FIELDWORK_SSH_HOST" "id -gn $(shell_quote "$FIELDWORK_REMOTE_USER") 2>/dev/null" || true)"
  socket_unit_group="$(ssh "$FIELDWORK_SSH_HOST" "sed -n 's/^SocketGroup=//p' /etc/systemd/system/fieldwork-pr-broker.socket 2>/dev/null | tail -1" || true)"
  socket_expected_group="${socket_unit_group:-$socket_primary_group}"
  socket_meta="$(ssh "$FIELDWORK_SSH_HOST" "stat -c '%U:%G %a' /run/fieldwork-pr-broker/fieldwork-pr.sock 2>/dev/null" || true)"
  case "$socket_meta" in
    *:*" "*)
      submit_socket_group="${socket_meta#*:}"
      submit_socket_group="${submit_socket_group%% *}"
      ;;
  esac
  if [ -z "$socket_expected_group" ]; then
    security_fail "cannot resolve the broker submit socket group" "Run: fieldwork doctor --remote --explain"
  elif [ "$socket_meta" = "fieldwork-pr-broker:$socket_expected_group 660" ]; then
    security_ok "broker socket owner/mode is fieldwork-pr-broker:$socket_expected_group 660"
  elif [ -z "$socket_meta" ]; then
    security_fail "broker socket is missing" "Run: $(remote_sudo_ssh_command "bash ~/.fieldwork/infra/fieldwork-pr-broker/install.sh")"
  else
    security_fail "broker socket owner/mode is $socket_meta (expected fieldwork-pr-broker:$socket_expected_group 660)" "Run: fieldwork sync-vps --force-install, then $(remote_sudo_ssh_command "bash ~/.fieldwork/infra/fieldwork-pr-broker/install.sh")"
  fi
  if [ -n "$socket_unit_group" ] && [ -n "$socket_primary_group" ] && [ "$socket_unit_group" != "$socket_primary_group" ]; then
    security_info "submit socket uses configured group $socket_unit_group instead of the agent primary group $socket_primary_group; custom groups must remain visible inside the agent sandbox."
  fi
  if ssh "$FIELDWORK_SSH_HOST" "test -w /run/fieldwork-pr-broker/fieldwork-pr.sock" >/dev/null 2>&1; then
    security_ok "agent user can write broker socket"
  else
    security_fail "agent user cannot write broker socket" "Reconnect to the VPS if group membership just changed; otherwise run fieldwork sync-vps --force-install, then $(remote_sudo_ssh_command "bash ~/.fieldwork/infra/fieldwork-pr-broker/install.sh")"
  fi
  if agents_include "$security_agents" codex; then
    if ssh "$FIELDWORK_SSH_HOST" "test -w /run/fieldwork-pr-broker/fieldwork-pr.sock" >/dev/null 2>&1; then
      security_ok "Codex SSH identity can reach broker submit socket"
    else
      security_fail "Codex SSH identity cannot reach broker submit socket" "Reconnect to the VPS if group membership just changed; otherwise run fieldwork sync-vps --force-install, then $(remote_sudo_ssh_command "bash ~/.fieldwork/infra/fieldwork-pr-broker/install.sh")"
    fi
  fi

  local ledger_meta=""
  ledger_meta="$(ssh "$FIELDWORK_SSH_HOST" "sudo -n stat -c '%U:%G %a' /var/lib/fieldwork-pr-broker/requests 2>/dev/null" || true)"
  if [ -z "$ledger_meta" ]; then
    security_manual "broker request ledger metadata needs sudo inspection" "Run: $(remote_sudo_ssh_command "stat -c '%U:%G %a' /var/lib/fieldwork-pr-broker/requests")"
  elif [ "$ledger_meta" = "fieldwork-pr-broker:fieldwork-pr-broker 700" ]; then
    security_ok "broker request ledger owner/mode is fieldwork-pr-broker:fieldwork-pr-broker 700"
  else
    security_fail "broker request ledger owner/mode is $ledger_meta" "Run: $(remote_sudo_ssh_command "install -o fieldwork-pr-broker -g fieldwork-pr-broker -m 700 -d /var/lib/fieldwork-pr-broker/requests")"
  fi

  phase_section "Broker Service Hardening"
  local directive
  for directive in \
    "NoNewPrivileges=true" \
    "PrivateTmp=true" \
    "ProtectSystem=strict" \
    "ProtectHome=read-only" \
    "RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6"; do
    if ssh "$FIELDWORK_SSH_HOST" "systemctl cat fieldwork-pr-broker.service 2>/dev/null | grep -Fx '$directive' >/dev/null" >/dev/null 2>&1; then
      security_ok "broker service has $directive"
    else
      security_fail "broker service missing $directive" "Run: fieldwork sync-vps --force-install, then $(remote_sudo_ssh_command "bash ~/.fieldwork/infra/fieldwork-pr-broker/install.sh")"
    fi
  done

  phase_section "Approval-Gate Bot"
  echo "  Optional. A separate 'fieldwork-bot' Linux user queues each PR for"
  echo "  mobile approval over Telegram and signs approve calls to the broker"
  echo "  with an HMAC secret."
  echo
  echo "  Trust separation: the bot user must not be able to read the broker"
  if [ -n "$submit_socket_group" ]; then
    echo "  GitHub PAT and must not be in the submit socket group ($submit_socket_group)."
  else
    echo "  GitHub PAT and must not be in the submit socket group."
  fi
  echo
  info_row "Setup" "fieldwork setup-notify --telegram-bot  (or skip, this is optional)"
  echo
  # When installed, we assert the trust separation: no GitHub PAT in the
  # bot user's reach, no submit-socket group membership, and tight perms on the
  # approve socket and HMAC secret.
  if ssh "$FIELDWORK_SSH_HOST" "test -f /etc/systemd/system/fieldwork-bot.service" >/dev/null 2>&1; then
    local bot_user_exists=0
    if ssh "$FIELDWORK_SSH_HOST" "id fieldwork-bot >/dev/null 2>&1"; then
      bot_user_exists=1
    fi

    if [ "$bot_user_exists" = "1" ] && [ -n "$submit_socket_group" ] && ssh "$FIELDWORK_SSH_HOST" "id -nG fieldwork-bot 2>/dev/null | tr ' ' '\n' | grep -Fxq $(shell_quote "$submit_socket_group")"; then
      security_fail "bot user is in the submit socket group (could forge /pr requests)" "Remove fieldwork-bot from $submit_socket_group: $(remote_sudo_ssh_command "gpasswd -d fieldwork-bot $(shell_quote "$submit_socket_group")")"
    elif [ "$bot_user_exists" = "1" ]; then
      security_ok "bot user is not in the submit socket group"
    else
      security_manual "bot user not provisioned yet" "Run: fieldwork setup-notify --telegram-bot"
    fi

    # File presence + owner/mode is necessary but NOT sufficient. A stale or
    # dangling Unix socket bind (kernel listener with no accepting process, or
    # an inode the broker no longer maps to the on-disk path) can pass stat
    # but ENOENT on connect(). The live probe below is what catches that case;
    # the stat check stays as a cheap fast-path with a clearer diagnosis when
    # the file itself is wrong.
    local approve_meta="" approve_file_ok=0
    approve_meta="$(ssh "$FIELDWORK_SSH_HOST" "stat -c '%U:%G %a' /run/fieldwork-pr-broker/fieldwork-pr-approve.sock 2>/dev/null" || true)"
    local approve_restart_hint
    approve_restart_hint="Restart broker service and both socket units (stale/dangling Unix socket bind may exist): $(remote_sudo_ssh_command "systemctl stop fieldwork-pr-broker.service fieldwork-pr-broker.socket fieldwork-pr-approve.socket && rm -f /run/fieldwork-pr-broker/*.sock && systemctl start fieldwork-pr-broker.socket fieldwork-pr-approve.socket")"
    if [ "$approve_meta" = "fieldwork-pr-broker:fieldwork-bot 660" ]; then
      security_ok "approve socket file: ok"
      approve_file_ok=1
    elif [ -z "$approve_meta" ]; then
      security_fail "approve socket file: missing" "$approve_restart_hint"
    else
      security_fail "approve socket file: wrong owner/mode ($approve_meta, expected fieldwork-pr-broker:fieldwork-bot 660)" "$approve_restart_hint"
    fi

    # Live connect probe, must run as the bot user so we exercise the same
    # uid path the daemon uses when handling Telegram callbacks. POST {} to
    # /approve; the broker validates the JSON shape and returns the
    # well-known error `approve request missing required field: ...` (set at
    # lib/broker/server.py:598). Matching that single stable substring proves
    # the path resolves, connect() succeeds, the broker is accepting on this
    # fd, and the bot user has SocketGroup access. All in one shot.
    if [ "$approve_file_ok" = "1" ] && [ "$bot_user_exists" = "1" ]; then
      if ssh "$FIELDWORK_SSH_HOST" "sudo -n -u fieldwork-bot true 2>/dev/null" >/dev/null 2>&1; then
        if ssh "$FIELDWORK_SSH_HOST" "sudo -n -u fieldwork-bot curl -sS --unix-socket /run/fieldwork-pr-broker/fieldwork-pr-approve.sock -H 'Content-Type: application/json' --data-binary '{}' http://localhost/approve 2>/dev/null | grep -Fq 'approve request missing required field'" >/dev/null 2>&1; then
          security_ok "approve socket connect as fieldwork-bot: ok"
        else
          security_fail "approve socket connect as fieldwork-bot: failed" "$approve_restart_hint"
        fi
      else
        security_manual "approve socket connect probe needs manual sudo verification" "Run: ssh -t $FIELDWORK_SSH_HOST $(shell_double_quote "sudo -u fieldwork-bot curl -sS --unix-socket /run/fieldwork-pr-broker/fieldwork-pr-approve.sock -H 'Content-Type: application/json' --data-binary '{}' http://localhost/approve"). Expected output contains: approve request missing required field"
      fi
    fi

    # PAT-read isolation and HMAC secret checks depend on the bot user
    # existing; skip them with a single deferred note otherwise so the
    # user isn't asked to verify state for an account that hasn't been
    # created yet.
    if [ "$bot_user_exists" = "1" ]; then
      if ssh "$FIELDWORK_SSH_HOST" "sudo -n -u fieldwork-bot test ! -r /etc/fieldwork-pr-broker/gh-token 2>/dev/null" >/dev/null 2>&1; then
        security_ok "bot user cannot read broker GitHub PAT"
      else
        security_manual "PAT-read isolation needs manual sudo verification" "Run: ssh -t $FIELDWORK_SSH_HOST $(shell_double_quote "sudo -u fieldwork-bot cat /etc/fieldwork-pr-broker/gh-token"). Expected: permission denied"
      fi

      local secret_meta=""
      secret_meta="$(ssh "$FIELDWORK_SSH_HOST" "sudo -n stat -c '%U:%G %a' /etc/fieldwork-bot/secret 2>/dev/null" || true)"
      if [ -z "$secret_meta" ]; then
        security_manual "HMAC secret metadata needs manual sudo verification" "Run: $(remote_sudo_ssh_command "stat -c '%U:%G %a' /etc/fieldwork-bot/secret"). Expected: fieldwork-bot:fieldwork-bot 400"
      elif [ "$secret_meta" = "fieldwork-bot:fieldwork-bot 400" ]; then
        security_ok "HMAC secret owner/mode is fieldwork-bot:fieldwork-bot 400"
      else
        security_fail "HMAC secret owner/mode is $secret_meta" "Run: fieldwork setup-notify --telegram-bot"
      fi
    else
      security_manual "PAT-read isolation and HMAC secret checks deferred" "Run: fieldwork setup-notify --telegram-bot (these checks light up once the bot user exists)"
    fi
  else
    security_manual "approval-gate bot is not installed" "Run: fieldwork setup-notify --telegram-bot (skip if you don't need a Telegram approval step)"
  fi

  phase_section "Network And Notifications"
  local ufw_status=""
  ufw_status="$(ssh "$FIELDWORK_SSH_HOST" "sudo -n ufw status 2>/dev/null" || true)"
  if [ -z "$ufw_status" ]; then
    security_manual "firewall rules need sudo inspection" "Run: $(remote_sudo_ssh_command "ufw status") and confirm public 22/tcp is restricted once your private SSH path works."
  elif printf '%s\n' "$ufw_status" | grep -Ei '^[[:space:]]*22/tcp[[:space:]]+ALLOW' | grep -Eiv '(on[[:space:]]+(tailscale|wg|tun)[0-9]*|(^|[^0-9.])(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.))' >/dev/null; then
    security_fail "public SSH firewall rule appears to be allowed" "Restrict public 22/tcp once your private SSH path works: $(remote_sudo_ssh_command "ufw delete allow 22/tcp")"
  else
    security_ok "no obvious public 22/tcp allow rule in ufw"
  fi

  if ssh "$FIELDWORK_SSH_HOST" "if grep -RqsE 'notify\\.env|NTFY_TOPIC|TG_BOT_TOKEN' ~/.config/systemd/user/fieldwork-agent@.service ~/.config/systemd/user/fieldwork-agent@.service.d 2>/dev/null; then exit 1; else exit 0; fi" >/dev/null 2>&1; then
    security_ok "notification secrets are not injected into Claude systemd unit"
  else
    security_fail "notification secrets appear in Claude systemd unit config" "Remove notify.env or token variables from ~/.config/systemd/user/fieldwork-agent@.service, then run systemctl --user daemon-reload."
  fi

  if [ -n "$slug" ]; then
    phase_section "Repo Boundary"
    local repo_path="$FIELDWORK_PROJECTS_DIR/$slug"
    local repo_path_q
    repo_path_q="$(shell_quote "$repo_path")"
    if ssh "$FIELDWORK_SSH_HOST" "test -d $repo_path_q/.git" >/dev/null 2>&1; then
      security_ok "repo checkout exists at $repo_path"
    else
      security_fail "repo checkout missing at $repo_path" "Run: fieldwork onboard <owner>/$slug"
    fi

    if ssh "$FIELDWORK_SSH_HOST" "test -f $repo_path_q/.fieldwork/expected-origin" >/dev/null 2>&1; then
      security_ok "repo expected-origin file exists"
    else
      security_fail "repo expected-origin file missing" "Run: fieldwork onboard <owner>/$slug or inspect $repo_path/.fieldwork/expected-origin on the VPS."
    fi

    if ssh "$FIELDWORK_SSH_HOST" "repo_path=$repo_path_q; expected=\$(cat \"\$repo_path/.fieldwork/expected-origin\" 2>/dev/null) || exit 10; origin=\$(git -C \"\$repo_path\" config --get remote.origin.url 2>/dev/null) || exit 11; expected_norm=\$(printf '%s' \"\$expected\" | sed -E 's#^https://github.com/##; s#\\.git\$##'); origin_norm=\$(printf '%s' \"\$origin\" | sed -E 's#^https://github\\.com/##; s#^git@[^:]+:##; s#\\.git\$##'); [ \"\$expected_norm\" = \"\$origin_norm\" ]" >/dev/null 2>&1; then
      security_ok "repo origin matches .fieldwork/expected-origin"
    else
      security_fail "repo origin does not match .fieldwork/expected-origin" "On the VPS, inspect: cd $repo_path && git remote -v && cat .fieldwork/expected-origin"
    fi

    security_info "deploy key read-only status is GitHub-side; confirm the repo deploy key has 'Allow write access' unchecked."
  fi

  if [ -n "$next_action" ]; then
    echo
    label_line "Next action"
    echo "  $next_action"
  else
    echo
    label_line "Next action"
    echo "  none; security posture looks good"
  fi
  return "$failed"
}
