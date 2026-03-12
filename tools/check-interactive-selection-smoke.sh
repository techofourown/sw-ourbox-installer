#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tools/lib.sh"

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

interactive_selection_enabled() {
  return 0
}

interactive_target_selection_enabled() {
  return 0
}

TARGET=""
determine_target <<< $'\n'
[[ "${TARGET}" == "woodbox" ]] || die "expected ENTER to accept the default target selection"

OS_REPO="ghcr.io/example/ourbox-woodbox-os"
OS_CATALOG_TAG="x86-catalog"
OS_CHANNEL_TAG_STABLE="x86-stable"
OS_CHANNEL_TAG_BETA="x86-beta"
OS_CHANNEL_TAG_NIGHTLY="x86-nightly"
OS_CHANNEL_TAG_EXP_LABS="x86-exp-labs"
OS_REF=""

AIRGAP_REPO="ghcr.io/example/airgap-platform"
AIRGAP_CATALOG_TAG="catalog-amd64"
AIRGAP_CHANNEL_TAG_STABLE="stable-amd64"
AIRGAP_CHANNEL_TAG_BETA="beta-amd64"
AIRGAP_CHANNEL_TAG_NIGHTLY="nightly-amd64"
AIRGAP_CHANNEL_TAG_EXP_LABS="exp-labs-amd64"
EXPECTED_AIRGAP_ARCH="amd64"
AIRGAP_REF=""

CONTRACT_DIGEST="sha256:1111111111111111111111111111111111111111111111111111111111111111"
OS_STABLE_PINNED="ghcr.io/example/ourbox-woodbox-os@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
OS_BETA_PINNED="ghcr.io/example/ourbox-woodbox-os@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
AIRGAP_STABLE_PINNED="ghcr.io/example/airgap-platform@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
AIRGAP_BETA_PINNED="ghcr.io/example/airgap-platform@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
BAKED_AIRGAP_REF="ghcr.io/example/airgap-platform@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"

OS_CATALOG_DIR="${TMP_ROOT}/os-catalog"
AIRGAP_CATALOG_DIR="${TMP_ROOT}/airgap-catalog"
mkdir -p "${OS_CATALOG_DIR}" "${AIRGAP_CATALOG_DIR}"

cat > "${OS_CATALOG_DIR}/catalog.tsv" <<EOF
channel	tag	created	version	platform_contract_digest	pinned_ref
x86-stable	x86-stable	2026-03-12T12:00:00Z	v1.0.0	${CONTRACT_DIGEST}	${OS_STABLE_PINNED}
x86-beta	x86-beta	2026-03-13T12:00:00Z	v1.1.0	${CONTRACT_DIGEST}	${OS_BETA_PINNED}
EOF

cat > "${AIRGAP_CATALOG_DIR}/catalog.tsv" <<EOF
channel	tag	created	version	arch	platform_contract_digest	pinned_ref
stable	stable-amd64	2026-03-12T12:00:00Z	v1.0.0	amd64	${CONTRACT_DIGEST}	${AIRGAP_STABLE_PINNED}
beta	beta-amd64	2026-03-13T12:00:00Z	v1.1.0	amd64	${CONTRACT_DIGEST}	${AIRGAP_BETA_PINNED}
EOF

try_cache_pull_oci_artifact() {
  local ref="$1"
  local _reuse_cache="$2"
  local outvar="$3"
  local catalog_dir=""

  case "${ref}" in
    "${OS_REPO}:${OS_CATALOG_TAG}") catalog_dir="${OS_CATALOG_DIR}" ;;
    "${AIRGAP_REPO}:${AIRGAP_CATALOG_TAG}") catalog_dir="${AIRGAP_CATALOG_DIR}" ;;
    *) die "unexpected cache pull in interactive selection smoke: ${ref}" ;;
  esac

  printf -v "${outvar}" '%s' "${catalog_dir}"
  return 0
}

CACHE_REUSE_ENABLED=0
CACHE_REUSE_DECISION_MADE=0

OS_CHANNEL="stable"
SELECTED_OS_REF=""
SELECTED_OS_SELECTION_SOURCE=""
SELECTED_OS_RELEASE_CHANNEL=""
determine_os_ref <<< $'\n'
[[ "${SELECTED_OS_REF}" == "${OS_STABLE_PINNED}" ]] || die "expected ENTER to accept the default OS selection"
[[ "${SELECTED_OS_SELECTION_SOURCE}" == "catalog" ]] || die "expected default OS selection source to be catalog"
[[ "${SELECTED_OS_RELEASE_CHANNEL}" == "stable" ]] || die "expected default OS release channel to normalize to stable"

OS_CHANNEL="stable"
SELECTED_OS_REF=""
SELECTED_OS_SELECTION_SOURCE=""
SELECTED_OS_RELEASE_CHANNEL=""
determine_os_ref <<< $'l\n1\n'
[[ "${SELECTED_OS_REF}" == "${OS_BETA_PINNED}" ]] || die "expected catalog list selection to choose the first listed OS row"
[[ "${SELECTED_OS_SELECTION_SOURCE}" == "catalog" ]] || die "expected listed OS selection source to be catalog"
[[ "${SELECTED_OS_RELEASE_CHANNEL}" == "beta" ]] || die "expected listed OS release channel to normalize to beta"

AIRGAP_CHANNEL=""
SELECTED_AIRGAP_REF=""
SELECTED_AIRGAP_SELECTION_MODE=""
SELECTED_AIRGAP_SELECTION_SOURCE=""
SELECTED_AIRGAP_RELEASE_CHANNEL=""
determine_airgap_ref "${CONTRACT_DIGEST}" <<< $'\n'
[[ "${SELECTED_AIRGAP_REF}" == "${BAKED_AIRGAP_REF}" ]] || die "expected ENTER to accept the baked airgap default"
[[ "${SELECTED_AIRGAP_SELECTION_MODE}" == "baked-from-selected-os" ]] || die "expected baked airgap selection mode"
[[ "${SELECTED_AIRGAP_SELECTION_SOURCE}" == "baked-os-payload" ]] || die "expected baked airgap selection source"

AIRGAP_CHANNEL=""
SELECTED_AIRGAP_REF=""
SELECTED_AIRGAP_SELECTION_MODE=""
SELECTED_AIRGAP_SELECTION_SOURCE=""
SELECTED_AIRGAP_RELEASE_CHANNEL=""
determine_airgap_ref "${CONTRACT_DIGEST}" <<< $'l\n1\n'
[[ "${SELECTED_AIRGAP_REF}" == "${AIRGAP_BETA_PINNED}" ]] || die "expected airgap catalog list selection to choose the first listed row"
[[ "${SELECTED_AIRGAP_SELECTION_MODE}" == "host-selected" ]] || die "expected listed airgap selection mode to be host-selected"
[[ "${SELECTED_AIRGAP_SELECTION_SOURCE}" == "catalog" ]] || die "expected listed airgap selection source to be catalog"
[[ "${SELECTED_AIRGAP_RELEASE_CHANNEL}" == "beta" ]] || die "expected listed airgap release channel to normalize to beta"

root_backing_disk() {
  printf '/dev/nvme0n1\n'
}

refresh_target_media_candidates() {
  TARGET_MEDIA_CANDIDATES=(/dev/sdb /dev/sdc)
}

print_target_media_candidates() {
  :
}

preferred_byid_for_disk() {
  if [[ "${1:-}" == "/dev/sdb" ]]; then
    printf '/dev/disk/by-id/usb-smoke-target\n'
  fi
}

validate_target_flash_device_or_die() {
  [[ "${1:-}" == "/dev/disk/by-id/usb-smoke-target" ]] || die "unexpected validated flash target: ${1:-missing}"
}

lsblk() {
  return 0
}

FLASH_DEVICE=""
select_target_flash_device_interactive <<< $'1\nSELECT\n'
[[ "${FLASH_DEVICE}" == "/dev/disk/by-id/usb-smoke-target" ]] || die "expected interactive media selection to capture the confirmed by-id target"

printf '[%s] interactive selection smoke passed\n' "$(date -Is)"
