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

cleanup_guest_runtime_archive() {
  [ -z "${guest_runtime_archive_path:-}" ] || rm -f -- "$guest_runtime_archive_path"
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
  command -v python3 >/dev/null 2>&1 || \
    fail "python3 is required to validate OrbStack machine settings"
}

validate_config() {
  [ "$RUNNER_USER" != root ] || \
    fail "RUNNER_USER must be a dedicated non-root account"
  [[ "$RUNNER_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || \
    fail "RUNNER_USER must be a valid Linux username"
  [[ "$RUNNER_NAME_PREFIX" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || \
    fail "RUNNER_NAME_PREFIX may contain only letters, numbers, dots, underscores, and hyphens"
  [[ "$ORB_MACHINE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || \
    fail "ORB_MACHINE may contain only letters, numbers, dots, underscores, and hyphens"
  [[ "$RUNNER_HOME" = /* && "$RUNNER_HOME" != / ]] || \
    fail "RUNNER_HOME must be an absolute, non-root path"
  [[ "$RUNNER_HOME" =~ ^/[A-Za-z0-9._/-]+$ ]] || \
    fail "RUNNER_HOME contains unsupported characters"
  [[ "$ORB_CPUS" =~ ^[1-9][0-9]*$ ]] || \
    fail "ORB_CPUS must be a positive integer"
  [[ "$RUNNER_COUNT" =~ ^[1-9][0-9]*$ ]] || \
    fail "RUNNER_COUNT must be a positive integer"
  orbstack_memory_size_to_mib "$ORB_MEMORY" >/dev/null || \
    fail "ORB_MEMORY must be positive MiB or use an M, MiB, G, or GiB suffix"
  orbstack_disk_size_to_bytes "$ORB_DISK" >/dev/null || \
    fail "ORB_DISK must be positive GiB or use a G or GiB suffix"
}

initialize_guest_runtime_paths() {
  local runtime_path
  guest_runtime_paths=(
    provision-box.sh
    install-runners.sh
    uninstall-runners.sh
    provision-postgres.sh
    lib/github-target.sh
    lib/orbstack-machine.sh
  )

  if [ -e "$repo_dir/config.env" ] || [ -L "$repo_dir/config.env" ]; then
    [ -f "$repo_dir/config.env" ] && [ ! -L "$repo_dir/config.env" ] || \
      fail "config.env must be a regular, non-symlink file"
    guest_runtime_paths+=(config.env)
  fi

  for runtime_path in "${guest_runtime_paths[@]}"; do
    [ -f "$repo_dir/$runtime_path" ] && [ ! -L "$repo_dir/$runtime_path" ] || \
      fail "required guest runtime file is missing or symlinked: $runtime_path"
    case "$runtime_path" in
      lib/*|config.env) ;;
      *) [ -x "$repo_dir/$runtime_path" ] || fail "guest runtime script is not executable: $runtime_path" ;;
    esac
  done
}

validate_existing_machine() {
  orbstack_validate_machine 1 || \
    fail "existing machine '$ORB_MACHINE' is incompatible; choose a new name or correct its settings"
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

copy_guest_runtime() {
  guest_runtime_archive_path="$(mktemp "${TMPDIR:-/tmp}/little-ci.XXXXXX.tar.gz")"
  trap cleanup_guest_runtime_archive EXIT HUP INT TERM

  echo "== copying Little-CI guest runtime to $ORB_MACHINE:$remote_repo_dir =="
  tar -C "$repo_dir" -czf "$guest_runtime_archive_path" "${guest_runtime_paths[@]}"
  orbctl run -m "$ORB_MACHINE" -u "$RUNNER_USER" mkdir -p "$remote_repo_dir"
  # Isolated machines have no Mac bind mount, so stream the archive over stdin.
  orbctl run -m "$ORB_MACHINE" -u "$RUNNER_USER" \
    tar -xzf - -C "$remote_repo_dir" < "$guest_runtime_archive_path"

  cleanup_guest_runtime_archive
  guest_runtime_archive_path=""
  trap - EXIT HUP INT TERM
}

main() {
  local machine_names machine_was_created
  repo_dir="$(cd "$(dirname "$0")" && pwd)"
  guest_runtime_paths=()
  initialize_guest_runtime_paths
  . "$repo_dir/lib/github-target.sh"
  . "$repo_dir/lib/orbstack-machine.sh"
  reject_persisted_github_credentials "$repo_dir/config.env" || exit 1
  [ -f "$repo_dir/config.env" ] && . "$repo_dir/config.env"

  RUNNER_USER="${RUNNER_USER:-deploy}"
  github_target_init
  require_apple_silicon_mac
  github_fleet_init
  if [ -z "${ORB_MACHINE:-}" ]; then
    case "$RUNNER_NAME_PREFIX" in
      *[A-Z]*)
        fail "set ORB_MACHINE explicitly when an overridden RUNNER_NAME_PREFIX contains uppercase letters"
        ;;
    esac
    ORB_MACHINE="$RUNNER_NAME_PREFIX"
  fi
  ORB_CPUS="${ORB_CPUS:-2}"
  ORB_MEMORY="${ORB_MEMORY:-4G}"
  ORB_DISK="${ORB_DISK:-48G}"
  RUNNER_COUNT="${RUNNER_COUNT:-1}"
  RUNNER_HOME="${RUNNER_HOME:-/home/${RUNNER_USER}}"
  remote_repo_dir="$RUNNER_HOME/little-ci"
  guest_runtime_archive_path=""
  machine_was_created=0

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
    machine_was_created=1
  fi

  wait_until_ready
  if [ "$machine_was_created" = 1 ]; then
    orbstack_validate_machine 1 || \
      fail "new machine '$ORB_MACHINE' does not match the requested secure configuration"
    orbstack_write_machine_identity || fail "could not write Little-CI ownership identity"
    orbstack_verify_machine_identity || fail "could not verify Little-CI ownership identity"
  else
    orbstack_verify_machine_identity || \
      fail "refusing to modify an existing machine without matching Little-CI ownership"
  fi

  echo "== installing base packages and Docker =="
  orbctl run -m "$ORB_MACHINE" -u root bash -s <<'EOF'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
install -d -m 755 /etc/needrestart/conf.d
cat > /etc/needrestart/conf.d/actions_runner_services.conf <<'NEEDRESTART'
$nrconf{override_rc}{qr(^actions\.runner\..+\.service$)} = 0;
NEEDRESTART
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

  copy_guest_runtime

  echo "== configuring scratch space and cleanup =="
  orbctl run -m "$ORB_MACHINE" -u root env \
    "GITHUB_SCOPE=$GITHUB_SCOPE" \
    "GITHUB_URL=$GITHUB_URL" \
    "RUNNER_GROUP=${RUNNER_GROUP:-}" \
    "FLEET_ID=${FLEET_ID:-}" \
    "RUNNER_NAME_PREFIX=$RUNNER_NAME_PREFIX" \
    "RUNNER_USER=$RUNNER_USER" \
    "RUNNER_COUNT=$RUNNER_COUNT" \
    bash -c 'cd "$1" && ./provision-box.sh' bash "$remote_repo_dir"

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
