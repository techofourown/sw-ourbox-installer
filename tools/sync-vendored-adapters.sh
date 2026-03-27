#!/usr/bin/env bash
# Sync vendored adapter files from img-ourbox-woodbox and img-ourbox-matchbox
# to the latest main HEAD of each upstream repo.
#
# For each target, resolves the current main HEAD, fetches the 6 vendored
# files, and overwrites the local copies + pin file if the revision changed.
#
# Usage:
#   bash tools/sync-vendored-adapters.sh           # apply updates
#   bash tools/sync-vendored-adapters.sh --dry-run # report only, no changes
#
# Sets VENDORED_ADAPTERS_CHANGED=1 in GITHUB_ENV when running inside GitHub
# Actions and at least one adapter was updated.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tools/lib.sh"

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

need_cmd curl
need_cmd python3

UPSTREAM_PATHS=(
  "tools/media-adapter/adapter.json"
  "tools/media-adapter/compose-media.sh"
  "tools/media-adapter/validate-media.sh"
  "tools/lib.sh"
  "tools/flash-installer-media.sh"
  "tools/strict-kv-metadata.py"
)
LOCAL_NAMES=(
  "adapter.json"
  "compose-media.sh"
  "validate-media.sh"
  "lib.sh"
  "flash-installer-media.sh"
  "strict-kv-metadata.py"
)

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

CHANGED=0

for target_dir in "${ROOT}"/vendor/*.upstream.env; do
  [[ -f "${target_dir}" ]] || continue
  pin_file="${target_dir}"

  # shellcheck disable=SC1090
  source "${pin_file}"
  target="${TARGET_ID:?missing TARGET_ID in ${pin_file}}"

  # Normalize SOURCE_REPO to owner/repo slug.
  # vendor-adapter.sh records the remote URL which may be HTTPS or SSH.
  case "${SOURCE_REPO}" in
    https://github.com/*) repo_slug="${SOURCE_REPO#https://github.com/}" ;;
    git@github.com:*)     repo_slug="${SOURCE_REPO#git@github.com:}" ;;
    *)                    die "SOURCE_REPO must be a GitHub URL: ${SOURCE_REPO}" ;;
  esac
  repo_slug="${repo_slug%.git}"

  # Resolve latest main HEAD via the GitHub API.
  LATEST_SHA="$(curl -fsSL \
    -H "Accept: application/vnd.github.v3+json" \
    "https://api.github.com/repos/${repo_slug}/git/refs/heads/main" \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['object']['sha'])")" \
    || die "failed to resolve main HEAD for ${repo_slug}"

  if [[ "${SOURCE_REVISION}" == "${LATEST_SHA}" ]]; then
    log "${target}: already at ${LATEST_SHA:0:12}"
    continue
  fi

  log "${target}: ${SOURCE_REVISION:0:12} -> ${LATEST_SHA:0:12}"

  if [[ "${DRY_RUN}" == "0" ]]; then
    for i in "${!UPSTREAM_PATHS[@]}"; do
      upstream_path="${UPSTREAM_PATHS[$i]}"
      local_name="${LOCAL_NAMES[$i]}"
      url="https://raw.githubusercontent.com/${repo_slug}/${LATEST_SHA}/${upstream_path}"
      dest="${ROOT}/vendor/${target}/${local_name}"
      log "  Fetching ${local_name}"
      curl -fsSL "${url}" -o "${dest}" || die "failed to fetch ${url}"
    done

    cat > "${pin_file}" <<EOF
TARGET_ID=${target}
SOURCE_REPO=${SOURCE_REPO}
SOURCE_REVISION=${LATEST_SHA}
SYNCED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
  fi

  CHANGED=1
done

if [[ "${CHANGED}" == "1" ]]; then
  log "Sync complete: one or more adapters updated"
  if [[ -n "${GITHUB_ENV:-}" ]]; then
    echo "VENDORED_ADAPTERS_CHANGED=1" >> "${GITHUB_ENV}"
  fi
else
  log "Sync complete: all adapters up to date"
fi
