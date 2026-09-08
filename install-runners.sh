#!/usr/bin/env bash
# install-runners.sh — download, register, and service-install N GitHub Actions
# self-hosted runners on this box. Idempotent: an already-configured runner is
# skipped, so re-running only fills in what's missing.
#
# Needs a SHORT-LIVED registration token in REGTOKEN. Get one with the gh CLI:
#     gh api -X POST repos/OWNER/REPO/actions/runners/registration-token --jq .token
# or from the web UI: repo/org Settings > Actions > Runners > New self-hosted runner.
# The token expires in ~1 hour and is NOT a personal access token — never commit it.
#
# Run as the RUNNER_USER (the account the services will run as; it needs
# passwordless sudo, because svc.sh installs a systemd unit):
#     REGTOKEN=xxxxx ./install-runners.sh
#
# Run provision-box.sh FIRST so swap/scratch/TMPDIR are in place before start.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
[ -f "$here/config.env" ] && . "$here/config.env"

: "${REGTOKEN:?REGTOKEN env required — short-lived runner registration token (see header)}"
GITHUB_URL="${GITHUB_URL:?set GITHUB_URL in config.env}"
RUNNER_COUNT="${RUNNER_COUNT:-3}"
RUNNER_VERSION="${RUNNER_VERSION:-2.336.0}"
RUNNER_NAME_PREFIX="${RUNNER_NAME_PREFIX:-ci}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted}"
RUNNER_USER="${RUNNER_USER:-$(whoami)}"
RUNNER_HOME="${RUNNER_HOME:-$HOME}"

TAR="actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
cd "$RUNNER_HOME"
[ -f "$TAR" ] || curl -fsSL -o "$TAR" \
  "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${TAR}"

for n in $(seq 1 "$RUNNER_COUNT"); do
  dir="$RUNNER_HOME/actions-runner-$n"
  name="${RUNNER_NAME_PREFIX}-$n"
  if [ -f "$dir/.runner" ]; then echo "[$name] already configured, skipping"; continue; fi
  mkdir -p "$dir"; tar xzf "$TAR" -C "$dir"
  ( cd "$dir"
    ./config.sh --unattended --url "$GITHUB_URL" --token "$REGTOKEN" \
      --name "$name" --labels "${RUNNER_LABELS},${RUNNER_NAME_PREFIX}-$n" \
      --work _work --replace
    sudo ./svc.sh install "$RUNNER_USER"
    sudo ./svc.sh start
  )
  echo "[$name] configured + service started"
done

echo "== runner services =="
systemctl list-units 'actions.runner.*' --no-pager --type=service | grep -E 'actions.runner' || true
