#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tools/lib.sh"

PIN_FILE="${ROOT}/vendor/woodbox.upstream.env"
[[ -f "${PIN_FILE}" ]] || die "missing vendored woodbox pin file: ${PIN_FILE}"

# shellcheck disable=SC1090
source "${PIN_FILE}"

[[ "${TARGET_ID:-}" == "woodbox" ]] || die "unexpected TARGET_ID in ${PIN_FILE}: ${TARGET_ID:-missing}"
[[ -n "${SOURCE_REPO:-}" ]] || die "missing SOURCE_REPO in ${PIN_FILE}"
[[ "${SOURCE_REVISION:-}" =~ ^[0-9a-f]{40}$ ]] || die "SOURCE_REVISION must be a clean 40-hex commit in ${PIN_FILE}"
[[ "${SYNCED_AT:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]] || die "SYNCED_AT must be set in ${PIN_FILE}"

printf '[%s] vendored woodbox pin check passed\n' "$(date -Is)"
