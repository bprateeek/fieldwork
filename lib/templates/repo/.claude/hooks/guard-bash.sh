#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash): denies dangerous command patterns.
#
# Returns hookSpecificOutput.permissionDecision = "deny" for matched patterns.
# Emits NO output for safe commands so the normal permission flow continues
# (emitting "allow" would bypass the user's permission prompts. We don't want that).

set -euo pipefail
payload="$(cat)"
cmd="$(jq -r '.tool_input.command // ""' <<<"$payload")"

deny() {
  jq -nc --arg r "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 0
}

case "$cmd" in
  *"rm -rf /"*|*"rm -rf ~"*|*"rm -rf \$HOME"*|*"rm -rf $HOME"*) deny "destructive rm path";;
  *"git push --force"*|*"git push -f "*|*"git push --force-with-lease"*) deny "force push blocked";;
  *"git reset --hard"*) deny "hard reset blocked";;
  *"git clean -f"*) deny "git clean -f blocked";;
  *"chmod -R 777"*|*"chmod 777"*) deny "world-writable chmod blocked";;
  *"| sh"*|*"| bash"*|*"|sh "*|*"|bash "*) deny "pipe-to-shell blocked";;
  *"curl "*"| sudo"*|*"wget "*"| sudo"*) deny "curl/wget piped to sudo blocked";;
esac

# Fieldwork cage: remote agent sessions run inside a user namespace with
# NoNewPrivs, where every sandboxed Bash call fails with a bwrap error by
# design. Deny plain Bash with steering guidance instead of letting the model
# hit cryptic bwrap failures and conclude the Bash tool is broken. All
# conditions are required so local macOS, CI, cloud, and plain Linux sessions
# never match (cloud can have NoNewPrivs=1 but never the Fieldwork runner
# socket). FIELDWORK_GUARD_UNAME / FIELDWORK_GUARD_PROC_STATUS are test seams.
uname_s="${FIELDWORK_GUARD_UNAME:-$(uname -s)}"
proc_status="${FIELDWORK_GUARD_PROC_STATUS:-/proc/self/status}"
runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
if [ "$uname_s" = "Linux" ] \
  && grep -q '^NoNewPrivs:[[:space:]]*1$' "$proc_status" 2>/dev/null \
  && [ -S "$runtime_dir/fieldwork-verify.sock" ]; then
  case "$cmd" in
    # Trailing space mirrors the sandbox.excludedCommands globs: only a
    # verbatim absolute-path invocation with arguments skips the sandbox, so
    # only that form may pass. A cd/env/&& prefix would re-enable the per-call
    # sandbox and die on bwrap; denying it here is the kinder failure.
    "/usr/local/bin/fieldwork-verify "*) ;;
    "/usr/local/bin/fieldwork-pr-prepare "*) ;;
    "/usr/local/bin/fieldwork-pr-build "*) ;;
    "/usr/local/bin/fieldwork-pr-upload "*) ;;
    *) deny "Plain Bash is disabled in this Fieldwork remote session: the agent runs in a sandbox cage where every sandboxed Bash call fails by design. This is expected, not a malfunction. Explore with the Read, Grep, and Glob tools instead. To run checks use /verify-before-pr; to commit and deliver a PR use /pr-delivery. That skill uses the four root-owned protocol-v2 clients as separate absolute-path calls: fieldwork-verify, fieldwork-pr-prepare, fieldwork-pr-build, and fieldwork-pr-upload. Do not use a removed one-step submit client, combine build and upload, bypass the broker, or ask the user to push manually.";;
  esac
fi

# safe → no output, no bypass; normal permission flow continues
exit 0
