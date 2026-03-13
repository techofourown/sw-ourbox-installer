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

make_pinned_ref() {
  local repo="$1"
  local value="$2"

  printf '%s@sha256:%064x\n' "${repo}" "${value}"
}

CONTRACT_DIGEST="sha256:1111111111111111111111111111111111111111111111111111111111111111"
OS_STABLE_PINNED="$(make_pinned_ref "${OS_REPO}" 100)"
OS_BETA_PINNED="$(make_pinned_ref "${OS_REPO}" 101)"
OS_PAGE2_SELECTED_PINNED="$(make_pinned_ref "${OS_REPO}" 102)"
AIRGAP_STABLE_PINNED="$(make_pinned_ref "${AIRGAP_REPO}" 200)"
AIRGAP_BETA_PINNED="$(make_pinned_ref "${AIRGAP_REPO}" 201)"
AIRGAP_PAGE2_SELECTED_PINNED="$(make_pinned_ref "${AIRGAP_REPO}" 202)"
BAKED_AIRGAP_REF="$(make_pinned_ref "${AIRGAP_REPO}" 299)"

OS_CATALOG_DIR="${TMP_ROOT}/os-catalog"
AIRGAP_CATALOG_DIR="${TMP_ROOT}/airgap-catalog"
mkdir -p "${OS_CATALOG_DIR}" "${AIRGAP_CATALOG_DIR}"

{
  echo $'channel\ttag\tcreated\tversion\tplatform_contract_digest\tpinned_ref'
  printf 'x86-beta\tx86-beta\t2026-03-13T12:00:00Z\tv1.1.0\t%s\t%s\n' "${CONTRACT_DIGEST}" "${OS_BETA_PINNED}"
  printf 'x86-stable\tx86-stable\t2026-03-12T12:00:00\tv1.0.0\t%s\t%s\n' "${CONTRACT_DIGEST}" "${OS_STABLE_PINNED}"
  printf 'x86-nightly\tx86-nightly\t2026-03-11T12:00:00Z\tv0.11.0\t%s\t%s\n' "${CONTRACT_DIGEST}" "$(make_pinned_ref "${OS_REPO}" 111)"
  printf 'x86-exp-labs\tx86-exp-labs\t2026-03-10T12:00:00Z\tv0.10.0\t%s\t%s\n' "${CONTRACT_DIGEST}" "$(make_pinned_ref "${OS_REPO}" 110)"
  printf 'x86-stable\tx86-stable-older-1\t2026-03-09T12:00:00Z\tv0.9.0\t%s\t%s\n' "${CONTRACT_DIGEST}" "$(make_pinned_ref "${OS_REPO}" 109)"
  printf 'x86-beta\tx86-beta-older-1\t2026-03-08T12:00:00Z\tv0.8.0\t%s\t%s\n' "${CONTRACT_DIGEST}" "$(make_pinned_ref "${OS_REPO}" 108)"
  printf 'x86-nightly\tx86-nightly-older-1\t2026-03-07T12:00:00Z\tv0.7.0\t%s\t%s\n' "${CONTRACT_DIGEST}" "$(make_pinned_ref "${OS_REPO}" 107)"
  printf 'x86-exp-labs\tx86-exp-labs-older-1\t2026-03-06T12:00:00Z\tv0.6.0\t%s\t%s\n' "${CONTRACT_DIGEST}" "$(make_pinned_ref "${OS_REPO}" 106)"
  printf 'x86-stable\tx86-stable-older-2\t2026-03-05T12:00:00Z\tv0.5.0\t%s\t%s\n' "${CONTRACT_DIGEST}" "$(make_pinned_ref "${OS_REPO}" 105)"
  printf 'x86-beta\tx86-beta-older-2\t2026-03-04T12:00:00Z\tv0.4.0\t%s\t%s\n' "${CONTRACT_DIGEST}" "$(make_pinned_ref "${OS_REPO}" 104)"
  printf 'x86-nightly\tx86-nightly-older-2\t2026-03-03T12:00:00Z\tv0.3.0\t%s\t%s\n' "${CONTRACT_DIGEST}" "$(make_pinned_ref "${OS_REPO}" 103)"
  printf 'x86-exp-labs\tx86-exp-labs-older-2\t2026-03-02T12:00:00Z\tv0.2.0\t%s\t%s\n' "${CONTRACT_DIGEST}" "${OS_PAGE2_SELECTED_PINNED}"
  printf 'x86-stable\tx86-stable-oldest\t2026-03-01T12:00:00\tv0.1.0\t%s\t%s\n' "${CONTRACT_DIGEST}" "$(make_pinned_ref "${OS_REPO}" 100)"
} > "${OS_CATALOG_DIR}/catalog.tsv"

{
  echo $'channel\ttag\tcreated\tversion\tarch\tplatform_contract_digest\tpinned_ref'
  printf 'beta\tbeta-amd64\t2026-03-13T12:00:00Z\tv1.1.0\tamd64\t%s\t%s\n' "${CONTRACT_DIGEST}" "${AIRGAP_BETA_PINNED}"
  printf 'stable\tstable-amd64\t2026-03-12T12:00:00\tv1.0.0\tamd64\t%s\t%s\n' "${CONTRACT_DIGEST}" "${AIRGAP_STABLE_PINNED}"
  printf 'nightly\tnightly-amd64\t2026-03-11T12:00:00Z\tv0.11.0\tamd64\t%s\t%s\n' "${CONTRACT_DIGEST}" "$(make_pinned_ref "${AIRGAP_REPO}" 211)"
  printf 'exp-labs\texp-labs-amd64\t2026-03-10T12:00:00Z\tv0.10.0\tamd64\t%s\t%s\n' "${CONTRACT_DIGEST}" "$(make_pinned_ref "${AIRGAP_REPO}" 210)"
  printf 'stable\tstable-amd64-older-1\t2026-03-09T12:00:00Z\tv0.9.0\tamd64\t%s\t%s\n' "${CONTRACT_DIGEST}" "$(make_pinned_ref "${AIRGAP_REPO}" 209)"
  printf 'beta\tbeta-amd64-older-1\t2026-03-08T12:00:00Z\tv0.8.0\tamd64\t%s\t%s\n' "${CONTRACT_DIGEST}" "$(make_pinned_ref "${AIRGAP_REPO}" 208)"
  printf 'nightly\tnightly-amd64-older-1\t2026-03-07T12:00:00Z\tv0.7.0\tamd64\t%s\t%s\n' "${CONTRACT_DIGEST}" "$(make_pinned_ref "${AIRGAP_REPO}" 207)"
  printf 'exp-labs\texp-labs-amd64-older-1\t2026-03-06T12:00:00Z\tv0.6.0\tamd64\t%s\t%s\n' "${CONTRACT_DIGEST}" "$(make_pinned_ref "${AIRGAP_REPO}" 206)"
  printf 'stable\tstable-amd64-older-2\t2026-03-05T12:00:00Z\tv0.5.0\tamd64\t%s\t%s\n' "${CONTRACT_DIGEST}" "$(make_pinned_ref "${AIRGAP_REPO}" 205)"
  printf 'beta\tbeta-amd64-older-2\t2026-03-04T12:00:00Z\tv0.4.0\tamd64\t%s\t%s\n' "${CONTRACT_DIGEST}" "$(make_pinned_ref "${AIRGAP_REPO}" 204)"
  printf 'nightly\tnightly-amd64-older-2\t2026-03-03T12:00:00Z\tv0.3.0\tamd64\t%s\t%s\n' "${CONTRACT_DIGEST}" "$(make_pinned_ref "${AIRGAP_REPO}" 203)"
  printf 'exp-labs\texp-labs-amd64-older-2\t2026-03-02T12:00:00Z\tv0.2.0\tamd64\t%s\t%s\n' "${CONTRACT_DIGEST}" "${AIRGAP_PAGE2_SELECTED_PINNED}"
  printf 'stable\tstable-amd64-oldest\t2026-03-01T12:00:00\tv0.1.0\tamd64\t%s\t%s\n' "${CONTRACT_DIGEST}" "$(make_pinned_ref "${AIRGAP_REPO}" 200)"
} > "${AIRGAP_CATALOG_DIR}/catalog.tsv"

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
determine_os_ref <<< $'l\n\n\n'
[[ "${SELECTED_OS_REF}" == "${OS_STABLE_PINNED}" ]] || die "expected pager cancel followed by ENTER to keep the default OS selection"
[[ "${SELECTED_OS_SELECTION_SOURCE}" == "catalog" ]] || die "expected pager cancel fallback OS selection source to remain catalog"
[[ "${SELECTED_OS_RELEASE_CHANNEL}" == "stable" ]] || die "expected pager cancel fallback OS release channel to remain stable"

OS_CHANNEL="stable"
SELECTED_OS_REF=""
SELECTED_OS_SELECTION_SOURCE=""
SELECTED_OS_RELEASE_CHANNEL=""
determine_os_ref <<< $'l\n1\n'
[[ "${SELECTED_OS_REF}" == "${OS_BETA_PINNED}" ]] || die "expected catalog list selection to choose the first listed OS row"
[[ "${SELECTED_OS_SELECTION_SOURCE}" == "catalog" ]] || die "expected listed OS selection source to be catalog"
[[ "${SELECTED_OS_RELEASE_CHANNEL}" == "beta" ]] || die "expected listed OS release channel to normalize to beta"

OS_CHANNEL="stable"
SELECTED_OS_REF=""
SELECTED_OS_SELECTION_SOURCE=""
SELECTED_OS_RELEASE_CHANNEL=""
determine_os_ref <<< $'l\nn\n2\n'
[[ "${SELECTED_OS_REF}" == "${OS_PAGE2_SELECTED_PINNED}" ]] || die "expected paginated OS catalog selection to choose the second row on page two"
[[ "${SELECTED_OS_SELECTION_SOURCE}" == "catalog" ]] || die "expected paginated OS selection source to be catalog"
[[ "${SELECTED_OS_RELEASE_CHANNEL}" == "exp-labs" ]] || die "expected paginated OS release channel to normalize to exp-labs"

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

AIRGAP_CHANNEL=""
SELECTED_AIRGAP_REF=""
SELECTED_AIRGAP_SELECTION_MODE=""
SELECTED_AIRGAP_SELECTION_SOURCE=""
SELECTED_AIRGAP_RELEASE_CHANNEL=""
determine_airgap_ref "${CONTRACT_DIGEST}" <<< $'l\nn\np\n1\n'
[[ "${SELECTED_AIRGAP_REF}" == "${AIRGAP_BETA_PINNED}" ]] || die "expected previous-page navigation to return to the newest airgap row"
[[ "${SELECTED_AIRGAP_SELECTION_MODE}" == "host-selected" ]] || die "expected paginated airgap selection mode to be host-selected"
[[ "${SELECTED_AIRGAP_SELECTION_SOURCE}" == "catalog" ]] || die "expected paginated airgap selection source to be catalog"
[[ "${SELECTED_AIRGAP_RELEASE_CHANNEL}" == "beta" ]] || die "expected paginated airgap release channel to normalize to beta"

AIRGAP_CHANNEL="stable"
SELECTED_AIRGAP_REF=""
SELECTED_AIRGAP_SELECTION_MODE=""
SELECTED_AIRGAP_SELECTION_SOURCE=""
SELECTED_AIRGAP_RELEASE_CHANNEL=""
determine_airgap_ref "${CONTRACT_DIGEST}" <<< $'\n'
[[ "${SELECTED_AIRGAP_REF}" == "${AIRGAP_STABLE_PINNED}" ]] || die "expected mixed timestamp default airgap resolution to choose newest stable row"
[[ "${SELECTED_AIRGAP_SELECTION_MODE}" == "host-selected" ]] || die "expected default airgap channel selection mode to be host-selected"
[[ "${SELECTED_AIRGAP_SELECTION_SOURCE}" == "catalog" ]] || die "expected default airgap channel selection source to be catalog"
[[ "${SELECTED_AIRGAP_RELEASE_CHANNEL}" == "stable" ]] || die "expected default airgap channel release channel to remain stable"
AIRGAP_CHANNEL=""

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
