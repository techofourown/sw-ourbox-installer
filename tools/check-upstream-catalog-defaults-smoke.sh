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
  return 1
}

TARGET="woodbox"
CACHE_REUSE_ENABLED=0
INSTALL_DEFAULTS_REF="ghcr.io/example/sw-ourbox-os/install-defaults:stable"
DEFAULTS_CACHE_DIR="${TMP_ROOT}/install-defaults-cache"
DEFAULTS_BUILD_DIR="${TMP_ROOT}/install-defaults-build"
mkdir -p "${DEFAULTS_CACHE_DIR}" "${DEFAULTS_BUILD_DIR}/install-defaults/defaults"

cat > "${DEFAULTS_BUILD_DIR}/install-defaults/defaults/woodbox.env" <<'EOF_DEFAULTS'
APPLICATION_CATALOG_DEFAULT_IDS=demo-apps,hello-world
EOF_DEFAULTS

tar -czf "${DEFAULTS_CACHE_DIR}/install-defaults.tar.gz" -C "${DEFAULTS_BUILD_DIR}" install-defaults

try_cache_pull_oci_artifact() {
  local ref="$1"
  local _reuse="$2"
  local outvar="$3"

  [[ "${ref}" == "${INSTALL_DEFAULTS_REF}" ]] || return 1
  printf -v "${outvar}" '%s' "${DEFAULTS_CACHE_DIR}"
}

load_application_catalog_defaults_from_install_defaults
[[ "${APPLICATION_CATALOG_DEFAULT_IDS}" == "demo-apps,hello-world" ]] || {
  echo "expected install-defaults artifact to supply application catalog default ids" >&2
  exit 1
}

APPLICATION_CATALOG_SOURCES_JSON='[
  {
    "catalog_id": "demo-apps",
    "catalog_name": "Demo Application Catalog",
    "description": "default demo catalog",
    "catalog_ref": "ghcr.io/example/sw-ourbox-catalog-demo:catalog-amd64",
    "release_channel": "stable"
  },
  {
    "catalog_id": "hello-world",
    "catalog_name": "Hello World Catalog",
    "description": "default hello-world catalog",
    "catalog_ref": "ghcr.io/example/sw-ourbox-catalog-hello-world:catalog-amd64",
    "release_channel": "stable"
  }
]'

SUBSTRATE_REF=""
SUBSTRATE_CHANNEL=""
SELECTED_APPLICATION_CATALOG_SOURCES_JSON=""
SELECTED_APPLICATION_CATALOG_SOURCE_DISPLAY=""
determine_application_catalog_sources
[[ "${SELECTED_APPLICATION_CATALOG_SOURCES_JSON}" == *'"catalog_id": "demo-apps"'* ]] || {
  echo "expected upstream default ids to include demo-apps" >&2
  exit 1
}
[[ "${SELECTED_APPLICATION_CATALOG_SOURCES_JSON}" == *'"catalog_id": "hello-world"'* ]] || {
  echo "expected upstream default ids to include hello-world" >&2
  exit 1
}

APPLICATION_CATALOG_DEFAULT_IDS=""
INSTALL_DEFAULTS_REF="ghcr.io/example/sw-ourbox-os/install-defaults-missing:stable"
try_cache_pull_oci_artifact() {
  return 1
}
if (resolve_default_application_catalog_sources_json) >"${TMP_ROOT}/missing-defaults.out" 2>"${TMP_ROOT}/missing-defaults.err"; then
  echo "expected missing upstream install defaults to fail fast" >&2
  exit 1
fi
grep -F "failed to pull upstream install defaults" "${TMP_ROOT}/missing-defaults.err" >/dev/null || {
  echo "expected failure output to mention missing upstream install defaults" >&2
  cat "${TMP_ROOT}/missing-defaults.err" >&2
  exit 1
}

CATALOG_INDEX_REF="ghcr.io/example/sw-ourbox-catalog-demo:catalog-amd64"
CATALOG_INDEX_CACHE_DIR="${TMP_ROOT}/catalog-index-cache"
mkdir -p "${CATALOG_INDEX_CACHE_DIR}"
cat > "${CATALOG_INDEX_CACHE_DIR}/catalog.tsv" <<'EOF_INDEX'
channel	tag	created	version	revision	arch	platform_profile	platform_images_lock_sha256	artifact_digest	pinned_ref
stable	main-older	2026-03-16T10:00:00Z	v0.1.0	111111111111	amd64	demo-apps	sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa	sha256:1111111111111111111111111111111111111111111111111111111111111111	ghcr.io/example/sw-ourbox-catalog-demo@sha256:1111111111111111111111111111111111111111111111111111111111111111
stable	main-newer	2026-03-16T11:00:00Z	v0.1.1	222222222222	amd64	demo-apps	sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb	sha256:2222222222222222222222222222222222222222222222222222222222222222	ghcr.io/example/sw-ourbox-catalog-demo@sha256:2222222222222222222222222222222222222222222222222222222222222222
beta	main-beta	2026-03-16T12:00:00Z	v0.2.0	333333333333	amd64	demo-apps	sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc	sha256:3333333333333333333333333333333333333333333333333333333333333333	ghcr.io/example/sw-ourbox-catalog-demo@sha256:3333333333333333333333333333333333333333333333333333333333333333
EOF_INDEX

cache_pull_oci_artifact() {
  local ref="$1"
  local _reuse="$2"
  local outvar="$3"

  [[ "${ref}" == "${CATALOG_INDEX_REF}" ]] || {
    echo "unexpected cache pull ref: ${ref}" >&2
    return 1
  }
  printf -v "${outvar}" '%s' "${CATALOG_INDEX_CACHE_DIR}"
}

EXPECTED_SUBSTRATE_ARCH="amd64"
INSTALL_DEFAULTS_REF="ghcr.io/example/sw-ourbox-os/install-defaults:stable"
resolved_catalog_ref="$(resolve_application_catalog_bundle_ref_from_catalog "${CATALOG_INDEX_REF}" stable)"
[[ "${resolved_catalog_ref}" == "ghcr.io/example/sw-ourbox-catalog-demo@sha256:2222222222222222222222222222222222222222222222222222222222222222" ]] || {
  echo "expected catalog index resolver to choose the newest matching stable row" >&2
  exit 1
}

CUSTOM_INDEX_REF="ghcr.io/example/custom-catalog:catalog-amd64"
CUSTOM_INDEX_PINNED_REF="ghcr.io/example/custom-catalog@sha256:4444444444444444444444444444444444444444444444444444444444444444"
CUSTOM_BUNDLE_PINNED_REF="ghcr.io/example/custom-catalog@sha256:5555555555555555555555555555555555555555555555555555555555555555"
CUSTOM_INDEX_CACHE_DIR="${TMP_ROOT}/custom-index-cache"
CUSTOM_BUNDLE_CACHE_DIR="${TMP_ROOT}/custom-bundle-cache"
CUSTOM_BUNDLE_BUILD_DIR="${TMP_ROOT}/custom-bundle-build"
PULL_LOG="${TMP_ROOT}/custom-catalog-pulls.log"

mkdir -p "${CUSTOM_INDEX_CACHE_DIR}" "${CUSTOM_BUNDLE_CACHE_DIR}" "${CUSTOM_BUNDLE_BUILD_DIR}/bundle"
: > "${PULL_LOG}"

cat > "${CUSTOM_INDEX_CACHE_DIR}/catalog.tsv" <<EOF_CUSTOM_INDEX
channel	tag	created	version	revision	arch	platform_profile	platform_images_lock_sha256	artifact_digest	pinned_ref
stable	main	2026-03-16T13:00:00Z	v0.3.0	444444444444	amd64	custom	sha256:6666666666666666666666666666666666666666666666666666666666666666	sha256:5555555555555555555555555555555555555555555555555555555555555555	${CUSTOM_BUNDLE_PINNED_REF}
EOF_CUSTOM_INDEX

cat > "${CUSTOM_BUNDLE_BUILD_DIR}/bundle/catalog.json" <<'EOF_CUSTOM_CATALOG'
{
  "schema": 1,
  "kind": "ourbox-application-catalog",
  "catalog_id": "custom-catalog",
  "catalog_name": "Custom Catalog",
  "catalog_description": "custom",
  "default_app_ids": [
    "custom-app"
  ],
  "apps": [
    {
      "id": "custom-app",
      "app_uid": "example/custom-app",
      "display_name": "Custom App",
      "description": "custom app",
      "service_name": "custom-app",
      "service_port": 8080,
      "host_template": "custom.{box_host}",
      "path": "/",
      "expected_status": 200,
      "body_marker": "Custom App",
      "route_description": "custom-app-root",
      "default_backend": false,
      "image_names": [
        "custom-app"
      ]
    }
  ]
}
EOF_CUSTOM_CATALOG

cat > "${CUSTOM_BUNDLE_BUILD_DIR}/bundle/images.lock.json" <<'EOF_CUSTOM_IMAGES'
{
  "schema": 1,
  "images": [
    {
      "name": "custom-app",
      "ref": "ghcr.io/example/custom-app@sha256:6666666666666666666666666666666666666666666666666666666666666666"
    }
  ]
}
EOF_CUSTOM_IMAGES

printf '\n' > "${CUSTOM_BUNDLE_BUILD_DIR}/bundle/manifest.env"

cat > "${CUSTOM_BUNDLE_BUILD_DIR}/bundle/profile.env" <<'EOF_CUSTOM_PROFILE'
OURBOX_PROFILE=custom
EOF_CUSTOM_PROFILE

tar -czf "${CUSTOM_BUNDLE_CACHE_DIR}/application-catalog-bundle.tar.gz" -C "${CUSTOM_BUNDLE_BUILD_DIR}/bundle" .
sha256sum "${CUSTOM_BUNDLE_CACHE_DIR}/application-catalog-bundle.tar.gz" > "${CUSTOM_BUNDLE_CACHE_DIR}/application-catalog-bundle.tar.gz.sha256"

cache_pull_oci_artifact() {
  local ref="$1"
  local _reuse="$2"
  local outvar="$3"

  printf '%s\n' "${ref}" >> "${PULL_LOG}"
  case "${ref}" in
    "${CUSTOM_INDEX_REF}"|"${CUSTOM_INDEX_PINNED_REF}")
      OURBOX_CACHE_LAST_PINNED_REF="${CUSTOM_INDEX_PINNED_REF}"
      OURBOX_CACHE_LAST_DIGEST="${CUSTOM_INDEX_PINNED_REF##*@}"
      printf -v "${outvar}" '%s' "${CUSTOM_INDEX_CACHE_DIR}"
      ;;
    "${CUSTOM_BUNDLE_PINNED_REF}")
      OURBOX_CACHE_LAST_PINNED_REF="${CUSTOM_BUNDLE_PINNED_REF}"
      OURBOX_CACHE_LAST_DIGEST="${CUSTOM_BUNDLE_PINNED_REF##*@}"
      printf -v "${outvar}" '%s' "${CUSTOM_BUNDLE_CACHE_DIR}"
      ;;
    *)
      echo "unexpected cache pull ref: ${ref}" >&2
      return 1
      ;;
  esac
}

SELECTED_APPLICATION_CATALOG_SOURCES_JSON="$(parse_custom_application_catalog_refs_json "${CUSTOM_INDEX_REF}")"
APPLICATION_SOURCE_RESOLUTIONS_JSON="{}"
prepare_merged_application_catalog "catalog-defaults" "[]"

python3 - <<'PY' "${MERGED_APPLICATION_SUMMARY_FILE}" "${CUSTOM_BUNDLE_PINNED_REF}"
import json
import sys

summary = json.load(open(sys.argv[1], "r", encoding="utf-8"))
source_catalogs = summary.get("source_catalogs", [])
if len(source_catalogs) != 1:
    raise SystemExit("expected one merged source catalog after custom index resolution")
source = source_catalogs[0]
if source.get("catalog_id") != "custom-catalog":
    raise SystemExit(f"unexpected merged catalog id: {source.get('catalog_id')!r}")
if source.get("artifact_ref") != sys.argv[2]:
    raise SystemExit(f"expected merged source artifact_ref to be {sys.argv[2]!r}, got {source.get('artifact_ref')!r}")
if summary.get("selected_app_ids") != ["example/custom-app"]:
    raise SystemExit(f"unexpected selected app ids: {summary.get('selected_app_ids')!r}")
PY

mapfile -t custom_pull_refs < "${PULL_LOG}"
[[ "${#custom_pull_refs[@]}" -eq 3 ]] || {
  echo "expected custom catalog resolution to perform three pulls" >&2
  exit 1
}
[[ "${custom_pull_refs[0]}" == "${CUSTOM_INDEX_REF}" ]] || {
  echo "expected the first pull to use the operator-provided custom catalog ref" >&2
  exit 1
}
[[ "${custom_pull_refs[1]}" == "${CUSTOM_INDEX_PINNED_REF}" ]] || {
  echo "expected the resolver to inspect the pinned custom catalog index" >&2
  exit 1
}
[[ "${custom_pull_refs[2]}" == "${CUSTOM_BUNDLE_PINNED_REF}" ]] || {
  echo "expected the final pull to use the resolved custom catalog bundle ref" >&2
  exit 1
}

MISMATCH_LATEST_REF="ghcr.io/example/custom-catalog:latest"
MISMATCH_LATEST_PINNED_REF="ghcr.io/example/custom-catalog@sha256:7777777777777777777777777777777777777777777777777777777777777777"
MISMATCH_BUNDLE_CACHE_DIR="${TMP_ROOT}/mismatch-bundle-cache"
MISMATCH_BUNDLE_BUILD_DIR="${TMP_ROOT}/mismatch-bundle-build"
mkdir -p "${MISMATCH_BUNDLE_CACHE_DIR}" "${MISMATCH_BUNDLE_BUILD_DIR}/bundle"

cat > "${MISMATCH_BUNDLE_BUILD_DIR}/bundle/catalog.json" <<'EOF_MISMATCH_CATALOG'
{
  "schema": 1,
  "kind": "ourbox-application-catalog",
  "catalog_id": "custom-catalog",
  "catalog_name": "Custom Catalog",
  "catalog_description": "custom",
  "default_app_ids": [
    "custom-app"
  ],
  "apps": [
    {
      "id": "custom-app",
      "app_uid": "example/custom-app",
      "display_name": "Custom App",
      "description": "custom app",
      "service_name": "custom-app",
      "service_port": 8080,
      "host_template": "custom.{box_host}",
      "path": "/",
      "expected_status": 200,
      "body_marker": "Custom App",
      "route_description": "custom-app-root",
      "default_backend": false,
      "image_names": [
        "custom-app"
      ]
    }
  ]
}
EOF_MISMATCH_CATALOG

cat > "${MISMATCH_BUNDLE_BUILD_DIR}/bundle/images.lock.json" <<'EOF_MISMATCH_IMAGES'
{
  "schema": 1,
  "images": [
    {
      "name": "custom-app",
      "ref": "ghcr.io/example/custom-app@sha256:8888888888888888888888888888888888888888888888888888888888888888"
    }
  ]
}
EOF_MISMATCH_IMAGES

printf '\n' > "${MISMATCH_BUNDLE_BUILD_DIR}/bundle/manifest.env"

cat > "${MISMATCH_BUNDLE_BUILD_DIR}/bundle/profile.env" <<'EOF_MISMATCH_PROFILE'
OURBOX_PROFILE=custom
EOF_MISMATCH_PROFILE

tar -czf "${MISMATCH_BUNDLE_CACHE_DIR}/application-catalog-bundle.tar.gz" -C "${MISMATCH_BUNDLE_BUILD_DIR}/bundle" .
sha256sum "${MISMATCH_BUNDLE_CACHE_DIR}/application-catalog-bundle.tar.gz" > "${MISMATCH_BUNDLE_CACHE_DIR}/application-catalog-bundle.tar.gz.sha256"

cache_pull_oci_artifact() {
  local ref="$1"
  local _reuse="$2"
  local outvar="$3"

  [[ "${ref}" == "${MISMATCH_LATEST_REF}" ]] || {
    echo "unexpected cache pull ref: ${ref}" >&2
    return 1
  }

  OURBOX_CACHE_LAST_PINNED_REF="${MISMATCH_LATEST_PINNED_REF}"
  OURBOX_CACHE_LAST_DIGEST="${MISMATCH_LATEST_PINNED_REF##*@}"
  printf -v "${outvar}" '%s' "${MISMATCH_BUNDLE_CACHE_DIR}"
}

SELECTED_APPLICATION_CATALOG_SOURCES_JSON="$(parse_custom_application_catalog_refs_json "${MISMATCH_LATEST_REF}")"
APPLICATION_SOURCE_RESOLUTIONS_JSON="{}"
prepare_merged_application_catalog "catalog-defaults" "[]"

python3 - <<'PY' "${MERGED_APPLICATION_SUMMARY_FILE}" "${MISMATCH_LATEST_PINNED_REF}"
import json
import sys

summary = json.load(open(sys.argv[1], "r", encoding="utf-8"))
source_catalogs = summary.get("source_catalogs", [])
if len(source_catalogs) != 1:
    raise SystemExit("expected one merged source catalog after direct bundle resolution")
source = source_catalogs[0]
if source.get("artifact_ref") != sys.argv[2]:
    raise SystemExit(f"expected direct bundle artifact_ref to be {sys.argv[2]!r}, got {source.get('artifact_ref')!r}")
PY

printf '[%s] upstream catalog defaults smoke passed\n' "$(date -Is)"
