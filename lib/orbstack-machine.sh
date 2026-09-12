#!/usr/bin/env bash

orbstack_memory_size_to_mib() {
  local configured_size="$1" size_number multiplier
  case "$configured_size" in
    *GiB) size_number="${configured_size%GiB}"; multiplier=1024 ;;
    *G) size_number="${configured_size%G}"; multiplier=1024 ;;
    *MiB) size_number="${configured_size%MiB}"; multiplier=1 ;;
    *M) size_number="${configured_size%M}"; multiplier=1 ;;
    *) size_number="$configured_size"; multiplier=1 ;;
  esac
  [[ "$size_number" =~ ^[1-9][0-9]*$ ]] || return 1
  printf '%s\n' "$((size_number * multiplier))"
}

orbstack_disk_size_to_bytes() {
  local configured_size="$1" size_number
  case "$configured_size" in
    *GiB) size_number="${configured_size%GiB}" ;;
    *G) size_number="${configured_size%G}" ;;
    *) size_number="$configured_size" ;;
  esac
  [[ "$size_number" =~ ^[1-9][0-9]*$ ]] || return 1
  printf '%s\n' "$((size_number * 1024 * 1024 * 1024))"
}

little_ci_machine_identity() {
  local identity_values
  identity_values="$ORB_MACHINE:$GITHUB_SCOPE:$GITHUB_TARGET:$RUNNER_NAME_PREFIX:$RUNNER_USER:$RUNNER_HOME"
  case "$identity_values" in
    *$'\n'*|*$'\r'*)
      echo "Little-CI machine identity values must not contain newlines" >&2
      return 1
      ;;
  esac
  printf 'machine=%s\nscope=%s\ntarget=%s\nprefix=%s\nuser=%s\nhome=%s\n' \
    "$ORB_MACHINE" "$GITHUB_SCOPE" "$GITHUB_TARGET" "$RUNNER_NAME_PREFIX" \
    "$RUNNER_USER" "$RUNNER_HOME"
}

orbstack_validate_machine() {
  local check_resources="${1:-0}"
  local machine_json machine_facts
  local machine_name machine_distro machine_version machine_architecture machine_isolated
  local machine_network_isolated machine_ssh_agent
  local machine_user machine_cpus machine_memory_mib machine_disk_bytes
  local configured_mounts expected_memory_mib expected_disk_bytes

  case "$check_resources" in
    0|1) ;;
    *)
      echo "orbstack_validate_machine expects resource validation mode 0 or 1" >&2
      return 1
      ;;
  esac

  machine_json="$(orbctl info "$ORB_MACHINE" --format json)" || {
    echo "could not inspect OrbStack machine '$ORB_MACHINE'" >&2
    return 1
  }
  machine_facts="$(python3 -c '
import json
import sys

record = json.load(sys.stdin)["record"]
image = record["image"]
config = record["config"]
values = (
    record["name"],
    image["distro"],
    image["version"],
    image["arch"],
    config["isolated"],
    config["isolate_network"],
    config["forward_ssh_agent"],
    config["default_username"],
    config["cpu_limit"],
    config["memory_limit_mib"],
    config["disk_limit_bytes"],
)
def serialize(value):
    if isinstance(value, bool):
        return str(value).lower()
    return str(value)

print("|".join(serialize(value) for value in values))
' <<< "$machine_json")" || {
    echo "could not inspect OrbStack machine '$ORB_MACHINE'" >&2
    return 1
  }

  IFS='|' read -r machine_name machine_distro machine_version machine_architecture \
    machine_isolated machine_network_isolated machine_ssh_agent \
    machine_user machine_cpus machine_memory_mib machine_disk_bytes <<< "$machine_facts"

  [ "$machine_name" = "$ORB_MACHINE" ] || {
    echo "OrbStack returned machine '$machine_name', expected '$ORB_MACHINE'" >&2
    return 1
  }
  [ "$machine_distro" = ubuntu ] && [ "$machine_version" = noble ] || {
    echo "OrbStack machine '$ORB_MACHINE' must use Ubuntu 24.04 (noble)" >&2
    return 1
  }
  [ "$machine_architecture" = arm64 ] || {
    echo "OrbStack machine '$ORB_MACHINE' must use arm64" >&2
    return 1
  }
  [ "$machine_isolated" = true ] && [ "$machine_network_isolated" = true ] || {
    echo "OrbStack machine '$ORB_MACHINE' must enable isolation and network isolation" >&2
    return 1
  }
  [ "$machine_ssh_agent" = false ] || {
    echo "OrbStack machine '$ORB_MACHINE' must disable SSH-agent forwarding and Mac mounts" >&2
    return 1
  }
  configured_mounts="$(orbctl config get "machine.$ORB_MACHINE.mounts")" || {
    echo "could not verify configured mounts for OrbStack machine '$ORB_MACHINE'" >&2
    return 1
  }
  [ -z "$configured_mounts" ] || {
    echo "OrbStack machine '$ORB_MACHINE' must disable SSH-agent forwarding and Mac mounts" >&2
    return 1
  }
  [ "$machine_user" = "$RUNNER_USER" ] || {
    echo "OrbStack machine '$ORB_MACHINE' default user is '$machine_user', expected '$RUNNER_USER'" >&2
    return 1
  }

  if [ "$check_resources" = 1 ]; then
    expected_memory_mib="$(orbstack_memory_size_to_mib "$ORB_MEMORY")" || {
      echo "ORB_MEMORY has an unsupported value: '$ORB_MEMORY'" >&2
      return 1
    }
    expected_disk_bytes="$(orbstack_disk_size_to_bytes "$ORB_DISK")" || {
      echo "ORB_DISK has an unsupported value: '$ORB_DISK'" >&2
      return 1
    }
    [ "$machine_cpus" = "$ORB_CPUS" ] && \
      [ "$machine_memory_mib" = "$expected_memory_mib" ] && \
      [ "$machine_disk_bytes" = "$expected_disk_bytes" ] || {
        printf "OrbStack machine '%s' resources are CPU=%s, memory=%sMiB, disk=%sB; expected CPU=%s, memory=%sMiB, disk=%sB\n" \
          "$ORB_MACHINE" "$machine_cpus" "$machine_memory_mib" "$machine_disk_bytes" \
          "$ORB_CPUS" "$expected_memory_mib" "$expected_disk_bytes" >&2
        return 1
      }
  fi
}

orbstack_write_machine_identity() {
  local expected_identity
  expected_identity="$(little_ci_machine_identity)" || return 1
  printf '%s\n' "$expected_identity" | orbctl run -m "$ORB_MACHINE" -u root bash -c '
    set -eu
    identity_dir=/etc/little-ci
    identity_path=$identity_dir/identity
    pending_identity_path=$identity_dir/.identity.new.$$
    install -d -o root -g root -m 700 "$identity_dir"
    trap '\''rm -f -- "$pending_identity_path"'\'' EXIT HUP INT TERM
    cat > "$pending_identity_path"
    chown root:root "$pending_identity_path"
    chmod 600 "$pending_identity_path"
    mv "$pending_identity_path" "$identity_path"
    trap - EXIT HUP INT TERM
  '
}

orbstack_verify_machine_identity() {
  local actual_identity expected_identity identity_permissions
  expected_identity="$(little_ci_machine_identity)" || return 1
  identity_permissions="$(orbctl run -m "$ORB_MACHINE" -u root \
    stat -c '%u:%g:%a' /etc/little-ci /etc/little-ci/identity 2>/dev/null)" || {
    echo "OrbStack machine '$ORB_MACHINE' has no protected Little-CI identity" >&2
    return 1
  }
  [ "$identity_permissions" = $'0:0:700\n0:0:600' ] || {
    echo "OrbStack machine '$ORB_MACHINE' has an unprotected Little-CI identity" >&2
    return 1
  }
  actual_identity="$(orbctl run -m "$ORB_MACHINE" -u root cat /etc/little-ci/identity 2>/dev/null)" || {
    echo "OrbStack machine '$ORB_MACHINE' is not owned by this Little-CI fleet" >&2
    return 1
  }
  [ "$actual_identity" = "$expected_identity" ] || {
    echo "OrbStack machine '$ORB_MACHINE' belongs to a different Little-CI fleet" >&2
    return 1
  }
}
