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

  case "$GITHUB_SCOPE" in
    repository)
      if [ -n "${RUNNER_GROUP:-}" ]; then
        echo "RUNNER_GROUP is only supported when GITHUB_SCOPE=organization" >&2
        return 1
      fi
      ;;
    organization)
      if [[ ! "${RUNNER_GROUP:-}" =~ [^[:space:]] ]]; then
        echo "RUNNER_GROUP is required when GITHUB_SCOPE=organization" >&2
        return 1
      fi
      ;;
  esac
}

# Resolve one collision-resistant fleet prefix shared by every script. A manual
# prefix remains available for existing installations and advanced operators.
github_fleet_init() {
  local normalized_github_target

  if [ -z "${GITHUB_TARGET:-}" ]; then
    echo "github_target_init must run before github_fleet_init" >&2
    return 1
  fi

  if [ -n "${RUNNER_NAME_PREFIX:-}" ]; then
    [[ "$RUNNER_NAME_PREFIX" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
      echo "RUNNER_NAME_PREFIX may contain only letters, numbers, dots, underscores, and hyphens" >&2
      return 1
    }
    github_validate_runner_label "$RUNNER_NAME_PREFIX" "RUNNER_NAME_PREFIX"
    return
  fi

  if [ -z "${FLEET_ID:-}" ]; then
    echo "FLEET_ID is required when RUNNER_NAME_PREFIX is unset" >&2
    return 1
  fi
  [[ "$FLEET_ID" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || {
    echo "FLEET_ID may contain only lowercase letters, numbers, dots, underscores, and hyphens" >&2
    return 1
  }

  command -v tr >/dev/null || {
    echo "tr is required to derive RUNNER_NAME_PREFIX" >&2
    return 1
  }
  normalized_github_target="$(printf '%s' "$GITHUB_TARGET" | tr '[:upper:]' '[:lower:]')" || return 1
  RUNNER_NAME_PREFIX="little-ci-${normalized_github_target//\//-}-${FLEET_ID}"

  github_validate_runner_label "$RUNNER_NAME_PREFIX" "RUNNER_NAME_PREFIX"
}

github_validate_runner_label() {
  local runner_label="$1"
  local label_source="$2"
  local LC_ALL=C

  [ -n "$runner_label" ] || {
    echo "$label_source must not contain an empty label" >&2
    return 1
  }
  [ "${#runner_label}" -le 256 ] || {
    echo "$label_source labels must not exceed 256 characters" >&2
    return 1
  }
  [[ "$runner_label" != [[:space:]]* && "$runner_label" != *[[:space:]] ]] || {
    echo "$label_source labels must not have leading or trailing whitespace" >&2
    return 1
  }
  [[ "$runner_label" != *[![:print:]]* ]] || {
    echo "$label_source labels must contain only printable characters" >&2
    return 1
  }
}

github_validate_runner_labels() {
  local runner_labels="$1"
  local label_source="$2"
  local runner_label
  local -a parsed_labels

  IFS=',' read -r -a parsed_labels <<< "$runner_labels"
  [ "${#parsed_labels[@]}" -gt 0 ] || {
    echo "$label_source must contain at least one label" >&2
    return 1
  }
  case "$runner_labels" in
    ,*|*,|*,,*)
      echo "$label_source must not contain empty comma-separated labels" >&2
      return 1
      ;;
  esac
  for runner_label in "${parsed_labels[@]}"; do
    github_validate_runner_label "$runner_label" "$label_source" || return 1
  done
}
