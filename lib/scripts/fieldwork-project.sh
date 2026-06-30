#!/usr/bin/env bash
# Shared project-path and slug helpers for forge-aware client scripts.

fieldwork_project_valid() {
  local project="${1:-}"
  local segment
  case "$project" in
    */*) ;;
    *) return 1 ;;
  esac
  [ "${project#/}" = "$project" ] || return 1
  [ "${project%/}" = "$project" ] || return 1
  IFS='/' read -r -a _fw_project_segments <<<"$project"
  [ "${#_fw_project_segments[@]}" -ge 2 ] || return 1
  for segment in "${_fw_project_segments[@]}"; do
    [[ "$segment" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
  done
  return 0
}

fieldwork_project_leaf() {
  local project="${1:-}"
  project="${project%.git}"
  printf '%s\n' "${project##*/}"
}

fieldwork_slug_valid() {
  [[ "${1:-}" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]]
}

fieldwork_slug_from_project() {
  local project="${1:-}"
  local leaf slug
  fieldwork_project_valid "$project" || return 1
  leaf="$(fieldwork_project_leaf "$project")"
  slug="$(printf '%s' "$leaf" | tr '[:upper:]' '[:lower:]' | sed -E 's/[._]+/-/g; s/[^a-z0-9-]+/-/g; s/-+/-/g; s/^-+//; s/-+$//')"
  slug="${slug:0:31}"
  slug="$(printf '%s' "$slug" | sed -E 's/-+$//')"
  fieldwork_slug_valid "$slug" || return 1
  printf '%s\n' "$slug"
}

fieldwork_gitlab_api_host() {
  local api="${1:-${FIELDWORK_GITLAB_API:-https://gitlab.com/api/v4}}"
  python3 - "$api" <<'PY'
import sys
from urllib.parse import urlparse
api = sys.argv[1].strip() or "https://gitlab.com/api/v4"
p = urlparse(api)
if p.scheme != "https" or not p.hostname or p.username or p.password or p.query or p.fragment or p.path.rstrip("/") != "/api/v4":
    raise SystemExit(1)
host = p.hostname.lower()
if p.port is not None:
    host = f"{host}:{p.port}"
print(host)
PY
}

fieldwork_gitlab_api_bare_host() {
  local host
  host="$(fieldwork_gitlab_api_host "$@")" || return 1
  printf '%s\n' "${host%%:*}"
}
