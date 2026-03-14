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
  "catalog_id": "catalog-a",
  "catalog_name": "Catalog A",
  "catalog_description": "first",
  "default_app_ids": [
    "hello-world"
  ],
  "apps": [
    {
      "id": "hello-world",
      "app_uid": "techofourown/hello-world",
      "display_name": "Hello World",
      "description": "first copy",
      "renderer": "hello-world",
      "service_name": "hello-world-a",
      "service_port": 80,
      "host_template": "hello.{box_host}",
      "path": "/",
      "expected_status": 200,
      "body_marker": "Hello from A",
      "route_description": "hello-a",
      "default_backend": false,
      "image_names": [
        "hello-world"
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
      "name": "hello-world",
      "ref": "ghcr.io/example/hello-world@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    }
  ]
}
EOF_IMAGES_ONE

cat > "${CATALOG_TWO_DIR}/catalog.json" <<'EOF_CATALOG_TWO'
{
  "schema": 1,
  "kind": "ourbox-application-catalog",
  "catalog_id": "catalog-b",
  "catalog_name": "Catalog B",
  "catalog_description": "second",
  "default_app_ids": [
    "hello-world"
  ],
  "apps": [
    {
      "id": "hello-world",
      "app_uid": "techofourown/hello-world",
      "display_name": "Hello World",
      "description": "second copy",
      "renderer": "hello-world",
      "service_name": "hello-world-b",
      "service_port": 80,
      "host_template": "hello.{box_host}",
      "path": "/",
      "expected_status": 200,
      "body_marker": "Hello from B",
      "route_description": "hello-b",
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
      "ref": "ghcr.io/example/hello-world@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    }
  ]
}
EOF_IMAGES_TWO

cat > "${TMP_ROOT}/sources.json" <<EOF_SOURCES
[
  {
    "catalog_id": "catalog-b",
    "catalog_name": "Catalog B",
    "artifact_ref": "ghcr.io/example/sw-ourbox-catalog-b@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "artifact_digest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "catalog_path": "${CATALOG_TWO_DIR}/catalog.json",
    "images_lock_path": "${CATALOG_TWO_DIR}/images.lock.json"
  },
  {
    "catalog_id": "catalog-a",
    "catalog_name": "Catalog A",
    "artifact_ref": "ghcr.io/example/sw-ourbox-catalog-a@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "artifact_digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "catalog_path": "${CATALOG_ONE_DIR}/catalog.json",
    "images_lock_path": "${CATALOG_ONE_DIR}/images.lock.json"
  }
]
EOF_SOURCES

python3 "${ROOT}/tools/merge-application-catalogs.py" \
  --sources-json "${TMP_ROOT}/sources.json" \
  --selection-mode catalog-defaults \
  --out-duplicates "${TMP_ROOT}/duplicates.json" \
  --out-catalog "${TMP_ROOT}/merged.catalog.json" \
  --out-selected-apps "${TMP_ROOT}/merged.selected-apps.json" \
  --out-images-lock "${TMP_ROOT}/merged.images.lock.json" \
  --out-summary "${TMP_ROOT}/merged.summary.json" >"${TMP_ROOT}/missing-resolution.log" 2>&1 && {
  echo "expected merge to fail without an explicit duplicate app source choice" >&2
  exit 1
}

grep -F "duplicate application source choices are required" "${TMP_ROOT}/missing-resolution.log" >/dev/null || {
  cat "${TMP_ROOT}/missing-resolution.log" >&2
  exit 1
}

python3 "${ROOT}/tools/merge-application-catalogs.py" \
  --sources-json "${TMP_ROOT}/sources.json" \
  --selection-mode catalog-defaults \
  --source-resolutions-json '{"techofourown/hello-world":"catalog-a"}' \
  --out-duplicates "${TMP_ROOT}/duplicates.json" \
  --out-catalog "${TMP_ROOT}/merged.catalog.json" \
  --out-selected-apps "${TMP_ROOT}/merged.selected-apps.json" \
  --out-images-lock "${TMP_ROOT}/merged.images.lock.json" \
  --out-summary "${TMP_ROOT}/merged.summary.json"

python3 - <<'PY' "${TMP_ROOT}/merged.catalog.json" "${TMP_ROOT}/merged.summary.json"
import json
import sys

catalog = json.load(open(sys.argv[1], "r", encoding="utf-8"))
summary = json.load(open(sys.argv[2], "r", encoding="utf-8"))

app = catalog["apps"][0]
if app["service_name"] != "hello-world-a":
    raise SystemExit(f"expected explicit source selection to choose catalog-a, got {app['service_name']}")
if app["body_marker"] != "Hello from A":
    raise SystemExit(f"expected explicit source selection to choose catalog-a payload, got {app['body_marker']}")
if app["selected_source_catalog_id"] != "catalog-a":
    raise SystemExit(f"expected selected_source_catalog_id catalog-a, got {app['selected_source_catalog_id']}")
conflicts = summary.get("conflicts", [])
if len(conflicts) != 1:
    raise SystemExit(f"expected one conflict record, got {len(conflicts)}")
conflict = conflicts[0]
if conflict["policy"] != "operator-selected-source":
    raise SystemExit(f"unexpected conflict policy: {conflict['policy']}")
if conflict["selected_catalog_id"] != "catalog-a":
    raise SystemExit(f"unexpected selected catalog: {conflict}")
if conflict["available_catalog_ids"] != ["catalog-a", "catalog-b"]:
    raise SystemExit(f"unexpected available catalogs: {conflict}")
PY

printf '[%s] application catalog conflict-policy smoke passed\n' "$(date -Is)"
