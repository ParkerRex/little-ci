#!/usr/bin/env bash
# provision-box.sh — idempotent host provisioner for a self-hosted CI runner box.
#
# Sets up, for a memory-constrained box running heavy CI jobs:
#   1. Swap        — one swapfile PER runner (SWAP_GB each), persisted in fstab.
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
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
[ -f "$here/config.env" ] && . "$here/config.env"

RUNNER_COUNT="${RUNNER_COUNT:-3}"
SWAP_GB="${SWAP_GB:-10}"
SWAPPINESS="${SWAPPINESS:-10}"
REAP_AGE="${REAP_AGE:-6h}"
RUNNER_NAME_PREFIX="${RUNNER_NAME_PREFIX:-ci}"
GITHUB_URL="${GITHUB_URL:?set GITHUB_URL in config.env (e.g. https://github.com/OWNER/REPO)}"

# The runner services are named  actions.runner.<owner>-<repo>.<name>.service
# by GitHub's svc.sh. Derive that prefix so we can write each TMPDIR drop-in.
slug="${GITHUB_URL#https://github.com/}"; slug="${slug%/}"; slug="${slug//\//-}"
SVC_PREFIX="actions.runner.${slug}.${RUNNER_NAME_PREFIX}"

[ "$(id -u)" -eq 0 ] || { echo "provision-box.sh must run as root" >&2; exit 1; }
echo "== provisioning for $RUNNER_COUNT runner(s): ${SWAP_GB}G swap each, scratch + ${REAP_AGE} reaper =="

# --- 1. Swap: one <SWAP_GB> swapfile per runner, persisted ---
for n in $(seq 1 "$RUNNER_COUNT"); do
  f="/swapfile$n"
  if ! swapon --show=NAME --noheadings | grep -qx "$f"; then
    if [ ! -f "$f" ]; then
      fallocate -l "${SWAP_GB}G" "$f" 2>/dev/null || \
        dd if=/dev/zero of="$f" bs=1M count=$((SWAP_GB * 1024)) status=none
      chmod 600 "$f"; mkswap "$f" >/dev/null
    fi
    swapon "$f"
  fi
  grep -q "^$f " /etc/fstab || echo "$f none swap sw 0 0" >> /etc/fstab
done

# --- 2. swappiness, persisted ---
sysctl -w vm.swappiness="$SWAPPINESS" >/dev/null
echo "vm.swappiness=$SWAPPINESS" > /etc/sysctl.d/99-ci-swappiness.conf

# --- 3. Per-runner isolated scratch + systemd TMPDIR drop-in ---
reaper="D /tmp 1777 root root $REAP_AGE"
for n in $(seq 1 "$RUNNER_COUNT"); do
  mkdir -p "/scratch/$n"; chmod 1777 "/scratch/$n"
  d="/etc/systemd/system/${SVC_PREFIX}-$n.service.d"
  mkdir -p "$d"
  printf '[Service]\nEnvironment=TMPDIR=/scratch/%s\nEnvironment=TMP=/scratch/%s\n' "$n" "$n" \
    > "$d/tmpdir.conf"
  reaper+=$'\n'"D /scratch/$n 1777 root root $REAP_AGE"
done

# --- 4. Reaper: age /tmp + each /scratch/N ---
printf '%s\n' "$reaper" > /etc/tmpfiles.d/runner-scratch.conf

systemctl daemon-reload 2>/dev/null || true
systemd-tmpfiles --create /etc/tmpfiles.d/runner-scratch.conf 2>/dev/null || true

echo "== done =="
swapon --show
echo "swappiness=$(sysctl -n vm.swappiness)"
df -h / | tail -1
echo "NOTE: TMPDIR drop-ins apply on the next runner (re)start."
