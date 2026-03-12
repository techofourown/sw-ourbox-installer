#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${WOODBOX_ADAPTER_ROOT:=${SCRIPT_DIR}}"
ADAPTER_WORKSPACE_ROOT="$(cd "${WOODBOX_ADAPTER_ROOT}/../.." && pwd)"

LIB_SH="${WOODBOX_ADAPTER_ROOT}/lib.sh"
if [[ ! -f "${LIB_SH}" ]]; then
  LIB_SH="$(cd "${SCRIPT_DIR}/../.." && pwd)/tools/lib.sh"
fi
# shellcheck disable=SC1090
source "${LIB_SH}"

MISSION_DIR=""
OS_PAYLOAD=""
OS_META_ENV=""
SUBSTRATE_ISO=""
OUTPUT_DIR=""
FLASH_DEVICE=""

usage() {
  cat <<EOF
Usage: $0 --mission-dir DIR --os-payload PATH --os-meta-env PATH --substrate-iso PATH [--output-dir DIR] [--flash-device DEV]

Woodbox mission-media composition:
- validates a prepared mission directory
- starts from a published Woodbox installer substrate ISO
- embeds the selected OS payload
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
    --substrate-iso)
      [[ $# -ge 2 ]] || die "--substrate-iso requires a value"
      SUBSTRATE_ISO="$2"
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
[[ -n "${SUBSTRATE_ISO}" ]] || die "--substrate-iso is required"
[[ -f "${SUBSTRATE_ISO}" ]] || die "substrate ISO not found: ${SUBSTRATE_ISO}"

need_cmd xorriso
need_cmd 7z
need_cmd rsync
need_cmd sha256sum
need_cmd awk
need_cmd bash

bash "${WOODBOX_ADAPTER_ROOT}/validate-media.sh" \
  --mission-dir "${MISSION_DIR}" \
  --os-payload "${OS_PAYLOAD}" \
  --os-meta-env "${OS_META_ENV}"

STRICT_METADATA_PARSER="${WOODBOX_ADAPTER_ROOT}/strict-kv-metadata.py"
if [[ ! -f "${STRICT_METADATA_PARSER}" ]]; then
  STRICT_METADATA_PARSER="$(cd "${SCRIPT_DIR}/../.." && pwd)/tools/strict-kv-metadata.py"
fi
[[ -f "${STRICT_METADATA_PARSER}" ]] || die "strict metadata parser not found: ${STRICT_METADATA_PARSER}"

FLASH_HELPER="${WOODBOX_ADAPTER_ROOT}/flash-installer-media.sh"
if [[ ! -f "${FLASH_HELPER}" ]]; then
  FLASH_HELPER="$(cd "${SCRIPT_DIR}/../.." && pwd)/tools/flash-installer-media.sh"
fi
[[ -f "${FLASH_HELPER}" ]] || die "flash helper not found: ${FLASH_HELPER}"

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
OUT_ISO="${ADAPTER_WORKSPACE_ROOT}/deploy/installer-${OURBOX_PRODUCT}-${OURBOX_DEVICE}-${OURBOX_TARGET_SLUG}-${OURBOX_SKU_SLUG}-${OURBOX_VARIANT_SLUG}-${OURBOX_VERSION}.iso"
OUT_SHA="${OUT_ISO}.sha256"
if [[ -n "${OUTPUT_DIR}" ]]; then
  mkdir -p "${OUTPUT_DIR}"
  OUT_ISO="${OUTPUT_DIR}/$(basename "${OUT_ISO}")"
  OUT_SHA="${OUT_ISO}.sha256"
fi
mkdir -p "$(dirname "${OUT_ISO}")"

WORK_ROOT="${OURBOX_MEDIA_COMPOSE_WORK_ROOT:-${ADAPTER_WORKSPACE_ROOT}/artifacts/work}"
mkdir -p "${WORK_ROOT}"
WORKDIR="$(mktemp -d "${WORK_ROOT}/compose-media.XXXXXX")"
trap 'rm -rf -- "${WORKDIR}"' EXIT
ISO_DIR="${WORKDIR}/iso"
BOOT_DIR="${WORKDIR}/BOOT"
mkdir -p "${ISO_DIR}" "${BOOT_DIR}"

VOLID="$(xorriso -indev "${SUBSTRATE_ISO}" -pvd_info 2>/dev/null \
  | awk -F': *' 'tolower($1) ~ /volume id/ {print $2; exit}' \
  | sed -E "s/[[:space:]]*$//; s/^'//; s/'$//")"
[[ -n "${VOLID}" ]] || die "failed to read volume id from substrate ISO: ${SUBSTRATE_ISO}"

log "Composing Woodbox mission media from substrate ISO"
log "Using substrate ISO: ${SUBSTRATE_ISO}"

xorriso -osirrox on -indev "${SUBSTRATE_ISO}" -extract / "${ISO_DIR}" >/dev/null 2>&1 \
  || die "failed to extract substrate ISO: ${SUBSTRATE_ISO}"
chmod -R u+w "${ISO_DIR}" || true

[[ -f "${ISO_DIR}/ourbox/installer/defaults.env" ]] || die "substrate ISO missing /ourbox/installer/defaults.env"
[[ -f "${ISO_DIR}/ourbox/tools/ourbox-preinstall" ]] || die "substrate ISO missing /ourbox/tools/ourbox-preinstall"
[[ -f "${ISO_DIR}/nocloud/user-data" ]] || die "substrate ISO missing /nocloud/user-data"
[[ -f "${ISO_DIR}/autoinstall.yaml" ]] || die "substrate ISO missing /autoinstall.yaml"
[[ -d "${ISO_DIR}/boot/grub" ]] || die "substrate ISO missing /boot/grub"

mkdir -p "${ISO_DIR}/ourbox/payload"
cp "${OS_PAYLOAD}" "${ISO_DIR}/ourbox/payload/os-payload.tar.gz"
sha256sum "${ISO_DIR}/ourbox/payload/os-payload.tar.gz" \
  | awk '{print $1}' > "${ISO_DIR}/ourbox/payload/os-payload.tar.gz.sha256"
cp "${OS_META_ENV}" "${ISO_DIR}/ourbox/payload/payload.meta.env"

mkdir -p "${ISO_DIR}/ourbox/mission"
rsync -a --delete "${MISSION_DIR}/" "${ISO_DIR}/ourbox/mission/"
[[ -f "${ISO_DIR}/ourbox/mission/mission-manifest.json" ]] \
  || die "mission-manifest.json missing after mission embed"

if ! grep -Rqs 'autoinstall' "${ISO_DIR}/boot/grub"; then
  die "substrate ISO boot configs do not contain autoinstall kernel args"
fi
if ! grep -Rqs 'ds=nocloud' "${ISO_DIR}/boot/grub"; then
  die "substrate ISO boot configs do not contain ds=nocloud kernel args"
fi

7z e "${SUBSTRATE_ISO}" -o"${BOOT_DIR}" \
  '[BOOT]/1-Boot-NoEmul.img' \
  '[BOOT]/2-Boot-NoEmul.img' \
  >/dev/null 2>&1 \
  || die "failed to extract boot images from substrate ISO: ${SUBSTRATE_ISO}"

rm -f "${OUT_ISO}" "${OUT_SHA}"
xorriso -as mkisofs \
  -r \
  -V "${VOLID}" \
  -o "${OUT_ISO}" \
  --grub2-mbr "${BOOT_DIR}/1-Boot-NoEmul.img" \
  -partition_offset 16 \
  --mbr-force-bootable \
  -append_partition 2 28732ac11ff8d211ba4b00a0c93ec93b "${BOOT_DIR}/2-Boot-NoEmul.img" \
  -appended_part_as_gpt \
  -iso_mbr_part_type a2a0d0ebe5b9334487c068b6b72699c7 \
  -c '/boot.catalog' \
  -b '/boot/grub/i386-pc/eltorito.img' \
  -no-emul-boot -boot-load-size 4 -boot-info-table --grub2-boot-info \
  -eltorito-alt-boot \
  -e '--interval:appended_partition_2:::' \
  -no-emul-boot \
  "${ISO_DIR}" \
  >/dev/null

( cd "$(dirname "${OUT_ISO}")" && sha256sum "$(basename "${OUT_ISO}")" > "$(basename "${OUT_SHA}")" )

[[ -f "${OUT_ISO}" ]] || die "expected composed ISO not found: ${OUT_ISO}"
[[ -f "${OUT_SHA}" ]] || die "expected composed ISO checksum not found: ${OUT_SHA}"

if [[ -n "${FLASH_DEVICE}" ]]; then
  "${FLASH_HELPER}" "${OUT_ISO}" "${FLASH_DEVICE}"
fi

log "Woodbox mission media ready: ${OUT_ISO}"
log "Checksum file: ${OUT_SHA}"
