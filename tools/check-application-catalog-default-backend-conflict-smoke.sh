#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMP_ROOT}"' EXIT

CATALOG_ONE_DIR="${TMP_ROOT}/catalog-one"
CATALOG_TWO_DIR="${TMP_ROOT}/catalog-two"
mkdir -p "${CATALOG_ONE_DIR}" "${CATALOG_TWO_DIR}"

cat > "${CATALOG_ONE_DIR}/catalog.json" <<'EOF_CATALOG_ONE'
{
  "schema": 1,
  "kind": "ourbox-application-catalog",
  "catalog_id": "demo-apps",
  "catalog_name": "Demo Application Catalog",
  "catalog_description": "first catalog",
  "default_app_ids": [
    "landing"
  ],
  "apps": [
    {
      "id": "landing",
      "app_uid": "techofourown/landing",
      "display_name": "Landing",
      "description": "landing page",
      "renderer": "landing",
      "service_name": "landing",
      "service_port": 80,
      "host_template": "{box_host}",
      "path": "/",
      "expected_status": 200,
      "body_marker": "Landing",
      "route_description": "landing-root",
      "default_backend": true,
      "image_names": [
        "landing"
      ]
    }
  ]
}
EOF_CATALOG_ONE

cat > "${CATALOG_ONE_DIR}/images.lock.json" <<'EOF_IMAGES_ONE'
{
  "schema": 1,
  "images": [
    {
      "name": "landing",
      "ref": "ghcr.io/example/landing@sha256:1111111111111111111111111111111111111111111111111111111111111111"
    }
  ]
}
EOF_IMAGES_ONE

cat > "${CATALOG_TWO_DIR}/catalog.json" <<'EOF_CATALOG_TWO'
{
  "schema": 1,
  "kind": "ourbox-application-catalog",
  "catalog_id": "portal-apps",
  "catalog_name": "Portal Application Catalog",
  "catalog_description": "second catalog",
  "default_app_ids": [
    "portal"
  ],
  "apps": [
    {
      "id": "portal",
      "app_uid": "thirdparty/portal",
      "display_name": "Portal",
      "description": "second root candidate",
      "renderer": "landing",
      "service_name": "portal",
      "service_port": 80,
      "host_template": "portal.{box_host}",
      "path": "/",
      "expected_status": 200,
      "body_marker": "Portal",
      "route_description": "portal-root",
      "default_backend": true,
      "image_names": [
        "portal"
      ]
    }
  ]
}
EOF_CATALOG_TWO

cat > "${CATALOG_TWO_DIR}/images.lock.json" <<'EOF_IMAGES_TWO'
{
  "schema": 1,
  "images": [
    {
      "name": "portal",
      "ref": "ghcr.io/example/portal@sha256:2222222222222222222222222222222222222222222222222222222222222222"
    }
  ]
}
EOF_IMAGES_TWO

cat > "${TMP_ROOT}/sources.json" <<EOF_SOURCES
[
  {
    "catalog_id": "demo-apps",
    "catalog_name": "Demo Application Catalog",
    "artifact_ref": "ghcr.io/example/sw-ourbox-catalog-demo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "artifact_digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "catalog_path": "${CATALOG_ONE_DIR}/catalog.json",
    "images_lock_path": "${CATALOG_ONE_DIR}/images.lock.json"
  },
  {
    "catalog_id": "portal-apps",
    "catalog_name": "Portal Application Catalog",
    "artifact_ref": "ghcr.io/example/sw-ourbox-catalog-portal@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "artifact_digest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "catalog_path": "${CATALOG_TWO_DIR}/catalog.json",
    "images_lock_path": "${CATALOG_TWO_DIR}/images.lock.json"
  }
]
EOF_SOURCES

python3 "${ROOT}/tools/merge-application-catalogs.py" \
  --sources-json "${TMP_ROOT}/sources.json" \
  --selection-mode all-apps \
  --out-catalog "${TMP_ROOT}/merged.catalog.json" \
  --out-selected-apps "${TMP_ROOT}/merged.selected-apps.json" \
  --out-images-lock "${TMP_ROOT}/merged.images.lock.json" \
  --out-summary "${TMP_ROOT}/merged.summary.json"

python3 - <<'PY' "${TMP_ROOT}/merged.catalog.json" "${TMP_ROOT}/merged.summary.json"
import json
import sys

catalog = json.load(open(sys.argv[1], "r", encoding="utf-8"))
summary = json.load(open(sys.argv[2], "r", encoding="utf-8"))

default_backends = [app["id"] for app in catalog["apps"] if app.get("default_backend")]
if default_backends != ["techofourown/landing"]:
    raise SystemExit(f"unexpected default backend resolution: {default_backends}")

conflicts = summary.get("conflicts", [])
if len(conflicts) != 1:
    raise SystemExit(f"expected one default-backend conflict record, got {len(conflicts)}")
conflict = conflicts[0]
if conflict.get("type") != "default-backend":
    raise SystemExit(f"unexpected conflict type: {conflict}")
if conflict.get("kept_app_uid") != "techofourown/landing":
    raise SystemExit(f"unexpected kept default backend: {conflict}")
if conflict.get("app_uid") != "thirdparty/portal":
    raise SystemExit(f"unexpected dropped default backend: {conflict}")
if conflict.get("policy") != "first-selected-default-backend-wins":
    raise SystemExit(f"unexpected default backend conflict policy: {conflict}")
PY

printf '[%s] application catalog default-backend conflict smoke passed\n' "$(date -Is)"
