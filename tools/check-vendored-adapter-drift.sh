#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tools/lib.sh"

TARGET="${1:?usage: check-vendored-adapter-drift.sh <target>}"

PIN_FILE="${ROOT}/vendor/${TARGET}.upstream.env"
[[ -f "${PIN_FILE}" ]] || die "missing pin file: ${PIN_FILE}"

# shellcheck disable=SC1090
source "${PIN_FILE}"

[[ "${TARGET_ID:-}" == "${TARGET}" ]] \
  || die "TARGET_ID mismatch: expected ${TARGET}, got ${TARGET_ID:-missing}"
[[ "${SOURCE_REVISION:-}" =~ ^[0-9a-f]{40}$ ]] \
  || die "SOURCE_REVISION must be a 40-hex commit SHA in ${PIN_FILE}"
[[ -n "${SOURCE_REPO:-}" ]] \
  || die "SOURCE_REPO not set in ${PIN_FILE}"

need_cmd curl
need_cmd diff

# Normalize SOURCE_REPO to owner/repo slug for raw.githubusercontent.com.
# vendor-adapter.sh records the remote URL which may be HTTPS or SSH.
case "${SOURCE_REPO}" in
  https://github.com/*) REPO_SLUG="${SOURCE_REPO#https://github.com/}" ;;
  git@github.com:*)     REPO_SLUG="${SOURCE_REPO#git@github.com:}" ;;
  *)                    die "SOURCE_REPO must be a GitHub URL: ${SOURCE_REPO}" ;;
esac
REPO_SLUG="${REPO_SLUG%.git}"

BASE_URL="https://raw.githubusercontent.com/${REPO_SLUG}/${SOURCE_REVISION}"

# Map upstream paths to local vendored paths — mirrors vendor-adapter.sh.
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

DRIFT=0
for i in "${!UPSTREAM_PATHS[@]}"; do
  upstream_path="${UPSTREAM_PATHS[$i]}"
  local_name="${LOCAL_NAMES[$i]}"
  local_file="${ROOT}/vendor/${TARGET}/${local_name}"
  upstream_file="${TMP}/${local_name}"
  url="${BASE_URL}/${upstream_path}"

  [[ -f "${local_file}" ]] \
    || die "vendored file missing: ${local_file}"

  log "Fetching ${url}"
  curl -fsSL "${url}" -o "${upstream_file}" \
    || die "failed to fetch ${url}"

  if ! diff -u "${upstream_file}" "${local_file}"; then
    log "DRIFT: ${local_name} differs from ${REPO_SLUG}@${SOURCE_REVISION}"
    DRIFT=1
  fi
done

[[ "${DRIFT}" -eq 0 ]] \
  || die "vendored ${TARGET} adapter has drifted from ${REPO_SLUG}@${SOURCE_REVISION}"

log "Vendored ${TARGET} adapter matches ${REPO_SLUG}@${SOURCE_REVISION}"
