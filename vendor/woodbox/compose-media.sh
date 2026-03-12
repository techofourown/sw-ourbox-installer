#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${WOODBOX_ADAPTER_ROOT:=${SCRIPT_DIR}}"
: "${WOODBOX_REPO_ROOT:=$(cd "${SCRIPT_DIR}/../.." && pwd)}"
ROOT="${WOODBOX_REPO_ROOT}"
# shellcheck disable=SC1091
source "${ROOT}/tools/lib.sh"

MISSION_DIR=""
OS_PAYLOAD=""
OUTPUT_DIR=""
FLASH_DEVICE=""

usage() {
  cat <<EOF
Usage: $0 --mission-dir DIR --os-payload PATH [--output-dir DIR] [--flash-device DEV]

Phase-one Woodbox media composition:
- validates a prepared mission directory
- builds Woodbox mission media by embedding the selected OS payload
- embeds the mission directory into /cdrom/ourbox/mission/
- optionally flashes the resulting ISO to removable media
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mission-dir)
      [[ $# -ge 2 ]] || die "--mission-dir requires a value"
      MISSION_DIR="$2"
      shift 2
      ;;
    --os-payload)
      [[ $# -ge 2 ]] || die "--os-payload requires a value"
      OS_PAYLOAD="$2"
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || die "--output-dir requires a value"
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --flash-device)
      [[ $# -ge 2 ]] || die "--flash-device requires a value"
      FLASH_DEVICE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n "${MISSION_DIR}" ]] || die "--mission-dir is required"
[[ -n "${OS_PAYLOAD}" ]] || die "--os-payload is required"

bash "${WOODBOX_ADAPTER_ROOT}/validate-media.sh" \
  --mission-dir "${MISSION_DIR}" \
  --os-payload "${OS_PAYLOAD}"

PAYLOAD_META="${OS_PAYLOAD%.tar.gz}.meta.env"
if [[ -f "${PAYLOAD_META}" ]]; then
  # shellcheck disable=SC1090
  source "${PAYLOAD_META}"
fi

: "${OURBOX_PRODUCT:=ourbox}"
: "${OURBOX_DEVICE:=woodbox}"
: "${OURBOX_TARGET:=x86}"
: "${OURBOX_SKU:=TOO-OBX-WBX-BASE-JU3XK8}"
: "${OURBOX_VARIANT:=prod}"
: "${OURBOX_VERSION:=host-compose}"

OURBOX_TARGET_SLUG="$(echo "${OURBOX_TARGET}" | tr '[:upper:]' '[:lower:]')"
OURBOX_SKU_SLUG="$(echo "${OURBOX_SKU}" | tr '[:upper:]' '[:lower:]')"
OURBOX_VARIANT_SLUG="$(echo "${OURBOX_VARIANT}" | tr '[:upper:]' '[:lower:]')"
OUT_ISO="${ROOT}/deploy/installer-${OURBOX_PRODUCT}-${OURBOX_DEVICE}-${OURBOX_TARGET_SLUG}-${OURBOX_SKU_SLUG}-${OURBOX_VARIANT_SLUG}-${OURBOX_VERSION}.iso"
OUT_SHA="${OUT_ISO}.sha256"

log "Composing Woodbox mission media"
OURBOX_PRODUCT="${OURBOX_PRODUCT}" \
OURBOX_DEVICE="${OURBOX_DEVICE}" \
OURBOX_TARGET="${OURBOX_TARGET}" \
OURBOX_SKU="${OURBOX_SKU}" \
OURBOX_VARIANT="${OURBOX_VARIANT}" \
OURBOX_VERSION="${OURBOX_VERSION}" \
  "${ROOT}/tools/build-installer-iso.sh" \
    --embed-payload "${OS_PAYLOAD}" \
    --embed-mission-dir "${MISSION_DIR}"

[[ -f "${OUT_ISO}" ]] || die "expected composed ISO not found: ${OUT_ISO}"
[[ -f "${OUT_SHA}" ]] || die "expected composed ISO checksum not found: ${OUT_SHA}"

if [[ -n "${OUTPUT_DIR}" ]]; then
  mkdir -p "${OUTPUT_DIR}"
  cp -f "${OUT_ISO}" "${OUTPUT_DIR}/"
  cp -f "${OUT_SHA}" "${OUTPUT_DIR}/"
  OUT_ISO="${OUTPUT_DIR}/$(basename "${OUT_ISO}")"
  OUT_SHA="${OUTPUT_DIR}/$(basename "${OUT_SHA}")"
fi

if [[ -n "${FLASH_DEVICE}" ]]; then
  "${ROOT}/tools/flash-installer-media.sh" "${OUT_ISO}" "${FLASH_DEVICE}"
fi

log "Woodbox mission media ready: ${OUT_ISO}"
log "Checksum file: ${OUT_SHA}"
