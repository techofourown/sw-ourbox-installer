#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tools/lib.sh"
# shellcheck disable=SC1091
source "${ROOT}/tools/cache.sh"

TARGET=""
OS_CHANNEL="stable"
OS_REF=""
AIRGAP_CHANNEL=""
AIRGAP_REF=""
OUTPUT_DIR=""
MISSION_ONLY=0
COMPOSE_ONLY=0
FLASH_DEVICE=""
VENDORED_ADAPTER_ROOT="${ROOT}/vendor/woodbox"
VENDORED_METADATA_PARSER="${VENDORED_ADAPTER_ROOT}/strict-kv-metadata.py"
MISSION_SCHEMA="${ROOT}/schemas/mission-manifest.schema.json"
MISSION_SCHEMA_VALIDATOR="${ROOT}/tools/validate-mission-manifest.py"
TMP_ROOT=""
CACHE_REUSE_ENABLED=0
CACHE_REUSE_DECISION_MADE=0
: "${OURBOX_CACHE_REUSE_POLICY:=ask}"
: "${OURBOX_CACHE_CLEANUP_POLICY:=ask}"

usage() {
  cat <<EOF
Usage: $0 [options]

Phase-one unified host-side mission prep for OurBox targets.

Normal operator flow:
  $0

This prompts for target, OS, airgap, and removable media, then composes and
flashes mission media. Non-flash modes are available only behind explicit flags.

Options:
  --target TARGET             Preselect the target type for the UI
                              (currently only woodbox is supported)
  --os-channel CHANNEL        Preferred OS channel for interactive selection or
                              non-interactive resolution when --os-ref is not set
                              (default: stable)
  --os-ref REF                Exact OS artifact ref to pull instead of catalog/channel resolution
  --airgap-channel CHANNEL    Preferred airgap channel for interactive selection or
                              non-interactive resolution after OS selection
                              (default: baked bundle from the selected OS)
  --airgap-ref REF            Exact airgap bundle ref to pull instead of using the baked bundle
  --output-dir DIR            Keep staged mission or composed media under DIR
                              (used only by explicit non-default modes)
  --mission-only              Stage the mission directory only; do not compose or flash media
  --compose-only              Compose mission media to disk but do not flash it
  --flash-device DEV          Flash to the given device without interactive media selection
  -h, --help                  Show help
EOF
}

interactive_target_selection_enabled() {
  [[ -t 0 && -t 1 ]]
}

interactive_selection_enabled() {
  [[ -t 0 && -t 1 ]]
}

default_output_dir_for_target() {
  local target="$1"
  printf '%s/out/%s\n' "${ROOT}" "${target}"
}

show_target_default_choice() {
  local target="$1"

  echo
  echo "Host-side target selection"
  echo "Default: ${target}"
  echo "Options:"
  echo "  [ENTER] Use default"
  echo "  1       woodbox"
  echo "  q       Quit"
  echo
}

interactive_select_target() {
  local choice=""
  local default_target="woodbox"

  while [[ -z "${TARGET}" ]]; do
    show_target_default_choice "${default_target}"
    read -r -p "Choice: " choice

    case "${choice}" in
      "")
        TARGET="${default_target}"
        ;;
      1)
        TARGET="woodbox"
        ;;
      q|Q)
        die "Mission compose aborted by user"
        ;;
      *)
        log "Unknown option."
        ;;
    esac
  done
}

determine_target() {
  if [[ -n "${TARGET}" ]]; then
    return 0
  fi

  if interactive_target_selection_enabled; then
    interactive_select_target
  else
    TARGET="woodbox"
  fi
}

require_flash_path_or_explicit_mode() {
  if [[ "${MISSION_ONLY}" == "1" || "${COMPOSE_ONLY}" == "1" || -n "${FLASH_DEVICE}" ]]; then
    return 0
  fi

  interactive_selection_enabled && return 0
  die "non-interactive run requires --flash-device, --compose-only, or --mission-only"
}

if [[ "${OURBOX_PREPARE_INSTALLER_LIBRARY_ONLY:-0}" == "1" ]]; then
  return 0 2>/dev/null || exit 0
fi

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
    --mission-only)
      MISSION_ONLY=1
      shift
      ;;
    --compose-only)
      COMPOSE_ONLY=1
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

determine_target
[[ "${TARGET}" == "woodbox" ]] || die "phase one only supports target 'woodbox'"
[[ "${MISSION_ONLY}" == "0" || "${COMPOSE_ONLY}" == "0" ]] || die "--mission-only cannot be combined with --compose-only"
[[ "${MISSION_ONLY}" == "0" || -z "${FLASH_DEVICE}" ]] || die "--flash-device cannot be combined with --mission-only"
[[ "${COMPOSE_ONLY}" == "0" || -z "${FLASH_DEVICE}" ]] || die "--flash-device cannot be combined with --compose-only"
if [[ -z "${OUTPUT_DIR}" && ( "${MISSION_ONLY}" == "1" || "${COMPOSE_ONLY}" == "1" ) ]]; then
  OUTPUT_DIR="$(default_output_dir_for_target "${TARGET}")"
fi

need_cmd python3
need_cmd git
need_cmd oras
need_cmd sha256sum
need_cmd tar
need_cmd find

[[ -f "${VENDORED_ADAPTER_ROOT}/adapter.json" ]] || die "vendored Woodbox adapter not found: ${VENDORED_ADAPTER_ROOT}/adapter.json"
[[ -f "${VENDORED_ADAPTER_ROOT}/compose-media.sh" ]] || die "vendored Woodbox compose script not found: ${VENDORED_ADAPTER_ROOT}/compose-media.sh"
[[ -f "${VENDORED_ADAPTER_ROOT}/validate-media.sh" ]] || die "vendored Woodbox validate script not found: ${VENDORED_ADAPTER_ROOT}/validate-media.sh"
[[ -f "${VENDORED_METADATA_PARSER}" ]] || die "vendored Woodbox metadata parser not found: ${VENDORED_METADATA_PARSER}"
[[ -f "${MISSION_SCHEMA}" ]] || die "mission schema not found: ${MISSION_SCHEMA}"
[[ -f "${MISSION_SCHEMA_VALIDATOR}" ]] || die "mission schema validator not found: ${MISSION_SCHEMA_VALIDATOR}"

WORK_ROOT="${ROOT}/cache/work"
mkdir -p "${WORK_ROOT}"
TMP_ROOT="$(mktemp -d "${WORK_ROOT}/prepare-installer-media.XXXXXX")"
trap 'rm -rf "${TMP_ROOT}"' EXIT
require_flash_path_or_explicit_mode

ADAPTER_SOURCE_REPO="vendored-local"
ADAPTER_SOURCE_REVISION="unknown"
VENDORED_PIN="${ROOT}/vendor/woodbox.upstream.env"
if [[ -f "${VENDORED_PIN}" ]]; then
  # shellcheck disable=SC1090
  source "${VENDORED_PIN}"
  ADAPTER_SOURCE_REPO="${SOURCE_REPO:-${ADAPTER_SOURCE_REPO}}"
  ADAPTER_SOURCE_REVISION="${SOURCE_REVISION:-${ADAPTER_SOURCE_REVISION}}"
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

installer_tags = official["installer_channel_tags"]

values = [
    official["os_repo"],
    official["os_catalog_tag"],
    os_tags["stable"],
    os_tags["beta"],
    os_tags["nightly"],
    os_tags["exp-labs"],
    adapter["expected_os_artifact_type"],
    adapter["expected_airgap_arch"],
    official["airgap_repo"],
    official["airgap_catalog_tag"],
    airgap_tags["stable"],
    airgap_tags["beta"],
    airgap_tags["nightly"],
    airgap_tags["exp-labs"],
    official["installer_repo"],
    installer_tags["stable"],
    installer_tags["beta"],
    installer_tags["nightly"],
    installer_tags["exp-labs"],
    str(adapter.get("minimum_media_size_bytes", "")),
    adapter.get("output_kind", ""),
    json.dumps(adapter.get("runtime_prompts_kept", [])),
]
print("\n".join(values))
PY
)"
mapfile -t adapter_fields <<<"${adapter_dump}"
[[ "${#adapter_fields[@]}" -eq 22 ]] || die "failed to load vendored woodbox adapter metadata"
OS_REPO="${adapter_fields[0]}"
OS_CATALOG_TAG="${adapter_fields[1]}"
OS_CHANNEL_TAG_STABLE="${adapter_fields[2]}"
OS_CHANNEL_TAG_BETA="${adapter_fields[3]}"
OS_CHANNEL_TAG_NIGHTLY="${adapter_fields[4]}"
OS_CHANNEL_TAG_EXP_LABS="${adapter_fields[5]}"
EXPECTED_OS_ARTIFACT_TYPE="${adapter_fields[6]}"
EXPECTED_AIRGAP_ARCH="${adapter_fields[7]}"
AIRGAP_REPO="${adapter_fields[8]}"
AIRGAP_CATALOG_TAG="${adapter_fields[9]}"
AIRGAP_CHANNEL_TAG_STABLE="${adapter_fields[10]}"
AIRGAP_CHANNEL_TAG_BETA="${adapter_fields[11]}"
AIRGAP_CHANNEL_TAG_NIGHTLY="${adapter_fields[12]}"
AIRGAP_CHANNEL_TAG_EXP_LABS="${adapter_fields[13]}"
INSTALLER_REPO="${adapter_fields[14]}"
INSTALLER_CHANNEL_TAG_STABLE="${adapter_fields[15]}"
INSTALLER_CHANNEL_TAG_BETA="${adapter_fields[16]}"
INSTALLER_CHANNEL_TAG_NIGHTLY="${adapter_fields[17]}"
INSTALLER_CHANNEL_TAG_EXP_LABS="${adapter_fields[18]}"
MINIMUM_MEDIA_SIZE_BYTES="${adapter_fields[19]}"
OUTPUT_KIND="${adapter_fields[20]}"
ADAPTER_RUNTIME_PROMPTS_JSON="${adapter_fields[21]}"

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

root_backing_disk() {
  local root_src=""
  local root_real=""
  local root_parent=""

  need_cmd findmnt
  need_cmd readlink
  need_cmd lsblk

  root_src="$(findmnt -nr -o SOURCE / 2>/dev/null || true)"
  root_real="$(readlink -f "${root_src}" 2>/dev/null || echo "${root_src}")"
  root_parent="$(lsblk -no PKNAME "${root_real}" 2>/dev/null || true)"
  if [[ -n "${root_parent}" ]]; then
    printf '/dev/%s\n' "${root_parent}"
  else
    printf '%s\n' "${root_real}"
  fi
}

preferred_byid_for_disk() {
  local disk="$1"
  local best=""
  local path=""
  local target=""
  local base=""

  need_cmd readlink

  for path in /dev/disk/by-id/*; do
    [[ -L "${path}" ]] || continue
    [[ "${path}" == *-part* ]] && continue
    target="$(readlink -f "${path}" 2>/dev/null || true)"
    [[ "${target}" == "${disk}" ]] || continue

    base="$(basename "${path}")"
    if [[ "${base}" == usb-* ]]; then
      printf '%s\n' "${path}"
      return 0
    fi
    [[ -z "${best}" ]] && best="${path}"
  done

  [[ -n "${best}" ]] && printf '%s\n' "${best}"
}

is_candidate_media_disk() {
  local disk="$1"
  local root_disk="$2"
  local type=""
  local tran=""
  local rm=""

  need_cmd lsblk

  type="$(lsblk -dn -o TYPE "${disk}" 2>/dev/null | tr -d '[:space:]')"
  [[ "${type}" == "disk" ]] || return 1
  [[ "${disk}" != "${root_disk}" ]] || return 1

  tran="$(lsblk -dn -o TRAN "${disk}" 2>/dev/null | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
  rm="$(lsblk -dn -o RM "${disk}" 2>/dev/null | tr -d '[:space:]')"
  [[ "${tran}" == "usb" || "${rm}" == "1" ]] || return 1
  return 0
}

declare -a TARGET_MEDIA_CANDIDATES=()

refresh_target_media_candidates() {
  local root_disk="$1"
  local disk=""

  TARGET_MEDIA_CANDIDATES=()
  while read -r disk; do
    [[ -n "${disk}" ]] || continue
    if is_candidate_media_disk "${disk}" "${root_disk}"; then
      TARGET_MEDIA_CANDIDATES+=("${disk}")
    fi
  done < <(lsblk -dn -o NAME,TYPE | awk '$2=="disk" {print "/dev/"$1}')
}

print_target_media_candidates() {
  local idx=""
  local disk=""
  local size=""
  local tran=""
  local model=""
  local serial=""
  local byid=""

  echo
  echo "Detected removable/USB target candidates:"
  echo
  printf '  %-3s %-14s %-8s %-6s %-22s %-14s\n' "#" "Device" "Size" "Tran" "Model" "Serial"
  for idx in "${!TARGET_MEDIA_CANDIDATES[@]}"; do
    disk="${TARGET_MEDIA_CANDIDATES[$idx]}"
    size="$(lsblk -dn -o SIZE "${disk}" 2>/dev/null | tr -d '[:space:]')"
    tran="$(lsblk -dn -o TRAN "${disk}" 2>/dev/null | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
    model="$(lsblk -dn -o MODEL "${disk}" 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    serial="$(lsblk -dn -o SERIAL "${disk}" 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [[ -n "${tran}" ]] || tran="-"
    [[ -n "${model}" ]] || model="-"
    [[ -n "${serial}" ]] || serial="-"
    printf '  %-3s %-14s %-8s %-6s %-22.22s %-14.14s\n' "$((idx + 1))" "${disk}" "${size}" "${tran}" "${model}" "${serial}"

    byid="$(preferred_byid_for_disk "${disk}" || true)"
    if [[ -n "${byid}" ]]; then
      echo "      by-id: ${byid}"
    fi

    echo "      partitions (name fstype label mountpoints):"
    lsblk -nr -o NAME,FSTYPE,LABEL,MOUNTPOINTS "${disk}" 2>/dev/null | sed 's/^/        /'
  done
  echo
}

validate_target_flash_device_or_die() {
  local target="$1"
  local target_real=""
  local target_type=""
  local root_disk=""

  need_cmd lsblk
  need_cmd readlink

  [[ -n "${target}" ]] || die "target device is empty"
  [[ "${target}" != *"<"* && "${target}" != *">"* ]] || die "target contains angle brackets; use a real /dev path"
  [[ -e "${target}" ]] || die "target device does not exist: ${target}"

  target_real="$(readlink -f "${target}")"
  target_type="$(lsblk -dn -o TYPE "${target_real}" 2>/dev/null | tr -d '[:space:]')"
  [[ "${target_type}" == "disk" ]] || die "target is not a raw disk: ${target_real}"

  root_disk="$(root_backing_disk)"
  [[ "${target_real}" != "${root_disk}" ]] || die "refusing target that backs / (${root_disk})"
}

select_target_flash_device_interactive() {
  local choice=""
  local idx=""
  local selected=""
  local byid=""
  local confirm=""
  local root_disk=""

  root_disk="$(root_backing_disk)"
  while true; do
    refresh_target_media_candidates "${root_disk}"
    if (( ${#TARGET_MEDIA_CANDIDATES[@]} == 0 )); then
      echo
      echo "No removable/USB disk candidates found."
      echo "Insert the target USB media, then rescan."
      read -r -p "Press ENTER to rescan, or type q to quit: " choice
      [[ "${choice}" == "q" || "${choice}" == "Q" ]] && die "no target media selected"
      continue
    fi

    print_target_media_candidates
    read -r -p "Select target number (r=rescan, q=quit): " choice
    case "${choice}" in
      r|R) continue ;;
      q|Q) die "operator canceled target media selection" ;;
    esac

    [[ "${choice}" =~ ^[0-9]+$ ]] || {
      log "Invalid selection: ${choice}"
      continue
    }
    idx="$((choice - 1))"
    if (( idx < 0 || idx >= ${#TARGET_MEDIA_CANDIDATES[@]} )); then
      log "Selection out of range: ${choice}"
      continue
    fi

    selected="${TARGET_MEDIA_CANDIDATES[$idx]}"
    byid="$(preferred_byid_for_disk "${selected}" || true)"
    if [[ -n "${byid}" ]]; then
      selected="${byid}"
    fi

    validate_target_flash_device_or_die "${selected}"
    echo
    lsblk -o NAME,SIZE,MODEL,SERIAL,TYPE,FSTYPE,LABEL,MOUNTPOINTS "${selected}" || true
    echo
    read -r -p "Type SELECT to use ${selected}: " confirm
    [[ "${confirm}" == "SELECT" ]] || {
      log "Selection not confirmed; returning to list"
      continue
    }
    FLASH_DEVICE="${selected}"
    return 0
  done
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
from datetime import datetime, timezone
import re
import sys

def parse_created(value: str):
    value = value.strip()
    if not value:
        return None
    if value.endswith("Z") or value.endswith("z"):
        value = value[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(value)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        else:
            dt = dt.astimezone(timezone.utc)
        return dt
    except ValueError:
        return None

catalog_tsv = sys.argv[1]
channel = sys.argv[2]
rows = []
with open(catalog_tsv, "r", encoding="utf-8") as handle:
    reader = csv.DictReader(handle, delimiter="\t")
    for row in reader:
        row_channel = (row.get("channel") or "").strip()
        pinned_ref = (row.get("pinned_ref") or "").strip()
        created = (row.get("created") or "").strip()
        created_key = parse_created(created)
        if created_key is None:
            continue
        if row_channel not in {channel, f"x86-{channel}"}:
            continue
        if not re.fullmatch(r"[^\s]+@sha256:[0-9a-f]{64}", pinned_ref):
            continue
        rows.append((created_key, pinned_ref))

if not rows:
    raise SystemExit(1)

rows.sort(key=lambda item: item[0], reverse=True)
print(rows[0][1])
PY
}

normalize_release_channel() {
  local channel="${1:-}"

  case "${channel}" in
    x86-stable) printf '%s\n' "stable" ;;
    x86-beta) printf '%s\n' "beta" ;;
    x86-nightly) printf '%s\n' "nightly" ;;
    x86-exp-labs) printf '%s\n' "exp-labs" ;;
    *) printf '%s\n' "${channel}" ;;
  esac
}

os_channel_tag_for() {
  local channel="${1:-}"

  case "${channel}" in
    stable) printf '%s\n' "${OS_CHANNEL_TAG_STABLE}" ;;
    beta) printf '%s\n' "${OS_CHANNEL_TAG_BETA}" ;;
    nightly) printf '%s\n' "${OS_CHANNEL_TAG_NIGHTLY}" ;;
    exp-labs) printf '%s\n' "${OS_CHANNEL_TAG_EXP_LABS}" ;;
    *) printf '%s\n' "x86-${channel}" ;;
  esac
}

airgap_channel_tag_for() {
  local channel="${1:-}"

  case "${channel}" in
    stable) printf '%s\n' "${AIRGAP_CHANNEL_TAG_STABLE}" ;;
    beta) printf '%s\n' "${AIRGAP_CHANNEL_TAG_BETA}" ;;
    nightly) printf '%s\n' "${AIRGAP_CHANNEL_TAG_NIGHTLY}" ;;
    exp-labs) printf '%s\n' "${AIRGAP_CHANNEL_TAG_EXP_LABS}" ;;
    *) printf '%s\n' "${channel}-${EXPECTED_AIRGAP_ARCH}" ;;
  esac
}

installer_channel_tag_for() {
  local channel="${1:-}"

  case "${channel}" in
    stable) printf '%s\n' "${INSTALLER_CHANNEL_TAG_STABLE}" ;;
    beta) printf '%s\n' "${INSTALLER_CHANNEL_TAG_BETA}" ;;
    nightly) printf '%s\n' "${INSTALLER_CHANNEL_TAG_NIGHTLY}" ;;
    exp-labs) printf '%s\n' "${INSTALLER_CHANNEL_TAG_EXP_LABS}" ;;
    *) printf '%s\n' "${OURBOX_TARGET:-x86}-installer-${channel}" ;;
  esac
}

selected_installer_release_channel() {
  case "${SELECTED_OS_RELEASE_CHANNEL:-}" in
    stable|beta|nightly|exp-labs) printf '%s\n' "${SELECTED_OS_RELEASE_CHANNEL}" ;;
    *) printf '%s\n' "stable" ;;
  esac
}

verify_installer_substrate_cache_dir() {
  local cache_dir="$1"
  local iso_path="${cache_dir}/installer.iso"
  local sha_path="${cache_dir}/installer.iso.sha256"
  local expected=""
  local actual=""

  [[ -f "${iso_path}" ]] || die "installer substrate missing installer.iso in ${cache_dir}"
  [[ -f "${sha_path}" ]] || die "installer substrate missing installer.iso.sha256 in ${cache_dir}"
  expected="$(awk 'NF>=1 {print $1; exit}' "${sha_path}")"
  expected="${expected,,}"
  [[ "${expected}" =~ ^[0-9a-f]{64}$ ]] || die "invalid sha256 in ${sha_path}"
  actual="$(sha256sum "${iso_path}" | awk '{print $1}')"
  [[ "${expected}" == "${actual}" ]] || die "installer substrate sha mismatch (expected ${expected}, got ${actual})"
}

list_os_catalog_entries() {
  local catalog_tsv="$1"

  python3 - <<'PY' "${catalog_tsv}"
import csv
from datetime import datetime, timezone
import re
import sys

def parse_created(value: str):
    value = value.strip()
    if not value:
        return None
    if value.endswith("Z") or value.endswith("z"):
        value = value[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(value)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        else:
            dt = dt.astimezone(timezone.utc)
        return dt
    except ValueError:
        return None

catalog_tsv = sys.argv[1]
rows = []
with open(catalog_tsv, "r", encoding="utf-8") as handle:
    reader = csv.DictReader(handle, delimiter="\t")
    for row in reader:
        row_channel = (row.get("channel") or "").strip()
        tag = (row.get("tag") or "").strip()
        created = (row.get("created") or "").strip()
        version = (row.get("version") or "").strip()
        contract = (row.get("platform_contract_digest") or "").strip()
        pinned_ref = (row.get("pinned_ref") or "").strip()
        created_key = parse_created(created)
        if created_key is None:
            continue
        if not re.fullmatch(r"[^\s]+@sha256:[0-9a-f]{64}", pinned_ref):
            continue
        rows.append((created_key, created, row_channel, tag, version, contract, pinned_ref))

rows.sort(key=lambda item: (item[0], item[3]), reverse=True)
for _created_key, created, row_channel, tag, version, contract, pinned_ref in rows:
    print("\t".join((row_channel, tag, created, version, contract, pinned_ref)))
PY
}

select_airgap_ref_from_catalog() {
  local catalog_tsv="$1"
  local channel="$2"
  local required_contract_digest="$3"
  local required_arch="$4"

  python3 - <<'PY' "${catalog_tsv}" "${channel}" "${required_contract_digest}" "${required_arch}"
import csv
from datetime import datetime, timezone
import re
import sys

def parse_created(value: str):
    value = value.strip()
    if not value:
        return None
    if value.endswith("Z") or value.endswith("z"):
        value = value[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(value)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        else:
            dt = dt.astimezone(timezone.utc)
        return dt
    except ValueError:
        return None

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
        created_key = parse_created(created)
        if created_key is None:
            continue
        if row_channel != channel:
            continue
        if row_arch != arch or row_digest != digest:
            continue
        if not re.fullmatch(r"[^\s]+@sha256:[0-9a-f]{64}", pinned_ref):
            continue
        rows.append((created_key, pinned_ref))

if not rows:
    raise SystemExit(1)

rows.sort(key=lambda item: item[0], reverse=True)
print(rows[0][1])
PY
}

list_airgap_catalog_entries() {
  local catalog_tsv="$1"
  local required_contract_digest="$2"
  local required_arch="$3"

  python3 - <<'PY' "${catalog_tsv}" "${required_contract_digest}" "${required_arch}"
import csv
from datetime import datetime, timezone
import re
import sys

def parse_created(value: str):
    value = value.strip()
    if not value:
        return None
    if value.endswith("Z") or value.endswith("z"):
        value = value[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(value)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        else:
            dt = dt.astimezone(timezone.utc)
        return dt
    except ValueError:
        return None

catalog_tsv, digest, arch = sys.argv[1:]
rows = []
with open(catalog_tsv, "r", encoding="utf-8") as handle:
    reader = csv.DictReader(handle, delimiter="\t")
    for row in reader:
        row_channel = (row.get("channel") or "").strip()
        tag = (row.get("tag") or "").strip()
        created = (row.get("created") or "").strip()
        version = (row.get("version") or "").strip()
        row_arch = (row.get("arch") or "").strip()
        row_digest = (row.get("platform_contract_digest") or "").strip()
        pinned_ref = (row.get("pinned_ref") or "").strip()
        created_key = parse_created(created)
        if created_key is None:
            continue
        if row_arch != arch or row_digest != digest:
            continue
        if not re.fullmatch(r"[^\s]+@sha256:[0-9a-f]{64}", pinned_ref):
            continue
        rows.append((created_key, created, row_channel, tag, version, row_digest, pinned_ref))

rows.sort(key=lambda item: (item[0], item[3]), reverse=True)
for _created_key, created, row_channel, tag, version, row_digest, pinned_ref in rows:
    print("\t".join((row_channel, tag, created, version, row_digest, pinned_ref)))
PY
}

render_os_catalog_entry() {
  local display_number="$1"
  local entry="$2"
  local channel=""
  local tag=""
  local created=""
  local version=""
  local contract=""
  local pinned_ref=""

  IFS=$'\t' read -r channel tag created version contract pinned_ref <<<"${entry}"
  printf "  %d) %-12s %-30s %s %s %s\n" "${display_number}" "${channel}" "${tag}" "${version}" "${created}" "${contract}"
}

render_airgap_catalog_entry() {
  local display_number="$1"
  local entry="$2"
  local channel=""
  local tag=""
  local created=""
  local version=""
  local contract=""
  local pinned_ref=""

  IFS=$'\t' read -r channel tag created version contract pinned_ref <<<"${entry}"
  printf "  %d) %-10s %-24s %s %s %s\n" "${display_number}" "${channel}" "${tag}" "${version}" "${created}" "${contract}"
}

paginate_catalog_entries_interactive() {
  local title="$1"
  local entries_name="$2"
  local render_fn="$3"
  local outvar="$4"
  local pick=""
  local page_size=10
  local page=0
  local total=0
  local page_count=0
  local start=0
  local end=0
  local visible_count=0
  local entry_number=1
  local selected_index=0
  local -n entries_ref="${entries_name}"

  total="${#entries_ref[@]}"
  (( total > 0 )) || return 1
  page_count=$(((total + page_size - 1) / page_size))

  while true; do
    start=$((page * page_size))
    end=$((start + page_size))
    if (( end > total )); then
      end="${total}"
    fi
    visible_count=$((end - start))

    echo
    echo "${title} (page $((page + 1))/${page_count}, newest first, showing $((start + 1))-${end} of ${total}):"
    for ((entry_number = 1; entry_number <= visible_count; entry_number++)); do
      "${render_fn}" "${entry_number}" "${entries_ref[$((start + entry_number - 1))]}"
    done

    echo "Options:"
    echo "  [1-${visible_count}] Select row on this page"
    if (( page + 1 < page_count )); then
      echo "  n       Next page"
    fi
    if (( page > 0 )); then
      echo "  p       Previous page"
    fi
    echo "  [ENTER] Cancel"
    echo "  q       Cancel"
    echo

    read -r -p "Choice: " pick
    case "${pick}" in
      "")
        return 1
        ;;
      q|Q)
        return 1
        ;;
      n|N)
        if (( page + 1 < page_count )); then
          page=$((page + 1))
        else
          log "Already on the last page."
        fi
        ;;
      p|P)
        if (( page > 0 )); then
          page=$((page - 1))
        else
          log "Already on the first page."
        fi
        ;;
      *)
        if [[ ! "${pick}" =~ ^[0-9]+$ ]]; then
          log "Invalid selection."
          continue
        fi
        if (( pick < 1 || pick > visible_count )); then
          log "Selection out of range."
          continue
        fi

        selected_index=$((start + pick - 1))
        printf -v "${outvar}" '%s' "${entries_ref[selected_index]}"
        return 0
        ;;
    esac
  done
}

resolve_os_channel_ref() {
  local channel="$1"
  local catalog_cache_dir=""
  local catalog_tsv=""
  local catalog_ref=""
  local channel_tag_ref="${OS_REPO}:$(os_channel_tag_for "${channel}")"

  if try_cache_pull_oci_artifact "${OS_REPO}:${OS_CATALOG_TAG}" "${CACHE_REUSE_ENABLED}" catalog_cache_dir; then
    catalog_tsv="$(find_pulled_file "${catalog_cache_dir}" "catalog.tsv")"
    if [[ -n "${catalog_tsv}" ]]; then
      catalog_ref="$(select_os_ref_from_catalog "${catalog_tsv}" "${channel}" || true)"
      if is_pinned_ref "${catalog_ref}"; then
        SELECTED_OS_SELECTION_SOURCE="catalog"
        SELECTED_OS_RELEASE_CHANNEL="${channel}"
        SELECTED_OS_REF="${catalog_ref}"
        return 0
      fi
    fi
    log "OS catalog ${OS_REPO}:${OS_CATALOG_TAG} had no valid pinned row for channel ${channel}; falling back to channel tag"
  else
    log "OS catalog ${OS_REPO}:${OS_CATALOG_TAG} unavailable; falling back to channel tag"
  fi

  SELECTED_OS_SELECTION_SOURCE="channel-tag"
  SELECTED_OS_RELEASE_CHANNEL="${channel}"
  SELECTED_OS_REF="${channel_tag_ref}"
}

show_os_default_choice() {
  local ref="$1"

  echo
  echo "Host-side OS selection"
  echo "Default source : ${SELECTED_OS_SELECTION_SOURCE:-pending}"
  echo "Default: install '${ref}'"
  echo "Options:"
  echo "  [ENTER] Use default"
  echo "  c       Choose channel (prefers newest catalog row for that lane)"
  echo "  l       List from catalog (if available)"
  echo "  r       Enter custom OCI ref (tag or digest)"
  echo "  o       Override OS repo (custom registry/fork)"
  echo "  q       Quit"
  echo
}

choose_os_channel_interactive() {
  local pick=""
  local custom_tag=""

  echo "Channels:"
  echo "  1) stable (${OS_CHANNEL_TAG_STABLE}) (recommended)"
  echo "  2) beta (${OS_CHANNEL_TAG_BETA})"
  echo "  3) nightly (${OS_CHANNEL_TAG_NIGHTLY})"
  echo "  4) exp-labs (${OS_CHANNEL_TAG_EXP_LABS})"
  echo "  5) custom tag name"

  read -r -p "Select channel [1-5]: " pick
  case "${pick}" in
    1|"") OS_CHANNEL="stable" ;;
    2) OS_CHANNEL="beta" ;;
    3) OS_CHANNEL="nightly" ;;
    4) OS_CHANNEL="exp-labs" ;;
    5)
      read -r -p "Enter tag: " custom_tag
      [[ -n "${custom_tag}" ]] || {
        log "Tag cannot be empty."
        return 1
      }
      SELECTED_OS_REF="${OS_REPO}:${custom_tag}"
      SELECTED_OS_SELECTION_SOURCE="channel-tag"
      SELECTED_OS_RELEASE_CHANNEL=""
      return 0
      ;;
    *)
      log "Invalid choice."
      return 1
      ;;
  esac

  resolve_os_channel_ref "${OS_CHANNEL}"
}

select_os_ref_from_catalog_interactive() {
  local catalog_cache_dir=""
  local catalog_tsv=""
  local chosen=""
  local normalized_channel=""
  local channel=""
  local tag=""
  local created=""
  local version=""
  local contract=""
  local pinned_ref=""
  local -a entries=()

  if ! try_cache_pull_oci_artifact "${OS_REPO}:${OS_CATALOG_TAG}" "${CACHE_REUSE_ENABLED}" catalog_cache_dir; then
    log "Catalog unavailable; skipping list."
    return 1
  fi

  catalog_tsv="$(find_pulled_file "${catalog_cache_dir}" "catalog.tsv")"
  mapfile -t entries < <(list_os_catalog_entries "${catalog_tsv}")
  if [[ "${#entries[@]}" -eq 0 ]]; then
    log "Catalog pulled (${OS_REPO}:${OS_CATALOG_TAG}) but contained no valid entries."
    return 1
  fi

  paginate_catalog_entries_interactive "Catalog entries (${OS_REPO}:${OS_CATALOG_TAG})" entries render_os_catalog_entry chosen || return 1
  IFS=$'\t' read -r channel tag created version contract pinned_ref <<<"${chosen}"
  normalized_channel="$(normalize_release_channel "${channel}")"
  OS_CHANNEL="${normalized_channel}"
  SELECTED_OS_REF="${pinned_ref}"
  SELECTED_OS_SELECTION_SOURCE="catalog"
  SELECTED_OS_RELEASE_CHANNEL="${normalized_channel}"
  log "Selected ${SELECTED_OS_REF} (channel=${normalized_channel}, version=${version}, contract=${contract})"
}

prompt_custom_os_ref_interactive() {
  local ref=""

  read -r -p "Enter full OCI ref (e.g., repo:tag or repo@sha256:...): " ref
  [[ -n "${ref}" && "${ref}" != *[[:space:]]* ]] || {
    log "Ref must be a single-line OCI ref without whitespace."
    return 1
  }

  SELECTED_OS_REF="${ref}"
  SELECTED_OS_SELECTION_SOURCE="operator-override"
  SELECTED_OS_RELEASE_CHANNEL=""
}

override_os_repo_interactive() {
  local next_repo=""
  local next_catalog="x86-catalog"
  local user_catalog=""

  read -r -p "Enter OCI repo (e.g., ghcr.io/org/ourbox-os): " next_repo
  [[ -n "${next_repo}" ]] || {
    log "Repository cannot be empty."
    return 1
  }

  OS_REPO="${next_repo}"
  read -r -p "Catalog tag [${next_catalog}]: " user_catalog
  if [[ -n "${user_catalog}" ]]; then
    OS_CATALOG_TAG="${user_catalog}"
  else
    OS_CATALOG_TAG="${next_catalog}"
  fi

  log "OS repo override set to ${OS_REPO}"
}

interactive_select_os_ref() {
  local choice=""
  local default_ref=""
  local default_source=""
  local default_channel=""

  SELECTED_OS_REF=""
  SELECTED_OS_SELECTION_SOURCE=""
  SELECTED_OS_RELEASE_CHANNEL=""

  while [[ -z "${SELECTED_OS_REF}" ]]; do
    resolve_os_channel_ref "${OS_CHANNEL}"
    default_ref="${SELECTED_OS_REF}"
    default_source="${SELECTED_OS_SELECTION_SOURCE}"
    default_channel="${SELECTED_OS_RELEASE_CHANNEL}"
    SELECTED_OS_REF=""

    show_os_default_choice "${default_ref}"
    read -r -p "Choice: " choice

    case "${choice}" in
      "")
        SELECTED_OS_REF="${default_ref}"
        SELECTED_OS_SELECTION_SOURCE="${default_source}"
        SELECTED_OS_RELEASE_CHANNEL="${default_channel}"
        ;;
      c)
        choose_os_channel_interactive || true
        ;;
      l)
        select_os_ref_from_catalog_interactive || true
        ;;
      r)
        prompt_custom_os_ref_interactive || true
        ;;
      o)
        override_os_repo_interactive || true
        ;;
      q|Q)
        die "Mission compose aborted by user"
        ;;
      *)
        log "Unknown option."
        ;;
    esac
  done
}

determine_os_ref() {
  if [[ -n "${OS_REF}" ]]; then
    SELECTED_OS_SELECTION_SOURCE="os-ref"
    SELECTED_OS_RELEASE_CHANNEL=""
    SELECTED_OS_REF="${OS_REF}"
    return 0
  fi

  if interactive_selection_enabled; then
    interactive_select_os_ref
    return 0
  fi

  resolve_os_channel_ref "${OS_CHANNEL}"
}

resolve_airgap_channel_ref() {
  local required_contract_digest="$1"
  local channel="$2"
  local catalog_cache_dir=""
  local catalog_tsv=""
  local catalog_ref=""
  local channel_tag_ref="${AIRGAP_REPO}:$(airgap_channel_tag_for "${channel}")"

  if try_cache_pull_oci_artifact "${AIRGAP_REPO}:${AIRGAP_CATALOG_TAG}" "${CACHE_REUSE_ENABLED}" catalog_cache_dir; then
    catalog_tsv="$(find_pulled_file "${catalog_cache_dir}" "catalog.tsv")"
    if [[ -n "${catalog_tsv}" ]]; then
      catalog_ref="$(select_airgap_ref_from_catalog "${catalog_tsv}" "${channel}" "${required_contract_digest}" "${EXPECTED_AIRGAP_ARCH}" || true)"
      if is_pinned_ref "${catalog_ref}"; then
        SELECTED_AIRGAP_SELECTION_MODE="host-selected"
        SELECTED_AIRGAP_SELECTION_SOURCE="catalog"
        SELECTED_AIRGAP_RELEASE_CHANNEL="${channel}"
        SELECTED_AIRGAP_REF="${catalog_ref}"
        return 0
      fi
    fi
    log "Airgap catalog ${AIRGAP_REPO}:${AIRGAP_CATALOG_TAG} had no valid pinned row for channel ${channel} and contract ${required_contract_digest}; falling back to channel tag"
  else
    log "Airgap catalog ${AIRGAP_REPO}:${AIRGAP_CATALOG_TAG} unavailable; falling back to channel tag"
  fi

  SELECTED_AIRGAP_SELECTION_MODE="host-selected"
  SELECTED_AIRGAP_SELECTION_SOURCE="channel-tag"
  SELECTED_AIRGAP_RELEASE_CHANNEL="${channel}"
  SELECTED_AIRGAP_REF="${channel_tag_ref}"
}

resolve_default_airgap_ref() {
  local required_contract_digest="$1"

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

  resolve_airgap_channel_ref "${required_contract_digest}" "${AIRGAP_CHANNEL}"
}

show_airgap_default_choice() {
  local ref="$1"

  echo
  echo "Host-side airgap selection"
  echo "Default source : ${SELECTED_AIRGAP_SELECTION_SOURCE:-pending}"
  echo "Default: use airgap bundle '${ref}'"
  echo "Options:"
  echo "  [ENTER] Use default"
  echo "  c       Choose channel (prefers newest contract-matching catalog row for that lane)"
  echo "  l       List from catalog (if available)"
  echo "  r       Enter custom OCI ref (tag or digest)"
  echo "  o       Override airgap repo (custom registry/fork)"
  echo "  q       Quit"
  echo
}

choose_airgap_channel_interactive() {
  local required_contract_digest="$1"
  local pick=""
  local custom_tag=""

  echo "Channels:"
  echo "  1) stable (${AIRGAP_CHANNEL_TAG_STABLE}) (recommended)"
  echo "  2) beta (${AIRGAP_CHANNEL_TAG_BETA})"
  echo "  3) nightly (${AIRGAP_CHANNEL_TAG_NIGHTLY})"
  echo "  4) exp-labs (${AIRGAP_CHANNEL_TAG_EXP_LABS})"
  echo "  5) custom tag name"

  read -r -p "Select channel [1-5]: " pick
  case "${pick}" in
    1|"") AIRGAP_CHANNEL="stable" ;;
    2) AIRGAP_CHANNEL="beta" ;;
    3) AIRGAP_CHANNEL="nightly" ;;
    4) AIRGAP_CHANNEL="exp-labs" ;;
    5)
      read -r -p "Enter tag: " custom_tag
      [[ -n "${custom_tag}" ]] || {
        log "Tag cannot be empty."
        return 1
      }
      SELECTED_AIRGAP_SELECTION_MODE="host-selected"
      SELECTED_AIRGAP_SELECTION_SOURCE="channel-tag"
      SELECTED_AIRGAP_RELEASE_CHANNEL=""
      SELECTED_AIRGAP_REF="${AIRGAP_REPO}:${custom_tag}"
      return 0
      ;;
    *)
      log "Invalid choice."
      return 1
      ;;
  esac

  resolve_airgap_channel_ref "${required_contract_digest}" "${AIRGAP_CHANNEL}"
}

select_airgap_ref_from_catalog_interactive() {
  local required_contract_digest="$1"
  local catalog_cache_dir=""
  local catalog_tsv=""
  local chosen=""
  local channel=""
  local tag=""
  local created=""
  local version=""
  local contract=""
  local pinned_ref=""
  local -a entries=()

  if ! try_cache_pull_oci_artifact "${AIRGAP_REPO}:${AIRGAP_CATALOG_TAG}" "${CACHE_REUSE_ENABLED}" catalog_cache_dir; then
    log "Airgap catalog unavailable; skipping list."
    return 1
  fi

  catalog_tsv="$(find_pulled_file "${catalog_cache_dir}" "catalog.tsv")"
  mapfile -t entries < <(list_airgap_catalog_entries "${catalog_tsv}" "${required_contract_digest}" "${EXPECTED_AIRGAP_ARCH}")
  if [[ "${#entries[@]}" -eq 0 ]]; then
    log "Airgap catalog pulled (${AIRGAP_REPO}:${AIRGAP_CATALOG_TAG}) but contained no matching rows for arch=${EXPECTED_AIRGAP_ARCH} contract=${required_contract_digest}."
    return 1
  fi

  paginate_catalog_entries_interactive "Airgap catalog entries (${AIRGAP_REPO}:${AIRGAP_CATALOG_TAG})" entries render_airgap_catalog_entry chosen || return 1
  IFS=$'\t' read -r channel tag created version contract pinned_ref <<<"${chosen}"
  AIRGAP_CHANNEL="$(normalize_release_channel "${channel}")"
  SELECTED_AIRGAP_SELECTION_MODE="host-selected"
  SELECTED_AIRGAP_SELECTION_SOURCE="catalog"
  SELECTED_AIRGAP_RELEASE_CHANNEL="${AIRGAP_CHANNEL}"
  SELECTED_AIRGAP_REF="${pinned_ref}"
  log "Selected ${SELECTED_AIRGAP_REF} (channel=${AIRGAP_CHANNEL}, version=${version}, contract=${contract})"
}

prompt_custom_airgap_ref_interactive() {
  local ref=""

  read -r -p "Enter full OCI ref (e.g., repo:tag or repo@sha256:...): " ref
  [[ -n "${ref}" && "${ref}" != *[[:space:]]* ]] || {
    log "Ref must be a single-line OCI ref without whitespace."
    return 1
  }

  SELECTED_AIRGAP_SELECTION_MODE="host-selected"
  SELECTED_AIRGAP_SELECTION_SOURCE="operator-override"
  SELECTED_AIRGAP_RELEASE_CHANNEL=""
  SELECTED_AIRGAP_REF="${ref}"
}

override_airgap_repo_interactive() {
  local next_repo=""
  local next_catalog="catalog-${EXPECTED_AIRGAP_ARCH}"
  local user_catalog=""

  read -r -p "Enter OCI repo (e.g., ghcr.io/org/airgap-platform): " next_repo
  [[ -n "${next_repo}" ]] || {
    log "Repository cannot be empty."
    return 1
  }

  AIRGAP_REPO="${next_repo}"
  read -r -p "Catalog tag [${next_catalog}]: " user_catalog
  if [[ -n "${user_catalog}" ]]; then
    AIRGAP_CATALOG_TAG="${user_catalog}"
  else
    AIRGAP_CATALOG_TAG="${next_catalog}"
  fi

  if [[ -z "${AIRGAP_CHANNEL}" ]]; then
    AIRGAP_CHANNEL="stable"
  fi

  log "Airgap repo override set to ${AIRGAP_REPO}"
}

interactive_select_airgap_ref() {
  local required_contract_digest="$1"
  local choice=""
  local default_ref=""
  local default_source=""
  local default_channel=""
  local default_mode=""

  SELECTED_AIRGAP_REF=""
  SELECTED_AIRGAP_SELECTION_MODE=""
  SELECTED_AIRGAP_SELECTION_SOURCE=""
  SELECTED_AIRGAP_RELEASE_CHANNEL=""

  while [[ -z "${SELECTED_AIRGAP_REF}" ]]; do
    resolve_default_airgap_ref "${required_contract_digest}"
    default_ref="${SELECTED_AIRGAP_REF}"
    default_mode="${SELECTED_AIRGAP_SELECTION_MODE}"
    default_source="${SELECTED_AIRGAP_SELECTION_SOURCE}"
    default_channel="${SELECTED_AIRGAP_RELEASE_CHANNEL}"
    SELECTED_AIRGAP_REF=""

    show_airgap_default_choice "${default_ref}"
    read -r -p "Choice: " choice

    case "${choice}" in
      "")
        SELECTED_AIRGAP_REF="${default_ref}"
        SELECTED_AIRGAP_SELECTION_MODE="${default_mode}"
        SELECTED_AIRGAP_SELECTION_SOURCE="${default_source}"
        SELECTED_AIRGAP_RELEASE_CHANNEL="${default_channel}"
        ;;
      c)
        choose_airgap_channel_interactive "${required_contract_digest}" || true
        ;;
      l)
        select_airgap_ref_from_catalog_interactive "${required_contract_digest}" || true
        ;;
      r)
        prompt_custom_airgap_ref_interactive || true
        ;;
      o)
        override_airgap_repo_interactive || true
        ;;
      q|Q)
        die "Mission compose aborted by user"
        ;;
      *)
        log "Unknown option."
        ;;
    esac
  done
}

determine_airgap_ref() {
  local required_contract_digest="$1"

  if [[ -n "${AIRGAP_REF}" ]]; then
    SELECTED_AIRGAP_SELECTION_MODE="explicit-ref"
    SELECTED_AIRGAP_SELECTION_SOURCE="airgap-ref"
    SELECTED_AIRGAP_RELEASE_CHANNEL=""
    SELECTED_AIRGAP_REF="${AIRGAP_REF}"
    return 0
  fi

  if interactive_selection_enabled; then
    interactive_select_airgap_ref "${required_contract_digest}"
    return 0
  fi

  resolve_default_airgap_ref "${required_contract_digest}"
}

initial_cache_refs=()
if [[ -n "${OS_REF}" ]]; then
  initial_cache_refs+=("${OS_REF}")
else
  initial_cache_refs+=("${OS_REPO}:${OS_CATALOG_TAG}" "${OS_REPO}:$(os_channel_tag_for "${OS_CHANNEL}")")
fi
if [[ -n "${AIRGAP_REF}" ]]; then
  initial_cache_refs+=("${AIRGAP_REF}")
else
  initial_cache_refs+=("${AIRGAP_REPO}:${AIRGAP_CATALOG_TAG}")
  if [[ -n "${AIRGAP_CHANNEL}" ]]; then
    initial_cache_refs+=("${AIRGAP_REPO}:$(airgap_channel_tag_for "${AIRGAP_CHANNEL}")")
  fi
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
  python3 "${VENDORED_METADATA_PARSER}" "${OS_META_ENV}" \
    --allow OS_PAYLOAD_BASENAME \
    --allow OS_PAYLOAD_SHA256 \
    --allow OS_PAYLOAD_SIZE_BYTES \
    --allow OS_ARTIFACT_TYPE \
    --allow OURBOX_PRODUCT \
    --allow OURBOX_DEVICE \
    --allow OURBOX_TARGET \
    --allow OURBOX_SKU \
    --allow OURBOX_VARIANT \
    --allow OURBOX_VERSION \
    --allow OURBOX_RECIPE_GIT_HASH \
    --allow BUILD_TS \
    --allow GIT_SHA \
    --allow OURBOX_PLATFORM_CONTRACT_SOURCE \
    --allow OURBOX_PLATFORM_CONTRACT_REVISION \
    --allow OURBOX_PLATFORM_CONTRACT_VERSION \
    --allow OURBOX_PLATFORM_CONTRACT_DIGEST \
    --allow OURBOX_AIRGAP_PLATFORM_REF \
    --allow OURBOX_AIRGAP_PLATFORM_DIGEST \
    --allow OURBOX_AIRGAP_PLATFORM_SOURCE \
    --allow OURBOX_AIRGAP_PLATFORM_REVISION \
    --allow OURBOX_AIRGAP_PLATFORM_VERSION \
    --allow OURBOX_AIRGAP_PLATFORM_CREATED \
    --allow OURBOX_AIRGAP_PLATFORM_ARCH \
    --allow OURBOX_AIRGAP_PLATFORM_PROFILE \
    --allow OURBOX_AIRGAP_PLATFORM_K3S_VERSION \
    --allow OURBOX_AIRGAP_PLATFORM_IMAGES_LOCK_SHA256 \
    --allow OURBOX_BASE_ISO_URL \
    --allow OURBOX_BASE_ISO_SHA256 \
    --allow K3S_VERSION \
    --allow GITHUB_RUN_ID \
    --allow GITHUB_RUN_ATTEMPT \
    --require OS_ARTIFACT_TYPE \
    --require OURBOX_PLATFORM_CONTRACT_DIGEST \
    --require OURBOX_AIRGAP_PLATFORM_REF \
    --require OURBOX_AIRGAP_PLATFORM_DIGEST \
    --require OURBOX_AIRGAP_PLATFORM_SOURCE \
    --require OURBOX_AIRGAP_PLATFORM_REVISION \
    --require OURBOX_AIRGAP_PLATFORM_VERSION \
    --require OURBOX_AIRGAP_PLATFORM_CREATED \
    --require OURBOX_AIRGAP_PLATFORM_ARCH \
    --require OURBOX_AIRGAP_PLATFORM_PROFILE \
    --require OURBOX_AIRGAP_PLATFORM_K3S_VERSION \
    --require OURBOX_AIRGAP_PLATFORM_IMAGES_LOCK_SHA256 \
    --print OS_ARTIFACT_TYPE \
    --print OURBOX_PLATFORM_CONTRACT_DIGEST \
    --print OURBOX_PLATFORM_CONTRACT_SOURCE \
    --print OURBOX_PLATFORM_CONTRACT_REVISION \
    --print OURBOX_PLATFORM_CONTRACT_VERSION \
    --print OURBOX_PLATFORM_CONTRACT_CREATED \
    --print OURBOX_AIRGAP_PLATFORM_REF \
    --print OURBOX_AIRGAP_PLATFORM_DIGEST \
    --print OURBOX_AIRGAP_PLATFORM_SOURCE \
    --print OURBOX_AIRGAP_PLATFORM_REVISION \
    --print OURBOX_AIRGAP_PLATFORM_VERSION \
    --print OURBOX_AIRGAP_PLATFORM_CREATED \
    --print OURBOX_AIRGAP_PLATFORM_ARCH \
    --print OURBOX_AIRGAP_PLATFORM_PROFILE \
    --print OURBOX_AIRGAP_PLATFORM_K3S_VERSION \
    --print OURBOX_AIRGAP_PLATFORM_IMAGES_LOCK_SHA256 \
    --print OURBOX_VERSION \
    --print OURBOX_VARIANT \
    --print OURBOX_TARGET \
    --print OURBOX_SKU
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
SELECTED_INSTALLER_SUBSTRATE_RELEASE_CHANNEL="$(selected_installer_release_channel)"
SELECTED_INSTALLER_SUBSTRATE_REF="${INSTALLER_REPO}:$(installer_channel_tag_for "${SELECTED_INSTALLER_SUBSTRATE_RELEASE_CHANNEL}")"
maybe_confirm_cache_reuse "the selected mission artifacts" "${SELECTED_OS_REF}" "${SELECTED_AIRGAP_REF}" "${SELECTED_INSTALLER_SUBSTRATE_REF}"
cache_pull_oci_artifact "${SELECTED_AIRGAP_REF}" "${CACHE_REUSE_ENABLED}" AIRGAP_CACHE_DIR
SELECTED_AIRGAP_DIGEST="${OURBOX_CACHE_LAST_DIGEST}"
SELECTED_AIRGAP_PINNED_REF="${OURBOX_CACHE_LAST_PINNED_REF}"

cache_pull_oci_artifact "${SELECTED_INSTALLER_SUBSTRATE_REF}" "${CACHE_REUSE_ENABLED}" INSTALLER_SUBSTRATE_CACHE_DIR
SELECTED_INSTALLER_SUBSTRATE_DIGEST="${OURBOX_CACHE_LAST_DIGEST}"
SELECTED_INSTALLER_SUBSTRATE_PINNED_REF="${OURBOX_CACHE_LAST_PINNED_REF}"
verify_installer_substrate_cache_dir "${INSTALLER_SUBSTRATE_CACHE_DIR}"
INSTALLER_SUBSTRATE_ISO="$(find_pulled_file "${INSTALLER_SUBSTRATE_CACHE_DIR}" "installer.iso")"
[[ -f "${INSTALLER_SUBSTRATE_ISO}" ]] || die "cached installer substrate missing installer.iso: ${INSTALLER_SUBSTRATE_CACHE_DIR}"

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
  python3 "${VENDORED_METADATA_PARSER}" "${AIRGAP_MANIFEST}" \
    --allow OURBOX_AIRGAP_PLATFORM_SCHEMA \
    --allow OURBOX_AIRGAP_PLATFORM_KIND \
    --allow OURBOX_AIRGAP_PLATFORM_SOURCE \
    --allow OURBOX_AIRGAP_PLATFORM_REVISION \
    --allow OURBOX_AIRGAP_PLATFORM_VERSION \
    --allow OURBOX_AIRGAP_PLATFORM_CREATED \
    --allow OURBOX_PLATFORM_CONTRACT_REF \
    --allow OURBOX_PLATFORM_CONTRACT_DIGEST \
    --allow AIRGAP_PLATFORM_ARCH \
    --allow K3S_VERSION \
    --allow OURBOX_PLATFORM_PROFILE \
    --allow OURBOX_PLATFORM_IMAGES_LOCK_PATH \
    --allow OURBOX_PLATFORM_IMAGES_LOCK_SHA256 \
    --require OURBOX_AIRGAP_PLATFORM_SOURCE \
    --require OURBOX_AIRGAP_PLATFORM_REVISION \
    --require OURBOX_AIRGAP_PLATFORM_VERSION \
    --require OURBOX_AIRGAP_PLATFORM_CREATED \
    --require OURBOX_PLATFORM_CONTRACT_DIGEST \
    --require AIRGAP_PLATFORM_ARCH \
    --require K3S_VERSION \
    --require OURBOX_PLATFORM_PROFILE \
    --require OURBOX_PLATFORM_IMAGES_LOCK_PATH \
    --require OURBOX_PLATFORM_IMAGES_LOCK_SHA256 \
    --print OURBOX_AIRGAP_PLATFORM_SOURCE \
    --print OURBOX_AIRGAP_PLATFORM_REVISION \
    --print OURBOX_AIRGAP_PLATFORM_VERSION \
    --print OURBOX_AIRGAP_PLATFORM_CREATED \
    --print OURBOX_PLATFORM_CONTRACT_REF \
    --print OURBOX_PLATFORM_CONTRACT_DIGEST \
    --print AIRGAP_PLATFORM_ARCH \
    --print K3S_VERSION \
    --print OURBOX_PLATFORM_PROFILE \
    --print OURBOX_PLATFORM_IMAGES_LOCK_PATH \
    --print OURBOX_PLATFORM_IMAGES_LOCK_SHA256
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

STAGING_OUTPUT_DIR="${TMP_ROOT}/prepared-output"
MISSION_DIR="${STAGING_OUTPUT_DIR}/mission"
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
export VENDORED_ADAPTER_ROOT ADAPTER_RUNTIME_PROMPTS_JSON MINIMUM_MEDIA_SIZE_BYTES OUTPUT_KIND
export SELECTED_INSTALLER_SUBSTRATE_PINNED_REF SELECTED_INSTALLER_SUBSTRATE_DIGEST SELECTED_INSTALLER_SUBSTRATE_RELEASE_CHANNEL
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
        "strategy": "published-installer-substrate",
        "artifact_ref": os.environ["SELECTED_INSTALLER_SUBSTRATE_PINNED_REF"],
        "artifact_digest": os.environ["SELECTED_INSTALLER_SUBSTRATE_DIGEST"],
        "release_channel": os.environ["SELECTED_INSTALLER_SUBSTRATE_RELEASE_CHANNEL"],
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

python3 "${MISSION_SCHEMA_VALIDATOR}" "${MISSION_SCHEMA}" "${MISSION_DIR}/mission-manifest.json"
bash "${VENDORED_ADAPTER_ROOT}/validate-media.sh" \
  --mission-dir "${MISSION_DIR}" \
  --os-payload "${OS_STAGE_DIR}/os-payload.tar.gz" \
  --os-meta-env "${OS_STAGE_DIR}/os.meta.env"

log "Selected OS artifact: ${SELECTED_OS_PINNED_REF} (${SELECTED_OS_SELECTION_SOURCE})"
log "Selected airgap bundle: ${SELECTED_AIRGAP_PINNED_REF} (${SELECTED_AIRGAP_SELECTION_SOURCE})"
log "Selected installer substrate: ${SELECTED_INSTALLER_SUBSTRATE_PINNED_REF} (${SELECTED_INSTALLER_SUBSTRATE_RELEASE_CHANNEL})"

if [[ "${MISSION_ONLY}" == "1" ]]; then
  mkdir -p "${OUTPUT_DIR}"
  FINAL_MISSION_DIR="${OUTPUT_DIR}/mission"
  rm -rf "${FINAL_MISSION_DIR}"
  cp -a "${MISSION_DIR}" "${FINAL_MISSION_DIR}"
  log "Mission directory prepared: ${FINAL_MISSION_DIR}"
  log "Mission-only mode requested; skipping media compose"
  offer_cache_cleanup
  exit 0
fi

if [[ -z "${FLASH_DEVICE}" ]]; then
  if [[ "${COMPOSE_ONLY}" == "1" ]]; then
    log "Compose-only mode requested; skipping target media selection"
  elif interactive_selection_enabled; then
    log "Entering interactive target media selection."
    select_target_flash_device_interactive
    validate_target_flash_device_or_die "${FLASH_DEVICE}"
    log "Using target media device: ${FLASH_DEVICE}"
  else
    die "non-interactive run requires --flash-device, --compose-only, or --mission-only"
  fi
else
  validate_target_flash_device_or_die "${FLASH_DEVICE}"
  log "Using target media device: ${FLASH_DEVICE}"
fi

COMPOSE_OUTPUT_DIR="${STAGING_OUTPUT_DIR}/media"
if [[ -n "${OUTPUT_DIR}" ]]; then
  COMPOSE_OUTPUT_DIR="${OUTPUT_DIR}/media"
fi
compose_cmd=(
  "${VENDORED_ADAPTER_ROOT}/compose-media.sh"
  --mission-dir "${MISSION_DIR}"
  --os-payload "${OS_STAGE_DIR}/os-payload.tar.gz"
  --os-meta-env "${OS_STAGE_DIR}/os.meta.env"
  --substrate-iso "${INSTALLER_SUBSTRATE_ISO}"
  --output-dir "${COMPOSE_OUTPUT_DIR}"
)
if [[ -n "${FLASH_DEVICE}" ]]; then
  compose_cmd+=(--flash-device "${FLASH_DEVICE}")
fi

log "Invoking vendored Woodbox media adapter"
WOODBOX_ADAPTER_ROOT="${VENDORED_ADAPTER_ROOT}" \
OURBOX_MEDIA_COMPOSE_WORK_ROOT="${WORK_ROOT}" \
  "${compose_cmd[@]}"

if [[ "${COMPOSE_ONLY}" == "1" || -n "${OUTPUT_DIR}" ]]; then
  log "Mission media output directory: ${COMPOSE_OUTPUT_DIR}"
else
  log "Mission media flashed from managed scratch workspace; no persistent ISO was kept"
fi

offer_cache_cleanup
