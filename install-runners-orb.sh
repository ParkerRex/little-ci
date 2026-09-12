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
set +x

script_dir="$(cd "$(dirname "$0")" && pwd)"
[ -f "$script_dir/lib/github-target.sh" ] || {
  echo "missing $script_dir/lib/github-target.sh" >&2
  exit 1
}
[ -f "$script_dir/lib/orbstack-machine.sh" ] || {
  echo "missing $script_dir/lib/orbstack-machine.sh" >&2
  exit 1
}
. "$script_dir/lib/github-target.sh"
. "$script_dir/lib/orbstack-machine.sh"
reject_persisted_github_credentials "$script_dir/config.env"
[ -f "$script_dir/config.env" ] && . "$script_dir/config.env"

github_target_init
github_fleet_init

RUNNER_USER="${RUNNER_USER:-deploy}"
RUNNER_COUNT="${RUNNER_COUNT:-1}"
RUNNER_LABELS="${RUNNER_LABELS:-little-ci}"
RUNNER_GROUP="${RUNNER_GROUP:-}"
RUNNER_VERSION="${RUNNER_VERSION:-2.337.0}"
if [ -z "${ORB_MACHINE:-}" ] && [[ "$RUNNER_NAME_PREFIX" =~ [A-Z] ]]; then
  echo "ORB_MACHINE is required when an explicit RUNNER_NAME_PREFIX contains uppercase letters" >&2
  exit 1
fi
ORB_MACHINE="${ORB_MACHINE:-$RUNNER_NAME_PREFIX}"
RUNNER_HOME="${RUNNER_HOME:-/home/${RUNNER_USER}}"
remote_repo_dir="$RUNNER_HOME/little-ci"
runtime_files=(install-runners.sh lib/github-target.sh)
[ ! -f "$script_dir/config.env" ] || runtime_files+=(config.env)

if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
  echo "install-runners-orb.sh requires an Apple Silicon Mac (Darwin arm64)" >&2
  exit 1
fi
[[ "$RUNNER_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || {
  echo "RUNNER_USER is not a valid Unix account name (got '$RUNNER_USER')" >&2
  exit 1
}
[ "$RUNNER_USER" != root ] || {
  echo "RUNNER_USER must be a non-root account" >&2
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
[[ "$RUNNER_HOME" = /* && "$RUNNER_HOME" != / && "$RUNNER_HOME" != *[[:space:]]* ]] || {
  echo "RUNNER_HOME must be an absolute, non-root path without whitespace (got '$RUNNER_HOME')" >&2
  exit 1
}
github_validate_runner_labels "$RUNNER_LABELS" "RUNNER_LABELS"
for ((runner_number = 1; runner_number <= RUNNER_COUNT; runner_number++)); do
  github_validate_runner_label "${RUNNER_NAME_PREFIX}-$runner_number" "runner name label"
done

command -v orbctl >/dev/null || { echo "orbctl not on PATH" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }
command -v tar >/dev/null || { echo "tar is required" >&2; exit 1; }
command -v mktemp >/dev/null || { echo "mktemp is required" >&2; exit 1; }
if [ "${REGTOKEN+x}" = x ] && [ -z "$REGTOKEN" ]; then
  echo "REGTOKEN is empty" >&2
  exit 1
fi
if [ -z "${REGTOKEN:-}" ]; then
  command -v gh >/dev/null || { echo "gh not on PATH and REGTOKEN unset" >&2; exit 1; }
fi

orbstack_validate_machine
orbctl start "$ORB_MACHINE" >/dev/null
orbstack_verify_machine_identity
guest_runner_uid="$(orbctl run -m "$ORB_MACHINE" -u "$RUNNER_USER" id -u)" || {
  echo "could not determine the effective UID for OrbStack runner user '$RUNNER_USER'" >&2
  exit 1
}
[[ "$guest_runner_uid" =~ ^[0-9]+$ ]] && [ "$guest_runner_uid" -ne 0 ] || {
  echo "OrbStack runner user '$RUNNER_USER' must have a non-root UID" >&2
  exit 1
}

if [ -z "${REGTOKEN:-}" ]; then
  REGTOKEN="$(gh api --method POST "$GITHUB_API_TARGET/actions/runners/registration-token" --jq .token)"
fi
: "${REGTOKEN:?REGTOKEN is empty}"

echo "== copying repo to $ORB_MACHINE:$remote_repo_dir =="
orbctl run -m "$ORB_MACHINE" -u "$RUNNER_USER" mkdir -p "$remote_repo_dir"
repository_archive="$(mktemp /tmp/little-ci.XXXXXX.tar.gz)"
trap 'rm -f -- "$repository_archive"' EXIT
tar -C "$script_dir" -czf "$repository_archive" "${runtime_files[@]}"
orbctl run -m "$ORB_MACHINE" -u "$RUNNER_USER" tar -xzf - -C "$remote_repo_dir" < "$repository_archive"
rm -f -- "$repository_archive"
trap - EXIT

echo "== install-runners.sh on $ORB_MACHINE =="
export REGTOKEN GITHUB_SCOPE GITHUB_URL RUNNER_COUNT RUNNER_NAME_PREFIX RUNNER_LABELS
export RUNNER_GROUP RUNNER_VERSION RUNNER_USER RUNNER_HOME
ORBENV=REGTOKEN:GITHUB_SCOPE:GITHUB_URL:RUNNER_COUNT:RUNNER_NAME_PREFIX:RUNNER_LABELS:RUNNER_GROUP:RUNNER_VERSION:RUNNER_USER:RUNNER_HOME \
  orbctl run -m "$ORB_MACHINE" -u "$RUNNER_USER" \
  bash -c 'cd "$1" && RUNNER_HOME="$2" RUNNER_NAME_PREFIX="$3" RUNNER_ARCH=linux-arm64 SKIP_SERVICE_INSTALL=1 ./install-runners.sh' \
  bash "$remote_repo_dir" "$RUNNER_HOME" "$RUNNER_NAME_PREFIX"

echo "== installing runner services =="
for ((runner_number = 1; runner_number <= RUNNER_COUNT; runner_number++)); do
  runner_dir="$RUNNER_HOME/actions-runner-$runner_number"
  orbctl run -m "$ORB_MACHINE" -u root bash -c \
    'set -euo pipefail
    runner_dir="$1"
    runner_user="$2"
    runner_prefix="$3"
    runner_number="$4"
    cd "$runner_dir"
    [ ! -L .service ] || {
      echo "runner service metadata must not be a symlink: $runner_dir/.service" >&2
      exit 1
    }
    if [ ! -e .service ]; then
      ./svc.sh install "$runner_user"
    fi
    [ -f .service ] || {
      echo "runner service metadata is missing: $runner_dir/.service" >&2
      exit 1
    }
    runner_service_name="$(cat .service)"
    [[ "$runner_service_name" =~ ^actions\.runner\.[A-Za-z0-9_.@-]+\.service$ ]] || {
      echo "runner service metadata contains an invalid unit name: $runner_dir/.service" >&2
      exit 1
    }
    service_unit_file="/etc/systemd/system/$runner_service_name"
    if ! test -f "$service_unit_file"; then
      if systemctl is-active --quiet "$runner_service_name"; then
        echo "runner service $runner_service_name is active but its unit file is missing" >&2
        echo "drain and stop the service before rerunning install-runners-orb.sh" >&2
        exit 1
      fi
      rm -f -- .service
      ./svc.sh install "$runner_user"
      [ -f .service ] && [ ! -L .service ] || {
        echo "runner service reinstall did not create regular metadata: $runner_dir/.service" >&2
        exit 1
      }
      runner_service_name="$(cat .service)"
      [[ "$runner_service_name" =~ ^actions\.runner\.[A-Za-z0-9_.@-]+\.service$ ]] || {
        echo "reinstalled runner service metadata contains an invalid unit name: $runner_dir/.service" >&2
        exit 1
      }
      service_unit_file="/etc/systemd/system/$runner_service_name"
    fi
    test -f "$service_unit_file" && \
      grep -Fqx -- "ExecStart=$runner_dir/runsvc.sh" "$service_unit_file" && \
      grep -Fqx -- "User=$runner_user" "$service_unit_file" && \
      grep -Fqx -- "WorkingDirectory=$runner_dir" "$service_unit_file" || {
        echo "runner service $runner_service_name does not belong to $runner_dir and $runner_user" >&2
        exit 1
      }
    scratch_dir="/scratch/$runner_prefix/$runner_number"
    service_drop_in_dir="/etc/systemd/system/${runner_service_name}.d"
    service_drop_in_file="$service_drop_in_dir/zz-little-ci-scratch.conf"
    if test -L "$service_drop_in_dir" || \
      { test -e "$service_drop_in_dir" && ! test -d "$service_drop_in_dir"; }; then
      echo "runner service drop-in path must be a real directory: $service_drop_in_dir" >&2
      exit 1
    fi
    if test -L "$service_drop_in_file" || \
      { test -e "$service_drop_in_file" && ! test -f "$service_drop_in_file"; }; then
      echo "runner service drop-in must be a regular non-symlink file: $service_drop_in_file" >&2
      exit 1
    fi
    desired_drop_in="$(printf "[Service]\nEnvironment=TMPDIR=%s\nEnvironment=TMP=%s\n" \
      "$scratch_dir" "$scratch_dir")"
    existing_drop_in=""
    drop_in_needs_write=1
    if test -f "$service_drop_in_file"; then
      existing_drop_in="$(cat "$service_drop_in_file")"
      if [ "$existing_drop_in" = "$desired_drop_in" ]; then
        drop_in_needs_write=0
      fi
    fi
    if [ "$drop_in_needs_write" = 1 ]; then
      if systemctl is-active --quiet "$runner_service_name"; then
        echo "runner service $runner_service_name is active and its scratch drop-in needs repair" >&2
        echo "drain its job, stop the service, rerun install-runners-orb.sh, then verify it with doctor.sh" >&2
        exit 1
      fi
    fi
    install -d -m 755 "/scratch/$runner_prefix"
    install -d -m 1777 "$scratch_dir"
    install -d -m 755 "$service_drop_in_dir"
    if [ "$drop_in_needs_write" = 1 ]; then
      printf "%s\n" "$desired_drop_in" > "$service_drop_in_file"
    fi
    systemctl daemon-reload
    ./svc.sh start' \
    bash "$runner_dir" "$RUNNER_USER" "$RUNNER_NAME_PREFIX" "$runner_number"
done

echo "== services =="
orbctl run -m "$ORB_MACHINE" -u root systemctl list-units 'actions.runner.*' --no-pager --type=service || true
echo "Next: ./check-runners.sh"
