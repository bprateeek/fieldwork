# shellcheck shell=bash
# Fieldwork shared user-facing message helpers.
#
# Sourceable from any entry point (bin/fieldwork, lib/cli/*.sh via their caller,
# the standalone lib/scripts/fieldwork-onboard). Self-contained: it does not
# depend on bin/fieldwork's color layer, so it works in the onboard script too.
#
# Every failure should carry a next step and, where one exists, a doc pointer
# (a repo-relative docs/<file>.md#anchor, resolvable offline, no network).
#
# Internals are namespaced _fieldwork_msg_* to avoid colliding with the
# green/red/yellow/bold helpers already defined in bin/fieldwork.

# Colour when: NO_COLOR unset, then an explicit FIELDWORK_UI_COLOR, else stderr
# is a terminal (die/warn write to stderr).
_fieldwork_msg_use_color() {
  [ -z "${NO_COLOR:-}" ] || return 1
  case "${FIELDWORK_UI_COLOR:-}" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  [ -t 2 ]
}

_fieldwork_msg_paint() {
  # _fieldwork_msg_paint <sgr-code> <text>
  if _fieldwork_msg_use_color; then
    printf '\033[%sm%s\033[0m' "$1" "$2"
  else
    printf '%s' "$2"
  fi
}

_fieldwork_msg_green() { _fieldwork_msg_paint 32 "$1"; }
_fieldwork_msg_red() { _fieldwork_msg_paint 31 "$1"; }
_fieldwork_msg_yellow() { _fieldwork_msg_paint 33 "$1"; }
_fieldwork_msg_cyan() { _fieldwork_msg_paint 36 "$1"; }
_fieldwork_msg_bold() { _fieldwork_msg_paint 1 "$1"; }

# _fieldwork_msg_followups_stderr <next> <doc>
_fieldwork_msg_followups_stderr() {
  [ -n "$1" ] && printf '  %s %s\n' "$(_fieldwork_msg_bold 'Next:')" "$1" >&2
  [ -n "$2" ] && printf '  %s %s\n' "$(_fieldwork_msg_bold 'See:')" "$2" >&2
  return 0
}

# fieldwork_die MESSAGE [NEXT_STEP] [DOC_POINTER]: print to stderr, exit 1.
fieldwork_die() {
  printf '%s %s\n' "$(_fieldwork_msg_red 'Error:')" "$1" >&2
  _fieldwork_msg_followups_stderr "${2:-}" "${3:-}"
  exit 1
}

# fieldwork_warn MESSAGE [NEXT_STEP] [DOC_POINTER]: print to stderr, return 0.
fieldwork_warn() {
  printf '%s %s\n' "$(_fieldwork_msg_yellow 'Warning:')" "$1" >&2
  _fieldwork_msg_followups_stderr "${2:-}" "${3:-}"
  return 0
}

# fieldwork_hint NEXT_STEP [DOC_POINTER]: guidance to stdout, return 0.
fieldwork_hint() {
  local next="${1:-}" doc="${2:-}"
  [ -n "$next" ] && printf '  %s %s\n' "$(_fieldwork_msg_bold 'Next:')" "$(_fieldwork_msg_cyan "$next")"
  [ -n "$doc" ] && printf '  %s %s\n' "$(_fieldwork_msg_bold 'See:')" "$doc"
  return 0
}
