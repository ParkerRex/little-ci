#!/usr/bin/env bash
# check-runners.sh — health check: how many self-hosted runners are ONLINE.
#   exit 0  GREEN — >= EXPECTED_RUNNERS online
#   exit 1  RED   — fewer than expected online (a dropped runner silently slows CI)
#   exit 2  DARK  — could not read the runners API (gh not authed / no GH_TOKEN)
#
# Needs the gh CLI authenticated with admin access to the repo/org, OR a PAT in
# GH_TOKEN with the `manage_runners` / repo-admin scope. Reads no secrets of its own.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
[ -f "$here/config.env" ] && . "$here/config.env"

GITHUB_URL="${GITHUB_URL:?set GITHUB_URL in config.env}"
EXPECTED="${EXPECTED_RUNNERS:-${RUNNER_COUNT:-3}}"
slug="${GITHUB_URL#https://github.com/}"; slug="${slug%/}"

json="$(gh api "/repos/$slug/actions/runners" 2>/dev/null || true)"
if [ -z "$json" ]; then
  echo "check-runners = DARK — could not read runners API for $slug (gh auth / GH_TOKEN?)"
  exit 2
fi

out="$(printf '%s' "$json" | python3 - "$EXPECTED" <<'PY'
import sys, json
expected = int(sys.argv[1])
rs = json.load(sys.stdin).get("runners", [])
online = sum(1 for r in rs if r.get("status") == "online")
detail = " | ".join(
    "%s=%s%s" % (r["name"], r["status"], "(busy)" if r.get("busy") else "") for r in rs
)
print("%s|%d|%d|%s" % ("GREEN" if online >= expected else "RED", online, len(rs), detail))
PY
)"

verdict="${out%%|*}"; rest="${out#*|}"
online="${rest%%|*}"; rest="${rest#*|}"
total="${rest%%|*}"; detail="${rest#*|}"

if [ "$verdict" = GREEN ]; then
  echo "check-runners = GREEN — $online/$total online (expected $EXPECTED)  [$detail]"
  exit 0
fi
echo "check-runners = RED — only $online/$total online (expected $EXPECTED)  [$detail]"
echo "  FIX (on the box): sudo systemctl enable --now '<runner-service>.service'"
echo "  list services:    systemctl list-units 'actions.runner.*' --type=service"
exit 1
