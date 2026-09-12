#!/usr/bin/env bash
# Read-only Mac-side diagnostics for an OrbStack Little-CI fleet.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"

failures=0
warnings=0
pass() { printf 'PASS: %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*"; warnings=$((warnings + 1)); }
fail() { printf 'FAIL: %s\n' "$*"; failures=$((failures + 1)); }

[ -f "$script_dir/lib/github-target.sh" ] || {
  fail "missing $script_dir/lib/github-target.sh"
  printf '\nLittle-CI doctor: %d failure(s), %d warning(s)\n' "$failures" "$warnings"
  exit 1
}
. "$script_dir/lib/github-target.sh"
if reject_persisted_github_credentials "$script_dir/config.env"; then
  [ -f "$script_dir/config.env" ] && . "$script_dir/config.env"
else
  fail "config.env contains persisted GitHub credentials"
fi

RUNNER_COUNT="${RUNNER_COUNT:-1}"
RUNNER_VERSION="${RUNNER_VERSION:-2.337.0}"
RUNNER_USER="${RUNNER_USER:-deploy}"
RUNNER_HOME="${RUNNER_HOME:-/home/${RUNNER_USER}}"

if [ "$(uname -s 2>/dev/null || true)" = Darwin ] && [ "$(uname -m 2>/dev/null || true)" = arm64 ]; then
  pass "host is an Apple Silicon Mac"
else
  fail "doctor.sh requires an Apple Silicon Mac (Darwin arm64)"
fi

if github_target_init; then
  github_target="$GITHUB_TARGET"
  github_api_target="$GITHUB_API_TARGET"
else
  fail "GitHub target configuration is invalid"
  github_target=""
  github_api_target=""
fi
if [ -n "$github_target" ]; then
  RUNNER_NAME_PREFIX="${RUNNER_NAME_PREFIX:-little-ci-${github_target//\//-}}"
else
  RUNNER_NAME_PREFIX="${RUNNER_NAME_PREFIX:-little-ci-invalid-target}"
fi
ORB_MACHINE="${ORB_MACHINE:-$RUNNER_NAME_PREFIX}"
case "$RUNNER_NAME_PREFIX" in ''|*[!A-Za-z0-9._-]*) fail "RUNNER_NAME_PREFIX contains unsupported characters" ;; esac
case "$RUNNER_HOME" in /*) ;; *) fail "RUNNER_HOME must be an absolute path" ;; esac
[ "$RUNNER_HOME" != / ] || fail "RUNNER_HOME must not be /"
case "$RUNNER_COUNT" in ''|*[!0-9]*) fail "RUNNER_COUNT must be a positive integer"; RUNNER_COUNT=1 ;; esac
if [ "$RUNNER_COUNT" -lt 1 ]; then fail "RUNNER_COUNT must be at least 1"; RUNNER_COUNT=1; fi

if ! command -v orbctl >/dev/null 2>&1; then
  fail "orbctl is not on PATH"
  machine_running=false
else
  orb_version="$(orbctl version 2>/dev/null | sed -n '1p')"
  [ -n "$orb_version" ] && pass "OrbStack CLI available ($orb_version)" || fail "OrbStack CLI did not report a version"
  orb_status="$(orbctl status 2>/dev/null || true)"
  [ "$orb_status" = Running ] && pass "OrbStack is running" || fail "OrbStack is not running (${orb_status:-unknown})"

  machine_json="$(orbctl info "$ORB_MACHINE" -f json 2>/dev/null || true)"
  if [ -z "$machine_json" ]; then
    fail "OrbStack machine not found: $ORB_MACHINE"
    machine_running=false
  else
    machine_details="$(printf '%s' "$machine_json" | python3 -c '
import json, sys
machine_info = json.load(sys.stdin)["record"]
machine_image, machine_config = machine_info["image"], machine_info["config"]
machine_fields = [machine_info["state"], machine_image["distro"], machine_image["version"], machine_image["arch"], machine_config["isolated"], machine_config["isolate_network"], machine_config["forward_ssh_agent"], machine_config["cpu_limit"], machine_config["memory_limit_mib"], machine_config["disk_limit_bytes"], machine_config["default_username"]]
print("\t".join(str(field).lower() for field in machine_fields))
' 2>/dev/null || true)"
    if [ -z "$machine_details" ]; then
      fail "could not parse OrbStack machine settings"
      machine_running=false
    else
      IFS=$'\t' read -r machine_state machine_distro machine_version machine_arch machine_isolated machine_network_isolated machine_ssh_agent machine_cpus machine_memory machine_disk machine_user <<< "$machine_details"
      if [ "$machine_state" = running ]; then pass "machine $ORB_MACHINE is running"; machine_running=true; else fail "machine $ORB_MACHINE is $machine_state"; machine_running=false; fi
      [ "$machine_distro" = ubuntu ] && [ "$machine_version" = noble ] && pass "machine image is Ubuntu 24.04 (noble)" || fail "machine image is ${machine_distro}:${machine_version}, expected Ubuntu 24.04"
      [ "$machine_arch" = arm64 ] && pass "machine architecture is arm64" || fail "machine architecture is $machine_arch, expected arm64"
      [ "$machine_isolated" = true ] && pass "Mac filesystem integration is isolated" || fail "machine was not created with --isolated"
      [ "$machine_network_isolated" = true ] && pass "machine network is isolated from other OrbStack machines" || fail "machine was not created with --isolate-network"
      [ "$machine_ssh_agent" = false ] && pass "SSH agent forwarding is disabled" || fail "SSH agent forwarding is enabled"
      [ "$machine_user" = "$RUNNER_USER" ] && pass "default machine user is $RUNNER_USER" || warn "default machine user is $machine_user, configured runner user is $RUNNER_USER"
      pass "machine resources: ${machine_cpus} CPU, ${machine_memory} MiB RAM, ${machine_disk} bytes disk limit"
    fi
  fi

  pause_in_sleep="$(orbctl config get power.pause_in_sleep 2>/dev/null || true)"
  [ "$pause_in_sleep" = false ] && pass "OrbStack will not intentionally pause the VM during host sleep" || fail "power.pause_in_sleep is ${pause_in_sleep:-unknown}; OrbStack will pause the VM during host sleep"
  if [ "$pause_in_sleep" = false ]; then
    warn "macOS can still suspend execution; prevent host sleep when runners must remain continuously available"
  fi
  start_at_login="$(orbctl config get app.start_at_login 2>/dev/null || true)"
  [ "$start_at_login" = true ] && pass "OrbStack starts at login" || warn "app.start_at_login is ${start_at_login:-unknown}; runners may stay offline after login"
fi

if [ "${machine_running:-false}" = true ]; then
  guest_facts="$(orbctl run -m "$ORB_MACHINE" -u root bash -lc '
set -u
. /etc/os-release
printf "%s\t%s\t%s\t%s\n" "$ID" "$VERSION_ID" "$(uname -m)" "$(systemctl is-active docker 2>/dev/null || true)"
' 2>/dev/null || true)"
  if [ -z "$guest_facts" ]; then
    fail "could not inspect the Linux guest"
  else
    IFS=$'\t' read -r guest_id guest_version guest_arch docker_state <<< "$guest_facts"
    [ "$guest_id" = ubuntu ] && [ "$guest_version" = 24.04 ] && pass "guest reports Ubuntu 24.04" || fail "guest reports ${guest_id:-unknown} ${guest_version:-unknown}"
    case "$guest_arch" in aarch64|arm64) pass "guest reports Apple Silicon architecture ($guest_arch)" ;; *) fail "guest architecture is ${guest_arch:-unknown}" ;; esac
    [ "$docker_state" = active ] && pass "Docker service is active" || fail "Docker service is ${docker_state:-unknown}"
  fi

  docker_version="$(orbctl run -m "$ORB_MACHINE" -u "$RUNNER_USER" docker info --format '{{.ServerVersion}}' 2>/dev/null || true)"
  [ -n "$docker_version" ] && pass "runner user can reach Docker $docker_version" || fail "$RUNNER_USER cannot reach the Docker daemon"

  for runner_number in $(seq 1 "$RUNNER_COUNT"); do
    runner_name="${RUNNER_NAME_PREFIX}-${runner_number}"
    runner_dir="$RUNNER_HOME/actions-runner-${runner_number}"
    runner_service="$(orbctl run -m "$ORB_MACHINE" -u root bash -lc "test -f '$runner_dir/.service' && cat '$runner_dir/.service'" 2>/dev/null || true)"
    if [ -z "$runner_service" ]; then
      fail "$runner_name has no installed systemd service"
    elif orbctl run -m "$ORB_MACHINE" -u root systemctl is-active --quiet "$runner_service" 2>/dev/null; then
      pass "$runner_name service is active"
    else
      fail "$runner_name service is not active ($runner_service)"
    fi
    installed_runner_version="$(orbctl run -m "$ORB_MACHINE" -u "$RUNNER_USER" \
      bash -c 'cd "$1" && ./bin/Runner.Listener --version' bash "$runner_dir" 2>/dev/null || true)"
    if [ -z "$installed_runner_version" ]; then
      fail "$runner_name installed version could not be read"
    elif [ "$installed_runner_version" = "$RUNNER_VERSION" ]; then
      pass "$runner_name installed runner version is $installed_runner_version"
    else
      warn "$runner_name installed runner version is $installed_runner_version (bootstrap version is $RUNNER_VERSION)"
    fi
  done
fi

if [ -z "$github_api_target" ]; then
  fail "GitHub target is invalid; visibility check skipped"
elif ! command -v gh >/dev/null 2>&1; then
  fail "gh is not on PATH"
elif ! command -v python3 >/dev/null 2>&1; then
  fail "python3 is not on PATH"
else
  runners_json="$(gh api --paginate --slurp "${github_api_target}/actions/runners?per_page=100" 2>/dev/null || true)"
  if [ -z "$runners_json" ]; then
    fail "GitHub runners are not visible through gh for $github_target"
  else
    github_report="$(printf '%s' "$runners_json" | python3 -c '
import json, re, sys

prefix, count = sys.argv[1], int(sys.argv[2])
runners = [runner for page in json.load(sys.stdin) for runner in page.get("runners", [])]
by_name = {runner.get("name"): runner for runner in runners}
pattern = re.compile(r"^" + re.escape(prefix) + r"-([1-9][0-9]*)$")
for index in range(1, count + 1):
    name = "%s-%d" % (prefix, index)
    runner = by_name.get(name)
    if runner is None:
        print("FAIL\t%s is not registered with GitHub" % name)
        continue
    labels = {str(label.get("name", "")).casefold() for label in runner.get("labels", [])}
    if prefix.casefold() not in labels:
        print("FAIL\t%s is missing fleet label %s" % (name, prefix))
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
' "$RUNNER_NAME_PREFIX" "$RUNNER_COUNT" 2>/dev/null || true)"
    if [ -z "$github_report" ]; then
      fail "could not parse the GitHub runner response"
    else
      while IFS=$'\t' read -r severity diagnostic_message; do
        case "$severity" in PASS) pass "$diagnostic_message" ;; WARN) warn "$diagnostic_message" ;; FAIL) fail "$diagnostic_message" ;; esac
      done <<< "$github_report"
    fi
  fi
fi

printf '\nLittle-CI doctor: %d failure(s), %d warning(s)\n' "$failures" "$warnings"
[ "$failures" -eq 0 ]
