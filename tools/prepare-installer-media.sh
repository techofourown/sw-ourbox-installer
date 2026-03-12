#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tools/lib.sh"
# shellcheck disable=SC1091
source "${ROOT}/tools/cache.sh"

TARGET="woodbox"
OS_CHANNEL="stable"
OS_REF=""
AIRGAP_CHANNEL=""
AIRGAP_REF=""
OUTPUT_DIR="${ROOT}/out/woodbox"
MISSION_ONLY=0
FLASH_DEVICE=""
ADAPTER_REPO_ROOT="${WOODBOX_REPO_ROOT:-/techofourown/img-ourbox-woodbox}"
VENDORED_ADAPTER_ROOT="${ROOT}/vendor/woodbox"
TMP_ROOT=""
CACHE_REUSE_ENABLED=0
CACHE_REUSE_DECISION_MADE=0
: "${OURBOX_CACHE_REUSE_POLICY:=ask}"
: "${OURBOX_CACHE_CLEANUP_POLICY:=ask}"

usage() {
  cat <<EOF
Usage: $0 [options]

Phase-one unified host-side mission prep for Woodbox.

Options:
  --target woodbox            Target to compose (only woodbox is supported now)
  --os-channel CHANNEL        OS channel to use when --os-ref is not set (default: stable)
  --os-ref REF                Exact OS artifact ref to pull instead of catalog/channel resolution
  --airgap-channel CHANNEL    Airgap bundle channel to resolve on the host after OS selection
  --airgap-ref REF            Exact airgap bundle ref to pull instead of using the baked bundle
  --output-dir DIR            Directory for staged mission output
  --adapter-repo-root DIR     Path to the authoritative img-ourbox-woodbox checkout
  --mission-only              Stop after staging the mission directory and manifest
  --flash-device DEV          Pass the composed ISO to the Woodbox adapter for flashing
  -h, --help                  Show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      [[ $# -ge 2 ]] || die "--target requires a value"
      TARGET="$2"
      shift 2
      ;;
    --os-channel)
      [[ $# -ge 2 ]] || die "--os-channel requires a value"
      OS_CHANNEL="$2"
      shift 2
      ;;
    --os-ref)
      [[ $# -ge 2 ]] || die "--os-ref requires a value"
      OS_REF="$2"
      shift 2
      ;;
    --airgap-channel)
      [[ $# -ge 2 ]] || die "--airgap-channel requires a value"
      AIRGAP_CHANNEL="$2"
      shift 2
      ;;
    --airgap-ref)
      [[ $# -ge 2 ]] || die "--airgap-ref requires a value"
      AIRGAP_REF="$2"
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || die "--output-dir requires a value"
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --adapter-repo-root)
      [[ $# -ge 2 ]] || die "--adapter-repo-root requires a value"
      ADAPTER_REPO_ROOT="$2"
      shift 2
      ;;
    --mission-only)
      MISSION_ONLY=1
      shift
      ;;
    --flash-device)
      [[ $# -ge 2 ]] || die "--flash-device requires a value"
      FLASH_DEVICE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      die "unknown argument: $1"
      ;;
  esac
done

[[ "${TARGET}" == "woodbox" ]] || die "phase one only supports --target woodbox"
[[ "${MISSION_ONLY}" == "0" || -z "${FLASH_DEVICE}" ]] || die "--flash-device cannot be combined with --mission-only"

need_cmd python3
need_cmd git
need_cmd oras
need_cmd sha256sum
need_cmd tar
need_cmd find

[[ -d "${ADAPTER_REPO_ROOT}" ]] || die "authoritative Woodbox repo not found: ${ADAPTER_REPO_ROOT}"
[[ -f "${VENDORED_ADAPTER_ROOT}/adapter.json" ]] || die "vendored Woodbox adapter not found: ${VENDORED_ADAPTER_ROOT}/adapter.json"
[[ -f "${VENDORED_ADAPTER_ROOT}/compose-media.sh" ]] || die "vendored Woodbox compose script not found: ${VENDORED_ADAPTER_ROOT}/compose-media.sh"
[[ -f "${VENDORED_ADAPTER_ROOT}/validate-media.sh" ]] || die "vendored Woodbox validate script not found: ${VENDORED_ADAPTER_ROOT}/validate-media.sh"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMP_ROOT}"' EXIT

substrate_revision="$(git -C "${ADAPTER_REPO_ROOT}" rev-parse HEAD 2>/dev/null || echo unknown)"
if [[ -n "$(git -C "${ADAPTER_REPO_ROOT}" status --short 2>/dev/null || true)" ]]; then
  substrate_revision="${substrate_revision}-dirty"
fi
substrate_repo="$(git -C "${ADAPTER_REPO_ROOT}" remote get-url github 2>/dev/null || printf '%s\n' "${ADAPTER_REPO_ROOT}")"

ADAPTER_SOURCE_REPO="${substrate_repo}"
ADAPTER_SOURCE_REVISION="${substrate_revision}"
VENDORED_PIN="${ROOT}/vendor/woodbox.upstream.env"
if [[ -f "${VENDORED_PIN}" ]]; then
  # shellcheck disable=SC1090
  source "${VENDORED_PIN}"
  ADAPTER_SOURCE_REPO="${SOURCE_REPO:-${ADAPTER_SOURCE_REPO}}"
  ADAPTER_SOURCE_REVISION="${SOURCE_REVISION:-${ADAPTER_SOURCE_REVISION}}"
  if [[ "${SOURCE_REVISION:-unknown}" != "${substrate_revision}" ]]; then
    log "WARNING: vendored woodbox adapter pin (${SOURCE_REVISION:-unknown}) does not match local substrate repo revision (${substrate_revision})"
  fi
fi

adapter_dump="$(
  python3 - <<'PY' "${VENDORED_ADAPTER_ROOT}/adapter.json" "${OS_CHANNEL}" "${AIRGAP_CHANNEL}"
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    adapter = json.load(handle)

official = adapter["official"]
os_channel = sys.argv[2]
airgap_channel = sys.argv[3]

os_tags = official["os_channel_tags"]
if os_channel not in os_tags:
    raise SystemExit(f"unsupported woodbox os channel: {os_channel}")

airgap_tags = official["airgap_channel_tags"]
if airgap_channel and airgap_channel not in airgap_tags:
    raise SystemExit(f"unsupported woodbox airgap channel: {airgap_channel}")

values = [
    official["os_repo"],
    official["os_catalog_tag"],
    os_tags[os_channel],
    adapter["expected_os_artifact_type"],
    adapter["expected_airgap_arch"],
    official["airgap_repo"],
    official["airgap_catalog_tag"],
    airgap_tags.get(airgap_channel, ""),
    str(adapter.get("minimum_media_size_bytes", "")),
    adapter.get("output_kind", ""),
    json.dumps(adapter.get("runtime_prompts_kept", [])),
]
print("\n".join(values))
PY
)"
mapfile -t adapter_fields <<<"${adapter_dump}"
[[ "${#adapter_fields[@]}" -eq 11 ]] || die "failed to load vendored woodbox adapter metadata"
OS_REPO="${adapter_fields[0]}"
OS_CATALOG_TAG="${adapter_fields[1]}"
OS_CHANNEL_TAG="${adapter_fields[2]}"
EXPECTED_OS_ARTIFACT_TYPE="${adapter_fields[3]}"
EXPECTED_AIRGAP_ARCH="${adapter_fields[4]}"
AIRGAP_REPO="${adapter_fields[5]}"
AIRGAP_CATALOG_TAG="${adapter_fields[6]}"
AIRGAP_CHANNEL_TAG="${adapter_fields[7]}"
MINIMUM_MEDIA_SIZE_BYTES="${adapter_fields[8]}"
OUTPUT_KIND="${adapter_fields[9]}"
ADAPTER_RUNTIME_PROMPTS_JSON="${adapter_fields[10]}"

case "${OURBOX_CACHE_REUSE_POLICY}" in
  ask|always|never) ;;
  *) die "OURBOX_CACHE_REUSE_POLICY must be ask, always, or never" ;;
esac

case "${OURBOX_CACHE_CLEANUP_POLICY}" in
  ask|clear|keep) ;;
  *) die "OURBOX_CACHE_CLEANUP_POLICY must be ask, clear, or keep" ;;
esac

prompt_yes_no_default_no() {
  local prompt="$1"
  local answer=""

  if [[ ! -t 0 ]]; then
    return 1
  fi

  read -r -p "${prompt} [y/N]: " answer
  case "${answer}" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

maybe_confirm_cache_reuse() {
  local label="$1"
  shift
  local ref=""
  local -a cached_refs=()

  if (( CACHE_REUSE_DECISION_MADE )); then
    return 0
  fi

  for ref in "$@"; do
    [[ -n "${ref}" ]] || continue
    if cache_has_cached_ref "${ref}"; then
      cached_refs+=("${ref}")
    fi
  done

  (( ${#cached_refs[@]} > 0 )) || return 0

  case "${OURBOX_CACHE_REUSE_POLICY}" in
    always)
      CACHE_REUSE_ENABLED=1
      ;;
    never)
      CACHE_REUSE_ENABLED=0
      ;;
    ask)
      echo
      echo "Cached installer assets are available for ${label}:"
      for ref in "${cached_refs[@]}"; do
        echo "  - ${ref}"
      done
      echo
      if prompt_yes_no_default_no "Reuse cached assets where available for this compose?"; then
        CACHE_REUSE_ENABLED=1
      else
        CACHE_REUSE_ENABLED=0
      fi
      ;;
  esac

  CACHE_REUSE_DECISION_MADE=1
  if (( CACHE_REUSE_ENABLED )); then
    log "Cache reuse confirmed for ${label}"
  else
    log "Cache reuse declined for ${label}; pulling fresh bytes where needed"
  fi
}

offer_cache_cleanup() {
  local should_clear=0

  cache_has_any_content || return 0

  case "${OURBOX_CACHE_CLEANUP_POLICY}" in
    clear)
      should_clear=1
      ;;
    keep)
      should_clear=0
      ;;
    ask)
      echo
      if prompt_yes_no_default_no "Clear the installer cache now to reclaim disk space?"; then
        should_clear=1
      fi
      ;;
  esac

  if (( should_clear )); then
    cache_clear_all
    log "Cleared installer cache: ${OURBOX_INSTALLER_CACHE_ROOT}"
  else
    log "Keeping installer cache: ${OURBOX_INSTALLER_CACHE_ROOT}"
  fi
}

find_pulled_file() {
  local root="$1"
  local name="$2"
  find "${root}" -maxdepth 5 -type f -name "${name}" | head -n 1
}

select_os_ref_from_catalog() {
  local catalog_tsv="$1"
  local channel="$2"

  python3 - <<'PY' "${catalog_tsv}" "${channel}"
import csv
import re
import sys

catalog_tsv = sys.argv[1]
channel = sys.argv[2]
rows = []
with open(catalog_tsv, "r", encoding="utf-8") as handle:
    reader = csv.DictReader(handle, delimiter="\t")
    for row in reader:
        row_channel = (row.get("channel") or "").strip()
        pinned_ref = (row.get("pinned_ref") or "").strip()
        created = (row.get("created") or "").strip()
        if not created:
            continue
        if row_channel not in {channel, f"x86-{channel}"}:
            continue
        if not re.fullmatch(r"[^\s]+@sha256:[0-9a-f]{64}", pinned_ref):
            continue
        rows.append((created, pinned_ref))

if not rows:
    raise SystemExit(1)

rows.sort(key=lambda item: item[0], reverse=True)
print(rows[0][1])
PY
}

select_airgap_ref_from_catalog() {
  local catalog_tsv="$1"
  local channel="$2"
  local required_contract_digest="$3"
  local required_arch="$4"

  python3 - <<'PY' "${catalog_tsv}" "${channel}" "${required_contract_digest}" "${required_arch}"
import csv
import re
import sys

catalog_tsv, channel, digest, arch = sys.argv[1:]
rows = []
with open(catalog_tsv, "r", encoding="utf-8") as handle:
    reader = csv.DictReader(handle, delimiter="\t")
    for row in reader:
        row_channel = (row.get("channel") or "").strip()
        row_digest = (row.get("platform_contract_digest") or "").strip()
        row_arch = (row.get("arch") or "").strip()
        pinned_ref = (row.get("pinned_ref") or "").strip()
        created = (row.get("created") or "").strip()
        if not created:
            continue
        if row_channel != channel:
            continue
        if row_arch != arch or row_digest != digest:
            continue
        if not re.fullmatch(r"[^\s]+@sha256:[0-9a-f]{64}", pinned_ref):
            continue
        rows.append((created, pinned_ref))

if not rows:
    raise SystemExit(1)

rows.sort(key=lambda item: item[0], reverse=True)
print(rows[0][1])
PY
}

determine_os_ref() {
  local catalog_cache_dir=""
  local catalog_tsv=""
  local catalog_ref=""

  if [[ -n "${OS_REF}" ]]; then
    SELECTED_OS_SELECTION_SOURCE="os-ref"
    SELECTED_OS_RELEASE_CHANNEL=""
    SELECTED_OS_REF="${OS_REF}"
    return 0
  fi

  if try_cache_pull_oci_artifact "${OS_REPO}:${OS_CATALOG_TAG}" "${CACHE_REUSE_ENABLED}" catalog_cache_dir; then
    catalog_tsv="$(find_pulled_file "${catalog_cache_dir}" "catalog.tsv")"
    if [[ -n "${catalog_tsv}" ]]; then
      catalog_ref="$(select_os_ref_from_catalog "${catalog_tsv}" "${OS_CHANNEL}" || true)"
      if is_pinned_ref "${catalog_ref}"; then
        SELECTED_OS_SELECTION_SOURCE="catalog"
        SELECTED_OS_RELEASE_CHANNEL="${OS_CHANNEL}"
        SELECTED_OS_REF="${catalog_ref}"
        return 0
      fi
    fi
    log "OS catalog ${OS_REPO}:${OS_CATALOG_TAG} had no valid pinned row for channel ${OS_CHANNEL}; falling back to channel tag"
  else
    log "OS catalog ${OS_REPO}:${OS_CATALOG_TAG} unavailable; falling back to channel tag"
  fi

  SELECTED_OS_SELECTION_SOURCE="channel-tag"
  SELECTED_OS_RELEASE_CHANNEL="${OS_CHANNEL}"
  SELECTED_OS_REF="${OS_REPO}:${OS_CHANNEL_TAG}"
}

determine_airgap_ref() {
  local required_contract_digest="$1"
  local catalog_cache_dir=""
  local catalog_tsv=""
  local catalog_ref=""

  if [[ -n "${AIRGAP_REF}" ]]; then
    SELECTED_AIRGAP_SELECTION_MODE="explicit-ref"
    SELECTED_AIRGAP_SELECTION_SOURCE="airgap-ref"
    SELECTED_AIRGAP_RELEASE_CHANNEL=""
    SELECTED_AIRGAP_REF="${AIRGAP_REF}"
    return 0
  fi

  if [[ -z "${AIRGAP_CHANNEL}" ]]; then
    SELECTED_AIRGAP_SELECTION_MODE="baked-from-selected-os"
    SELECTED_AIRGAP_SELECTION_SOURCE="baked-os-payload"
    SELECTED_AIRGAP_RELEASE_CHANNEL=""
    SELECTED_AIRGAP_REF="${BAKED_AIRGAP_REF}"
    return 0
  fi

  if try_cache_pull_oci_artifact "${AIRGAP_REPO}:${AIRGAP_CATALOG_TAG}" "${CACHE_REUSE_ENABLED}" catalog_cache_dir; then
    catalog_tsv="$(find_pulled_file "${catalog_cache_dir}" "catalog.tsv")"
    if [[ -n "${catalog_tsv}" ]]; then
      catalog_ref="$(select_airgap_ref_from_catalog "${catalog_tsv}" "${AIRGAP_CHANNEL}" "${required_contract_digest}" "${EXPECTED_AIRGAP_ARCH}" || true)"
      if is_pinned_ref "${catalog_ref}"; then
        SELECTED_AIRGAP_SELECTION_MODE="host-selected"
        SELECTED_AIRGAP_SELECTION_SOURCE="catalog"
        SELECTED_AIRGAP_RELEASE_CHANNEL="${AIRGAP_CHANNEL}"
        SELECTED_AIRGAP_REF="${catalog_ref}"
        return 0
      fi
    fi
    log "Airgap catalog ${AIRGAP_REPO}:${AIRGAP_CATALOG_TAG} had no valid pinned row for channel ${AIRGAP_CHANNEL} and contract ${required_contract_digest}; falling back to channel tag"
  else
    log "Airgap catalog ${AIRGAP_REPO}:${AIRGAP_CATALOG_TAG} unavailable; falling back to channel tag"
  fi

  SELECTED_AIRGAP_SELECTION_MODE="host-selected"
  SELECTED_AIRGAP_SELECTION_SOURCE="channel-tag"
  SELECTED_AIRGAP_RELEASE_CHANNEL="${AIRGAP_CHANNEL}"
  SELECTED_AIRGAP_REF="${AIRGAP_REPO}:${AIRGAP_CHANNEL_TAG}"
}

initial_cache_refs=()
if [[ -n "${OS_REF}" ]]; then
  initial_cache_refs+=("${OS_REF}")
else
  initial_cache_refs+=("${OS_REPO}:${OS_CATALOG_TAG}" "${OS_REPO}:${OS_CHANNEL_TAG}")
fi
if [[ -n "${AIRGAP_REF}" ]]; then
  initial_cache_refs+=("${AIRGAP_REF}")
elif [[ -n "${AIRGAP_CHANNEL}" ]]; then
  initial_cache_refs+=("${AIRGAP_REPO}:${AIRGAP_CATALOG_TAG}" "${AIRGAP_REPO}:${AIRGAP_CHANNEL_TAG}")
fi
maybe_confirm_cache_reuse "the requested selection inputs" "${initial_cache_refs[@]}"

SELECTED_OS_REF=""
determine_os_ref
maybe_confirm_cache_reuse "the selected OS artifact" "${SELECTED_OS_REF}"
cache_pull_oci_artifact "${SELECTED_OS_REF}" "${CACHE_REUSE_ENABLED}" OS_CACHE_DIR
SELECTED_OS_DIGEST="${OURBOX_CACHE_LAST_DIGEST}"
SELECTED_OS_PINNED_REF="${OURBOX_CACHE_LAST_PINNED_REF}"

OS_PAYLOAD="$(find_pulled_file "${OS_CACHE_DIR}" "os-payload.tar.gz")"
OS_PAYLOAD_SHA_FILE="$(find_pulled_file "${OS_CACHE_DIR}" "os-payload.tar.gz.sha256")"
OS_META_ENV="$(find_pulled_file "${OS_CACHE_DIR}" "os.meta.env")"
[[ -f "${OS_PAYLOAD}" ]] || die "cached OS artifact missing os-payload.tar.gz: ${OS_CACHE_DIR}"
[[ -f "${OS_PAYLOAD_SHA_FILE}" ]] || die "cached OS artifact missing os-payload.tar.gz.sha256: ${OS_CACHE_DIR}"
[[ -f "${OS_META_ENV}" ]] || die "cached OS artifact missing os.meta.env: ${OS_CACHE_DIR}"

EXPECTED_OS_SHA="$(awk 'NF>=1 {print $1; exit}' "${OS_PAYLOAD_SHA_FILE}")"
EXPECTED_OS_SHA="${EXPECTED_OS_SHA,,}"
[[ "${EXPECTED_OS_SHA}" =~ ^[0-9a-f]{64}$ ]] || die "invalid SHA256 in ${OS_PAYLOAD_SHA_FILE}"
ACTUAL_OS_SHA="$(sha256_file "${OS_PAYLOAD}")"
[[ "${ACTUAL_OS_SHA}" == "${EXPECTED_OS_SHA}" ]] || die "os payload SHA mismatch for ${SELECTED_OS_PINNED_REF}"

os_meta_dump="$(
  (
    unset OS_ARTIFACT_TYPE OURBOX_PLATFORM_CONTRACT_DIGEST OURBOX_PLATFORM_CONTRACT_SOURCE
    unset OURBOX_PLATFORM_CONTRACT_REVISION OURBOX_PLATFORM_CONTRACT_VERSION OURBOX_PLATFORM_CONTRACT_CREATED
    unset OURBOX_AIRGAP_PLATFORM_REF OURBOX_AIRGAP_PLATFORM_DIGEST OURBOX_AIRGAP_PLATFORM_SOURCE
    unset OURBOX_AIRGAP_PLATFORM_REVISION OURBOX_AIRGAP_PLATFORM_VERSION OURBOX_AIRGAP_PLATFORM_CREATED
    unset OURBOX_AIRGAP_PLATFORM_ARCH OURBOX_AIRGAP_PLATFORM_PROFILE OURBOX_AIRGAP_PLATFORM_K3S_VERSION
    unset OURBOX_AIRGAP_PLATFORM_IMAGES_LOCK_SHA256 OURBOX_VERSION OURBOX_VARIANT OURBOX_TARGET OURBOX_SKU
    # shellcheck disable=SC1090
    source "${OS_META_ENV}"
    printf '%s\n' \
      "${OS_ARTIFACT_TYPE-}" \
      "${OURBOX_PLATFORM_CONTRACT_DIGEST-}" \
      "${OURBOX_PLATFORM_CONTRACT_SOURCE-}" \
      "${OURBOX_PLATFORM_CONTRACT_REVISION-}" \
      "${OURBOX_PLATFORM_CONTRACT_VERSION-}" \
      "${OURBOX_PLATFORM_CONTRACT_CREATED-}" \
      "${OURBOX_AIRGAP_PLATFORM_REF-}" \
      "${OURBOX_AIRGAP_PLATFORM_DIGEST-}" \
      "${OURBOX_AIRGAP_PLATFORM_SOURCE-}" \
      "${OURBOX_AIRGAP_PLATFORM_REVISION-}" \
      "${OURBOX_AIRGAP_PLATFORM_VERSION-}" \
      "${OURBOX_AIRGAP_PLATFORM_CREATED-}" \
      "${OURBOX_AIRGAP_PLATFORM_ARCH-}" \
      "${OURBOX_AIRGAP_PLATFORM_PROFILE-}" \
      "${OURBOX_AIRGAP_PLATFORM_K3S_VERSION-}" \
      "${OURBOX_AIRGAP_PLATFORM_IMAGES_LOCK_SHA256-}" \
      "${OURBOX_VERSION-}" \
      "${OURBOX_VARIANT-}" \
      "${OURBOX_TARGET-}" \
      "${OURBOX_SKU-}"
  )
)"
mapfile -t os_meta_fields <<<"${os_meta_dump}"
[[ "${#os_meta_fields[@]}" -eq 20 ]] || die "failed to parse ${OS_META_ENV}"

OS_ARTIFACT_TYPE="${os_meta_fields[0]}"
PLATFORM_CONTRACT_DIGEST="${os_meta_fields[1]}"
PLATFORM_CONTRACT_SOURCE="${os_meta_fields[2]}"
PLATFORM_CONTRACT_REVISION="${os_meta_fields[3]}"
PLATFORM_CONTRACT_VERSION="${os_meta_fields[4]}"
PLATFORM_CONTRACT_CREATED="${os_meta_fields[5]}"
BAKED_AIRGAP_REF="${os_meta_fields[6]}"
BAKED_AIRGAP_DIGEST="${os_meta_fields[7]}"
BAKED_AIRGAP_SOURCE="${os_meta_fields[8]}"
BAKED_AIRGAP_REVISION="${os_meta_fields[9]}"
BAKED_AIRGAP_VERSION="${os_meta_fields[10]}"
BAKED_AIRGAP_CREATED="${os_meta_fields[11]}"
BAKED_AIRGAP_ARCH="${os_meta_fields[12]}"
BAKED_AIRGAP_PROFILE="${os_meta_fields[13]}"
BAKED_AIRGAP_K3S_VERSION="${os_meta_fields[14]}"
BAKED_AIRGAP_IMAGES_LOCK_SHA256="${os_meta_fields[15]}"
OURBOX_VERSION="${os_meta_fields[16]}"
OURBOX_VARIANT="${os_meta_fields[17]}"
OURBOX_TARGET="${os_meta_fields[18]}"
OURBOX_SKU="${os_meta_fields[19]}"

[[ "${OS_ARTIFACT_TYPE}" == "${EXPECTED_OS_ARTIFACT_TYPE}" ]] || die "unexpected OS artifact type in ${OS_META_ENV}: ${OS_ARTIFACT_TYPE}"
is_sha256_digest "${PLATFORM_CONTRACT_DIGEST}" || die "invalid platform contract digest in ${OS_META_ENV}"
is_pinned_ref "${BAKED_AIRGAP_REF}" || die "selected OS payload is missing a pinned baked airgap ref"
is_sha256_digest "${BAKED_AIRGAP_DIGEST}" || die "selected OS payload is missing a baked airgap digest"
[[ "${BAKED_AIRGAP_ARCH}" == "${EXPECTED_AIRGAP_ARCH}" ]] || die "selected OS payload baked airgap arch mismatch: ${BAKED_AIRGAP_ARCH}"

SELECTED_AIRGAP_REF=""
determine_airgap_ref "${PLATFORM_CONTRACT_DIGEST}"
maybe_confirm_cache_reuse "the selected mission artifacts" "${SELECTED_OS_REF}" "${SELECTED_AIRGAP_REF}"
cache_pull_oci_artifact "${SELECTED_AIRGAP_REF}" "${CACHE_REUSE_ENABLED}" AIRGAP_CACHE_DIR
SELECTED_AIRGAP_DIGEST="${OURBOX_CACHE_LAST_DIGEST}"
SELECTED_AIRGAP_PINNED_REF="${OURBOX_CACHE_LAST_PINNED_REF}"

AIRGAP_TARBALL="$(find_pulled_file "${AIRGAP_CACHE_DIR}" "airgap-platform.tar.gz")"
[[ -f "${AIRGAP_TARBALL}" ]] || die "cached airgap artifact missing airgap-platform.tar.gz: ${AIRGAP_CACHE_DIR}"

AIRGAP_EXTRACT_DIR="${TMP_ROOT}/airgap-extract"
mkdir -p "${AIRGAP_EXTRACT_DIR}"
tar -xzf "${AIRGAP_TARBALL}" -C "${AIRGAP_EXTRACT_DIR}"

AIRGAP_MANIFEST="${AIRGAP_EXTRACT_DIR}/manifest.env"
[[ -f "${AIRGAP_MANIFEST}" ]] || die "airgap bundle missing manifest.env"
[[ -x "${AIRGAP_EXTRACT_DIR}/k3s/k3s" ]] || die "airgap bundle missing k3s binary"
[[ -f "${AIRGAP_EXTRACT_DIR}/k3s/k3s-airgap-images-${EXPECTED_AIRGAP_ARCH}.tar" ]] || die "airgap bundle missing k3s airgap images tar for ${EXPECTED_AIRGAP_ARCH}"
[[ -f "${AIRGAP_EXTRACT_DIR}/platform/images.lock.json" ]] || die "airgap bundle missing platform/images.lock.json"
[[ -f "${AIRGAP_EXTRACT_DIR}/platform/profile.env" ]] || die "airgap bundle missing platform/profile.env"
[[ -d "${AIRGAP_EXTRACT_DIR}/platform/images" ]] || die "airgap bundle missing platform/images directory"
find "${AIRGAP_EXTRACT_DIR}/platform/images" -maxdepth 1 -type f -name '*.tar' -print -quit | grep -q . \
  || die "airgap bundle missing platform image tar payloads"

airgap_manifest_dump="$(
  (
    unset OURBOX_AIRGAP_PLATFORM_SOURCE OURBOX_AIRGAP_PLATFORM_REVISION OURBOX_AIRGAP_PLATFORM_VERSION
    unset OURBOX_AIRGAP_PLATFORM_CREATED OURBOX_PLATFORM_CONTRACT_REF OURBOX_PLATFORM_CONTRACT_DIGEST
    unset AIRGAP_PLATFORM_ARCH K3S_VERSION OURBOX_PLATFORM_PROFILE OURBOX_PLATFORM_IMAGES_LOCK_PATH
    unset OURBOX_PLATFORM_IMAGES_LOCK_SHA256
    # shellcheck disable=SC1090
    source "${AIRGAP_MANIFEST}"
    printf '%s\n' \
      "${OURBOX_AIRGAP_PLATFORM_SOURCE-}" \
      "${OURBOX_AIRGAP_PLATFORM_REVISION-}" \
      "${OURBOX_AIRGAP_PLATFORM_VERSION-}" \
      "${OURBOX_AIRGAP_PLATFORM_CREATED-}" \
      "${OURBOX_PLATFORM_CONTRACT_REF-}" \
      "${OURBOX_PLATFORM_CONTRACT_DIGEST-}" \
      "${AIRGAP_PLATFORM_ARCH-}" \
      "${K3S_VERSION-}" \
      "${OURBOX_PLATFORM_PROFILE-}" \
      "${OURBOX_PLATFORM_IMAGES_LOCK_PATH-}" \
      "${OURBOX_PLATFORM_IMAGES_LOCK_SHA256-}"
  )
)"
mapfile -t airgap_manifest_fields <<<"${airgap_manifest_dump}"
[[ "${#airgap_manifest_fields[@]}" -eq 11 ]] || die "failed to parse ${AIRGAP_MANIFEST}"

SELECTED_AIRGAP_SOURCE="${airgap_manifest_fields[0]}"
SELECTED_AIRGAP_REVISION="${airgap_manifest_fields[1]}"
SELECTED_AIRGAP_VERSION="${airgap_manifest_fields[2]}"
SELECTED_AIRGAP_CREATED="${airgap_manifest_fields[3]}"
SELECTED_AIRGAP_PLATFORM_CONTRACT_REF="${airgap_manifest_fields[4]}"
SELECTED_AIRGAP_PLATFORM_CONTRACT_DIGEST="${airgap_manifest_fields[5]}"
SELECTED_AIRGAP_ARCH="${airgap_manifest_fields[6]}"
SELECTED_AIRGAP_K3S_VERSION="${airgap_manifest_fields[7]}"
SELECTED_AIRGAP_PROFILE="${airgap_manifest_fields[8]}"
SELECTED_AIRGAP_IMAGES_LOCK_PATH="${airgap_manifest_fields[9]}"
SELECTED_AIRGAP_IMAGES_LOCK_SHA256="${airgap_manifest_fields[10]}"

[[ -n "${SELECTED_AIRGAP_SOURCE}" ]] || die "selected airgap bundle is missing OURBOX_AIRGAP_PLATFORM_SOURCE"
[[ -n "${SELECTED_AIRGAP_REVISION}" ]] || die "selected airgap bundle is missing OURBOX_AIRGAP_PLATFORM_REVISION"
[[ -n "${SELECTED_AIRGAP_VERSION}" ]] || die "selected airgap bundle is missing OURBOX_AIRGAP_PLATFORM_VERSION"
is_sha256_digest "${SELECTED_AIRGAP_PLATFORM_CONTRACT_DIGEST}" || die "selected airgap bundle has invalid platform contract digest"
[[ "${SELECTED_AIRGAP_PLATFORM_CONTRACT_DIGEST}" == "${PLATFORM_CONTRACT_DIGEST}" ]] || die "selected airgap bundle contract digest mismatch: expected ${PLATFORM_CONTRACT_DIGEST}, got ${SELECTED_AIRGAP_PLATFORM_CONTRACT_DIGEST}"
[[ "${SELECTED_AIRGAP_ARCH}" == "${EXPECTED_AIRGAP_ARCH}" ]] || die "selected airgap bundle arch mismatch: expected ${EXPECTED_AIRGAP_ARCH}, got ${SELECTED_AIRGAP_ARCH}"
[[ -n "${SELECTED_AIRGAP_K3S_VERSION}" ]] || die "selected airgap bundle is missing K3S_VERSION"
[[ -n "${SELECTED_AIRGAP_PROFILE}" ]] || die "selected airgap bundle is missing OURBOX_PLATFORM_PROFILE"
[[ -n "${SELECTED_AIRGAP_IMAGES_LOCK_PATH}" ]] || die "selected airgap bundle is missing OURBOX_PLATFORM_IMAGES_LOCK_PATH"
[[ "${SELECTED_AIRGAP_IMAGES_LOCK_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die "selected airgap bundle has invalid OURBOX_PLATFORM_IMAGES_LOCK_SHA256"

COMPOSER_REVISION="$(git -C "${ROOT}" rev-parse HEAD 2>/dev/null || echo unknown)"
if [[ -n "$(git -C "${ROOT}" status --short 2>/dev/null || true)" ]]; then
  COMPOSER_REVISION="${COMPOSER_REVISION}-dirty"
fi

COMPOSED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
COMPOSE_ID="${TARGET}-${OURBOX_VERSION}-${COMPOSED_AT//[:]/}"

MISSION_DIR="${OUTPUT_DIR}/mission"
OS_STAGE_DIR="${MISSION_DIR}/artifacts/os"
AIRGAP_STAGE_DIR="${MISSION_DIR}/artifacts/airgap"
mkdir -p "${OS_STAGE_DIR}" "${AIRGAP_STAGE_DIR}"

cp -f "${OS_PAYLOAD}" "${OS_STAGE_DIR}/os-payload.tar.gz"
cp -f "${OS_PAYLOAD_SHA_FILE}" "${OS_STAGE_DIR}/os-payload.tar.gz.sha256"
cp -f "${OS_META_ENV}" "${OS_STAGE_DIR}/os.meta.env"
printf '%s\n' "${SELECTED_OS_PINNED_REF}" > "${OS_STAGE_DIR}/artifact.ref"

cp -f "${AIRGAP_TARBALL}" "${AIRGAP_STAGE_DIR}/airgap-platform.tar.gz"
printf '%s  %s\n' "$(sha256_file "${AIRGAP_STAGE_DIR}/airgap-platform.tar.gz")" "airgap-platform.tar.gz" > "${AIRGAP_STAGE_DIR}/airgap-platform.tar.gz.sha256"
cp -f "${AIRGAP_MANIFEST}" "${AIRGAP_STAGE_DIR}/manifest.env"
printf '%s\n' "${SELECTED_AIRGAP_PINNED_REF}" > "${AIRGAP_STAGE_DIR}/artifact.ref"

export MISSION_DIR COMPOSE_ID COMPOSED_AT TARGET COMPOSER_REVISION ADAPTER_SOURCE_REPO ADAPTER_SOURCE_REVISION
export ADAPTER_REPO_ROOT VENDORED_ADAPTER_ROOT ADAPTER_RUNTIME_PROMPTS_JSON MINIMUM_MEDIA_SIZE_BYTES OUTPUT_KIND
export SUBSTRATE_SOURCE_REPO="${substrate_repo}" SUBSTRATE_SOURCE_REVISION="${substrate_revision}"
export SELECTED_OS_PINNED_REF SELECTED_OS_DIGEST EXPECTED_OS_ARTIFACT_TYPE PLATFORM_CONTRACT_DIGEST PLATFORM_CONTRACT_SOURCE
export PLATFORM_CONTRACT_REVISION PLATFORM_CONTRACT_VERSION PLATFORM_CONTRACT_CREATED SELECTED_OS_SELECTION_SOURCE SELECTED_OS_RELEASE_CHANNEL
export SELECTED_AIRGAP_PINNED_REF SELECTED_AIRGAP_DIGEST SELECTED_AIRGAP_SELECTION_MODE SELECTED_AIRGAP_SELECTION_SOURCE SELECTED_AIRGAP_RELEASE_CHANNEL
export SELECTED_AIRGAP_SOURCE SELECTED_AIRGAP_REVISION SELECTED_AIRGAP_VERSION SELECTED_AIRGAP_CREATED SELECTED_AIRGAP_PLATFORM_CONTRACT_REF
export SELECTED_AIRGAP_PLATFORM_CONTRACT_DIGEST SELECTED_AIRGAP_ARCH SELECTED_AIRGAP_PROFILE SELECTED_AIRGAP_K3S_VERSION
export SELECTED_AIRGAP_IMAGES_LOCK_SHA256 MISSION_ONLY BAKED_AIRGAP_DIGEST

python3 - <<'PY'
import hashlib
import json
import os
from pathlib import Path

mission_dir = Path(os.environ["MISSION_DIR"])
os_payload = mission_dir / "artifacts" / "os" / "os-payload.tar.gz"
os_meta = mission_dir / "artifacts" / "os" / "os.meta.env"
airgap_payload = mission_dir / "artifacts" / "airgap" / "airgap-platform.tar.gz"
airgap_manifest = mission_dir / "artifacts" / "airgap" / "manifest.env"

def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

staged_files = []
for path in sorted(mission_dir.rglob("*")):
    if not path.is_file():
        continue
    relpath = path.relative_to(mission_dir).as_posix()
    staged_files.append(
        {
            "relpath": relpath,
            "sha256": sha256(path),
            "size_bytes": path.stat().st_size,
        }
    )

runtime_prompts = json.loads(os.environ["ADAPTER_RUNTIME_PROMPTS_JSON"])
manifest = {
    "schema": 1,
    "kind": "ourbox-mission",
    "compose_id": os.environ["COMPOSE_ID"],
    "created": os.environ["COMPOSED_AT"],
    "target": {
        "id": os.environ["TARGET"],
        "media_kind": "installer-usb",
    },
    "composer": {
        "name": "sw-ourbox-installer",
        "phase": "phase-1",
        "source_revision": os.environ["COMPOSER_REVISION"],
    },
    "adapter": {
        "source_repo": os.environ["ADAPTER_SOURCE_REPO"],
        "source_revision": os.environ["ADAPTER_SOURCE_REVISION"],
        "adapter_json_relpath": "vendor/woodbox/adapter.json",
        "runtime_prompts_kept": runtime_prompts,
    },
    "operator_mode": {
        "mode": "install",
        "prompt_hostname_on_target": True,
        "prompt_identity_on_target": True,
    },
    "mission_media": {
      "compose_strategy": "woodbox-fat-iso-with-host-selected-os-and-airgap",
      "mission_only": os.environ["MISSION_ONLY"] == "1",
    },
    "substrate": {
        "strategy": "target-repo-build",
        "repo_path": os.environ["ADAPTER_REPO_ROOT"],
        "repo_revision": os.environ["SUBSTRATE_SOURCE_REVISION"],
        "compose_entrypoint": "tools/media-adapter/compose-media.sh",
    },
    "platform_contract": {
        "digest": os.environ["PLATFORM_CONTRACT_DIGEST"],
        "source": os.environ["PLATFORM_CONTRACT_SOURCE"],
        "revision": os.environ["PLATFORM_CONTRACT_REVISION"],
        "version": os.environ["PLATFORM_CONTRACT_VERSION"],
        "created": os.environ["PLATFORM_CONTRACT_CREATED"],
    },
    "selected_os": {
        "selection_source": os.environ["SELECTED_OS_SELECTION_SOURCE"],
        "release_channel": os.environ["SELECTED_OS_RELEASE_CHANNEL"],
        "artifact_ref": os.environ["SELECTED_OS_PINNED_REF"],
        "artifact_digest": os.environ["SELECTED_OS_DIGEST"],
        "artifact_type": os.environ["EXPECTED_OS_ARTIFACT_TYPE"],
        "platform_contract_digest": os.environ["PLATFORM_CONTRACT_DIGEST"],
        "payload": {
            "relpath": os_payload.relative_to(mission_dir).as_posix(),
            "sha256": sha256(os_payload),
            "size_bytes": os_payload.stat().st_size,
        },
        "metadata_relpath": os_meta.relative_to(mission_dir).as_posix(),
    },
    "selected_airgap": {
        "selection_mode": os.environ["SELECTED_AIRGAP_SELECTION_MODE"],
        "selection_source": os.environ["SELECTED_AIRGAP_SELECTION_SOURCE"],
        "release_channel": os.environ["SELECTED_AIRGAP_RELEASE_CHANNEL"],
        "artifact_ref": os.environ["SELECTED_AIRGAP_PINNED_REF"],
        "artifact_digest": os.environ["SELECTED_AIRGAP_DIGEST"],
        "platform_contract_digest": os.environ["SELECTED_AIRGAP_PLATFORM_CONTRACT_DIGEST"],
        "arch": os.environ["SELECTED_AIRGAP_ARCH"],
        "profile": os.environ["SELECTED_AIRGAP_PROFILE"],
        "version": os.environ["SELECTED_AIRGAP_VERSION"],
        "created": os.environ["SELECTED_AIRGAP_CREATED"],
        "k3s_version": os.environ["SELECTED_AIRGAP_K3S_VERSION"],
        "images_lock_sha256": os.environ["SELECTED_AIRGAP_IMAGES_LOCK_SHA256"],
        "payload_relpath": airgap_payload.relative_to(mission_dir).as_posix(),
        "manifest_relpath": airgap_manifest.relative_to(mission_dir).as_posix(),
        "present_in_selected_os_payload": os.environ["SELECTED_AIRGAP_DIGEST"] == os.environ["BAKED_AIRGAP_DIGEST"],
    },
    "staged_files": staged_files,
}

with (mission_dir / "mission-manifest.json").open("w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2)
    handle.write("\n")
PY

log "Mission directory prepared: ${MISSION_DIR}"
log "Selected OS artifact: ${SELECTED_OS_PINNED_REF} (${SELECTED_OS_SELECTION_SOURCE})"
log "Selected airgap bundle: ${SELECTED_AIRGAP_PINNED_REF} (${SELECTED_AIRGAP_SELECTION_SOURCE})"

if [[ "${MISSION_ONLY}" == "1" ]]; then
  log "Mission-only mode requested; skipping media compose"
  offer_cache_cleanup
  exit 0
fi

compose_cmd=(
  "${VENDORED_ADAPTER_ROOT}/compose-media.sh"
  --mission-dir "${MISSION_DIR}"
  --os-payload "${OS_STAGE_DIR}/os-payload.tar.gz"
  --output-dir "${OUTPUT_DIR}/media"
)
if [[ -n "${FLASH_DEVICE}" ]]; then
  compose_cmd+=(--flash-device "${FLASH_DEVICE}")
fi

log "Invoking vendored Woodbox media adapter"
WOODBOX_ADAPTER_ROOT="${VENDORED_ADAPTER_ROOT}" \
WOODBOX_REPO_ROOT="${ADAPTER_REPO_ROOT}" \
  "${compose_cmd[@]}"

offer_cache_cleanup
