#!/usr/bin/env bash
# Mac-side Little-CI teardown. This streams the Linux-side script over stdin;
# the GitHub remove token travels through OrbStack's environment bridge and is
# never written to disk. The machine is kept unless --delete-machine is
# explicitly combined with --all and --confirm.
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
[ -f "$script_dir/lib/github-target.sh" ] || {
    echo "missing $script_dir/lib/github-target.sh" >&2
    exit 1
}
. "$script_dir/lib/github-target.sh"
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
--delete-machine  Permanently delete the OrbStack machine after --all succeeds.
--confirm         Required acknowledgement for any removal.

Without --delete-machine, the OrbStack machine and non-runner data are retained.
EOF
}

mode=""
requested_runner=""
confirmed=false
delete_machine=false
forwarded_args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --all|--prune)
      [ -z "$mode" ] || { echo "choose exactly one removal mode" >&2; exit 2; }
      mode="${1#--}"
      forwarded_args+=("$1")
      ;;
    --runner)
      [ -z "$mode" ] || { echo "choose exactly one removal mode" >&2; exit 2; }
      [ "$#" -ge 2 ] || { echo "--runner requires a name" >&2; exit 2; }
      mode="runner"
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

[ -n "$mode" ] || { echo "choose --all, --prune, or --runner NAME" >&2; usage >&2; exit 2; }
[ "$confirmed" = true ] || { echo "refusing removal without --confirm" >&2; exit 2; }
if [ "$delete_machine" = true ] && [ "$mode" != all ]; then
  echo "--delete-machine is allowed only with --all" >&2
  exit 2
fi

github_target_init
RUNNER_COUNT="${RUNNER_COUNT:-1}"
RUNNER_USER="${RUNNER_USER:-deploy}"
RUNNER_HOME="${RUNNER_HOME:-/home/${RUNNER_USER}}"
RUNNER_NAME_PREFIX="${RUNNER_NAME_PREFIX:-little-ci-${GITHUB_TARGET//\//-}}"
ORB_MACHINE="${ORB_MACHINE:-$RUNNER_NAME_PREFIX}"
case "$RUNNER_NAME_PREFIX" in ''|*[!A-Za-z0-9._-]*) echo "RUNNER_NAME_PREFIX contains unsupported characters" >&2; exit 2 ;; esac
case "$RUNNER_COUNT" in ''|*[!0-9]*) echo "RUNNER_COUNT must be a positive integer" >&2; exit 2 ;; esac
[ "$RUNNER_COUNT" -ge 1 ] || { echo "RUNNER_COUNT must be at least 1" >&2; exit 2; }
[[ "$RUNNER_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || { echo "RUNNER_USER is not a valid Unix account name" >&2; exit 2; }
[[ "$ORB_MACHINE" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "ORB_MACHINE contains unsupported characters" >&2; exit 2; }
if [ "$mode" = runner ]; then
  case "$requested_runner" in "$RUNNER_NAME_PREFIX"-[1-9]* ) ;; *) echo "--runner must be an exact ${RUNNER_NAME_PREFIX}-N name" >&2; exit 2 ;; esac
  runner_suffix="${requested_runner#"$RUNNER_NAME_PREFIX"-}"
  case "$runner_suffix" in *[!0-9]*) echo "--runner must end in a positive integer" >&2; exit 2 ;; esac
fi

command -v orbctl >/dev/null || { echo "orbctl not on PATH — install OrbStack" >&2; exit 1; }
command -v gh >/dev/null || { echo "gh not on PATH — install and authenticate GitHub CLI" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 not on PATH" >&2; exit 1; }
orbctl list -q | grep -Fqx "$ORB_MACHINE" || { echo "OrbStack machine not found: $ORB_MACHINE" >&2; exit 1; }

echo "== checking that selected GitHub runners are idle =="
preflight_json="$(gh api --paginate --slurp "${GITHUB_API_TARGET}/actions/runners?per_page=100")"
busy_runners="$(printf '%s' "$preflight_json" | python3 -c '
import json, re, sys

prefix, mode, count, exact_name = sys.argv[1:]
pages = json.load(sys.stdin)
pattern = re.compile(r"^" + re.escape(prefix) + r"-([1-9][0-9]*)$")
for page in pages:
    for runner in page.get("runners", []):
        match = pattern.match(runner.get("name", ""))
        if not match:
            continue
        index = int(match.group(1))
        selected = mode == "all" or (mode == "prune" and index > int(count)) or (mode == "runner" and runner["name"] == exact_name)
        if selected and runner.get("busy"):
            print(runner["name"])
' "$RUNNER_NAME_PREFIX" "$mode" "$RUNNER_COUNT" "$requested_runner")"
if [ -n "$busy_runners" ]; then
  echo "refusing to interrupt busy runner(s):" >&2
  while IFS= read -r busy_runner; do
    [ -n "$busy_runner" ] && echo "  $busy_runner" >&2
  done <<< "$busy_runners"
  exit 1
fi

echo "== starting OrbStack machine $ORB_MACHINE =="
orbctl start "$ORB_MACHINE" >/dev/null

echo "== fetching short-lived GitHub runner remove token =="
REMOVETOKEN="$(gh api --method POST "${GITHUB_API_TARGET}/actions/runners/remove-token" --jq .token)"
: "${REMOVETOKEN:?GitHub returned an empty runner remove token}"
export REMOVETOKEN GITHUB_SCOPE GITHUB_URL RUNNER_COUNT RUNNER_NAME_PREFIX RUNNER_USER RUNNER_HOME
trap 'unset REMOVETOKEN' EXIT

echo "== unregistering selected local runners =="
ORBENV=REMOVETOKEN:GITHUB_SCOPE:GITHUB_URL:RUNNER_COUNT:RUNNER_NAME_PREFIX:RUNNER_USER:RUNNER_HOME \
  orbctl run -m "$ORB_MACHINE" -u root bash -s -- "${forwarded_args[@]}" \
  < <(cat "$script_dir/lib/github-target.sh" "$script_dir/uninstall-runners.sh")
unset REMOVETOKEN
trap - EXIT

echo "== checking for stale offline GitHub registrations =="
runners_json="$(gh api --paginate --slurp "${GITHUB_API_TARGET}/actions/runners?per_page=100")"
stale_rows="$(printf '%s' "$runners_json" | python3 -c '
import json, re, sys

prefix, mode, count, exact_name = sys.argv[1:]
pages = json.load(sys.stdin)
pattern = re.compile(r"^" + re.escape(prefix) + r"-([1-9][0-9]*)$")
for page in pages:
    for runner in page.get("runners", []):
        match = pattern.match(runner.get("name", ""))
        labels = {label.get("name") for label in runner.get("labels", [])}
        if not match or prefix not in labels:
            continue
        index = int(match.group(1))
        selected = mode == "all" or (mode == "prune" and index > int(count)) or (mode == "runner" and runner["name"] == exact_name)
        if selected:
            print("%s\t%s\t%s" % (runner["id"], runner["name"], runner.get("status", "unknown")))
' "$RUNNER_NAME_PREFIX" "$mode" "$RUNNER_COUNT" "$requested_runner")"

remaining=0
if [ -z "$stale_rows" ]; then
  echo "No selected GitHub registrations remain."
else
  while IFS=$'\t' read -r runner_id runner_name runner_status; do
    [ -n "$runner_id" ] || continue
    if [ "$runner_status" != offline ]; then
      echo "ERROR: refusing to force-delete active runner $runner_name ($runner_status)" >&2
      remaining=$((remaining + 1))
      continue
    fi
    echo "Deleting stale offline registration: $runner_name"
    gh api --method DELETE "${GITHUB_API_TARGET}/actions/runners/${runner_id}" --silent
  done <<< "$stale_rows"
fi

if [ "$remaining" -ne 0 ]; then
  echo "$remaining selected runner(s) remain active; the OrbStack machine was retained." >&2
  exit 1
fi

if [ "$delete_machine" = true ]; then
  echo "== permanently deleting OrbStack machine $ORB_MACHINE =="
  orbctl delete --force "$ORB_MACHINE"
else
  echo "OrbStack machine retained: $ORB_MACHINE"
fi
