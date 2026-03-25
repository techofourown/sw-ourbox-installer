#!/usr/bin/env bash
set -euo pipefail

HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARNESS_TMP_ROOT="$(mktemp -d)"
ROOT="${HARNESS_ROOT}"
TMP_ROOT="${HARNESS_TMP_ROOT}"
trap 'rm -rf "${HARNESS_TMP_ROOT}"' EXIT

OURBOX_PREPARE_INSTALLER_LIBRARY_ONLY=1
# shellcheck disable=SC1091
source "${ROOT}/tools/prepare-installer-media.sh"
unset OURBOX_PREPARE_INSTALLER_LIBRARY_ONLY

# Load the post-guard helper functions without executing the main body.
# shellcheck disable=SC1091
source <(
  sed -n '/^application_catalog_source_display_from_json()/,$p' "${ROOT}/tools/prepare-installer-media.sh" \
    | sed '/^initial_cache_refs=()/,$d'
)

ROOT="${HARNESS_ROOT}"
TMP_ROOT="${HARNESS_TMP_ROOT}"

MISSION_ROOT="${TMP_ROOT}/mission"
SUBSTRATE_STAGE_DIR="${MISSION_ROOT}/artifacts/substrate"
MERGED_APPLICATION_CATALOG_FILE="${TMP_ROOT}/merged.catalog.json"
MERGED_SELECTED_APPLICATIONS_FILE="${TMP_ROOT}/merged.selected-apps.json"
MERGED_IMAGES_LOCK_FILE="${TMP_ROOT}/merged.images.lock.json"
OS_PAYLOAD="${TMP_ROOT}/os-payload.tar.gz"
APPLICATION_CATALOG_ID="demo-apps"
COMPOSER_REVISION="abc123def456"
COMPOSED_AT="2026-03-13T00:00:00Z"
EXPECTED_SUBSTRATE_ARCH="amd64"
BAKED_SUBSTRATE_K3S_VERSION="v1.35.0+k3s1"
BAKED_SUBSTRATE_PROFILE="demo-apps"

mkdir -p "${SUBSTRATE_STAGE_DIR}"

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

PAYLOAD_ARCHIVE_ROOT="${TMP_ROOT}/payload-root"
PAYLOAD_ROOT="${PAYLOAD_ARCHIVE_ROOT}/substrate"
mkdir -p "${PAYLOAD_ROOT}/k3s" "${PAYLOAD_ROOT}/platform/images"
printf '#!/bin/sh\nexit 0\n' > "${PAYLOAD_ROOT}/k3s/k3s"
chmod +x "${PAYLOAD_ROOT}/k3s/k3s"
printf 'fixture k3s image tar\n' > "${PAYLOAD_ROOT}/k3s/k3s-images-amd64.tar"
printf 'PROFILE=demo-apps\n' > "${PAYLOAD_ROOT}/platform/profile.env"
printf '{"images":[]}\n' > "${PAYLOAD_ROOT}/platform/images.lock.json"
printf 'fixture image tar\n' > "${PAYLOAD_ROOT}/platform/images/$(image_tar_name "ghcr.io/example/landing@sha256:1111111111111111111111111111111111111111111111111111111111111111")"
cat > "${PAYLOAD_ROOT}/manifest.env" <<'EOF'
OURBOX_SUBSTRATE_SOURCE=https://github.com/techofourown/sw-ourbox-os
OURBOX_SUBSTRATE_REVISION=abc123def456
OURBOX_SUBSTRATE_VERSION=v0.0.1
OURBOX_SUBSTRATE_CREATED=2026-03-13T00:00:00Z
OURBOX_SUBSTRATE_ARCH=amd64
K3S_VERSION=v1.35.0+k3s1
OURBOX_PLATFORM_PROFILE=demo-apps
OURBOX_PLATFORM_IMAGES_LOCK_PATH=platform/images.lock.json
OURBOX_PLATFORM_IMAGES_LOCK_SHA256=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
EOF
mkdir -p "${PAYLOAD_ARCHIVE_ROOT}/rootfs"
printf 'fixture payload metadata\n' > "${PAYLOAD_ARCHIVE_ROOT}/payload.meta.env"
tar -C "${PAYLOAD_ARCHIVE_ROOT}" -czf "${OS_PAYLOAD}" .

pull_and_save_image_tar() {
  echo "unexpected image pull in host-composed selected-app bundle smoke" >&2
  exit 1
}

synthesize_selected_application_bundle

EXPECTED_SHA="$(sha256_file "${SUBSTRATE_STAGE_DIR}/ourbox-substrate.tar.gz")"
EXPECTED_REF="host-composed.local/application-catalog/${APPLICATION_CATALOG_ID}@sha256:${EXPECTED_SHA}"

[[ "${SELECTED_SUBSTRATE_PINNED_REF}" == "${EXPECTED_REF}" ]] || {
  echo "unexpected selected substrate ref: ${SELECTED_SUBSTRATE_PINNED_REF}" >&2
  exit 1
}
[[ "${SELECTED_SUBSTRATE_DIGEST}" == "sha256:${EXPECTED_SHA}" ]] || {
  echo "unexpected selected substrate digest: ${SELECTED_SUBSTRATE_DIGEST}" >&2
  exit 1
}
[[ "$(tr -d '\n' < "${SUBSTRATE_STAGE_DIR}/artifact.ref")" == "${EXPECTED_REF}" ]] || {
  echo "artifact.ref did not match the digest-pinned host-composed bundle ref" >&2
  exit 1
}

printf '[%s] host-composed selected-app bundle smoke passed\n' "$(date -Is)"
