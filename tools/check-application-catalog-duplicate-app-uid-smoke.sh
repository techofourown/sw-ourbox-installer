#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMP_ROOT}"' EXIT

CATALOG_DIR="${TMP_ROOT}/catalog"
mkdir -p "${CATALOG_DIR}"

cat > "${CATALOG_DIR}/catalog.json" <<'EOF_CATALOG'
{
  "schema": 1,
  "kind": "ourbox-application-catalog",
  "catalog_id": "demo-apps",
  "catalog_name": "Demo Application Catalog",
  "catalog_description": "duplicate app uid fixture",
  "default_app_ids": [
    "landing"
  ],
  "apps": [
    {
      "id": "landing",
      "app_uid": "techofourown/landing",
      "display_name": "Landing A",
      "description": "first landing",
      "renderer": "landing",
      "service_name": "landing-a",
      "service_port": 80,
      "host_template": "{box_host}",
      "path": "/",
      "expected_status": 200,
      "body_marker": "Landing A",
      "route_description": "landing-a",
      "default_backend": true,
      "image_names": [
        "landing-a"
      ]
    },
    {
      "id": "landing-shadow",
      "app_uid": "techofourown/landing",
      "display_name": "Landing B",
      "description": "duplicate stable identity",
      "renderer": "landing",
      "service_name": "landing-b",
      "service_port": 80,
      "host_template": "alt.{box_host}",
      "path": "/",
      "expected_status": 200,
      "body_marker": "Landing B",
      "route_description": "landing-b",
      "default_backend": false,
      "image_names": [
        "landing-b"
      ]
    }
  ]
}
EOF_CATALOG

cat > "${CATALOG_DIR}/images.lock.json" <<'EOF_IMAGES'
{
  "schema": 1,
  "images": [
    {
      "name": "landing-a",
      "ref": "ghcr.io/example/landing-a@sha256:1111111111111111111111111111111111111111111111111111111111111111"
    },
    {
      "name": "landing-b",
      "ref": "ghcr.io/example/landing-b@sha256:2222222222222222222222222222222222222222222222222222222222222222"
    }
  ]
}
EOF_IMAGES

cat > "${TMP_ROOT}/sources.json" <<EOF_SOURCES
[
  {
    "catalog_id": "demo-apps",
    "catalog_name": "Demo Application Catalog",
    "artifact_ref": "ghcr.io/example/sw-ourbox-catalog-demo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "artifact_digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "catalog_path": "${CATALOG_DIR}/catalog.json",
    "images_lock_path": "${CATALOG_DIR}/images.lock.json"
  }
]
EOF_SOURCES

set +e
python3 "${ROOT}/tools/merge-application-catalogs.py" \
  --sources-json "${TMP_ROOT}/sources.json" \
  --selection-mode catalog-defaults \
  --out-catalog "${TMP_ROOT}/merged.catalog.json" \
  --out-selected-apps "${TMP_ROOT}/merged.selected-apps.json" \
  --out-images-lock "${TMP_ROOT}/merged.images.lock.json" \
  --out-summary "${TMP_ROOT}/merged.summary.json" >"${TMP_ROOT}/merge.log" 2>&1
status=$?
set -e

[[ "${status}" -ne 0 ]] || {
  echo "expected merge-application-catalogs.py to reject duplicate canonical app identities" >&2
  exit 1
}

grep -F "duplicate canonical app identity" "${TMP_ROOT}/merge.log" >/dev/null || {
  cat "${TMP_ROOT}/merge.log" >&2
  exit 1
}

printf '[%s] application catalog duplicate app_uid smoke passed\n' "$(date -Is)"
