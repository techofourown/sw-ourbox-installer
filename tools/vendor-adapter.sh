#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tools/lib.sh"

TARGET="${1:-woodbox}"
SOURCE_REPO="${2:-/techofourown/img-ourbox-woodbox}"

case "${TARGET}" in
  woodbox) : ;;
  *) die "unsupported adapter target: ${TARGET}" ;;
esac

[[ -d "${SOURCE_REPO}" ]] || die "source repo not found: ${SOURCE_REPO}"

SOURCE_REVISION="$(git -C "${SOURCE_REPO}" rev-parse HEAD 2>/dev/null || echo unknown)"
[[ -z "$(git -C "${SOURCE_REPO}" status --short 2>/dev/null || true)" ]] \
  || die "source repo must be clean before vendoring: ${SOURCE_REPO}"
SOURCE_REMOTE="$(git -C "${SOURCE_REPO}" remote get-url github 2>/dev/null || printf '%s\n' "${SOURCE_REPO}")"
DEST_DIR="${ROOT}/vendor/${TARGET}"

mkdir -p "${DEST_DIR}"
cp -f "${SOURCE_REPO}/tools/media-adapter/adapter.json" "${DEST_DIR}/adapter.json"
cp -f "${SOURCE_REPO}/tools/media-adapter/compose-media.sh" "${DEST_DIR}/compose-media.sh"
cp -f "${SOURCE_REPO}/tools/media-adapter/validate-media.sh" "${DEST_DIR}/validate-media.sh"
cp -f "${SOURCE_REPO}/tools/strict-kv-metadata.py" "${DEST_DIR}/strict-kv-metadata.py"

cat > "${ROOT}/vendor/${TARGET}.upstream.env" <<EOF
TARGET_ID=${TARGET}
SOURCE_REPO=${SOURCE_REMOTE}
SOURCE_REVISION=${SOURCE_REVISION}
SYNCED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

log "Vendored ${TARGET} adapter from ${SOURCE_REPO} (${SOURCE_REVISION})"
