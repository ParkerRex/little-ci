#!/usr/bin/env bash
set -uo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_count=0
failure_count=0
sandbox_dir=""

cleanup() {
  if [ -n "$sandbox_dir" ] && [ -d "$sandbox_dir" ]; then
    rm -rf "$sandbox_dir"
  fi
}
trap cleanup EXIT

fail() {
  printf '    %s\n' "$*" >&2
  [ -z "${output+x}" ] || printf '    command output: %s\n' "$output" >&2
  [ -z "${sandbox_dir:-}" ] || [ ! -f "$sandbox_dir/command.log" ] || sed 's/^/    log: /' "$sandbox_dir/command.log" >&2
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

assert_file_order() {
  local file="$1"
  local earlier_text="$2"
  local later_text="$3"
  local earlier_line later_line
  earlier_line="$(grep -nF -- "$earlier_text" "$file" | head -1 | cut -d: -f1)"
  later_line="$(grep -nF -- "$later_text" "$file" | head -1 | cut -d: -f1)"
  [ -n "$earlier_line" ] || fail "missing earlier event in $file: $earlier_text"
  [ -n "$later_line" ] || fail "missing later event in $file: $later_text"
  [ "$earlier_line" -lt "$later_line" ] || \
    fail "expected '$earlier_text' before '$later_text' in $file"
}

new_sandbox() {
  cleanup
  sandbox_dir="$(mktemp -d "${TMPDIR:-/tmp}/little-ci-tests.XXXXXX")"
  mkdir -p "$sandbox_dir/repo" "$sandbox_dir/bin"
  find "$repo_root" -maxdepth 1 -type f -name '*.sh' -exec cp {} "$sandbox_dir/repo/" \;
  if [ -d "$repo_root/lib" ]; then
    cp -R "$repo_root/lib" "$sandbox_dir/repo/lib"
  fi
  chmod +x "$sandbox_dir/repo/"*.sh
  : > "$sandbox_dir/command.log"
}

install_gh_mock() {
  cat > "$sandbox_dir/bin/gh" <<'MOCK'
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
  chmod +x "$sandbox_dir/bin/gh"
}

install_lifecycle_gh_failure_mock() {
  cat > "$sandbox_dir/bin/gh" <<'MOCK'
#!/usr/bin/env bash
printf 'gh' >> "${MOCK_COMMAND_LOG:?}"
printf ' %q' "$@" >> "$MOCK_COMMAND_LOG"
printf '\n' >> "$MOCK_COMMAND_LOG"
if [[ " $* " == *"remove-token"* ]]; then
  printf 'unused-remove-token\n'
  exit 0
fi
if [[ " $* " == *" --method DELETE "* ]]; then
  [ "${MOCK_GH_FAILURE_MODE:?}" != delete ] || exit 71
  exit 0
fi
if [[ " $* " == *"actions/runners?per_page=100"* ]]; then
  request_count=0
  [ ! -f "${MOCK_GH_COUNT_FILE:?}" ] || request_count="$(cat "$MOCK_GH_COUNT_FILE")"
  request_count=$((request_count + 1))
  printf '%s\n' "$request_count" > "$MOCK_GH_COUNT_FILE"
  if [ "$MOCK_GH_FAILURE_MODE" = read ] && [ "$request_count" -gt 1 ]; then
    exit 70
  fi
  printf '%s\n' "${MOCK_GH_RESPONSE:?}"
  exit 0
fi
exit 64
MOCK
  chmod +x "$sandbox_dir/bin/gh"
}

install_uname_mock() {
  local architecture="$1"
  local operating_system="${2:-Darwin}"
  cat > "$sandbox_dir/bin/uname" <<MOCK
#!/usr/bin/env bash
case "\${1:-}" in
  -m) printf '%s\\n' '$architecture' ;;
  -s) printf '%s\\n' '$operating_system' ;;
  *) /usr/bin/uname "\$@" ;;
esac
MOCK
  chmod +x "$sandbox_dir/bin/uname"
}

install_runner_user_id_mock() {
  cat > "$sandbox_dir/bin/id" <<'MOCK'
#!/usr/bin/env bash
[ -z "${MOCK_COMMAND_LOG:-}" ] || {
  printf 'id' >> "$MOCK_COMMAND_LOG"
  printf ' %q' "$@" >> "$MOCK_COMMAND_LOG"
  printf '\n' >> "$MOCK_COMMAND_LOG"
}
case "${1:-}" in
  -u)
    if [ "$#" -eq 1 ]; then
      printf '%s\n' "${MOCK_EFFECTIVE_UID:-501}"
    else
      printf '%s\n' "${MOCK_CONFIGURED_UID:-501}"
    fi
    ;;
  -un) printf '%s\n' "${MOCK_EFFECTIVE_USER:-deploy}" ;;
  *) /usr/bin/id "$@" ;;
esac
MOCK
  chmod +x "$sandbox_dir/bin/id"
}

install_orbctl_machine_mock() {
  cat > "$sandbox_dir/bin/orbctl" <<'MOCK'
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
  config)
    if [ "${2:-}" = get ] && [[ "${3:-}" == machine.*.mounts ]]; then
      [ "${MOCK_MOUNTS_STATUS:-0}" -eq 0 ] || exit "$MOCK_MOUNTS_STATUS"
      printf '%s' "${MOCK_CONFIGURED_MOUNTS:-}"
      exit 0
    fi
    exit "${MOCK_ORBCTL_STATUS:-0}"
    ;;
  run)
    case " $* " in
      *" stat -c %U:%G %a /etc/little-ci/identity "*)
        [ "${MOCK_IDENTITY_PRESENT:-1}" = 1 ] || exit 1
        printf 'root:root 600\n'
        ;;
      *" stat -c %u:%g:%a /etc/little-ci /etc/little-ci/identity "*)
        [ "${MOCK_IDENTITY_PRESENT:-1}" = 1 ] || exit 1
        if [ -n "${MOCK_IDENTITY_PERMISSIONS:-}" ]; then
          printf '%s\n' "$MOCK_IDENTITY_PERMISSIONS"
        else
          printf '0:0:700\n0:0:600\n'
        fi
        ;;
      *" cat /etc/little-ci/identity "*) printf '%s\n' "${MOCK_ORB_IDENTITY:-}" ;;
      *" id -u "*) printf '%s\n' "${MOCK_GUEST_UID:-1000}" ;;
      *" uname -m "*) printf 'aarch64\n' ;;
    esac
    if [ -n "${MOCK_ORBCTL_STDIN_LOG:-}" ] && [[ " $* " == *" bash -s "* ]]; then
      cat >> "$MOCK_ORBCTL_STDIN_LOG"
      printf '\n' >> "$MOCK_ORBCTL_STDIN_LOG"
    fi
    if [ -n "${MOCK_GUEST_UNINSTALL_STATUS:-}" ] && [[ " $* " == *" bash -s -- --all --confirm "* ]]; then
      exit "$MOCK_GUEST_UNINSTALL_STATUS"
    fi
    if [ "${MOCK_EXECUTE_GUEST_UNINSTALL:-0}" = 1 ] && [[ " $* " == *" bash -s -- --all --confirm "* ]]; then
      /bin/bash -s -- --all --confirm
      exit $?
    fi
    exit "${MOCK_ORBCTL_STATUS:-0}"
    ;;
  *)
    exit "${MOCK_ORBCTL_STATUS:-0}"
    ;;
esac
MOCK
  chmod +x "$sandbox_dir/bin/orbctl"
}

install_service_command_mocks() {
  cat > "$sandbox_dir/bin/sudo" <<'MOCK'
#!/usr/bin/env bash
printf 'sudo' >> "${MOCK_COMMAND_LOG:?}"
printf ' %q' "$@" >> "$MOCK_COMMAND_LOG"
printf '\n' >> "$MOCK_COMMAND_LOG"
case "${1:-}" in
  test)
    drop_in_dir="/etc/systemd/system/${MOCK_SERVICE_NAME:?}.d"
    drop_in_file="$drop_in_dir/zz-little-ci-scratch.conf"
    case "${2:-}:${3:-}" in
      -f:/etc/systemd/system/"$MOCK_SERVICE_NAME") exit 0 ;;
      -L:"$drop_in_dir") [ "${MOCK_DROP_IN_SYMLINK:-none}" = dir ] ;;
      -L:"$drop_in_file") [ "${MOCK_DROP_IN_SYMLINK:-none}" = file ] ;;
      -e:"$drop_in_dir"|-d:"$drop_in_dir") [ "${MOCK_DROP_IN_STATE:-missing}" != missing ] || [ "${MOCK_DROP_IN_SYMLINK:-none}" = dir ] ;;
      -e:"$drop_in_file"|-f:"$drop_in_file") [ "${MOCK_DROP_IN_STATE:-missing}" != missing ] || [ "${MOCK_DROP_IN_SYMLINK:-none}" = file ] ;;
      *) exit 1 ;;
    esac
    ;;
  grep)
    [ "${MOCK_SERVICE_OWNERSHIP:-valid}" = valid ] || exit 1
    case "${4:-}" in
      "ExecStart=${MOCK_RUNNER_DIR:?}/runsvc.sh"|"User=${MOCK_RUNNER_USER:?}"|"WorkingDirectory=$MOCK_RUNNER_DIR") exit 0 ;;
      *) exit 1 ;;
    esac
    ;;
  tee)
    [ "${2:-}" = "/etc/systemd/system/${MOCK_SERVICE_NAME}.d/zz-little-ci-scratch.conf" ] || exit 1
    cat > "${MOCK_TEE_OUTPUT:?}"
    ;;
  cat)
    case "${MOCK_DROP_IN_STATE:-missing}" in
      unchanged)
        printf '[Service]\nEnvironment=TMPDIR=/scratch/%s/1\nEnvironment=TMP=/scratch/%s/1\n' \
          "${MOCK_RUNNER_PREFIX:?}" "$MOCK_RUNNER_PREFIX"
        ;;
      changed) printf '[Service]\nEnvironment=TMPDIR=/scratch/unrelated/1\n' ;;
      *) exit 1 ;;
    esac
    ;;
  systemctl)
    if [ "${2:-}" = is-active ]; then
      [ "${MOCK_SERVICE_ACTIVE:-1}" = 1 ]
    else
      exit 0
    fi
    ;;
  install|./svc.sh) exit 0 ;;
  *) exit 1 ;;
esac
MOCK
  cat > "$sandbox_dir/bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "${MOCK_COMMAND_LOG:?}"
exit 0
MOCK
  chmod +x "$sandbox_dir/bin/sudo" "$sandbox_dir/bin/systemctl"
}

install_tar_inventory_mock() {
  cat > "$sandbox_dir/bin/tar" <<'MOCK'
#!/usr/bin/env bash
/usr/bin/tar "$@"
archive_path=""
previous_argument=""
for argument in "$@"; do
  if [ "$previous_argument" = -czf ]; then
    archive_path="$argument"
    break
  fi
  previous_argument="$argument"
done
if [ -n "$archive_path" ]; then
  /usr/bin/tar -tzf "$archive_path" >> "${MOCK_ARCHIVE_INVENTORY:?}"
fi
MOCK
  chmod +x "$sandbox_dir/bin/tar"
}

create_existing_runner_fixture() {
  local runner_name="$1"
  local service_name="$2"
  local runner_home="$sandbox_dir/runner-home"
  local runner_dir="$runner_home/actions-runner-1"
  mkdir -p "$runner_dir"
  : > "$runner_home/actions-runner-linux-arm64-2.337.0.tar.gz"
  printf '%s\n' \
    "{\"agentName\":\"$runner_name\",\"gitHubUrl\":\"https://github.com/acme/widget\",\"workFolder\":\"_work\"}" \
    > "$runner_dir/.runner"
  printf '%s\n' "$service_name" > "$runner_dir/.service"
}

install_uninstall_resource_mocks() {
  cat > "$sandbox_dir/bin/sudo" <<'MOCK'
#!/usr/bin/env bash
printf 'sudo' >> "${MOCK_COMMAND_LOG:?}"
printf ' %q' "$@" >> "$MOCK_COMMAND_LOG"
printf '\n' >> "$MOCK_COMMAND_LOG"
pending_record_store="${MOCK_PENDING_RECORD_STORE:-$MOCK_COMMAND_LOG.pending-record}"
service_removed_store="${MOCK_SERVICE_REMOVED_STORE:-$MOCK_COMMAND_LOG.service-removed}"
last_argument="${!#}"
case "${1:-}" in
  test)
    case " $* " in
      *" ! -e "*pending-cleanup*) [ ! -f "$pending_record_store" ] ;;
      *" -e "*pending-cleanup*|*" -f "*pending-cleanup*) [ -f "$pending_record_store" ] ;;
      *" -d "*pending-cleanup*) exit 0 ;;
      *" ! -L "*) exit 0 ;;
      *" -L "*pending-cleanup*) exit 1 ;;
      *" -e /etc/systemd/system/actions.runner."*) [ ! -f "$service_removed_store" ] ;;
      *) exit 0 ;;
    esac
    ;;
  grep) [ "${MOCK_SERVICE_OWNERSHIP:-valid}" = valid ] ;;
  stat)
    case "${!#}" in
      */pending-cleanup) printf 'root:root 700\n' ;;
      */pending-cleanup/*) printf 'root:root 600\n' ;;
      */managed-swapfiles) printf 'root:root 600\n' ;;
      /var/lib/little-ci/fleets/*) printf 'root:root 700\n' ;;
      /scratch/*) printf 'root:root\n' ;;
      *) exit 1 ;;
    esac
    ;;
  cat)
    if [[ "$last_argument" == */pending-cleanup/* ]]; then
      /bin/cat "$pending_record_store"
    else
      printf '1\t/swapfile-%s-1\n' "${MOCK_RUNNER_PREFIX:?}"
    fi
    ;;
  swapon) printf '/swapfile-%s-1\n' "${MOCK_RUNNER_PREFIX:?}" ;;
  swapoff) exit "${MOCK_SWAPOFF_STATUS:-0}" ;;
  python3)
    if [[ "${3:-}" == */pending-cleanup/* ]]; then
      printf '%s\t%s\t%s\t%s\t%s\n' "${4:?}" "${5:?}" "${6:?}" "${7:?}" "${8:?}" > "$pending_record_store"
    fi
    exit 0
    ;;
  ./svc.sh)
    if [ "${2:-}" = uninstall ]; then
      : > "$service_removed_store"
      /bin/rm -f -- "${MOCK_ALLOWED_RUNNER_DIR:?}/.service"
    fi
    exit 0
    ;;
  install|rmdir|systemctl) exit 0 ;;
  rm)
    removal_path="$last_argument"
    if [[ "$removal_path" == */pending-cleanup/* ]]; then
      /bin/rm -f -- "$pending_record_store"
      exit 0
    fi
    if [ "$removal_path" = "${MOCK_ALLOWED_RUNNER_DIR:?}" ]; then
      /bin/rm -rf -- "$removal_path"
    fi
    ;;
  *) exit 1 ;;
esac
MOCK
  chmod +x "$sandbox_dir/bin/sudo"
}

create_removable_runner_fixture() {
  local runner_home="$1"
  local runner_name="$2"
  local service_name="$3"
  local runner_dir="$runner_home/actions-runner-1"
  mkdir -p "$runner_dir"
  printf '%s\n' \
    "{\"agentName\":\"$runner_name\",\"gitHubUrl\":\"https://github.com/acme/widget\"}" \
    > "$runner_dir/.runner"
  printf '%s\n' "$service_name" > "$runner_dir/.service"
  cat > "$runner_dir/config.sh" <<'MOCK'
#!/usr/bin/env bash
[ "${1:-}" = remove ] && [ "${2:-}" = --token ] && [ "${3:-}" = "${REMOVETOKEN:?}" ]
MOCK
  cat > "$runner_dir/svc.sh" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
  chmod +x "$runner_dir/config.sh" "$runner_dir/svc.sh"
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

test_root_command_scripts_are_executable() {
  local script
  while IFS= read -r script; do
    [ -x "$script" ] || fail "command script is not executable: $script"
  done < <(find "$repo_root" -maxdepth 1 -type f -name '*.sh' -print | sort)
}

test_repository_api_routing() {
  new_sandbox
  install_gh_mock
  local output status
  set +e
  output="$(
    cd "$sandbox_dir/repo" &&
      PATH="$sandbox_dir/bin:$PATH" \
      MOCK_COMMAND_LOG="$sandbox_dir/command.log" \
      MOCK_GH_RESPONSE='{"runners":[{"name":"little-ci-acme-widget-1","status":"online","labels":[{"name":"little-ci"},{"name":"little-ci-acme-widget"},{"name":"little-ci-acme-widget-1"},{"name":"arm64"}]}]}' \
      GITHUB_SCOPE=repository \
      GITHUB_URL=https://github.com/acme/widget \
      RUNNER_NAME_PREFIX=little-ci-acme-widget \
      EXPECTED_RUNNERS=1 \
      ./check-runners.sh 2>&1
  )"
  status=$?
  set -e
  assert_status 0 "$status"
  assert_file_contains "$sandbox_dir/command.log" '/repos/acme/widget/actions/runners'
  assert_contains "$output" 'GREEN'
}

test_organization_api_routing() {
  new_sandbox
  install_gh_mock
  local output status
  set +e
  output="$(
    cd "$sandbox_dir/repo" &&
      PATH="$sandbox_dir/bin:$PATH" \
      MOCK_COMMAND_LOG="$sandbox_dir/command.log" \
      MOCK_GH_RESPONSE='{"runners":[{"name":"little-ci-acme-1","status":"online","labels":[{"name":"little-ci"},{"name":"little-ci-acme"},{"name":"little-ci-acme-1"},{"name":"arm64"}]}]}' \
      GITHUB_SCOPE=organization \
      GITHUB_URL=https://github.com/acme \
      RUNNER_GROUP=trusted-macs \
      RUNNER_NAME_PREFIX=little-ci-acme \
      EXPECTED_RUNNERS=1 \
      ./check-runners.sh 2>&1
  )"
  status=$?
  set -e
  assert_status 0 "$status"
  assert_file_contains "$sandbox_dir/command.log" '/orgs/acme/actions/runners'
  assert_contains "$output" 'GREEN'
}

test_health_check_ignores_unrelated_runners() {
  new_sandbox
  install_gh_mock
  local output status
  set +e
  output="$(
    cd "$sandbox_dir/repo" &&
      PATH="$sandbox_dir/bin:$PATH" \
      MOCK_COMMAND_LOG="$sandbox_dir/command.log" \
      MOCK_GH_RESPONSE='{"runners":[{"name":"little-ci-acme-widget-1","status":"online","labels":[{"name":"little-ci"},{"name":"little-ci-acme-widget"},{"name":"little-ci-acme-widget-1"},{"name":"arm64"}]},{"name":"other-fleet-1","status":"online","labels":[{"name":"other-fleet"}]},{"name":"other-fleet-2","status":"online","labels":[{"name":"other-fleet"}]}]}' \
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

test_health_check_requires_stable_configured_and_exact_labels() {
  new_sandbox
  install_gh_mock
  local output status
  set +e
  output="$(
    cd "$sandbox_dir/repo" &&
      PATH="$sandbox_dir/bin:$PATH" \
      MOCK_COMMAND_LOG="$sandbox_dir/command.log" \
      MOCK_GH_RESPONSE='{"runners":[{"name":"little-ci-acme-widget-1","status":"online","labels":[{"name":"little-ci-acme-widget"},{"name":"arm64"}]}]}' \
      GITHUB_SCOPE=repository \
      GITHUB_URL=https://github.com/acme/widget \
      RUNNER_NAME_PREFIX=little-ci-acme-widget \
      RUNNER_LABELS=project-ci \
      EXPECTED_RUNNERS=1 \
      ./check-runners.sh 2>&1
  )"
  status=$?
  set -e
  assert_status 1 "$status"
  assert_contains "$output" 'RED'
  assert_contains "$output" 'project-ci'
  assert_contains "$output" 'little-ci'
  assert_contains "$output" 'little-ci-acme-widget-1'
}

test_fleet_ids_derive_distinct_lowercase_prefixes() {
  new_sandbox
  local studio_prefix laptop_prefix
  studio_prefix="$(
    cd "$sandbox_dir/repo" && bash -c '
      . ./lib/github-target.sh
      GITHUB_SCOPE=repository
      GITHUB_URL=https://github.com/Acme/Widget
      FLEET_ID=mac-studio
      github_target_init
      github_fleet_init
      printf "%s\n" "$RUNNER_NAME_PREFIX"
    '
  )"
  laptop_prefix="$(
    cd "$sandbox_dir/repo" && bash -c '
      . ./lib/github-target.sh
      GITHUB_SCOPE=repository
      GITHUB_URL=https://github.com/Acme/Widget
      FLEET_ID=macbook
      github_target_init
      github_fleet_init
      printf "%s\n" "$RUNNER_NAME_PREFIX"
    '
  )"
  [ "$studio_prefix" = little-ci-acme-widget-mac-studio ] || \
    fail "unexpected derived prefix: $studio_prefix"
  [ "$laptop_prefix" = little-ci-acme-widget-macbook ] || \
    fail "unexpected derived prefix: $laptop_prefix"
  [ "$studio_prefix" != "$laptop_prefix" ] || fail 'distinct fleet IDs collided'
}

test_missing_or_uppercase_fleet_id_is_rejected() {
  new_sandbox
  local missing_output uppercase_output missing_status uppercase_status
  set +e
  missing_output="$(
    cd "$sandbox_dir/repo" && bash -c '
      . ./lib/github-target.sh
      GITHUB_SCOPE=repository
      GITHUB_URL=https://github.com/acme/widget
      github_target_init && github_fleet_init
    ' 2>&1
  )"
  missing_status=$?
  uppercase_output="$(
    cd "$sandbox_dir/repo" && bash -c '
      . ./lib/github-target.sh
      GITHUB_SCOPE=repository
      GITHUB_URL=https://github.com/acme/widget
      FLEET_ID=MacStudio
      github_target_init && github_fleet_init
    ' 2>&1
  )"
  uppercase_status=$?
  set -e
  [ "$missing_status" -ne 0 ] || fail 'missing FLEET_ID unexpectedly accepted'
  [ "$uppercase_status" -ne 0 ] || fail 'uppercase FLEET_ID unexpectedly accepted'
  assert_contains "$missing_output" 'FLEET_ID is required'
  assert_contains "$uppercase_output" 'lowercase letters'
}

test_organization_scope_requires_runner_group() {
  new_sandbox
  install_gh_mock
  local output status
  set +e
  output="$(
    cd "$sandbox_dir/repo" &&
      PATH="$sandbox_dir/bin:$PATH" \
      MOCK_COMMAND_LOG="$sandbox_dir/command.log" \
      GITHUB_SCOPE=organization \
      GITHUB_URL=https://github.com/acme \
      FLEET_ID=studio \
      ./check-runners.sh 2>&1
  )"
  status=$?
  set -e
  assert_status 2 "$status"
  assert_contains "$output" 'RUNNER_GROUP is required'
  [ ! -s "$sandbox_dir/command.log" ] || fail 'GitHub API called before runner-group validation'
}

test_runner_labels_reject_empty_entries_and_overlength_values() {
  new_sandbox
  install_runner_user_id_mock
  PATH="$sandbox_dir/bin:$PATH"
  export PATH
  local runner_home="$sandbox_dir/runner-home"
  local overlength_label
  mkdir -p "$runner_home"
  overlength_label="$(printf 'x%.0s' {1..257})"

  local empty_output empty_status long_output long_status whitespace_output whitespace_status control_output control_status
  set +e
  empty_output="$(
    cd "$sandbox_dir/repo" &&
      GITHUB_SCOPE=repository \
      GITHUB_URL=https://github.com/acme/widget \
      FLEET_ID=studio \
      REGTOKEN=unused-registration-token \
      RUNNER_HOME="$runner_home" \
      RUNNER_USER=deploy \
      RUNNER_ARCH=linux-arm64 \
      RUNNER_LABELS=little-ci,,project-ci \
      ./install-runners.sh 2>&1
  )"
  empty_status=$?
  long_output="$(
    cd "$sandbox_dir/repo" &&
      GITHUB_SCOPE=repository \
      GITHUB_URL=https://github.com/acme/widget \
      FLEET_ID=studio \
      REGTOKEN=unused-registration-token \
      RUNNER_HOME="$runner_home" \
      RUNNER_USER=deploy \
      RUNNER_ARCH=linux-arm64 \
      RUNNER_LABELS="$overlength_label" \
      ./install-runners.sh 2>&1
  )"
  long_status=$?
  whitespace_output="$(
    cd "$sandbox_dir/repo" &&
      GITHUB_SCOPE=repository \
      GITHUB_URL=https://github.com/acme/widget \
      FLEET_ID=studio \
      REGTOKEN=unused-registration-token \
      RUNNER_HOME="$runner_home" \
      RUNNER_USER=deploy \
      RUNNER_ARCH=linux-arm64 \
      RUNNER_LABELS='little-ci, project-ci' \
      ./install-runners.sh 2>&1
  )"
  whitespace_status=$?
  control_output="$(
    cd "$sandbox_dir/repo" &&
      GITHUB_SCOPE=repository \
      GITHUB_URL=https://github.com/acme/widget \
      FLEET_ID=studio \
      REGTOKEN=unused-registration-token \
      RUNNER_HOME="$runner_home" \
      RUNNER_USER=deploy \
      RUNNER_ARCH=linux-arm64 \
      RUNNER_LABELS=$'little-ci,project\001ci' \
      ./install-runners.sh 2>&1
  )"
  control_status=$?
  set -e
  [ "$empty_status" -ne 0 ] || fail 'empty runner-label entry unexpectedly accepted'
  [ "$long_status" -ne 0 ] || fail 'overlength runner label unexpectedly accepted'
  [ "$whitespace_status" -ne 0 ] || fail 'whitespace-padded runner label unexpectedly accepted'
  [ "$control_status" -ne 0 ] || fail 'runner label with control character unexpectedly accepted'
  assert_contains "$empty_output" 'RUNNER_LABELS'
  assert_contains "$long_output" '256'
  assert_contains "$whitespace_output" 'leading or trailing whitespace'
  assert_contains "$control_output" 'printable characters'
  [ -z "$(find "$runner_home" -mindepth 1 -print -quit)" ] || fail 'runner files created before label rejection'
}

test_runner_label_allows_exact_256_character_boundary() {
  new_sandbox
  local boundary_label
  boundary_label="$(printf 'x%.0s' {1..256})"
  (
    cd "$sandbox_dir/repo" && bash -c '
      . ./lib/github-target.sh
      github_validate_runner_label "$1" boundary-label
    ' bash "$boundary_label"
  )
}

test_generated_runner_labels_respect_github_length_limit() {
  new_sandbox
  install_runner_user_id_mock
  PATH="$sandbox_dir/bin:$PATH"
  export PATH
  local runner_home="$sandbox_dir/runner-home"
  local long_prefix
  mkdir -p "$runner_home"
  long_prefix="little-ci-$(printf 'x%.0s' {1..247})"

  local output status
  set +e
  output="$(
    cd "$sandbox_dir/repo" &&
      GITHUB_SCOPE=repository \
      GITHUB_URL=https://github.com/acme/widget \
      RUNNER_NAME_PREFIX="$long_prefix" \
      REGTOKEN=unused-registration-token \
      RUNNER_HOME="$runner_home" \
      RUNNER_USER=deploy \
      RUNNER_ARCH=linux-arm64 \
      RUNNER_LABELS=little-ci \
      ./install-runners.sh 2>&1
  )"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'generated runner label over 256 characters unexpectedly accepted'
  assert_contains "$output" '256'
  [ -z "$(find "$runner_home" -mindepth 1 -print -quit)" ] || fail 'runner files created before generated-label rejection'
}

test_orbstack_rejects_intel_mac() {
  new_sandbox
  install_uname_mock x86_64
  cat > "$sandbox_dir/bin/orbctl" <<'MOCK'
#!/usr/bin/env bash
printf 'orbctl %s\n' "$*" >> "${MOCK_COMMAND_LOG:?}"
exit 99
MOCK
  chmod +x "$sandbox_dir/bin/orbctl"

  local output status
  set +e
  output="$(
    cd "$sandbox_dir/repo" &&
      PATH="$sandbox_dir/bin:$PATH" \
      MOCK_COMMAND_LOG="$sandbox_dir/command.log" \
      GITHUB_URL=https://github.com/acme/widget \
      ./provision-orbstack.sh 2>&1
  )"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'Intel Mac unexpectedly accepted'
  assert_contains "$output" 'Apple Silicon'
  assert_file_not_contains "$sandbox_dir/command.log" 'orbctl'
}

test_orbstack_provisioning_rejects_root_runner_before_mutation() {
  new_sandbox
  install_uname_mock arm64
  install_orbctl_machine_mock

  local output status
  set +e
  output="$(
    cd "$sandbox_dir/repo" &&
      PATH="$sandbox_dir/bin:$PATH" \
      MOCK_COMMAND_LOG="$sandbox_dir/command.log" \
      GITHUB_SCOPE=repository \
      GITHUB_URL=https://github.com/acme/widget \
      FLEET_ID=studio \
      RUNNER_USER=root \
      ./provision-orbstack.sh 2>&1
  )"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'root runner user unexpectedly accepted'
  assert_contains "$output" 'RUNNER_USER'
  assert_contains "$output" 'root'
  [ ! -s "$sandbox_dir/command.log" ] || fail 'OrbStack mutation occurred before root-user rejection'
}

test_generic_install_rejects_root_runner_before_mutation() {
  new_sandbox
  install_runner_user_id_mock
  mkdir -p "$sandbox_dir/runner-home"
  cat > "$sandbox_dir/bin/curl" <<'MOCK'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "${MOCK_COMMAND_LOG:?}"
exit 74
MOCK
  chmod +x "$sandbox_dir/bin/curl"

  local output status
  set +e
  output="$(
    cd "$sandbox_dir/repo" &&
      PATH="$sandbox_dir/bin:$PATH" \
      MOCK_COMMAND_LOG="$sandbox_dir/command.log" \
      GITHUB_SCOPE=repository \
      GITHUB_URL=https://github.com/acme/widget \
      FLEET_ID=studio \
      REGTOKEN=unused-registration-token \
      RUNNER_HOME="$sandbox_dir/runner-home" \
      RUNNER_USER=root \
      RUNNER_ARCH=linux-arm64 \
      ./install-runners.sh 2>&1
  )"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'generic installer accepted root runner user'
  assert_contains "$output" 'RUNNER_USER must be a non-root account'
  assert_file_not_contains "$sandbox_dir/command.log" 'curl '
  assert_file_not_contains "$sandbox_dir/command.log" 'config.sh'
  assert_file_not_contains "$sandbox_dir/command.log" 'svc.sh'
  [ -z "$(find "$sandbox_dir/runner-home" -mindepth 1 -print -quit)" ] || fail 'runner files created before root-user rejection'
}

test_generic_install_rejects_mismatched_nonroot_account_before_token() {
  new_sandbox
  install_runner_user_id_mock
  mkdir -p "$sandbox_dir/runner-home"
  cat > "$sandbox_dir/bin/curl" <<'MOCK'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "${MOCK_COMMAND_LOG:?}"
exit 74
MOCK
  chmod +x "$sandbox_dir/bin/curl"

  local output status
  set +e
  output="$(
    cd "$sandbox_dir/repo" &&
      PATH="$sandbox_dir/bin:$PATH" \
      MOCK_COMMAND_LOG="$sandbox_dir/command.log" \
      MOCK_EFFECTIVE_UID=501 \
      MOCK_CONFIGURED_UID=502 \
      MOCK_EFFECTIVE_USER=alice \
      GITHUB_SCOPE=repository \
      GITHUB_URL=https://github.com/acme/widget \
      FLEET_ID=studio \
      RUNNER_HOME="$sandbox_dir/runner-home" \
      RUNNER_USER=deploy \
      RUNNER_ARCH=linux-arm64 \
      ./install-runners.sh 2>&1
  )"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'installer accepted a different non-root account'
  assert_contains "$output" "does not match RUNNER_USER 'deploy' UID"
  assert_contains "$output" "run install-runners.sh as 'deploy'"
  assert_file_contains "$sandbox_dir/command.log" 'id -u'
  assert_file_contains "$sandbox_dir/command.log" 'id -u deploy'
  assert_file_not_contains "$sandbox_dir/command.log" 'curl '
  assert_file_not_contains "$sandbox_dir/command.log" 'config.sh'
  assert_file_not_contains "$sandbox_dir/command.log" 'svc.sh'
  case "$output" in
    *'REGTOKEN env required'*) fail 'token validation happened before account mismatch rejection' ;;
  esac
  [ -z "$(find "$sandbox_dir/runner-home" -mindepth 1 -print -quit)" ] || fail 'runner files created before account mismatch rejection'
}

test_orbstack_creation_uses_secure_arm_defaults() {
  new_sandbox
  install_uname_mock arm64
  install_orbctl_machine_mock

  local output status
  set +e
  output="$(
    cd "$sandbox_dir/repo" &&
      PATH="$sandbox_dir/bin:$PATH" \
      MOCK_COMMAND_LOG="$sandbox_dir/command.log" \
      MOCK_MACHINE_EXISTS=0 \
      MOCK_CREATE_STATUS=77 \
      GITHUB_URL=https://github.com/acme/widget \
      FLEET_ID=studio \
      ./provision-orbstack.sh 2>&1
  )"
  status=$?
  set -e
  assert_status 77 "$status"
  assert_file_contains "$sandbox_dir/command.log" 'orbctl create --arch arm64 --cpus 2 --memory 4G --disk 48G --isolated --isolate-network --user deploy ubuntu:24.04 little-ci-acme-widget-studio'
  assert_contains "$output" '1 runner'
}

test_existing_orbstack_machine_is_validated_before_start() {
  new_sandbox
  install_uname_mock arm64
  install_orbctl_machine_mock

  local output status
  set +e
  output="$(
    cd "$sandbox_dir/repo" &&
      PATH="$sandbox_dir/bin:$PATH" \
      MOCK_COMMAND_LOG="$sandbox_dir/command.log" \
      MOCK_MACHINE_EXISTS=1 \
      MOCK_MACHINE_NAME=little-ci-acme-widget-studio \
      MOCK_ORB_INFO='{"record":{"name":"little-ci-acme-widget-studio","image":{"distro":"ubuntu","version":"noble","arch":"arm64"},"config":{"isolated":true,"isolate_network":true,"forward_ssh_agent":true,"default_username":"deploy","cpu_limit":2,"memory_limit_mib":4096,"disk_limit_bytes":51539607552}}}' \
      GITHUB_URL=https://github.com/acme/widget \
      FLEET_ID=studio \
      ./provision-orbstack.sh 2>&1
  )"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'insecure existing machine unexpectedly accepted'
  assert_contains "$output" 'disable SSH-agent forwarding and Mac mounts'
  assert_file_contains "$sandbox_dir/command.log" 'orbctl info little-ci-acme-widget-studio --format json'
  assert_file_not_contains "$sandbox_dir/command.log" 'orbctl start'
}

test_compatible_orbstack_machine_reaches_start() {
  new_sandbox
  install_uname_mock arm64
  install_orbctl_machine_mock

  local status
  set +e
  (
    cd "$sandbox_dir/repo" &&
      PATH="$sandbox_dir/bin:$PATH" \
      MOCK_COMMAND_LOG="$sandbox_dir/command.log" \
      MOCK_MACHINE_EXISTS=1 \
      MOCK_MACHINE_NAME=little-ci-acme-widget-studio \
      MOCK_START_STATUS=76 \
      MOCK_ORB_INFO='{"record":{"name":"little-ci-acme-widget-studio","image":{"distro":"ubuntu","version":"noble","arch":"arm64"},"config":{"isolated":true,"isolate_network":true,"forward_ssh_agent":false,"default_username":"deploy","cpu_limit":2,"memory_limit_mib":4096,"disk_limit_bytes":51539607552}}}' \
      GITHUB_URL=https://github.com/acme/widget \
      FLEET_ID=studio \
      ./provision-orbstack.sh >/dev/null 2>&1
  )
  status=$?
  set -e
  assert_status 76 "$status"
  assert_file_contains "$sandbox_dir/command.log" 'orbctl start little-ci-acme-widget-studio'
}

test_existing_orbstack_identity_mismatch_blocks_package_mutation() {
  new_sandbox
  install_uname_mock arm64
  install_orbctl_machine_mock

  local output status
  set +e
  output="$(
    cd "$sandbox_dir/repo" &&
      PATH="$sandbox_dir/bin:$PATH" \
      MOCK_COMMAND_LOG="$sandbox_dir/command.log" \
      MOCK_MACHINE_EXISTS=1 \
      MOCK_MACHINE_NAME=little-ci-acme-widget-studio \
      MOCK_ORB_INFO='{"record":{"name":"little-ci-acme-widget-studio","state":"running","image":{"distro":"ubuntu","version":"noble","arch":"arm64"},"config":{"isolated":true,"isolate_network":true,"forward_ssh_agent":false,"default_username":"deploy","cpu_limit":2,"memory_limit_mib":4096,"disk_limit_bytes":51539607552}}}' \
      MOCK_ORB_IDENTITY=$'machine=little-ci-acme-widget-studio\nscope=repository\ntarget=acme/other\nprefix=little-ci-acme-other-studio\nuser=deploy\nhome=/home/deploy' \
      GITHUB_SCOPE=repository \
      GITHUB_URL=https://github.com/acme/widget \
      FLEET_ID=studio \
      ./provision-orbstack.sh 2>&1
  )"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'existing machine with mismatched identity unexpectedly mutated'
  assert_contains "$output" 'refusing to modify an existing machine without matching Little-CI ownership'
  assert_file_contains "$sandbox_dir/command.log" 'cat /etc/little-ci/identity'
  assert_file_not_contains "$sandbox_dir/command.log" 'bash -s'
  assert_file_not_contains "$sandbox_dir/command.log" 'mkdir -p /home/deploy/little-ci'
}

test_new_orbstack_machine_installs_needrestart_runner_policy() {
  new_sandbox
  install_uname_mock arm64
  install_orbctl_machine_mock
  : > "$sandbox_dir/orbctl-stdin.log"

  local output status
  set +e
  output="$(
    cd "$sandbox_dir/repo" &&
      PATH="$sandbox_dir/bin:$PATH" \
      MOCK_COMMAND_LOG="$sandbox_dir/command.log" \
      MOCK_ORBCTL_STDIN_LOG="$sandbox_dir/orbctl-stdin.log" \
      MOCK_MACHINE_EXISTS=0 \
      MOCK_ORB_INFO='{"record":{"name":"little-ci-acme-widget-studio","state":"running","image":{"distro":"ubuntu","version":"noble","arch":"arm64"},"config":{"isolated":true,"isolate_network":true,"forward_ssh_agent":false,"default_username":"deploy","cpu_limit":2,"memory_limit_mib":4096,"disk_limit_bytes":51539607552}}}' \
      MOCK_ORB_IDENTITY=$'machine=little-ci-acme-widget-studio\nscope=repository\ntarget=acme/widget\nprefix=little-ci-acme-widget-studio\nuser=deploy\nhome=/home/deploy' \
      GITHUB_SCOPE=repository \
      GITHUB_URL=https://github.com/acme/widget \
      FLEET_ID=studio \
      ./provision-orbstack.sh 2>&1
  )"
  status=$?
  set -e
  assert_status 0 "$status"
  assert_file_contains "$sandbox_dir/orbctl-stdin.log" '/etc/needrestart/conf.d/actions_runner_services.conf'
  assert_file_contains "$sandbox_dir/orbctl-stdin.log" "override_rc"
  assert_file_contains "$sandbox_dir/orbctl-stdin.log" 'actions\.runner'
  assert_contains "$output" 'little-ci-acme-widget-studio ready'
}

test_orbstack_guest_skips_swapfile_commands() {
  new_sandbox
  mkdir -p "$sandbox_dir/orbstack-guest"

  cat > "$sandbox_dir/bin/id" <<'MOCK'
#!/usr/bin/env bash
[ "${1:-}" = -u ] && { printf '0\n'; exit 0; }
/usr/bin/id "$@"
MOCK
  cat > "$sandbox_dir/bin/awk" <<'MOCK'
#!/usr/bin/env bash
# Simulate an OrbStack guest without legacy Little-CI fstab entries.
exit 0
MOCK
  cat > "$sandbox_dir/bin/sysctl" <<'MOCK'
#!/usr/bin/env bash
printf 'sysctl %s\n' "$*" >> "${MOCK_COMMAND_LOG:?}"
exit 75
MOCK
  for command_name in fallocate dd mkswap swapon; do
    cat > "$sandbox_dir/bin/$command_name" <<'MOCK'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$*" >> "${MOCK_COMMAND_LOG:?}"
exit 74
MOCK
    chmod +x "$sandbox_dir/bin/$command_name"
  done
  chmod +x "$sandbox_dir/bin/id" "$sandbox_dir/bin/awk" "$sandbox_dir/bin/sysctl"

  local output status
  set +e
  output="$(
    cd "$sandbox_dir/repo" &&
      PATH="$sandbox_dir/bin:$PATH" \
      MOCK_COMMAND_LOG="$sandbox_dir/command.log" \
      LITTLE_CI_ORBSTACK_GUEST_MARKER="$sandbox_dir/orbstack-guest" \
      GITHUB_URL=https://github.com/acme/widget \
      FLEET_ID=studio \
      ./provision-box.sh 2>&1
  )"
  status=$?
  set -e
  assert_status 75 "$status"
  assert_contains "$output" 'OrbStack guest detected'
  assert_file_contains "$sandbox_dir/command.log" 'sysctl -w vm.swappiness=10'
  assert_file_not_contains "$sandbox_dir/command.log" 'fallocate'
  assert_file_not_contains "$sandbox_dir/command.log" 'dd '
  assert_file_not_contains "$sandbox_dir/command.log" 'mkswap'
  assert_file_not_contains "$sandbox_dir/command.log" 'swapon'
}

test_existing_runner_accepts_utf8_bom() {
  new_sandbox
  install_runner_user_id_mock
  PATH="$sandbox_dir/bin:$PATH"
  export PATH
  mkdir -p "$sandbox_dir/runner-home/actions-runner-1"
  : > "$sandbox_dir/runner-home/actions-runner-linux-arm64-2.337.0.tar.gz"
  printf '\357\273\277%s\n' \
    '{"agentName":"little-ci-acme-widget-1","gitHubUrl":"https://github.com/acme/widget","workFolder":"_work"}' \
    > "$sandbox_dir/runner-home/actions-runner-1/.runner"

  local output status
  set +e
  output="$(
    cd "$sandbox_dir/repo" &&
      MOCK_COMMAND_LOG="$sandbox_dir/command.log" \
      GITHUB_SCOPE=repository \
      GITHUB_URL=https://github.com/acme/widget \
      REGTOKEN=unused-registration-token \
      RUNNER_HOME="$sandbox_dir/runner-home" \
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
  assert_contains "$output" 'existing local registration retained'
  assert_file_contains "$sandbox_dir/command.log" 'id -u'
  assert_file_contains "$sandbox_dir/command.log" 'id -u deploy'
}

test_existing_service_gets_exact_fleet_scratch_drop_in() {
  new_sandbox
  install_runner_user_id_mock
  local runner_prefix=little-ci-acme-widget-studio
  local service_name=actions.runner.acme-widget.little-ci-acme-widget-studio-1.service
  local runner_dir="$sandbox_dir/runner-home/actions-runner-1"
  create_existing_runner_fixture "$runner_prefix-1" "$service_name"
  install_service_command_mocks

  local output status
  set +e
  output="$(
    cd "$sandbox_dir/repo" &&
      PATH="$sandbox_dir/bin:$PATH" \
      MOCK_COMMAND_LOG="$sandbox_dir/command.log" \
      MOCK_RUNNER_DIR="$runner_dir" \
      MOCK_RUNNER_USER=deploy \
      MOCK_RUNNER_PREFIX="$runner_prefix" \
      MOCK_SERVICE_NAME="$service_name" \
      MOCK_DROP_IN_STATE=unchanged \
      MOCK_TEE_OUTPUT="$sandbox_dir/drop-in.conf" \
      GITHUB_SCOPE=repository \
      GITHUB_URL=https://github.com/acme/widget \
      FLEET_ID=studio \
      REGTOKEN=unused-registration-token \
      RUNNER_HOME="$sandbox_dir/runner-home" \
      RUNNER_USER=deploy \
      RUNNER_ARCH=linux-arm64 \
      RUNNER_COUNT=1 \
      ./install-runners.sh 2>&1
  )"
  status=$?
  set -e
  assert_status 0 "$status"
  assert_file_contains "$sandbox_dir/command.log" "sudo test -f /etc/systemd/system/$service_name"
  assert_file_contains "$sandbox_dir/command.log" 'sudo install -d -m 1777 /scratch/little-ci-acme-widget-studio/1'
  assert_file_not_contains "$sandbox_dir/command.log" "sudo tee /etc/systemd/system/$service_name.d/zz-little-ci-scratch.conf"
  assert_file_contains "$sandbox_dir/command.log" 'sudo ./svc.sh start'
  assert_contains "$output" 'existing local registration retained'
}

test_active_service_drop_in_drift_is_rejected() {
  local drop_in_state="$1"
  new_sandbox
  install_runner_user_id_mock
  local runner_prefix=little-ci-acme-widget-studio
  local service_name=actions.runner.acme-widget.little-ci-acme-widget-studio-1.service
  local runner_dir="$sandbox_dir/runner-home/actions-runner-1"
  create_existing_runner_fixture "$runner_prefix-1" "$service_name"
  install_service_command_mocks

  local output status
  set +e
  output="$(
    cd "$sandbox_dir/repo" &&
      PATH="$sandbox_dir/bin:$PATH" \
      MOCK_COMMAND_LOG="$sandbox_dir/command.log" \
      MOCK_RUNNER_DIR="$runner_dir" \
      MOCK_RUNNER_USER=deploy \
      MOCK_RUNNER_PREFIX="$runner_prefix" \
      MOCK_SERVICE_NAME="$service_name" \
      MOCK_DROP_IN_STATE="$drop_in_state" \
      MOCK_SERVICE_ACTIVE=1 \
      MOCK_TEE_OUTPUT="$sandbox_dir/drop-in.conf" \
      GITHUB_SCOPE=repository \
      GITHUB_URL=https://github.com/acme/widget \
      FLEET_ID=studio \
      REGTOKEN=unused-registration-token \
      RUNNER_HOME="$sandbox_dir/runner-home" \
      RUNNER_USER=deploy \
      RUNNER_ARCH=linux-arm64 \
      RUNNER_COUNT=1 \
      ./install-runners.sh 2>&1
  )"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "active service unexpectedly accepted $drop_in_state scratch drop-in"
  assert_contains "$output" 'active and its scratch drop-in needs repair'
  assert_file_not_contains "$sandbox_dir/command.log" 'sudo install -d'
  assert_file_not_contains "$sandbox_dir/command.log" 'sudo tee'
  assert_file_not_contains "$sandbox_dir/command.log" 'sudo ./svc.sh start'
}

test_service_drop_in_symlink_is_rejected_before_write() {
  local symlink_kind="$1"
  new_sandbox
  install_runner_user_id_mock
  local runner_prefix=little-ci-acme-widget-studio
  local service_name=actions.runner.acme-widget.little-ci-acme-widget-studio-1.service
  local runner_dir="$sandbox_dir/runner-home/actions-runner-1"
  create_existing_runner_fixture "$runner_prefix-1" "$service_name"
  install_service_command_mocks

  local output status
  set +e
  output="$(
    cd "$sandbox_dir/repo" &&
      PATH="$sandbox_dir/bin:$PATH" \
      MOCK_COMMAND_LOG="$sandbox_dir/command.log" \
      MOCK_RUNNER_DIR="$runner_dir" \
      MOCK_RUNNER_USER=deploy \
      MOCK_RUNNER_PREFIX="$runner_prefix" \
      MOCK_SERVICE_NAME="$service_name" \
      MOCK_DROP_IN_STATE=unchanged \
      MOCK_DROP_IN_SYMLINK="$symlink_kind" \
      MOCK_TEE_OUTPUT="$sandbox_dir/drop-in.conf" \
      GITHUB_SCOPE=repository \
      GITHUB_URL=https://github.com/acme/widget \
      FLEET_ID=studio \
      REGTOKEN=unused-registration-token \
      RUNNER_HOME="$sandbox_dir/runner-home" \
      RUNNER_USER=deploy \
      RUNNER_ARCH=linux-arm64 \
      RUNNER_COUNT=1 \
      ./install-runners.sh 2>&1
  )"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "$symlink_kind symlink unexpectedly accepted"
  case "$symlink_kind" in
    dir) assert_contains "$output" 'drop-in path must be a real directory' ;;
    file) assert_contains "$output" 'drop-in must be a regular non-symlink file' ;;
  esac
  assert_file_not_contains "$sandbox_dir/command.log" 'sudo cat'
  assert_file_not_contains "$sandbox_dir/command.log" 'sudo install -d'
  assert_file_not_contains "$sandbox_dir/command.log" 'sudo tee'
  assert_file_not_contains "$sandbox_dir/command.log" 'sudo systemctl'
  assert_file_not_contains "$sandbox_dir/command.log" 'sudo ./svc.sh start'
}

test_inactive_service_repairs_scratch_drop_in_then_starts() {
  new_sandbox
  install_runner_user_id_mock
  local runner_prefix=little-ci-acme-widget-studio
  local service_name=actions.runner.acme-widget.little-ci-acme-widget-studio-1.service
  local runner_dir="$sandbox_dir/runner-home/actions-runner-1"
  create_existing_runner_fixture "$runner_prefix-1" "$service_name"
  install_service_command_mocks

  local output status
  set +e
  output="$(
    cd "$sandbox_dir/repo" &&
      PATH="$sandbox_dir/bin:$PATH" \
      MOCK_COMMAND_LOG="$sandbox_dir/command.log" \
      MOCK_RUNNER_DIR="$runner_dir" \
      MOCK_RUNNER_USER=deploy \
      MOCK_RUNNER_PREFIX="$runner_prefix" \
      MOCK_SERVICE_NAME="$service_name" \
      MOCK_DROP_IN_STATE=missing \
      MOCK_SERVICE_ACTIVE=0 \
      MOCK_TEE_OUTPUT="$sandbox_dir/drop-in.conf" \
      GITHUB_SCOPE=repository \
      GITHUB_URL=https://github.com/acme/widget \
      FLEET_ID=studio \
      REGTOKEN=unused-registration-token \
      RUNNER_HOME="$sandbox_dir/runner-home" \
      RUNNER_USER=deploy \
      RUNNER_ARCH=linux-arm64 \
      RUNNER_COUNT=1 \
      ./install-runners.sh 2>&1
  )"
  status=$?
  set -e
  assert_status 0 "$status"
  assert_file_contains "$sandbox_dir/command.log" "sudo tee /etc/systemd/system/$service_name.d/zz-little-ci-scratch.conf"
  assert_file_contains "$sandbox_dir/drop-in.conf" "Environment=TMPDIR=/scratch/$runner_prefix/1"
  assert_file_contains "$sandbox_dir/command.log" 'sudo systemctl daemon-reload'
  assert_file_contains "$sandbox_dir/command.log" 'sudo ./svc.sh start'
  assert_file_order "$sandbox_dir/command.log" 'sudo tee' 'sudo systemctl daemon-reload'
  assert_file_order "$sandbox_dir/command.log" 'sudo systemctl daemon-reload' 'sudo ./svc.sh start'
  assert_contains "$output" 'existing local registration retained'
}

test_mismatched_service_unit_blocks_scratch_and_start() {
  new_sandbox
  install_runner_user_id_mock
  local runner_prefix=little-ci-acme-widget-studio
  local service_name=actions.runner.acme-widget.little-ci-acme-widget-studio-1.service
  local runner_dir="$sandbox_dir/runner-home/actions-runner-1"
  create_existing_runner_fixture "$runner_prefix-1" "$service_name"
  install_service_command_mocks

  local output status
  set +e
  output="$(
    cd "$sandbox_dir/repo" &&
      PATH="$sandbox_dir/bin:$PATH" \
      MOCK_COMMAND_LOG="$sandbox_dir/command.log" \
      MOCK_RUNNER_DIR="$runner_dir" \
      MOCK_RUNNER_USER=deploy \
      MOCK_SERVICE_NAME="$service_name" \
      MOCK_SERVICE_OWNERSHIP=mismatched \
      MOCK_TEE_OUTPUT="$sandbox_dir/drop-in.conf" \
      GITHUB_SCOPE=repository \
      GITHUB_URL=https://github.com/acme/widget \
      FLEET_ID=studio \
      REGTOKEN=unused-registration-token \
      RUNNER_HOME="$sandbox_dir/runner-home" \
      RUNNER_USER=deploy \
      RUNNER_ARCH=linux-arm64 \
      RUNNER_COUNT=1 \
      ./install-runners.sh 2>&1
  )"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'mismatched service ownership unexpectedly accepted'
  assert_contains "$output" 'does not belong'
  assert_file_not_contains "$sandbox_dir/command.log" '/scratch/'
  assert_file_not_contains "$sandbox_dir/command.log" './svc.sh start'
  [ ! -e "$sandbox_dir/drop-in.conf" ] || fail 'drop-in written for mismatched service'
}

test_legacy_swapfile_cleanup_is_opt_in() {
  new_sandbox
  mkdir -p "$sandbox_dir/orbstack-guest"
  cat > "$sandbox_dir/bin/id" <<'MOCK'
#!/usr/bin/env bash
[ "${1:-}" = -u ] && { printf '0\n'; exit 0; }
/usr/bin/id "$@"
MOCK
  cat > "$sandbox_dir/bin/awk" <<'MOCK'
#!/usr/bin/env bash
printf '/swapfile1\n'
MOCK
  cat > "$sandbox_dir/bin/sysctl" <<'MOCK'
#!/usr/bin/env bash
exit 75
MOCK
  for command_name in rm swapoff; do
    cat > "$sandbox_dir/bin/$command_name" <<'MOCK'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$*" >> "${MOCK_COMMAND_LOG:?}"
exit 74
MOCK
    chmod +x "$sandbox_dir/bin/$command_name"
  done
  chmod +x "$sandbox_dir/bin/id" "$sandbox_dir/bin/awk" "$sandbox_dir/bin/sysctl"

  local output status
  set +e
  output="$(
    cd "$sandbox_dir/repo" &&
      PATH="$sandbox_dir/bin:$PATH" \
      MOCK_COMMAND_LOG="$sandbox_dir/command.log" \
      LITTLE_CI_ORBSTACK_GUEST_MARKER="$sandbox_dir/orbstack-guest" \
      GITHUB_URL=https://github.com/acme/widget \
      FLEET_ID=studio \
      ./provision-box.sh 2>&1
  )"
  status=$?
  set -e
  assert_status 75 "$status"
  assert_contains "$output" 'set REMOVE_LEGACY_SWAPFILES=1'
  assert_file_not_contains "$sandbox_dir/command.log" 'rm '
  assert_file_not_contains "$sandbox_dir/command.log" 'swapoff'
}

test_swap_manifest_records_exact_owned_path_and_rejects_unsafe_permissions() {
  new_sandbox
  local manifest_dir="$sandbox_dir/managed-state-studio"
  local manifest_path="$manifest_dir/managed-swapfiles"
  local second_manifest_dir="$sandbox_dir/managed-state-laptop"
  local second_manifest_path="$second_manifest_dir/managed-swapfiles"
  mkdir -p "$manifest_dir"
  mkdir -p "$second_manifest_dir"
  : > "$manifest_path"
  : > "$second_manifest_path"
  cat > "$sandbox_dir/bin/stat" <<'MOCK'
#!/usr/bin/env bash
case "${!#}" in
  */managed-swapfiles) printf '%s\n' "${MOCK_MANIFEST_STAT:?}" ;;
  */managed-state-*) printf '0:0:700\n' ;;
  *) exit 1 ;;
esac
MOCK
  chmod +x "$sandbox_dir/bin/stat"

  local status
  set +e
  (
    cd "$sandbox_dir/repo" &&
      PATH="$sandbox_dir/bin:$PATH" \
      MOCK_MANIFEST_STAT=0:0:600 \
      bash -c '. ./provision-box.sh; swap_ownership_manifest="$1"; record_created_swapfile 1 /swapfile-little-ci-acme-widget-studio-1; record_created_swapfile 1 /swapfile-little-ci-acme-widget-studio-1' bash "$manifest_path"
  )
  status=$?
  set -e
  assert_status 0 "$status"
  [ "$(cat "$manifest_path")" = $'1\t/swapfile-little-ci-acme-widget-studio-1' ] || fail 'managed swapfile record is not exact or idempotent'

  (
    cd "$sandbox_dir/repo" &&
      PATH="$sandbox_dir/bin:$PATH" \
      MOCK_MANIFEST_STAT=0:0:600 \
      bash -c '. ./provision-box.sh; swap_ownership_manifest="$1"; record_created_swapfile 1 /swapfile-little-ci-acme-widget-laptop-1' bash "$second_manifest_path"
  )
  [ "$(cat "$second_manifest_path")" = $'1\t/swapfile-little-ci-acme-widget-laptop-1' ] || fail 'second fleet swapfile record is not exact'
  [ "$(cut -f2 "$manifest_path")" != "$(cut -f2 "$second_manifest_path")" ] || fail 'two fleets mapped runner 1 to the same swapfile path'

  set +e
  (
    cd "$sandbox_dir/repo" &&
      PATH="$sandbox_dir/bin:$PATH" \
      MOCK_MANIFEST_STAT=501:20:644 \
      bash -c '. ./provision-box.sh; swap_ownership_manifest="$1"; record_created_swapfile 3 /swapfile-little-ci-acme-widget-studio-3' bash "$manifest_path"
  ) >/dev/null 2>&1
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'unsafe swap manifest permissions unexpectedly accepted'
  [ "$(cat "$manifest_path")" = $'1\t/swapfile-little-ci-acme-widget-studio-1' ] || fail 'unsafe manifest state was modified'
}

test_config_file_rejects_persisted_tokens_without_leaking_value() {
  new_sandbox
  printf '%s\n' \
    'GITHUB_URL=https://github.com/acme/widget' \
    'REGTOKEN=do-not-print-this-secret' \
    > "$sandbox_dir/repo/config.env"

  local output provision_output provision_status status
  set +e
  output="$(cd "$sandbox_dir/repo" && ./install-runners.sh 2>&1)"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'persisted registration token unexpectedly accepted'
  assert_contains "$output" 'must not contain GitHub credentials'
  case "$output" in
    *do-not-print-this-secret*) fail 'secret value leaked in error output' ;;
  esac

  set +e
  provision_output="$(cd "$sandbox_dir/repo" && ./provision-orbstack.sh 2>&1)"
  provision_status=$?
  set -e
  [ "$provision_status" -ne 0 ] || fail 'provisioning accepted a persisted registration token'
  assert_contains "$provision_output" 'must not contain GitHub credentials'
  case "$provision_output" in
    *do-not-print-this-secret*) fail 'secret value leaked from provisioning error output' ;;
  esac
}

test_doctor_reports_missing_configured_runner_label() {
  new_sandbox
  install_uname_mock arm64
  install_gh_mock
  install_orbctl_machine_mock

  local output status
  set +e
  output="$(
    cd "$sandbox_dir/repo" &&
      PATH="$sandbox_dir/bin:$PATH" \
      MOCK_COMMAND_LOG="$sandbox_dir/command.log" \
      MOCK_ORB_INFO='{"record":{"name":"little-ci-acme-widget-studio","state":"running","image":{"distro":"ubuntu","version":"noble","arch":"arm64"},"config":{"isolated":true,"isolate_network":true,"forward_ssh_agent":false,"default_username":"deploy","cpu_limit":2,"memory_limit_mib":4096,"disk_limit_bytes":51539607552}}}' \
      MOCK_ORB_IDENTITY=$'machine=little-ci-acme-widget-studio\nscope=repository\ntarget=acme/widget\nprefix=little-ci-acme-widget-studio\nuser=deploy\nhome=/home/deploy' \
      MOCK_GH_RESPONSE='[{"runners":[{"id":41,"name":"little-ci-acme-widget-studio-1","status":"online","labels":[{"name":"little-ci"},{"name":"little-ci-acme-widget-studio"}]}]}]' \
      GITHUB_SCOPE=repository \
      GITHUB_URL=https://github.com/acme/widget \
      FLEET_ID=studio \
      RUNNER_LABELS=little-ci,project-ci \
      ./doctor.sh 2>&1
  )"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'doctor unexpectedly accepted runner missing configured label'
  assert_contains "$output" 'missing required labels project-ci'
  assert_contains "$output" 'reinstall this runner to reconcile labels'
}

test_doctor_requires_exact_runner_name_and_arm64_labels() {
  new_sandbox
  install_uname_mock arm64
  install_gh_mock
  install_orbctl_machine_mock

  local output status
  set +e
  output="$(
    cd "$sandbox_dir/repo" &&
      PATH="$sandbox_dir/bin:$PATH" \
      MOCK_COMMAND_LOG="$sandbox_dir/command.log" \
      MOCK_ORB_INFO='{"record":{"name":"little-ci-acme-widget-studio","state":"running","image":{"distro":"ubuntu","version":"noble","arch":"arm64"},"config":{"isolated":true,"isolate_network":true,"forward_ssh_agent":false,"default_username":"deploy","cpu_limit":2,"memory_limit_mib":4096,"disk_limit_bytes":51539607552}}}' \
      MOCK_ORB_IDENTITY=$'machine=little-ci-acme-widget-studio\nscope=repository\ntarget=acme/widget\nprefix=little-ci-acme-widget-studio\nuser=deploy\nhome=/home/deploy' \
      MOCK_GH_RESPONSE='[{"runners":[{"id":41,"name":"little-ci-acme-widget-studio-1","status":"online","labels":[{"name":"little-ci"},{"name":"project-ci"},{"name":"little-ci-acme-widget-studio"}]}]}]' \
      GITHUB_SCOPE=repository \
      GITHUB_URL=https://github.com/acme/widget \
      FLEET_ID=studio \
      RUNNER_LABELS=little-ci,project-ci \
      ./doctor.sh 2>&1
  )"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'doctor unexpectedly accepted missing exact-name and arm64 labels'
  assert_contains "$output" 'little-ci-acme-widget-studio-1'
  assert_contains "$output" 'arm64'
  assert_contains "$output" 'missing required labels'
}

test_doctor_always_requires_stable_little_ci_label() {
  new_sandbox
  install_uname_mock arm64
  install_gh_mock
  install_orbctl_machine_mock

  local output status
  set +e
  output="$(
    cd "$sandbox_dir/repo" &&
      PATH="$sandbox_dir/bin:$PATH" \
      MOCK_COMMAND_LOG="$sandbox_dir/command.log" \
      MOCK_ORB_INFO='{"record":{"name":"little-ci-acme-widget-studio","state":"running","image":{"distro":"ubuntu","version":"noble","arch":"arm64"},"config":{"isolated":true,"isolate_network":true,"forward_ssh_agent":false,"default_username":"deploy","cpu_limit":2,"memory_limit_mib":4096,"disk_limit_bytes":51539607552}}}' \
      MOCK_ORB_IDENTITY=$'machine=little-ci-acme-widget-studio\nscope=repository\ntarget=acme/widget\nprefix=little-ci-acme-widget-studio\nuser=deploy\nhome=/home/deploy' \
      MOCK_GH_RESPONSE='[{"runners":[{"id":41,"name":"little-ci-acme-widget-studio-1","status":"online","labels":[{"name":"project-ci"},{"name":"little-ci-acme-widget-studio"},{"name":"little-ci-acme-widget-studio-1"},{"name":"arm64"}]}]}]' \
      GITHUB_SCOPE=repository \
      GITHUB_URL=https://github.com/acme/widget \
      FLEET_ID=studio \
      RUNNER_LABELS=project-ci \
      ./doctor.sh 2>&1
  )"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'doctor unexpectedly accepted missing stable little-ci label'
  assert_contains "$output" 'missing required labels little-ci'
}

test_orbstack_uninstall_forwards_remove_token_and_cleans_matching_stale_runner() {
  new_sandbox
  install_gh_mock
  install_orbctl_machine_mock

  local output status
  set +e
  output="$(
    cd "$sandbox_dir/repo" &&
      PATH="$sandbox_dir/bin:$PATH" \
      MOCK_COMMAND_LOG="$sandbox_dir/command.log" \
      MOCK_MACHINE_EXISTS=1 \
      MOCK_MACHINE_NAME=little-ci-acme \
      MOCK_ORB_INFO='{"record":{"name":"little-ci-acme","state":"running","image":{"distro":"ubuntu","version":"noble","arch":"arm64"},"config":{"isolated":true,"isolate_network":true,"forward_ssh_agent":false,"default_username":"deploy","cpu_limit":2,"memory_limit_mib":4096,"disk_limit_bytes":51539607552}}}' \
      MOCK_ORB_IDENTITY=$'machine=little-ci-acme\nscope=organization\ntarget=acme\nprefix=little-ci-acme\nuser=deploy\nhome=/home/deploy' \
      MOCK_GH_TOKEN=do-not-log-remove-token \
      MOCK_GH_RESPONSE='[{"runners":[{"id":41,"name":"little-ci-acme-1","status":"offline","labels":[{"name":"little-ci-acme"}]},{"id":99,"name":"other-fleet-1","status":"offline","labels":[{"name":"other-fleet"}]}]}]' \
      GITHUB_SCOPE=organization \
      GITHUB_URL=https://github.com/acme \
      RUNNER_GROUP=trusted-macs \
      RUNNER_NAME_PREFIX=little-ci-acme \
      ./uninstall-runners-orb.sh --all --confirm 2>&1
  )"
  status=$?
  set -e
  assert_status 0 "$status"
  assert_file_contains "$sandbox_dir/command.log" '/orgs/acme/actions/runners/remove-token'
  assert_file_contains "$sandbox_dir/command.log" 'ORBENV=REMOVETOKEN:GITHUB_SCOPE:GITHUB_URL:RUNNER_COUNT:RUNNER_NAME_PREFIX:RUNNER_USER:RUNNER_HOME:RUNNER_GROUP'
  assert_file_contains "$sandbox_dir/command.log" 'bash -s -- --all --confirm'
  assert_file_contains "$sandbox_dir/command.log" '/orgs/acme/actions/runners/41'
  assert_file_not_contains "$sandbox_dir/command.log" '/orgs/acme/actions/runners/99'
  assert_file_not_contains "$sandbox_dir/command.log" 'orbctl delete'
  case "$output$(cat "$sandbox_dir/command.log")" in
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
    cd "$sandbox_dir/repo" &&
      PATH="$sandbox_dir/bin:$PATH" \
      MOCK_COMMAND_LOG="$sandbox_dir/command.log" \
      GITHUB_URL=https://github.com/acme/widget \
      ./uninstall-runners-orb.sh --prune --confirm --delete-machine 2>&1
  )"
  status=$?
  set -e
  assert_status 2 "$status"
  assert_contains "$output" 'allowed only with --all'
  [ ! -s "$sandbox_dir/command.log" ] || fail 'external commands ran before delete-mode validation'
}

test_orbstack_uninstall_rejects_markerless_machine_before_github() {
  new_sandbox
  install_uname_mock arm64
  install_gh_mock
  install_orbctl_machine_mock

  local output status
  set +e
  output="$(
    cd "$sandbox_dir/repo" &&
      PATH="$sandbox_dir/bin:$PATH" \
      MOCK_COMMAND_LOG="$sandbox_dir/command.log" \
      MOCK_MACHINE_EXISTS=1 \
      MOCK_MACHINE_NAME=little-ci-acme-widget-studio \
      MOCK_IDENTITY_PRESENT=0 \
      MOCK_ORB_INFO='{"record":{"name":"little-ci-acme-widget-studio","state":"running","image":{"distro":"ubuntu","version":"noble","arch":"arm64"},"config":{"isolated":true,"isolate_network":true,"forward_ssh_agent":false,"default_username":"deploy","cpu_limit":2,"memory_limit_mib":4096,"disk_limit_bytes":51539607552}}}' \
      GITHUB_SCOPE=repository \
      GITHUB_URL=https://github.com/acme/widget \
      FLEET_ID=studio \
      ./uninstall-runners-orb.sh --all --confirm --delete-machine 2>&1
  )"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'markerless machine unexpectedly accepted for teardown'
  assert_contains "$output" 'no protected Little-CI identity'
  assert_file_not_contains "$sandbox_dir/command.log" 'gh '
  assert_file_not_contains "$sandbox_dir/command.log" 'bash -s -- --all --confirm'
  assert_file_not_contains "$sandbox_dir/command.log" 'orbctl delete'
}

test_orbstack_uninstall_rejects_mismatched_identity_before_github() {
  new_sandbox
  install_uname_mock arm64
  install_gh_mock
  install_orbctl_machine_mock

  local output status
  set +e
  output="$(
    cd "$sandbox_dir/repo" &&
      PATH="$sandbox_dir/bin:$PATH" \
      MOCK_COMMAND_LOG="$sandbox_dir/command.log" \
      MOCK_MACHINE_EXISTS=1 \
      MOCK_MACHINE_NAME=little-ci-acme-widget-studio \
      MOCK_ORB_INFO='{"record":{"name":"little-ci-acme-widget-studio","state":"running","image":{"distro":"ubuntu","version":"noble","arch":"arm64"},"config":{"isolated":true,"isolate_network":true,"forward_ssh_agent":false,"default_username":"deploy","cpu_limit":2,"memory_limit_mib":4096,"disk_limit_bytes":51539607552}}}' \
      MOCK_ORB_IDENTITY=$'machine=little-ci-acme-widget-studio\nscope=repository\ntarget=acme/other\nprefix=little-ci-acme-other-studio\nuser=deploy\nhome=/home/deploy' \
      GITHUB_SCOPE=repository \
      GITHUB_URL=https://github.com/acme/widget \
      FLEET_ID=studio \
      ./uninstall-runners-orb.sh --all --confirm --delete-machine 2>&1
  )"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'mismatched machine identity unexpectedly accepted for teardown'
  assert_contains "$output" 'belongs to a different Little-CI fleet'
  assert_file_not_contains "$sandbox_dir/command.log" 'gh '
  assert_file_not_contains "$sandbox_dir/command.log" 'bash -s -- --all --confirm'
  assert_file_not_contains "$sandbox_dir/command.log" 'orbctl delete'
}

test_orbstack_uninstall_guest_failure_reports_recovery_without_deleting() {
  new_sandbox
  install_uname_mock arm64
  install_gh_mock
  install_orbctl_machine_mock

  local output status
  set +e
  output="$(
    cd "$sandbox_dir/repo" &&
      PATH="$sandbox_dir/bin:$PATH" \
      MOCK_COMMAND_LOG="$sandbox_dir/command.log" \
      MOCK_MACHINE_EXISTS=1 \
      MOCK_MACHINE_NAME=little-ci-acme-widget-studio \
      MOCK_GUEST_UNINSTALL_STATUS=1 \
      MOCK_ORB_INFO='{"record":{"name":"little-ci-acme-widget-studio","state":"running","image":{"distro":"ubuntu","version":"noble","arch":"arm64"},"config":{"isolated":true,"isolate_network":true,"forward_ssh_agent":false,"default_username":"deploy","cpu_limit":2,"memory_limit_mib":4096,"disk_limit_bytes":51539607552}}}' \
      MOCK_ORB_IDENTITY=$'machine=little-ci-acme-widget-studio\nscope=repository\ntarget=acme/widget\nprefix=little-ci-acme-widget-studio\nuser=deploy\nhome=/home/deploy' \
      MOCK_GH_RESPONSE='[{"runners":[{"id":41,"name":"little-ci-acme-widget-studio-1","status":"offline","busy":false,"labels":[{"name":"little-ci-acme-widget-studio"}]}]}]' \
      GITHUB_SCOPE=repository \
      GITHUB_URL=https://github.com/acme/widget \
      FLEET_ID=studio \
      ./uninstall-runners-orb.sh --all --confirm --delete-machine 2>&1
  )"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'guest uninstall failure unexpectedly reported success'
  assert_contains "$output" 'Remaining selected GitHub registrations:'
  assert_contains "$output" 'Remaining selected local directories and services:'
  assert_contains "$output" 'Recovery: rerun ./uninstall-runners-orb.sh --all --confirm'
  assert_file_contains "$sandbox_dir/command.log" 'bash -s -- --all --confirm'
  assert_file_not_contains "$sandbox_dir/command.log" '--method DELETE'
  assert_file_not_contains "$sandbox_dir/command.log" 'orbctl delete'
}

test_orbstack_uninstall_allows_safe_resource_drift() {
  new_sandbox
  install_uname_mock arm64
  install_gh_mock
  install_orbctl_machine_mock

  local output status
  set +e
  output="$(
    cd "$sandbox_dir/repo" &&
      PATH="$sandbox_dir/bin:$PATH" \
      MOCK_COMMAND_LOG="$sandbox_dir/command.log" \
      MOCK_MACHINE_EXISTS=1 \
      MOCK_MACHINE_NAME=little-ci-acme-widget-studio \
      MOCK_ORB_INFO='{"record":{"name":"little-ci-acme-widget-studio","state":"running","image":{"distro":"ubuntu","version":"noble","arch":"arm64"},"config":{"isolated":true,"isolate_network":true,"forward_ssh_agent":false,"default_username":"deploy","cpu_limit":8,"memory_limit_mib":16384,"disk_limit_bytes":107374182400}}}' \
      MOCK_ORB_IDENTITY=$'machine=little-ci-acme-widget-studio\nscope=repository\ntarget=acme/widget\nprefix=little-ci-acme-widget-studio\nuser=deploy\nhome=/home/deploy' \
      MOCK_GH_RESPONSE='[{"runners":[]}]' \
      GITHUB_SCOPE=repository \
      GITHUB_URL=https://github.com/acme/widget \
      FLEET_ID=studio \
      ORB_CPUS=2 \
      ORB_MEMORY=4G \
      ORB_DISK=48G \
      ./uninstall-runners-orb.sh --all --confirm 2>&1
  )"
  status=$?
  set -e
  assert_status 0 "$status"
  assert_file_contains "$sandbox_dir/command.log" '/repos/acme/widget/actions/runners/remove-token'
  assert_file_contains "$sandbox_dir/command.log" 'bash -s -- --all --confirm'
  assert_contains "$output" 'OrbStack machine retained'
}

test_stale_runner_api_read_failure_reports_recovery_without_machine_delete() {
  new_sandbox
  install_uname_mock arm64
  install_lifecycle_gh_failure_mock
  install_orbctl_machine_mock
  : > "$sandbox_dir/gh-count"

  local output status
  set +e
  output="$(
    cd "$sandbox_dir/repo" &&
      PATH="$sandbox_dir/bin:$PATH" \
      MOCK_COMMAND_LOG="$sandbox_dir/command.log" \
      MOCK_GH_COUNT_FILE="$sandbox_dir/gh-count" \
      MOCK_GH_FAILURE_MODE=read \
      MOCK_GH_RESPONSE='[{"runners":[{"id":41,"name":"little-ci-acme-widget-studio-1","status":"offline","busy":false,"labels":[{"name":"little-ci-acme-widget-studio"}]}]}]' \
      MOCK_MACHINE_EXISTS=1 \
      MOCK_MACHINE_NAME=little-ci-acme-widget-studio \
      MOCK_ORB_INFO='{"record":{"name":"little-ci-acme-widget-studio","state":"running","image":{"distro":"ubuntu","version":"noble","arch":"arm64"},"config":{"isolated":true,"isolate_network":true,"forward_ssh_agent":false,"default_username":"deploy","cpu_limit":2,"memory_limit_mib":4096,"disk_limit_bytes":51539607552}}}' \
      MOCK_ORB_IDENTITY=$'machine=little-ci-acme-widget-studio\nscope=repository\ntarget=acme/widget\nprefix=little-ci-acme-widget-studio\nuser=deploy\nhome=/home/deploy' \
      GITHUB_SCOPE=repository \
      GITHUB_URL=https://github.com/acme/widget \
      FLEET_ID=studio \
      ./uninstall-runners-orb.sh --all --confirm --delete-machine 2>&1
  )"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'stale-runner API read failure unexpectedly reported success'
  assert_contains "$output" 'Remaining selected GitHub registrations:'
  assert_contains "$output" 'Recovery: rerun ./uninstall-runners-orb.sh --all --confirm'
  assert_file_not_contains "$sandbox_dir/command.log" 'orbctl delete'
}

test_stale_runner_delete_failure_reports_recovery_without_machine_delete() {
  new_sandbox
  install_uname_mock arm64
  install_lifecycle_gh_failure_mock
  install_orbctl_machine_mock
  : > "$sandbox_dir/gh-count"

  local output status
  set +e
  output="$(
    cd "$sandbox_dir/repo" &&
      PATH="$sandbox_dir/bin:$PATH" \
      MOCK_COMMAND_LOG="$sandbox_dir/command.log" \
      MOCK_GH_COUNT_FILE="$sandbox_dir/gh-count" \
      MOCK_GH_FAILURE_MODE=delete \
      MOCK_GH_RESPONSE='[{"runners":[{"id":41,"name":"little-ci-acme-widget-studio-1","status":"offline","busy":false,"labels":[{"name":"little-ci-acme-widget-studio"}]}]}]' \
      MOCK_MACHINE_EXISTS=1 \
      MOCK_MACHINE_NAME=little-ci-acme-widget-studio \
      MOCK_ORB_INFO='{"record":{"name":"little-ci-acme-widget-studio","state":"running","image":{"distro":"ubuntu","version":"noble","arch":"arm64"},"config":{"isolated":true,"isolate_network":true,"forward_ssh_agent":false,"default_username":"deploy","cpu_limit":2,"memory_limit_mib":4096,"disk_limit_bytes":51539607552}}}' \
      MOCK_ORB_IDENTITY=$'machine=little-ci-acme-widget-studio\nscope=repository\ntarget=acme/widget\nprefix=little-ci-acme-widget-studio\nuser=deploy\nhome=/home/deploy' \
      GITHUB_SCOPE=repository \
      GITHUB_URL=https://github.com/acme/widget \
      FLEET_ID=studio \
      ./uninstall-runners-orb.sh --all --confirm --delete-machine 2>&1
  )"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'stale-runner DELETE failure unexpectedly reported success'
  assert_file_contains "$sandbox_dir/command.log" '--method DELETE /repos/acme/widget/actions/runners/41'
  assert_contains "$output" 'Remaining selected GitHub registrations:'
  assert_contains "$output" 'Recovery: rerun ./uninstall-runners-orb.sh --all --confirm'
  assert_file_not_contains "$sandbox_dir/command.log" 'orbctl delete'
}

test_malformed_guest_runner_metadata_blocks_stale_and_machine_deletion() {
  new_sandbox
  install_uname_mock arm64
  install_gh_mock
  install_orbctl_machine_mock
  local runner_user runner_home runner_dir
  runner_user="$(id -un)"
  runner_home="$sandbox_dir/guest-home"
  mkdir -p "$runner_home/actions-runner-1"
  runner_home="$(cd "$runner_home" && pwd -P)"
  runner_dir="$runner_home/actions-runner-1"
  printf '{malformed json\n' > "$runner_dir/.runner"
  install_uninstall_resource_mocks

  local output status
  set +e
  output="$(
    cd "$sandbox_dir/repo" &&
      PATH="$sandbox_dir/bin:$PATH" \
      MOCK_COMMAND_LOG="$sandbox_dir/command.log" \
      MOCK_ALLOWED_RUNNER_DIR="$runner_dir" \
      MOCK_RUNNER_PREFIX=little-ci-acme-widget-studio \
      MOCK_PENDING_RECORD_STORE="$sandbox_dir/pending-record" \
      MOCK_MACHINE_EXISTS=1 \
      MOCK_MACHINE_NAME=little-ci-acme-widget-studio \
      MOCK_EXECUTE_GUEST_UNINSTALL=1 \
      MOCK_ORB_INFO="{\"record\":{\"name\":\"little-ci-acme-widget-studio\",\"state\":\"running\",\"image\":{\"distro\":\"ubuntu\",\"version\":\"noble\",\"arch\":\"arm64\"},\"config\":{\"isolated\":true,\"isolate_network\":true,\"forward_ssh_agent\":false,\"default_username\":\"$runner_user\",\"cpu_limit\":2,\"memory_limit_mib\":4096,\"disk_limit_bytes\":51539607552}}}" \
      MOCK_ORB_IDENTITY="$(printf 'machine=little-ci-acme-widget-studio\nscope=repository\ntarget=acme/widget\nprefix=little-ci-acme-widget-studio\nuser=%s\nhome=%s' "$runner_user" "$runner_home")" \
      MOCK_GH_RESPONSE='[{"runners":[{"id":41,"name":"little-ci-acme-widget-studio-1","status":"offline","busy":false,"labels":[{"name":"little-ci-acme-widget-studio"}]}]}]' \
      GITHUB_SCOPE=repository \
      GITHUB_URL=https://github.com/acme/widget \
      FLEET_ID=studio \
      RUNNER_USER="$runner_user" \
      RUNNER_HOME="$runner_home" \
      ./uninstall-runners-orb.sh --all --confirm --delete-machine 2>&1
  )"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'malformed runner metadata unexpectedly allowed teardown to continue'
  assert_contains "$output" 'unreadable'
  assert_contains "$output" 'Recovery:'
  assert_file_not_contains "$sandbox_dir/command.log" '--method DELETE'
  assert_file_not_contains "$sandbox_dir/command.log" 'orbctl delete'
  [ -f "$runner_dir/.runner" ] || fail 'malformed runner metadata was removed'
}

test_organization_runner_group_reaches_registration_command() {
  new_sandbox
  install_runner_user_id_mock
  PATH="$sandbox_dir/bin:$PATH"
  export PATH
  mkdir -p "$sandbox_dir/runner-package" "$sandbox_dir/runner-home"
  cat > "$sandbox_dir/runner-package/config.sh" <<'MOCK'
#!/usr/bin/env bash
printf 'config.sh' >> "${MOCK_COMMAND_LOG:?}"
printf ' %q' "$@" >> "$MOCK_COMMAND_LOG"
printf '\n' >> "$MOCK_COMMAND_LOG"
MOCK
  chmod +x "$sandbox_dir/runner-package/config.sh"
  tar -C "$sandbox_dir/runner-package" -czf \
    "$sandbox_dir/runner-home/actions-runner-linux-arm64-2.337.0.tar.gz" .

  local output status
  set +e
  output="$(
    cd "$sandbox_dir/repo" &&
      MOCK_COMMAND_LOG="$sandbox_dir/command.log" \
      GITHUB_SCOPE=organization \
      GITHUB_URL=https://github.com/acme \
      REGTOKEN=unused-registration-token \
      RUNNER_HOME="$sandbox_dir/runner-home" \
      RUNNER_USER=deploy \
      RUNNER_ARCH=linux-arm64 \
      RUNNER_COUNT=1 \
      RUNNER_GROUP=trusted-macs \
      FLEET_ID=studio \
      SKIP_SERVICE_INSTALL=1 \
      ./install-runners.sh 2>&1
  )"
  status=$?
  set -e
  assert_status 0 "$status"
  assert_file_contains "$sandbox_dir/command.log" '--runnergroup trusted-macs'
  assert_file_contains "$sandbox_dir/command.log" '--labels little-ci\,little-ci-acme-studio\,little-ci-acme-studio-1\,arm64'
  assert_file_not_contains "$sandbox_dir/command.log" '--replace'
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
    cd "$sandbox_dir/repo" &&
      PATH="$sandbox_dir/bin:$PATH" \
      MOCK_COMMAND_LOG="$sandbox_dir/command.log" \
      MOCK_GH_TOKEN=do-not-log-registration-token \
      MOCK_MACHINE_EXISTS=1 \
      MOCK_MACHINE_NAME=little-ci-acme-studio \
      MOCK_ORB_INFO='{"record":{"name":"little-ci-acme-studio","image":{"distro":"ubuntu","version":"noble","arch":"arm64"},"config":{"isolated":true,"isolate_network":true,"forward_ssh_agent":false,"default_username":"deploy","cpu_limit":2,"memory_limit_mib":4096,"disk_limit_bytes":51539607552}}}' \
      MOCK_ORB_IDENTITY=$'machine=little-ci-acme-studio\nscope=organization\ntarget=acme\nprefix=little-ci-acme-studio\nuser=deploy\nhome=/home/deploy' \
      GITHUB_SCOPE=organization \
      GITHUB_URL=https://github.com/acme \
      FLEET_ID=studio \
      RUNNER_GROUP=trusted-macs \
      RUNNER_USER=deploy \
      RUNNER_COUNT=1 \
      ./install-runners-orb.sh 2>&1
  )"
  status=$?
  set -e
  assert_status 0 "$status"
  assert_file_order "$sandbox_dir/command.log" 'orbctl info little-ci-acme-studio --format json' 'orbctl start little-ci-acme-studio'
  assert_file_order "$sandbox_dir/command.log" 'cat /etc/little-ci/identity' '/orgs/acme/actions/runners/registration-token'
  assert_file_order "$sandbox_dir/command.log" '/orgs/acme/actions/runners/registration-token' 'mkdir -p /home/deploy/little-ci'
  assert_file_contains "$sandbox_dir/command.log" '/orgs/acme/actions/runners/registration-token'
  assert_file_contains "$sandbox_dir/command.log" 'ORBENV=REGTOKEN'
  assert_file_contains "$sandbox_dir/command.log" 'RUNNER_ARCH=linux-arm64\ SKIP_SERVICE_INSTALL=1\ ./install-runners.sh'
  assert_file_contains "$sandbox_dir/command.log" '-u root'
  assert_file_contains "$sandbox_dir/command.log" './svc.sh start'
  case "$output$(cat "$sandbox_dir/command.log")" in
    *do-not-log-registration-token*) fail 'registration token leaked to output or command log' ;;
  esac
}

test_orbstack_install_rejects_mismatched_machine_identity_before_token() {
  new_sandbox
  install_uname_mock arm64
  install_gh_mock
  install_orbctl_machine_mock

  local output status
  set +e
  output="$(
    cd "$sandbox_dir/repo" &&
      PATH="$sandbox_dir/bin:$PATH" \
      MOCK_COMMAND_LOG="$sandbox_dir/command.log" \
      MOCK_ORB_INFO='{"record":{"name":"little-ci-acme-widget-studio","image":{"distro":"ubuntu","version":"noble","arch":"arm64"},"config":{"isolated":true,"isolate_network":true,"forward_ssh_agent":false,"default_username":"deploy","cpu_limit":2,"memory_limit_mib":4096,"disk_limit_bytes":51539607552}}}' \
      MOCK_ORB_IDENTITY=$'machine=little-ci-acme-widget-studio\nscope=repository\ntarget=acme/other\nprefix=little-ci-acme-other-studio\nuser=deploy\nhome=/home/deploy' \
      GITHUB_SCOPE=repository \
      GITHUB_URL=https://github.com/acme/widget \
      FLEET_ID=studio \
      ./install-runners-orb.sh 2>&1
  )"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'mismatched machine identity unexpectedly accepted'
  assert_contains "$output" 'belongs to a different Little-CI fleet'
  assert_file_contains "$sandbox_dir/command.log" 'orbctl info little-ci-acme-widget-studio --format json'
  assert_file_contains "$sandbox_dir/command.log" 'cat /etc/little-ci/identity'
  assert_file_not_contains "$sandbox_dir/command.log" 'registration-token'
  assert_file_not_contains "$sandbox_dir/command.log" 'mkdir -p /home/deploy/little-ci'
}

test_orbstack_install_rejects_root_effective_guest_user_before_token() {
  new_sandbox
  install_uname_mock arm64
  install_gh_mock
  install_orbctl_machine_mock

  local output status
  set +e
  output="$(
    cd "$sandbox_dir/repo" &&
      PATH="$sandbox_dir/bin:$PATH" \
      MOCK_COMMAND_LOG="$sandbox_dir/command.log" \
      MOCK_GUEST_UID=0 \
      MOCK_ORB_INFO='{"record":{"name":"little-ci-acme-widget-studio","image":{"distro":"ubuntu","version":"noble","arch":"arm64"},"config":{"isolated":true,"isolate_network":true,"forward_ssh_agent":false,"default_username":"deploy","cpu_limit":2,"memory_limit_mib":4096,"disk_limit_bytes":51539607552}}}' \
      MOCK_ORB_IDENTITY=$'machine=little-ci-acme-widget-studio\nscope=repository\ntarget=acme/widget\nprefix=little-ci-acme-widget-studio\nuser=deploy\nhome=/home/deploy' \
      GITHUB_SCOPE=repository \
      GITHUB_URL=https://github.com/acme/widget \
      FLEET_ID=studio \
      ./install-runners-orb.sh 2>&1
  )"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'OrbStack wrapper accepted runner user resolving to UID 0'
  assert_contains "$output" 'non-root UID'
  assert_file_order "$sandbox_dir/command.log" 'cat /etc/little-ci/identity' 'id -u'
  assert_file_not_contains "$sandbox_dir/command.log" 'registration-token'
  assert_file_not_contains "$sandbox_dir/command.log" 'mkdir -p /home/deploy/little-ci'
}

test_orbstack_install_rejects_mac_mount_before_start() {
  local configured_mounts="${1:-/Users}"
  local mounts_status="${2:-0}"
  local expected_error="${3:-disable SSH-agent forwarding and Mac mounts}"
  new_sandbox
  install_uname_mock arm64
  install_gh_mock
  install_orbctl_machine_mock

  local output status
  set +e
  output="$(
    cd "$sandbox_dir/repo" &&
      PATH="$sandbox_dir/bin:$PATH" \
      MOCK_COMMAND_LOG="$sandbox_dir/command.log" \
      MOCK_CONFIGURED_MOUNTS="$configured_mounts" \
      MOCK_MOUNTS_STATUS="$mounts_status" \
      MOCK_ORB_INFO='{"record":{"name":"little-ci-acme-widget-studio","image":{"distro":"ubuntu","version":"noble","arch":"arm64"},"config":{"isolated":true,"isolate_network":true,"forward_ssh_agent":false,"default_username":"deploy","cpu_limit":2,"memory_limit_mib":4096,"disk_limit_bytes":51539607552}}}' \
      GITHUB_SCOPE=repository \
      GITHUB_URL=https://github.com/acme/widget \
      FLEET_ID=studio \
      ./install-runners-orb.sh 2>&1
  )"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'machine with Mac mount unexpectedly accepted'
  assert_contains "$output" "$expected_error"
  assert_file_contains "$sandbox_dir/command.log" 'orbctl config get machine.little-ci-acme-widget-studio.mounts'
  assert_file_not_contains "$sandbox_dir/command.log" 'orbctl start'
  assert_file_not_contains "$sandbox_dir/command.log" 'registration-token'
}

test_orbstack_transfers_use_explicit_allowlist() {
  new_sandbox
  install_uname_mock arm64
  install_orbctl_machine_mock
  install_tar_inventory_mock
  printf 'untracked secret\n' > "$sandbox_dir/repo/.env"
  printf 'runner credential\n' > "$sandbox_dir/repo/.credentials"
  printf 'arbitrary note\n' > "$sandbox_dir/repo/arbitrary-notes.txt"
  mkdir -p "$sandbox_dir/repo/_work"
  printf 'workspace residue\n' > "$sandbox_dir/repo/_work/residue"
  : > "$sandbox_dir/archive-inventory.log"

  local install_status provision_status
  set +e
  (
    cd "$sandbox_dir/repo" &&
      PATH="$sandbox_dir/bin:$PATH" \
      MOCK_COMMAND_LOG="$sandbox_dir/command.log" \
      MOCK_ARCHIVE_INVENTORY="$sandbox_dir/archive-inventory.log" \
      MOCK_ORB_INFO='{"record":{"name":"little-ci-acme-widget-studio","state":"running","image":{"distro":"ubuntu","version":"noble","arch":"arm64"},"config":{"isolated":true,"isolate_network":true,"forward_ssh_agent":false,"default_username":"deploy","cpu_limit":2,"memory_limit_mib":4096,"disk_limit_bytes":51539607552}}}' \
      MOCK_ORB_IDENTITY=$'machine=little-ci-acme-widget-studio\nscope=repository\ntarget=acme/widget\nprefix=little-ci-acme-widget-studio\nuser=deploy\nhome=/home/deploy' \
      GITHUB_SCOPE=repository \
      GITHUB_URL=https://github.com/acme/widget \
      FLEET_ID=studio \
      REGTOKEN=unused-registration-token \
      ./install-runners-orb.sh >/dev/null 2>&1
  )
  install_status=$?
  set -e
  assert_status 0 "$install_status"
  assert_file_not_contains "$sandbox_dir/archive-inventory.log" '.env'
  assert_file_not_contains "$sandbox_dir/archive-inventory.log" '.credentials'
  assert_file_not_contains "$sandbox_dir/archive-inventory.log" '_work'
  assert_file_not_contains "$sandbox_dir/archive-inventory.log" 'arbitrary-notes.txt'
  assert_file_not_contains "$sandbox_dir/archive-inventory.log" 'README.md'
  assert_file_not_contains "$sandbox_dir/archive-inventory.log" 'tests/'
  assert_file_not_contains "$sandbox_dir/archive-inventory.log" 'examples/'
  assert_file_contains "$sandbox_dir/archive-inventory.log" 'install-runners.sh'
  assert_file_contains "$sandbox_dir/archive-inventory.log" 'lib/github-target.sh'

  : > "$sandbox_dir/archive-inventory.log"
  set +e
  (
    cd "$sandbox_dir/repo" &&
      PATH="$sandbox_dir/bin:$PATH" \
      MOCK_COMMAND_LOG="$sandbox_dir/command.log" \
      MOCK_ARCHIVE_INVENTORY="$sandbox_dir/archive-inventory.log" \
      MOCK_MACHINE_EXISTS=1 \
      MOCK_MACHINE_NAME=little-ci-acme-widget-studio \
      MOCK_ORB_INFO='{"record":{"name":"little-ci-acme-widget-studio","state":"running","image":{"distro":"ubuntu","version":"noble","arch":"arm64"},"config":{"isolated":true,"isolate_network":true,"forward_ssh_agent":false,"default_username":"deploy","cpu_limit":2,"memory_limit_mib":4096,"disk_limit_bytes":51539607552}}}' \
      MOCK_ORB_IDENTITY=$'machine=little-ci-acme-widget-studio\nscope=repository\ntarget=acme/widget\nprefix=little-ci-acme-widget-studio\nuser=deploy\nhome=/home/deploy' \
      GITHUB_SCOPE=repository \
      GITHUB_URL=https://github.com/acme/widget \
      FLEET_ID=studio \
      ./provision-orbstack.sh >/dev/null 2>&1
  )
  provision_status=$?
  set -e
  assert_status 0 "$provision_status"
  assert_file_not_contains "$sandbox_dir/archive-inventory.log" '.env'
  assert_file_not_contains "$sandbox_dir/archive-inventory.log" '.credentials'
  assert_file_not_contains "$sandbox_dir/archive-inventory.log" '_work'
  assert_file_not_contains "$sandbox_dir/archive-inventory.log" 'arbitrary-notes.txt'
  assert_file_not_contains "$sandbox_dir/archive-inventory.log" 'README.md'
  assert_file_not_contains "$sandbox_dir/archive-inventory.log" 'tests/'
  assert_file_not_contains "$sandbox_dir/archive-inventory.log" 'examples/'
  assert_file_contains "$sandbox_dir/archive-inventory.log" 'provision-box.sh'
  assert_file_contains "$sandbox_dir/archive-inventory.log" 'uninstall-runners.sh'
}

test_local_uninstall_uses_remove_token_and_deletes_selected_runner() {
  new_sandbox
  local runner_home="$sandbox_dir/runner-home"
  mkdir -p "$runner_home"
  runner_home="$(cd "$runner_home" && pwd -P)"
  local runner_dir="$runner_home/actions-runner-1"
  local runner_prefix=little-ci-acme-widget
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
rm -f .runner
MOCK
  cat > "$sandbox_dir/bin/sudo" <<'MOCK'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >> "${MOCK_COMMAND_LOG:?}"
case "${1:-}" in
  test) exit 1 ;;
  rm)
    runner_path="${!#}"
    if [ "$runner_path" = "${MOCK_ALLOWED_RUNNER_DIR:?}" ]; then
      /bin/rm -rf -- "$runner_path"
    fi
    ;;
  rmdir|systemctl) exit 0 ;;
  *) exit 1 ;;
esac
MOCK
  chmod +x "$runner_dir/config.sh" "$sandbox_dir/bin/sudo"
  install_uninstall_resource_mocks

  local output status
  set +e
  output="$(
    cd "$sandbox_dir/repo" &&
      PATH="$sandbox_dir/bin:$PATH" \
      MOCK_COMMAND_LOG="$sandbox_dir/command.log" \
      MOCK_ALLOWED_RUNNER_DIR="$runner_dir" \
      MOCK_RUNNER_PREFIX="$runner_prefix" \
      MOCK_PENDING_RECORD_STORE="$sandbox_dir/pending-record" \
      GITHUB_SCOPE=repository \
      GITHUB_URL=https://github.com/acme/widget \
      REMOVETOKEN=unused-remove-token \
      RUNNER_HOME="$runner_home" \
      RUNNER_USER="$runner_user" \
      RUNNER_COUNT=1 \
      RUNNER_NAME_PREFIX="$runner_prefix" \
      ./uninstall-runners.sh --all --confirm 2>&1
  )"
  status=$?
  set -e
  assert_status 0 "$status"
  assert_file_contains "$sandbox_dir/command.log" 'config-remove-token=matched'
  [ ! -e "$runner_dir" ] || fail 'selected runner directory was not removed'
  assert_contains "$output" 'Local removal complete: 1 removed, 0 failed.'
}

test_local_uninstall_rejects_root_runner_home_before_commands() {
  new_sandbox
  cat > "$sandbox_dir/bin/sudo" <<'MOCK'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >> "${MOCK_COMMAND_LOG:?}"
exit 74
MOCK
  chmod +x "$sandbox_dir/bin/sudo"

  local output status
  set +e
  output="$(
    cd "$sandbox_dir/repo" &&
      PATH="$sandbox_dir/bin:$PATH" \
      MOCK_COMMAND_LOG="$sandbox_dir/command.log" \
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
  [ ! -s "$sandbox_dir/command.log" ] || fail 'privileged command ran with RUNNER_HOME=/'
}

test_unselected_malformed_runner_does_not_block_removal_mode() {
  local removal_mode="$1"
  new_sandbox
  local runner_home="$sandbox_dir/removal-home"
  mkdir -p "$runner_home/actions-runner-1"
  runner_home="$(cd "$runner_home" && pwd -P)"
  printf '{malformed json\n' > "$runner_home/actions-runner-1/.runner"
  install_uninstall_resource_mocks

  local -a removal_args
  case "$removal_mode" in
    runner) removal_args=(--runner little-ci-acme-widget-studio-2 --confirm) ;;
    prune) removal_args=(--prune --confirm) ;;
    *) fail "unsupported removal mode fixture: $removal_mode" ;;
  esac

  local output status
  set +e
  output="$(
    cd "$sandbox_dir/repo" &&
      PATH="$sandbox_dir/bin:$PATH" \
      MOCK_COMMAND_LOG="$sandbox_dir/command.log" \
      MOCK_RUNNER_PREFIX=little-ci-acme-widget-studio \
      MOCK_PENDING_RECORD_STORE="$sandbox_dir/pending-record" \
      GITHUB_SCOPE=repository \
      GITHUB_URL=https://github.com/acme/widget \
      FLEET_ID=studio \
      REMOVETOKEN=unused-remove-token \
      RUNNER_COUNT=1 \
      RUNNER_HOME="$runner_home" \
      RUNNER_USER="$(id -un)" \
      ./uninstall-runners.sh "${removal_args[@]}" 2>&1
  )"
  status=$?
  set -e
  assert_status 0 "$status"
  assert_contains "$output" 'No selected local runners found'
  case "$output" in
    *'unreadable or malformed'*) fail "unselected malformed runner blocked --$removal_mode" ;;
  esac
  [ -f "$runner_home/actions-runner-1/.runner" ] || fail 'unselected malformed runner was mutated'
}

test_selected_malformed_runner_fails_closed() {
  new_sandbox
  local runner_home="$sandbox_dir/removal-home"
  mkdir -p "$runner_home/actions-runner-1"
  runner_home="$(cd "$runner_home" && pwd -P)"
  printf '{malformed json\n' > "$runner_home/actions-runner-1/.runner"
  install_uninstall_resource_mocks

  local output status
  set +e
  output="$(
    cd "$sandbox_dir/repo" &&
      PATH="$sandbox_dir/bin:$PATH" \
      MOCK_COMMAND_LOG="$sandbox_dir/command.log" \
      MOCK_RUNNER_PREFIX=little-ci-acme-widget-studio \
      MOCK_PENDING_RECORD_STORE="$sandbox_dir/pending-record" \
      GITHUB_SCOPE=repository \
      GITHUB_URL=https://github.com/acme/widget \
      FLEET_ID=studio \
      REMOVETOKEN=unused-remove-token \
      RUNNER_HOME="$runner_home" \
      RUNNER_USER="$(id -un)" \
      ./uninstall-runners.sh --runner little-ci-acme-widget-studio-1 --confirm 2>&1
  )"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'selected malformed runner unexpectedly accepted'
  assert_contains "$output" 'unreadable or malformed'
  assert_contains "$output" 'no mutation performed'
  [ -f "$runner_home/actions-runner-1/.runner" ] || fail 'selected malformed runner was mutated'
}

test_local_uninstall_removes_only_owned_service_scratch_and_swap_artifacts() {
  new_sandbox
  local runner_home="$sandbox_dir/removal-home"
  mkdir -p "$runner_home"
  runner_home="$(cd "$runner_home" && pwd -P)"
  local runner_dir="$runner_home/actions-runner-1"
  local runner_prefix=little-ci-acme-widget-studio
  local service_name=actions.runner.acme-widget.little-ci-acme-widget-studio-1.service
  create_removable_runner_fixture "$runner_home" "$runner_prefix-1" "$service_name"
  cat > "$runner_dir/config.sh" <<'MOCK'
#!/usr/bin/env bash
printf 'config-remove-called\n' >> "${MOCK_COMMAND_LOG:?}"
rm -f .runner
MOCK
  chmod +x "$runner_dir/config.sh"
  install_uninstall_resource_mocks

  local output status
  set +e
  output="$(
    cd "$sandbox_dir/repo" &&
      PATH="$sandbox_dir/bin:$PATH" \
      MOCK_COMMAND_LOG="$sandbox_dir/command.log" \
      MOCK_ALLOWED_RUNNER_DIR="$runner_dir" \
      MOCK_RUNNER_PREFIX="$runner_prefix" \
      MOCK_PENDING_RECORD_STORE="$sandbox_dir/pending-record" \
      GITHUB_SCOPE=repository \
      GITHUB_URL=https://github.com/acme/widget \
      FLEET_ID=studio \
      REMOVETOKEN=unused-remove-token \
      RUNNER_HOME="$runner_home" \
      RUNNER_USER="$(id -un)" \
      ./uninstall-runners.sh --all --confirm 2>&1
  )"
  status=$?
  set -e
  assert_status 0 "$status"
  assert_file_order "$sandbox_dir/command.log" "/pending-cleanup/1 1 $runner_prefix-1" 'sudo ./svc.sh uninstall'
  assert_file_order "$sandbox_dir/command.log" 'sudo ./svc.sh uninstall' 'config-remove-called'
  assert_file_order "$sandbox_dir/command.log" 'config-remove-called' "sudo rm -rf -- /scratch/$runner_prefix/1"
  assert_file_order "$sandbox_dir/command.log" "sudo rm -rf -- $runner_dir" "sudo rm -f -- /var/lib/little-ci/fleets/$runner_prefix/pending-cleanup/1"
  assert_file_contains "$sandbox_dir/command.log" "sudo rm -f -- /etc/systemd/system/$service_name.d/zz-little-ci-scratch.conf"
  assert_file_contains "$sandbox_dir/command.log" "sudo rmdir /etc/systemd/system/$service_name.d"
  assert_file_not_contains "$sandbox_dir/command.log" "rm -rf -- /etc/systemd/system/$service_name.d"
  assert_file_contains "$sandbox_dir/command.log" "sudo rm -rf -- /scratch/$runner_prefix/1"
  assert_file_contains "$sandbox_dir/command.log" "sudo swapoff /swapfile-$runner_prefix-1"
  assert_file_contains "$sandbox_dir/command.log" "sudo python3 - /swapfile-$runner_prefix-1"
  assert_file_contains "$sandbox_dir/command.log" "sudo rm -f -- /swapfile-$runner_prefix-1"
  assert_file_contains "$sandbox_dir/command.log" "sudo python3 - 1 /swapfile-$runner_prefix-1 /var/lib/little-ci/fleets/$runner_prefix/managed-swapfiles"
  [ ! -e "$runner_dir" ] || fail 'runner directory retained after complete owned-resource cleanup'
  [ ! -e "$sandbox_dir/pending-record" ] || fail 'pending cleanup record remained after complete cleanup'
  assert_contains "$output" 'Local removal complete: 1 removed, 0 failed.'
}

test_local_uninstall_service_mismatch_performs_no_mutation() {
  new_sandbox
  local runner_home="$sandbox_dir/removal-home"
  mkdir -p "$runner_home"
  runner_home="$(cd "$runner_home" && pwd -P)"
  local runner_dir="$runner_home/actions-runner-1"
  local runner_prefix=little-ci-acme-widget-studio
  local service_name=actions.runner.unrelated.valid-looking.service
  create_removable_runner_fixture "$runner_home" "$runner_prefix-1" "$service_name"
  install_uninstall_resource_mocks

  local output status
  set +e
  output="$(
    cd "$sandbox_dir/repo" &&
      PATH="$sandbox_dir/bin:$PATH" \
      MOCK_COMMAND_LOG="$sandbox_dir/command.log" \
      MOCK_ALLOWED_RUNNER_DIR="$runner_dir" \
      MOCK_RUNNER_PREFIX="$runner_prefix" \
      MOCK_PENDING_RECORD_STORE="$sandbox_dir/pending-record" \
      MOCK_SERVICE_OWNERSHIP=mismatched \
      GITHUB_SCOPE=repository \
      GITHUB_URL=https://github.com/acme/widget \
      FLEET_ID=studio \
      REMOVETOKEN=unused-remove-token \
      RUNNER_HOME="$runner_home" \
      RUNNER_USER="$(id -un)" \
      ./uninstall-runners.sh --all --confirm 2>&1
  )"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'unrelated service identity unexpectedly accepted'
  assert_contains "$output" 'does not belong'
  assert_file_not_contains "$sandbox_dir/command.log" 'sudo ./svc.sh uninstall'
  assert_file_not_contains "$sandbox_dir/command.log" 'sudo rm '
  assert_file_not_contains "$sandbox_dir/command.log" 'sudo swapoff'
  [ -d "$runner_dir" ] || fail 'runner directory changed after ownership rejection'
}

test_local_uninstall_swap_failure_retains_runner_and_manifest_state() {
  new_sandbox
  local runner_home="$sandbox_dir/removal-home"
  mkdir -p "$runner_home"
  runner_home="$(cd "$runner_home" && pwd -P)"
  local runner_dir="$runner_home/actions-runner-1"
  local runner_prefix=little-ci-acme-widget-studio
  local service_name=actions.runner.acme-widget.little-ci-acme-widget-studio-1.service
  create_removable_runner_fixture "$runner_home" "$runner_prefix-1" "$service_name"
  cat > "$runner_dir/config.sh" <<'MOCK'
#!/usr/bin/env bash
printf 'config-remove-called\n' >> "${MOCK_COMMAND_LOG:?}"
rm -f .runner
MOCK
  chmod +x "$runner_dir/config.sh"
  install_uninstall_resource_mocks

  local output status resume_output resume_status
  set +e
  output="$(
    cd "$sandbox_dir/repo" &&
      PATH="$sandbox_dir/bin:$PATH" \
      MOCK_COMMAND_LOG="$sandbox_dir/command.log" \
      MOCK_ALLOWED_RUNNER_DIR="$runner_dir" \
      MOCK_RUNNER_PREFIX="$runner_prefix" \
      MOCK_PENDING_RECORD_STORE="$sandbox_dir/pending-record" \
      MOCK_SWAPOFF_STATUS=1 \
      GITHUB_SCOPE=repository \
      GITHUB_URL=https://github.com/acme/widget \
      FLEET_ID=studio \
      REMOVETOKEN=unused-remove-token \
      RUNNER_HOME="$runner_home" \
      RUNNER_USER="$(id -un)" \
      ./uninstall-runners.sh --all --confirm 2>&1
  )"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'swapoff failure unexpectedly reported success'
  assert_contains "$output" 'protected cleanup record retained'
  assert_contains "$output" 'Recovery steps:'
  assert_file_contains "$sandbox_dir/command.log" "sudo swapoff /swapfile-$runner_prefix-1"
  assert_file_not_contains "$sandbox_dir/command.log" "sudo python3 - /swapfile-$runner_prefix-1"
  assert_file_not_contains "$sandbox_dir/command.log" "sudo rm -f -- /swapfile-$runner_prefix-1"
  assert_file_not_contains "$sandbox_dir/command.log" "sudo python3 - 1 /swapfile-$runner_prefix-1 /var/lib/little-ci/fleets/$runner_prefix/managed-swapfiles"
  [ -d "$runner_dir" ] || fail 'runner directory removed after incomplete swap cleanup'
  [ ! -e "$runner_dir/.runner" ] || fail 'successful config removal unexpectedly retained .runner'
  [ -f "$sandbox_dir/pending-record" ] || fail 'pending cleanup record was not retained after cleanup failure'
  assert_file_contains "$sandbox_dir/command.log" 'config-remove-called'

  set +e
  resume_output="$(
    cd "$sandbox_dir/repo" &&
      PATH="$sandbox_dir/bin:$PATH" \
      MOCK_COMMAND_LOG="$sandbox_dir/command.log" \
      MOCK_ALLOWED_RUNNER_DIR="$runner_dir" \
      MOCK_RUNNER_PREFIX="$runner_prefix" \
      MOCK_PENDING_RECORD_STORE="$sandbox_dir/pending-record" \
      GITHUB_SCOPE=repository \
      GITHUB_URL=https://github.com/acme/widget \
      FLEET_ID=studio \
      REMOVETOKEN=unused-remove-token \
      RUNNER_HOME="$runner_home" \
      RUNNER_USER="$(id -un)" \
      ./uninstall-runners.sh --all --confirm 2>&1
  )"
  resume_status=$?
  set -e
  assert_status 0 "$resume_status"
  assert_contains "$resume_output" 'Local removal complete: 1 removed, 0 failed.'
  [ ! -e "$runner_dir" ] || fail 'resume did not remove runner directory'
  [ ! -e "$sandbox_dir/pending-record" ] || fail 'resume did not remove pending cleanup record'
}

test_unregistration_failure_retains_metadata_and_pending_record() {
  new_sandbox
  local runner_home="$sandbox_dir/removal-home"
  mkdir -p "$runner_home"
  runner_home="$(cd "$runner_home" && pwd -P)"
  local runner_dir="$runner_home/actions-runner-1"
  local runner_prefix=little-ci-acme-widget-studio
  local service_name=actions.runner.acme-widget.little-ci-acme-widget-studio-1.service
  create_removable_runner_fixture "$runner_home" "$runner_prefix-1" "$service_name"
  cat > "$runner_dir/config.sh" <<'MOCK'
#!/usr/bin/env bash
printf 'config-remove-failed\n' >> "${MOCK_COMMAND_LOG:?}"
exit 1
MOCK
  chmod +x "$runner_dir/config.sh"
  install_uninstall_resource_mocks

  local output status
  set +e
  output="$(
    cd "$sandbox_dir/repo" &&
      PATH="$sandbox_dir/bin:$PATH" \
      MOCK_COMMAND_LOG="$sandbox_dir/command.log" \
      MOCK_ALLOWED_RUNNER_DIR="$runner_dir" \
      MOCK_RUNNER_PREFIX="$runner_prefix" \
      MOCK_PENDING_RECORD_STORE="$sandbox_dir/pending-record" \
      GITHUB_SCOPE=repository \
      GITHUB_URL=https://github.com/acme/widget \
      FLEET_ID=studio \
      REMOVETOKEN=unused-remove-token \
      RUNNER_HOME="$runner_home" \
      RUNNER_USER="$(id -un)" \
      ./uninstall-runners.sh --all --confirm 2>&1
  )"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'unregistration failure unexpectedly reported success'
  assert_contains "$output" 'protected cleanup record retained'
  assert_contains "$output" 'Recovery steps:'
  assert_file_order "$sandbox_dir/command.log" "/pending-cleanup/1 1 $runner_prefix-1" 'sudo ./svc.sh uninstall'
  assert_file_order "$sandbox_dir/command.log" 'sudo ./svc.sh uninstall' 'config-remove-failed'
  assert_file_not_contains "$sandbox_dir/command.log" "sudo rm -rf -- /scratch/$runner_prefix/1"
  [ -f "$runner_dir/.runner" ] || fail '.runner metadata was lost after unregistration failure'
  [ -f "$sandbox_dir/pending-record" ] || fail 'pending cleanup record was lost after unregistration failure'
  [ -d "$runner_dir" ] || fail 'runner directory was removed after unregistration failure'
}

run_case 'all shell files pass bash -n' test_bash_syntax
run_case 'root command scripts are executable' test_root_command_scripts_are_executable
run_case 'repository scope uses repository runner API' test_repository_api_routing
run_case 'organization scope uses organization runner API' test_organization_api_routing
run_case 'health check counts only its configured fleet' test_health_check_ignores_unrelated_runners
run_case 'health check requires stable configured and exact labels' test_health_check_requires_stable_configured_and_exact_labels
run_case 'fleet IDs derive distinct lowercase runner prefixes' test_fleet_ids_derive_distinct_lowercase_prefixes
run_case 'missing and uppercase fleet IDs are rejected' test_missing_or_uppercase_fleet_id_is_rejected
run_case 'organization scope requires a runner group' test_organization_scope_requires_runner_group
run_case 'runner labels reject empty and overlength values' test_runner_labels_reject_empty_entries_and_overlength_values
run_case 'runner label allows exact 256-character boundary' test_runner_label_allows_exact_256_character_boundary
run_case 'generated runner labels respect GitHub length limit' test_generated_runner_labels_respect_github_length_limit
run_case 'OrbStack provisioning rejects Intel Macs' test_orbstack_rejects_intel_mac
run_case 'OrbStack provisioning rejects root runner before mutation' test_orbstack_provisioning_rejects_root_runner_before_mutation
run_case 'generic install rejects root runner before mutation' test_generic_install_rejects_root_runner_before_mutation
run_case 'generic install rejects mismatched non-root account before token' test_generic_install_rejects_mismatched_nonroot_account_before_token
run_case 'new OrbStack machine uses secure Apple Silicon defaults' test_orbstack_creation_uses_secure_arm_defaults
run_case 'existing OrbStack machine is rejected before start when incompatible' test_existing_orbstack_machine_is_validated_before_start
run_case 'compatible existing OrbStack machine reaches start' test_compatible_orbstack_machine_reaches_start
run_case 'existing OrbStack identity mismatch blocks package mutation' test_existing_orbstack_identity_mismatch_blocks_package_mutation
run_case 'new OrbStack machine installs needrestart runner policy' test_new_orbstack_machine_installs_needrestart_runner_policy
run_case 'OrbStack guests skip Linux swapfile commands' test_orbstack_guest_skips_swapfile_commands
run_case 'existing runner metadata accepts GitHub UTF-8 BOM' test_existing_runner_accepts_utf8_bom
run_case 'existing service receives exact fleet scratch drop-in' test_existing_service_gets_exact_fleet_scratch_drop_in
run_case 'active service rejects missing scratch drop-in' test_active_service_drop_in_drift_is_rejected missing
run_case 'active service rejects changed scratch drop-in' test_active_service_drop_in_drift_is_rejected changed
run_case 'service drop-in directory symlink is rejected before write' test_service_drop_in_symlink_is_rejected_before_write dir
run_case 'service drop-in file symlink is rejected before write' test_service_drop_in_symlink_is_rejected_before_write file
run_case 'inactive service repairs scratch drop-in before start' test_inactive_service_repairs_scratch_drop_in_then_starts
run_case 'mismatched service unit blocks scratch and start' test_mismatched_service_unit_blocks_scratch_and_start
run_case 'legacy OrbStack swapfile cleanup is opt in' test_legacy_swapfile_cleanup_is_opt_in
run_case 'swap manifest records exact owned path and requires root-restricted state' test_swap_manifest_records_exact_owned_path_and_rejects_unsafe_permissions
run_case 'config.env rejects persisted tokens without leaking them' test_config_file_rejects_persisted_tokens_without_leaking_value
run_case 'doctor reports missing configured runner label' test_doctor_reports_missing_configured_runner_label
run_case 'doctor requires exact runner-name and arm64 labels' test_doctor_requires_exact_runner_name_and_arm64_labels
run_case 'doctor always requires stable little-ci label' test_doctor_always_requires_stable_little_ci_label
run_case 'OrbStack uninstall forwards remove token and deletes only matching stale runner' test_orbstack_uninstall_forwards_remove_token_and_cleans_matching_stale_runner
run_case 'OrbStack machine deletion requires all mode' test_machine_deletion_requires_all_mode
run_case 'OrbStack uninstall rejects markerless machine before GitHub' test_orbstack_uninstall_rejects_markerless_machine_before_github
run_case 'OrbStack uninstall rejects mismatched identity before GitHub' test_orbstack_uninstall_rejects_mismatched_identity_before_github
run_case 'OrbStack uninstall reports recovery after guest failure without deleting' test_orbstack_uninstall_guest_failure_reports_recovery_without_deleting
run_case 'OrbStack uninstall allows safe resource drift' test_orbstack_uninstall_allows_safe_resource_drift
run_case 'stale runner API read failure reports recovery without machine deletion' test_stale_runner_api_read_failure_reports_recovery_without_machine_delete
run_case 'stale runner DELETE failure reports recovery without machine deletion' test_stale_runner_delete_failure_reports_recovery_without_machine_delete
run_case 'malformed guest runner metadata blocks stale and machine deletion' test_malformed_guest_runner_metadata_blocks_stale_and_machine_deletion
run_case 'organization runner group reaches GitHub registration command' test_organization_runner_group_reaches_registration_command
run_case 'OrbStack install fetches registration token and installs services as root' test_orbstack_install_fetches_registration_token_and_splits_service_install
run_case 'OrbStack install rejects mismatched identity before token' test_orbstack_install_rejects_mismatched_machine_identity_before_token
run_case 'OrbStack install rejects guest UID 0 before token' test_orbstack_install_rejects_root_effective_guest_user_before_token
run_case 'OrbStack install rejects Mac mounts before start' test_orbstack_install_rejects_mac_mount_before_start
run_case 'OrbStack install rejects unverifiable mount configuration' test_orbstack_install_rejects_mac_mount_before_start '' 72 'could not verify configured mounts'
run_case 'OrbStack transfers use an explicit file allowlist' test_orbstack_transfers_use_explicit_allowlist
run_case 'local uninstall unregisters and removes the selected runner' test_local_uninstall_uses_remove_token_and_deletes_selected_runner
run_case 'local uninstall rejects RUNNER_HOME=/ before commands' test_local_uninstall_rejects_root_runner_home_before_commands
run_case 'unselected malformed runner does not block exact removal' test_unselected_malformed_runner_does_not_block_removal_mode runner
run_case 'unselected malformed runner does not block prune' test_unselected_malformed_runner_does_not_block_removal_mode prune
run_case 'selected malformed runner fails closed' test_selected_malformed_runner_fails_closed
run_case 'local uninstall removes only owned service scratch and swap artifacts' test_local_uninstall_removes_only_owned_service_scratch_and_swap_artifacts
run_case 'local uninstall rejects unrelated service before mutation' test_local_uninstall_service_mismatch_performs_no_mutation
run_case 'local uninstall retains runner and manifest state after swap failure' test_local_uninstall_swap_failure_retains_runner_and_manifest_state
run_case 'unregistration failure retains metadata and pending cleanup record' test_unregistration_failure_retains_metadata_and_pending_record

printf '\n%d tests, %d failures\n' "$test_count" "$failure_count"
[ "$failure_count" -eq 0 ]
