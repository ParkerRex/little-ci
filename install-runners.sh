#!/usr/bin/env bash
# install-runners.sh — download, register, and service-install N GitHub Actions
# self-hosted runners on this box. Idempotent: matching existing registrations
# are reused and their services are started.
#
# Needs a SHORT-LIVED registration token in REGTOKEN. Get one with the gh CLI:
#     gh api --method POST repos/OWNER/REPO/actions/runners/registration-token --jq .token
# or from the web UI: repo/org Settings > Actions > Runners > New self-hosted runner.
# The token expires in ~1 hour and is NOT a personal access token — never commit it.
#
# Run as the RUNNER_USER (the account the services will run as; it needs
# passwordless sudo, because svc.sh installs a systemd unit):
#     REGTOKEN=xxxxx ./install-runners.sh
#
# Run provision-box.sh FIRST so swap/scratch/TMPDIR are in place before start.
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
[ -f "$script_dir/lib/github-target.sh" ] || {
  echo "missing $script_dir/lib/github-target.sh" >&2
  exit 1
}

# Explicit environment overrides win over config.env for these execution-mode
# controls. The OrbStack wrapper relies on both guarantees.
runner_arch_override_set="${RUNNER_ARCH+x}"
runner_arch_override="${RUNNER_ARCH:-}"
skip_service_override_set="${SKIP_SERVICE_INSTALL+x}"
skip_service_override="${SKIP_SERVICE_INSTALL:-}"
runner_home_override_set="${RUNNER_HOME+x}"
runner_home_override="${RUNNER_HOME:-}"
. "$script_dir/lib/github-target.sh"
reject_persisted_github_credentials "$script_dir/config.env"
[ -f "$script_dir/config.env" ] && . "$script_dir/config.env"
[ -z "$runner_arch_override_set" ] || RUNNER_ARCH="$runner_arch_override"
[ -z "$skip_service_override_set" ] || SKIP_SERVICE_INSTALL="$skip_service_override"
[ -z "$runner_home_override_set" ] || RUNNER_HOME="$runner_home_override"

github_target_init
: "${REGTOKEN:?REGTOKEN env required — short-lived runner registration token (see header)}"

RUNNER_COUNT="${RUNNER_COUNT:-1}"
RUNNER_VERSION="${RUNNER_VERSION:-2.337.0}"
RUNNER_NAME_PREFIX="${RUNNER_NAME_PREFIX:-little-ci-${GITHUB_TARGET//\//-}}"
RUNNER_LABELS="${RUNNER_LABELS:-little-ci}"
RUNNER_GROUP="${RUNNER_GROUP:-}"
RUNNER_USER="${RUNNER_USER:-$(whoami)}"
RUNNER_HOME="${RUNNER_HOME:-$HOME}"
SKIP_SERVICE_INSTALL="${SKIP_SERVICE_INSTALL:-0}"

[[ "$RUNNER_COUNT" =~ ^[1-9][0-9]*$ ]] || {
  echo "RUNNER_COUNT must be a positive integer (got '$RUNNER_COUNT')" >&2
  exit 1
}
[[ "$RUNNER_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "RUNNER_VERSION must have the form N.N.N (got '$RUNNER_VERSION')" >&2
  exit 1
}
[[ "$RUNNER_NAME_PREFIX" =~ ^[A-Za-z0-9._-]+$ ]] || {
  echo "RUNNER_NAME_PREFIX may contain only letters, numbers, dots, underscores, and hyphens" >&2
  exit 1
}
[[ "$RUNNER_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || {
  echo "RUNNER_USER is not a valid Unix account name (got '$RUNNER_USER')" >&2
  exit 1
}
case "$SKIP_SERVICE_INSTALL" in
  0|1) ;;
  *)
    echo "SKIP_SERVICE_INSTALL must be 0 or 1 (got '$SKIP_SERVICE_INSTALL')" >&2
    exit 1
    ;;
esac
[ "${RUNNER_HOME#/}" != "$RUNNER_HOME" ] || {
  echo "RUNNER_HOME must be an absolute path (got '$RUNNER_HOME')" >&2
  exit 1
}
command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }
command -v tar >/dev/null || { echo "tar is required" >&2; exit 1; }

# linux-x64 on amd64 boxes; linux-arm64 on Apple Silicon VMs / Ampere.
# Override with RUNNER_ARCH if uname is lying (rare).
if [ -z "${RUNNER_ARCH:-}" ]; then
  case "$(uname -m)" in
    x86_64|amd64) RUNNER_ARCH=linux-x64 ;;
    aarch64|arm64) RUNNER_ARCH=linux-arm64 ;;
    *)
      echo "unsupported uname -m: $(uname -m) — set RUNNER_ARCH=linux-x64 or linux-arm64" >&2
      exit 1
      ;;
  esac
fi
case "$RUNNER_ARCH" in
  linux-x64|linux-arm64) ;;
  *)
    echo "RUNNER_ARCH must be linux-x64 or linux-arm64 (got '$RUNNER_ARCH')" >&2
    exit 1
    ;;
esac
arch_label="${RUNNER_ARCH#linux-}"
case ",${RUNNER_LABELS}," in
  *,little-ci,*) configured_labels="$RUNNER_LABELS" ;;
  *) configured_labels="${RUNNER_LABELS},little-ci" ;;
esac

ensure_runner_service() {
  local runner_dir="$1"

  if [ "$SKIP_SERVICE_INSTALL" = 1 ]; then
    return
  fi

  (
    cd "$runner_dir"
    if [ ! -f .service ]; then
      sudo ./svc.sh install "$RUNNER_USER"
    fi
    sudo ./svc.sh start
  )
}

validate_existing_runner() {
  local runner_file="$1"
  local expected_name="$2"

  python3 - "$runner_file" "$expected_name" "$GITHUB_URL" <<'PY'
import json
import sys

runner_file, expected_name, expected_url = sys.argv[1:]
try:
    with open(runner_file, encoding="utf-8-sig") as handle:
        runner = json.load(handle)
except (OSError, json.JSONDecodeError) as error:
    print(f"invalid .runner file: {error}", file=sys.stderr)
    raise SystemExit(1)

checks = (
    ("name", runner.get("agentName"), expected_name),
    ("GitHub URL", str(runner.get("gitHubUrl", "")).rstrip("/"), expected_url),
    ("work folder", runner.get("workFolder"), "_work"),
)
for field, actual, expected in checks:
    if actual != expected:
        print(f"existing runner {field} mismatch: expected '{expected}', found '{actual}'", file=sys.stderr)
        raise SystemExit(1)
PY
}

runner_archive_name="actions-runner-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"
echo "== installing $RUNNER_COUNT $RUNNER_ARCH runner(s) v${RUNNER_VERSION} into $RUNNER_HOME =="
cd "$RUNNER_HOME"
[ -f "$runner_archive_name" ] || curl -fsSL -o "$runner_archive_name" \
  "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${runner_archive_name}"

for runner_number in $(seq 1 "$RUNNER_COUNT"); do
  runner_dir="$RUNNER_HOME/actions-runner-$runner_number"
  runner_name="${RUNNER_NAME_PREFIX}-$runner_number"
  if [ -f "$runner_dir/.runner" ]; then
    validate_existing_runner "$runner_dir/.runner" "$runner_name" || {
      echo "[$runner_name] refusing to reuse mismatched registration in $runner_dir" >&2
      exit 1
    }
    echo "[$runner_name] existing registration matches"
    ensure_runner_service "$runner_dir"
    continue
  fi

  mkdir -p "$runner_dir"
  tar xzf "$runner_archive_name" -C "$runner_dir"
  config_args=(
    --unattended
    --url "$GITHUB_URL"
    --token "$REGTOKEN"
    --name "$runner_name"
    --labels "${configured_labels},${RUNNER_NAME_PREFIX},${runner_name},${arch_label}"
    --work _work
    --replace
  )
  if [ -n "$RUNNER_GROUP" ]; then
    config_args+=(--runnergroup "$RUNNER_GROUP")
  fi
  (cd "$runner_dir" && ./config.sh "${config_args[@]}")
  ensure_runner_service "$runner_dir"
  if [ "$SKIP_SERVICE_INSTALL" = 1 ]; then
    echo "[$runner_name] configured; service installation deferred"
  else
    echo "[$runner_name] configured + service started"
  fi
done

if [ "$SKIP_SERVICE_INSTALL" = 0 ]; then
  echo "== runner services =="
  systemctl list-units 'actions.runner.*' --no-pager --type=service | grep -E 'actions.runner' || true
fi
