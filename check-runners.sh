#!/usr/bin/env bash
# check-runners.sh — health check for this Little-CI fleet only.
#   exit 0  GREEN — every expected fleet runner is online with required labels
#   exit 1  RED   — an expected runner is missing, offline, or missing labels
#   exit 2  DARK  — could not read the runners API (gh not authed / no GH_TOKEN)
#
# Needs gh authenticated with repository Administration read access or
# organization Self-hosted runners read access. Reads no secrets of its own.
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
[ -f "$script_dir/lib/github-target.sh" ] || {
  echo "check-runners = DARK — missing $script_dir/lib/github-target.sh"
  exit 2
}
. "$script_dir/lib/github-target.sh"
reject_persisted_github_credentials "$script_dir/config.env" || exit 2
[ -f "$script_dir/config.env" ] && . "$script_dir/config.env"

if ! github_target_init; then
  echo "check-runners = DARK — invalid GitHub target configuration"
  exit 2
fi
if ! github_fleet_init; then
  echo "check-runners = DARK — invalid fleet configuration"
  exit 2
fi

EXPECTED="${EXPECTED_RUNNERS:-${RUNNER_COUNT:-1}}"
RUNNER_LABELS="${RUNNER_LABELS:-little-ci}"
expected_arch_label=""
[[ "$EXPECTED" =~ ^[1-9][0-9]*$ ]] || {
  echo "check-runners = DARK — EXPECTED_RUNNERS must be a positive integer (got '$EXPECTED')"
  exit 2
}
github_validate_runner_labels "$RUNNER_LABELS" "RUNNER_LABELS" || {
  echo "check-runners = DARK — invalid configured runner labels"
  exit 2
}
github_validate_runner_label "${RUNNER_NAME_PREFIX}-$EXPECTED" "expected runner name label" || {
  echo "check-runners = DARK — invalid expected runner label"
  exit 2
}
if [ -n "${RUNNER_ARCH:-}" ]; then
  case "$RUNNER_ARCH" in
    linux-arm64|linux-x64) expected_arch_label="${RUNNER_ARCH#linux-}" ;;
    *)
      echo "check-runners = DARK — RUNNER_ARCH must be linux-arm64 or linux-x64 (got '$RUNNER_ARCH')"
      exit 2
      ;;
  esac
fi

if ! command -v gh >/dev/null; then
  echo "check-runners = DARK — gh is not on PATH"
  exit 2
fi
if ! command -v python3 >/dev/null; then
  echo "check-runners = DARK — python3 is not on PATH"
  exit 2
fi

if ! api_pages_json="$(gh api --paginate --slurp "$GITHUB_API_TARGET/actions/runners?per_page=100" 2>/dev/null)"; then
  echo "check-runners = DARK — could not read runners API for $GITHUB_SCOPE $GITHUB_TARGET (gh auth / GH_TOKEN?)"
  exit 2
fi

health_result="$(printf '%s' "$api_pages_json" | python3 -c '
import json
import re
import sys

expected = int(sys.argv[1])
prefix = sys.argv[2]
configured_labels = sys.argv[3]
expected_arch_label = sys.argv[4]
pages = json.load(sys.stdin)
if isinstance(pages, dict):
    pages = [pages]
runners = [runner for page in pages for runner in page.get("runners", [])]
by_name = {runner.get("name"): runner for runner in runners}

online = 0
registered = 0
details = []
expected_names = {f"{prefix}-{number}" for number in range(1, expected + 1)}
configured_required_labels = [label.casefold() for label in configured_labels.split(",")]
for number in range(1, expected + 1):
    name = f"{prefix}-{number}"
    runner = by_name.get(name)
    if runner is None:
        details.append(f"{name}=missing")
        continue
    registered += 1
    labels = {str(label.get("name", "")).casefold() for label in runner.get("labels", [])}
    required_labels = configured_required_labels + ["little-ci", prefix.casefold(), name.casefold()]
    if expected_arch_label:
        required_labels.append(expected_arch_label.casefold())
    missing_labels = []
    for label in required_labels:
        if label not in labels and label not in missing_labels:
            missing_labels.append(label)
    if not expected_arch_label and not labels.intersection({"arm64", "x64"}):
        missing_labels.append("arm64-or-x64")
    if missing_labels:
        details.append(f"{name}=missing(labels:" + ",".join(missing_labels) + ")")
        continue
    status = runner.get("status", "unknown")
    busy = "(busy)" if runner.get("busy") else ""
    details.append(f"{name}={status}{busy}")
    online += status == "online"

fleet_pattern = re.compile(rf"^{re.escape(prefix)}-[1-9][0-9]*$")
for runner in runners:
    name = runner.get("name", "")
    labels = {str(label.get("name", "")).casefold() for label in runner.get("labels", [])}
    if name not in expected_names and fleet_pattern.fullmatch(name) and prefix.casefold() in labels:
        status = runner.get("status", "unknown")
        busy = "(busy)" if runner.get("busy") else ""
        details.append(f"extra:{name}={status}{busy}")

verdict = "GREEN" if online == expected else "RED"
print(f"{verdict}|{online}|{registered}|" + " | ".join(details))
' "$EXPECTED" "$RUNNER_NAME_PREFIX" "$RUNNER_LABELS" "$expected_arch_label")" || {
  echo "check-runners = DARK — runners API returned invalid data"
  exit 2
}

verdict="${health_result%%|*}"; health_fields="${health_result#*|}"
online="${health_fields%%|*}"; health_fields="${health_fields#*|}"
registered="${health_fields%%|*}"; detail="${health_fields#*|}"

if [ "$verdict" = GREEN ]; then
  echo "check-runners = GREEN — $online/$EXPECTED online, $registered registered  [$detail]"
  exit 0
fi
echo "check-runners = RED — only $online/$EXPECTED online, $registered registered  [$detail]"
echo "  missing labels: drain, exactly uninstall, and reinstall the affected runner"
echo "  offline service: sudo systemctl enable --now '<runner-service>.service'"
exit 1
