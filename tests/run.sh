#!/usr/bin/env bash
set -uo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_count=0
failure_count=0
current_tmp=""

cleanup() {
  if [ -n "$current_tmp" ] && [ -d "$current_tmp" ]; then
    rm -rf "$current_tmp"
  fi
}
trap cleanup EXIT

fail() {
  printf '    %s\n' "$*" >&2
  exit 1
}

assert_status() {
  local expected="$1"
  local actual="$2"
  [ "$actual" -eq "$expected" ] || fail "expected exit $expected, got $actual"
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  case "$haystack" in
    *"$needle"*) ;;
    *) fail "expected output to contain: $needle" ;;
  esac
}

assert_file_contains() {
  local file="$1"
  local needle="$2"
  [ -f "$file" ] || fail "missing file: $file"
  grep -F -- "$needle" "$file" >/dev/null || fail "expected $file to contain: $needle"
}

assert_file_not_contains() {
  local file="$1"
  local needle="$2"
  if [ -f "$file" ] && grep -F -- "$needle" "$file" >/dev/null; then
    fail "expected $file not to contain: $needle"
  fi
}

new_sandbox() {
  cleanup
  current_tmp="$(mktemp -d "${TMPDIR:-/tmp}/little-ci-tests.XXXXXX")"
  mkdir -p "$current_tmp/repo" "$current_tmp/bin"
  find "$repo_root" -maxdepth 1 -type f -name '*.sh' -exec cp {} "$current_tmp/repo/" \;
  if [ -d "$repo_root/lib" ]; then
    cp -R "$repo_root/lib" "$current_tmp/repo/lib"
  fi
  chmod +x "$current_tmp/repo/"*.sh
  : > "$current_tmp/command.log"
}

install_gh_mock() {
  cat > "$current_tmp/bin/gh" <<'MOCK'
#!/usr/bin/env bash
printf 'gh' >> "${MOCK_COMMAND_LOG:?}"
printf ' %q' "$@" >> "$MOCK_COMMAND_LOG"
printf '\n' >> "$MOCK_COMMAND_LOG"
if [[ " $* " == *" --jq .token "* ]]; then
  printf '%s\n' "${MOCK_GH_TOKEN:-registration-token}"
else
  if [ -n "${MOCK_GH_RESPONSE:-}" ]; then
    printf '%s\n' "$MOCK_GH_RESPONSE"
  else
    printf '{"runners":[]}\n'
  fi
fi
MOCK
  chmod +x "$current_tmp/bin/gh"
}

install_uname_mock() {
  local architecture="$1"
  local operating_system="${2:-Darwin}"
  cat > "$current_tmp/bin/uname" <<MOCK
#!/usr/bin/env bash
case "\${1:-}" in
  -m) printf '%s\\n' '$architecture' ;;
  -s) printf '%s\\n' '$operating_system' ;;
  *) /usr/bin/uname "\$@" ;;
esac
MOCK
  chmod +x "$current_tmp/bin/uname"
}

install_orbctl_machine_mock() {
  cat > "$current_tmp/bin/orbctl" <<'MOCK'
#!/usr/bin/env bash
printf 'orbctl' >> "${MOCK_COMMAND_LOG:?}"
printf ' %q' "$@" >> "$MOCK_COMMAND_LOG"
printf ' ORBENV=%q' "${ORBENV:-}" >> "$MOCK_COMMAND_LOG"
printf '\n' >> "$MOCK_COMMAND_LOG"

case "${1:-}" in
  list)
    [ "${MOCK_MACHINE_EXISTS:-0}" = 1 ] && printf '%s\n' "${MOCK_MACHINE_NAME:-little-ci}"
    exit 0
    ;;
  info)
    printf '%s\n' "${MOCK_ORB_INFO:?}"
    ;;
  start)
    exit "${MOCK_START_STATUS:-0}"
    ;;
  create)
    exit "${MOCK_CREATE_STATUS:-0}"
    ;;
  run)
    if [[ " $* " == *" uname -m "* ]]; then
      printf 'aarch64\n'
    fi
    exit "${MOCK_ORBCTL_STATUS:-0}"
    ;;
  *)
    exit "${MOCK_ORBCTL_STATUS:-0}"
    ;;
esac
MOCK
  chmod +x "$current_tmp/bin/orbctl"
}

run_case() {
  local name="$1"
  shift
  test_count=$((test_count + 1))
  printf 'TEST %s\n' "$name"
  if ( trap cleanup EXIT; "$@" ); then
    printf '  PASS\n'
  else
    failure_count=$((failure_count + 1))
    printf '  FAIL\n' >&2
  fi
}

test_bash_syntax() {
  local script
  while IFS= read -r script; do
    bash -n "$script"
  done < <(find "$repo_root" -maxdepth 2 -type f -name '*.sh' -print | sort)
}

test_repository_api_routing() {
  new_sandbox
  install_gh_mock
  local output status
  set +e
  output="$(
    cd "$current_tmp/repo" &&
      PATH="$current_tmp/bin:$PATH" \
      MOCK_COMMAND_LOG="$current_tmp/command.log" \
      MOCK_GH_RESPONSE='{"runners":[{"name":"little-ci-acme-widget-1","status":"online","labels":[{"name":"little-ci-acme-widget"}]}]}' \
      GITHUB_SCOPE=repository \
      GITHUB_URL=https://github.com/acme/widget \
      RUNNER_NAME_PREFIX=little-ci-acme-widget \
      EXPECTED_RUNNERS=1 \
      ./check-runners.sh 2>&1
  )"
  status=$?
  set -e
  assert_status 0 "$status"
  assert_file_contains "$current_tmp/command.log" '/repos/acme/widget/actions/runners'
  assert_contains "$output" 'GREEN'
}

test_organization_api_routing() {
  new_sandbox
  install_gh_mock
  local output status
  set +e
  output="$(
    cd "$current_tmp/repo" &&
      PATH="$current_tmp/bin:$PATH" \
      MOCK_COMMAND_LOG="$current_tmp/command.log" \
      MOCK_GH_RESPONSE='{"runners":[{"name":"little-ci-acme-1","status":"online","labels":[{"name":"little-ci-acme"}]}]}' \
      GITHUB_SCOPE=organization \
      GITHUB_URL=https://github.com/acme \
      RUNNER_NAME_PREFIX=little-ci-acme \
      EXPECTED_RUNNERS=1 \
      ./check-runners.sh 2>&1
  )"
  status=$?
  set -e
  assert_status 0 "$status"
  assert_file_contains "$current_tmp/command.log" '/orgs/acme/actions/runners'
  assert_contains "$output" 'GREEN'
}

test_health_check_ignores_unrelated_runners() {
  new_sandbox
  install_gh_mock
  local output status
  set +e
  output="$(
    cd "$current_tmp/repo" &&
      PATH="$current_tmp/bin:$PATH" \
      MOCK_COMMAND_LOG="$current_tmp/command.log" \
      MOCK_GH_RESPONSE='{"runners":[{"name":"little-ci-acme-widget-1","status":"online","labels":[{"name":"little-ci-acme-widget"}]},{"name":"other-fleet-1","status":"online","labels":[{"name":"other-fleet"}]},{"name":"other-fleet-2","status":"online","labels":[{"name":"other-fleet"}]}]}' \
      GITHUB_SCOPE=repository \
      GITHUB_URL=https://github.com/acme/widget \
      RUNNER_NAME_PREFIX=little-ci-acme-widget \
      EXPECTED_RUNNERS=2 \
      ./check-runners.sh 2>&1
  )"
  status=$?
  set -e
  assert_status 1 "$status"
  assert_contains "$output" 'RED'
  assert_contains "$output" 'little-ci-acme-widget-2'
}

test_orbstack_rejects_intel_mac() {
  new_sandbox
  install_uname_mock x86_64
  cat > "$current_tmp/bin/orbctl" <<'MOCK'
#!/usr/bin/env bash
printf 'orbctl %s\n' "$*" >> "${MOCK_COMMAND_LOG:?}"
exit 99
MOCK
  chmod +x "$current_tmp/bin/orbctl"

  local output status
  set +e
  output="$(
    cd "$current_tmp/repo" &&
      PATH="$current_tmp/bin:$PATH" \
      MOCK_COMMAND_LOG="$current_tmp/command.log" \
      GITHUB_URL=https://github.com/acme/widget \
      ./provision-orbstack.sh 2>&1
  )"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'Intel Mac unexpectedly accepted'
  assert_contains "$output" 'Apple Silicon'
  assert_file_not_contains "$current_tmp/command.log" 'orbctl'
}

test_orbstack_creation_uses_secure_arm_defaults() {
  new_sandbox
  install_uname_mock arm64
  install_orbctl_machine_mock

  local output status
  set +e
  output="$(
    cd "$current_tmp/repo" &&
      PATH="$current_tmp/bin:$PATH" \
      MOCK_COMMAND_LOG="$current_tmp/command.log" \
      MOCK_MACHINE_EXISTS=0 \
      MOCK_CREATE_STATUS=77 \
      GITHUB_URL=https://github.com/acme/widget \
      ./provision-orbstack.sh 2>&1
  )"
  status=$?
  set -e
  assert_status 77 "$status"
  assert_file_contains "$current_tmp/command.log" 'orbctl create --arch arm64 --cpus 2 --memory 4G --disk 48G --isolated --isolate-network --user deploy ubuntu:24.04 little-ci-acme-widget'
  assert_contains "$output" '1 runner'
}

test_existing_orbstack_machine_is_validated_before_start() {
  new_sandbox
  install_uname_mock arm64
  install_orbctl_machine_mock

  local output status
  set +e
  output="$(
    cd "$current_tmp/repo" &&
      PATH="$current_tmp/bin:$PATH" \
      MOCK_COMMAND_LOG="$current_tmp/command.log" \
      MOCK_MACHINE_EXISTS=1 \
      MOCK_MACHINE_NAME=little-ci-acme-widget \
      MOCK_ORB_INFO='{"record":{"image":{"distro":"ubuntu","version":"noble","arch":"arm64"},"config":{"isolated":true,"isolate_network":false,"default_username":"deploy","cpu_limit":2,"memory_limit_mib":4096,"disk_limit_bytes":51539607552}}}' \
      GITHUB_URL=https://github.com/acme/widget \
      ./provision-orbstack.sh 2>&1
  )"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'insecure existing machine unexpectedly accepted'
  assert_contains "$output" 'network isolation'
  assert_file_contains "$current_tmp/command.log" 'orbctl info little-ci-acme-widget --format json'
  assert_file_not_contains "$current_tmp/command.log" 'orbctl start'
}

test_compatible_orbstack_machine_reaches_start() {
  new_sandbox
  install_uname_mock arm64
  install_orbctl_machine_mock

  local status
  set +e
  (
    cd "$current_tmp/repo" &&
      PATH="$current_tmp/bin:$PATH" \
      MOCK_COMMAND_LOG="$current_tmp/command.log" \
      MOCK_MACHINE_EXISTS=1 \
      MOCK_MACHINE_NAME=little-ci-acme-widget \
      MOCK_START_STATUS=76 \
      MOCK_ORB_INFO='{"record":{"image":{"distro":"ubuntu","version":"noble","arch":"arm64"},"config":{"isolated":true,"isolate_network":true,"default_username":"deploy","cpu_limit":2,"memory_limit_mib":4096,"disk_limit_bytes":51539607552}}}' \
      GITHUB_URL=https://github.com/acme/widget \
      ./provision-orbstack.sh >/dev/null 2>&1
  )
  status=$?
  set -e
  assert_status 76 "$status"
  assert_file_contains "$current_tmp/command.log" 'orbctl start little-ci-acme-widget'
}

test_orbstack_guest_skips_swapfile_commands() {
  new_sandbox
  mkdir -p "$current_tmp/orbstack-guest"

  cat > "$current_tmp/bin/id" <<'MOCK'
#!/usr/bin/env bash
[ "${1:-}" = -u ] && { printf '0\n'; exit 0; }
/usr/bin/id "$@"
MOCK
  cat > "$current_tmp/bin/awk" <<'MOCK'
#!/usr/bin/env bash
# Simulate an OrbStack guest without legacy Little-CI fstab entries.
exit 0
MOCK
  cat > "$current_tmp/bin/sysctl" <<'MOCK'
#!/usr/bin/env bash
printf 'sysctl %s\n' "$*" >> "${MOCK_COMMAND_LOG:?}"
exit 75
MOCK
  for command_name in fallocate dd mkswap swapon; do
    cat > "$current_tmp/bin/$command_name" <<'MOCK'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$*" >> "${MOCK_COMMAND_LOG:?}"
exit 74
MOCK
    chmod +x "$current_tmp/bin/$command_name"
  done
  chmod +x "$current_tmp/bin/id" "$current_tmp/bin/awk" "$current_tmp/bin/sysctl"

  local output status
  set +e
  output="$(
    cd "$current_tmp/repo" &&
      PATH="$current_tmp/bin:$PATH" \
      MOCK_COMMAND_LOG="$current_tmp/command.log" \
      LITTLE_CI_ORBSTACK_GUEST_MARKER="$current_tmp/orbstack-guest" \
      GITHUB_URL=https://github.com/acme/widget \
      ./provision-box.sh 2>&1
  )"
  status=$?
  set -e
  assert_status 75 "$status"
  assert_contains "$output" 'OrbStack guest detected'
  assert_file_contains "$current_tmp/command.log" 'sysctl -w vm.swappiness=10'
  assert_file_not_contains "$current_tmp/command.log" 'fallocate'
  assert_file_not_contains "$current_tmp/command.log" 'dd '
  assert_file_not_contains "$current_tmp/command.log" 'mkswap'
  assert_file_not_contains "$current_tmp/command.log" 'swapon'
}

test_existing_runner_accepts_utf8_bom() {
  new_sandbox
  mkdir -p "$current_tmp/runner-home/actions-runner-1"
  : > "$current_tmp/runner-home/actions-runner-linux-arm64-2.337.0.tar.gz"
  printf '\357\273\277%s\n' \
    '{"agentName":"little-ci-acme-widget-1","gitHubUrl":"https://github.com/acme/widget","workFolder":"_work"}' \
    > "$current_tmp/runner-home/actions-runner-1/.runner"

  local output status
  set +e
  output="$(
    cd "$current_tmp/repo" &&
      GITHUB_SCOPE=repository \
      GITHUB_URL=https://github.com/acme/widget \
      REGTOKEN=unused-registration-token \
      RUNNER_HOME="$current_tmp/runner-home" \
      RUNNER_USER=deploy \
      RUNNER_ARCH=linux-arm64 \
      RUNNER_COUNT=1 \
      RUNNER_NAME_PREFIX=little-ci-acme-widget \
      SKIP_SERVICE_INSTALL=1 \
      ./install-runners.sh 2>&1
  )"
  status=$?
  set -e
  assert_status 0 "$status"
  assert_contains "$output" 'existing registration matches'
}

test_legacy_swapfile_cleanup_is_opt_in() {
  new_sandbox
  mkdir -p "$current_tmp/orbstack-guest"
  cat > "$current_tmp/bin/id" <<'MOCK'
#!/usr/bin/env bash
[ "${1:-}" = -u ] && { printf '0\n'; exit 0; }
/usr/bin/id "$@"
MOCK
  cat > "$current_tmp/bin/awk" <<'MOCK'
#!/usr/bin/env bash
printf '/swapfile1\n'
MOCK
  cat > "$current_tmp/bin/sysctl" <<'MOCK'
#!/usr/bin/env bash
exit 75
MOCK
  for command_name in rm swapoff; do
    cat > "$current_tmp/bin/$command_name" <<'MOCK'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$*" >> "${MOCK_COMMAND_LOG:?}"
exit 74
MOCK
    chmod +x "$current_tmp/bin/$command_name"
  done
  chmod +x "$current_tmp/bin/id" "$current_tmp/bin/awk" "$current_tmp/bin/sysctl"

  local output status
  set +e
  output="$(
    cd "$current_tmp/repo" &&
      PATH="$current_tmp/bin:$PATH" \
      MOCK_COMMAND_LOG="$current_tmp/command.log" \
      LITTLE_CI_ORBSTACK_GUEST_MARKER="$current_tmp/orbstack-guest" \
      GITHUB_URL=https://github.com/acme/widget \
      ./provision-box.sh 2>&1
  )"
  status=$?
  set -e
  assert_status 75 "$status"
  assert_contains "$output" 'set REMOVE_LEGACY_SWAPFILES=1'
  assert_file_not_contains "$current_tmp/command.log" 'rm '
  assert_file_not_contains "$current_tmp/command.log" 'swapoff'
}

test_config_file_rejects_persisted_tokens_without_leaking_value() {
  new_sandbox
  printf '%s\n' \
    'GITHUB_URL=https://github.com/acme/widget' \
    'REGTOKEN=do-not-print-this-secret' \
    > "$current_tmp/repo/config.env"

  local output provision_output provision_status status
  set +e
  output="$(cd "$current_tmp/repo" && ./install-runners.sh 2>&1)"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'persisted registration token unexpectedly accepted'
  assert_contains "$output" 'must not contain GitHub credentials'
  case "$output" in
    *do-not-print-this-secret*) fail 'secret value leaked in error output' ;;
  esac

  set +e
  provision_output="$(cd "$current_tmp/repo" && ./provision-orbstack.sh 2>&1)"
  provision_status=$?
  set -e
  [ "$provision_status" -ne 0 ] || fail 'provisioning accepted a persisted registration token'
  assert_contains "$provision_output" 'must not contain GitHub credentials'
  case "$provision_output" in
    *do-not-print-this-secret*) fail 'secret value leaked from provisioning error output' ;;
  esac
}

test_orbstack_uninstall_forwards_remove_token_and_cleans_matching_stale_runner() {
  new_sandbox
  install_gh_mock
  install_orbctl_machine_mock

  local output status
  set +e
  output="$(
    cd "$current_tmp/repo" &&
      PATH="$current_tmp/bin:$PATH" \
      MOCK_COMMAND_LOG="$current_tmp/command.log" \
      MOCK_MACHINE_EXISTS=1 \
      MOCK_MACHINE_NAME=little-ci-acme \
      MOCK_GH_TOKEN=do-not-log-remove-token \
      MOCK_GH_RESPONSE='[{"runners":[{"id":41,"name":"little-ci-acme-1","status":"offline","labels":[{"name":"little-ci-acme"}]},{"id":99,"name":"other-fleet-1","status":"offline","labels":[{"name":"other-fleet"}]}]}]' \
      GITHUB_SCOPE=organization \
      GITHUB_URL=https://github.com/acme \
      RUNNER_NAME_PREFIX=little-ci-acme \
      ./uninstall-runners-orb.sh --all --confirm 2>&1
  )"
  status=$?
  set -e
  assert_status 0 "$status"
  assert_file_contains "$current_tmp/command.log" '/orgs/acme/actions/runners/remove-token'
  assert_file_contains "$current_tmp/command.log" 'ORBENV=REMOVETOKEN:GITHUB_SCOPE:GITHUB_URL:RUNNER_COUNT:RUNNER_NAME_PREFIX:RUNNER_USER:RUNNER_HOME'
  assert_file_contains "$current_tmp/command.log" 'bash -s -- --all --confirm'
  assert_file_contains "$current_tmp/command.log" '/orgs/acme/actions/runners/41'
  assert_file_not_contains "$current_tmp/command.log" '/orgs/acme/actions/runners/99'
  assert_file_not_contains "$current_tmp/command.log" 'orbctl delete'
  case "$output$(cat "$current_tmp/command.log")" in
    *do-not-log-remove-token*) fail 'remove token leaked to output or command log' ;;
  esac
}

test_machine_deletion_requires_all_mode() {
  new_sandbox
  install_gh_mock
  install_orbctl_machine_mock

  local output status
  set +e
  output="$(
    cd "$current_tmp/repo" &&
      PATH="$current_tmp/bin:$PATH" \
      MOCK_COMMAND_LOG="$current_tmp/command.log" \
      GITHUB_URL=https://github.com/acme/widget \
      ./uninstall-runners-orb.sh --prune --confirm --delete-machine 2>&1
  )"
  status=$?
  set -e
  assert_status 2 "$status"
  assert_contains "$output" 'allowed only with --all'
  [ ! -s "$current_tmp/command.log" ] || fail 'external commands ran before delete-mode validation'
}

test_organization_runner_group_reaches_registration_command() {
  new_sandbox
  mkdir -p "$current_tmp/runner-package" "$current_tmp/runner-home"
  cat > "$current_tmp/runner-package/config.sh" <<'MOCK'
#!/usr/bin/env bash
printf 'config.sh' >> "${MOCK_COMMAND_LOG:?}"
printf ' %q' "$@" >> "$MOCK_COMMAND_LOG"
printf '\n' >> "$MOCK_COMMAND_LOG"
MOCK
  chmod +x "$current_tmp/runner-package/config.sh"
  tar -C "$current_tmp/runner-package" -czf \
    "$current_tmp/runner-home/actions-runner-linux-arm64-2.337.0.tar.gz" .

  local output status
  set +e
  output="$(
    cd "$current_tmp/repo" &&
      MOCK_COMMAND_LOG="$current_tmp/command.log" \
      GITHUB_SCOPE=organization \
      GITHUB_URL=https://github.com/acme \
      REGTOKEN=unused-registration-token \
      RUNNER_HOME="$current_tmp/runner-home" \
      RUNNER_USER=deploy \
      RUNNER_ARCH=linux-arm64 \
      RUNNER_COUNT=1 \
      RUNNER_GROUP=trusted-macs \
      SKIP_SERVICE_INSTALL=1 \
      ./install-runners.sh 2>&1
  )"
  status=$?
  set -e
  assert_status 0 "$status"
  assert_file_contains "$current_tmp/command.log" '--runnergroup trusted-macs'
  assert_file_contains "$current_tmp/command.log" '--labels little-ci\,little-ci-acme\,little-ci-acme-1\,arm64'
  assert_contains "$output" 'service installation deferred'
}

test_orbstack_install_fetches_registration_token_and_splits_service_install() {
  new_sandbox
  install_uname_mock arm64
  install_gh_mock
  install_orbctl_machine_mock

  local output status
  set +e
  output="$(
    cd "$current_tmp/repo" &&
      PATH="$current_tmp/bin:$PATH" \
      MOCK_COMMAND_LOG="$current_tmp/command.log" \
      MOCK_GH_TOKEN=do-not-log-registration-token \
      GITHUB_SCOPE=organization \
      GITHUB_URL=https://github.com/acme \
      RUNNER_USER=deploy \
      RUNNER_COUNT=1 \
      ./install-runners-orb.sh 2>&1
  )"
  status=$?
  set -e
  assert_status 0 "$status"
  assert_file_contains "$current_tmp/command.log" '/orgs/acme/actions/runners/registration-token'
  assert_file_contains "$current_tmp/command.log" 'ORBENV=REGTOKEN'
  assert_file_contains "$current_tmp/command.log" 'RUNNER_ARCH=linux-arm64\ SKIP_SERVICE_INSTALL=1\ ./install-runners.sh'
  assert_file_contains "$current_tmp/command.log" '-u root'
  assert_file_contains "$current_tmp/command.log" './svc.sh\ start'
  case "$output$(cat "$current_tmp/command.log")" in
    *do-not-log-registration-token*) fail 'registration token leaked to output or command log' ;;
  esac
}

test_local_uninstall_uses_remove_token_and_deletes_selected_runner() {
  new_sandbox
  local runner_home="$current_tmp/runner-home"
  local runner_dir="$runner_home/actions-runner-1"
  local runner_user
  runner_user="$(id -un)"
  mkdir -p "$runner_dir"
  printf '%s\n' \
    '{"agentName":"little-ci-acme-widget-1","gitHubUrl":"https://github.com/acme/widget"}' \
    > "$runner_dir/.runner"
  cat > "$runner_dir/config.sh" <<'MOCK'
#!/usr/bin/env bash
[ "${1:-}" = remove ] || exit 64
[ "${2:-}" = --token ] || exit 65
[ "${3:-}" = "${REMOVETOKEN:?}" ] || exit 66
printf 'config-remove-token=matched\n' >> "${MOCK_COMMAND_LOG:?}"
MOCK
  cat > "$current_tmp/bin/sudo" <<'MOCK'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >> "${MOCK_COMMAND_LOG:?}"
"$@"
MOCK
  chmod +x "$runner_dir/config.sh" "$current_tmp/bin/sudo"

  local output status
  set +e
  output="$(
    cd "$current_tmp/repo" &&
      PATH="$current_tmp/bin:$PATH" \
      MOCK_COMMAND_LOG="$current_tmp/command.log" \
      GITHUB_SCOPE=repository \
      GITHUB_URL=https://github.com/acme/widget \
      REMOVETOKEN=unused-remove-token \
      RUNNER_HOME="$runner_home" \
      RUNNER_USER="$runner_user" \
      RUNNER_COUNT=1 \
      RUNNER_NAME_PREFIX=little-ci-acme-widget \
      ./uninstall-runners.sh --all --confirm 2>&1
  )"
  status=$?
  set -e
  assert_status 0 "$status"
  assert_file_contains "$current_tmp/command.log" 'config-remove-token=matched'
  [ ! -e "$runner_dir" ] || fail 'selected runner directory was not removed'
  assert_contains "$output" 'Local removal complete: 1 removed, 0 failed.'
}

test_local_uninstall_rejects_root_runner_home_before_commands() {
  new_sandbox
  cat > "$current_tmp/bin/sudo" <<'MOCK'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >> "${MOCK_COMMAND_LOG:?}"
exit 74
MOCK
  chmod +x "$current_tmp/bin/sudo"

  local output status
  set +e
  output="$(
    cd "$current_tmp/repo" &&
      PATH="$current_tmp/bin:$PATH" \
      MOCK_COMMAND_LOG="$current_tmp/command.log" \
      GITHUB_SCOPE=repository \
      GITHUB_URL=https://github.com/acme/widget \
      REMOVETOKEN=unused-remove-token \
      RUNNER_HOME=/ \
      RUNNER_USER="$(id -un)" \
      ./uninstall-runners.sh --all --confirm 2>&1
  )"
  status=$?
  set -e
  assert_status 2 "$status"
  assert_contains "$output" 'RUNNER_HOME must not be /'
  [ ! -s "$current_tmp/command.log" ] || fail 'privileged command ran with RUNNER_HOME=/'
}

run_case 'all shell files pass bash -n' test_bash_syntax
run_case 'repository scope uses repository runner API' test_repository_api_routing
run_case 'organization scope uses organization runner API' test_organization_api_routing
run_case 'health check counts only its configured fleet' test_health_check_ignores_unrelated_runners
run_case 'OrbStack provisioning rejects Intel Macs' test_orbstack_rejects_intel_mac
run_case 'new OrbStack machine uses secure Apple Silicon defaults' test_orbstack_creation_uses_secure_arm_defaults
run_case 'existing OrbStack machine is rejected before start when incompatible' test_existing_orbstack_machine_is_validated_before_start
run_case 'compatible existing OrbStack machine reaches start' test_compatible_orbstack_machine_reaches_start
run_case 'OrbStack guests skip Linux swapfile commands' test_orbstack_guest_skips_swapfile_commands
run_case 'existing runner metadata accepts GitHub UTF-8 BOM' test_existing_runner_accepts_utf8_bom
run_case 'legacy OrbStack swapfile cleanup is opt in' test_legacy_swapfile_cleanup_is_opt_in
run_case 'config.env rejects persisted tokens without leaking them' test_config_file_rejects_persisted_tokens_without_leaking_value
run_case 'OrbStack uninstall forwards remove token and deletes only matching stale runner' test_orbstack_uninstall_forwards_remove_token_and_cleans_matching_stale_runner
run_case 'OrbStack machine deletion requires all mode' test_machine_deletion_requires_all_mode
run_case 'organization runner group reaches GitHub registration command' test_organization_runner_group_reaches_registration_command
run_case 'OrbStack install fetches registration token and installs services as root' test_orbstack_install_fetches_registration_token_and_splits_service_install
run_case 'local uninstall unregisters and removes the selected runner' test_local_uninstall_uses_remove_token_and_deletes_selected_runner
run_case 'local uninstall rejects RUNNER_HOME=/ before commands' test_local_uninstall_rejects_root_runner_home_before_commands

printf '\n%d tests, %d failures\n' "$test_count" "$failure_count"
[ "$failure_count" -eq 0 ]
