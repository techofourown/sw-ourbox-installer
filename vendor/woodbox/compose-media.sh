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
OS_META_ENV=""
OUTPUT_DIR=""
FLASH_DEVICE=""

usage() {
  cat <<EOF
Usage: $0 --mission-dir DIR --os-payload PATH --os-meta-env PATH [--output-dir DIR] [--flash-device DEV]

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
    --os-meta-env)
      [[ $# -ge 2 ]] || die "--os-meta-env requires a value"
      OS_META_ENV="$2"
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
[[ -n "${OS_META_ENV}" ]] || die "--os-meta-env is required"

bash "${WOODBOX_ADAPTER_ROOT}/validate-media.sh" \
  --mission-dir "${MISSION_DIR}" \
  --os-payload "${OS_PAYLOAD}" \
  --os-meta-env "${OS_META_ENV}"

STRICT_METADATA_PARSER="${WOODBOX_ADAPTER_ROOT}/strict-kv-metadata.py"
if [[ ! -f "${STRICT_METADATA_PARSER}" ]]; then
  STRICT_METADATA_PARSER="${ROOT}/tools/strict-kv-metadata.py"
fi
[[ -f "${STRICT_METADATA_PARSER}" ]] || die "strict metadata parser not found: ${STRICT_METADATA_PARSER}"

payload_meta_dump="$(
  python3 "${STRICT_METADATA_PARSER}" "${OS_META_ENV}" \
    --allow OS_PAYLOAD_BASENAME \
    --allow OS_PAYLOAD_SHA256 \
    --allow OS_PAYLOAD_SIZE_BYTES \
    --allow OS_ARTIFACT_TYPE \
    --allow OURBOX_PRODUCT \
    --allow OURBOX_DEVICE \
    --allow OURBOX_TARGET \
    --allow OURBOX_SKU \
    --allow OURBOX_VARIANT \
    --allow OURBOX_VERSION \
    --allow OURBOX_RECIPE_GIT_HASH \
    --allow BUILD_TS \
    --allow GIT_SHA \
    --allow OURBOX_PLATFORM_CONTRACT_SOURCE \
    --allow OURBOX_PLATFORM_CONTRACT_REVISION \
    --allow OURBOX_PLATFORM_CONTRACT_VERSION \
    --allow OURBOX_PLATFORM_CONTRACT_DIGEST \
    --allow OURBOX_AIRGAP_PLATFORM_REF \
    --allow OURBOX_AIRGAP_PLATFORM_DIGEST \
    --allow OURBOX_AIRGAP_PLATFORM_SOURCE \
    --allow OURBOX_AIRGAP_PLATFORM_REVISION \
    --allow OURBOX_AIRGAP_PLATFORM_VERSION \
    --allow OURBOX_AIRGAP_PLATFORM_CREATED \
    --allow OURBOX_AIRGAP_PLATFORM_ARCH \
    --allow OURBOX_AIRGAP_PLATFORM_PROFILE \
    --allow OURBOX_AIRGAP_PLATFORM_K3S_VERSION \
    --allow OURBOX_AIRGAP_PLATFORM_IMAGES_LOCK_SHA256 \
    --allow OURBOX_BASE_ISO_URL \
    --allow OURBOX_BASE_ISO_SHA256 \
    --allow K3S_VERSION \
    --allow GITHUB_RUN_ID \
    --allow GITHUB_RUN_ATTEMPT \
    --print OURBOX_PRODUCT \
    --print OURBOX_DEVICE \
    --print OURBOX_TARGET \
    --print OURBOX_SKU \
    --print OURBOX_VARIANT \
    --print OURBOX_VERSION
)"
mapfile -t payload_meta_fields <<<"${payload_meta_dump}"
[[ "${#payload_meta_fields[@]}" -eq 6 ]] || die "failed to parse ${OS_META_ENV}"

: "${OURBOX_PRODUCT:=${payload_meta_fields[0]:-ourbox}}"
: "${OURBOX_DEVICE:=${payload_meta_fields[1]:-woodbox}}"
: "${OURBOX_TARGET:=${payload_meta_fields[2]:-x86}}"
: "${OURBOX_SKU:=${payload_meta_fields[3]:-TOO-OBX-WBX-BASE-JU3XK8}}"
: "${OURBOX_VARIANT:=${payload_meta_fields[4]:-prod}}"
: "${OURBOX_VERSION:=${payload_meta_fields[5]:-host-compose}}"

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
    --embed-payload-meta "${OS_META_ENV}" \
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
