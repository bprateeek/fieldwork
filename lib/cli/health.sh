# shellcheck shell=bash
# Fieldwork `health` rendering: pure functions, no SSH.
#
# bin/fieldwork's health() does the SSH orchestration (one setup-probe + at most
# one bounded bot snapshot) and feeds the captured text in here. Keeping the
# rendering pure makes it unit-testable from fixtures without a VPS.
#
# Depends only on lib/cli/messaging.sh (sourced by the caller first). It does
# NOT use bin/fieldwork's setup_status_line/info_row helpers (those aren't
# sourceable), so it defines its own small row helpers.

# _health_kv KEY TEXT → value for KEY (handles values containing '='), or empty.
_health_kv() {
  printf '%s\n' "$2" | awk -F= -v k="$1" '$1==k { sub(/^[^=]*=/,""); print; exit }'
}

# _health_is_num STR → success if STR is a non-empty run of digits. Uses
# parameter-expansion stripping instead of a `[!0-9]` case glob: on some
# bash/locale combinations `[!0-9]` is parsed as a positive class, not a
# negation, which silently breaks numeric guards.
_health_is_num() {
  [ -n "$1" ] && [ -z "${1//[0-9]/}" ]
}

# Row counters, reset per render. info/ok rows do not count toward the verdict.
_HEALTH_NEEDS=0
_HEALTH_BLOCKED=0

# _health_row ok|needs|blocked|info AREA [DETAIL]
_health_row() {
  local status="$1" area="$2" detail="${3:-}" label
  case "$status" in
    ok)      label="$(_fieldwork_msg_green  'ok     ')" ;;
    needs)   label="$(_fieldwork_msg_yellow 'needs  ')"; _HEALTH_NEEDS=$((_HEALTH_NEEDS + 1)) ;;
    blocked) label="$(_fieldwork_msg_red    'blocked')"; _HEALTH_BLOCKED=$((_HEALTH_BLOCKED + 1)) ;;
    info)    label="$(_fieldwork_msg_cyan   'info   ')" ;;
    *)       label="$status" ;;
  esac
  if [ -n "$detail" ]; then
    printf '  %s  %s: %s\n' "$label" "$area" "$detail"
  else
    printf '  %s  %s\n' "$label" "$area"
  fi
}

_health_has_agent() {
  case ",$1," in *",$2,"*) return 0 ;; *) return 1 ;; esac
}

# Local checks (the only impure-but-trivial part: command -v + file tests).
# Emits key=value lines consumed by health_render.
health_local_checks() {
  local missing="" t root
  root="${FIELDWORK_ROOT:-}"
  for t in bash git jq ssh scp sed grep rsync; do
    command -v "$t" >/dev/null 2>&1 || missing="${missing:+$missing, }$t"
  done
  if [ -z "$missing" ]; then printf 'tools=ok\n'; else printf 'tools=missing:%s\n' "$missing"; fi
  if command -v fieldwork >/dev/null 2>&1 || [ -x "$HOME/.local/bin/fieldwork" ] || [ -x "$root/bin/fieldwork" ]; then
    printf 'cmd=ok\n'
  else
    printf 'cmd=missing\n'
  fi
  if [ -x "$HOME/.fieldwork/scripts/fieldwork-pr-submit" ] \
    && [ -x "$HOME/.fieldwork/scripts/fieldwork-verify" ] \
    && [ -x "$HOME/.fieldwork/scripts/fieldwork-pr-prepare" ] \
    && [ -f "$HOME/.fieldwork/agents" ]; then
    printf 'helpers=ok\n'
  else
    printf 'helpers=missing\n'
  fi
}

_health_agent_row() {
  # _health_agent_row AGENT SNAP : renders one row for a configured agent.
  local agent="$1" snap="$2" cli login service
  case "$agent" in
    claude)
      cli="$(_health_kv claude_cli "$snap")"
      login="$(_health_kv claude_login "$snap")"
      service="$(_health_kv claude_service "$snap")"
      if [ -z "$cli" ] && [ -z "$login" ]; then
        _health_row info "Agent: claude" "unknown (older remote probe; run fieldwork sync-vps)"
      elif [ "$cli" != ok ]; then
        _health_row needs "Agent: claude" "CLI missing. Run fieldwork setup."
      elif [ "$login" != ok ]; then
        _health_row needs "Agent: claude" "not logged in. Run: claude login"
      elif [ "$service" != ok ]; then
        _health_row needs "Agent: claude" "session service missing. Run fieldwork setup."
      else
        _health_row ok "Agent: claude"
      fi
      ;;
    codex)
      cli="$(_health_kv codex_cli "$snap")"
      login="$(_health_kv codex_login "$snap")"
      if [ -z "$cli" ] && [ -z "$login" ]; then
        _health_row info "Agent: codex" "unknown (older remote probe; run fieldwork sync-vps)"
      elif [ "$cli" != ok ]; then
        _health_row needs "Agent: codex" "codex --version failed. Run fieldwork setup."
      elif [ "$login" != ok ]; then
        _health_row needs "Agent: codex" "not logged in. Run: codex login"
      else
        _health_row ok "Agent: codex" "cli+login (delivery readiness: fieldwork doctor)"
      fi
      ;;
  esac
}

# health_render PROBE_RESULT FALLBACK_REASON SNAPSHOT_TEXT BOT_TEXT LOCAL_TEXT
# Prints the report. Returns 3 when any area is blocked (caller exits nonzero),
# else 0: needs/info never make the exit code nonzero.
health_render() {
  local probe_result="$1" fallback_reason="$2" snap="$3" bot="$4" localtext="$5"
  _HEALTH_NEEDS=0
  _HEALTH_BLOCKED=0

  local v
  v="$(_health_kv tools "$localtext")"
  case "$v" in
    ok) _health_row ok "Local tools" ;;
    missing:*) _health_row needs "Local tools" "missing: ${v#missing:}" ;;
    *) _health_row info "Local tools" "unknown" ;;
  esac
  if [ "$(_health_kv cmd "$localtext")" = ok ]; then
    _health_row ok "Fieldwork command"
  else
    _health_row needs "Fieldwork command" "not on PATH. Re-run install.sh."
  fi
  if [ "$(_health_kv helpers "$localtext")" = ok ]; then
    _health_row ok "Helper scripts"
  else
    _health_row info "Helper scripts" "not installed locally (installed on the VPS)"
  fi

  case "$probe_result" in
    transport_failed)
      _health_row blocked "VPS" "unreachable over SSH"
      fieldwork_hint "fieldwork doctor --remote" "docs/troubleshooting.md#vps-unreachable"
      ;;
    reached_untrusted)
      _health_row needs "VPS" "reachable but Fieldwork untrusted (${fallback_reason:-unknown})"
      fieldwork_hint "fieldwork sync-vps, then fieldwork setup" "docs/troubleshooting.md#vps-untrusted"
      ;;
    valid)
      _health_render_remote "$snap" "$bot"
      ;;
    *)
      _health_row info "VPS" "probe state unknown"
      ;;
  esac

  echo
  if [ "$_HEALTH_BLOCKED" -gt 0 ] || [ "$_HEALTH_NEEDS" -gt 0 ]; then
    printf '%s area(s) need attention.\n' "$((_HEALTH_BLOCKED + _HEALTH_NEEDS))"
  else
    printf 'All systems go.\n'
  fi
  [ "$_HEALTH_BLOCKED" -gt 0 ] && return 3
  return 0
}

# Renders the remote areas from a trusted (valid) snapshot + bot text.
_health_render_remote() {
  local snap="$1" bot="$2"

  # VPS / bootstrap
  if [ "$(_health_kv fieldwork_checkout "$snap")" = ok ]; then
    _health_row ok "VPS" "reachable, checkout current"
  else
    _health_row needs "VPS" "remote out of date. Run fieldwork sync-vps."
  fi
  if [ "$(_health_kv bootstrap_ready "$snap")" = ok ]; then
    _health_row ok "Bootstrap"
  else
    _health_row needs "Bootstrap" "run fieldwork setup"
  fi

  # GitHub auth (its own area)
  local gh_cli gh_live gh_hosts
  gh_cli="$(_health_kv gh_cli "$snap")"
  gh_live="$(_health_kv gh_live "$snap")"
  gh_hosts="$(_health_kv gh_hosts "$snap")"
  if [ "$gh_cli" != ok ]; then
    _health_row needs "GitHub auth" "gh CLI missing. Run fieldwork setup."
  elif [ "$gh_live" = ok ]; then
    _health_row ok "GitHub auth"
  elif [ "$gh_live" = timeout ]; then
    _health_row info "GitHub auth" "status check timed out"
  elif [ "$gh_hosts" = ok ]; then
    _health_row needs "GitHub auth" "re-authenticate. Run: gh auth login"
  else
    _health_row needs "GitHub auth" "not authenticated. Run: gh auth login"
  fi

  # Agents
  local agents agents_status
  agents="$(_health_kv configured_agents "$snap")"
  agents_status="$(_health_kv configured_agents_status "$snap")"
  if [ "$agents_status" = invalid ]; then
    _health_row needs "Agents" "~/.fieldwork/agents unparseable. Run fieldwork setup."
  elif [ -z "$agents" ]; then
    _health_row info "Agents" "unknown (older remote probe; run fieldwork sync-vps)"
  else
    _health_has_agent "$agents" claude && _health_agent_row claude "$snap"
    _health_has_agent "$agents" codex && _health_agent_row codex "$snap"
  fi

  # Runner sockets
  local vr pr
  vr="$(_health_kv verify_runner "$snap")"
  pr="$(_health_kv prepare_runner "$snap")"
  if [ "$vr" = ok ] && [ "$pr" = ok ]; then
    _health_row ok "Runner sockets"
  elif [ -z "$vr" ] && [ -z "$pr" ]; then
    _health_row info "Runner sockets" "unknown"
  else
    _health_row needs "Runner sockets" "run fieldwork setup"
  fi

  # Broker (probe socket/tool + bot preflight route)
  local bsock btool bsubmit
  bsock="$(_health_kv broker_socket "$snap")"
  btool="$(_health_kv broker_pat_tool "$snap")"
  bsubmit="$(_health_kv BROKER_SUBMIT_STATUS "$bot")"
  if [ "$bsock" != ok ]; then
    _health_row needs "Broker" "socket missing or not writable. Run fieldwork setup."
  elif [ "$bsubmit" = bad ]; then
    _health_row needs "Broker" "preflight route failing"
  elif [ "$btool" != ok ]; then
    _health_row needs "Broker" "rotate-pat tool missing. Run fieldwork setup."
  else
    _health_row ok "Broker"
  fi

  # Token (tri-state)
  local marker sudo_probe
  marker="$(_health_kv broker_pat_marker "$snap")"
  sudo_probe="$(_health_kv broker_pat_sudo_probe "$snap")"
  if [ "$marker" = ok ] || [ "$sudo_probe" = ok ]; then
    _health_row ok "Broker token" "stored"
  elif [ "$sudo_probe" = unavailable ]; then
    _health_row info "Broker token" "unknown (passwordless sudo unavailable)"
  elif [ "$sudo_probe" = missing ]; then
    _health_row needs "Broker token" "not confirmed. Run rotate-pat on the VPS."
  else
    _health_row info "Broker token" "unknown"
  fi

  # Approvals (optional unless configured or pending)
  local token_cfg svc pending
  token_cfg="$(_health_kv TOKEN_CONFIG_STATUS "$bot")"
  svc="$(_health_kv SERVICE_STATE "$bot")"
  pending="$(_health_kv DIR_PENDING_COUNT "$bot")"
  [ -n "$pending" ] || pending="$(_health_kv HEALTH_PENDING_COUNT "$bot")"
  _health_is_num "$pending" || pending=0
  if [ "$token_cfg" != ok ] && [ "$pending" -eq 0 ]; then
    _health_row info "Approvals" "not configured (optional)"
  elif [ "$pending" -gt 0 ] && [ "$svc" != active ]; then
    _health_row needs "Approvals" "$pending pending, bot not running"
  elif [ "$svc" = active ]; then
    if [ "$pending" -gt 0 ]; then
      _health_row info "Approvals" "$pending pending"
    else
      _health_row ok "Approvals"
    fi
  else
    _health_row needs "Approvals" "bot configured but not running"
  fi
}

# --- Mobile → PR queue + last-PR rendering (used by `fieldwork status`) --------
# Pure: queue_render reads a captured bot-snapshot; pr_audit_parse reads audit
# JSONL on stdin (via jq). Neither performs SSH.

# _health_fmt_age SECONDS -> compact age (e.g. 5s/12m/3h/2d), or "unknown".
_health_fmt_age() {
  local s="$1"
  _health_is_num "$s" || { printf 'unknown'; return 0; }
  if [ "$s" -lt 60 ]; then printf '%ss' "$s"
  elif [ "$s" -lt 3600 ]; then printf '%dm' "$((s / 60))"
  elif [ "$s" -lt 86400 ]; then printf '%dh' "$((s / 3600))"
  else printf '%dd' "$((s / 86400))"; fi
}

# queue_render BOT_TEXT [SLUG_FILTER]
# Prints the "Mobile → PR queue" block. With a slug filter, lists only that
# repo's pending items; items lacking a slug are surfaced as "unmatched" rather
# than silently dropped.
queue_render() {
  local bot="$1" slug_filter="${2:-}"
  local count oldest source line repo branch age rid s shown=0 unmatched=0

  count="$(_health_kv DIR_PENDING_COUNT "$bot")"
  oldest="$(_health_kv DIR_OLDEST_PENDING_AGE_SECONDS "$bot")"
  source="$(_health_kv DIR_PENDING_SOURCE "$bot")"

  printf 'Mobile -> PR queue\n'

  if ! _health_is_num "$count"; then
    if [ "$source" = unavailable ]; then
      printf '  pending queue needs broker sudo on the VPS. Run `fieldwork bot-status`\n'
    else
      printf '  pending: unknown\n'
    fi
    return 0
  fi

  if [ -n "$slug_filter" ]; then
    # Pre-count matches so the summary line is accurate before the listing.
    while IFS= read -r line; do
      case "$line" in DIR_PENDING_ITEM=*) ;; *) continue ;; esac
      IFS=$'\t' read -r repo branch age rid s <<EOF
${line#DIR_PENDING_ITEM=}
EOF
      if [ -z "$s" ]; then unmatched=$((unmatched + 1)); continue; fi
      [ "$s" = "$slug_filter" ] && shown=$((shown + 1))
    done <<EOF
$bot
EOF
    printf '  pending for %s: %s\n' "$slug_filter" "$shown"
  else
    if [ "$count" = 0 ]; then
      printf '  pending: 0\n'
    else
      printf '  pending: %s (oldest %s)\n' "$count" "$(_health_fmt_age "$oldest")"
    fi
  fi

  while IFS= read -r line; do
    case "$line" in DIR_PENDING_ITEM=*) ;; *) continue ;; esac
    IFS=$'\t' read -r repo branch age rid s <<EOF
${line#DIR_PENDING_ITEM=}
EOF
    if [ -n "$slug_filter" ]; then
      [ -n "$s" ] || continue
      [ "$s" = "$slug_filter" ] || continue
    fi
    printf '  - %s · %s · %s\n' "${repo:-unknown}" "${branch:-?}" "$(_health_fmt_age "$age")"
  done <<EOF
$bot
EOF

  if [ -n "$slug_filter" ] && [ "$unmatched" -gt 0 ]; then
    printf '  (%s pending item(s) had no slug and were not matched)\n' "$unmatched"
  fi
  return 0
}

# pr_audit_parse SLUG  (reads broker audit JSONL on stdin)
# Prints three lines (event, pr_url, branch) for the latest event (by ts)
# matching the slug, or nothing. One field per line (not tab-joined) so an empty
# pr_url is preserved: `read` collapses empty tab-separated fields because tab is
# IFS whitespace. Uses jq (a required local tool); never performs SSH.
pr_audit_parse() {
  jq -rs --arg slug "$1" '
    [ .[] | select(.repo_path_slug == $slug) ]
    | sort_by(.ts)
    | last
    | if . == null then empty
      else (.event // "?"), (.pr_url // ""), (.branch // "")
      end
  ' 2>/dev/null || true
}

# pr_audit_row SLUG  (reads broker audit JSONL on stdin)
# Convenience wrapper: parses and prints the human row text via pr_event_label.
pr_audit_row() {
  local parsed event url branch
  parsed="$(pr_audit_parse "$1")"
  { IFS= read -r event; IFS= read -r url; IFS= read -r branch; } <<EOF
$parsed
EOF
  pr_event_label "$event" "$url" "$branch"
}

# pr_event_label EVENT URL BRANCH -> human row text.
pr_event_label() {
  local event="$1" url="$2" branch="$3" base
  base="${branch:+ ($branch)}"
  case "$event" in
    pr_opened) [ -n "$url" ] && printf 'opened: %s' "$url" || printf 'opened%s' "$base" ;;
    request_queued) printf 'queued, awaiting approval%s' "$base" ;;
    request_rejected) printf 'rejected%s' "$base" ;;
    request_denied) printf 'denied%s' "$base" ;;
    request_expired) printf 'expired%s' "$base" ;;
    ''|'?') printf 'no recent PR activity' ;;
    *) printf '%s%s' "$event" "$base" ;;
  esac
}
