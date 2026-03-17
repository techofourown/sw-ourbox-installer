#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tools/lib.sh"

need_cmd xz
need_cmd losetup
need_cmd lsblk
need_cmd mount
need_cmd umount
need_cmd mountpoint
need_cmd findmnt
need_cmd readlink
need_cmd rsync
need_cmd sha256sum
need_cmd awk
need_cmd bash
need_cmd python3
need_cmd sfdisk
need_cmd mkfs.ext4
need_cmd truncate
need_cmd cmp

SUDO=""
if [[ ${EUID} -ne 0 ]]; then
  need_cmd sudo
  SUDO="sudo"
fi

TMP="$(mktemp -d)"
LOOPDEV=""
VERIFY_LOOPDEV=""
MOUNT_DIR="${TMP}/mnt"
VERIFY_MOUNT_DIR="${TMP}/verify-mnt"
trap 'cleanup' EXIT

cleanup() {
  if [[ -n "${VERIFY_LOOPDEV}" ]]; then
    if mountpoint -q "${VERIFY_MOUNT_DIR}" 2>/dev/null; then
      ${SUDO} umount "${VERIFY_MOUNT_DIR}" >/dev/null 2>&1 || true
    fi
    ${SUDO} losetup -d "${VERIFY_LOOPDEV}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${LOOPDEV}" ]]; then
    if mountpoint -q "${MOUNT_DIR}" 2>/dev/null; then
      ${SUDO} umount "${MOUNT_DIR}" >/dev/null 2>&1 || true
    fi
    ${SUDO} losetup -d "${LOOPDEV}" >/dev/null 2>&1 || true
  fi
  rm -rf "${TMP}"
}

wait_for_loop_parts() {
  local loopdev="$1"
  local deadline=$((SECONDS + 10))
  local parts=()

  while (( SECONDS < deadline )); do
    mapfile -t parts < <(${SUDO} lsblk -rno PATH,TYPE "${loopdev}" | awk '$2=="part" {print $1}')
    if (( ${#parts[@]} > 0 )); then
      printf '%s\n' "${parts[@]}"
      return 0
    fi
    sleep 1
  done

  return 1
}

find_installer_root_partition() {
  local loopdev="$1"
  local mount_dir="$2"
  local part=""
  local loop_parts=()

  mapfile -t loop_parts < <(wait_for_loop_parts "${loopdev}")
  (( ${#loop_parts[@]} > 0 )) || return 1

  for part in "${loop_parts[@]}"; do
    if ! ${SUDO} mount -o rw "${part}" "${mount_dir}" >/dev/null 2>&1; then
      continue
    fi
    if ${SUDO} test -f "${mount_dir}/opt/ourbox/tools/ourbox-install"; then
      printf '%s\n' "${part}"
      return 0
    fi
    ${SUDO} umount "${mount_dir}" >/dev/null 2>&1 || true
  done

  return 1
}

MISSION_DIR="${TMP}/mission"
OS_DIR="${MISSION_DIR}/artifacts/os"
AIRGAP_DIR="${MISSION_DIR}/artifacts/airgap"
mkdir -p "${OS_DIR}" "${AIRGAP_DIR}" "${MOUNT_DIR}" "${VERIFY_MOUNT_DIR}"

printf 'fixture matchbox payload\n' > "${OS_DIR}/os.img.xz"
printf '%s  %s\n' "$(sha256sum "${OS_DIR}/os.img.xz" | awk '{print $1}')" "os.img.xz" \
  > "${OS_DIR}/os.img.xz.sha256"
cat > "${OS_DIR}/os.meta.env" <<'EOF'
OS_IMAGE_BASENAME=fixture-matchbox
OS_IMAGE_SHA256=unused-for-this-smoke
OS_IMAGE_SIZE_BYTES=0
OS_ARTIFACT_TYPE=application/vnd.techofourown.ourbox.matchbox.os-image.v1
OURBOX_TARGET=rpi
OURBOX_VARIANT=prod
OURBOX_VERSION=v0.0.1
OURBOX_SKU=TOO-OBX-MBX-BASE-001
BUILD_TS=2026-03-17T00:00:00Z
GIT_SHA=abc123def456
OURBOX_PLATFORM_CONTRACT_DIGEST=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
OURBOX_PLATFORM_CONTRACT_SOURCE=https://github.com/techofourown/sw-ourbox-os
OURBOX_PLATFORM_CONTRACT_REVISION=abc123def456
OURBOX_PLATFORM_CONTRACT_VERSION=v0.0.1
OURBOX_PLATFORM_CONTRACT_CREATED=2026-03-17T00:00:00Z
K3S_VERSION=v1.35.0+k3s1
OURBOX_AIRGAP_PLATFORM_REF=ghcr.io/example/airgap-platform@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
OURBOX_AIRGAP_PLATFORM_DIGEST=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
OURBOX_AIRGAP_PLATFORM_SOURCE=https://github.com/techofourown/sw-ourbox-os
OURBOX_AIRGAP_PLATFORM_REVISION=abc123def456
OURBOX_AIRGAP_PLATFORM_VERSION=v0.0.1
OURBOX_AIRGAP_PLATFORM_CREATED=2026-03-17T00:00:00Z
OURBOX_AIRGAP_PLATFORM_ARCH=arm64
OURBOX_AIRGAP_PLATFORM_PROFILE=demo-apps
OURBOX_AIRGAP_PLATFORM_K3S_VERSION=v1.35.0+k3s1
OURBOX_AIRGAP_PLATFORM_IMAGES_LOCK_SHA256=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
EOF

AIRGAP_SOURCE_DIR="${TMP}/airgap-source"
mkdir -p "${AIRGAP_SOURCE_DIR}/k3s" "${AIRGAP_SOURCE_DIR}/platform/images"
printf '#!/bin/sh\nexit 0\n' > "${AIRGAP_SOURCE_DIR}/k3s/k3s"
chmod +x "${AIRGAP_SOURCE_DIR}/k3s/k3s"
printf 'fixture airgap images\n' > "${AIRGAP_SOURCE_DIR}/k3s/k3s-airgap-images-arm64.tar"
printf '{"images":[]}\n' > "${AIRGAP_SOURCE_DIR}/platform/images.lock.json"
printf 'PROFILE=demo-apps\n' > "${AIRGAP_SOURCE_DIR}/platform/profile.env"
printf 'fixture image tar\n' > "${AIRGAP_SOURCE_DIR}/platform/images/platform-demo.tar"
cat > "${AIRGAP_SOURCE_DIR}/manifest.env" <<'EOF'
OURBOX_AIRGAP_PLATFORM_SOURCE=https://github.com/techofourown/sw-ourbox-os
OURBOX_AIRGAP_PLATFORM_REVISION=abc123def456
OURBOX_AIRGAP_PLATFORM_VERSION=v0.0.1
OURBOX_AIRGAP_PLATFORM_CREATED=2026-03-17T00:00:00Z
OURBOX_PLATFORM_CONTRACT_DIGEST=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
AIRGAP_PLATFORM_ARCH=arm64
K3S_VERSION=v1.35.0+k3s1
OURBOX_PLATFORM_PROFILE=demo-apps
OURBOX_PLATFORM_IMAGES_LOCK_PATH=platform/images.lock.json
OURBOX_PLATFORM_IMAGES_LOCK_SHA256=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
EOF
tar -C "${AIRGAP_SOURCE_DIR}" -czf "${AIRGAP_DIR}/airgap-platform.tar.gz" k3s platform manifest.env
printf '%s  %s\n' "$(sha256sum "${AIRGAP_DIR}/airgap-platform.tar.gz" | awk '{print $1}')" "airgap-platform.tar.gz" \
  > "${AIRGAP_DIR}/airgap-platform.tar.gz.sha256"
cp -f "${AIRGAP_SOURCE_DIR}/manifest.env" "${AIRGAP_DIR}/manifest.env"

python3 - <<'PY' "${MISSION_DIR}" "${ROOT}/vendor/matchbox/adapter.json"
import hashlib
import json
import pathlib
import sys

mission_dir = pathlib.Path(sys.argv[1])
adapter_path = pathlib.Path(sys.argv[2])
with adapter_path.open("r", encoding="utf-8") as handle:
    adapter = json.load(handle)

def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

os_payload = mission_dir / "artifacts/os/os.img.xz"
os_meta = mission_dir / "artifacts/os/os.meta.env"
airgap_payload = mission_dir / "artifacts/airgap/airgap-platform.tar.gz"
airgap_manifest = mission_dir / "artifacts/airgap/manifest.env"

staged_files = []
for path in sorted(mission_dir.rglob("*")):
    if path.is_file():
        staged_files.append(
            {
                "relpath": path.relative_to(mission_dir).as_posix(),
                "sha256": sha256(path),
                "size_bytes": path.stat().st_size,
            }
        )

manifest = {
    "schema": 1,
    "kind": "ourbox-mission",
    "compose_id": "matchbox-fixture",
    "created": "2026-03-17T00:00:00Z",
    "target": {
        "id": "matchbox",
        "media_kind": "installer-usb",
    },
    "composer": {
        "name": "sw-ourbox-installer",
        "phase": "phase-2",
        "source_revision": "abc123def456",
    },
    "adapter": {
        "source_repo": "https://github.com/techofourown/img-ourbox-matchbox",
        "source_revision": "abc123def456",
        "adapter_json_relpath": "vendor/matchbox/adapter.json",
        "runtime_prompts_kept": adapter["runtime_prompts_kept"],
    },
    "operator_mode": {
        "mode": "install",
        "prompt_hostname_on_target": True,
        "prompt_identity_on_target": True,
    },
    "mission_media": {
        "compose_strategy": "matchbox-fat-image-with-host-selected-os-and-airgap",
        "mission_only": False,
    },
    "substrate": {
        "strategy": "published-installer-substrate",
        "artifact_ref": "ghcr.io/example/ourbox-matchbox-installer@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
        "artifact_digest": "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
        "release_channel": "stable",
        "compose_entrypoint": "tools/media-adapter/compose-media.sh",
    },
    "platform_contract": {
        "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    },
    "selected_os": {
        "selection_source": "catalog",
        "release_channel": "stable",
        "artifact_ref": "ghcr.io/example/ourbox-matchbox-os@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
        "artifact_digest": "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
        "artifact_type": adapter["expected_os_artifact_type"],
        "platform_contract_digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "payload": {
            "relpath": os_payload.relative_to(mission_dir).as_posix(),
            "sha256": sha256(os_payload),
            "size_bytes": os_payload.stat().st_size,
        },
        "metadata_relpath": os_meta.relative_to(mission_dir).as_posix(),
    },
    "selected_airgap": {
        "selection_mode": "application-catalogs",
        "selection_source": "catalog",
        "release_channel": "stable",
        "artifact_ref": "ghcr.io/example/airgap-platform@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "artifact_digest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "platform_contract_digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "arch": adapter["expected_airgap_arch"],
        "profile": "demo-apps",
        "version": "v0.0.1",
        "created": "2026-03-17T00:00:00Z",
        "k3s_version": "v1.35.0+k3s1",
        "images_lock_sha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
        "payload_relpath": airgap_payload.relative_to(mission_dir).as_posix(),
        "manifest_relpath": airgap_manifest.relative_to(mission_dir).as_posix(),
        "present_in_selected_os_payload": False,
    },
    "staged_files": staged_files,
}

with (mission_dir / "mission-manifest.json").open("w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2)
    handle.write("\n")
PY

python3 "${ROOT}/tools/validate-mission-manifest.py" \
  "${ROOT}/schemas/mission-manifest.schema.json" \
  "${MISSION_DIR}/mission-manifest.json"

bash "${ROOT}/vendor/matchbox/validate-media.sh" \
  --mission-dir "${MISSION_DIR}" \
  --os-payload "${OS_DIR}/os.img.xz" \
  --os-meta-env "${OS_DIR}/os.meta.env"

SUBSTRATE_RAW="${TMP}/installer-substrate.img"
SUBSTRATE_ARTIFACT="${TMP}/installer-substrate.img.xz"
OUT_DIR="${TMP}/out"
truncate -s 128M "${SUBSTRATE_RAW}"
LOOPDEV="$(${SUDO} losetup --find --show "${SUBSTRATE_RAW}")"
printf ',,L,*\n' | ${SUDO} sfdisk "${LOOPDEV}" >/dev/null
${SUDO} partprobe "${LOOPDEV}" >/dev/null 2>&1 || true
ROOT_PART="$(wait_for_loop_parts "${LOOPDEV}" | head -n 1)"
[[ -n "${ROOT_PART}" ]] || die "failed to discover substrate partition"
${SUDO} mkfs.ext4 -q -F "${ROOT_PART}" >/dev/null
${SUDO} mount "${ROOT_PART}" "${MOUNT_DIR}"
${SUDO} install -d -m 0755 "${MOUNT_DIR}/opt/ourbox/tools" "${MOUNT_DIR}/opt/ourbox/installer"
printf '#!/bin/sh\nexit 0\n' | ${SUDO} tee "${MOUNT_DIR}/opt/ourbox/tools/ourbox-install" >/dev/null
${SUDO} chmod 0755 "${MOUNT_DIR}/opt/ourbox/tools/ourbox-install"
printf 'INSTALLER_ID=matchbox\n' | ${SUDO} tee "${MOUNT_DIR}/opt/ourbox/installer/defaults.env" >/dev/null
${SUDO} umount "${MOUNT_DIR}"
${SUDO} losetup -d "${LOOPDEV}"
LOOPDEV=""
xz -z -c "${SUBSTRATE_RAW}" > "${SUBSTRATE_ARTIFACT}"

${SUDO} env \
  MATCHBOX_ADAPTER_ROOT="${ROOT}/vendor/matchbox" \
  OURBOX_MEDIA_COMPOSE_WORK_ROOT="${TMP}/work" \
  bash "${ROOT}/vendor/matchbox/compose-media.sh" \
    --mission-dir "${MISSION_DIR}" \
    --os-payload "${OS_DIR}/os.img.xz" \
    --os-meta-env "${OS_DIR}/os.meta.env" \
    --substrate-artifact "${SUBSTRATE_ARTIFACT}" \
    --output-dir "${OUT_DIR}"

${SUDO} chown -R "$(id -u):$(id -g)" "${TMP}"

OUT_IMG_XZ="${OUT_DIR}/installer-ourbox-matchbox-rpi-too-obx-mbx-base-001-prod-v0.0.1.img.xz"
[[ -f "${OUT_IMG_XZ}" ]] || die "composed Matchbox media missing from ${OUT_DIR}"

VERIFY_RAW="${TMP}/verify.img"
xz -dc "${OUT_IMG_XZ}" > "${VERIFY_RAW}"
VERIFY_LOOPDEV="$(${SUDO} losetup --find --show -Pf "${VERIFY_RAW}")"
VERIFY_ROOT_PART="$(find_installer_root_partition "${VERIFY_LOOPDEV}" "${VERIFY_MOUNT_DIR}" || true)"
[[ -n "${VERIFY_ROOT_PART}" ]] || die "failed to locate composed Matchbox installer root partition"
${SUDO} test -f "${VERIFY_MOUNT_DIR}/opt/ourbox/mission/mission-manifest.json" \
  || die "composed Matchbox media is missing embedded mission-manifest.json"
${SUDO} cmp -s "${VERIFY_MOUNT_DIR}/opt/ourbox/mission/mission-manifest.json" \
  "${MISSION_DIR}/mission-manifest.json" \
  || die "embedded Matchbox mission manifest does not match the staged mission"
${SUDO} umount "${VERIFY_MOUNT_DIR}" >/dev/null 2>&1 || true
${SUDO} losetup -d "${VERIFY_LOOPDEV}" >/dev/null 2>&1 || true
VERIFY_LOOPDEV=""

printf '[%s] vendored matchbox compose smoke passed\n' "$(date -Is)"
