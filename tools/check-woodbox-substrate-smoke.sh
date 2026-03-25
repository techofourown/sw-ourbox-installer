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
SUBSTRATE_DIR="${MISSION_DIR}/artifacts/substrate"
SSH_DIR="${MISSION_DIR}/artifacts/installed-target-ssh"
SUBSTRATE_SOURCE_DIR="${TMP}/substrate-source"
SUBSTRATE_TREE="${TMP}/substrate-tree"
BOOT_DIR="${TMP}/boot-images"
mkdir -p "${OS_DIR}" "${SUBSTRATE_DIR}" "${SSH_DIR}" "${SUBSTRATE_SOURCE_DIR}/k3s" "${SUBSTRATE_SOURCE_DIR}/platform/images" \
  "${SUBSTRATE_TREE}/boot/grub/i386-pc" "${SUBSTRATE_TREE}/nocloud" "${SUBSTRATE_TREE}/ourbox/installer" \
  "${SUBSTRATE_TREE}/ourbox/tools" "${BOOT_DIR}"

cp "${ROOT}/vendor/woodbox/strict-kv-metadata.py" "${TMP}/strict-kv-metadata.py"
chmod +x "${TMP}/strict-kv-metadata.py"

printf 'payload bytes\n' > "${OS_DIR}/os-payload.tar.gz"
printf '%s  %s\n' "$(sha256sum "${OS_DIR}/os-payload.tar.gz" | awk '{print $1}')" "os-payload.tar.gz" > "${OS_DIR}/os-payload.tar.gz.sha256"
cat > "${OS_DIR}/os.meta.env" <<'EOF'
OS_ARTIFACT_TYPE=application/vnd.techofourown.ourbox.woodbox.os-payload.v1
OURBOX_PRODUCT=ourbox
OURBOX_DEVICE=woodbox
OURBOX_TARGET=x86
OURBOX_SKU=TOO-OBX-WBX-BASE-JU3XK8
OURBOX_VARIANT=prod
OURBOX_VERSION=v0.0.1
OURBOX_RECIPE_GIT_HASH=abc123def456
BUILD_TS=2026-03-12T00:00:00Z
OURBOX_SUBSTRATE_REF=ghcr.io/example/ourbox-substrate@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
OURBOX_SUBSTRATE_DIGEST=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
OURBOX_SUBSTRATE_SOURCE=https://github.com/techofourown/sw-ourbox-os
OURBOX_SUBSTRATE_REVISION=abc123def456
OURBOX_SUBSTRATE_VERSION=v0.0.1
OURBOX_SUBSTRATE_CREATED=2026-03-12T00:00:00Z
OURBOX_SUBSTRATE_ARCH=amd64
OURBOX_SUBSTRATE_PROFILE=demo-apps
OURBOX_SUBSTRATE_K3S_VERSION=v1.35.0+k3s1
OURBOX_SUBSTRATE_IMAGES_LOCK_SHA256=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
OURBOX_BASE_ISO_URL=https://example.invalid/ubuntu.iso
OURBOX_BASE_ISO_SHA256=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
K3S_VERSION=v1.35.0+k3s1
GITHUB_RUN_ID=
GITHUB_RUN_ATTEMPT=
EOF

cat > "${SUBSTRATE_SOURCE_DIR}/manifest.env" <<'EOF'
OURBOX_SUBSTRATE_SOURCE=https://github.com/techofourown/sw-ourbox-os
OURBOX_SUBSTRATE_REVISION=abc123def456
OURBOX_SUBSTRATE_VERSION=v0.0.1
OURBOX_SUBSTRATE_CREATED=2026-03-12T00:00:00Z
OURBOX_SUBSTRATE_ARCH=amd64
K3S_VERSION=v1.35.0+k3s1
OURBOX_PLATFORM_PROFILE=demo-apps
OURBOX_PLATFORM_IMAGES_LOCK_PATH=platform/images.lock.json
OURBOX_PLATFORM_IMAGES_LOCK_SHA256=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
EOF
printf '#!/bin/sh\nexit 0\n' > "${SUBSTRATE_SOURCE_DIR}/k3s/k3s"
chmod +x "${SUBSTRATE_SOURCE_DIR}/k3s/k3s"
printf 'fixture substrate images\n' > "${SUBSTRATE_SOURCE_DIR}/k3s/k3s-images-amd64.tar"
printf '{"images":[]}\n' > "${SUBSTRATE_SOURCE_DIR}/platform/images.lock.json"
printf 'PROFILE=demo-apps\n' > "${SUBSTRATE_SOURCE_DIR}/platform/profile.env"
printf 'fixture image tar\n' > "${SUBSTRATE_SOURCE_DIR}/platform/images/platform-demo.tar"
tar -C "${SUBSTRATE_SOURCE_DIR}" -czf "${SUBSTRATE_DIR}/ourbox-substrate.tar.gz" k3s platform manifest.env
printf '%s  %s\n' "$(sha256sum "${SUBSTRATE_DIR}/ourbox-substrate.tar.gz" | awk '{print $1}')" "ourbox-substrate.tar.gz" > "${SUBSTRATE_DIR}/ourbox-substrate.tar.gz.sha256"
cp -f "${SUBSTRATE_SOURCE_DIR}/manifest.env" "${SUBSTRATE_DIR}/manifest.env"
cat > "${SUBSTRATE_DIR}/catalog.json" <<'EOF'
{
  "schema": 1,
  "kind": "ourbox-application-catalog",
  "catalog_id": "demo-apps",
  "catalog_name": "Demo Apps",
  "default_app_ids": [
    "landing",
    "dufs"
  ],
  "apps": [
    {
      "id": "landing",
      "display_name": "Landing",
      "image_names": [
        "landing"
      ],
      "services": [
        {
          "name": "landing",
          "image": "landing",
          "port": 80
        }
      ]
    },
    {
      "id": "dufs",
      "display_name": "Dufs",
      "image_names": [
        "dufs"
      ],
      "services": [
        {
          "name": "dufs",
          "image": "dufs",
          "port": 5000
        }
      ]
    }
  ]
}
EOF
cat > "${SUBSTRATE_DIR}/selected-apps.json" <<'EOF'
{
  "schema": 1,
  "kind": "ourbox-selected-applications",
  "catalog_id": "demo-apps",
  "selection_mode": "catalog-defaults",
  "selected_app_ids": [
    "landing",
    "dufs"
  ]
}
EOF
cat > "${SUBSTRATE_DIR}/application-images.lock.json" <<'EOF'
{
  "schema": 1,
  "images": [
    {
      "name": "landing",
      "ref": "ghcr.io/example/landing@sha256:1111111111111111111111111111111111111111111111111111111111111111"
    },
    {
      "name": "dufs",
      "ref": "ghcr.io/example/dufs@sha256:2222222222222222222222222222222222222222222222222222222222222222"
    }
  ]
}
EOF
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFM7xJ0oE1W8rQx6wH4M7dQf3J6pV8nX2kL4cR5sT6u7 fixture@host\n' > "${SSH_DIR}/authorized-key.pub"

cat > "${MISSION_DIR}/mission-manifest.json" <<'EOF'
{
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
    "compose_strategy": "woodbox-fat-iso-with-host-selected-os-application-catalog-and-app-selection",
    "mission_only": false
  },
  "requested": {
    "substrate": {
      "strategy": "published-installer-substrate",
      "release_channel": "stable",
      "requested_ref": "ghcr.io/example/ourbox-woodbox-installer:stable"
    },
    "os": {
      "selection_source": "catalog",
      "release_channel": "stable",
      "requested_ref": ""
    },
    "selected_substrate": {
      "selection_mode": "host-selected",
      "selection_source": "application-catalogs",
      "release_channel": "",
      "requested_ref": ""
    },
    "applications": {
      "catalog_id": "demo-apps",
      "catalog_name": "Demo Apps",
      "selection_mode": "catalog-defaults",
      "selected_app_ids": [
        "landing",
        "dufs"
      ],
      "source_catalogs": [
        {
          "catalog_id": "demo-apps",
          "catalog_name": "Demo Apps"
        }
      ]
    },
    "installed_target_ssh": {
      "mode": "host-generated-authorized-key",
      "key_name": "fixture-shared-dev"
    }
  },
  "resolved": {
    "substrate": {
      "strategy": "published-installer-substrate",
      "artifact_ref": "ghcr.io/example/ourbox-woodbox-installer@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
      "artifact_digest": "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
      "release_channel": "stable",
      "compose_entrypoint": "tools/media-adapter/compose-media.sh"
    },
    "os": {
      "selection_source": "catalog",
      "release_channel": "stable",
      "artifact_ref": "ghcr.io/example/ourbox-woodbox-os@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
      "artifact_digest": "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
      "artifact_type": "application/vnd.techofourown.ourbox.woodbox.os-payload.v1",
      "payload": {
        "relpath": "artifacts/os/os-payload.tar.gz",
        "sha256": "be3d5e9960cb84a33783cc670ccf3e2a01910868003719d8cb9f95f0d68088d9",
        "size_bytes": 14
      },
      "metadata_relpath": "artifacts/os/os.meta.env"
    },
    "selected_substrate": {
      "selection_mode": "host-selected",
      "selection_source": "application-catalogs",
      "release_channel": "",
      "artifact_ref": "ghcr.io/example/ourbox-substrate@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "artifact_digest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "arch": "amd64",
      "profile": "demo-apps",
      "version": "v0.0.1",
      "created": "2026-03-12T00:00:00Z",
      "k3s_version": "v1.35.0+k3s1",
      "payload_relpath": "artifacts/substrate/ourbox-substrate.tar.gz",
      "manifest_relpath": "artifacts/substrate/manifest.env",
      "images_lock_sha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
      "present_in_selected_os_payload": false
    },
    "applications": {
      "catalog_id": "demo-apps",
      "catalog_name": "Demo Apps",
      "selection_mode": "catalog-defaults",
      "selected_app_ids": [
        "landing",
        "dufs"
      ],
      "catalog_relpath": "artifacts/substrate/catalog.json",
      "images_lock_relpath": "artifacts/substrate/application-images.lock.json",
      "selection_relpath": "artifacts/substrate/selected-apps.json"
    },
    "installed_target_ssh": {
      "mode": "host-generated-authorized-key",
      "key_name": "fixture-shared-dev",
      "authorized_key_relpath": "artifacts/installed-target-ssh/authorized-key.pub",
      "key_type": "ssh-ed25519",
      "public_key_fingerprint": "SHA256:fixtureFingerprint0123456789abcdef=="
    }
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

expect_validation_failure() {
  local mission_dir="$1"
  local description="$2"
  local expected_message="$3"
  local output=""
  local status=0

  set +e
  output="$(
    bash "${ROOT}/vendor/woodbox/validate-media.sh" \
      --mission-dir "${mission_dir}" \
      --os-payload "${OS_DIR}/os-payload.tar.gz" \
      --os-meta-env "${OS_DIR}/os.meta.env" 2>&1
  )"
  status=$?
  set -e

  [[ "${status}" -ne 0 ]] || die "expected vendored woodbox validator to reject ${description}"
  if [[ -n "${expected_message}" ]]; then
    grep -Fq "${expected_message}" <<<"${output}" \
      || die "vendored woodbox validator did not explain ${description}"
  fi
}

BAD_MISSION_DIR="${TMP}/bad-woodbox-mission-missing-service-image"
cp -a "${MISSION_DIR}" "${BAD_MISSION_DIR}"
cat > "${BAD_MISSION_DIR}/artifacts/substrate/application-images.lock.json" <<'EOF'
{
  "schema": 1,
  "images": [
    {
      "name": "landing",
      "ref": "ghcr.io/example/landing@sha256:1111111111111111111111111111111111111111111111111111111111111111"
    }
  ]
}
EOF
expect_validation_failure "${BAD_MISSION_DIR}" \
  "application images locks missing selected service images" \
  ""

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

printf '[%s] woodbox substrate smoke passed\n' "$(date -Is)"
