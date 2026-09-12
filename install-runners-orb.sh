#!/usr/bin/env bash
# install-runners-orb.sh — copy this repo into the OrbStack CI machine and
# register runners. Run on the Mac. REGTOKEN is forwarded through OrbStack
# (ORBENV) and is never written to disk.
#
#     export REGTOKEN="$(gh api --method POST repos/OWNER/REPO/actions/runners/registration-token --jq .token)"
#     ./install-runners-orb.sh
#
# If REGTOKEN is unset, this script fetches one from GITHUB_URL via gh.
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
[ -f "$script_dir/lib/github-target.sh" ] || {
  echo "missing $script_dir/lib/github-target.sh" >&2
  exit 1
}
. "$script_dir/lib/github-target.sh"
reject_persisted_github_credentials "$script_dir/config.env"
[ -f "$script_dir/config.env" ] && . "$script_dir/config.env"

github_target_init

RUNNER_USER="${RUNNER_USER:-deploy}"
RUNNER_COUNT="${RUNNER_COUNT:-1}"
RUNNER_NAME_PREFIX="${RUNNER_NAME_PREFIX:-little-ci-${GITHUB_TARGET//\//-}}"
ORB_MACHINE="${ORB_MACHINE:-$RUNNER_NAME_PREFIX}"
RUNNER_HOME="${RUNNER_HOME:-/home/${RUNNER_USER}}"
remote_repo_dir="$RUNNER_HOME/little-ci"

if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
  echo "install-runners-orb.sh requires an Apple Silicon Mac (Darwin arm64)" >&2
  exit 1
fi
[[ "$RUNNER_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || {
  echo "RUNNER_USER is not a valid Unix account name (got '$RUNNER_USER')" >&2
  exit 1
}
[[ "$RUNNER_COUNT" =~ ^[1-9][0-9]*$ ]] || {
  echo "RUNNER_COUNT must be a positive integer (got '$RUNNER_COUNT')" >&2
  exit 1
}
[[ "$ORB_MACHINE" =~ ^[A-Za-z0-9._-]+$ ]] || {
  echo "ORB_MACHINE may contain only letters, numbers, dots, underscores, and hyphens" >&2
  exit 1
}
[[ "$RUNNER_HOME" = /* && "$RUNNER_HOME" != / ]] || {
  echo "RUNNER_HOME must be an absolute, non-root path (got '$RUNNER_HOME')" >&2
  exit 1
}

if [ -z "${REGTOKEN:-}" ]; then
  command -v gh >/dev/null || { echo "gh not on PATH and REGTOKEN unset" >&2; exit 1; }
  REGTOKEN="$(gh api --method POST "$GITHUB_API_TARGET/actions/runners/registration-token" --jq .token)"
fi
: "${REGTOKEN:?REGTOKEN is empty}"

command -v orbctl >/dev/null || { echo "orbctl not on PATH" >&2; exit 1; }
orbctl start "$ORB_MACHINE" >/dev/null

machine_arch="$(orbctl run -m "$ORB_MACHINE" uname -m)"
case "$machine_arch" in
  arm64|aarch64) ;;
  *)
    echo "OrbStack machine '$ORB_MACHINE' must use arm64 Linux (found '$machine_arch')" >&2
    exit 1
    ;;
esac

echo "== copying repo to $ORB_MACHINE:$remote_repo_dir =="
orbctl run -m "$ORB_MACHINE" -u "$RUNNER_USER" mkdir -p "$remote_repo_dir"
tarball="$(mktemp /tmp/little-ci.XXXXXX.tar.gz)"
cleanup() {
  rm -f -- "$tarball"
}
trap cleanup EXIT
tar -C "$script_dir" --exclude .git --exclude 'actions-runner*' --exclude '*.tar.gz' -czf "$tarball" .
orbctl run -m "$ORB_MACHINE" -u "$RUNNER_USER" tar -xzf - -C "$remote_repo_dir" < "$tarball"
rm -f -- "$tarball"
trap - EXIT

echo "== install-runners.sh on $ORB_MACHINE =="
export REGTOKEN
ORBENV=REGTOKEN orbctl run -m "$ORB_MACHINE" -u "$RUNNER_USER" \
  bash -c 'cd "$1" && RUNNER_HOME="$2" RUNNER_ARCH=linux-arm64 SKIP_SERVICE_INSTALL=1 ./install-runners.sh' \
  bash "$remote_repo_dir" "$RUNNER_HOME"

echo "== installing runner services =="
for runner_number in $(seq 1 "$RUNNER_COUNT"); do
  runner_dir="$RUNNER_HOME/actions-runner-$runner_number"
  orbctl run -m "$ORB_MACHINE" -u root bash -c \
    'set -e; cd "$1"; if [ ! -f .service ]; then ./svc.sh install "$2"; fi; ./svc.sh start' \
    bash "$runner_dir" "$RUNNER_USER"
done

echo "== services =="
orbctl run -m "$ORB_MACHINE" -u root systemctl list-units 'actions.runner.*' --no-pager --type=service || true
echo "Next: ./check-runners.sh"
