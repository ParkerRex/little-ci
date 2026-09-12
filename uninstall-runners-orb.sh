#!/usr/bin/env bash
# Ownership-gated Mac-side teardown for one OrbStack Little-CI fleet.
set -euo pipefail
set +x

script_dir="$(cd "$(dirname "$0")" && pwd)"
for required_script in \
  "$script_dir/lib/github-target.sh" \
  "$script_dir/lib/orbstack-machine.sh" \
  "$script_dir/uninstall-runners.sh"; do
  [ -f "$required_script" ] && [ ! -L "$required_script" ] && [ -r "$required_script" ] || {
    echo "required teardown script is missing, unreadable, or symlinked: $required_script" >&2
    exit 1
  }
done
. "$script_dir/lib/github-target.sh"
. "$script_dir/lib/orbstack-machine.sh"
reject_persisted_github_credentials "$script_dir/config.env"
[ -f "$script_dir/config.env" ] && . "$script_dir/config.env"

usage() {
  cat <<'EOF'
Usage:
  ./uninstall-runners-orb.sh --all --confirm [--delete-machine]
  ./uninstall-runners-orb.sh --prune --confirm
  ./uninstall-runners-orb.sh --runner NAME --confirm

--all             Remove every runner in this Little-CI fleet.
--prune           Remove runners numbered above RUNNER_COUNT.
--runner NAME     Remove one exact runner from this fleet.
--delete-machine  Permanently delete the verified OrbStack machine after --all.
--confirm         Required acknowledgement for any removal.

The machine is retained unless --delete-machine is explicitly supplied.
EOF
}

runner_is_selected_python='import json, re, sys
prefix, mode, count, exact_name = sys.argv[1:]
pattern = re.compile(r"^" + re.escape(prefix) + r"-([1-9][0-9]*)$")
for page in json.load(sys.stdin):
    for runner in page.get("runners", []):
        match = pattern.fullmatch(runner.get("name", ""))
        if not match:
            continue
        index = int(match.group(1))
        selected = mode == "all" or (mode == "prune" and index > int(count)) or (mode == "runner" and runner["name"] == exact_name)
        if selected:
            labels = {str(label.get("name", "")).casefold() for label in runner.get("labels", [])}
            has_fleet_label = prefix.casefold() in labels
            print("%s\t%s\t%s\t%s\t%s" % (runner["id"], runner["name"], runner.get("status", "unknown"), str(bool(runner.get("busy"))).lower(), str(has_fleet_label).lower()))'

removal_mode=""
requested_runner=""
confirmed=false
delete_machine=false
forwarded_args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --all|--prune)
      [ -z "$removal_mode" ] || { echo "choose exactly one removal mode" >&2; exit 2; }
      removal_mode="${1#--}"
      forwarded_args+=("$1")
      ;;
    --runner)
      [ -z "$removal_mode" ] || { echo "choose exactly one removal mode" >&2; exit 2; }
      [ "$#" -ge 2 ] || { echo "--runner requires a name" >&2; exit 2; }
      removal_mode="runner"
      requested_runner="$2"
      forwarded_args+=("$1" "$2")
      shift
      ;;
    --confirm) confirmed=true; forwarded_args+=("$1") ;;
    --delete-machine) delete_machine=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

[ -n "$removal_mode" ] || { echo "choose --all, --prune, or --runner NAME" >&2; exit 2; }
[ "$confirmed" = true ] || { echo "refusing removal without --confirm" >&2; exit 2; }
if [ "$delete_machine" = true ] && [ "$removal_mode" != all ]; then
  echo "--delete-machine is allowed only with --all" >&2
  exit 2
fi

github_target_init
github_fleet_init
RUNNER_COUNT="${RUNNER_COUNT:-1}"
RUNNER_USER="${RUNNER_USER:-deploy}"
RUNNER_HOME="${RUNNER_HOME:-/home/${RUNNER_USER}}"
RUNNER_GROUP="${RUNNER_GROUP:-}"
if [ -z "${ORB_MACHINE:-}" ] && [[ "$RUNNER_NAME_PREFIX" =~ [A-Z] ]]; then
  echo "ORB_MACHINE is required when RUNNER_NAME_PREFIX contains uppercase letters" >&2
  exit 2
fi
ORB_MACHINE="${ORB_MACHINE:-$RUNNER_NAME_PREFIX}"

[[ "$RUNNER_COUNT" =~ ^[1-9][0-9]*$ ]] || { echo "RUNNER_COUNT must be a positive integer" >&2; exit 2; }
[[ "$RUNNER_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || { echo "RUNNER_USER must be a valid Linux username" >&2; exit 2; }
[ "$RUNNER_USER" != root ] || { echo "RUNNER_USER must be a non-root account" >&2; exit 2; }
[[ "$RUNNER_HOME" = /* && "$RUNNER_HOME" != / && "$RUNNER_HOME" != *[[:space:]]* ]] || { echo "RUNNER_HOME must be an absolute, non-root path without whitespace" >&2; exit 2; }
[[ "$ORB_MACHINE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo "ORB_MACHINE contains unsupported characters" >&2; exit 2; }
if [ "$removal_mode" = runner ]; then
  runner_suffix="${requested_runner#"$RUNNER_NAME_PREFIX"-}"
  [[ "$requested_runner" = "$RUNNER_NAME_PREFIX"-* && "$runner_suffix" =~ ^[1-9][0-9]*$ ]] || {
    echo "--runner must be an exact ${RUNNER_NAME_PREFIX}-N name" >&2
    exit 2
  }
fi

[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || { echo "uninstall-runners-orb.sh requires an Apple Silicon Mac" >&2; exit 1; }
for required_command in orbctl gh python3 mktemp; do
  command -v "$required_command" >/dev/null 2>&1 || { echo "$required_command is not on PATH" >&2; exit 1; }
done

guest_teardown_script="$(mktemp "${TMPDIR:-/tmp}/little-ci-uninstall.XXXXXX")"
cleanup_guest_teardown_script() {
  unset REMOVETOKEN 2>/dev/null || true
  rm -f -- "$guest_teardown_script"
}
trap cleanup_guest_teardown_script EXIT
trap 'exit 130' HUP INT TERM
chmod 600 "$guest_teardown_script"
if ! {
  cat "$script_dir/lib/github-target.sh" &&
  printf '\n' &&
  cat "$script_dir/uninstall-runners.sh"
} > "$guest_teardown_script"; then
  echo "could not assemble the guest teardown script" >&2
  exit 1
fi
bash -n "$guest_teardown_script" || { echo "assembled guest teardown script is invalid" >&2; exit 1; }

orbctl list -q | grep -Fqx "$ORB_MACHINE" || { echo "OrbStack machine not found: $ORB_MACHINE" >&2; exit 1; }

orbstack_validate_machine 0 || { echo "refusing teardown of an incompatible OrbStack machine" >&2; exit 1; }
orbctl start "$ORB_MACHINE" >/dev/null
orbstack_verify_machine_identity || { echo "refusing teardown without matching Little-CI ownership" >&2; exit 1; }

echo "== checking that selected GitHub runners are idle =="
if ! preflight_json="$(gh api --paginate --slurp "${GITHUB_API_TARGET}/actions/runners?per_page=100")"; then
  echo "could not read GitHub runners; refusing removal without a busy-state check" >&2
  exit 1
fi
if ! selected_rows="$(printf '%s' "$preflight_json" | python3 -c "$runner_is_selected_python" "$RUNNER_NAME_PREFIX" "$removal_mode" "$RUNNER_COUNT" "$requested_runner")"; then
  echo "GitHub returned unreadable runner state; refusing removal" >&2
  exit 1
fi
busy_runners="$(printf '%s\n' "$selected_rows" | awk -F '\t' '$4 == "true" { print $2 }')"
if [ -n "$busy_runners" ]; then
  echo "refusing to interrupt busy runner(s):" >&2
  printf '  %s\n' $busy_runners >&2
  exit 1
fi

echo "== fetching short-lived GitHub runner remove token =="
if ! REMOVETOKEN="$(gh api --method POST "${GITHUB_API_TARGET}/actions/runners/remove-token" --jq .token)"; then
  echo "could not obtain a GitHub runner remove token" >&2
  exit 1
fi
: "${REMOVETOKEN:?GitHub returned an empty runner remove token}"
export REMOVETOKEN GITHUB_SCOPE GITHUB_URL RUNNER_COUNT RUNNER_NAME_PREFIX RUNNER_USER RUNNER_HOME RUNNER_GROUP

echo "== unregistering selected local runners =="
local_removal_succeeded=true
if ! ORBENV=REMOVETOKEN:GITHUB_SCOPE:GITHUB_URL:RUNNER_COUNT:RUNNER_NAME_PREFIX:RUNNER_USER:RUNNER_HOME:RUNNER_GROUP \
  orbctl run -m "$ORB_MACHINE" -u root bash -s -- "${forwarded_args[@]}" \
  < "$guest_teardown_script"; then
  local_removal_succeeded=false
fi
unset REMOVETOKEN

report_remaining_state() {
  local recovery_args="--$removal_mode"
  [ "$removal_mode" != runner ] || recovery_args="--runner '$requested_runner'"
  echo "Remaining selected GitHub registrations:" >&2
  latest_runners_json="$(gh api --paginate --slurp "${GITHUB_API_TARGET}/actions/runners?per_page=100" 2>/dev/null || true)"
  if [ -n "$latest_runners_json" ]; then
    if remaining_github_rows="$(printf '%s' "$latest_runners_json" | python3 -c "$runner_is_selected_python" "$RUNNER_NAME_PREFIX" "$removal_mode" "$RUNNER_COUNT" "$requested_runner" 2>/dev/null)"; then
      if [ -n "$remaining_github_rows" ]; then
        printf '%s\n' "$remaining_github_rows" | awk -F '\t' '{ printf "  %s status=%s busy=%s\n", $2, $3, $4 }' >&2
      else
        echo "  none" >&2
      fi
    else
      echo "  unavailable (GitHub runner response was unreadable)" >&2
    fi
  else
    echo "  unavailable (gh API read failed)" >&2
  fi
  echo "Remaining selected local directories and services:" >&2
  orbctl run -m "$ORB_MACHINE" -u root bash -s -- "$RUNNER_HOME" "$RUNNER_NAME_PREFIX" "$removal_mode" "$RUNNER_COUNT" "$requested_runner" <<'GUEST_REPORT' >&2 || true
runner_home="$1"; prefix="$2"; mode="$3"; count="$4"; exact_name="$5"
for runner_dir in "$runner_home"/actions-runner-*; do
  [ -d "$runner_dir" ] || continue
  number="${runner_dir#"$runner_home"/actions-runner-}"
  [[ "$number" =~ ^[1-9][0-9]*$ ]] || continue
  name="$prefix-$number"
  selected=false
  case "$mode" in
    all) selected=true ;;
    prune) [ "$number" -gt "$count" ] && selected=true ;;
    runner) [ "$name" = "$exact_name" ] && selected=true ;;
  esac
  [ "$selected" = true ] || continue
  service="none"
  [ ! -f "$runner_dir/.service" ] || service="$(cat "$runner_dir/.service")"
  printf '  %s service=%s\n' "$runner_dir" "$service"
done
GUEST_REPORT
  echo "Recovery: rerun ./uninstall-runners-orb.sh $recovery_args --confirm after resolving the reported failure." >&2
}

if [ "$local_removal_succeeded" != true ]; then
  report_remaining_state
  exit 1
fi

echo "== checking for stale offline GitHub registrations =="
if ! runners_json="$(gh api --paginate --slurp "${GITHUB_API_TARGET}/actions/runners?per_page=100")"; then
  echo "ERROR: could not verify remaining GitHub registrations after local cleanup" >&2
  report_remaining_state
  exit 1
fi
if ! stale_rows="$(printf '%s' "$runners_json" | python3 -c "$runner_is_selected_python" "$RUNNER_NAME_PREFIX" "$removal_mode" "$RUNNER_COUNT" "$requested_runner")"; then
  echo "ERROR: GitHub returned unreadable runner state after local cleanup" >&2
  report_remaining_state
  exit 1
fi
remaining_count=0
if [ -z "$stale_rows" ]; then
  echo "No selected GitHub registrations remain."
else
  while IFS=$'\t' read -r runner_id runner_name runner_status runner_busy runner_has_fleet_label; do
    [ -n "$runner_id" ] || continue
    [ "$runner_has_fleet_label" = true ] || {
      echo "ERROR: refusing registration without fleet label: $runner_name" >&2
      remaining_count=$((remaining_count + 1))
      continue
    }
    if [ "$runner_status" != offline ] || [ "$runner_busy" = true ]; then
      echo "ERROR: refusing to force-delete active runner $runner_name (status=$runner_status busy=$runner_busy)" >&2
      remaining_count=$((remaining_count + 1))
      continue
    fi
    echo "Deleting stale offline registration: $runner_name"
    if ! gh api --method DELETE "${GITHUB_API_TARGET}/actions/runners/${runner_id}" --silent; then
      echo "ERROR: failed to delete stale GitHub registration $runner_name" >&2
      remaining_count=$((remaining_count + 1))
    fi
  done <<< "$stale_rows"
fi

if [ "$remaining_count" -ne 0 ]; then
  report_remaining_state
  exit 1
fi

if [ "$delete_machine" = true ]; then
  orbstack_validate_machine 0 || { echo "machine changed during teardown; refusing deletion" >&2; exit 1; }
  orbstack_verify_machine_identity || { echo "machine ownership changed during teardown; refusing deletion" >&2; exit 1; }
  echo "== permanently deleting verified OrbStack machine $ORB_MACHINE =="
  orbctl delete --force "$ORB_MACHINE"
else
  echo "OrbStack machine retained: $ORB_MACHINE"
fi
