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
  "catalog_description": "demo",
  "default_app_ids": [
    "landing"
  ],
  "apps": [
    {
      "id": "landing",
      "app_uid": "techofourown/landing",
      "display_name": "Landing",
      "description": "landing",
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
  "catalog_id": "hello-world",
  "catalog_name": "Hello World Catalog",
  "catalog_description": "hello",
  "default_app_ids": [
    "hello-world"
  ],
  "apps": [
    {
      "id": "hello-world",
      "app_uid": "techofourown/hello-world",
      "display_name": "Hello World",
      "description": "hello",
      "renderer": "hello-world",
      "service_name": "hello-world",
      "service_port": 80,
      "host_template": "hello.{box_host}",
      "path": "/",
      "expected_status": 200,
      "body_marker": "Hello, world.",
      "route_description": "hello-world-root",
      "default_backend": false,
      "image_names": [
        "hello-world"
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
      "name": "hello-world",
      "ref": "ghcr.io/example/hello-world@sha256:2222222222222222222222222222222222222222222222222222222222222222"
    }
  ]
}
EOF_IMAGES_TWO

cat > "${TMP_ROOT}/sources-order-a.json" <<EOF_SOURCES_A
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
    "catalog_id": "hello-world",
    "catalog_name": "Hello World Catalog",
    "artifact_ref": "ghcr.io/example/sw-ourbox-catalog-hello-world@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "artifact_digest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "catalog_path": "${CATALOG_TWO_DIR}/catalog.json",
    "images_lock_path": "${CATALOG_TWO_DIR}/images.lock.json"
  }
]
EOF_SOURCES_A

cat > "${TMP_ROOT}/sources-order-b.json" <<EOF_SOURCES_B
[
  {
    "catalog_id": "hello-world",
    "catalog_name": "Hello World Catalog",
    "artifact_ref": "ghcr.io/example/sw-ourbox-catalog-hello-world@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "artifact_digest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "catalog_path": "${CATALOG_TWO_DIR}/catalog.json",
    "images_lock_path": "${CATALOG_TWO_DIR}/images.lock.json"
  },
  {
    "catalog_id": "demo-apps",
    "catalog_name": "Demo Application Catalog",
    "artifact_ref": "ghcr.io/example/sw-ourbox-catalog-demo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "artifact_digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "catalog_path": "${CATALOG_ONE_DIR}/catalog.json",
    "images_lock_path": "${CATALOG_ONE_DIR}/images.lock.json"
  }
]
EOF_SOURCES_B

python3 "${ROOT}/tools/merge-application-catalogs.py" \
  --sources-json "${TMP_ROOT}/sources-order-a.json" \
  --selection-mode all-apps \
  --out-catalog "${TMP_ROOT}/a.catalog.json" \
  --out-selected-apps "${TMP_ROOT}/a.selected-apps.json" \
  --out-images-lock "${TMP_ROOT}/a.images.lock.json" \
  --out-summary "${TMP_ROOT}/a.summary.json"

python3 "${ROOT}/tools/merge-application-catalogs.py" \
  --sources-json "${TMP_ROOT}/sources-order-b.json" \
  --selection-mode all-apps \
  --out-catalog "${TMP_ROOT}/b.catalog.json" \
  --out-selected-apps "${TMP_ROOT}/b.selected-apps.json" \
  --out-images-lock "${TMP_ROOT}/b.images.lock.json" \
  --out-summary "${TMP_ROOT}/b.summary.json"

cmp "${TMP_ROOT}/a.catalog.json" "${TMP_ROOT}/b.catalog.json"
cmp "${TMP_ROOT}/a.selected-apps.json" "${TMP_ROOT}/b.selected-apps.json"
cmp "${TMP_ROOT}/a.images.lock.json" "${TMP_ROOT}/b.images.lock.json"
cmp "${TMP_ROOT}/a.summary.json" "${TMP_ROOT}/b.summary.json"

python3 - <<'PY' "${TMP_ROOT}/a.summary.json"
import json
import sys

summary = json.load(open(sys.argv[1], "r", encoding="utf-8"))
expected_catalogs = ["demo-apps", "hello-world"]
actual_catalogs = [item["catalog_id"] for item in summary["source_catalogs"]]
if actual_catalogs != expected_catalogs:
    raise SystemExit(f"expected canonical source catalog order {expected_catalogs}, got {actual_catalogs}")
if summary["selected_app_ids"] != ["techofourown/hello-world", "techofourown/landing"]:
    raise SystemExit(f"unexpected deterministic selected_app_ids ordering: {summary['selected_app_ids']}")
PY

printf '[%s] merged catalog determinism smoke passed\n' "$(date -Is)"
