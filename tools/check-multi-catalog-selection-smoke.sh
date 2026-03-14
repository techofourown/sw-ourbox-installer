#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMP_ROOT}"' EXIT
HARNESS_ROOT="${ROOT}"
HARNESS_TMP_ROOT="${TMP_ROOT}"

OURBOX_PREPARE_INSTALLER_LIBRARY_ONLY=1
# shellcheck disable=SC1091
source "${ROOT}/tools/prepare-installer-media.sh"
unset OURBOX_PREPARE_INSTALLER_LIBRARY_ONLY

ROOT="${HARNESS_ROOT}"
TMP_ROOT="${HARNESS_TMP_ROOT}"

# shellcheck disable=SC1091
source <(
  sed -n '/^prompt_yes_no_default_no()/,$p' "${ROOT}/tools/prepare-installer-media.sh" \
    | sed '/^initial_cache_refs=()/,$d'
)

ROOT="${HARNESS_ROOT}"
TMP_ROOT="${HARNESS_TMP_ROOT}"

interactive_selection_enabled() {
  return 0
}

APPLICATION_CATALOG_SOURCES_JSON='[
  {
    "catalog_id": "demo-apps",
    "catalog_name": "Demo Application Catalog",
    "description": "default",
    "artifact_ref": "ghcr.io/example/sw-ourbox-catalog-demo:latest",
    "default_selected": true
  },
  {
    "catalog_id": "hello-world",
    "catalog_name": "Hello World Catalog",
    "description": "secondary",
    "artifact_ref": "ghcr.io/example/sw-ourbox-catalog-hello-world:latest",
    "default_selected": false
  }
]'

AIRGAP_REF=""
AIRGAP_CHANNEL=""
SELECTED_APPLICATION_CATALOG_SOURCES_JSON=""
SELECTED_APPLICATION_CATALOG_SOURCE_DISPLAY=""
determine_application_catalog_sources <<< $'\n'
[[ "${SELECTED_APPLICATION_CATALOG_SOURCES_JSON}" == *'"catalog_id": "demo-apps"'* ]] || {
  echo "expected ENTER to accept the default application catalog source" >&2
  exit 1
}
[[ "${SELECTED_APPLICATION_CATALOG_SOURCES_JSON}" != *'"catalog_id": "hello-world"'* ]] || {
  echo "expected ENTER to keep the default selection to one source" >&2
  exit 1
}

AIRGAP_REF=""
AIRGAP_CHANNEL=""
SELECTED_APPLICATION_CATALOG_SOURCES_JSON=""
SELECTED_APPLICATION_CATALOG_SOURCE_DISPLAY=""
determine_application_catalog_sources <<< $'c\n1,2\n'
[[ "${SELECTED_APPLICATION_CATALOG_SOURCES_JSON}" == *'"catalog_id": "demo-apps"'* ]] || {
  echo "expected interactive source selection to include demo-apps" >&2
  exit 1
}
[[ "${SELECTED_APPLICATION_CATALOG_SOURCES_JSON}" == *'"catalog_id": "hello-world"'* ]] || {
  echo "expected interactive source selection to include hello-world" >&2
  exit 1
}

AIRGAP_REF=""
AIRGAP_CHANNEL="hello-world,demo-apps"
SELECTED_APPLICATION_CATALOG_SOURCES_JSON=""
SELECTED_APPLICATION_CATALOG_SOURCE_DISPLAY=""
determine_application_catalog_sources
[[ "${SELECTED_APPLICATION_CATALOG_SOURCES_JSON}" == *'"catalog_id": "hello-world"'* ]] || {
  echo "expected non-interactive source id selection to include hello-world" >&2
  exit 1
}
[[ "${SELECTED_APPLICATION_CATALOG_SOURCES_JSON}" == *'"catalog_id": "demo-apps"'* ]] || {
  echo "expected non-interactive source id selection to include demo-apps" >&2
  exit 1
}

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
    "landing",
    "hello-world"
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
    },
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
EOF_CATALOG_ONE

cat > "${CATALOG_ONE_DIR}/images.lock.json" <<'EOF_IMAGES_ONE'
{
  "schema": 1,
  "images": [
    {
      "name": "landing",
      "ref": "ghcr.io/example/landing@sha256:1111111111111111111111111111111111111111111111111111111111111111"
    },
    {
      "name": "hello-world",
      "ref": "ghcr.io/example/hello-world@sha256:2222222222222222222222222222222222222222222222222222222222222222"
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
    "catalog_id": "hello-world",
    "catalog_name": "Hello World Catalog",
    "artifact_ref": "ghcr.io/example/sw-ourbox-catalog-hello-world@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "artifact_digest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "catalog_path": "${CATALOG_TWO_DIR}/catalog.json",
    "images_lock_path": "${CATALOG_TWO_DIR}/images.lock.json"
  }
]
EOF_SOURCES

python3 "${ROOT}/tools/merge-application-catalogs.py" \
  --sources-json "${TMP_ROOT}/sources.json" \
  --selection-mode catalog-defaults \
  --out-catalog "${TMP_ROOT}/merged.catalog.json" \
  --out-selected-apps "${TMP_ROOT}/merged.selected-apps.json" \
  --out-images-lock "${TMP_ROOT}/merged.images.lock.json" \
  --out-summary "${TMP_ROOT}/merged.summary.json"

python3 - <<'PY' "${TMP_ROOT}/merged.catalog.json" "${TMP_ROOT}/merged.selected-apps.json" "${TMP_ROOT}/merged.images.lock.json"
import json
import sys

catalog = json.load(open(sys.argv[1], "r", encoding="utf-8"))
selected = json.load(open(sys.argv[2], "r", encoding="utf-8"))
images = json.load(open(sys.argv[3], "r", encoding="utf-8"))

app_ids = [app["id"] for app in catalog["apps"]]
if app_ids.count("techofourown/hello-world") != 1:
    raise SystemExit("expected merged catalog to dedupe hello-world by app_uid")
if "techofourown/landing" not in app_ids:
    raise SystemExit("expected merged catalog to keep the unique landing app")
if selected["selected_app_ids"] != ["techofourown/hello-world", "techofourown/landing"]:
    raise SystemExit("expected merged default app ids to be deterministic and deduped")
if len(images["images"]) != 2:
    raise SystemExit("expected merged images lock to contain deduped selected images")
PY

python3 "${ROOT}/tools/merge-application-catalogs.py" \
  --sources-json "${TMP_ROOT}/sources.json" \
  --selection-mode custom \
  --selected-app-ids "techofourown/hello-world" \
  --out-catalog "${TMP_ROOT}/custom.catalog.json" \
  --out-selected-apps "${TMP_ROOT}/custom.selected-apps.json" \
  --out-images-lock "${TMP_ROOT}/custom.images.lock.json" \
  --out-summary "${TMP_ROOT}/custom.summary.json"

python3 - <<'PY' "${TMP_ROOT}/custom.selected-apps.json" "${TMP_ROOT}/custom.summary.json"
import json
import sys

selected = json.load(open(sys.argv[1], "r", encoding="utf-8"))
summary = json.load(open(sys.argv[2], "r", encoding="utf-8"))

if selected["selected_app_ids"] != ["techofourown/hello-world"]:
    raise SystemExit("expected custom merged selected-apps to contain only the requested app")
if len(summary.get("source_catalogs", [])) != 2:
    raise SystemExit("expected merged summary to retain both source catalogs")
PY
