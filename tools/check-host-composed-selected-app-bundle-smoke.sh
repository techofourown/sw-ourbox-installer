#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMP_ROOT}"' EXIT

OURBOX_PREPARE_INSTALLER_LIBRARY_ONLY=1
# shellcheck disable=SC1091
source "${ROOT}/tools/prepare-installer-media.sh"
unset OURBOX_PREPARE_INSTALLER_LIBRARY_ONLY

HARNESS_ROOT="${ROOT}"
HARNESS_TMP_ROOT="${TMP_ROOT}"

# Load the post-guard helper functions without executing the main body.
# shellcheck disable=SC1091
source <(
  sed -n '/^application_catalog_source_display_from_json()/,$p' "${ROOT}/tools/prepare-installer-media.sh" \
    | sed '/^initial_cache_refs=()/,$d'
)

ROOT="${HARNESS_ROOT}"
TMP_ROOT="${HARNESS_TMP_ROOT}"

MISSION_ROOT="${TMP_ROOT}/mission"
AIRGAP_STAGE_DIR="${MISSION_ROOT}/artifacts/airgap"
MERGED_APPLICATION_CATALOG_FILE="${TMP_ROOT}/merged.catalog.json"
MERGED_SELECTED_APPLICATIONS_FILE="${TMP_ROOT}/merged.selected-apps.json"
MERGED_IMAGES_LOCK_FILE="${TMP_ROOT}/merged.images.lock.json"
OS_PAYLOAD="${TMP_ROOT}/os-payload.tar.gz"
APPLICATION_CATALOG_ID="demo-apps"
COMPOSER_REVISION="abc123def456"
COMPOSED_AT="2026-03-13T00:00:00Z"
PLATFORM_CONTRACT_SOURCE="https://github.com/techofourown/sw-ourbox-os"
PLATFORM_CONTRACT_DIGEST="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
EXPECTED_AIRGAP_ARCH="amd64"
BAKED_AIRGAP_K3S_VERSION="v1.35.0+k3s1"
BAKED_AIRGAP_PROFILE="demo-apps"

mkdir -p "${AIRGAP_STAGE_DIR}"

cat > "${MERGED_APPLICATION_CATALOG_FILE}" <<'EOF'
{
  "schema": 1,
  "kind": "ourbox-application-catalog",
  "catalog_id": "demo-apps",
  "catalog_name": "Demo Application Catalog",
  "default_app_ids": [
    "landing"
  ],
  "apps": [
    {
      "id": "landing",
      "app_uid": "techofourown/landing",
      "display_name": "Landing",
      "image_names": [
        "landing"
      ]
    }
  ]
}
EOF

cat > "${MERGED_SELECTED_APPLICATIONS_FILE}" <<'EOF'
{
  "schema": 1,
  "kind": "ourbox-selected-applications",
  "catalog_id": "demo-apps",
  "selection_mode": "custom",
  "selected_app_ids": [
    "landing"
  ]
}
EOF

cat > "${MERGED_IMAGES_LOCK_FILE}" <<'EOF'
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

PAYLOAD_ROOT="${TMP_ROOT}/payload-root/airgap"
mkdir -p "${PAYLOAD_ROOT}/k3s" "${PAYLOAD_ROOT}/platform/images"
printf '#!/bin/sh\nexit 0\n' > "${PAYLOAD_ROOT}/k3s/k3s"
chmod +x "${PAYLOAD_ROOT}/k3s/k3s"
printf 'fixture airgap image tar\n' > "${PAYLOAD_ROOT}/k3s/k3s-airgap-images-amd64.tar"
printf 'PROFILE=demo-apps\n' > "${PAYLOAD_ROOT}/platform/profile.env"
printf '{"images":[]}\n' > "${PAYLOAD_ROOT}/platform/images.lock.json"
printf 'fixture image tar\n' > "${PAYLOAD_ROOT}/platform/images/$(image_tar_name "ghcr.io/example/landing@sha256:1111111111111111111111111111111111111111111111111111111111111111")"
cat > "${PAYLOAD_ROOT}/manifest.env" <<'EOF'
OURBOX_AIRGAP_PLATFORM_SOURCE=https://github.com/techofourown/sw-ourbox-os
OURBOX_AIRGAP_PLATFORM_REVISION=abc123def456
OURBOX_AIRGAP_PLATFORM_VERSION=v0.0.1
OURBOX_AIRGAP_PLATFORM_CREATED=2026-03-13T00:00:00Z
OURBOX_PLATFORM_CONTRACT_DIGEST=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
AIRGAP_PLATFORM_ARCH=amd64
K3S_VERSION=v1.35.0+k3s1
OURBOX_PLATFORM_PROFILE=demo-apps
OURBOX_PLATFORM_IMAGES_LOCK_PATH=platform/images.lock.json
OURBOX_PLATFORM_IMAGES_LOCK_SHA256=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
EOF
tar -C "${TMP_ROOT}/payload-root" -czf "${OS_PAYLOAD}" airgap

pull_and_save_image_tar() {
  echo "unexpected image pull in host-composed selected-app bundle smoke" >&2
  exit 1
}

synthesize_selected_application_bundle

EXPECTED_SHA="$(sha256_file "${AIRGAP_STAGE_DIR}/airgap-platform.tar.gz")"
EXPECTED_REF="host-composed.local/application-catalog/${APPLICATION_CATALOG_ID}@sha256:${EXPECTED_SHA}"

[[ "${SELECTED_AIRGAP_PINNED_REF}" == "${EXPECTED_REF}" ]] || {
  echo "unexpected selected airgap ref: ${SELECTED_AIRGAP_PINNED_REF}" >&2
  exit 1
}
[[ "${SELECTED_AIRGAP_DIGEST}" == "sha256:${EXPECTED_SHA}" ]] || {
  echo "unexpected selected airgap digest: ${SELECTED_AIRGAP_DIGEST}" >&2
  exit 1
}
[[ "$(tr -d '\n' < "${AIRGAP_STAGE_DIR}/artifact.ref")" == "${EXPECTED_REF}" ]] || {
  echo "artifact.ref did not match the digest-pinned host-composed bundle ref" >&2
  exit 1
}

printf '[%s] host-composed selected-app bundle smoke passed\n' "$(date -Is)"
