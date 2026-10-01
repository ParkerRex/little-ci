#!/usr/bin/env bash
# provision-job-dependencies.sh — install Ubuntu packages trusted CI jobs expect.
#
# Installs ffmpeg, ripgrep, and the exact Ubuntu packages that Playwright's
# `playwright install-deps chromium` installs, so jobs can launch a Chromium they
# download themselves. It does not download browsers, Node.js, Bun, or
# Playwright, and it changes no runner, service, or fleet state.
#
# Safe to re-run: when every package is already installed it verifies the tools
# without contacting apt. Run as root on an Ubuntu 24.04 arm64 or amd64 host:
#     sudo ./provision-job-dependencies.sh
# provision-orbstack.sh runs it inside the OrbStack guest automatically.

set -euo pipefail

# Load the owning checkout's trusted config.env (never the caller's cwd) before
# defining anything below, so it cannot replace the fixed package lists or the
# functions that install them. This script reads no settings from it.
script_dir="$(cd "$(dirname "$0")" && pwd)"
[ -f "$script_dir/lib/github-target.sh" ] || {
  echo "missing $script_dir/lib/github-target.sh" >&2
  exit 1
}
. "$script_dir/lib/github-target.sh"
reject_persisted_github_credentials "$script_dir/config.env"
[ ! -f "$script_dir/config.env" ] || . "$script_dir/config.env"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

# ffmpeg and ripgrep are in Ubuntu's universe component.
job_tool_packages=(ffmpeg ripgrep)

# Playwright v1.59.1 `install-deps chromium` for ubuntu24.04-x64 and
# ubuntu24.04-arm64 (identical lists): the chromium group plus the tools group
# that install-deps always adds. Refresh both lists together from
# https://github.com/microsoft/playwright/blob/v1.59.1/packages/playwright-core/src/server/registry/nativeDeps.ts
# when consuming projects move to a Playwright release that changes them.
playwright_chromium_packages=(
  libasound2t64 libatk-bridge2.0-0t64 libatk1.0-0t64 libatspi2.0-0t64 libcairo2
  libcups2t64 libdbus-1-3 libdrm2 libgbm1 libglib2.0-0t64 libnspr4 libnss3
  libpango-1.0-0 libx11-6 libxcb1 libxcomposite1 libxdamage1 libxext6
  libxfixes3 libxkbcommon0 libxrandr2
)
playwright_tools_packages=(
  xvfb fonts-noto-color-emoji fonts-unifont libfontconfig1 libfreetype6
  xfonts-cyrillic xfonts-scalable fonts-liberation fonts-ipafont-gothic
  fonts-wqy-zenhei fonts-tlwg-loma-otf fonts-freefont-ttf
)
readonly job_tool_packages playwright_chromium_packages playwright_tools_packages

require_supported_host() {
  local os_release_file distribution_id distribution_version package_architecture
  os_release_file="${LITTLE_CI_OS_RELEASE_FILE:-/etc/os-release}"

  [ "$(id -u)" -eq 0 ] || fail "provision-job-dependencies.sh must run as root"
  [ -r "$os_release_file" ] || fail "cannot read $os_release_file"
  # os-release is a root-owned shell fragment; read it in subshells only.
  # shellcheck source=/dev/null
  distribution_id="$(. "$os_release_file" && printf '%s' "${ID:-}")"
  # shellcheck source=/dev/null
  distribution_version="$(. "$os_release_file" && printf '%s' "${VERSION_ID:-}")"
  if [ "$distribution_id" != ubuntu ] || [ "$distribution_version" != 24.04 ]; then
    fail "CI job dependency provisioning requires Ubuntu 24.04 (found ${distribution_id:-unknown} ${distribution_version:-unknown}); the Playwright package list is release-specific"
  fi
  package_architecture="$(dpkg --print-architecture)"
  case "$package_architecture" in
    arm64|amd64) ;;
    *) fail "CI job dependencies support arm64 or amd64 only (found $package_architecture)" ;;
  esac
}

package_is_installed() {
  [ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null)" = installed ]
}

list_missing_packages() {
  local package_name
  for package_name in "$@"; do
    package_is_installed "$package_name" || printf '%s\n' "$package_name"
  done
}

# Package maintenance must not restart a runner mid-job. provision-orbstack.sh
# writes the same policy before its base packages; generic hosts get it here.
install_needrestart_runner_policy() {
  local needrestart_conf_dir
  needrestart_conf_dir="${LITTLE_CI_NEEDRESTART_CONF_DIR:-/etc/needrestart/conf.d}"
  install -d -m 755 "$needrestart_conf_dir"
  cat > "$needrestart_conf_dir/actions_runner_services.conf" <<'NEEDRESTART'
$nrconf{override_rc}{qr(^actions\.runner\..+\.service$)} = 0;
NEEDRESTART
}

main() {
  local required_packages missing_packages remaining_packages ffmpeg_version
  local ripgrep_version
  required_packages=(
    "${job_tool_packages[@]}"
    "${playwright_chromium_packages[@]}"
    "${playwright_tools_packages[@]}"
  )

  require_supported_host
  install_needrestart_runner_policy

  mapfile -t missing_packages < <(list_missing_packages "${required_packages[@]}")
  if [ "${#missing_packages[@]}" -eq 0 ]; then
    echo "== CI job dependencies already installed =="
  else
    echo "== installing ${#missing_packages[@]} CI job dependency package(s) =="
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends "${missing_packages[@]}"
    mapfile -t remaining_packages < <(list_missing_packages "${required_packages[@]}")
    [ "${#remaining_packages[@]}" -eq 0 ] || \
      fail "packages still missing after apt-get install: ${remaining_packages[*]}"
  fi

  # Capture instead of piping to head so pipefail cannot trip on SIGPIPE.
  ffmpeg_version="$(ffmpeg -version)" || fail "ffmpeg is installed but does not run"
  ripgrep_version="$(rg --version)" || fail "rg is installed but does not run"
  printf '%s\n%s\n' "${ffmpeg_version%%$'\n'*}" "${ripgrep_version%%$'\n'*}"
  echo "== CI job dependencies ready =="
}

main "$@"
