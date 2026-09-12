#!/usr/bin/env bash
# provision-box.sh — idempotent host provisioner for a self-hosted CI runner box.
#
# Sets up, for a memory-constrained box running heavy CI jobs:
#   1. Swap        — one swapfile PER runner on generic Linux. OrbStack guests
#                    use OrbStack-managed zram/swap instead.
#   2. swappiness  — low (default 10) so the box only swaps under real pressure.
#   3. Scratch     — per-fleet, per-runner scratch directories so runners do not
#                    contend on a single shared /tmp.
#   4. Reaper      — ages /tmp + fleet scratch (default 6h) via systemd-tmpfiles,
#                    so dead job-workspace dirs can't accumulate and fill the disk.
#
# Safe to re-run. Run as root ON the box:
#     sudo ./provision-box.sh
# or from your laptop:
#     ssh root@BOX 'bash -s' < provision-box.sh      # (with env vars exported inline)
#
# Run this BEFORE install-runners.sh so fleet scratch exists before the installer
# binds each runner's registered systemd service to its directory.
is_orbstack_guest() {
  local guest_marker kernel_release_file
  guest_marker="${LITTLE_CI_ORBSTACK_GUEST_MARKER:-/opt/orbstack-guest}"
  kernel_release_file="${LITTLE_CI_KERNEL_RELEASE_FILE:-/proc/sys/kernel/osrelease}"

  [ -e "$guest_marker" ] || \
    { [ -r "$kernel_release_file" ] && grep -Fqi orbstack "$kernel_release_file"; }
}

record_created_swapfile() {
  local runner_number="$1" swapfile_path="$2" ownership_record manifest_metadata
  local manifest_dir
  manifest_dir="$(dirname "$swap_ownership_manifest")"

  if [ -L "$manifest_dir" ] || [ -L "$swap_ownership_manifest" ]; then
    echo "refusing symlinked swap ownership state: $swap_ownership_manifest" >&2
    return 1
  fi
  if [ -e "$manifest_dir" ]; then
    manifest_metadata="$(stat -c '%u:%g:%a' "$manifest_dir")"
    [ "$manifest_metadata" = 0:0:700 ] || {
      echo "swap ownership directory must be root-owned mode 700: $manifest_dir" >&2
      return 1
    }
  else
    install -d -o root -g root -m 700 "$manifest_dir"
  fi
  if [ -e "$swap_ownership_manifest" ]; then
    [ -f "$swap_ownership_manifest" ] || {
      echo "swap ownership manifest is not a regular file: $swap_ownership_manifest" >&2
      return 1
    }
    manifest_metadata="$(stat -c '%u:%g:%a' "$swap_ownership_manifest")"
    [ "$manifest_metadata" = 0:0:600 ] || {
      echo "swap ownership manifest must be root-owned mode 600: $swap_ownership_manifest" >&2
      return 1
    }
  else
    install -o root -g root -m 600 /dev/null "$swap_ownership_manifest"
  fi

  ownership_record="$(printf '%s\t%s' "$runner_number" "$swapfile_path")"
  grep -Fqx "$ownership_record" "$swap_ownership_manifest" || \
    printf '%s\n' "$ownership_record" >> "$swap_ownership_manifest"
}

swapfile_is_manifest_owned() {
  local runner_number="$1" swapfile_path="$2" ownership_record manifest_dir manifest_metadata
  manifest_dir="$(dirname "$swap_ownership_manifest")"
  ownership_record="$(printf '%s\t%s' "$runner_number" "$swapfile_path")"

  [ ! -L "$manifest_dir" ] && [ ! -L "$swap_ownership_manifest" ] || return 1
  [ -d "$manifest_dir" ] && [ -f "$swap_ownership_manifest" ] || return 1
  manifest_metadata="$(stat -c '%u:%g:%a' "$manifest_dir")"
  [ "$manifest_metadata" = 0:0:700 ] || return 1
  manifest_metadata="$(stat -c '%u:%g:%a' "$swap_ownership_manifest")"
  [ "$manifest_metadata" = 0:0:600 ] || return 1
  grep -Fqx "$ownership_record" "$swap_ownership_manifest"
}

validate_owned_swapfile() {
  local runner_number="$1" swapfile_path="$2" expected_size_bytes actual_metadata
  local actual_size_bytes filesystem_signature

  swapfile_is_manifest_owned "$runner_number" "$swapfile_path" || {
    echo "refusing existing unowned Little-CI swapfile: $swapfile_path" >&2
    return 1
  }
  [ -f "$swapfile_path" ] && [ ! -L "$swapfile_path" ] || {
    echo "owned swapfile must be a regular, non-symlink file: $swapfile_path" >&2
    return 1
  }
  actual_metadata="$(stat -c '%u:%g:%a' "$swapfile_path")"
  [ "$actual_metadata" = 0:0:600 ] || {
    echo "owned swapfile must be root-owned mode 600: $swapfile_path" >&2
    return 1
  }
  expected_size_bytes="$((SWAP_GB * 1024 * 1024 * 1024))"
  actual_size_bytes="$(stat -c '%s' "$swapfile_path")"
  [ "$actual_size_bytes" = "$expected_size_bytes" ] || {
    echo "owned swapfile has size ${actual_size_bytes}B; expected ${expected_size_bytes}B: $swapfile_path" >&2
    return 1
  }
  filesystem_signature="$(blkid -p -s TYPE -o value "$swapfile_path" 2>/dev/null)" || {
    echo "owned swapfile has no readable swap signature: $swapfile_path" >&2
    return 1
  }
  [ "$filesystem_signature" = swap ] || {
    echo "owned swapfile has invalid signature '$filesystem_signature': $swapfile_path" >&2
    return 1
  }
}

fstab_has_exact_swap_entry() {
  local swapfile_path="$1"
  awk -v swapfile_path="$swapfile_path" '
    $0 !~ /^[[:space:]]*#/ && NF == 6 &&
      $1 == swapfile_path && $2 == "none" && $3 == "swap" &&
      $4 == "sw" && $5 == "0" && $6 == "0" { found = 1 }
    END { exit(found ? 0 : 1) }
  ' /etc/fstab
}

cleanup_pending_swapfile() {
  [ -n "${pending_swapfile_path:-}" ] || return 0
  if ! swapfile_is_manifest_owned "$pending_runner_number" "$pending_swapfile_path"; then
    rm -f -- "$pending_swapfile_path"
  fi
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
github_fleet_init

RUNNER_COUNT="${RUNNER_COUNT:-1}"
SWAP_GB="${SWAP_GB:-10}"
SWAPPINESS="${SWAPPINESS:-10}"
REAP_AGE="${REAP_AGE:-6h}"
REMOVE_LEGACY_SWAPFILES="${REMOVE_LEGACY_SWAPFILES:-0}"
RUNNER_USER="${RUNNER_USER:-deploy}"
swap_ownership_manifest="/var/lib/little-ci/fleets/$RUNNER_NAME_PREFIX/managed-swapfiles"

[ "$(id -u)" -eq 0 ] || { echo "provision-box.sh must run as root" >&2; exit 1; }
[ "$RUNNER_USER" != root ] || { echo "RUNNER_USER must be a dedicated non-root account" >&2; exit 1; }
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
    active_swap_paths="$(swapon --show=NAME --noheadings)"
    deactivated_legacy_swapfiles=()
    legacy_swapoff_failed=0
    while IFS= read -r swapfile_path; do
      if grep -Fqx "$swapfile_path" <<< "$active_swap_paths"; then
        if swapoff "$swapfile_path"; then
          deactivated_legacy_swapfiles+=("$swapfile_path")
        else
          echo "could not deactivate legacy swapfile; preserving fstab and files: $swapfile_path" >&2
          legacy_swapoff_failed=1
        fi
      fi
    done <<< "$legacy_swap_paths"
    if [ "$legacy_swapoff_failed" = 1 ]; then
      for swapfile_path in "${deactivated_legacy_swapfiles[@]}"; do
        swapon "$swapfile_path" || \
          echo "WARN: could not reactivate legacy swapfile after cleanup abort: $swapfile_path" >&2
      done
      exit 1
    fi

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
      rm -f -- "$swapfile_path"
      echo "removed legacy Little-CI swapfile $swapfile_path"
    done <<< "$legacy_swap_paths"
  fi
else
  echo "== configuring ${SWAP_GB}G swapfile per runner =="
  pending_swapfile_path=""
  pending_runner_number=""
  for runner_number in $(seq 1 "$RUNNER_COUNT"); do
    swapfile_path="/swapfile-${RUNNER_NAME_PREFIX}-${runner_number}"
    if [ -e "$swapfile_path" ] || [ -L "$swapfile_path" ]; then
      validate_owned_swapfile "$runner_number" "$swapfile_path"
    else
      if ! (set -o noclobber; : > "$swapfile_path") 2>/dev/null; then
        echo "could not exclusively create Little-CI swapfile: $swapfile_path" >&2
        exit 1
      fi
      pending_swapfile_path="$swapfile_path"
      pending_runner_number="$runner_number"
      trap cleanup_pending_swapfile EXIT HUP INT TERM
      if ! fallocate -l "${SWAP_GB}G" "$swapfile_path" 2>/dev/null; then
        dd if=/dev/zero of="$swapfile_path" bs=1M count=$((SWAP_GB * 1024)) conv=notrunc status=none
      fi
      chmod 600 "$swapfile_path"
      mkswap "$swapfile_path" >/dev/null
      record_created_swapfile "$runner_number" "$swapfile_path"
      pending_swapfile_path=""
      pending_runner_number=""
      trap - EXIT HUP INT TERM
    fi
    if ! swapon --show=NAME --noheadings | grep -Fqx "$swapfile_path"; then
      swapon "$swapfile_path"
    fi
    fstab_has_exact_swap_entry "$swapfile_path" || \
      echo "$swapfile_path none swap sw 0 0" >> /etc/fstab
  done
fi

# --- 2. swappiness, persisted ---
sysctl -w vm.swappiness="$SWAPPINESS" >/dev/null
echo "vm.swappiness=$SWAPPINESS" > /etc/sysctl.d/99-little-ci-swappiness.conf

# --- 3. Per-fleet, per-runner scratch ---
reaper_config="D /tmp 1777 root root $REAP_AGE"
scratch_root="/scratch/$RUNNER_NAME_PREFIX"
mkdir -p "$scratch_root"
chmod 755 "$scratch_root"
for runner_number in $(seq 1 "$RUNNER_COUNT"); do
  scratch_dir="$scratch_root/$runner_number"
  mkdir -p "$scratch_dir"
  chmod 1777 "$scratch_dir"
  reaper_config+=$'\n'"D $scratch_dir 1777 root root $REAP_AGE"
done

# --- 4. Reaper: age /tmp + this fleet's scratch ---
tmpfiles_policy="/etc/tmpfiles.d/little-ci-${RUNNER_NAME_PREFIX}-scratch.conf"
printf '%s\n' "$reaper_config" > "$tmpfiles_policy"

systemd-tmpfiles --create "$tmpfiles_policy" 2>/dev/null || true

echo "== done =="
swapon --show
echo "swappiness=$(sysctl -n vm.swappiness)"
df -h / | tail -1
echo "NOTE: install-runners.sh binds each registered service to its fleet scratch directory."
