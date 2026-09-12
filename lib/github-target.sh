#!/usr/bin/env bash

reject_persisted_github_credentials() {
  local config_file="$1"

  [ ! -f "$config_file" ] || ! grep -Eq \
    '^[[:space:]]*(export[[:space:]]+)?(REGTOKEN|REMOVETOKEN|GH_TOKEN|GITHUB_TOKEN)[[:space:]]*=' \
    "$config_file" || {
      echo "config.env must not contain GitHub credentials; pass them through the environment" >&2
      return 1
    }
}

# Validate the configured GitHub scope and expose its REST API target.
# Call after loading config.env.
github_target_init() {
  GITHUB_SCOPE="${GITHUB_SCOPE:-repository}"

  case "$GITHUB_SCOPE" in
    repository|organization) ;;
    *)
      echo "GITHUB_SCOPE must be 'repository' or 'organization' (got '$GITHUB_SCOPE')" >&2
      return 1
      ;;
  esac

  if [ -z "${GITHUB_URL:-}" ]; then
    echo "GITHUB_URL is required" >&2
    return 1
  fi

  GITHUB_URL="${GITHUB_URL%/}"
  case "$GITHUB_SCOPE" in
    repository)
      if [[ ! "$GITHUB_URL" =~ ^https://github\.com/([A-Za-z0-9][A-Za-z0-9-]*)/([A-Za-z0-9._-]+)$ ]]; then
        echo "GITHUB_URL must be https://github.com/OWNER/REPO when GITHUB_SCOPE=repository" >&2
        return 1
      fi
      GITHUB_TARGET="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
      GITHUB_API_TARGET="/repos/$GITHUB_TARGET"
      ;;
    organization)
      if [[ ! "$GITHUB_URL" =~ ^https://github\.com/([A-Za-z0-9][A-Za-z0-9-]*)$ ]]; then
        echo "GITHUB_URL must be https://github.com/ORGANIZATION when GITHUB_SCOPE=organization" >&2
        return 1
      fi
      GITHUB_TARGET="${BASH_REMATCH[1]}"
      GITHUB_API_TARGET="/orgs/$GITHUB_TARGET"
      ;;
  esac

  if [ "$GITHUB_SCOPE" = repository ] && [ -n "${RUNNER_GROUP:-}" ]; then
    echo "RUNNER_GROUP is only supported when GITHUB_SCOPE=organization" >&2
    return 1
  fi
}
