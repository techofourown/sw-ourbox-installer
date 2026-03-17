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
    "release_channel": "stable",
    "default_selected": false
  },
  {
    "catalog_id": "hello-world",
    "catalog_name": "Hello World Catalog",
    "description": "default hello-world catalog",
    "catalog_ref": "ghcr.io/example/sw-ourbox-catalog-hello-world:catalog-amd64",
    "release_channel": "stable",
    "default_selected": false
  }
]'

AIRGAP_REF=""
AIRGAP_CHANNEL=""
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

CATALOG_INDEX_REF="ghcr.io/example/sw-ourbox-catalog-demo:catalog-amd64"
CATALOG_INDEX_CACHE_DIR="${TMP_ROOT}/catalog-index-cache"
mkdir -p "${CATALOG_INDEX_CACHE_DIR}"
cat > "${CATALOG_INDEX_CACHE_DIR}/catalog.tsv" <<'EOF_INDEX'
channel	tag	created	version	revision	arch	platform_contract_digest	platform_profile	platform_images_lock_sha256	artifact_digest	pinned_ref
stable	main-older	2026-03-16T10:00:00Z	v0.1.0	111111111111	amd64	sha256:636af2d46d04b086366e97184d4e257d6c6e7dc75f070758d032cdd3cd4ff976	demo-apps	sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa	sha256:1111111111111111111111111111111111111111111111111111111111111111	ghcr.io/example/sw-ourbox-catalog-demo@sha256:1111111111111111111111111111111111111111111111111111111111111111
stable	main-newer	2026-03-16T11:00:00Z	v0.1.1	222222222222	amd64	sha256:636af2d46d04b086366e97184d4e257d6c6e7dc75f070758d032cdd3cd4ff976	demo-apps	sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb	sha256:2222222222222222222222222222222222222222222222222222222222222222	ghcr.io/example/sw-ourbox-catalog-demo@sha256:2222222222222222222222222222222222222222222222222222222222222222
beta	main-beta	2026-03-16T12:00:00Z	v0.2.0	333333333333	amd64	sha256:636af2d46d04b086366e97184d4e257d6c6e7dc75f070758d032cdd3cd4ff976	demo-apps	sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc	sha256:3333333333333333333333333333333333333333333333333333333333333333	ghcr.io/example/sw-ourbox-catalog-demo@sha256:3333333333333333333333333333333333333333333333333333333333333333
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

PLATFORM_CONTRACT_DIGEST="sha256:636af2d46d04b086366e97184d4e257d6c6e7dc75f070758d032cdd3cd4ff976"
EXPECTED_AIRGAP_ARCH="amd64"
resolved_catalog_ref="$(resolve_application_catalog_bundle_ref_from_catalog "${CATALOG_INDEX_REF}" stable)"
[[ "${resolved_catalog_ref}" == "ghcr.io/example/sw-ourbox-catalog-demo@sha256:2222222222222222222222222222222222222222222222222222222222222222" ]] || {
  echo "expected catalog index resolver to choose the newest matching stable row" >&2
  exit 1
}

printf '[%s] upstream catalog defaults smoke passed\n' "$(date -Is)"
