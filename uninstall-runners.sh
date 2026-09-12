#!/usr/bin/env bash
# Unregister and remove only explicitly selected runners from one Little-CI fleet.
set -euo pipefail
set +x

if ! declare -F github_target_init >/dev/null 2>&1; then
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  [ -f "$script_dir/lib/github-target.sh" ] || { echo "missing $script_dir/lib/github-target.sh" >&2; exit 1; }
  . "$script_dir/lib/github-target.sh"
  reject_persisted_github_credentials "$script_dir/config.env"
  [ -f "$script_dir/config.env" ] && . "$script_dir/config.env"
fi

usage() {
  cat <<'EOF'
Usage:
  REMOVETOKEN=... ./uninstall-runners.sh --all --confirm
  REMOVETOKEN=... ./uninstall-runners.sh --prune --confirm
  REMOVETOKEN=... ./uninstall-runners.sh --runner NAME --confirm

--all          Remove every local runner whose target and name match this fleet.
--prune        Remove only matching runners numbered above RUNNER_COUNT.
--runner NAME  Remove one exact runner from this fleet.
--confirm      Required acknowledgement for any removal.
EOF
}

removal_mode=""
requested_runner=""
confirmed=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --all|--prune)
      [ -z "$removal_mode" ] || { echo "choose exactly one removal mode" >&2; exit 2; }
      removal_mode="${1#--}"
      ;;
    --runner)
      [ -z "$removal_mode" ] || { echo "choose exactly one removal mode" >&2; exit 2; }
      [ "$#" -ge 2 ] || { echo "--runner requires a name" >&2; exit 2; }
      removal_mode="runner"
      requested_runner="$2"
      shift
      ;;
    --confirm) confirmed=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

[ -n "$removal_mode" ] || { echo "choose --all, --prune, or --runner NAME" >&2; exit 2; }
[ "$confirmed" = true ] || { echo "refusing removal without --confirm" >&2; exit 2; }
: "${REMOVETOKEN:?REMOVETOKEN env required — use a short-lived GitHub runner remove token}"

github_target_init
RUNNER_COUNT="${RUNNER_COUNT:-1}"
RUNNER_USER="${RUNNER_USER:-$(id -un)}"
if [ -z "${RUNNER_HOME:-}" ]; then
  RUNNER_HOME="$(getent passwd "$RUNNER_USER" 2>/dev/null | cut -d: -f6 || true)"
fi

[[ "$RUNNER_COUNT" =~ ^[1-9][0-9]*$ ]] || { echo "RUNNER_COUNT must be a positive integer" >&2; exit 2; }
[[ "$RUNNER_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || { echo "RUNNER_USER must be a valid Linux username" >&2; exit 2; }
[ "$RUNNER_USER" != root ] || { echo "RUNNER_USER must be a non-root account" >&2; exit 2; }
[ -n "$RUNNER_HOME" ] || { echo "could not determine RUNNER_HOME for $RUNNER_USER" >&2; exit 2; }
[[ "$RUNNER_HOME" = /* ]] || { echo "RUNNER_HOME must be an absolute path" >&2; exit 2; }
[ "$RUNNER_HOME" != / ] || { echo "RUNNER_HOME must not be /" >&2; exit 2; }
[ -d "$RUNNER_HOME" ] || { echo "RUNNER_HOME does not exist: $RUNNER_HOME" >&2; exit 2; }
RUNNER_HOME="$(cd "$RUNNER_HOME" && pwd -P)"
[ "$RUNNER_HOME" != / ] || { echo "RUNNER_HOME must not resolve to /" >&2; exit 2; }
github_fleet_init

runner_index() {
  local runner_name="$1" runner_number
  case "$runner_name" in
    "$RUNNER_NAME_PREFIX"-*) runner_number="${runner_name#"$RUNNER_NAME_PREFIX"-}" ;;
    *) return 1 ;;
  esac
  [[ "$runner_number" =~ ^[1-9][0-9]*$ ]] || return 1
  printf '%s\n' "$runner_number"
}

runner_number_is_selected() {
  local runner_number="$1"
  case "$removal_mode" in
    all) return 0 ;;
    prune) [ "$runner_number" -gt "$RUNNER_COUNT" ] ;;
    runner) [ "${RUNNER_NAME_PREFIX}-${runner_number}" = "$requested_runner" ] ;;
  esac
}

if [ "$removal_mode" = runner ] && ! runner_index "$requested_runner" >/dev/null; then
  echo "--runner must be an exact ${RUNNER_NAME_PREFIX}-N name" >&2
  exit 2
fi

run_privileged() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

run_as_runner() {
  if [ "$(id -un)" = "$RUNNER_USER" ]; then
    "$@"
  elif [ "$(id -u)" -eq 0 ]; then
    runuser -u "$RUNNER_USER" -- env HOME="$RUNNER_HOME" "$@"
  else
    echo "run as $RUNNER_USER or root" >&2
    return 1
  fi
}

failure_count=0
removed_count=0
selected_count=0
recovery_steps=()

record_failure() {
  local failure_message="$1" recovery_step="$2"
  echo "ERROR: $failure_message" >&2
  failure_count=$((failure_count + 1))
  recovery_steps+=("$recovery_step")
}

validate_pending_cleanup_dir() {
  local pending_cleanup_dir="$1"
  if ! run_privileged test -e "$pending_cleanup_dir"; then
    run_privileged test ! -L "$pending_cleanup_dir"
    return
  fi
  run_privileged test -d "$pending_cleanup_dir" && \
    run_privileged test ! -L "$pending_cleanup_dir" && \
    [ "$(run_privileged stat -c '%U:%G %a' "$pending_cleanup_dir")" = "root:root 700" ]
}

create_pending_cleanup_record() {
  local runner_number="$1" runner_name="$2" runner_dir="$3" runner_service="$4"
  local fleet_state_dir="/var/lib/little-ci/fleets/${RUNNER_NAME_PREFIX}"
  local pending_cleanup_dir="$fleet_state_dir/pending-cleanup"
  local pending_cleanup_record="$pending_cleanup_dir/$runner_number"

  if run_privileged test -e "$fleet_state_dir" || run_privileged test -L "$fleet_state_dir"; then
    run_privileged test -d "$fleet_state_dir" && run_privileged test ! -L "$fleet_state_dir" && \
      [ "$(run_privileged stat -c '%U:%G %a' "$fleet_state_dir")" = "root:root 700" ] || return 1
  else
    run_privileged install -d -o root -g root -m 700 "$fleet_state_dir" || return 1
  fi
  if run_privileged test -e "$pending_cleanup_dir" || run_privileged test -L "$pending_cleanup_dir"; then
    validate_pending_cleanup_dir "$pending_cleanup_dir" || return 1
  else
    run_privileged install -d -o root -g root -m 700 "$pending_cleanup_dir" || return 1
  fi
  run_privileged test ! -e "$pending_cleanup_record" || return 1

  run_privileged python3 - "$pending_cleanup_record" "$runner_number" "$runner_name" \
    "$runner_dir" "$GITHUB_TARGET" "${runner_service:--}" <<'WRITE_RECORD'
import os
import sys
import tempfile

record_path, runner_number, runner_name, runner_dir, target, service = sys.argv[1:]
descriptor, pending_record = tempfile.mkstemp(prefix=".pending-cleanup-", dir=os.path.dirname(record_path), text=True)
try:
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        stream.write("\t".join((runner_number, runner_name, runner_dir, target, service)) + "\n")
    os.chown(pending_record, 0, 0)
    os.chmod(pending_record, 0o600)
    os.link(pending_record, record_path)
    os.unlink(pending_record)
except BaseException:
    try:
        os.unlink(pending_record)
    except FileNotFoundError:
        pass
    raise
WRITE_RECORD
}

read_pending_cleanup_record() {
  local runner_number="$1"
  local pending_cleanup_dir="/var/lib/little-ci/fleets/${RUNNER_NAME_PREFIX}/pending-cleanup"
  local pending_cleanup_record="$pending_cleanup_dir/$runner_number"
  local record_contents

  validate_pending_cleanup_dir "$pending_cleanup_dir" || return 1
  run_privileged test -f "$pending_cleanup_record" && \
    run_privileged test ! -L "$pending_cleanup_record" && \
    [ "$(run_privileged stat -c '%U:%G %a' "$pending_cleanup_record")" = "root:root 600" ] || return 1
  record_contents="$(run_privileged cat "$pending_cleanup_record")" || return 1
  printf '%s\n' "$record_contents" | python3 -c '
import re
import sys

expected_number, expected_name, expected_dir, expected_target = sys.argv[1:]
lines = sys.stdin.read().splitlines()
if len(lines) != 1:
    raise SystemExit("pending cleanup record must contain exactly one line")
fields = lines[0].split("\t")
if len(fields) != 5:
    raise SystemExit("pending cleanup record must contain exactly five fields")
number, name, runner_dir, target, service = fields
if (number, name, runner_dir, target) != (expected_number, expected_name, expected_dir, expected_target):
    raise SystemExit("pending cleanup record identity mismatch")
if service != "-" and not re.fullmatch(r"actions\.runner\.[A-Za-z0-9._@-]+\.service", service):
    raise SystemExit("pending cleanup record contains an invalid service")
print("" if service == "-" else service)
' "$runner_number" "${RUNNER_NAME_PREFIX}-${runner_number}" \
    "$RUNNER_HOME/actions-runner-${runner_number}" "$GITHUB_TARGET"
}

remove_pending_cleanup_record() {
  local runner_number="$1"
  local pending_cleanup_dir="/var/lib/little-ci/fleets/${RUNNER_NAME_PREFIX}/pending-cleanup"
  local pending_cleanup_record="$pending_cleanup_dir/$runner_number"
  run_privileged rm -f -- "$pending_cleanup_record" || return 1
  run_privileged test ! -e "$pending_cleanup_record" && run_privileged test ! -L "$pending_cleanup_record" || return 1
  run_privileged rmdir "$pending_cleanup_dir" 2>/dev/null || true
  run_privileged rmdir "/var/lib/little-ci/fleets/${RUNNER_NAME_PREFIX}" 2>/dev/null || true
}

remove_tmpfiles_entry() {
  local scratch_dir="$1"
  local tmpfiles_path="/etc/tmpfiles.d/little-ci-${RUNNER_NAME_PREFIX}-scratch.conf"
  run_privileged test -f "$tmpfiles_path" || return 0
  run_privileged python3 - "$tmpfiles_path" "$scratch_dir" <<'PY'
import os
import stat
import sys
import tempfile

config_path, scratch_path = sys.argv[1:]
config_stat = os.stat(config_path, follow_symlinks=False)
if stat.S_ISLNK(config_stat.st_mode) or not stat.S_ISREG(config_stat.st_mode):
    raise SystemExit(f"refusing non-regular tmpfiles config: {config_path}")
with open(config_path, encoding="utf-8") as stream:
    lines = stream.readlines()
kept = [line for line in lines if len(line.split()) < 2 or line.split()[1] != scratch_path]
scratch_root = os.path.dirname(scratch_path) + "/"
if not any(len(line.split()) >= 2 and line.split()[1].startswith(scratch_root) for line in kept):
    os.unlink(config_path)
    raise SystemExit(0)
descriptor, replacement = tempfile.mkstemp(prefix=".little-ci-tmpfiles-", dir=os.path.dirname(config_path), text=True)
try:
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        stream.writelines(kept)
    os.chown(replacement, config_stat.st_uid, config_stat.st_gid)
    os.chmod(replacement, stat.S_IMODE(config_stat.st_mode))
    os.replace(replacement, config_path)
except BaseException:
    try:
        os.unlink(replacement)
    except FileNotFoundError:
        pass
    raise
PY
}

read_managed_swapfile() {
  local runner_number="$1" manifest_path="$2" manifest_contents manifest_dir
  run_privileged test -e "$manifest_path" || return 0
  manifest_dir="${manifest_path%/*}"
  run_privileged test -d "$manifest_dir" && run_privileged test ! -L "$manifest_dir" && \
    [ "$(run_privileged stat -c '%U:%G %a' "$manifest_dir")" = "root:root 700" ] || {
      echo "managed swapfile manifest directory has unexpected ownership or mode: $manifest_dir" >&2
      return 1
    }
  run_privileged test -f "$manifest_path" && run_privileged test ! -L "$manifest_path" || {
    echo "managed swapfile manifest is not a regular file: $manifest_path" >&2
    return 1
  }
  [ "$(run_privileged stat -c '%U:%G %a' "$manifest_path")" = "root:root 600" ] || {
    echo "managed swapfile manifest has unexpected ownership or mode: $manifest_path" >&2
    return 1
  }
  manifest_contents="$(run_privileged cat "$manifest_path")"
  printf '%s\n' "$manifest_contents" | python3 -c '
import sys

selected = int(sys.argv[1])
expected_path = sys.argv[2]
fleet_prefix = sys.argv[3]
records = {}
paths = set()
for line_number, raw_line in enumerate(sys.stdin, 1):
    line = raw_line.rstrip("\n")
    if not line:
        continue
    fields = line.split("\t")
    if len(fields) != 2 or not fields[0].isdigit() or int(fields[0]) < 1:
        raise SystemExit(f"malformed managed swapfile record at line {line_number}")
    number, path = int(fields[0]), fields[1]
    if path != f"/swapfile-{fleet_prefix}-{number}":
        raise SystemExit(f"managed swapfile path does not match runner {number}: {path}")
    if number in records or path in paths:
        raise SystemExit(f"duplicate managed swapfile record at line {line_number}")
    records[number] = path
    paths.add(path)
if selected in records:
    if records[selected] != expected_path:
        raise SystemExit(f"managed swapfile path does not match selected runner {selected}")
    print(records[selected])
' "$runner_number" "/swapfile-${RUNNER_NAME_PREFIX}-${runner_number}" "$RUNNER_NAME_PREFIX"
}

rewrite_fstab_without_swapfile() {
  local swapfile_path="$1"
  run_privileged python3 - "$swapfile_path" <<'PY'
import os
import stat
import sys
import tempfile

fstab_path = "/etc/fstab"
swapfile_path = sys.argv[1]
fstab_stat = os.stat(fstab_path, follow_symlinks=False)
if stat.S_ISLNK(fstab_stat.st_mode) or not stat.S_ISREG(fstab_stat.st_mode):
    raise SystemExit("refusing non-regular /etc/fstab")
with open(fstab_path, encoding="utf-8") as stream:
    lines = stream.readlines()
kept = []
for line in lines:
    fields = line.split()
    owned_entry = len(fields) == 6 and fields == [swapfile_path, "none", "swap", "sw", "0", "0"]
    if not owned_entry:
        kept.append(line)
descriptor, replacement = tempfile.mkstemp(prefix=".little-ci-fstab-", dir="/etc", text=True)
try:
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        stream.writelines(kept)
    os.chown(replacement, fstab_stat.st_uid, fstab_stat.st_gid)
    os.chmod(replacement, stat.S_IMODE(fstab_stat.st_mode))
    os.replace(replacement, fstab_path)
except BaseException:
    try:
        os.unlink(replacement)
    except FileNotFoundError:
        pass
    raise
PY
}

remove_swapfile_manifest_record() {
  local runner_number="$1" swapfile_path="$2" manifest_path="$3"
  run_privileged python3 - "$runner_number" "$swapfile_path" "$manifest_path" <<'PY'
import os
import stat
import sys
import tempfile

runner_number, swapfile_path, manifest_path = sys.argv[1:]
manifest_stat = os.stat(manifest_path, follow_symlinks=False)
with open(manifest_path, encoding="utf-8") as stream:
    lines = stream.readlines()
record = f"{runner_number}\t{swapfile_path}"
kept = [line for line in lines if line.rstrip("\n") != record]
if not kept:
    os.unlink(manifest_path)
    raise SystemExit(0)
descriptor, replacement = tempfile.mkstemp(prefix=".little-ci-swapfiles-", dir=os.path.dirname(manifest_path), text=True)
try:
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        stream.writelines(kept)
    os.chown(replacement, manifest_stat.st_uid, manifest_stat.st_gid)
    os.chmod(replacement, stat.S_IMODE(manifest_stat.st_mode))
    os.replace(replacement, manifest_path)
except BaseException:
    try:
        os.unlink(replacement)
    except FileNotFoundError:
        pass
    raise
PY
}

remove_managed_swapfile() {
  local runner_number="$1"
  local manifest_path="/var/lib/little-ci/fleets/${RUNNER_NAME_PREFIX}/managed-swapfiles"
  local swapfile_path
  if ! swapfile_path="$(read_managed_swapfile "$runner_number" "$manifest_path")"; then
    return 1
  fi
  [ -n "$swapfile_path" ] || return 0
  [ "$swapfile_path" = "/swapfile-${RUNNER_NAME_PREFIX}-${runner_number}" ] || return 1
  if run_privileged test -e "$swapfile_path"; then
    run_privileged test -f "$swapfile_path" && run_privileged test ! -L "$swapfile_path" || return 1
  fi

  if run_privileged swapon --show=NAME --noheadings | grep -Fqx "$swapfile_path"; then
    run_privileged swapoff "$swapfile_path" || return 1
  fi
  rewrite_fstab_without_swapfile "$swapfile_path" || return 1
  run_privileged rm -f -- "$swapfile_path" || return 1
  remove_swapfile_manifest_record "$runner_number" "$swapfile_path" "$manifest_path" || return 1
  run_privileged rmdir "/var/lib/little-ci/fleets/${RUNNER_NAME_PREFIX}" 2>/dev/null || true
}

validate_service_drop_in() {
  local runner_number="$1" runner_service="$2"
  local service_drop_in_dir="/etc/systemd/system/${runner_service}.d"
  local service_drop_in_file="$service_drop_in_dir/zz-little-ci-scratch.conf"
  local scratch_dir="/scratch/${RUNNER_NAME_PREFIX}/${runner_number}"

  run_privileged test -e "$service_drop_in_file" || return 0
  run_privileged test -d "$service_drop_in_dir" && run_privileged test ! -L "$service_drop_in_dir" && \
    run_privileged test -f "$service_drop_in_file" && run_privileged test ! -L "$service_drop_in_file" && \
    run_privileged grep -Fqx -- "Environment=TMPDIR=$scratch_dir" "$service_drop_in_file" && \
    run_privileged grep -Fqx -- "Environment=TMP=$scratch_dir" "$service_drop_in_file"
}

remove_service_drop_in() {
  local runner_number="$1" runner_service="$2"
  local service_drop_in_dir="/etc/systemd/system/${runner_service}.d"
  local service_drop_in_file="$service_drop_in_dir/zz-little-ci-scratch.conf"

  validate_service_drop_in "$runner_number" "$runner_service" || return 1
  run_privileged rm -f -- "$service_drop_in_file" || return 1
  run_privileged rmdir "$service_drop_in_dir" 2>/dev/null || true
  run_privileged systemctl daemon-reload
}

cleanup_runner_resources() {
  local runner_number="$1" runner_service="$2"
  local scratch_dir="/scratch/${RUNNER_NAME_PREFIX}/${runner_number}"
  local cleanup_failed=0

  if [ -n "$runner_service" ]; then
    remove_service_drop_in "$runner_number" "$runner_service" || cleanup_failed=1
  fi

  if run_privileged test -e "/scratch/${RUNNER_NAME_PREFIX}"; then
    if run_privileged test -d "/scratch/${RUNNER_NAME_PREFIX}" && \
      run_privileged test ! -L "/scratch/${RUNNER_NAME_PREFIX}" && \
      [ "$(run_privileged stat -c '%U:%G' "/scratch/${RUNNER_NAME_PREFIX}")" = "root:root" ]; then
      run_privileged rm -rf -- "$scratch_dir" || cleanup_failed=1
    else
      echo "ERROR: refusing untrusted fleet scratch root /scratch/${RUNNER_NAME_PREFIX}" >&2
      cleanup_failed=1
    fi
  fi
  remove_tmpfiles_entry "$scratch_dir" || cleanup_failed=1
  remove_managed_swapfile "$runner_number" || cleanup_failed=1
  run_privileged rmdir "/scratch/${RUNNER_NAME_PREFIX}" 2>/dev/null || true

  [ "$cleanup_failed" -eq 0 ]
}

validate_runner_service() {
  local runner_dir="$1" runner_number="$2" runner_service="$3"
  local service_file="/etc/systemd/system/$runner_service"

  run_privileged test -f "$service_file" && run_privileged test ! -L "$service_file" && \
    run_privileged grep -Fqx -- "ExecStart=$runner_dir/runsvc.sh" "$service_file" && \
    run_privileged grep -Fqx -- "User=$RUNNER_USER" "$service_file" && \
    run_privileged grep -Fqx -- "WorkingDirectory=$runner_dir" "$service_file" || return 1

  validate_service_drop_in "$runner_number" "$runner_service"
}

read_runner_registration() {
  local runner_file="$1"
  python3 -c '
import json, sys
with open(sys.argv[1], encoding="utf-8-sig") as stream:
    settings = json.load(stream)
runner_name = settings.get("agentName")
github_url = settings.get("gitHubUrl")
if not isinstance(runner_name, str) or not runner_name or not isinstance(github_url, str) or not github_url:
    raise SystemExit(".runner is missing a valid agentName or gitHubUrl")
if any(character in runner_name or character in github_url for character in "\t\r\n"):
    raise SystemExit(".runner identity fields contain control characters")
print("%s\t%s" % (runner_name, github_url.rstrip("/")))
' "$runner_file"
}

scan_pending_cleanup_records() {
  local pending_cleanup_dir="/var/lib/little-ci/fleets/${RUNNER_NAME_PREFIX}/pending-cleanup"
  local pending_cleanup_record runner_number scan_failed=0
  if ! run_privileged test -e "$pending_cleanup_dir"; then
    run_privileged test ! -L "$pending_cleanup_dir" || {
      record_failure "pending cleanup path is a broken symlink: $pending_cleanup_dir" "inspect '$pending_cleanup_dir'"
      return 1
    }
    return 0
  fi
  if ! validate_pending_cleanup_dir "$pending_cleanup_dir"; then
    record_failure "pending cleanup directory is not root-owned mode 700" "inspect '$pending_cleanup_dir'"
    return 1
  fi
  for pending_cleanup_record in "$pending_cleanup_dir"/*; do
    [ -e "$pending_cleanup_record" ] || [ -L "$pending_cleanup_record" ] || continue
    runner_number="${pending_cleanup_record##*/}"
    if [[ ! "$runner_number" =~ ^[1-9][0-9]*$ ]] || \
      ! read_pending_cleanup_record "$runner_number" >/dev/null 2>&1; then
      record_failure "pending cleanup record is malformed or untrusted: $pending_cleanup_record" "inspect '$pending_cleanup_record'"
      scan_failed=1
    fi
  done
  [ "$scan_failed" -eq 0 ]
}

process_selected_runner() {
  local runner_number="$1"
  local runner_name="${RUNNER_NAME_PREFIX}-${runner_number}"
  local runner_dir="$RUNNER_HOME/actions-runner-${runner_number}"
  local pending_cleanup_record="/var/lib/little-ci/fleets/${RUNNER_NAME_PREFIX}/pending-cleanup/${runner_number}"
  local runner_registration configured_url registered_number runner_service current_service
  local record_exists=false

  selected_count=$((selected_count + 1))
  if run_privileged test -e "$pending_cleanup_record" || run_privileged test -L "$pending_cleanup_record"; then
    record_exists=true
    if ! runner_service="$(read_pending_cleanup_record "$runner_number" 2>/dev/null)"; then
      record_failure "pending cleanup record is malformed or untrusted: $pending_cleanup_record" "inspect '$pending_cleanup_record'"
      return
    fi
  else
    runner_service=""
  fi

  if [ -e "$runner_dir/.runner" ] || [ -L "$runner_dir/.runner" ]; then
    if [ ! -f "$runner_dir/.runner" ] || [ -L "$runner_dir/.runner" ] || \
      ! runner_registration="$(read_runner_registration "$runner_dir/.runner" 2>/dev/null)"; then
      record_failure "$runner_dir/.runner is unreadable or malformed; no mutation performed" "inspect '$runner_dir/.runner' and restore or remove this runner manually"
      return
    fi
    configured_url="${runner_registration#*$'\t'}"
    registered_number="$(runner_index "${runner_registration%%$'\t'*}" 2>/dev/null || true)"
    if [ "$configured_url" != "$GITHUB_URL" ] || [ "$registered_number" != "$runner_number" ]; then
      record_failure "$runner_dir/.runner does not match the selected fleet; no mutation performed" "inspect '$runner_dir/.runner'"
      return
    fi
    if [ ! -x "$runner_dir/config.sh" ] || [ -L "$runner_dir/config.sh" ]; then
      record_failure "$runner_dir/config.sh is missing or untrusted; no mutation performed" "restore '$runner_dir/config.sh'"
      return
    fi
  elif [ "$record_exists" != true ]; then
    record_failure "$runner_dir has no trustworthy .runner registration; no mutation performed" "inspect '$runner_dir' and restore or remove this runner manually"
    return
  fi

  if [ -e "$runner_dir/.service" ] || [ -L "$runner_dir/.service" ]; then
    if [ ! -f "$runner_dir/.service" ] || [ -L "$runner_dir/.service" ]; then
      record_failure "$runner_dir/.service is untrusted; no mutation performed" "inspect '$runner_dir/.service'"
      return
    fi
    current_service="$(cat "$runner_dir/.service")"
    if [[ ! "$current_service" =~ ^actions\.runner\.[A-Za-z0-9._@-]+\.service$ ]] || \
      { [ "$record_exists" = true ] && [ "$current_service" != "$runner_service" ]; } || \
      ! validate_runner_service "$runner_dir" "$runner_number" "$current_service"; then
      record_failure "$current_service does not belong to $runner_dir and $RUNNER_USER; no mutation performed" "inspect '/etc/systemd/system/$current_service' and '$runner_dir/.service'"
      return
    fi
    runner_service="$current_service"
    if [ ! -x "$runner_dir/svc.sh" ] || [ -L "$runner_dir/svc.sh" ]; then
      record_failure "$runner_dir/svc.sh is missing or untrusted; no mutation performed" "restore '$runner_dir/svc.sh'"
      return
    fi
  elif [ -n "$runner_service" ] && run_privileged test -e "/etc/systemd/system/$runner_service"; then
    record_failure "service $runner_service still exists without authoritative .service metadata; no mutation performed" "inspect '/etc/systemd/system/$runner_service' and '$runner_dir'"
    return
  fi

  if [ "$record_exists" != true ]; then
    if ! create_pending_cleanup_record "$runner_number" "$runner_name" "$runner_dir" "$runner_service"; then
      record_failure "could not create protected cleanup record for $runner_name; no mutation performed" "inspect '/var/lib/little-ci/fleets/$RUNNER_NAME_PREFIX'"
      return
    fi
  fi

  echo "== removing local runner $runner_name ($runner_dir) =="
  if [ -e "$runner_dir/.service" ]; then
    if ! (cd "$runner_dir" && run_privileged ./svc.sh uninstall); then
      record_failure "could not uninstall service $runner_service for $runner_name" "sudo systemctl status '$runner_service'"
      return
    fi
  fi
  if [ -e "$runner_dir/.runner" ]; then
    if ! (cd "$runner_dir" && run_as_runner ./config.sh remove --token "$REMOVETOKEN"); then
      record_failure "could not unregister $runner_name from $GITHUB_URL; protected cleanup record retained" "REMOVETOKEN=<new-token> ./uninstall-runners.sh --runner '$runner_name' --confirm"
      return
    fi
    if [ -e "$runner_dir/.runner" ]; then
      record_failure "config.sh reported success but retained $runner_dir/.runner; host resources were preserved" "inspect '$runner_dir/.runner'"
      return
    fi
  fi

  if ! cleanup_runner_resources "$runner_number" "$runner_service"; then
    record_failure "one or more owned host resources remain for $runner_name; protected cleanup record retained" "REMOVETOKEN=<new-token> ./uninstall-runners.sh --runner '$runner_name' --confirm"
    return
  fi
  if ! run_privileged rm -rf -- "$runner_dir"; then
    record_failure "could not remove unregistered runner directory $runner_dir; protected cleanup record retained" "sudo rm -rf -- '$runner_dir'"
    return
  fi
  if ! remove_pending_cleanup_record "$runner_number"; then
    record_failure "runner cleanup completed but protected cleanup record remains" "sudo rm -f -- '$pending_cleanup_record'"
    return
  fi
  removed_count=$((removed_count + 1))
}

if ! scan_pending_cleanup_records; then
  echo "Refusing runner mutation until pending cleanup state is repaired." >&2
else
  for runner_dir in "$RUNNER_HOME"/actions-runner-*; do
    [ -d "$runner_dir" ] || continue
    directory_number="${runner_dir#"$RUNNER_HOME"/actions-runner-}"
    [[ "$directory_number" =~ ^[1-9][0-9]*$ ]] || continue
    runner_number_is_selected "$directory_number" || continue
    [ ! -L "$runner_dir" ] || { record_failure "refusing symlinked runner directory $runner_dir" "inspect '$runner_dir'"; continue; }
    process_selected_runner "$directory_number"
  done

  pending_cleanup_dir="/var/lib/little-ci/fleets/${RUNNER_NAME_PREFIX}/pending-cleanup"
  if run_privileged test -d "$pending_cleanup_dir"; then
    for pending_cleanup_record in "$pending_cleanup_dir"/*; do
      [ -e "$pending_cleanup_record" ] || continue
      directory_number="${pending_cleanup_record##*/}"
      [[ "$directory_number" =~ ^[1-9][0-9]*$ ]] || continue
      runner_number_is_selected "$directory_number" || continue
      [ ! -d "$RUNNER_HOME/actions-runner-${directory_number}" ] || continue
      process_selected_runner "$directory_number"
    done
  fi
fi

if [ "$selected_count" -eq 0 ]; then
  echo "No selected local runners found. The Mac wrapper will still check for stale GitHub registrations."
fi
echo "Local removal complete: $removed_count removed, $failure_count failed."
if [ "$failure_count" -ne 0 ]; then
  echo "Recovery steps:" >&2
  for recovery_step in "${recovery_steps[@]}"; do
    echo "  $recovery_step" >&2
  done
  exit 1
fi
