#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tools/lib.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

MISSION_DIR="${TMP}/mission"
OS_DIR="${MISSION_DIR}/artifacts/os"
AIRGAP_DIR="${MISSION_DIR}/artifacts/airgap"
FAKE_WOODBOX="${TMP}/woodbox"
mkdir -p "${OS_DIR}" "${AIRGAP_DIR}" "${FAKE_WOODBOX}/tools" "${FAKE_WOODBOX}/deploy"

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

printf 'airgap bytes\n' > "${AIRGAP_DIR}/airgap-platform.tar.gz"
printf '%s\n' 'OURBOX_AIRGAP_PLATFORM_SOURCE=https://github.com/techofourown/sw-ourbox-os' > "${AIRGAP_DIR}/manifest.env"

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
    "strategy": "target-repo-build",
    "repo_path": "/tmp/woodbox",
    "repo_revision": "abc123def456",
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

cat > "${FAKE_WOODBOX}/tools/lib.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
log() { printf '[%s] %s\n' "$(date -Is)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
EOF

cat > "${FAKE_WOODBOX}/tools/build-installer-iso.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
payload=""
payload_meta=""
mission_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --embed-payload) payload="$2"; shift 2 ;;
    --embed-payload-meta) payload_meta="$2"; shift 2 ;;
    --embed-mission-dir) mission_dir="$2"; shift 2 ;;
    *) echo "unexpected arg: $1" >&2; exit 1 ;;
  esac
done
[[ -f "${payload}" ]] || { echo "payload missing" >&2; exit 1; }
[[ -f "${payload_meta}" ]] || { echo "payload meta missing" >&2; exit 1; }
[[ -f "${mission_dir}/mission-manifest.json" ]] || { echo "mission manifest missing" >&2; exit 1; }
[[ "${payload_meta}" == */os.meta.env ]] || { echo "explicit payload meta handoff missing" >&2; exit 1; }
mkdir -p "${ROOT}/deploy"
printf 'iso bytes\n' > "${ROOT}/deploy/installer-ourbox-woodbox-x86-too-obx-wbx-base-ju3xk8-prod-v0.0.1.iso"
printf 'checksum\n' > "${ROOT}/deploy/installer-ourbox-woodbox-x86-too-obx-wbx-base-ju3xk8-prod-v0.0.1.iso.sha256"
EOF
chmod +x "${FAKE_WOODBOX}/tools/build-installer-iso.sh"

cat > "${FAKE_WOODBOX}/tools/flash-installer-media.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
chmod +x "${FAKE_WOODBOX}/tools/flash-installer-media.sh"

WOODBOX_ADAPTER_ROOT="${ROOT}/vendor/woodbox" \
WOODBOX_REPO_ROOT="${FAKE_WOODBOX}" \
  bash "${ROOT}/vendor/woodbox/compose-media.sh" \
    --mission-dir "${MISSION_DIR}" \
    --os-payload "${OS_DIR}/os-payload.tar.gz" \
    --os-meta-env "${OS_DIR}/os.meta.env" \
    --output-dir "${TMP}/out"

[[ -f "${TMP}/out/installer-ourbox-woodbox-x86-too-obx-wbx-base-ju3xk8-prod-v0.0.1.iso" ]] \
  || die "composed ISO missing from adapter output"

printf '[%s] woodbox contract smoke passed\n' "$(date -Is)"
