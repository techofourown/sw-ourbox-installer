#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tools/lib.sh"

if [[ ${EUID} -ne 0 ]]; then
  log "Re-executing with sudo..."
  exec sudo -E -- "$0" "$@"
fi

ISO="${1:-}"
DEV="${2:-}"

[[ -n "${ISO}" && -n "${DEV}" ]] || die "Usage: $0 PATH_TO_INSTALLER_ISO TARGET_DISK"
[[ -f "${ISO}" ]] || die "ISO not found: ${ISO}"

need_cmd dd
need_cmd lsblk
need_cmd readlink
need_cmd findmnt
need_cmd awk
need_cmd umount
need_cmd wipefs
need_cmd blockdev

ISO="$(readlink -f "${ISO}")"
DEV="$(readlink -f "${DEV}")"

[[ "$(lsblk -dn -o TYPE "${DEV}" 2>/dev/null | tr -d '[:space:]')" == "disk" ]] || die "target is not a raw disk: ${DEV}"

# Refuse to flash disk backing /
root_src="$(findmnt -nr -o SOURCE / 2>/dev/null || true)"
root_real="$(readlink -f "${root_src}" 2>/dev/null || echo "${root_src}")"
root_parent="$(lsblk -no PKNAME "${root_real}" 2>/dev/null || true)"
if [[ -n "${root_parent}" ]]; then
  root_real="/dev/${root_parent}"
fi
[[ "${DEV}" != "${root_real}" ]] || die "refusing to flash disk backing / (${root_real})"

# Unmount any mounted partitions on target
while read -r name mp; do
  [[ -n "${mp}" ]] || continue
  umount "/dev/${name}" >/dev/null 2>&1 || umount "${mp}" >/dev/null 2>&1 || true
done < <(lsblk -nr -o NAME,MOUNTPOINT "${DEV}" | awk 'NF==2 && $2!="" {print $1, $2}')

if lsblk -nr -o MOUNTPOINT "${DEV}" | awk 'NF && $0 != "" {found=1} END{exit !found}'; then
  lsblk -o NAME,FSTYPE,LABEL,MOUNTPOINTS "${DEV}" || true
  die "device has mounted partitions; refusing to flash"
fi

size_bytes="$(blockdev --getsize64 "${DEV}")"
if (( size_bytes < 8000000000 )); then
  die "device is too small (${size_bytes} bytes); requires at least 8GB"
fi

log "About to flash installer ISO"
log "ISO=${ISO}"
log "DEV=${DEV}"

lsblk -o NAME,SIZE,MODEL,SERIAL,TYPE,FSTYPE,LABEL,MOUNTPOINTS "${DEV}" || true

read -r -p "Type FLASH to erase and flash ${DEV}: " a
[[ "${a}" == "FLASH" ]] || die "confirmation did not match FLASH"
read -r -p "Type the target device path exactly (${DEV}): " b
[[ "${b}" == "${DEV}" ]] || die "device confirmation mismatch"

wipefs -a "${DEV}" >/dev/null 2>&1 || true

log "Flashing ${ISO} -> ${DEV}"
dd if="${ISO}" of="${DEV}" bs=4M conv=fsync status=progress
sync

log "Flash complete"
