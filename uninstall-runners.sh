#!/usr/bin/env bash
# Unregister and remove only the Little-CI runners selected by name or index.
# Run on Linux as RUNNER_USER or root. A short-lived GitHub remove token is
# required; it is consumed from REMOVETOKEN and is never written to disk.
set -euo pipefail

if ! declare -F github_target_init >/dev/null 2>&1; then
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  [ -f "$script_dir/lib/github-target.sh" ] || {
    echo "missing $script_dir/lib/github-target.sh" >&2
    exit 1
  }
  . "$script_dir/lib/github-target.sh"
  reject_persisted_github_credentials "$script_dir/config.env"
  [ -f "$script_dir/config.env" ] && . "$script_dir/config.env"
fi

usage() {
  cat <<'EOF'
Usage:
  REMOVETOKEN=... ./uninstall-runners.sh --all --confirm
  REMOVETOKEN=... ./uninstall-runners.sh --prune --confirm
  REMOVETOKEN=... ./uninstall-runners.sh --runner NAME --confirm

--all          Remove every local runner whose target and name match this fleet.
--prune        Remove only matching runners numbered above RUNNER_COUNT.
--runner NAME  Remove one exact runner from this fleet.
--confirm      Required acknowledgement for any removal.
EOF
}

mode=""
requested_runner=""
confirmed=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --all|--prune)
      [ -z "$mode" ] || { echo "choose exactly one removal mode" >&2; exit 2; }
      mode="${1#--}"
      ;;
    --runner)
      [ -z "$mode" ] || { echo "choose exactly one removal mode" >&2; exit 2; }
      [ "$#" -ge 2 ] || { echo "--runner requires a name" >&2; exit 2; }
      mode="runner"
      requested_runner="$2"
      shift
      ;;
    --confirm) confirmed=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

[ -n "$mode" ] || { echo "choose --all, --prune, or --runner NAME" >&2; usage >&2; exit 2; }
[ "$confirmed" = true ] || { echo "refusing removal without --confirm" >&2; exit 2; }
: "${REMOVETOKEN:?REMOVETOKEN env required — use a short-lived GitHub runner remove token}"

github_target_init
RUNNER_COUNT="${RUNNER_COUNT:-1}"
RUNNER_USER="${RUNNER_USER:-$(id -un)}"
if [ -z "${RUNNER_HOME:-}" ]; then
  RUNNER_HOME="$(getent passwd "$RUNNER_USER" 2>/dev/null | cut -d: -f6 || true)"
fi

RUNNER_NAME_PREFIX="${RUNNER_NAME_PREFIX:-little-ci-${GITHUB_TARGET//\//-}}"
case "$RUNNER_NAME_PREFIX" in ''|*[!A-Za-z0-9._-]*) echo "RUNNER_NAME_PREFIX contains unsupported characters" >&2; exit 2 ;; esac
case "$RUNNER_COUNT" in ''|*[!0-9]*) echo "RUNNER_COUNT must be a positive integer" >&2; exit 2 ;; esac
[ "$RUNNER_COUNT" -ge 1 ] || { echo "RUNNER_COUNT must be at least 1" >&2; exit 2; }
[ -n "$RUNNER_HOME" ] || { echo "could not determine RUNNER_HOME for $RUNNER_USER" >&2; exit 2; }
case "$RUNNER_HOME" in /*) ;; *) echo "RUNNER_HOME must be an absolute path" >&2; exit 2 ;; esac
[ "$RUNNER_HOME" != / ] || { echo "RUNNER_HOME must not be /" >&2; exit 2; }
[ -d "$RUNNER_HOME" ] || { echo "RUNNER_HOME does not exist: $RUNNER_HOME" >&2; exit 2; }
RUNNER_HOME="$(cd "$RUNNER_HOME" && pwd -P)"
[ "$RUNNER_HOME" != / ] || { echo "RUNNER_HOME must not resolve to /" >&2; exit 2; }

runner_index() {
  local runner_name="$1"
  local suffix
  case "$runner_name" in
    "$RUNNER_NAME_PREFIX"-*) suffix="${runner_name#"$RUNNER_NAME_PREFIX"-}" ;;
    *) return 1 ;;
  esac
  case "$suffix" in ''|*[!0-9]*) return 1 ;; esac
  [ "$suffix" -ge 1 ] || return 1
  printf '%s\n' "$suffix"
}

is_selected() {
  local runner_name="$1"
  local index
  index="$(runner_index "$runner_name")" || return 1
  case "$mode" in
    all) return 0 ;;
    prune) [ "$index" -gt "$RUNNER_COUNT" ] ;;
    runner) [ "$runner_name" = "$requested_runner" ] ;;
  esac
}

if [ "$mode" = runner ] && ! runner_index "$requested_runner" >/dev/null; then
  echo "--runner must be an exact ${RUNNER_NAME_PREFIX}-N name" >&2
  exit 2
fi

run_privileged() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

run_as_runner() {
  if [ "$(id -un)" = "$RUNNER_USER" ]; then
    "$@"
  elif [ "$(id -u)" -eq 0 ]; then
    runuser -u "$RUNNER_USER" -- env HOME="$RUNNER_HOME" "$@"
  else
    echo "run as $RUNNER_USER or root" >&2
    return 1
  fi
}

removed=0
found=0
failures=0
for runner_dir in "$RUNNER_HOME"/actions-runner-*; do
  [ -d "$runner_dir" ] || continue
  [ ! -L "$runner_dir" ] || { echo "SKIP: refusing symlinked runner directory $runner_dir"; continue; }
  directory_number="${runner_dir#"$RUNNER_HOME"/actions-runner-}"
  case "$directory_number" in ''|*[!0-9]*) continue ;; esac
  [ "$directory_number" -ge 1 ] || continue
  runner_name=""
  configured_url=""

  if [ -f "$runner_dir/.runner" ]; then
    runner_metadata="$(python3 -c '
import json, sys
with open(sys.argv[1], encoding="utf-8-sig") as stream:
    settings = json.load(stream)
print("%s\t%s" % (settings.get("agentName", ""), settings.get("gitHubUrl", "")))
' "$runner_dir/.runner")" || { echo "WARN: unreadable metadata in $runner_dir; skipping" >&2; failures=$((failures + 1)); continue; }
    runner_name="${runner_metadata%%$'\t'*}"
    configured_url="${runner_metadata#*$'\t'}"
    configured_url="${configured_url%/}"
    if [ "$configured_url" != "$GITHUB_URL" ]; then
      echo "SKIP: $runner_dir belongs to $configured_url"
      continue
    fi
  elif [ -f "$runner_dir/.service" ]; then
    runner_number="${runner_dir##*-}"
    case "$runner_number" in ''|*[!0-9]*) continue ;; esac
    runner_name="${RUNNER_NAME_PREFIX}-${runner_number}"
    expected_service="actions.runner.${GITHUB_TARGET//\//-}.${runner_name}.service"
    if [ "$(cat "$runner_dir/.service")" != "$expected_service" ]; then
      echo "SKIP: $runner_dir has an unrecognized service registration"
      continue
    fi
  else
    continue
  fi

  runner_index "$runner_name" >/dev/null || { echo "SKIP: $runner_dir has non-fleet name $runner_name"; continue; }
  registered_number="$(runner_index "$runner_name")"
  if [ "$registered_number" != "$directory_number" ]; then
    echo "SKIP: $runner_dir contains mismatched runner name $runner_name"
    continue
  fi
  is_selected "$runner_name" || continue
  found=$((found + 1))
  echo "== removing local runner $runner_name ($runner_dir) =="

  if [ -f "$runner_dir/.service" ]; then
    if ! (cd "$runner_dir" && run_privileged ./svc.sh uninstall); then
      echo "ERROR: could not uninstall the service for $runner_name" >&2
      failures=$((failures + 1))
      continue
    fi
  fi
  if [ -f "$runner_dir/.runner" ]; then
    if ! (cd "$runner_dir" && run_as_runner ./config.sh remove --token "$REMOVETOKEN"); then
      echo "ERROR: could not unregister $runner_name from GitHub" >&2
      failures=$((failures + 1))
      continue
    fi
  fi
  if ! run_privileged rm -rf -- "$runner_dir"; then
    echo "ERROR: could not remove $runner_dir" >&2
    failures=$((failures + 1))
    continue
  fi
  removed=$((removed + 1))
done

if [ "$found" -eq 0 ]; then
  echo "No selected local runners found. The Mac wrapper will still check for stale GitHub registrations."
fi
echo "Local removal complete: $removed removed, $failures failed."
[ "$failures" -eq 0 ]
