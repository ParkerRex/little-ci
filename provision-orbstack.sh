#!/usr/bin/env bash
# provision-orbstack.sh — create and prepare Little-CI's OrbStack machine.
#
# Run this script on an Apple Silicon Mac. It creates an isolated,
# network-isolated Ubuntu 24.04 arm64 machine, installs base dependencies, and
# copies the Little-CI scripts into the machine. Safe to re-run after creation;
# incompatible existing machines are rejected instead of changed implicitly.

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

memory_size_to_mib() {
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

disk_size_to_bytes() {
  local configured_size="$1" size_number
  case "$configured_size" in
    *GiB) size_number="${configured_size%GiB}" ;;
    *G) size_number="${configured_size%G}" ;;
    *) size_number="$configured_size" ;;
  esac
  [[ "$size_number" =~ ^[1-9][0-9]*$ ]] || return 1
  printf '%s\n' "$((size_number * 1024 * 1024 * 1024))"
}

cleanup_repository_archive() {
  [ -z "${repository_archive_path:-}" ] || rm -f -- "$repository_archive_path"
}

require_apple_silicon_mac() {
  local operating_system host_architecture
  operating_system="$(uname -s)"
  host_architecture="$(uname -m)"

  [ "$operating_system" = "Darwin" ] || \
    fail "provision-orbstack.sh must run on macOS (found $operating_system)"
  [ "$host_architecture" = "arm64" ] || \
    fail "Little-CI requires an Apple Silicon Mac (found $host_architecture)"
  command -v orbctl >/dev/null 2>&1 || \
    fail "orbctl is not on PATH; install and start OrbStack first"
  command -v plutil >/dev/null 2>&1 || \
    fail "plutil is required to validate OrbStack machine settings"
}

validate_config() {
  [[ "$RUNNER_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || \
    fail "RUNNER_USER must be a valid Linux username"
  [[ "$RUNNER_NAME_PREFIX" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || \
    fail "RUNNER_NAME_PREFIX may contain only letters, numbers, dots, underscores, and hyphens"
  [[ "$ORB_MACHINE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || \
    fail "ORB_MACHINE may contain only letters, numbers, dots, underscores, and hyphens"
  [[ "$RUNNER_HOME" = /* && "$RUNNER_HOME" != / ]] || \
    fail "RUNNER_HOME must be an absolute, non-root path"
  [[ "$ORB_CPUS" =~ ^[1-9][0-9]*$ ]] || \
    fail "ORB_CPUS must be a positive integer"
  [[ "$RUNNER_COUNT" =~ ^[1-9][0-9]*$ ]] || \
    fail "RUNNER_COUNT must be a positive integer"
  expected_memory_mib="$(memory_size_to_mib "$ORB_MEMORY")" || \
    fail "ORB_MEMORY must be positive MiB or use an M, MiB, G, or GiB suffix"
  expected_disk_bytes="$(disk_size_to_bytes "$ORB_DISK")" || \
    fail "ORB_DISK must be positive GiB or use a G or GiB suffix"
}

machine_property() {
  local property_path="$1"
  printf '%s' "$machine_info" | plutil -extract "$property_path" raw -o - -- - 2>/dev/null
}

require_machine_property() {
  local property_path="$1" expected_value="$2" setting_name="$3" actual_value
  actual_value="$(machine_property "$property_path")" || \
    fail "could not read $setting_name from OrbStack metadata for '$ORB_MACHINE'"
  [ "$actual_value" = "$expected_value" ] || \
    fail "existing machine '$ORB_MACHINE' has $setting_name '$actual_value'; expected '$expected_value'. Delete or rename that machine, then rerun this script"
}

validate_existing_machine() {
  machine_info="$(orbctl info "$ORB_MACHINE" --format json)" || \
    fail "could not inspect existing OrbStack machine '$ORB_MACHINE'"

  require_machine_property record.image.distro ubuntu distro
  require_machine_property record.image.version noble "Ubuntu version"
  require_machine_property record.image.arch arm64 architecture
  require_machine_property record.config.isolated true isolation
  require_machine_property record.config.isolate_network true "network isolation"
  require_machine_property record.config.default_username "$RUNNER_USER" "default username"
  require_machine_property record.config.cpu_limit "$ORB_CPUS" "CPU limit"
  require_machine_property record.config.memory_limit_mib "$expected_memory_mib" "memory limit in MiB"
  require_machine_property record.config.disk_limit_bytes "$expected_disk_bytes" "disk limit in bytes"
}

wait_until_ready() {
  local attempt
  for attempt in $(seq 1 90); do
    if orbctl run -m "$ORB_MACHINE" -u root true 2>/dev/null; then
      return 0
    fi
    sleep 2
  done
  fail "machine '$ORB_MACHINE' did not become reachable within 180 seconds"
}

copy_repository() {
  repository_archive_path="$(mktemp "${TMPDIR:-/tmp}/little-ci.XXXXXX.tar.gz")"
  trap cleanup_repository_archive EXIT HUP INT TERM

  echo "== copying Little-CI to $ORB_MACHINE:$remote_repo_dir =="
  orbctl run -m "$ORB_MACHINE" -u "$RUNNER_USER" mkdir -p "$remote_repo_dir"
  tar -C "$repo_dir" --exclude .git --exclude 'actions-runner*' --exclude '*.tar.gz' -czf "$repository_archive_path" .
  # Isolated machines have no Mac bind mount, so stream the archive over stdin.
  orbctl run -m "$ORB_MACHINE" -u "$RUNNER_USER" bash -lc \
    "cat > /tmp/little-ci.tar.gz" < "$repository_archive_path"
  orbctl run -m "$ORB_MACHINE" -u "$RUNNER_USER" tar -xzf /tmp/little-ci.tar.gz -C "$remote_repo_dir"
  orbctl run -m "$ORB_MACHINE" -u "$RUNNER_USER" rm -f /tmp/little-ci.tar.gz

  cleanup_repository_archive
  repository_archive_path=""
  trap - EXIT HUP INT TERM
}

main() {
  local machine_names
  repo_dir="$(cd "$(dirname "$0")" && pwd)"
  [ -f "$repo_dir/lib/github-target.sh" ] || fail "missing $repo_dir/lib/github-target.sh"
  . "$repo_dir/lib/github-target.sh"
  reject_persisted_github_credentials "$repo_dir/config.env" || exit 1
  [ -f "$repo_dir/config.env" ] && . "$repo_dir/config.env"

  github_target_init
  RUNNER_USER="${RUNNER_USER:-deploy}"
  RUNNER_NAME_PREFIX="${RUNNER_NAME_PREFIX:-little-ci-${GITHUB_TARGET//\//-}}"
  ORB_MACHINE="${ORB_MACHINE:-$RUNNER_NAME_PREFIX}"
  ORB_CPUS="${ORB_CPUS:-2}"
  ORB_MEMORY="${ORB_MEMORY:-4G}"
  ORB_DISK="${ORB_DISK:-48G}"
  RUNNER_COUNT="${RUNNER_COUNT:-1}"
  RUNNER_HOME="${RUNNER_HOME:-/home/${RUNNER_USER}}"
  remote_repo_dir="$RUNNER_HOME/little-ci"
  machine_info=""
  repository_archive_path=""
  expected_memory_mib=""
  expected_disk_bytes=""

  require_apple_silicon_mac
  validate_config

  machine_names="$(orbctl list -q)" || \
    fail "could not query OrbStack; make sure the OrbStack app is running"
  if grep -Fqx "$ORB_MACHINE" <<< "$machine_names"; then
    echo "== validating existing machine $ORB_MACHINE =="
    validate_existing_machine
    echo "== starting existing machine $ORB_MACHINE =="
    orbctl start "$ORB_MACHINE" >/dev/null
  else
    echo "== creating isolated Ubuntu 24.04 arm64 machine $ORB_MACHINE for $RUNNER_COUNT runner(s) ($ORB_CPUS CPU, $ORB_MEMORY memory, $ORB_DISK disk) =="
    orbctl create \
      --arch arm64 \
      --cpus "$ORB_CPUS" \
      --memory "$ORB_MEMORY" \
      --disk "$ORB_DISK" \
      --isolated \
      --isolate-network \
      --user "$RUNNER_USER" \
      ubuntu:24.04 \
      "$ORB_MACHINE"
  fi

  wait_until_ready

  echo "== installing base packages and Docker =="
  orbctl run -m "$ORB_MACHINE" -u root bash -s <<'EOF'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y curl ca-certificates git jq python3 unzip libatomic1
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi
EOF

  # The runner needs Docker access for container jobs. Docker group membership is
  # root-equivalent, so do not also leave the service account with sudo access.
  orbctl run -m "$ORB_MACHINE" -u root bash -s -- "$RUNNER_USER" <<'EOF'
set -euo pipefail
runner_user="$1"
usermod -aG docker "$runner_user"
gpasswd -d "$runner_user" sudo >/dev/null 2>&1 || true

for sudoers_path in "/etc/sudoers.d/$runner_user" /etc/sudoers.d/orbstack; do
  [ -f "$sudoers_path" ] || continue
  if [ "$(sed '/^[[:space:]]*$/d' "$sudoers_path")" = "$runner_user ALL=(ALL) NOPASSWD:ALL" ]; then
    rm -f "$sudoers_path"
  else
    echo "WARN: preserving unexpected sudoers content in $sudoers_path" >&2
  fi
done
EOF

  # Some workflows expect Ubuntu's deb822 source file. OrbStack's image may
  # still ship the classic /etc/apt/sources.list instead.
  echo "== ensuring Ubuntu deb822 package sources =="
  orbctl run -m "$ORB_MACHINE" -u root bash -s <<'EOF'
set -euo pipefail
if [ "$(dpkg --print-architecture)" != arm64 ]; then
  echo "ERROR: Little-CI OrbStack guest must use arm64" >&2
  exit 1
fi
if [ ! -f /etc/apt/sources.list.d/ubuntu.sources ]; then
  cat > /etc/apt/sources.list.d/ubuntu.sources <<'SOURCES'
Types: deb
URIs: http://ports.ubuntu.com/ubuntu-ports
Suites: noble noble-updates noble-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
SOURCES
fi
if [ -s /etc/apt/sources.list ]; then
  mv /etc/apt/sources.list /etc/apt/sources.list.distrobuilder.bak
  : > /etc/apt/sources.list
fi
apt-get update
test -f /etc/apt/sources.list.d/ubuntu.sources
EOF

  copy_repository

  echo "== configuring scratch space and cleanup =="
  orbctl run -m "$ORB_MACHINE" -u root bash -lc "cd '$remote_repo_dir' && ./provision-box.sh"

  echo "== $ORB_MACHINE ready =="
  orbctl run -m "$ORB_MACHINE" -u "$RUNNER_USER" bash -lc \
    'uname -a; nproc; free -h; docker --version; if sudo -n true 2>/dev/null; then echo "ERROR: runner still has passwordless sudo" >&2; exit 1; else echo sudo=disabled; fi'
  echo "Next: ./install-runners-orb.sh"
}

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  return 0
fi

set -euo pipefail
main "$@"
