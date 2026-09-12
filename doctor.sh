#!/usr/bin/env bash
# Read-only Mac-side diagnostics for one OrbStack Little-CI fleet.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
failures=0
warnings=0

pass() { printf 'PASS: %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*"; warnings=$((warnings + 1)); }
fail() { printf 'FAIL: %s\n' "$*"; failures=$((failures + 1)); }

for required_library in github-target.sh orbstack-machine.sh; do
  [ -f "$script_dir/lib/$required_library" ] || fail "missing $script_dir/lib/$required_library"
done
if [ "$failures" -ne 0 ]; then
  printf '\nLittle-CI doctor: %d failure(s), %d warning(s)\n' "$failures" "$warnings"
  exit 1
fi

. "$script_dir/lib/github-target.sh"
. "$script_dir/lib/orbstack-machine.sh"
if reject_persisted_github_credentials "$script_dir/config.env"; then
  [ -f "$script_dir/config.env" ] && . "$script_dir/config.env"
else
  fail "config.env contains persisted GitHub credentials"
fi

target_is_valid=false
if github_target_init && github_fleet_init; then
  target_is_valid=true
else
  fail "GitHub target or fleet configuration is invalid"
fi

RUNNER_COUNT="${RUNNER_COUNT:-1}"
RUNNER_VERSION="${RUNNER_VERSION:-2.337.0}"
RUNNER_LABELS="${RUNNER_LABELS:-little-ci}"
RUNNER_USER="${RUNNER_USER:-deploy}"
RUNNER_HOME="${RUNNER_HOME:-/home/${RUNNER_USER}}"
RUNNER_NAME_PREFIX="${RUNNER_NAME_PREFIX:-invalid-fleet}"
if [ -z "${ORB_MACHINE:-}" ] && [[ "$RUNNER_NAME_PREFIX" =~ [A-Z] ]]; then
  fail "ORB_MACHINE is required when RUNNER_NAME_PREFIX contains uppercase letters"
fi
ORB_MACHINE="${ORB_MACHINE:-$RUNNER_NAME_PREFIX}"
ORB_CPUS="${ORB_CPUS:-2}"
ORB_MEMORY="${ORB_MEMORY:-4G}"
ORB_DISK="${ORB_DISK:-48G}"

[[ "$RUNNER_COUNT" =~ ^[1-9][0-9]*$ ]] || { fail "RUNNER_COUNT must be a positive integer"; RUNNER_COUNT=1; }
[[ "$RUNNER_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || fail "RUNNER_USER must be a valid Linux username"
[ "$RUNNER_USER" != root ] || fail "RUNNER_USER must be a non-root account"
[[ "$RUNNER_HOME" = /* && "$RUNNER_HOME" != / && "$RUNNER_HOME" != *[[:space:]]* ]] || fail "RUNNER_HOME must be an absolute, non-root path without whitespace"
[[ "$ORB_MACHINE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "ORB_MACHINE contains unsupported characters"
[[ "$ORB_CPUS" =~ ^[1-9][0-9]*$ ]] || fail "ORB_CPUS must be a positive integer"
orbstack_memory_size_to_mib "$ORB_MEMORY" >/dev/null 2>&1 || fail "ORB_MEMORY has an unsupported size"
orbstack_disk_size_to_bytes "$ORB_DISK" >/dev/null 2>&1 || fail "ORB_DISK has an unsupported size"

if [ "$(uname -s 2>/dev/null || true)" = Darwin ] && [ "$(uname -m 2>/dev/null || true)" = arm64 ]; then
  pass "host is an Apple Silicon Mac"
else
  fail "doctor.sh requires an Apple Silicon Mac (Darwin arm64)"
fi
for required_command in orbctl python3; do
  command -v "$required_command" >/dev/null 2>&1 || fail "$required_command is not on PATH"
done

machine_running=false
if command -v orbctl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  orb_version="$(orbctl version 2>/dev/null | sed -n '1p')"
  [ -n "$orb_version" ] && pass "OrbStack CLI available ($orb_version)" || fail "OrbStack CLI did not report a version"
  orb_status="$(orbctl status 2>/dev/null || true)"
  [ "$orb_status" = Running ] && pass "OrbStack is running" || fail "OrbStack is not running (${orb_status:-unknown})"

  machine_state="$(orbctl info "$ORB_MACHINE" --format json 2>/dev/null | python3 -c '
import json, sys
print(json.load(sys.stdin).get("record", {}).get("state", ""))
' 2>/dev/null || true)"
  if [ -z "$machine_state" ]; then
    fail "OrbStack machine not found or unreadable: $ORB_MACHINE"
  else
    if [ "$machine_state" = running ]; then
      machine_running=true
      pass "machine $ORB_MACHINE is running"
    else
      fail "machine $ORB_MACHINE is $machine_state; start it before checking guest ownership and services"
    fi
    if machine_validation_error="$(orbstack_validate_machine 1 2>&1)"; then
      pass "machine security, Ubuntu arm64 image, user, mounts, SSH forwarding, and resources match config.env"
    else
      fail "$machine_validation_error"
    fi
  fi

  pause_in_sleep="$(orbctl config get power.pause_in_sleep 2>/dev/null || true)"
  [ "$pause_in_sleep" = false ] && pass "OrbStack will not intentionally pause the VM during host sleep" || fail "power.pause_in_sleep is ${pause_in_sleep:-unknown}; OrbStack will pause the VM during host sleep"
  [ "$pause_in_sleep" != false ] || warn "macOS can still suspend execution; prevent host sleep when runners must remain continuously available"
  start_at_login="$(orbctl config get app.start_at_login 2>/dev/null || true)"
  [ "$start_at_login" = true ] && pass "OrbStack starts at login" || warn "app.start_at_login is ${start_at_login:-unknown}; runners may stay offline after login"
fi

if [ "$machine_running" = true ] && [ "$target_is_valid" = true ]; then
  if machine_identity_error="$(orbstack_verify_machine_identity 2>&1)"; then
    pass "root-owned /etc/little-ci/identity matches this fleet"
  else
    fail "$machine_identity_error"
  fi

  guest_facts="$(orbctl run -m "$ORB_MACHINE" -u root bash -lc '
set -u
. /etc/os-release
printf "%s\t%s\t%s\t%s\n" "$ID" "$VERSION_ID" "$(uname -m)" "$(systemctl is-active docker 2>/dev/null || true)"
' 2>/dev/null || true)"
  if [ -z "$guest_facts" ]; then
    fail "could not inspect the Linux guest"
  else
    IFS=$'\t' read -r guest_id guest_version guest_architecture docker_state <<< "$guest_facts"
    [ "$guest_id" = ubuntu ] && [ "$guest_version" = 24.04 ] && pass "guest reports Ubuntu 24.04" || fail "guest reports ${guest_id:-unknown} ${guest_version:-unknown}"
    case "$guest_architecture" in aarch64|arm64) pass "guest reports Apple Silicon architecture ($guest_architecture)" ;; *) fail "guest architecture is ${guest_architecture:-unknown}" ;; esac
    [ "$docker_state" = active ] && pass "Docker service is active" || fail "Docker service is ${docker_state:-unknown}"
  fi

  docker_version="$(orbctl run -m "$ORB_MACHINE" -u "$RUNNER_USER" docker info --format '{{.ServerVersion}}' 2>/dev/null || true)"
  [ -n "$docker_version" ] && pass "runner user can reach Docker $docker_version" || fail "$RUNNER_USER cannot reach the Docker daemon"

  for runner_number in $(seq 1 "$RUNNER_COUNT"); do
    runner_name="${RUNNER_NAME_PREFIX}-${runner_number}"
    runner_dir="$RUNNER_HOME/actions-runner-${runner_number}"
    if runner_registration="$(orbctl run -m "$ORB_MACHINE" -u "$RUNNER_USER" python3 -c '
import json, sys
with open(sys.argv[1], encoding="utf-8-sig") as stream:
    runner = json.load(stream)
runner_name = runner.get("agentName")
github_url = runner.get("gitHubUrl")
if not isinstance(runner_name, str) or not runner_name or not isinstance(github_url, str) or not github_url:
    raise SystemExit(".runner is missing a valid agentName or gitHubUrl")
if any(character in runner_name or character in github_url for character in "\t\r\n"):
    raise SystemExit(".runner identity fields contain control characters")
print("%s\t%s" % (runner_name, github_url.rstrip("/")))
' "$runner_dir/.runner" 2>/dev/null)"; then
      [ "$runner_registration" = "$runner_name"$'\t'"$GITHUB_URL" ] && pass "$runner_name local registration matches its fleet and GitHub target" || fail "$runner_name local registration is owned by another runner or GitHub target"
    else
      fail "$runner_name local .runner metadata is unreadable or malformed; reinstall this runner"
    fi

    runner_service="$(orbctl run -m "$ORB_MACHINE" -u root bash -c 'test -f "$1" && cat "$1"' bash "$runner_dir/.service" 2>/dev/null || true)"
    if [[ ! "$runner_service" =~ ^actions\.runner\.[A-Za-z0-9._@-]+\.service$ ]]; then
      fail "$runner_name has no valid authoritative .service identity"
    else
      scratch_dir="/scratch/$RUNNER_NAME_PREFIX/$runner_number"
      if orbctl run -m "$ORB_MACHINE" -u root bash -s -- "$runner_service" "$runner_dir" "$RUNNER_USER" "$scratch_dir" <<'VERIFY_SERVICE' >/dev/null 2>&1
set -euo pipefail
service_name="$1"; runner_dir="$2"; runner_user="$3"; scratch_dir="$4"
service_file="/etc/systemd/system/$service_name"
drop_in_file="/etc/systemd/system/${service_name}.d/zz-little-ci-scratch.conf"
test -f "$service_file"
grep -Fqx -- "ExecStart=$runner_dir/runsvc.sh" "$service_file"
grep -Fqx -- "User=$runner_user" "$service_file"
grep -Fqx -- "WorkingDirectory=$runner_dir" "$service_file"
test -f "$drop_in_file"
grep -Fqx -- "Environment=TMPDIR=$scratch_dir" "$drop_in_file"
grep -Fqx -- "Environment=TMP=$scratch_dir" "$drop_in_file"
VERIFY_SERVICE
      then
        pass "$runner_name service and Little-CI scratch drop-in have matching ownership"
      else
        fail "$runner_name service or scratch drop-in does not match its runner identity"
      fi
      if orbctl run -m "$ORB_MACHINE" -u root systemctl is-active --quiet "$runner_service" 2>/dev/null; then
        pass "$runner_name service is active ($runner_service)"
      else
        fail "$runner_name service is not active ($runner_service)"
      fi
    fi

    installed_runner_version="$(orbctl run -m "$ORB_MACHINE" -u "$RUNNER_USER" bash -c 'cd "$1" && ./bin/Runner.Listener --version' bash "$runner_dir" 2>/dev/null || true)"
    if [ -z "$installed_runner_version" ]; then
      fail "$runner_name installed version could not be read"
    elif [ "$installed_runner_version" = "$RUNNER_VERSION" ]; then
      pass "$runner_name installed runner version is $installed_runner_version"
    else
      warn "$runner_name installed runner version is $installed_runner_version (bootstrap version is $RUNNER_VERSION)"
    fi
  done
fi

api_pages_json=""
if [ "$target_is_valid" != true ]; then
  fail "GitHub target is invalid; visibility check skipped"
elif ! command -v gh >/dev/null 2>&1; then
  fail "gh is not on PATH"
elif ! command -v python3 >/dev/null 2>&1; then
  fail "python3 is not on PATH"
elif ! api_pages_json="$(gh api --paginate --slurp "${GITHUB_API_TARGET}/actions/runners?per_page=100" 2>/dev/null)"; then
  fail "GitHub runners are not visible through gh for $GITHUB_TARGET"
else
  github_report="$(printf '%s' "$api_pages_json" | python3 -c '
import json, re, sys
prefix, count, configured_labels = sys.argv[1], int(sys.argv[2]), sys.argv[3]
pages = json.load(sys.stdin)
runners = [runner for page in pages for runner in page.get("runners", [])]
by_name = {runner.get("name"): runner for runner in runners}
pattern = re.compile(r"^" + re.escape(prefix) + r"-([1-9][0-9]*)$")
configured_required_labels = [label.strip().casefold() for label in configured_labels.split(",") if label.strip()]
for index in range(1, count + 1):
    name = "%s-%d" % (prefix, index)
    runner = by_name.get(name)
    if runner is None:
        print("FAIL\t%s is not registered with GitHub" % name)
        continue
    labels = {str(label.get("name", "")).casefold() for label in runner.get("labels", [])}
    required_labels = configured_required_labels + ["little-ci", prefix.casefold(), name.casefold(), "arm64"]
    missing_labels = []
    for label in required_labels:
        if label not in labels and label not in missing_labels:
            missing_labels.append(label)
    if missing_labels:
        print("FAIL\t%s is missing required labels %s; reinstall this runner to reconcile labels" % (name, ",".join(missing_labels)))
    elif runner.get("status") != "online":
        print("FAIL\t%s is %s on GitHub" % (name, runner.get("status", "unknown")))
    else:
        busy = " and busy" if runner.get("busy") else ""
        print("PASS\t%s is online%s on GitHub" % (name, busy))
for runner in runners:
    match = pattern.match(runner.get("name", ""))
    labels = {str(label.get("name", "")).casefold() for label in runner.get("labels", [])}
    if match and prefix.casefold() in labels and int(match.group(1)) > count:
        print("WARN\t%s is outside RUNNER_COUNT=%d (%s)" % (runner["name"], count, runner.get("status", "unknown")))
' "$RUNNER_NAME_PREFIX" "$RUNNER_COUNT" "$RUNNER_LABELS" 2>/dev/null || true)"
  if [ -z "$github_report" ]; then
    fail "could not parse the GitHub runner response"
  else
    while IFS=$'\t' read -r severity diagnostic_message; do
      case "$severity" in PASS) pass "$diagnostic_message" ;; WARN) warn "$diagnostic_message" ;; FAIL) fail "$diagnostic_message" ;; esac
    done <<< "$github_report"
  fi
fi

if [ "$target_is_valid" = true ] && [ "$GITHUB_SCOPE" = organization ] && [ -n "$api_pages_json" ]; then
  runner_groups_json="$(gh api --paginate --slurp "/orgs/${GITHUB_TARGET}/actions/runner-groups?per_page=100" 2>/dev/null || true)"
  runner_group_id="$(printf '%s' "$runner_groups_json" | python3 -c '
import json, sys
group_name = sys.argv[1]
matches = [group for page in json.load(sys.stdin) for group in page.get("runner_groups", []) if group.get("name") == group_name]
if len(matches) == 1:
    print(matches[0]["id"])
' "$RUNNER_GROUP" 2>/dev/null || true)"
  if [ -z "$runner_group_id" ]; then
    fail "organization runner group '$RUNNER_GROUP' is missing, ambiguous, or inaccessible"
  else
    group_runners_json="$(gh api --paginate --slurp "/orgs/${GITHUB_TARGET}/actions/runner-groups/${runner_group_id}/runners?per_page=100" 2>/dev/null || true)"
    group_report="$(python3 -c '
import json, sys
prefix, count = sys.argv[1], int(sys.argv[2])
all_pages = json.loads(sys.argv[3])
group_pages = json.loads(sys.argv[4])
all_by_name = {runner.get("name"): runner for page in all_pages for runner in page.get("runners", [])}
group_by_name = {runner.get("name"): runner for page in group_pages for runner in page.get("runners", [])}
for index in range(1, count + 1):
    name = "%s-%d" % (prefix, index)
    registered = all_by_name.get(name)
    grouped = group_by_name.get(name)
    if registered and grouped and registered.get("id") == grouped.get("id"):
        print("PASS\t%s belongs to the configured organization runner group" % name)
    else:
        print("FAIL\t%s is not a member of the configured organization runner group" % name)
' "$RUNNER_NAME_PREFIX" "$RUNNER_COUNT" "$api_pages_json" "$group_runners_json" 2>/dev/null || true)"
    if [ -z "$group_report" ]; then
      fail "organization runner group membership is unreadable"
    else
      while IFS=$'\t' read -r severity diagnostic_message; do
        case "$severity" in PASS) pass "$diagnostic_message" ;; FAIL) fail "$diagnostic_message" ;; esac
      done <<< "$group_report"
    fi
  fi
fi

printf '\nLittle-CI doctor: %d failure(s), %d warning(s)\n' "$failures" "$warnings"
[ "$failures" -eq 0 ]
