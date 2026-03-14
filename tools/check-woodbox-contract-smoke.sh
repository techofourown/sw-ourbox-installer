#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tools/lib.sh"
need_cmd xorriso
need_cmd 7z

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

MISSION_DIR="${TMP}/mission"
OS_DIR="${MISSION_DIR}/artifacts/os"
AIRGAP_DIR="${MISSION_DIR}/artifacts/airgap"
SSH_DIR="${MISSION_DIR}/artifacts/installed-target-ssh"
AIRGAP_SOURCE_DIR="${TMP}/airgap-source"
SUBSTRATE_TREE="${TMP}/substrate-tree"
BOOT_DIR="${TMP}/boot-images"
mkdir -p "${OS_DIR}" "${AIRGAP_DIR}" "${SSH_DIR}" "${AIRGAP_SOURCE_DIR}/k3s" "${AIRGAP_SOURCE_DIR}/platform/images" \
  "${SUBSTRATE_TREE}/boot/grub/i386-pc" "${SUBSTRATE_TREE}/nocloud" "${SUBSTRATE_TREE}/ourbox/installer" \
  "${SUBSTRATE_TREE}/ourbox/tools" "${BOOT_DIR}"

cp "${ROOT}/vendor/woodbox/strict-kv-metadata.py" "${TMP}/strict-kv-metadata.py"
chmod +x "${TMP}/strict-kv-metadata.py"

printf 'payload bytes\n' > "${OS_DIR}/os-payload.tar.gz"
printf '%s  %s\n' "$(sha256sum "${OS_DIR}/os-payload.tar.gz" | awk '{print $1}')" "os-payload.tar.gz" > "${OS_DIR}/os-payload.tar.gz.sha256"
cat > "${OS_DIR}/os.meta.env" <<'EOF'
OS_ARTIFACT_TYPE=application/vnd.techofourown.ourbox.woodbox.os-payload.v1
OURBOX_PLATFORM_CONTRACT_DIGEST=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
OURBOX_PRODUCT=ourbox
OURBOX_DEVICE=woodbox
OURBOX_TARGET=x86
OURBOX_SKU=TOO-OBX-WBX-BASE-JU3XK8
OURBOX_VARIANT=prod
OURBOX_VERSION=v0.0.1
OURBOX_RECIPE_GIT_HASH=abc123def456
BUILD_TS=2026-03-12T00:00:00Z
OURBOX_PLATFORM_CONTRACT_SOURCE=https://github.com/techofourown/sw-ourbox-os
OURBOX_PLATFORM_CONTRACT_REVISION=abc123def456
OURBOX_PLATFORM_CONTRACT_VERSION=v0.0.1
OURBOX_AIRGAP_PLATFORM_REF=ghcr.io/example/airgap-platform@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
OURBOX_AIRGAP_PLATFORM_DIGEST=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
OURBOX_AIRGAP_PLATFORM_SOURCE=https://github.com/techofourown/sw-ourbox-os
OURBOX_AIRGAP_PLATFORM_REVISION=abc123def456
OURBOX_AIRGAP_PLATFORM_VERSION=v0.0.1
OURBOX_AIRGAP_PLATFORM_CREATED=2026-03-12T00:00:00Z
OURBOX_AIRGAP_PLATFORM_ARCH=amd64
OURBOX_AIRGAP_PLATFORM_PROFILE=demo-apps
OURBOX_AIRGAP_PLATFORM_K3S_VERSION=v1.35.0+k3s1
OURBOX_AIRGAP_PLATFORM_IMAGES_LOCK_SHA256=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
OURBOX_BASE_ISO_URL=https://example.invalid/ubuntu.iso
OURBOX_BASE_ISO_SHA256=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
K3S_VERSION=v1.35.0+k3s1
GITHUB_RUN_ID=
GITHUB_RUN_ATTEMPT=
EOF

cat > "${AIRGAP_SOURCE_DIR}/manifest.env" <<'EOF'
OURBOX_AIRGAP_PLATFORM_SOURCE=https://github.com/techofourown/sw-ourbox-os
OURBOX_AIRGAP_PLATFORM_REVISION=abc123def456
OURBOX_AIRGAP_PLATFORM_VERSION=v0.0.1
OURBOX_AIRGAP_PLATFORM_CREATED=2026-03-12T00:00:00Z
OURBOX_PLATFORM_CONTRACT_DIGEST=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
AIRGAP_PLATFORM_ARCH=amd64
K3S_VERSION=v1.35.0+k3s1
OURBOX_PLATFORM_PROFILE=demo-apps
OURBOX_PLATFORM_IMAGES_LOCK_PATH=platform/images.lock.json
OURBOX_PLATFORM_IMAGES_LOCK_SHA256=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
EOF
printf '#!/bin/sh\nexit 0\n' > "${AIRGAP_SOURCE_DIR}/k3s/k3s"
chmod +x "${AIRGAP_SOURCE_DIR}/k3s/k3s"
printf 'fixture airgap images\n' > "${AIRGAP_SOURCE_DIR}/k3s/k3s-airgap-images-amd64.tar"
printf '{"images":[]}\n' > "${AIRGAP_SOURCE_DIR}/platform/images.lock.json"
printf 'PROFILE=demo-apps\n' > "${AIRGAP_SOURCE_DIR}/platform/profile.env"
printf 'fixture image tar\n' > "${AIRGAP_SOURCE_DIR}/platform/images/platform-demo.tar"
tar -C "${AIRGAP_SOURCE_DIR}" -czf "${AIRGAP_DIR}/airgap-platform.tar.gz" k3s platform manifest.env
printf '%s  %s\n' "$(sha256sum "${AIRGAP_DIR}/airgap-platform.tar.gz" | awk '{print $1}')" "airgap-platform.tar.gz" > "${AIRGAP_DIR}/airgap-platform.tar.gz.sha256"
cp -f "${AIRGAP_SOURCE_DIR}/manifest.env" "${AIRGAP_DIR}/manifest.env"
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFM7xJ0oE1W8rQx6wH4M7dQf3J6pV8nX2kL4cR5sT6u7 fixture@host\n' > "${SSH_DIR}/authorized-key.pub"

cat > "${MISSION_DIR}/mission-manifest.json" <<'EOF'
{
  "schema": 1,
  "kind": "ourbox-mission",
  "compose_id": "woodbox-fixture",
  "created": "2026-03-12T00:00:00Z",
  "target": {
    "id": "woodbox",
    "media_kind": "installer-usb"
  },
  "composer": {
    "name": "sw-ourbox-installer",
    "phase": "phase-1",
    "source_revision": "abc123def456"
  },
  "adapter": {
    "source_repo": "https://github.com/techofourown/img-ourbox-woodbox",
    "source_revision": "abc123def456",
    "adapter_json_relpath": "vendor/woodbox/adapter.json",
    "runtime_prompts_kept": [
      "os-disk-selection",
      "data-disk-selection",
      "data-disk-format-confirmation",
      "identity",
      "install-confirmation"
    ]
  },
  "operator_mode": {
    "mode": "install",
    "prompt_hostname_on_target": true,
    "prompt_identity_on_target": true
  },
  "mission_media": {
    "compose_strategy": "woodbox-fat-iso-with-host-selected-os-and-airgap",
    "mission_only": false
  },
  "substrate": {
    "strategy": "published-installer-substrate",
    "artifact_ref": "ghcr.io/example/ourbox-woodbox-installer@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    "artifact_digest": "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    "release_channel": "stable",
    "compose_entrypoint": "tools/media-adapter/compose-media.sh"
  },
  "platform_contract": {
    "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  },
  "selected_os": {
    "selection_source": "catalog",
    "release_channel": "stable",
    "artifact_ref": "ghcr.io/example/ourbox-woodbox-os@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
    "artifact_digest": "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
    "artifact_type": "application/vnd.techofourown.ourbox.woodbox.os-payload.v1",
    "platform_contract_digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "payload": {
      "relpath": "artifacts/os/os-payload.tar.gz",
      "sha256": "be3d5e9960cb84a33783cc670ccf3e2a01910868003719d8cb9f95f0d68088d9",
      "size_bytes": 14
    },
    "metadata_relpath": "artifacts/os/os.meta.env"
  },
  "selected_airgap": {
    "selection_mode": "baked-from-selected-os",
    "selection_source": "baked-os-payload",
    "release_channel": "",
    "artifact_ref": "ghcr.io/example/airgap-platform@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "artifact_digest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "platform_contract_digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "arch": "amd64",
    "profile": "demo-apps",
    "version": "v0.0.1",
    "created": "2026-03-12T00:00:00Z",
    "k3s_version": "v1.35.0+k3s1",
    "payload_relpath": "artifacts/airgap/airgap-platform.tar.gz",
    "manifest_relpath": "artifacts/airgap/manifest.env",
    "images_lock_sha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    "present_in_selected_os_payload": true
  },
  "installed_target_ssh": {
    "mode": "host-generated-authorized-key",
    "key_name": "fixture-shared-dev",
    "authorized_key_relpath": "artifacts/installed-target-ssh/authorized-key.pub",
    "key_type": "ssh-ed25519",
    "public_key_fingerprint": "SHA256:fixtureFingerprint0123456789abcdef=="
  },
  "staged_files": [
    {
      "relpath": "artifacts/os/os-payload.tar.gz",
      "sha256": "be3d5e9960cb84a33783cc670ccf3e2a01910868003719d8cb9f95f0d68088d9",
      "size_bytes": 14
    },
    {
      "relpath": "artifacts/os/os.meta.env",
      "sha256": "0000000000000000000000000000000000000000000000000000000000000000",
      "size_bytes": 0
    }
  ]
}
EOF

python3 "${ROOT}/tools/validate-mission-manifest.py" \
  "${ROOT}/schemas/mission-manifest.schema.json" \
  "${MISSION_DIR}/mission-manifest.json"

bash "${ROOT}/vendor/woodbox/validate-media.sh" \
  --mission-dir "${MISSION_DIR}" \
  --os-payload "${OS_DIR}/os-payload.tar.gz" \
  --os-meta-env "${OS_DIR}/os.meta.env"

printf 'set timeout=1\nmenuentry \"fixture\" {\n linux /casper/vmlinuz autoinstall ds=nocloud\\;s=file:///cdrom/nocloud/ ---\n}\n' \
  > "${SUBSTRATE_TREE}/boot/grub/grub.cfg"
dd if=/dev/zero of="${SUBSTRATE_TREE}/boot/grub/i386-pc/eltorito.img" bs=1M count=1 status=none
dd if=/dev/zero of="${BOOT_DIR}/1-Boot-NoEmul.img" bs=1M count=1 status=none
dd if=/dev/zero of="${BOOT_DIR}/2-Boot-NoEmul.img" bs=1M count=1 status=none
printf 'fixture user-data\n' > "${SUBSTRATE_TREE}/nocloud/user-data"
printf 'fixture meta-data\n' > "${SUBSTRATE_TREE}/nocloud/meta-data"
printf 'fixture autoinstall\n' > "${SUBSTRATE_TREE}/autoinstall.yaml"
printf 'INSTALLER_ID=woodbox\n' > "${SUBSTRATE_TREE}/ourbox/installer/defaults.env"
printf '#!/bin/sh\nexit 0\n' > "${SUBSTRATE_TREE}/ourbox/tools/ourbox-preinstall"
chmod +x "${SUBSTRATE_TREE}/ourbox/tools/ourbox-preinstall"

SUBSTRATE_ISO="${TMP}/installer-substrate.iso"
xorriso -as mkisofs \
  -r \
  -V "WOODBOX_FIXTURE" \
  -o "${SUBSTRATE_ISO}" \
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
  "${SUBSTRATE_TREE}" \
  >/dev/null

WOODBOX_ADAPTER_ROOT="${ROOT}/vendor/woodbox" \
OURBOX_MEDIA_COMPOSE_WORK_ROOT="${TMP}/work" \
  bash "${ROOT}/vendor/woodbox/compose-media.sh" \
    --mission-dir "${MISSION_DIR}" \
    --os-payload "${OS_DIR}/os-payload.tar.gz" \
    --os-meta-env "${OS_DIR}/os.meta.env" \
    --substrate-iso "${SUBSTRATE_ISO}" \
    --output-dir "${TMP}/out"

[[ -f "${TMP}/out/installer-ourbox-woodbox-x86-too-obx-wbx-base-ju3xk8-prod-v0.0.1.iso" ]] \
  || die "composed ISO missing from adapter output"

printf '[%s] woodbox contract smoke passed\n' "$(date -Is)"
