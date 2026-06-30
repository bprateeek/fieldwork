#!/usr/bin/env bash
# Sourced by bin/fieldwork. Do not execute directly.
#
# The control-plane config object: the single place that resolves how this
# Fieldwork client talks to its VPS (host, user, projects/state root, default
# branch, forge) and under which identity (profile). Today there is one
# identity; the [profile.<name>] layer is shaped so more can be added without a
# rewrite (the managed multi-tenant pivot).
#
# Precedence, per field, lowest to highest:
#   hardcoded default  <  flat top-level key  <  [profile.<name>] key  <  env var
# A flat fieldwork.toml (no sections) is the implicit "default" profile, so
# existing configs resolve exactly as before.

_fieldwork_config_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/scripts/fieldwork-project.sh
source "$_fieldwork_config_dir/../scripts/fieldwork-project.sh"

# Prints `key=value` lines for one section of a config file.
#   want=""              -> top-level keys (the flat / "default" profile)
#   want="profile.NAME"  -> keys under a [profile.NAME] header
# Values keep the existing tiny-parser semantics: trimmed, one optional layer of
# surrounding double quotes stripped. Sections and complex TOML are ignored.
_fieldwork_config_scan() {
  local file="$1" want="$2" cur="" line key value
  while IFS= read -r line; do
    case "$line" in
      ''|\#*) continue ;;
      \[*\]*)
        cur="$(printf '%s' "$line" | sed 's/^\[//; s/\].*$//; s/[[:space:]]//g; s/"//g')"
        continue ;;
    esac
    [ "$cur" = "$want" ] || continue
    case "$line" in
      *=*) ;;
      *) continue ;;
    esac
    key="$(printf '%s' "${line%%=*}" | sed 's/[[:space:]]//g')"
    value="$(printf '%s' "${line#*=}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^"//; s/"$//')"
    [ -n "$key" ] || continue
    printf '%s=%s\n' "$key" "$value"
  done < "$file"
}

# Assigns the resolved value to the named variable unless the environment
# already provides a non-empty value (env wins, matching the documented
# behavior). Order within the file layer: default < flat < profile.
_fieldwork_config_resolve() {
  local var="$1" def="$2" flat="$3" prof="$4"
  if [ -n "${!var:-}" ]; then
    return 0
  fi
  local val="$def"
  [ -n "$flat" ] && val="$flat"
  [ -n "$prof" ] && val="$prof"
  printf -v "$var" '%s' "$val"
}

fieldwork_load_config() {
  # Hardcoded defaults (the lowest-precedence layer).
  local def_ssh_host="fieldwork-vps"
  local def_remote_user="fieldwork"
  local def_projects_dir="/home/fieldwork/projects"
  local def_default_branch="main"
  local def_notify_provider="ntfy"
  local def_forge="github"
  local def_gitlab_api="https://gitlab.com/api/v4"

  local flat_ssh_host="" flat_remote_user="" flat_projects_dir=""
  local flat_default_branch="" flat_notify_provider="" flat_forge=""
  local flat_default_profile="" flat_gitlab_api="" flat_gitlab_ca_bundle=""
  local flat_commit_name="" flat_commit_email=""
  local prof_ssh_host="" prof_remote_user="" prof_projects_dir=""
  local prof_default_branch="" prof_notify_provider="" prof_forge=""
  local prof_gitlab_api="" prof_gitlab_ca_bundle="" prof_commit_name="" prof_commit_email=""

  local cfg="${FIELDWORK_CONFIG:-}"
  if [ -z "$cfg" ]; then
    if [ -f "./fieldwork.toml" ]; then
      cfg="./fieldwork.toml"
    elif [ -f "$HOME/.config/fieldwork/config.toml" ]; then
      cfg="$HOME/.config/fieldwork/config.toml"
    fi
  fi
  [ -n "$cfg" ] && [ -f "$cfg" ] || cfg=""

  local k v
  if [ -n "$cfg" ]; then
    while IFS='=' read -r k v; do
      case "$k" in
        ssh_host) flat_ssh_host="$v" ;;
        remote_user) flat_remote_user="$v" ;;
        projects_dir) flat_projects_dir="$v" ;;
        default_branch) flat_default_branch="$v" ;;
        notify_provider) flat_notify_provider="$v" ;;
        forge) flat_forge="$v" ;;
        gitlab_api) flat_gitlab_api="$v" ;;
        gitlab_ca_bundle) flat_gitlab_ca_bundle="$v" ;;
        commit_name) flat_commit_name="$v" ;;
        commit_email) flat_commit_email="$v" ;;
        default_profile) flat_default_profile="$v" ;;
      esac
    done < <(_fieldwork_config_scan "$cfg" "")
  fi

  # Profile selection: env FIELDWORK_PROFILE > file default_profile > "default".
  local profile="${FIELDWORK_PROFILE:-}"
  if [ -z "$profile" ]; then
    profile="${flat_default_profile:-default}"
  fi

  if [ -n "$cfg" ] && [ "$profile" != "default" ]; then
    local found=0
    while IFS='=' read -r k v; do
      found=1
      case "$k" in
        ssh_host) prof_ssh_host="$v" ;;
        remote_user) prof_remote_user="$v" ;;
        projects_dir) prof_projects_dir="$v" ;;
        default_branch) prof_default_branch="$v" ;;
        notify_provider) prof_notify_provider="$v" ;;
        forge) prof_forge="$v" ;;
        gitlab_api) prof_gitlab_api="$v" ;;
        gitlab_ca_bundle) prof_gitlab_ca_bundle="$v" ;;
        commit_name) prof_commit_name="$v" ;;
        commit_email) prof_commit_email="$v" ;;
      esac
    done < <(_fieldwork_config_scan "$cfg" "profile.$profile")
    if [ "$found" = "0" ]; then
      printf '[fieldwork] warning: profile "%s" not found in %s; using default values\n' \
        "$profile" "$cfg" >&2
    fi
  fi

  _fieldwork_config_resolve FIELDWORK_SSH_HOST "$def_ssh_host" "$flat_ssh_host" "$prof_ssh_host"
  _fieldwork_config_resolve FIELDWORK_REMOTE_USER "$def_remote_user" "$flat_remote_user" "$prof_remote_user"
  _fieldwork_config_resolve FIELDWORK_PROJECTS_DIR "$def_projects_dir" "$flat_projects_dir" "$prof_projects_dir"
  _fieldwork_config_resolve FIELDWORK_DEFAULT_BRANCH "$def_default_branch" "$flat_default_branch" "$prof_default_branch"
  _fieldwork_config_resolve FIELDWORK_NOTIFY_PROVIDER "$def_notify_provider" "$flat_notify_provider" "$prof_notify_provider"
  _fieldwork_config_resolve FIELDWORK_FORGE "$def_forge" "$flat_forge" "$prof_forge"
  _fieldwork_config_resolve FIELDWORK_GITLAB_API "$def_gitlab_api" "$flat_gitlab_api" "$prof_gitlab_api"
  _fieldwork_config_resolve FIELDWORK_GITLAB_CA_BUNDLE_LOCAL "" "$flat_gitlab_ca_bundle" "$prof_gitlab_ca_bundle"
  _fieldwork_config_resolve FIELDWORK_COMMIT_NAME "" "$flat_commit_name" "$prof_commit_name"
  _fieldwork_config_resolve FIELDWORK_COMMIT_EMAIL "" "$flat_commit_email" "$prof_commit_email"

  # Identity is the resolved profile name; env already won above.
  if [ -z "${FIELDWORK_PROFILE:-}" ]; then
    FIELDWORK_PROFILE="$profile"
  fi
}
