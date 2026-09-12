#!/usr/bin/env bash
# provision-box.sh — idempotent host provisioner for a self-hosted CI runner box.
#
# Sets up, for a memory-constrained box running heavy CI jobs:
#   1. Swap        — one swapfile PER runner on generic Linux. OrbStack guests
#                    use OrbStack-managed zram/swap instead.
#   2. swappiness  — low (default 10) so the box only swaps under real pressure.
#   3. Scratch     — a per-runner /scratch/N with a systemd TMPDIR drop-in, so
#                    runners don't contend on a single shared /tmp.
#   4. Reaper      — ages /tmp + every /scratch/N (default 6h) via systemd-tmpfiles,
#                    so dead job-workspace dirs can't accumulate and fill the disk.
#
# Safe to re-run. Run as root ON the box:
#     sudo ./provision-box.sh
# or from your laptop:
#     ssh root@BOX 'bash -s' < provision-box.sh      # (with env vars exported inline)
#
# Run this BEFORE install-runners.sh — the TMPDIR drop-ins are then already in
# place when the runner services first start.
is_orbstack_guest() {
  local guest_marker kernel_release_file
  guest_marker="${LITTLE_CI_ORBSTACK_GUEST_MARKER:-/opt/orbstack-guest}"
  kernel_release_file="${LITTLE_CI_KERNEL_RELEASE_FILE:-/proc/sys/kernel/osrelease}"

  [ -e "$guest_marker" ] || \
    { [ -r "$kernel_release_file" ] && grep -Fqi orbstack "$kernel_release_file"; }
}

# Keep detection sourceable for dependency-light tests without provisioning the
# current host.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  return 0
fi

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

RUNNER_COUNT="${RUNNER_COUNT:-1}"
SWAP_GB="${SWAP_GB:-10}"
SWAPPINESS="${SWAPPINESS:-10}"
REAP_AGE="${REAP_AGE:-6h}"
REMOVE_LEGACY_SWAPFILES="${REMOVE_LEGACY_SWAPFILES:-0}"
RUNNER_NAME_PREFIX="${RUNNER_NAME_PREFIX:-little-ci-${GITHUB_TARGET//\//-}}"

# The runner services are named  actions.runner.<owner>-<repo>.<name>.service
# by GitHub's svc.sh. Derive that prefix so we can write each TMPDIR drop-in.
service_target="${GITHUB_TARGET//\//-}"
service_name_prefix="actions.runner.${service_target}.${RUNNER_NAME_PREFIX}"

[ "$(id -u)" -eq 0 ] || { echo "provision-box.sh must run as root" >&2; exit 1; }
[[ "$RUNNER_COUNT" =~ ^[1-9][0-9]*$ ]] || { echo "RUNNER_COUNT must be a positive integer" >&2; exit 1; }
[[ "$SWAP_GB" =~ ^[1-9][0-9]*$ ]] || { echo "SWAP_GB must be a positive integer" >&2; exit 1; }
case "$REMOVE_LEGACY_SWAPFILES" in
  0|1) ;;
  *) echo "REMOVE_LEGACY_SWAPFILES must be 0 or 1" >&2; exit 1 ;;
esac
echo "== provisioning for $RUNNER_COUNT runner(s): scratch + ${REAP_AGE} reaper =="

# --- 1. Swap: one <SWAP_GB> swapfile per runner, persisted ---
if is_orbstack_guest; then
  echo "== OrbStack guest detected: using OrbStack-managed zram/swap =="

  # Detect the exact fstab shape written by older releases. Removal is opt-in
  # because a matching file is not enough to prove ownership.
  legacy_swap_paths="$(awk '
    $1 ~ /^\/swapfile[0-9]+$/ && $2 == "none" && $3 == "swap" &&
      $4 == "sw" && $5 == "0" && $6 == "0" && NF == 6 { print $1 }
  ' /etc/fstab)"
  if [ -n "$legacy_swap_paths" ] && [ "$REMOVE_LEGACY_SWAPFILES" = 0 ]; then
    echo "WARN: legacy numbered swapfiles remain configured and may consume disk; set REMOVE_LEGACY_SWAPFILES=1 to remove them" >&2
  elif [ -n "$legacy_swap_paths" ]; then
    fstab_copy="$(mktemp /etc/fstab.little-ci.XXXXXX)"
    trap 'rm -f "$fstab_copy"' EXIT
    awk '
      !($1 ~ /^\/swapfile[0-9]+$/ && $2 == "none" && $3 == "swap" &&
        $4 == "sw" && $5 == "0" && $6 == "0" && NF == 6)
    ' /etc/fstab > "$fstab_copy"
    chown --reference=/etc/fstab "$fstab_copy"
    chmod --reference=/etc/fstab "$fstab_copy"
    mv "$fstab_copy" /etc/fstab
    trap - EXIT

    while IFS= read -r swapfile_path; do
      swapoff "$swapfile_path" 2>/dev/null || true
      rm -f -- "$swapfile_path"
      echo "removed legacy Little-CI swapfile $swapfile_path"
    done <<< "$legacy_swap_paths"
  fi
else
  echo "== configuring ${SWAP_GB}G swapfile per runner =="
  for runner_number in $(seq 1 "$RUNNER_COUNT"); do
    swapfile_path="/swapfile$runner_number"
    if ! swapon --show=NAME --noheadings | grep -Fqx "$swapfile_path"; then
      if [ ! -f "$swapfile_path" ]; then
        fallocate -l "${SWAP_GB}G" "$swapfile_path" 2>/dev/null || \
          dd if=/dev/zero of="$swapfile_path" bs=1M count=$((SWAP_GB * 1024)) status=none
        chmod 600 "$swapfile_path"
        mkswap "$swapfile_path" >/dev/null
      fi
      swapon "$swapfile_path"
    fi
    grep -Fq "$swapfile_path none swap sw 0 0" /etc/fstab || \
      echo "$swapfile_path none swap sw 0 0" >> /etc/fstab
  done
fi

# --- 2. swappiness, persisted ---
sysctl -w vm.swappiness="$SWAPPINESS" >/dev/null
echo "vm.swappiness=$SWAPPINESS" > /etc/sysctl.d/99-little-ci-swappiness.conf
rm -f /etc/sysctl.d/99-ci-swappiness.conf

# --- 3. Per-runner isolated scratch + systemd TMPDIR drop-in ---
reaper_config="D /tmp 1777 root root $REAP_AGE"
for runner_number in $(seq 1 "$RUNNER_COUNT"); do
  scratch_dir="/scratch/$runner_number"
  mkdir -p "$scratch_dir"
  chmod 1777 "$scratch_dir"
  service_drop_in_dir="/etc/systemd/system/${service_name_prefix}-$runner_number.service.d"
  mkdir -p "$service_drop_in_dir"
  printf '[Service]\nEnvironment=TMPDIR=%s\nEnvironment=TMP=%s\n' "$scratch_dir" "$scratch_dir" \
    > "$service_drop_in_dir/tmpdir.conf"
  reaper_config+=$'\n'"D $scratch_dir 1777 root root $REAP_AGE"
done

# --- 4. Reaper: age /tmp + each /scratch/N ---
printf '%s\n' "$reaper_config" > /etc/tmpfiles.d/little-ci-runner-scratch.conf
rm -f /etc/tmpfiles.d/runner-scratch.conf

systemctl daemon-reload 2>/dev/null || true
systemd-tmpfiles --create /etc/tmpfiles.d/little-ci-runner-scratch.conf 2>/dev/null || true

echo "== done =="
swapon --show
echo "swappiness=$(sysctl -n vm.swappiness)"
df -h / | tail -1
echo "NOTE: TMPDIR drop-ins apply on the next runner (re)start."
