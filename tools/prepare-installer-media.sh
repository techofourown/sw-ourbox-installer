#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tools/lib.sh"
# shellcheck disable=SC1091
source "${ROOT}/tools/cache.sh"

DEFAULT_OURBOX_STATE_ROOT="${XDG_STATE_HOME:-}"
if [[ -z "${DEFAULT_OURBOX_STATE_ROOT}" ]]; then
  if [[ -n "${HOME:-}" ]]; then
    DEFAULT_OURBOX_STATE_ROOT="${HOME}/.local/state"
  else
    DEFAULT_OURBOX_STATE_ROOT="${ROOT}/state"
  fi
fi

TARGET=""
OS_CHANNEL="stable"
OS_REF=""
SUBSTRATE_CHANNEL=""
SUBSTRATE_REF=""
APP_IDS=""
APP_SOURCE_RESOLUTIONS_SPEC=""
ALL_APPS=0
OUTPUT_DIR=""
MISSION_ONLY=0
COMPOSE_ONLY=0
FLASH_DEVICE=""
INSTALLED_TARGET_SSH_KEY_NAME_REQUEST=""
VENDORED_ADAPTER_ROOT=""
VENDORED_METADATA_PARSER=""
VENDORED_ADAPTER_PIN=""
MISSION_SCHEMA="${ROOT}/schemas/mission-manifest.schema.json"
MISSION_SCHEMA_VALIDATOR="${ROOT}/tools/validate-mission-manifest.py"
TMP_ROOT=""
CACHE_REUSE_ENABLED=0
CACHE_REUSE_DECISION_MADE=0
SELECTED_INSTALLED_TARGET_SSH_MODE=""
SELECTED_INSTALLED_TARGET_SSH_KEY_NAME=""
SELECTED_INSTALLED_TARGET_SSH_PUBLIC_KEY_PATH=""
SELECTED_INSTALLED_TARGET_SSH_PUBLIC_KEY_FINGERPRINT=""
SELECTED_INSTALLED_TARGET_SSH_KEY_TYPE=""
: "${OURBOX_CACHE_REUSE_POLICY:=ask}"
: "${OURBOX_CACHE_CLEANUP_POLICY:=ask}"
: "${OURBOX_INSTALLED_TARGET_SSH_KEYSTORE_ROOT:=${DEFAULT_OURBOX_STATE_ROOT}/ourbox/installed-target-ssh-keys}"
CONTAINER_CLI=""
APPLICATION_SOURCE_RESOLUTIONS_JSON="{}"
INSTALLER_SUBSTRATE_FILENAME=""
SUBSTRATE_SELECTION_MODEL=""
TARGET_SUPPORTS_APPLICATION_CATALOGS=0
TARGET_SUPPORTS_INSTALLED_TARGET_SSH=0

usage() {
  cat <<EOF
Usage: $0 [options]

Unified host-side mission prep for OurBox targets.

Normal operator flow:
  $0

This prompts for target, OS, one or more application catalogs, applications,
and removable media, then composes and flashes mission media. Non-flash modes
are available only behind explicit flags.

Options:
  --target TARGET             Preselect the target type for the UI
                              (woodbox or matchbox)
  --os-channel CHANNEL        Preferred OS channel for interactive selection or
                              non-interactive resolution when --os-ref is not set
                              (default: stable)
  --os-ref REF                Exact OS artifact ref to pull instead of catalog/channel resolution
  --substrate-channel CHANNEL  Preferred published substrate channel for
                              interactive selection or non-interactive
                              resolution after OS selection
  --substrate-ref REFS         Exact published substrate bundle refs to pull
                              instead of selecting from the official substrate
                              catalog
  --all-apps                  Install all applications from the merged selected
                              application catalogs without prompting
  --app-ids ID[,ID...]        Install an explicit comma-separated merged
                              application id subset without prompting
  --app-source-resolutions SPEC
                              Resolve duplicate merged application sources
                              without prompting. Format:
                              APP_UID=CATALOG_ID[,APP_UID=CATALOG_ID...]
  --installed-target-ssh-key-name NAME
                              Select or create a named host-side installed-target
                              SSH key and stage its public key into mission media
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

installed_target_ssh_key_name_is_valid() {
  local name="$1"
  [[ "${name}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]
}

installed_target_ssh_key_dir() {
  local key_name="$1"
  printf '%s/%s\n' "${OURBOX_INSTALLED_TARGET_SSH_KEYSTORE_ROOT}" "${key_name}"
}

installed_target_ssh_private_key_path() {
  local key_name="$1"
  printf '%s/id_ed25519\n' "$(installed_target_ssh_key_dir "${key_name}")"
}

installed_target_ssh_public_key_path_for_name() {
  local key_name="$1"
  printf '%s/id_ed25519.pub\n' "$(installed_target_ssh_key_dir "${key_name}")"
}

require_installed_target_ssh_key_tooling() {
  need_cmd ssh-keygen
  need_cmd hostname
}

installed_target_ssh_public_key_fingerprint() {
  local public_key="$1"
  require_installed_target_ssh_key_tooling
  ssh-keygen -lf "${public_key}" -E sha256 | awk 'NF>=2 {print $2; exit}'
}

disable_installed_target_ssh_key_selection() {
  SELECTED_INSTALLED_TARGET_SSH_MODE=""
  SELECTED_INSTALLED_TARGET_SSH_KEY_NAME=""
  SELECTED_INSTALLED_TARGET_SSH_PUBLIC_KEY_PATH=""
  SELECTED_INSTALLED_TARGET_SSH_PUBLIC_KEY_FINGERPRINT=""
  SELECTED_INSTALLED_TARGET_SSH_KEY_TYPE=""
}

installed_target_ssh_key_exists() {
  local key_name="$1"
  [[ -f "$(installed_target_ssh_private_key_path "${key_name}")" ]] \
    && [[ -f "$(installed_target_ssh_public_key_path_for_name "${key_name}")" ]]
}

list_installed_target_ssh_key_names() {
  local dir=""
  [[ -d "${OURBOX_INSTALLED_TARGET_SSH_KEYSTORE_ROOT}" ]] || return 0
  while read -r dir; do
    [[ -n "${dir}" ]] || continue
    installed_target_ssh_key_exists "${dir}" || continue
    printf '%s\n' "${dir}"
  done < <(find "${OURBOX_INSTALLED_TARGET_SSH_KEYSTORE_ROOT}" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
}

ensure_installed_target_ssh_key_exists() {
  local key_name="$1"
  local key_dir=""
  local private_key=""
  local public_key=""
  local comment=""

  installed_target_ssh_key_name_is_valid "${key_name}" \
    || die "invalid installed-target SSH key name: ${key_name}"

  require_installed_target_ssh_key_tooling

  key_dir="$(installed_target_ssh_key_dir "${key_name}")"
  private_key="$(installed_target_ssh_private_key_path "${key_name}")"
  public_key="$(installed_target_ssh_public_key_path_for_name "${key_name}")"

  mkdir -p "${OURBOX_INSTALLED_TARGET_SSH_KEYSTORE_ROOT}"

  if [[ -f "${private_key}" || -f "${public_key}" ]]; then
    [[ -f "${private_key}" && -f "${public_key}" ]] \
      || die "installed-target SSH key '${key_name}' is incomplete under ${key_dir}"
    return 0
  fi

  mkdir -p "${key_dir}"
  chmod 0700 "${key_dir}"
  comment="${key_name}@$(hostname -s 2>/dev/null || hostname)"
  ssh-keygen -q -t ed25519 -N "" -C "${comment}" -f "${private_key}" >/dev/null
  chmod 0600 "${private_key}"
  chmod 0644 "${public_key}"
}

select_installed_target_ssh_key_by_name() {
  local key_name="$1"

  ensure_installed_target_ssh_key_exists "${key_name}"
  SELECTED_INSTALLED_TARGET_SSH_MODE="host-generated-authorized-key"
  SELECTED_INSTALLED_TARGET_SSH_KEY_NAME="${key_name}"
  SELECTED_INSTALLED_TARGET_SSH_PUBLIC_KEY_PATH="$(installed_target_ssh_public_key_path_for_name "${key_name}")"
  SELECTED_INSTALLED_TARGET_SSH_PUBLIC_KEY_FINGERPRINT="$(installed_target_ssh_public_key_fingerprint "${SELECTED_INSTALLED_TARGET_SSH_PUBLIC_KEY_PATH}")"
  [[ "${SELECTED_INSTALLED_TARGET_SSH_PUBLIC_KEY_FINGERPRINT}" =~ ^SHA256:[A-Za-z0-9+/=]+$ ]] \
    || die "failed to derive a valid fingerprint for installed-target SSH key '${key_name}'"
  SELECTED_INSTALLED_TARGET_SSH_KEY_TYPE="ssh-ed25519"
}

render_installed_target_ssh_key_inventory() {
  local key_name="$1"
  local public_key=""
  local fingerprint=""

  public_key="$(installed_target_ssh_public_key_path_for_name "${key_name}")"
  fingerprint="$(installed_target_ssh_public_key_fingerprint "${public_key}")"
  printf '%-24s %s\n' "${key_name}" "${fingerprint:-unknown}"
}

delete_installed_target_ssh_key_by_name() {
  local key_name="$1"
  local key_dir=""

  installed_target_ssh_key_name_is_valid "${key_name}" \
    || die "invalid installed-target SSH key name: ${key_name}"
  key_dir="$(installed_target_ssh_key_dir "${key_name}")"
  [[ -d "${key_dir}" ]] || die "installed-target SSH key not found: ${key_name}"
  rm -rf "${key_dir}"
  if [[ "${SELECTED_INSTALLED_TARGET_SSH_KEY_NAME}" == "${key_name}" ]]; then
    disable_installed_target_ssh_key_selection
  fi
}

delete_all_installed_target_ssh_keys() {
  rm -rf "${OURBOX_INSTALLED_TARGET_SSH_KEYSTORE_ROOT}"
  disable_installed_target_ssh_key_selection
}

show_installed_target_ssh_intro() {
  echo
  echo "Host-side installed-system SSH access"
  echo "This step is optional."
  echo "You can continue without staging any SSH key."
  echo "If you skip this now, you can still configure a username and password later on the target during installation."
  echo
  echo "Options:"
  echo "  [ENTER] Continue without installed-target SSH"
  echo "  n       Continue without installed-target SSH"
  echo "  y       Configure an installed-target SSH key now"
  echo "  q       Quit"
  echo
}

log_installed_target_ssh_disabled_continue() {
  log "Continuing without installed-target SSH key. You can still configure username/password later on the target."
}

show_installed_target_ssh_key_panel() {
  local -a key_names=("$@")
  local idx=0

  echo
  echo "Host-side reusable installed-system SSH keys"
  if [[ -n "${SELECTED_INSTALLED_TARGET_SSH_KEY_NAME}" ]]; then
    echo "Selected: ${SELECTED_INSTALLED_TARGET_SSH_KEY_NAME} (${SELECTED_INSTALLED_TARGET_SSH_PUBLIC_KEY_FINGERPRINT})"
  else
    echo "Selected: disabled"
  fi
  echo "Store   : ${OURBOX_INSTALLED_TARGET_SSH_KEYSTORE_ROOT}"
  echo
  if (( ${#key_names[@]} > 0 )); then
    printf '  %-3s %-24s %s\n' "#" "Key name" "Fingerprint"
    for idx in "${!key_names[@]}"; do
      printf '  %-3s ' "$((idx + 1))"
      render_installed_target_ssh_key_inventory "${key_names[$idx]}"
    done
  else
    echo "  No stored installed-target SSH keys."
  fi
  echo
  echo "Options:"
  echo "  [ENTER] Continue without installed-target SSH key"
  if (( ${#key_names[@]} > 0 )); then
    echo "  [1-${#key_names[@]}] Use an existing named key"
    echo "  d       Delete a named key"
    echo "  x       Delete all named keys"
  fi
  echo "  n       Create a new named key"
  echo "  q       Quit"
  echo
}

create_installed_target_ssh_key_interactive() {
  local default_name=""
  local key_name=""

  default_name="ourbox-$(date -u +%Y%m%d-%H%M%S)"
  read -r -p "Enter key name [${default_name}]: " key_name
  key_name="${key_name:-${default_name}}"
  if ! installed_target_ssh_key_name_is_valid "${key_name}"; then
    log "Key name must match [A-Za-z0-9][A-Za-z0-9._-]{0,63}."
    return 1
  fi
  select_installed_target_ssh_key_by_name "${key_name}"
}

delete_installed_target_ssh_key_interactive() {
  local -a key_names=("$@")
  local pick=""
  local idx=0

  (( ${#key_names[@]} > 0 )) || return 1
  read -r -p "Enter key number to delete (or ENTER to cancel): " pick
  [[ -n "${pick}" ]] || return 1
  [[ "${pick}" =~ ^[0-9]+$ ]] || {
    log "Invalid selection."
    return 1
  }
  idx=$((pick - 1))
  if (( idx < 0 || idx >= ${#key_names[@]} )); then
    log "Selection out of range."
    return 1
  fi
  delete_installed_target_ssh_key_by_name "${key_names[$idx]}"
  log "Deleted installed-target SSH key: ${key_names[$idx]}"
}

delete_all_installed_target_ssh_keys_interactive() {
  local confirm=""

  read -r -p "Type DELETE-ALL-SSH-KEYS to remove every stored installed-target SSH key: " confirm
  [[ "${confirm}" == "DELETE-ALL-SSH-KEYS" ]] || {
    log "Delete-all not confirmed."
    return 1
  }
  delete_all_installed_target_ssh_keys
  log "Deleted all installed-target SSH keys"
}

interactive_confirm_installed_target_ssh_setup() {
  local choice=""

  while true; do
    show_installed_target_ssh_intro
    read -r -p "Configure installed-target SSH access now? [y/N]: " choice

    case "${choice}" in
      ""|n|N)
        disable_installed_target_ssh_key_selection
        log_installed_target_ssh_disabled_continue
        return 1
        ;;
      y|Y)
        return 0
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

interactive_select_installed_target_ssh_key() {
  local choice=""
  local idx=0
  local -a key_names=()

  disable_installed_target_ssh_key_selection
  if ! interactive_confirm_installed_target_ssh_setup; then
    return 0
  fi

  while true; do
    mapfile -t key_names < <(list_installed_target_ssh_key_names)
    show_installed_target_ssh_key_panel "${key_names[@]}"
    read -r -p "Choice: " choice

    case "${choice}" in
      "")
        disable_installed_target_ssh_key_selection
        log_installed_target_ssh_disabled_continue
        return 0
        ;;
      n|N)
        create_installed_target_ssh_key_interactive && return 0
        ;;
      d|D)
        delete_installed_target_ssh_key_interactive "${key_names[@]}" || true
        ;;
      x|X)
        delete_all_installed_target_ssh_keys_interactive || true
        ;;
      q|Q)
        die "Mission compose aborted by user"
        ;;
      *)
        if [[ ! "${choice}" =~ ^[0-9]+$ ]]; then
          log "Unknown option."
          continue
        fi
        idx=$((choice - 1))
        if (( idx < 0 || idx >= ${#key_names[@]} )); then
          log "Selection out of range."
          continue
        fi
        select_installed_target_ssh_key_by_name "${key_names[$idx]}"
        return 0
        ;;
    esac
  done
}

determine_installed_target_ssh_key() {
  disable_installed_target_ssh_key_selection

  if [[ "${TARGET_SUPPORTS_INSTALLED_TARGET_SSH}" != "1" ]]; then
    [[ -z "${INSTALLED_TARGET_SSH_KEY_NAME_REQUEST}" ]] || {
      die "target '${TARGET}' does not support --installed-target-ssh-key-name"
    }
    return 0
  fi

  if [[ -n "${INSTALLED_TARGET_SSH_KEY_NAME_REQUEST}" ]]; then
    select_installed_target_ssh_key_by_name "${INSTALLED_TARGET_SSH_KEY_NAME_REQUEST}"
    return 0
  fi

  if interactive_selection_enabled; then
    interactive_select_installed_target_ssh_key
  fi
}

stage_selected_installed_target_ssh_artifacts() {
  local mission_dir="$1"
  local stage_dir="${mission_dir}/artifacts/installed-target-ssh"

  rm -rf "${stage_dir}"

  if [[ -z "${SELECTED_INSTALLED_TARGET_SSH_KEY_NAME}" ]]; then
    return 0
  fi

  mkdir -p "${stage_dir}"
  cp -f "${SELECTED_INSTALLED_TARGET_SSH_PUBLIC_KEY_PATH}" "${stage_dir}/authorized-key.pub"
}

validate_staged_installed_target_ssh_artifacts() {
  local mission_dir="$1"
  local stage_dir="${mission_dir}/artifacts/installed-target-ssh"
  local staged_key="${stage_dir}/authorized-key.pub"
  local staged_fingerprint=""
  local -a key_lines=()

  if [[ "${SELECTED_INSTALLED_TARGET_SSH_MODE}" != "host-generated-authorized-key" ]]; then
    [[ ! -e "${stage_dir}" ]] || die "installed-target SSH mission artifacts must be absent when SSH key selection is disabled"
    return 0
  fi

  [[ -f "${staged_key}" ]] || die "installed-target SSH mission artifact missing: ${staged_key}"
  mapfile -t key_lines < <(awk 'NF {print $0}' "${staged_key}")
  [[ "${#key_lines[@]}" -eq 1 ]] || die "installed-target SSH mission artifact must contain exactly one non-empty public key line"
  [[ "${key_lines[0]}" == ssh-ed25519\ * ]] || die "installed-target SSH mission artifact must contain an ssh-ed25519 public key"
  staged_fingerprint="$(installed_target_ssh_public_key_fingerprint "${staged_key}")"
  [[ "${staged_fingerprint}" == "${SELECTED_INSTALLED_TARGET_SSH_PUBLIC_KEY_FINGERPRINT}" ]] || {
    die "installed-target SSH mission artifact fingerprint mismatch: expected ${SELECTED_INSTALLED_TARGET_SSH_PUBLIC_KEY_FINGERPRINT}, got ${staged_fingerprint:-unknown}"
  }
}

log_installed_target_ssh_selection_summary() {
  if [[ -n "${SELECTED_INSTALLED_TARGET_SSH_KEY_NAME}" ]]; then
    log "Installed-target SSH key: ${SELECTED_INSTALLED_TARGET_SSH_KEY_NAME} (${SELECTED_INSTALLED_TARGET_SSH_PUBLIC_KEY_FINGERPRINT})"
    return 0
  fi

  log "Installed-target SSH key: disabled"
}

show_target_default_choice() {
  local target="$1"

  echo
  echo "Host-side target selection"
  echo "Default: ${target}"
  echo "Options:"
  echo "  [ENTER] Use default"
  echo "  1       woodbox"
  echo "  2       matchbox"
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
      2)
        TARGET="matchbox"
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

load_target_adapter_metadata() {
  local adapter_dump=""
  local adapter_path=""

  VENDORED_ADAPTER_ROOT="${ROOT}/vendor/${TARGET}"
  VENDORED_METADATA_PARSER="${VENDORED_ADAPTER_ROOT}/strict-kv-metadata.py"
  VENDORED_ADAPTER_PIN="${ROOT}/vendor/${TARGET}.upstream.env"
  adapter_path="${VENDORED_ADAPTER_ROOT}/adapter.json"

  [[ -f "${adapter_path}" ]] || die "vendored adapter not found for target '${TARGET}': ${adapter_path}"
  [[ -f "${VENDORED_METADATA_PARSER}" ]] || die "vendored metadata parser not found for target '${TARGET}': ${VENDORED_METADATA_PARSER}"

  adapter_dump="$(
    python3 - <<'PY' "${adapter_path}" "${TARGET}" "${OS_CHANNEL}"
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    adapter = json.load(handle)

target = sys.argv[2]
os_channel = sys.argv[3]

if str(adapter.get("target_id", "")).strip() != target:
    raise SystemExit(f"adapter target_id does not match requested target {target!r}")

official = adapter.get("official") or {}
os_tags = official.get("os_channel_tags") or {}
installer_tags = official.get("installer_channel_tags") or {}
if os_channel not in os_tags:
    raise SystemExit(f"unsupported {target} os channel: {os_channel}")
for lane in ("stable", "beta", "nightly", "exp-labs"):
    if lane not in installer_tags:
        raise SystemExit(f"adapter missing installer channel tag for {lane}")

application_catalog_sources = official.get("application_catalog_sources")
substrate_selection_model = str(adapter.get("substrate_selection_model", "")).strip()
if isinstance(application_catalog_sources, list) and application_catalog_sources:
    selection_model = "application-catalogs"
elif substrate_selection_model == "published-substrate-bundle":
    selection_model = "published-substrate-bundle"
else:
    raise SystemExit(
        "adapter must declare either official.application_catalog_sources or substrate_selection_model=published-substrate-bundle"
    )

substrate_repo = ""
substrate_catalog_tag = ""
substrate_stable = ""
substrate_beta = ""
substrate_nightly = ""
substrate_exp_labs = ""
install_defaults_ref = str(official.get("install_defaults_ref", "")).strip()
if selection_model == "published-substrate-bundle":
    substrate_repo = str(official.get("substrate_bundle_repo", "")).strip()
    substrate_catalog_tag = str(official.get("substrate_bundle_catalog_tag", "")).strip()
    substrate_tags = official.get("substrate_bundle_channel_tags") or {}
    if not substrate_repo or not substrate_catalog_tag:
        raise SystemExit("published-substrate-bundle adapters must declare substrate_bundle_repo and substrate_bundle_catalog_tag")
    for lane in ("stable", "beta", "nightly", "exp-labs"):
        if lane not in substrate_tags:
            raise SystemExit(f"adapter missing substrate bundle channel tag for {lane}")
    substrate_stable = str(substrate_tags["stable"])
    substrate_beta = str(substrate_tags["beta"])
    substrate_nightly = str(substrate_tags["nightly"])
    substrate_exp_labs = str(substrate_tags["exp-labs"])

print("\n".join([
    str(official["os_repo"]),
    str(official["os_catalog_tag"]),
    str(os_tags["stable"]),
    str(os_tags["beta"]),
    str(os_tags["nightly"]),
    str(os_tags["exp-labs"]),
    str(adapter["expected_os_artifact_type"]),
    str(adapter["expected_substrate_arch"]),
    str(official["installer_repo"]),
    str(installer_tags["stable"]),
    str(installer_tags["beta"]),
    str(installer_tags["nightly"]),
    str(installer_tags["exp-labs"]),
    str(adapter.get("minimum_media_size_bytes", "")),
    str(adapter.get("output_kind", "")),
    json.dumps(adapter.get("runtime_prompts_kept", [])),
    str(adapter.get("installer_substrate_payload_filename", "installer.iso")),
    install_defaults_ref,
    selection_model,
    json.dumps(application_catalog_sources if isinstance(application_catalog_sources, list) else []),
    substrate_repo,
    substrate_catalog_tag,
    substrate_stable,
    substrate_beta,
    substrate_nightly,
    substrate_exp_labs,
    "__OURBOX_ADAPTER_FIELDS_END__",
]))
PY
  )"

  mapfile -t adapter_fields <<<"${adapter_dump}"
  [[ "${#adapter_fields[@]}" -eq 27 ]] || die "failed to load vendored adapter metadata for target '${TARGET}'"
  [[ "${adapter_fields[26]}" == "__OURBOX_ADAPTER_FIELDS_END__" ]] \
    || die "failed to load vendored adapter metadata for target '${TARGET}'"
  unset 'adapter_fields[26]'

  OS_REPO="${adapter_fields[0]}"
  OS_CATALOG_TAG="${adapter_fields[1]}"
  OS_CHANNEL_TAG_STABLE="${adapter_fields[2]}"
  OS_CHANNEL_TAG_BETA="${adapter_fields[3]}"
  OS_CHANNEL_TAG_NIGHTLY="${adapter_fields[4]}"
  OS_CHANNEL_TAG_EXP_LABS="${adapter_fields[5]}"
  EXPECTED_OS_ARTIFACT_TYPE="${adapter_fields[6]}"
  EXPECTED_SUBSTRATE_ARCH="${adapter_fields[7]}"
  INSTALLER_REPO="${adapter_fields[8]}"
  INSTALLER_CHANNEL_TAG_STABLE="${adapter_fields[9]}"
  INSTALLER_CHANNEL_TAG_BETA="${adapter_fields[10]}"
  INSTALLER_CHANNEL_TAG_NIGHTLY="${adapter_fields[11]}"
  INSTALLER_CHANNEL_TAG_EXP_LABS="${adapter_fields[12]}"
  MINIMUM_MEDIA_SIZE_BYTES="${adapter_fields[13]}"
  OUTPUT_KIND="${adapter_fields[14]}"
  ADAPTER_RUNTIME_PROMPTS_JSON="${adapter_fields[15]}"
  INSTALLER_SUBSTRATE_FILENAME="${adapter_fields[16]}"
  INSTALL_DEFAULTS_REF="${adapter_fields[17]}"
  SUBSTRATE_SELECTION_MODEL="${adapter_fields[18]}"
  APPLICATION_CATALOG_SOURCES_JSON="${adapter_fields[19]}"
  SUBSTRATE_REPO="${adapter_fields[20]}"
  SUBSTRATE_CATALOG_TAG="${adapter_fields[21]}"
  SUBSTRATE_CHANNEL_TAG_STABLE="${adapter_fields[22]}"
  SUBSTRATE_CHANNEL_TAG_BETA="${adapter_fields[23]}"
  SUBSTRATE_CHANNEL_TAG_NIGHTLY="${adapter_fields[24]}"
  SUBSTRATE_CHANNEL_TAG_EXP_LABS="${adapter_fields[25]}"

  TARGET_SUPPORTS_APPLICATION_CATALOGS=0
  TARGET_SUPPORTS_INSTALLED_TARGET_SSH=0
  case "${SUBSTRATE_SELECTION_MODEL}" in
    application-catalogs)
      TARGET_SUPPORTS_APPLICATION_CATALOGS=1
      TARGET_SUPPORTS_INSTALLED_TARGET_SSH=1
      ;;
    published-substrate-bundle)
      TARGET_SUPPORTS_APPLICATION_CATALOGS=0
      TARGET_SUPPORTS_INSTALLED_TARGET_SSH=0
      ;;
    *)
      die "unsupported adapter selection model for target '${TARGET}': ${SUBSTRATE_SELECTION_MODEL}"
      ;;
  esac
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
    --substrate-channel)
      [[ $# -ge 2 ]] || die "--substrate-channel requires a value"
      SUBSTRATE_CHANNEL="$2"
      shift 2
      ;;
    --substrate-ref)
      [[ $# -ge 2 ]] || die "--substrate-ref requires a value"
      SUBSTRATE_REF="$2"
      shift 2
      ;;
    --all-apps)
      ALL_APPS=1
      shift
      ;;
    --app-ids)
      [[ $# -ge 2 ]] || die "--app-ids requires a value"
      APP_IDS="$2"
      shift 2
      ;;
    --app-source-resolutions)
      [[ $# -ge 2 ]] || die "--app-source-resolutions requires a value"
      APP_SOURCE_RESOLUTIONS_SPEC="$2"
      shift 2
      ;;
    --installed-target-ssh-key-name)
      [[ $# -ge 2 ]] || die "--installed-target-ssh-key-name requires a value"
      INSTALLED_TARGET_SSH_KEY_NAME_REQUEST="$2"
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
[[ "${MISSION_ONLY}" == "0" || "${COMPOSE_ONLY}" == "0" ]] || die "--mission-only cannot be combined with --compose-only"
[[ "${MISSION_ONLY}" == "0" || -z "${FLASH_DEVICE}" ]] || die "--flash-device cannot be combined with --mission-only"
[[ "${COMPOSE_ONLY}" == "0" || -z "${FLASH_DEVICE}" ]] || die "--flash-device cannot be combined with --compose-only"
[[ "${ALL_APPS}" == "0" || -z "${APP_IDS}" ]] || die "--all-apps cannot be combined with --app-ids"
if [[ -z "${OUTPUT_DIR}" && ( "${MISSION_ONLY}" == "1" || "${COMPOSE_ONLY}" == "1" ) ]]; then
  OUTPUT_DIR="$(default_output_dir_for_target "${TARGET}")"
fi
load_target_adapter_metadata

need_cmd python3
need_cmd git
need_cmd oras
need_cmd sha256sum
need_cmd tar
need_cmd find

[[ -f "${VENDORED_ADAPTER_ROOT}/compose-media.sh" ]] || die "vendored compose script not found for target '${TARGET}': ${VENDORED_ADAPTER_ROOT}/compose-media.sh"
[[ -f "${VENDORED_ADAPTER_ROOT}/validate-media.sh" ]] || die "vendored validate script not found for target '${TARGET}': ${VENDORED_ADAPTER_ROOT}/validate-media.sh"
[[ -f "${MISSION_SCHEMA}" ]] || die "mission schema not found: ${MISSION_SCHEMA}"
[[ -f "${MISSION_SCHEMA_VALIDATOR}" ]] || die "mission schema validator not found: ${MISSION_SCHEMA_VALIDATOR}"

WORK_ROOT="${ROOT}/cache/work"
mkdir -p "${WORK_ROOT}"
TMP_ROOT="$(mktemp -d "${WORK_ROOT}/prepare-installer-media.XXXXXX")"
trap 'rm -rf "${TMP_ROOT}"' EXIT
require_flash_path_or_explicit_mode

ADAPTER_SOURCE_REPO="vendored-local"
ADAPTER_SOURCE_REVISION="unknown"
if [[ -f "${VENDORED_ADAPTER_PIN}" ]]; then
  # shellcheck disable=SC1090
  source "${VENDORED_ADAPTER_PIN}"
  ADAPTER_SOURCE_REPO="${SOURCE_REPO:-${ADAPTER_SOURCE_REPO}}"
  ADAPTER_SOURCE_REVISION="${SOURCE_REVISION:-${ADAPTER_SOURCE_REVISION}}"
fi

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
  local cache_display=""
  local -a cached_refs=()

  if (( CACHE_REUSE_DECISION_MADE )); then
    return 0
  fi

  for ref in "$@"; do
    [[ -n "${ref}" ]] || continue
    if cache_has_cached_ref "${ref}"; then
      cache_display="${ref}"
      if [[ "${OURBOX_CACHE_LAST_PINNED_REF}" != "${ref}" ]]; then
        cache_display="${ref} -> ${OURBOX_CACHE_LAST_PINNED_REF}"
      fi
      cached_refs+=("${cache_display}")
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
      echo "Cached installer assets are available for the current resolved digests for ${label}:"
      for ref in "${cached_refs[@]}"; do
        echo "  - ${ref}"
      done
      echo
      if prompt_yes_no_default_no "Reuse cached bytes when the current resolved digest is already cached?"; then
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

log_resolved_artifact_ref() {
  local label="$1"
  local requested_ref="$2"
  local pinned_ref="$3"

  [[ -n "${requested_ref}" && -n "${pinned_ref}" ]] || return 0
  if [[ "${requested_ref}" == "${pinned_ref}" ]]; then
    log "${label}: ${pinned_ref}"
    return 0
  fi

  log "Resolved ${label} ${requested_ref} -> ${pinned_ref}"
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
  local payload_name="$2"
  local payload_path="${cache_dir}/${payload_name}"
  local sha_path="${cache_dir}/${payload_name}.sha256"
  local expected=""
  local actual=""

  [[ -f "${payload_path}" ]] || die "installer substrate missing ${payload_name} in ${cache_dir}"
  [[ -f "${sha_path}" ]] || die "installer substrate missing ${payload_name}.sha256 in ${cache_dir}"
  expected="$(awk 'NF>=1 {print $1; exit}' "${sha_path}")"
  expected="${expected,,}"
  [[ "${expected}" =~ ^[0-9a-f]{64}$ ]] || die "invalid sha256 in ${sha_path}"
  actual="$(sha256sum "${payload_path}" | awk '{print $1}')"
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
        artifact_digest = (row.get("artifact_digest") or "").strip()
        pinned_ref = (row.get("pinned_ref") or "").strip()
        created_key = parse_created(created)
        if created_key is None:
            continue
        if not re.fullmatch(r"sha256:[0-9a-f]{64}", artifact_digest):
            continue
        if not re.fullmatch(r"[^\s]+@sha256:[0-9a-f]{64}", pinned_ref):
            continue
        rows.append((created_key, created, row_channel, tag, version, artifact_digest, pinned_ref))

rows.sort(key=lambda item: (item[0], item[3]), reverse=True)
for _created_key, created, row_channel, tag, version, artifact_digest, pinned_ref in rows:
    print("\t".join((row_channel, tag, created, version, artifact_digest, pinned_ref)))
PY
}

select_substrate_ref_from_catalog() {
  local catalog_tsv="$1"
  local channel="$2"
  local required_arch="$3"

  python3 - <<'PY' "${catalog_tsv}" "${channel}" "${required_arch}"
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

catalog_tsv, channel, arch = sys.argv[1:]
rows = []
with open(catalog_tsv, "r", encoding="utf-8") as handle:
    reader = csv.DictReader(handle, delimiter="\t")
    for row in reader:
        row_channel = (row.get("channel") or "").strip()
        row_arch = (row.get("arch") or "").strip()
        pinned_ref = (row.get("pinned_ref") or "").strip()
        created = (row.get("created") or "").strip()
        created_key = parse_created(created)
        if created_key is None:
            continue
        if row_channel != channel:
            continue
        if row_arch != arch:
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

render_os_catalog_entry() {
  local display_number="$1"
  local entry="$2"
  local channel=""
  local tag=""
  local created=""
  local version=""
  local artifact_digest=""
  local pinned_ref=""

  IFS=$'\t' read -r channel tag created version artifact_digest pinned_ref <<<"${entry}"
  printf "  %d) %-12s %-30s %s %s %s\n" "${display_number}" "${channel}" "${tag}" "${version}" "${created}" "${artifact_digest}"
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
    die "OS catalog ${OS_REPO}:${OS_CATALOG_TAG} had no valid pinned row for channel ${channel}"
  fi

  die "OS catalog ${OS_REPO}:${OS_CATALOG_TAG} is unavailable; cannot resolve channel ${channel}"
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
      SELECTED_OS_SELECTION_SOURCE="operator-override"
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
  local artifact_digest=""
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
  IFS=$'\t' read -r channel tag created version artifact_digest pinned_ref <<<"${chosen}"
  normalized_channel="$(normalize_release_channel "${channel}")"
  OS_CHANNEL="${normalized_channel}"
  SELECTED_OS_REF="${pinned_ref}"
  SELECTED_OS_SELECTION_SOURCE="catalog"
  SELECTED_OS_RELEASE_CHANNEL="${normalized_channel}"
  log "Selected ${SELECTED_OS_REF} (channel=${normalized_channel}, version=${version}, digest=${artifact_digest})"
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

resolve_substrate_channel_ref() {
  local channel="$1"
  local catalog_cache_dir=""
  local catalog_tsv=""
  local catalog_ref=""

  if try_cache_pull_oci_artifact "${SUBSTRATE_REPO}:${SUBSTRATE_CATALOG_TAG}" "${CACHE_REUSE_ENABLED}" catalog_cache_dir; then
    catalog_tsv="$(find_pulled_file "${catalog_cache_dir}" "catalog.tsv")"
    if [[ -n "${catalog_tsv}" ]]; then
      catalog_ref="$(select_substrate_ref_from_catalog "${catalog_tsv}" "${channel}" "${EXPECTED_SUBSTRATE_ARCH}" || true)"
      if is_pinned_ref "${catalog_ref}"; then
        SELECTED_SUBSTRATE_SELECTION_MODE="host-selected"
        SELECTED_SUBSTRATE_SELECTION_SOURCE="catalog"
        SELECTED_SUBSTRATE_RELEASE_CHANNEL="${channel}"
        SELECTED_SUBSTRATE_REF="${catalog_ref}"
        return 0
      fi
    fi
    die "application bundle catalog ${SUBSTRATE_REPO}:${SUBSTRATE_CATALOG_TAG} had no valid pinned row for lane ${channel}"
  fi

  die "application bundle catalog ${SUBSTRATE_REPO}:${SUBSTRATE_CATALOG_TAG} is unavailable; cannot resolve lane ${channel}"
}

resolve_default_substrate_ref() {
  if [[ -n "${SUBSTRATE_REF}" ]]; then
    SELECTED_SUBSTRATE_SELECTION_MODE="explicit-ref"
    SELECTED_SUBSTRATE_SELECTION_SOURCE="substrate-ref"
    SELECTED_SUBSTRATE_RELEASE_CHANNEL=""
    SELECTED_SUBSTRATE_REF="${SUBSTRATE_REF}"
    return 0
  fi

  if [[ -z "${SUBSTRATE_CHANNEL}" ]]; then
    SUBSTRATE_CHANNEL="stable"
  fi

  resolve_substrate_channel_ref "${SUBSTRATE_CHANNEL}"
}

show_substrate_default_choice() {
  local ref="$1"

  echo
  echo "Host-side application bundle selection"
  echo "Default source : ${SELECTED_SUBSTRATE_SELECTION_SOURCE:-pending}"
  echo "Default: use application bundle '${ref}'"
  echo "Options:"
  echo "  [ENTER] Use default"
  echo "  c       Choose lane (prefers the newest pinned catalog row for that lane)"
  echo "  l       List published bundles"
  echo "  r       Enter custom OCI ref (tag or digest)"
  echo "  o       Override application bundle repo (custom registry/fork)"
  echo "  q       Quit"
  echo
}

choose_substrate_channel_interactive() {
  local pick=""
  local custom_tag=""

  echo "Application bundle lanes:"
  echo "  1) stable (${SUBSTRATE_CHANNEL_TAG_STABLE}) (recommended)"
  echo "  2) beta (${SUBSTRATE_CHANNEL_TAG_BETA})"
  echo "  3) nightly (${SUBSTRATE_CHANNEL_TAG_NIGHTLY})"
  echo "  4) exp-labs (${SUBSTRATE_CHANNEL_TAG_EXP_LABS})"
  echo "  5) custom tag name"

  read -r -p "Select channel [1-5]: " pick
  case "${pick}" in
    1|"") SUBSTRATE_CHANNEL="stable" ;;
    2) SUBSTRATE_CHANNEL="beta" ;;
    3) SUBSTRATE_CHANNEL="nightly" ;;
    4) SUBSTRATE_CHANNEL="exp-labs" ;;
    5)
      read -r -p "Enter tag: " custom_tag
      [[ -n "${custom_tag}" ]] || {
        log "Tag cannot be empty."
        return 1
      }
      SELECTED_SUBSTRATE_SELECTION_MODE="host-selected"
      SELECTED_SUBSTRATE_SELECTION_SOURCE="operator-override"
      SELECTED_SUBSTRATE_RELEASE_CHANNEL=""
      SELECTED_SUBSTRATE_REF="${SUBSTRATE_REPO}:${custom_tag}"
      return 0
      ;;
    *)
      log "Invalid choice."
      return 1
      ;;
  esac

  resolve_substrate_channel_ref "${SUBSTRATE_CHANNEL}"
}

select_substrate_ref_from_catalog_interactive() {
  local catalog_cache_dir=""
  local catalog_tsv=""
  local chosen=""
  local normalized_channel=""
  local channel=""
  local tag=""
  local created=""
  local version=""
  local artifact_digest=""
  local pinned_ref=""
  local -a entries=()

  if ! try_cache_pull_oci_artifact "${SUBSTRATE_REPO}:${SUBSTRATE_CATALOG_TAG}" "${CACHE_REUSE_ENABLED}" catalog_cache_dir; then
    log "Catalog unavailable; skipping list."
    return 1
  fi

  catalog_tsv="$(find_pulled_file "${catalog_cache_dir}" "catalog.tsv")"
  mapfile -t entries < <(list_os_catalog_entries "${catalog_tsv}")
  if [[ "${#entries[@]}" -eq 0 ]]; then
    log "Catalog pulled (${SUBSTRATE_REPO}:${SUBSTRATE_CATALOG_TAG}) but contained no valid entries."
    return 1
  fi

  paginate_catalog_entries_interactive "Catalog entries (${SUBSTRATE_REPO}:${SUBSTRATE_CATALOG_TAG})" entries render_os_catalog_entry chosen || return 1
  IFS=$'\t' read -r channel tag created version artifact_digest pinned_ref <<<"${chosen}"
  normalized_channel="$(normalize_release_channel "${channel}")"
  SELECTED_SUBSTRATE_SELECTION_MODE="host-selected"
  SELECTED_SUBSTRATE_SELECTION_SOURCE="catalog"
  SELECTED_SUBSTRATE_RELEASE_CHANNEL="${normalized_channel}"
  SELECTED_SUBSTRATE_REF="${pinned_ref}"
  log "Selected ${SELECTED_SUBSTRATE_REF} (channel=${normalized_channel}, version=${version}, digest=${artifact_digest})"
}

prompt_custom_substrate_ref_interactive() {
  local ref=""

  read -r -p "Enter full OCI ref (e.g., repo:tag or repo@sha256:...): " ref
  [[ -n "${ref}" && "${ref}" != *[[:space:]]* ]] || {
    log "Ref must be a single-line OCI ref without whitespace."
    return 1
  }

  SELECTED_SUBSTRATE_SELECTION_MODE="host-selected"
  SELECTED_SUBSTRATE_SELECTION_SOURCE="operator-override"
  SELECTED_SUBSTRATE_RELEASE_CHANNEL=""
  SELECTED_SUBSTRATE_REF="${ref}"
}

override_substrate_repo_interactive() {
  local next_repo=""
  local next_catalog="catalog-${EXPECTED_SUBSTRATE_ARCH}"
  local user_catalog=""

  read -r -p "Enter OCI repo (e.g., ghcr.io/org/application-bundle): " next_repo
  [[ -n "${next_repo}" ]] || {
    log "Repository cannot be empty."
    return 1
  }

  SUBSTRATE_REPO="${next_repo}"
  read -r -p "Catalog tag [${next_catalog}]: " user_catalog
  if [[ -n "${user_catalog}" ]]; then
    SUBSTRATE_CATALOG_TAG="${user_catalog}"
  else
    SUBSTRATE_CATALOG_TAG="${next_catalog}"
  fi

  if [[ -z "${SUBSTRATE_CHANNEL}" ]]; then
    SUBSTRATE_CHANNEL="stable"
  fi

  log "Application bundle repo override set to ${SUBSTRATE_REPO}"
}

interactive_select_substrate_ref() {
  local choice=""
  local default_ref=""
  local default_source=""
  local default_channel=""
  local default_mode=""

  SELECTED_SUBSTRATE_REF=""
  SELECTED_SUBSTRATE_SELECTION_MODE=""
  SELECTED_SUBSTRATE_SELECTION_SOURCE=""
  SELECTED_SUBSTRATE_RELEASE_CHANNEL=""

  while [[ -z "${SELECTED_SUBSTRATE_REF}" ]]; do
    resolve_default_substrate_ref
    default_ref="${SELECTED_SUBSTRATE_REF}"
    default_mode="${SELECTED_SUBSTRATE_SELECTION_MODE}"
    default_source="${SELECTED_SUBSTRATE_SELECTION_SOURCE}"
    default_channel="${SELECTED_SUBSTRATE_RELEASE_CHANNEL}"
    SELECTED_SUBSTRATE_REF=""

    show_substrate_default_choice "${default_ref}"
    read -r -p "Choice: " choice

    case "${choice}" in
      "")
        SELECTED_SUBSTRATE_REF="${default_ref}"
        SELECTED_SUBSTRATE_SELECTION_MODE="${default_mode}"
        SELECTED_SUBSTRATE_SELECTION_SOURCE="${default_source}"
        SELECTED_SUBSTRATE_RELEASE_CHANNEL="${default_channel}"
        ;;
      c)
        choose_substrate_channel_interactive || true
        ;;
      l)
        select_substrate_ref_from_catalog_interactive || true
        ;;
      r)
        prompt_custom_substrate_ref_interactive || true
        ;;
      o)
        override_substrate_repo_interactive || true
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

determine_substrate_ref() {
  if [[ -n "${SUBSTRATE_REF}" ]]; then
    SELECTED_SUBSTRATE_SELECTION_MODE="explicit-ref"
    SELECTED_SUBSTRATE_SELECTION_SOURCE="substrate-ref"
    SELECTED_SUBSTRATE_RELEASE_CHANNEL=""
    SELECTED_SUBSTRATE_REF="${SUBSTRATE_REF}"
    return 0
  fi

  if interactive_selection_enabled; then
    interactive_select_substrate_ref
    return 0
  fi

  resolve_default_substrate_ref
}
SELECTED_APPLICATION_CATALOG_SOURCES_JSON="[]"
SELECTED_APPLICATION_CATALOG_SOURCE_DISPLAY=""
APPLICATION_CATALOG_DEFAULT_IDS="${APPLICATION_CATALOG_DEFAULT_IDS:-}"

application_catalog_source_display_from_json() {
  local sources_json="$1"
  python3 - <<'PY' "${sources_json}"
import json
import sys

sources = json.loads(sys.argv[1])
if not isinstance(sources, list) or not sources:
    raise SystemExit(1)

labels = []
for source in sources:
    name = str(source.get("catalog_name", "")).strip()
    catalog_id = str(source.get("catalog_id", "")).strip()
    ref = str(source.get("artifact_ref", "")).strip() or str(source.get("catalog_ref", "")).strip()
    if name and catalog_id:
        labels.append(f"{name} ({catalog_id})")
    elif name:
        labels.append(name)
    elif catalog_id:
        labels.append(catalog_id)
    else:
        labels.append(ref or "unknown")

print(", ".join(labels))
PY
}

list_application_catalog_source_entries() {
  python3 - <<'PY' "${APPLICATION_CATALOG_SOURCES_JSON}" "${APPLICATION_CATALOG_DEFAULT_IDS}"
import json
import sys

sources = json.loads(sys.argv[1])
default_ids = {item.strip() for item in sys.argv[2].split(",") if item.strip()}
if not isinstance(sources, list) or not sources:
    raise SystemExit("application catalog sources must be a non-empty list")

for source in sources:
    catalog_id = str(source.get("catalog_id", "")).strip()
    print("\x1f".join(
        [
            catalog_id,
            str(source.get("catalog_name", "")).strip(),
            str(source.get("description", "")).strip(),
            str(source.get("artifact_ref", "")).strip(),
            str(source.get("catalog_ref", "")).strip(),
            str(source.get("release_channel", "")).strip(),
            "1" if catalog_id in default_ids else "0",
        ]
    ))
PY
}

render_application_catalog_source_entry() {
  local display_number="$1"
  local entry="$2"
  local catalog_id=""
  local catalog_name=""
  local description=""
  local artifact_ref=""
  local catalog_ref=""
  local release_channel=""
  local default_selected=""

  IFS=$'\x1f' read -r catalog_id catalog_name description artifact_ref catalog_ref release_channel default_selected <<<"${entry}"
  if [[ "${default_selected}" == "1" ]]; then
    printf "  %d) %-18s %-28s [default]\n" "${display_number}" "${catalog_id}" "${catalog_name}"
  else
    printf "  %d) %-18s %-28s\n" "${display_number}" "${catalog_id}" "${catalog_name}"
  fi
  [[ -n "${description}" ]] && printf "      %s\n" "${description}"
  printf "      %s\n" "${artifact_ref:-${catalog_ref}}"
  [[ -n "${catalog_ref}" && -n "${release_channel}" ]] && printf "      channel: %s\n" "${release_channel}"
}

resolve_default_application_catalog_sources_json() {
  if [[ -z "${APPLICATION_CATALOG_DEFAULT_IDS}" ]]; then
    load_application_catalog_defaults_from_install_defaults
  fi
  [[ -n "${APPLICATION_CATALOG_DEFAULT_IDS}" ]] \
    || die "official application catalog defaults are missing from upstream install defaults; rerun with --substrate-channel or --substrate-ref to override explicitly"
  resolve_application_catalog_sources_from_ids "${APPLICATION_CATALOG_DEFAULT_IDS}"
}

resolve_application_catalog_sources_from_ids() {
  local requested_ids="$1"
  python3 - <<'PY' "${APPLICATION_CATALOG_SOURCES_JSON}" "${requested_ids}"
import json
import sys

sources = json.loads(sys.argv[1])
requested = [item.strip() for item in sys.argv[2].split(",") if item.strip()]
if not requested:
    raise SystemExit("no application catalog ids provided")

by_id = {}
for source in sources:
    catalog_id = str(source.get("catalog_id", "")).strip()
    if not catalog_id:
        raise SystemExit("application catalog source missing catalog_id")
    by_id[catalog_id] = source

selected = []
seen = set()
for catalog_id in requested:
    if catalog_id in seen:
        raise SystemExit(f"duplicate application catalog id: {catalog_id}")
    if catalog_id not in by_id:
        raise SystemExit(f"unknown application catalog id: {catalog_id}")
    selected.append(by_id[catalog_id])
    seen.add(catalog_id)

print(json.dumps(selected))
PY
}

load_application_catalog_defaults_from_install_defaults() {
  local defaults_cache_dir=""
  local defaults_tarball=""
  local extract_dir="${TMP_ROOT}/install-defaults"
  local profile_file=""

  APPLICATION_CATALOG_DEFAULT_IDS=""
  [[ -n "${INSTALL_DEFAULTS_REF}" ]] \
    || die "official application catalog defaults require an upstream install-defaults ref"

  if ! try_cache_pull_oci_artifact "${INSTALL_DEFAULTS_REF}" "${CACHE_REUSE_ENABLED}" defaults_cache_dir; then
    die "failed to pull upstream install defaults ${INSTALL_DEFAULTS_REF}; official application catalog defaults must come from upstream"
  fi

  defaults_tarball="$(find_pulled_file "${defaults_cache_dir}" "install-defaults.tar.gz")"
  if [[ -z "${defaults_tarball}" || ! -f "${defaults_tarball}" ]]; then
    die "upstream install defaults ${INSTALL_DEFAULTS_REF} did not include install-defaults.tar.gz"
  fi

  rm -rf "${extract_dir}"
  mkdir -p "${extract_dir}"
  tar -xzf "${defaults_tarball}" -C "${extract_dir}"
  profile_file="${extract_dir}/install-defaults/defaults/${TARGET}.env"
  if [[ ! -f "${profile_file}" ]]; then
    die "upstream install defaults ${INSTALL_DEFAULTS_REF} did not include defaults/${TARGET}.env"
  fi

  APPLICATION_CATALOG_DEFAULT_IDS="$(
    python3 - <<'PY' "${profile_file}"
import re
import sys
from pathlib import Path

value = ""
for raw_line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    line = raw_line.strip()
    if not line or line.startswith("#"):
        continue
    key, field = line.split("=", 1)
    if key == "APPLICATION_CATALOG_DEFAULT_IDS":
        value = field.strip()
        break

if value and not re.fullmatch(r"[a-z0-9-]+(?:,[a-z0-9-]+)*", value):
    raise SystemExit("APPLICATION_CATALOG_DEFAULT_IDS must be a comma-separated list of catalog ids")

print(value)
PY
  )" || die "failed to parse APPLICATION_CATALOG_DEFAULT_IDS from ${INSTALL_DEFAULTS_REF}"

  [[ -n "${APPLICATION_CATALOG_DEFAULT_IDS}" ]] \
    || die "upstream install defaults ${INSTALL_DEFAULTS_REF} did not declare APPLICATION_CATALOG_DEFAULT_IDS for ${TARGET}"
  log "Loaded default application catalog ids from install defaults: ${APPLICATION_CATALOG_DEFAULT_IDS}"
}

resolve_application_catalog_ids_from_numbers() {
  local raw_selection="$1"
  python3 - <<'PY' "${APPLICATION_CATALOG_SOURCES_JSON}" "${raw_selection}"
import json
import sys

sources = json.loads(sys.argv[1])
numbers = [item.strip() for item in sys.argv[2].split(",") if item.strip()]
if not numbers:
    raise SystemExit("no application catalog numbers selected")

selected_ids = []
seen = set()
for raw_number in numbers:
    if not raw_number.isdigit():
        raise SystemExit(f"invalid application catalog number: {raw_number}")
    index = int(raw_number)
    if index < 1 or index > len(sources):
        raise SystemExit(f"application catalog number out of range: {raw_number}")
    catalog_id = str(sources[index - 1].get("catalog_id", "")).strip()
    if not catalog_id:
        raise SystemExit(f"application catalog number {raw_number} does not map to a valid catalog_id")
    if catalog_id in seen:
        raise SystemExit(f"duplicate application catalog selection: {catalog_id}")
    selected_ids.append(catalog_id)
    seen.add(catalog_id)

print(",".join(selected_ids))
PY
}

resolve_application_catalog_sources_from_numbers() {
  local raw_selection="$1"
  local selected_ids=""

  selected_ids="$(resolve_application_catalog_ids_from_numbers "${raw_selection}")" || return 1
  resolve_application_catalog_sources_from_ids "${selected_ids}"
}

parse_custom_application_catalog_refs_json() {
  local refs_csv="$1"
  python3 - <<'PY' "${refs_csv}"
import json
import sys

refs = [item.strip() for item in sys.argv[1].split(",") if item.strip()]
if not refs:
    raise SystemExit("no application catalog refs provided")

selected = []
seen = set()
for ref in refs:
    if ref in seen:
        raise SystemExit(f"duplicate application catalog ref: {ref}")
    selected.append(
        {
            "catalog_id": "",
            "catalog_name": "",
            "description": "Operator-provided application catalog ref",
            "artifact_ref": ref,
            "catalog_ref": "",
            "release_channel": "",
            "default_selected": False,
        }
    )
    seen.add(ref)

print(json.dumps(selected))
PY
}

merge_application_catalog_sources_json() {
  local base_json="$1"
  local additional_json="$2"
  python3 - <<'PY' "${base_json}" "${additional_json}"
import json
import sys

base = json.loads(sys.argv[1]) if sys.argv[1] and sys.argv[1] != "[]" else []
additional = json.loads(sys.argv[2]) if sys.argv[2] and sys.argv[2] != "[]" else []

seen_refs = set()
merged = []
for source in base:
    ref = str(source.get("artifact_ref", "")).strip() or str(source.get("catalog_ref", "")).strip()
    if ref:
        seen_refs.add(ref)
    merged.append(source)

for source in additional:
    ref = str(source.get("artifact_ref", "")).strip() or str(source.get("catalog_ref", "")).strip()
    if ref and ref in seen_refs:
        print(f"warning: skipping duplicate catalog ref: {ref}", file=sys.stderr)
        continue
    if ref:
        seen_refs.add(ref)
    merged.append(source)

print(json.dumps(merged))
PY
}

show_application_catalog_source_panel() {
  local default_display="$1"

  echo
  echo "Host-side application catalog selection"
  echo "Default catalogs: ${default_display}"
  echo "Options:"
  echo "  [ENTER] Use the default application catalog set"
  echo "  c       Customize catalog selection (official + custom catalog refs)"
  echo "  q       Quit"
  echo
}

pick_official_catalog_sources_json() {
  local raw_selection=""
  local -a entries=()

  mapfile -t entries < <(list_application_catalog_source_entries)
  (( ${#entries[@]} > 0 )) || die "no application catalog sources declared by the adapter"

  echo >&2
  echo "Official application catalogs:" >&2
  local i=1
  local entry=""
  for entry in "${entries[@]}"; do
    render_application_catalog_source_entry "${i}" "${entry}" >&2
    i=$((i + 1))
  done
  echo >&2
  read -r -p "Enter catalog numbers separated by commas (or ENTER to skip): " raw_selection
  [[ -n "${raw_selection}" ]] || { echo "[]"; return 0; }

  resolve_application_catalog_sources_from_numbers "${raw_selection}" || { echo "[]"; return 0; }
}

interactive_select_application_catalog_sources() {
  local choice=""
  local default_sources_json=""
  local default_display=""
  local official_json="[]"
  local custom_json="[]"
  local combined_json="[]"
  local combined_display=""

  default_sources_json="$(resolve_default_application_catalog_sources_json)"
  default_display="$(application_catalog_source_display_from_json "${default_sources_json}")"

  while [[ -z "${SELECTED_APPLICATION_CATALOG_SOURCES_JSON}" || "${SELECTED_APPLICATION_CATALOG_SOURCES_JSON}" == "[]" ]]; do
    show_application_catalog_source_panel "${default_display}"
    read -r -p "Choice: " choice

    case "${choice}" in
      "")
        SELECTED_APPLICATION_CATALOG_SOURCES_JSON="${default_sources_json}"
        SELECTED_APPLICATION_CATALOG_SOURCE_DISPLAY="${default_display}"
        return 0
        ;;
      c|C)
        # Step 1/2: official catalogs
        echo
        echo "Step 1/2: Select official application catalogs"
        official_json="$(pick_official_catalog_sources_json)" || official_json="[]"

        if [[ "${official_json}" != "[]" ]]; then
          log "Official catalogs selected: $(application_catalog_source_display_from_json "${official_json}")"
        else
          log "No official catalogs selected."
        fi

        # Step 2/2: custom catalog refs
        echo
        echo "Step 2/2: Add custom application catalog refs"
        read -r -p "Enter catalog OCI refs separated by commas (or ENTER to skip): " choice
        if [[ -n "${choice}" ]]; then
          custom_json="$(parse_custom_application_catalog_refs_json "${choice}")" || custom_json="[]"
        fi

        # Merge official + custom
        combined_json="$(merge_application_catalog_sources_json "${official_json}" "${custom_json}")"

        if [[ -z "${combined_json}" || "${combined_json}" == "[]" ]]; then
          log "No catalogs selected. Restarting."
          continue
        fi

        combined_display="$(application_catalog_source_display_from_json "${combined_json}")"
        echo
        echo "Combined application catalog selection: ${combined_display}"
        read -r -p "Confirm this selection? [Y/n]: " choice
        case "${choice}" in
          ""|y|Y)
            SELECTED_APPLICATION_CATALOG_SOURCES_JSON="${combined_json}"
            SELECTED_APPLICATION_CATALOG_SOURCE_DISPLAY="${combined_display}"
            ;;
          *)
            log "Selection cancelled. Restarting."
            official_json="[]"
            custom_json="[]"
            continue
            ;;
        esac
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

determine_application_catalog_sources() {
  SELECTED_APPLICATION_CATALOG_SOURCES_JSON="[]"
  SELECTED_APPLICATION_CATALOG_SOURCE_DISPLAY=""

  if [[ -n "${SUBSTRATE_REF}" ]]; then
    SELECTED_APPLICATION_CATALOG_SOURCES_JSON="$(parse_custom_application_catalog_refs_json "${SUBSTRATE_REF}")"
    SELECTED_APPLICATION_CATALOG_SOURCE_DISPLAY="$(application_catalog_source_display_from_json "${SELECTED_APPLICATION_CATALOG_SOURCES_JSON}")"
    return 0
  fi

  if [[ -n "${SUBSTRATE_CHANNEL}" ]]; then
    SELECTED_APPLICATION_CATALOG_SOURCES_JSON="$(resolve_application_catalog_sources_from_ids "${SUBSTRATE_CHANNEL}")"
    SELECTED_APPLICATION_CATALOG_SOURCE_DISPLAY="$(application_catalog_source_display_from_json "${SELECTED_APPLICATION_CATALOG_SOURCES_JSON}")"
    return 0
  fi

  if interactive_selection_enabled; then
    interactive_select_application_catalog_sources
    return 0
  fi

  SELECTED_APPLICATION_CATALOG_SOURCES_JSON="$(resolve_default_application_catalog_sources_json)"
  SELECTED_APPLICATION_CATALOG_SOURCE_DISPLAY="$(application_catalog_source_display_from_json "${SELECTED_APPLICATION_CATALOG_SOURCES_JSON}")"
}

parse_application_source_resolutions_spec() {
  local spec="${1:-}"

  python3 - <<'PY' "${spec}"
import json
import sys

spec = sys.argv[1].strip()
if not spec:
    print("{}")
    raise SystemExit(0)

resolutions = {}
for raw_entry in spec.split(","):
    entry = raw_entry.strip()
    if not entry:
        continue
    if "=" not in entry:
        raise SystemExit(
            f"invalid --app-source-resolutions entry {entry!r}; expected APP_UID=CATALOG_ID"
        )
    app_uid, catalog_id = entry.split("=", 1)
    app_uid = app_uid.strip()
    catalog_id = catalog_id.strip()
    if not app_uid or not catalog_id:
        raise SystemExit(
            f"invalid --app-source-resolutions entry {entry!r}; expected APP_UID=CATALOG_ID"
        )
    if app_uid in resolutions:
        raise SystemExit(f"duplicate app source resolution for {app_uid}")
    resolutions[app_uid] = catalog_id

print(json.dumps(resolutions, sort_keys=True))
PY
}

application_source_resolution_set() {
  local app_uid="$1"
  local catalog_id="$2"

  python3 - <<'PY' "${APPLICATION_SOURCE_RESOLUTIONS_JSON}" "${app_uid}" "${catalog_id}"
import json
import sys

resolutions = json.loads(sys.argv[1])
app_uid = sys.argv[2].strip()
catalog_id = sys.argv[3].strip()
if not app_uid or not catalog_id:
    raise SystemExit("application source resolution updates require non-empty app_uid and catalog_id")
resolutions[app_uid] = catalog_id
print(json.dumps(resolutions, sort_keys=True))
PY
}

write_application_catalog_duplicate_report() {
  local source_records_json="$1"
  local out_json="$2"

  python3 "${ROOT}/tools/merge-application-catalogs.py" \
    --analysis-only \
    --sources-json "${source_records_json}" \
    --out-duplicates "${out_json}"
}

list_duplicate_application_uids_without_resolution() {
  local duplicate_report_json="$1"

  python3 - <<'PY' "${duplicate_report_json}" "${APPLICATION_SOURCE_RESOLUTIONS_JSON}"
import json
import sys

duplicate_report = json.load(open(sys.argv[1], "r", encoding="utf-8"))
resolutions = json.loads(sys.argv[2])

for item in duplicate_report:
    app_uid = str(item.get("app_uid", "")).strip()
    if not app_uid:
        continue
    if bool(item.get("definitions_identical", False)):
        continue
    if app_uid not in resolutions:
        print(app_uid)
PY
}

duplicate_application_candidate_count() {
  local duplicate_report_json="$1"
  local app_uid="$2"

  python3 - <<'PY' "${duplicate_report_json}" "${app_uid}"
import json
import sys

duplicate_report = json.load(open(sys.argv[1], "r", encoding="utf-8"))
target_app_uid = sys.argv[2].strip()
for item in duplicate_report:
    if str(item.get("app_uid", "")).strip() == target_app_uid:
        candidates = item.get("candidates") or []
        if not isinstance(candidates, list) or not candidates:
            raise SystemExit(f"duplicate report entry for {target_app_uid!r} is missing candidates")
        print(len(candidates))
        raise SystemExit(0)
raise SystemExit(f"duplicate report is missing app_uid {target_app_uid!r}")
PY
}

duplicate_application_catalog_id_from_choice() {
  local duplicate_report_json="$1"
  local app_uid="$2"
  local raw_choice="$3"

  python3 - <<'PY' "${duplicate_report_json}" "${app_uid}" "${raw_choice}"
import json
import sys

duplicate_report = json.load(open(sys.argv[1], "r", encoding="utf-8"))
target_app_uid = sys.argv[2].strip()
raw_choice = sys.argv[3].strip()
if not raw_choice.isdigit():
    raise SystemExit(f"invalid source choice {raw_choice!r}")
choice = int(raw_choice)

for item in duplicate_report:
    if str(item.get("app_uid", "")).strip() != target_app_uid:
        continue
    candidates = item.get("candidates") or []
    if choice < 1 or choice > len(candidates):
        raise SystemExit(f"source choice out of range: {raw_choice}")
    catalog_id = str(candidates[choice - 1].get("catalog_id", "")).strip()
    if not catalog_id:
        raise SystemExit(f"duplicate report candidate {raw_choice} for {target_app_uid!r} is missing catalog_id")
    print(catalog_id)
    raise SystemExit(0)

raise SystemExit(f"duplicate report is missing app_uid {target_app_uid!r}")
PY
}

render_duplicate_application_source_prompt() {
  local duplicate_report_json="$1"
  local app_uid="$2"

  python3 - <<'PY' "${duplicate_report_json}" "${app_uid}"
import json
import sys

duplicate_report = json.load(open(sys.argv[1], "r", encoding="utf-8"))
target_app_uid = sys.argv[2].strip()

for item in duplicate_report:
    app_uid = str(item.get("app_uid", "")).strip()
    if app_uid != target_app_uid:
        continue

    display_name = str(item.get("display_name", app_uid)).strip() or app_uid
    definitions_identical = bool(item.get("definitions_identical", False))
    print("Duplicate application source selection")
    if display_name == app_uid:
        print(f"Application : {app_uid}")
    else:
        print(f"Application : {display_name} ({app_uid})")
    if definitions_identical:
        print("Note        : These catalog entries currently look identical, but the source catalog still must be chosen.")
    else:
        print("Note        : These catalog entries differ. Choose which source catalog to expose.")
    print("Sources:")

    for index, candidate in enumerate(item.get("candidates") or [], start=1):
        catalog_name = str(candidate.get("catalog_name", "")).strip()
        catalog_id = str(candidate.get("catalog_id", "")).strip()
        marker = " [default in source]" if bool(candidate.get("default_selected", False)) else ""
        print(f"  {index}) {catalog_name} ({catalog_id}){marker}")
        description = str(candidate.get("description", "")).strip()
        if description:
            print(f"      {description}")
        print(f"      artifact: {candidate.get('artifact_ref', '')}")
        resolved_images = candidate.get("resolved_images") or []
        if resolved_images:
            print("      images:")
            for image in resolved_images:
                print(f"        - {image.get('name', '')}: {image.get('ref', '')}")
    raise SystemExit(0)

raise SystemExit(f"duplicate report is missing app_uid {target_app_uid!r}")
PY
}

require_duplicate_application_source_choices() {
  local duplicate_report_json="$1"
  local -a unresolved_app_uids=()
  local app_uid=""
  local raw_choice=""
  local candidate_count=""
  local chosen_catalog_id=""

  mapfile -t unresolved_app_uids < <(list_duplicate_application_uids_without_resolution "${duplicate_report_json}")
  (( ${#unresolved_app_uids[@]} > 0 )) || return 0

  if ! interactive_selection_enabled; then
    die "$(
      python3 - <<'PY' "${duplicate_report_json}"
import json
import sys

duplicate_report = json.load(open(sys.argv[1], "r", encoding="utf-8"))
lines = [
    "duplicate apps are present across the selected catalogs and require explicit source choices.",
    "Rerun interactively or pass --app-source-resolutions APP_UID=CATALOG_ID[,APP_UID=CATALOG_ID...].",
]
for item in duplicate_report:
    app_uid = str(item.get("app_uid", "")).strip()
    if not app_uid:
        continue
    if bool(item.get("definitions_identical", False)):
        continue
    choices = ", ".join(
        f\"{candidate.get('catalog_id', '')} ({candidate.get('catalog_name', '')})\"
        for candidate in (item.get('candidates') or [])
    )
    lines.append(f\"  - {app_uid}: {choices}\")
print(\"\\n\".join(lines))
PY
    )"
  fi

  echo
  echo "Selected application catalogs contain duplicate applications."
  echo "Choose which catalog should provide each duplicated app in the merged catalog."

  for app_uid in "${unresolved_app_uids[@]}"; do
    candidate_count="$(duplicate_application_candidate_count "${duplicate_report_json}" "${app_uid}")"
    while :; do
      echo
      render_duplicate_application_source_prompt "${duplicate_report_json}" "${app_uid}"
      echo
      read -r -p "Choose source [1-${candidate_count}] (q=quit): " raw_choice
      case "${raw_choice}" in
        q|Q)
          die "Mission compose aborted by user"
          ;;
        *)
          chosen_catalog_id="$(duplicate_application_catalog_id_from_choice "${duplicate_report_json}" "${app_uid}" "${raw_choice}" 2>/dev/null || true)"
          if [[ -z "${chosen_catalog_id}" ]]; then
            log "Invalid source selection."
            continue
          fi
          APPLICATION_SOURCE_RESOLUTIONS_JSON="$(application_source_resolution_set "${app_uid}" "${chosen_catalog_id}")"
          break
          ;;
      esac
    done
  done
}

APPLICATION_CATALOG_PRESENT=0
APPLICATION_CATALOG_FILE=""
APPLICATION_CATALOG_ID=""
APPLICATION_CATALOG_NAME=""
APPLICATION_CATALOG_DESCRIPTION=""
APPLICATION_DEFAULT_APP_IDS_JSON="[]"
APPLICATION_ALL_APP_IDS_JSON="[]"
SELECTED_APPLICATION_SELECTION_MODE=""
SELECTED_APPLICATION_IDS_JSON="[]"
SELECTED_APPLICATION_IDS_DISPLAY=""

load_application_catalog_metadata() {
  local catalog_file="${1:-${APPLICATION_CATALOG_FILE:-}}"

  APPLICATION_CATALOG_PRESENT=0
  if [[ -z "${catalog_file}" && -n "${SUBSTRATE_EXTRACT_DIR:-}" ]]; then
    catalog_file="${SUBSTRATE_EXTRACT_DIR}/platform/catalog.json"
  fi
  APPLICATION_CATALOG_FILE="${catalog_file}"
  [[ -f "${APPLICATION_CATALOG_FILE}" ]] || return 0

  local catalog_dump=""
  catalog_dump="$(
    python3 - <<'PY' "${APPLICATION_CATALOG_FILE}"
import json
import sys

catalog_path = sys.argv[1]
with open(catalog_path, "r", encoding="utf-8") as handle:
    catalog = json.load(handle)

if catalog.get("schema") != 1:
    raise SystemExit(f"{catalog_path} must declare schema=1")
if catalog.get("kind") != "ourbox-application-catalog":
    raise SystemExit(f"{catalog_path} must declare kind=ourbox-application-catalog")

catalog_id = str(catalog.get("catalog_id", "")).strip()
catalog_name = str(catalog.get("catalog_name", "")).strip()
catalog_description = str(catalog.get("catalog_description", "")).strip()
apps = catalog.get("apps")
default_app_ids = catalog.get("default_app_ids")

if not catalog_id:
    raise SystemExit(f"{catalog_path} must declare catalog_id")
if not catalog_name:
    raise SystemExit(f"{catalog_path} must declare catalog_name")
if not isinstance(apps, list) or not apps:
    raise SystemExit(f"{catalog_path} must declare a non-empty apps list")
if not isinstance(default_app_ids, list) or not default_app_ids:
    raise SystemExit(f"{catalog_path} must declare non-empty default_app_ids")

all_app_ids = []
seen_ids = set()
for app in apps:
    app_id = str(app.get("id", "")).strip()
    if not app_id:
        raise SystemExit(f"{catalog_path} contains an app without an id")
    if app_id in seen_ids:
        raise SystemExit(f"{catalog_path} contains duplicate app id {app_id}")
    all_app_ids.append(app_id)
    seen_ids.add(app_id)

unknown_defaults = sorted(set(default_app_ids) - seen_ids)
if unknown_defaults:
    raise SystemExit(
        f"{catalog_path} declares unknown default_app_ids: {', '.join(unknown_defaults)}"
    )

print(
    json.dumps(
        {
            "catalog_id": catalog_id,
            "catalog_name": catalog_name,
            "catalog_description": catalog_description,
            "default_app_ids": default_app_ids,
            "all_app_ids": all_app_ids,
        },
        separators=(",", ":"),
    )
)
PY
  )" || die "failed to parse application catalog metadata: ${APPLICATION_CATALOG_FILE}"

  APPLICATION_CATALOG_PRESENT=1
  APPLICATION_CATALOG_ID="$(
    python3 - <<'PY' "${catalog_dump}"
import json
import sys
print(json.loads(sys.argv[1])["catalog_id"])
PY
  )"
  APPLICATION_CATALOG_NAME="$(
    python3 - <<'PY' "${catalog_dump}"
import json
import sys
print(json.loads(sys.argv[1])["catalog_name"])
PY
  )"
  APPLICATION_CATALOG_DESCRIPTION="$(
    python3 - <<'PY' "${catalog_dump}"
import json
import sys
print(json.loads(sys.argv[1])["catalog_description"])
PY
  )"
  APPLICATION_DEFAULT_APP_IDS_JSON="$(
    python3 - <<'PY' "${catalog_dump}"
import json
import sys
print(json.dumps(json.loads(sys.argv[1])["default_app_ids"]))
PY
  )"
  APPLICATION_ALL_APP_IDS_JSON="$(
    python3 - <<'PY' "${catalog_dump}"
import json
import sys
print(json.dumps(json.loads(sys.argv[1])["all_app_ids"]))
PY
  )"
}

application_ids_display_from_json() {
  local app_ids_json="$1"
  python3 - <<'PY' "${APPLICATION_CATALOG_FILE}" "${app_ids_json}"
import json
import sys

catalog_path = sys.argv[1]
app_ids = json.loads(sys.argv[2])
if not isinstance(app_ids, list) or not app_ids:
    raise SystemExit(1)

catalog = {}
try:
    with open(catalog_path, "r", encoding="utf-8") as handle:
        loaded = json.load(handle)
    catalog = {
        str(app.get("id", "")).strip(): app
        for app in loaded.get("apps", [])
        if str(app.get("id", "")).strip()
    }
except Exception:
    catalog = {}

labels = []
for app_id in app_ids:
    normalized = str(app_id)
    app = catalog.get(normalized)
    if app is None:
        labels.append(normalized)
        continue
    display_name = str(app.get("display_name", normalized)).strip() or normalized
    if display_name == normalized:
        labels.append(normalized)
    else:
        labels.append(f"{display_name} ({normalized})")

print(", ".join(labels))
PY
}

resolve_selected_application_ids_json() {
  local selection_mode="$1"
  local selection_arg="${2:-}"

  python3 - <<'PY' "${APPLICATION_CATALOG_FILE}" "${APPLICATION_DEFAULT_APP_IDS_JSON}" "${APPLICATION_ALL_APP_IDS_JSON}" "${selection_mode}" "${selection_arg}"
import json
import sys

catalog_path, default_ids_json, all_ids_json, selection_mode, selection_arg = sys.argv[1:]
with open(catalog_path, "r", encoding="utf-8") as handle:
    catalog = json.load(handle)

app_by_id = {
    str(app["id"]): app
    for app in catalog["apps"]
}
default_ids = json.loads(default_ids_json)
all_ids = json.loads(all_ids_json)

def require_nonempty(ids):
    if not ids:
        raise SystemExit("selected application set must not be empty")
    return ids

if selection_mode == "catalog-defaults":
    print(json.dumps(require_nonempty(default_ids)))
    raise SystemExit(0)
if selection_mode == "all-apps":
    print(json.dumps(require_nonempty(all_ids)))
    raise SystemExit(0)
if selection_mode != "custom":
    raise SystemExit(f"unsupported application selection_mode {selection_mode!r}")

raw_ids = [item.strip() for item in selection_arg.split(",") if item.strip()]
selected_ids = []
seen_ids = set()
for app_id in raw_ids:
    if app_id in seen_ids:
        raise SystemExit(f"duplicate application id in selection: {app_id}")
    if app_id not in app_by_id:
        raise SystemExit(f"unknown application id in selection: {app_id}")
    selected_ids.append(app_id)
    seen_ids.add(app_id)

print(json.dumps(require_nonempty(selected_ids)))
PY
}

render_application_catalog_entries() {
  python3 - <<'PY' "${APPLICATION_CATALOG_FILE}" "${APPLICATION_DEFAULT_APP_IDS_JSON}"
import json
import sys

catalog_path = sys.argv[1]
default_ids = set(json.loads(sys.argv[2]))
with open(catalog_path, "r", encoding="utf-8") as handle:
    catalog = json.load(handle)

for index, app in enumerate(catalog["apps"], start=1):
    app_id = str(app["id"])
    display_name = str(app.get("display_name", app_id))
    description = str(app.get("description", "")).strip()
    source_catalog_names = app.get("source_catalog_names") or []
    selected_source_catalog_name = str(app.get("selected_source_catalog_name", "")).strip()
    marker = "default" if app_id in default_ids else ""
    line = f"  {index}) {app_id:<16} {display_name}"
    if marker:
        line += f" [{marker}]"
    print(line)
    if description:
        print(f"      {description}")
    if isinstance(source_catalog_names, list) and source_catalog_names:
        normalized_names = [str(name).strip() for name in source_catalog_names if str(name).strip()]
        if selected_source_catalog_name and len(normalized_names) > 1:
            alternates = [name for name in normalized_names if name != selected_source_catalog_name]
            print(f"      selected source: {selected_source_catalog_name}")
            if alternates:
                print(f"      also available from: {', '.join(alternates)}")
        else:
            print(f"      source: {', '.join(normalized_names)}")
PY
}

resolve_application_ids_csv_from_numbers() {
  local raw_selection="$1"
  python3 - <<'PY' "${APPLICATION_CATALOG_FILE}" "${raw_selection}"
import json
import sys

catalog_path, raw_selection = sys.argv[1:]
with open(catalog_path, "r", encoding="utf-8") as handle:
    catalog = json.load(handle)

apps = catalog["apps"]
numbers = [item.strip() for item in raw_selection.split(",") if item.strip()]
if not numbers:
    raise SystemExit("no application numbers selected")

selected_ids = []
seen_ids = set()
for raw_number in numbers:
    if not raw_number.isdigit():
        raise SystemExit(f"invalid application number: {raw_number}")
    index = int(raw_number)
    if index < 1 or index > len(apps):
        raise SystemExit(f"application number out of range: {raw_number}")
    app_id = str(apps[index - 1]["id"])
    if app_id in seen_ids:
        raise SystemExit(f"duplicate application selection: {app_id}")
    selected_ids.append(app_id)
    seen_ids.add(app_id)

print(",".join(selected_ids))
PY
}

resolve_custom_application_ids_from_numbers() {
  local raw_selection="$1"
  local selected_ids_csv=""

  selected_ids_csv="$(resolve_application_ids_csv_from_numbers "${raw_selection}")" || return 1
  resolve_selected_application_ids_json "custom" "${selected_ids_csv}"
}

show_application_selection_panel() {
  local default_display="$1"

  echo
  echo "Host-side application selection"
  echo "Catalog       : ${APPLICATION_CATALOG_NAME} (${APPLICATION_CATALOG_ID})"
  if [[ -n "${APPLICATION_CATALOG_DESCRIPTION}" ]]; then
    echo "Description   : ${APPLICATION_CATALOG_DESCRIPTION}"
  fi
  echo "Default apps  : ${default_display}"
  echo "Options:"
  echo "  [ENTER] Use the catalog default app set"
  echo "  a       Install all apps from this catalog"
  echo "  c       Choose a custom app set from this catalog"
  echo "  q       Quit"
  echo
}

choose_custom_applications_interactive() {
  local raw_selection=""

  echo
  echo "Applications in ${APPLICATION_CATALOG_NAME}:"
  render_application_catalog_entries
  echo
  read -r -p "Enter app numbers separated by commas (or ENTER to cancel): " raw_selection
  [[ -n "${raw_selection}" ]] || return 1

  SELECTED_APPLICATION_IDS_JSON="$(resolve_custom_application_ids_from_numbers "${raw_selection}")" || return 1
  SELECTED_APPLICATION_SELECTION_MODE="custom"
  SELECTED_APPLICATION_IDS_DISPLAY="$(application_ids_display_from_json "${SELECTED_APPLICATION_IDS_JSON}")"
}

interactive_select_applications() {
  local choice=""
  local default_display=""

  default_display="$(application_ids_display_from_json "${APPLICATION_DEFAULT_APP_IDS_JSON}")"
  while [[ -z "${SELECTED_APPLICATION_SELECTION_MODE}" ]]; do
    show_application_selection_panel "${default_display}"
    read -r -p "Choice: " choice

    case "${choice}" in
      "")
        SELECTED_APPLICATION_SELECTION_MODE="catalog-defaults"
        SELECTED_APPLICATION_IDS_JSON="${APPLICATION_DEFAULT_APP_IDS_JSON}"
        SELECTED_APPLICATION_IDS_DISPLAY="${default_display}"
        ;;
      a|A)
        SELECTED_APPLICATION_SELECTION_MODE="all-apps"
        SELECTED_APPLICATION_IDS_JSON="${APPLICATION_ALL_APP_IDS_JSON}"
        SELECTED_APPLICATION_IDS_DISPLAY="$(application_ids_display_from_json "${SELECTED_APPLICATION_IDS_JSON}")"
        ;;
      c|C)
        choose_custom_applications_interactive || true
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

determine_application_selection() {
  if [[ "${APPLICATION_CATALOG_PRESENT}" != "1" ]]; then
    [[ "${ALL_APPS}" == "0" && -z "${APP_IDS}" ]] || die "the selected application catalog bundle does not advertise catalog metadata, so explicit application selection is unavailable"
    SELECTED_APPLICATION_SELECTION_MODE=""
    SELECTED_APPLICATION_IDS_JSON="[]"
    SELECTED_APPLICATION_IDS_DISPLAY=""
    return 0
  fi

  if [[ "${ALL_APPS}" == "1" ]]; then
    SELECTED_APPLICATION_SELECTION_MODE="all-apps"
    SELECTED_APPLICATION_IDS_JSON="${APPLICATION_ALL_APP_IDS_JSON}"
    SELECTED_APPLICATION_IDS_DISPLAY="$(application_ids_display_from_json "${SELECTED_APPLICATION_IDS_JSON}")"
    return 0
  fi

  if [[ -n "${APP_IDS}" ]]; then
    SELECTED_APPLICATION_SELECTION_MODE="custom"
    SELECTED_APPLICATION_IDS_JSON="$(resolve_selected_application_ids_json "custom" "${APP_IDS}")"
    SELECTED_APPLICATION_IDS_DISPLAY="$(application_ids_display_from_json "${SELECTED_APPLICATION_IDS_JSON}")"
    return 0
  fi

  if interactive_selection_enabled; then
    interactive_select_applications
    return 0
  fi

  SELECTED_APPLICATION_SELECTION_MODE="catalog-defaults"
  SELECTED_APPLICATION_IDS_JSON="${APPLICATION_DEFAULT_APP_IDS_JSON}"
  SELECTED_APPLICATION_IDS_DISPLAY="$(application_ids_display_from_json "${SELECTED_APPLICATION_IDS_JSON}")"
}

json_array_to_csv() {
  local json_value="$1"
  python3 - <<'PY' "${json_value}"
import json
import sys

values = json.loads(sys.argv[1])
if not isinstance(values, list):
    raise SystemExit("expected a JSON array")
print(",".join(str(value) for value in values))
PY
}

pick_container_cli() {
  local candidate=""
  for candidate in docker nerdctl podman; do
    if command -v "${candidate}" >/dev/null 2>&1; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  return 1
}

ensure_container_cli() {
  if [[ -n "${CONTAINER_CLI}" ]]; then
    return 0
  fi
  CONTAINER_CLI="$(pick_container_cli || true)"
  [[ -n "${CONTAINER_CLI}" ]] || die "composing selected application bundles requires docker, nerdctl, or podman on the host"
  log "Using container CLI for selected application images: ${CONTAINER_CLI}"
}

image_tar_name() {
  local ref="$1"
  local base=""

  base="$(echo "${ref}" | sed 's|/|_|g; s|:|_|g')"
  printf '%s.tar\n' "${base}"
}

pull_and_save_image_tar() {
  local image_ref="$1"
  local tar_path="$2"
  local cli_base=""

  ensure_container_cli
  cli_base="$(basename "${CONTAINER_CLI%% *}")"

  case "${cli_base}" in
    docker|nerdctl)
      ${CONTAINER_CLI} pull --platform="linux/${EXPECTED_SUBSTRATE_ARCH}" "${image_ref}"
      if [[ "${cli_base}" == "nerdctl" ]]; then
        ${CONTAINER_CLI} save --platform="linux/${EXPECTED_SUBSTRATE_ARCH}" -o "${tar_path}" "${image_ref}"
      else
        ${CONTAINER_CLI} save -o "${tar_path}" "${image_ref}"
      fi
      ;;
    podman)
      ${CONTAINER_CLI} pull --arch="${EXPECTED_SUBSTRATE_ARCH}" --os=linux "${image_ref}"
      ${CONTAINER_CLI} save -o "${tar_path}" "${image_ref}"
      ;;
    *)
      die "unsupported container CLI: ${CONTAINER_CLI}"
      ;;
  esac

  [[ -s "${tar_path}" ]] || die "image save failed for ${image_ref}"
}

resolve_application_catalog_bundle_ref_from_catalog() {
  local catalog_ref="$1"
  local release_channel="${2:-stable}"
  local catalog_cache_dir=""
  local catalog_tsv=""
  local resolved_ref=""

  cache_pull_oci_artifact "${catalog_ref}" "${CACHE_REUSE_ENABLED}" catalog_cache_dir
  catalog_tsv="$(find_pulled_file "${catalog_cache_dir}" "catalog.tsv")"
  [[ -n "${catalog_tsv}" && -f "${catalog_tsv}" ]] || die "application catalog index missing catalog.tsv: ${catalog_ref}"

  resolved_ref="$(select_substrate_ref_from_catalog "${catalog_tsv}" "${release_channel}" "${EXPECTED_SUBSTRATE_ARCH}" || true)"
  is_pinned_ref "${resolved_ref}" \
    || die "application catalog index ${catalog_ref} had no ${release_channel} row for arch=${EXPECTED_SUBSTRATE_ARCH}"
  printf '%s\n' "${resolved_ref}"
}

extract_selected_application_catalog_source_entries() {
  python3 - <<'PY' "${SELECTED_APPLICATION_CATALOG_SOURCES_JSON}"
import json
import sys

sources = json.loads(sys.argv[1])
if not isinstance(sources, list) or not sources:
    raise SystemExit("selected application catalog sources must be a non-empty list")

for source in sources:
    print("\x1f".join(
        [
            str(source.get("catalog_id", "")).strip(),
            str(source.get("catalog_name", "")).strip(),
            str(source.get("artifact_ref", "")).strip(),
            str(source.get("catalog_ref", "")).strip(),
            str(source.get("release_channel", "")).strip(),
        ]
    ))
PY
}

prepare_merged_application_catalog() {
  local selection_mode="$1"
  local selected_ids_json="${2:-[]}"
  local selected_ids_csv=""
  local source_records_tsv="${TMP_ROOT}/application-catalog-source-records.tsv"
  local source_records_json="${TMP_ROOT}/application-catalog-source-records.json"
  local duplicate_report_json="${TMP_ROOT}/application-catalog-duplicates.json"
  local extracted_root="${TMP_ROOT}/application-catalog-sources"
  local merge_root="${TMP_ROOT}/merged-application-catalog"
  local requested_catalog_id=""
  local requested_catalog_name=""
  local requested_artifact_ref=""
  local requested_catalog_ref=""
  local requested_release_channel=""
  local requested_pull_ref=""
  local catalog_cache_dir=""
  local extracted_dir=""
  local bundle_tarball=""
  local bundle_sha=""
  local pinned_ref=""
  local pinned_digest=""
  local suggested_index_ref=""
  local catalog_dump=""
  local -a catalog_fields=()
  local index=0

  rm -rf "${extracted_root}" "${merge_root}"
  mkdir -p "${extracted_root}"
  : > "${source_records_tsv}"

  while IFS=$'\x1f' read -r requested_catalog_id requested_catalog_name requested_artifact_ref requested_catalog_ref requested_release_channel; do
    requested_pull_ref="${requested_artifact_ref}"
    if [[ -z "${requested_pull_ref}" && -n "${requested_catalog_ref}" ]]; then
      requested_pull_ref="$(resolve_application_catalog_bundle_ref_from_catalog "${requested_catalog_ref}" "${requested_release_channel:-stable}")"
    fi
    [[ -n "${requested_pull_ref}" ]] || die "selected application catalog source is missing artifact_ref and catalog_ref"

    cache_pull_oci_artifact "${requested_pull_ref}" "${CACHE_REUSE_ENABLED}" catalog_cache_dir
    pinned_digest="${OURBOX_CACHE_LAST_DIGEST}"
    pinned_ref="${OURBOX_CACHE_LAST_PINNED_REF}"
    log_resolved_artifact_ref "application catalog" "${requested_artifact_ref:-${requested_catalog_ref}}" "${pinned_ref}"

    bundle_tarball="$(find_pulled_file "${catalog_cache_dir}" "application-catalog-bundle.tar.gz")"
    if [[ ! -f "${bundle_tarball}" ]]; then
      local index_tsv=""
      index_tsv="$(find_pulled_file "${catalog_cache_dir}" "catalog.tsv")"
      if [[ -f "${index_tsv}" ]]; then
        log "Ref ${requested_pull_ref} is a catalog index; resolving bundle from it"
        requested_pull_ref="$(resolve_application_catalog_bundle_ref_from_catalog "${pinned_ref}" "${requested_release_channel:-stable}")"
        cache_pull_oci_artifact "${requested_pull_ref}" "${CACHE_REUSE_ENABLED}" catalog_cache_dir
        pinned_digest="${OURBOX_CACHE_LAST_DIGEST}"
        pinned_ref="${OURBOX_CACHE_LAST_PINNED_REF}"
        bundle_tarball="$(find_pulled_file "${catalog_cache_dir}" "application-catalog-bundle.tar.gz")"
      fi
    fi
    [[ -f "${bundle_tarball}" ]] || die "cached application catalog bundle missing application-catalog-bundle.tar.gz: ${catalog_cache_dir}"
    bundle_sha="${bundle_tarball}.sha256"
    if [[ -f "${bundle_sha}" ]]; then
      local expected_sha=""
      local actual_sha=""
      expected_sha="$(awk 'NF>=1 {print $1; exit}' "${bundle_sha}")"
      expected_sha="${expected_sha,,}"
      [[ "${expected_sha}" =~ ^[0-9a-f]{64}$ ]] || die "invalid sha256 in ${bundle_sha}"
      actual_sha="$(sha256_file "${bundle_tarball}")"
      [[ "${expected_sha}" == "${actual_sha}" ]] || die "application catalog bundle sha mismatch for ${pinned_ref}"
    fi

    index=$((index + 1))
    extracted_dir="${extracted_root}/source-${index}"
    mkdir -p "${extracted_dir}"
    tar -xzf "${bundle_tarball}" -C "${extracted_dir}"
    [[ -f "${extracted_dir}/catalog.json" ]] || die "application catalog bundle missing catalog.json: ${pinned_ref}"
    [[ -f "${extracted_dir}/images.lock.json" ]] || die "application catalog bundle missing images.lock.json: ${pinned_ref}"
    [[ -f "${extracted_dir}/manifest.env" ]] || die "application catalog bundle missing manifest.env: ${pinned_ref}"
    [[ -f "${extracted_dir}/profile.env" ]] || die "application catalog bundle missing profile.env: ${pinned_ref}"

    catalog_dump="$(
      python3 - <<'PY' "${extracted_dir}/catalog.json"
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    catalog = json.load(handle)

if catalog.get("schema") != 1:
    raise SystemExit("application catalog must declare schema=1")
if catalog.get("kind") != "ourbox-application-catalog":
    raise SystemExit("application catalog must declare kind=ourbox-application-catalog")

catalog_id = str(catalog.get("catalog_id", "")).strip()
catalog_name = str(catalog.get("catalog_name", "")).strip()
if not catalog_id or not catalog_name:
    raise SystemExit("application catalog must declare catalog_id and catalog_name")

print(catalog_id)
print(catalog_name)
PY
    )" || die "failed to parse application catalog bundle metadata: ${pinned_ref}"
    mapfile -t catalog_fields <<<"${catalog_dump}"
    [[ "${#catalog_fields[@]}" -eq 2 ]] || die "application catalog bundle parse produced an unexpected field set: ${pinned_ref}"

    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${catalog_fields[0]}" \
      "${catalog_fields[1]}" \
      "${pinned_ref}" \
      "${pinned_digest}" \
      "${extracted_dir}/catalog.json" \
      "${extracted_dir}/images.lock.json" >> "${source_records_tsv}"
  done < <(extract_selected_application_catalog_source_entries)

  python3 - <<'PY' "${source_records_tsv}" "${source_records_json}"
import json
import sys
from pathlib import Path

records = []
for raw_line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    if not raw_line.strip():
        continue
    catalog_id, catalog_name, artifact_ref, artifact_digest, catalog_path, images_lock_path = raw_line.split("\t")
    records.append(
        {
            "catalog_id": catalog_id,
            "catalog_name": catalog_name,
            "artifact_ref": artifact_ref,
            "artifact_digest": artifact_digest,
            "catalog_path": catalog_path,
            "images_lock_path": images_lock_path,
        }
    )

if not records:
    raise SystemExit("no application catalog sources were staged")

Path(sys.argv[2]).write_text(json.dumps(records, indent=2) + "\n", encoding="utf-8")
PY

  write_application_catalog_duplicate_report "${source_records_json}" "${duplicate_report_json}"
  require_duplicate_application_source_choices "${duplicate_report_json}"

  selected_ids_csv=""
  if [[ "${selection_mode}" == "custom" ]]; then
    selected_ids_csv="$(json_array_to_csv "${selected_ids_json}")"
  fi

  mkdir -p "${merge_root}"
  MERGED_APPLICATION_CATALOG_FILE="${merge_root}/catalog.json"
  MERGED_SELECTED_APPLICATIONS_FILE="${merge_root}/selected-apps.json"
  MERGED_IMAGES_LOCK_FILE="${merge_root}/images.lock.json"
  MERGED_APPLICATION_SUMMARY_FILE="${merge_root}/summary.json"

  python3 "${ROOT}/tools/merge-application-catalogs.py" \
    --sources-json "${source_records_json}" \
    --selection-mode "${selection_mode}" \
    --selected-app-ids "${selected_ids_csv}" \
    --source-resolutions-json "${APPLICATION_SOURCE_RESOLUTIONS_JSON}" \
    --out-duplicates "${duplicate_report_json}" \
    --out-catalog "${MERGED_APPLICATION_CATALOG_FILE}" \
    --out-selected-apps "${MERGED_SELECTED_APPLICATIONS_FILE}" \
    --out-images-lock "${MERGED_IMAGES_LOCK_FILE}" \
    --out-summary "${MERGED_APPLICATION_SUMMARY_FILE}"

  APPLICATION_CATALOG_FILE="${MERGED_APPLICATION_CATALOG_FILE}"
  load_application_catalog_metadata
}

log_application_catalog_merge_summary() {
  [[ -f "${MERGED_APPLICATION_SUMMARY_FILE}" ]] || return 0
  python3 - <<'PY' "${MERGED_APPLICATION_SUMMARY_FILE}"
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    summary = json.load(handle)

source_catalogs = summary.get("source_catalogs") or []
selected_ids = summary.get("selected_app_ids") or []
conflicts = summary.get("conflicts") or []

print(f"Merged application catalogs: {len(source_catalogs)} source(s), {len(selected_ids)} selected app(s)")
for conflict in conflicts:
    conflict_type = str(conflict.get("type", "")).strip()
    app_uid = str(conflict.get("app_uid", "")).strip()
    kept = str(conflict.get("kept_catalog_id", "")).strip()
    dropped = str(conflict.get("dropped_catalog_id", "")).strip()
    selected = str(conflict.get("selected_catalog_id", "")).strip()
    policy = str(conflict.get("policy", "")).strip()
    kept_app_uid = str(conflict.get("kept_app_uid", "")).strip()
    definitions_identical = bool(conflict.get("definitions_identical", False))
    available_catalog_ids = conflict.get("available_catalog_ids") or []
    if conflict_type == "default-backend" and app_uid and kept_app_uid and kept and dropped:
        print(
            f"Default backend conflict: kept {kept_app_uid} from {kept}, disabled {app_uid} from {dropped} "
            f"({policy or 'first-selected-default-backend-wins'})"
        )
        continue
    if conflict_type == "duplicate-app-source" and app_uid and selected:
        alternates = [str(item).strip() for item in available_catalog_ids if str(item).strip() and str(item).strip() != selected]
        note = "definitions-identical" if definitions_identical else "definitions-differ"
        if alternates:
            print(
                f"Selected source for {app_uid}: {selected} (also available from {', '.join(alternates)}; "
                f"{policy or 'operator-selected-source'}, {note})"
            )
        else:
            print(
                f"Selected source for {app_uid}: {selected} "
                f"({policy or 'operator-selected-source'}, {note})"
            )
        continue
    if app_uid and kept and dropped:
        print(f"Conflict resolved for {app_uid}: kept {kept}, dropped {dropped} ({policy or 'first-selected-source-wins'})")
PY
}

stage_selected_substrate_bundle() {
  local substrate_cache_dir=""
  local pulled_bundle=""
  local pulled_bundle_sha=""
  local expected_bundle_sha=""
  local actual_bundle_sha=""
  local extracted_dir="${TMP_ROOT}/selected-substrate-bundle"
  local manifest_dump=""
  local -a manifest_fields=()

  cache_pull_oci_artifact "${SELECTED_SUBSTRATE_REF}" "${CACHE_REUSE_ENABLED}" substrate_cache_dir
  SELECTED_SUBSTRATE_DIGEST="${OURBOX_CACHE_LAST_DIGEST}"
  SELECTED_SUBSTRATE_PINNED_REF="${OURBOX_CACHE_LAST_PINNED_REF}"
  log_resolved_artifact_ref "application bundle" "${SELECTED_SUBSTRATE_REF}" "${SELECTED_SUBSTRATE_PINNED_REF}"

  pulled_bundle="$(find_pulled_file "${substrate_cache_dir}" "ourbox-substrate.tar.gz")"
  [[ -f "${pulled_bundle}" ]] || die "cached application bundle missing ourbox-substrate.tar.gz: ${substrate_cache_dir}"
  pulled_bundle_sha="${pulled_bundle}.sha256"
  if [[ -f "${pulled_bundle_sha}" ]]; then
    expected_bundle_sha="$(awk 'NF>=1 {print $1; exit}' "${pulled_bundle_sha}")"
    expected_bundle_sha="${expected_bundle_sha,,}"
    [[ "${expected_bundle_sha}" =~ ^[0-9a-f]{64}$ ]] || die "invalid sha256 in ${pulled_bundle_sha}"
    actual_bundle_sha="$(sha256_file "${pulled_bundle}")"
    [[ "${actual_bundle_sha}" == "${expected_bundle_sha}" ]] || die "application bundle sha mismatch for ${SELECTED_SUBSTRATE_PINNED_REF}"
  fi

  rm -rf "${extracted_dir}"
  mkdir -p "${extracted_dir}"
  tar -xzf "${pulled_bundle}" -C "${extracted_dir}"
  [[ -f "${extracted_dir}/manifest.env" ]] || die "application bundle tarball missing manifest.env: ${SELECTED_SUBSTRATE_PINNED_REF}"
  [[ -x "${extracted_dir}/k3s/k3s" ]] || die "application bundle tarball missing k3s/k3s: ${SELECTED_SUBSTRATE_PINNED_REF}"
  [[ -f "${extracted_dir}/k3s/k3s-images-${EXPECTED_SUBSTRATE_ARCH}.tar" ]] \
    || die "application bundle tarball missing k3s/k3s-images-${EXPECTED_SUBSTRATE_ARCH}.tar: ${SELECTED_SUBSTRATE_PINNED_REF}"
  [[ -f "${extracted_dir}/platform/images.lock.json" ]] || die "application bundle tarball missing platform/images.lock.json: ${SELECTED_SUBSTRATE_PINNED_REF}"
  [[ -f "${extracted_dir}/platform/profile.env" ]] || die "application bundle tarball missing platform/profile.env: ${SELECTED_SUBSTRATE_PINNED_REF}"
  find "${extracted_dir}/platform/images" -maxdepth 1 -type f -name '*.tar' | grep -q . \
    || die "application bundle tarball missing platform image tar payloads: ${SELECTED_SUBSTRATE_PINNED_REF}"

  manifest_dump="$(
    python3 "${VENDORED_METADATA_PARSER}" "${extracted_dir}/manifest.env" \
      --allow OURBOX_SUBSTRATE_SOURCE \
      --allow OURBOX_SUBSTRATE_REVISION \
      --allow OURBOX_SUBSTRATE_VERSION \
      --allow OURBOX_SUBSTRATE_CREATED \
      --allow OURBOX_SUBSTRATE_ARCH \
      --allow K3S_VERSION \
      --allow OURBOX_PLATFORM_PROFILE \
      --allow OURBOX_PLATFORM_IMAGES_LOCK_PATH \
      --allow OURBOX_PLATFORM_IMAGES_LOCK_SHA256 \
      --require OURBOX_SUBSTRATE_SOURCE \
      --require OURBOX_SUBSTRATE_REVISION \
      --require OURBOX_SUBSTRATE_VERSION \
      --require OURBOX_SUBSTRATE_CREATED \
      --require OURBOX_SUBSTRATE_ARCH \
      --require K3S_VERSION \
      --require OURBOX_PLATFORM_PROFILE \
      --require OURBOX_PLATFORM_IMAGES_LOCK_PATH \
      --require OURBOX_PLATFORM_IMAGES_LOCK_SHA256 \
      --print OURBOX_SUBSTRATE_SOURCE \
      --print OURBOX_SUBSTRATE_REVISION \
      --print OURBOX_SUBSTRATE_VERSION \
      --print OURBOX_SUBSTRATE_CREATED \
      --print OURBOX_SUBSTRATE_ARCH \
      --print K3S_VERSION \
      --print OURBOX_PLATFORM_PROFILE \
      --print OURBOX_PLATFORM_IMAGES_LOCK_SHA256
  )"
  mapfile -t manifest_fields <<<"${manifest_dump}"
  [[ "${#manifest_fields[@]}" -eq 8 ]] || die "failed to parse application bundle manifest metadata: ${SELECTED_SUBSTRATE_PINNED_REF}"

  [[ "${manifest_fields[4]}" == "${EXPECTED_SUBSTRATE_ARCH}" ]] \
    || die "application bundle arch mismatch for ${SELECTED_SUBSTRATE_PINNED_REF}: expected ${EXPECTED_SUBSTRATE_ARCH}, got ${manifest_fields[4]}"

  cp -f "${pulled_bundle}" "${SUBSTRATE_STAGE_DIR}/ourbox-substrate.tar.gz"
  printf '%s  %s\n' "$(sha256_file "${SUBSTRATE_STAGE_DIR}/ourbox-substrate.tar.gz")" "ourbox-substrate.tar.gz" \
    > "${SUBSTRATE_STAGE_DIR}/ourbox-substrate.tar.gz.sha256"
  cp -f "${extracted_dir}/manifest.env" "${SUBSTRATE_STAGE_DIR}/manifest.env"
  printf '%s\n' "${SELECTED_SUBSTRATE_PINNED_REF}" > "${SUBSTRATE_STAGE_DIR}/artifact.ref"

  SELECTED_SUBSTRATE_SOURCE="${manifest_fields[0]}"
  SELECTED_SUBSTRATE_REVISION="${manifest_fields[1]}"
  SELECTED_SUBSTRATE_VERSION="${manifest_fields[2]}"
  SELECTED_SUBSTRATE_CREATED="${manifest_fields[3]}"
  SELECTED_SUBSTRATE_ARCH="${manifest_fields[4]}"
  SELECTED_SUBSTRATE_K3S_VERSION="${manifest_fields[5]}"
  SELECTED_SUBSTRATE_PROFILE="${manifest_fields[6]}"
  SELECTED_SUBSTRATE_IMAGES_LOCK_SHA256="${manifest_fields[7]}"
}

synthesize_selected_application_bundle() {
  local extracted_payload_root="${TMP_ROOT}/os-payload-extract"
  local base_substrate_dir="${extracted_payload_root}/substrate"
  local synthetic_root="${TMP_ROOT}/selected-application-bundle"
  local synthetic_images_dir="${synthetic_root}/platform/images"
  local image_dump=""
  local image_name=""
  local image_ref=""
  local target_tar=""
  local synthetic_sha=""
  local platform_images_lock_sha=""
  local bundle_ref=""
  local bundle_version=""

  rm -rf "${extracted_payload_root}" "${synthetic_root}"
  mkdir -p "${extracted_payload_root}" "${synthetic_images_dir}"

  if ! tar -xzf "${OS_PAYLOAD}" -C "${extracted_payload_root}" substrate 2>/dev/null; then
    tar -xzf "${OS_PAYLOAD}" -C "${extracted_payload_root}" ./substrate \
      || die "selected OS payload did not contain a baked substrate directory"
  fi
  [[ -d "${base_substrate_dir}" ]] || die "selected OS payload did not contain a baked substrate directory"
  [[ -f "${base_substrate_dir}/manifest.env" ]] || die "selected OS payload baked substrate bundle is missing manifest.env"
  [[ -f "${base_substrate_dir}/platform/images.lock.json" ]] || die "selected OS payload baked substrate bundle is missing platform/images.lock.json"
  [[ -d "${base_substrate_dir}/platform/images" ]] || die "selected OS payload baked substrate bundle is missing platform/images"

  cp -a "${base_substrate_dir}/." "${synthetic_root}/"
  mkdir -p "${synthetic_images_dir}"

  cp -f "${MERGED_APPLICATION_CATALOG_FILE}" "${synthetic_root}/platform/catalog.json"
  cp -f "${MERGED_SELECTED_APPLICATIONS_FILE}" "${synthetic_root}/platform/selected-apps.json"

  image_dump="$(
    python3 - <<'PY' "${MERGED_IMAGES_LOCK_FILE}"
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    images_lock = json.load(handle)

images = images_lock.get("images")
if not isinstance(images, list) or not images:
    raise SystemExit("merged images lock must declare a non-empty images list")

for image in images:
    name = str(image.get("name", "")).strip()
    ref = str(image.get("ref", "")).strip()
    if not name or not ref:
        raise SystemExit("merged images lock contains an invalid image entry")
    print(f"{name}\t{ref}")
PY
  )" || die "failed to parse merged images lock: ${MERGED_IMAGES_LOCK_FILE}"

  while IFS=$'\t' read -r image_name image_ref; do
    [[ -n "${image_name}" && -n "${image_ref}" ]] || continue
    target_tar="${synthetic_images_dir}/$(image_tar_name "${image_ref}")"
    if [[ -f "${target_tar}" ]]; then
      continue
    fi

    log "Pull + save selected application image ${image_ref}"
    pull_and_save_image_tar "${image_ref}" "${target_tar}"
  done <<<"${image_dump}"

  platform_images_lock_sha="$(sha256_file "${synthetic_root}/platform/images.lock.json")"
  bundle_version="host-selected-${APPLICATION_CATALOG_ID}"

  cat > "${synthetic_root}/manifest.env" <<EOF_MANIFEST
OURBOX_SUBSTRATE_SOURCE=https://github.com/techofourown/sw-ourbox-installer
OURBOX_SUBSTRATE_REVISION=${COMPOSER_REVISION}
OURBOX_SUBSTRATE_VERSION=${bundle_version}
OURBOX_SUBSTRATE_CREATED=${COMPOSED_AT}
OURBOX_SUBSTRATE_ARCH=${EXPECTED_SUBSTRATE_ARCH}
K3S_VERSION=${BAKED_SUBSTRATE_K3S_VERSION}
OURBOX_PLATFORM_PROFILE=${BAKED_SUBSTRATE_PROFILE}
OURBOX_PLATFORM_IMAGES_LOCK_PATH=platform/images.lock.json
OURBOX_PLATFORM_IMAGES_LOCK_SHA256=${platform_images_lock_sha}
EOF_MANIFEST

  tar -C "${synthetic_root}" -czf "${SUBSTRATE_STAGE_DIR}/ourbox-substrate.tar.gz" k3s platform manifest.env
  synthetic_sha="$(sha256_file "${SUBSTRATE_STAGE_DIR}/ourbox-substrate.tar.gz")"
  # Keep the artifact ref digest-pinned so the mission manifest and downstream
  # validator can treat host-composed bundles like the rest of the stack.
  bundle_ref="host-composed.local/application-catalog/${APPLICATION_CATALOG_ID}@sha256:${synthetic_sha}"
  printf '%s  %s\n' "${synthetic_sha}" "ourbox-substrate.tar.gz" > "${SUBSTRATE_STAGE_DIR}/ourbox-substrate.tar.gz.sha256"
  cp -f "${synthetic_root}/manifest.env" "${SUBSTRATE_STAGE_DIR}/manifest.env"
  printf '%s\n' "${bundle_ref}" > "${SUBSTRATE_STAGE_DIR}/artifact.ref"

  SELECTED_SUBSTRATE_PINNED_REF="${bundle_ref}"
  SELECTED_SUBSTRATE_DIGEST="sha256:${synthetic_sha}"
  SELECTED_SUBSTRATE_SELECTION_MODE="host-selected"
  SELECTED_SUBSTRATE_SELECTION_SOURCE="application-catalogs"
  SELECTED_SUBSTRATE_RELEASE_CHANNEL=""
  SELECTED_SUBSTRATE_SOURCE="https://github.com/techofourown/sw-ourbox-installer"
  SELECTED_SUBSTRATE_REVISION="${COMPOSER_REVISION}"
  SELECTED_SUBSTRATE_VERSION="${bundle_version}"
  SELECTED_SUBSTRATE_CREATED="${COMPOSED_AT}"
  SELECTED_SUBSTRATE_ARCH="${EXPECTED_SUBSTRATE_ARCH}"
  SELECTED_SUBSTRATE_K3S_VERSION="${BAKED_SUBSTRATE_K3S_VERSION}"
  SELECTED_SUBSTRATE_PROFILE="${BAKED_SUBSTRATE_PROFILE}"
  SELECTED_SUBSTRATE_IMAGES_LOCK_PATH="platform/images.lock.json"
  SELECTED_SUBSTRATE_IMAGES_LOCK_SHA256="${platform_images_lock_sha}"
}

initial_cache_refs=()
if [[ -n "${OS_REF}" ]]; then
  initial_cache_refs+=("${OS_REF}")
else
  initial_cache_refs+=("${OS_REPO}:${OS_CATALOG_TAG}" "${OS_REPO}:$(os_channel_tag_for "${OS_CHANNEL}")")
fi
maybe_confirm_cache_reuse "the requested selection inputs" "${initial_cache_refs[@]}"

SELECTED_OS_REF=""
determine_os_ref
maybe_confirm_cache_reuse "the selected OS artifact" "${SELECTED_OS_REF}"
cache_pull_oci_artifact "${SELECTED_OS_REF}" "${CACHE_REUSE_ENABLED}" OS_CACHE_DIR
SELECTED_OS_DIGEST="${OURBOX_CACHE_LAST_DIGEST}"
SELECTED_OS_PINNED_REF="${OURBOX_CACHE_LAST_PINNED_REF}"
log_resolved_artifact_ref "OS artifact" "${SELECTED_OS_REF}" "${SELECTED_OS_PINNED_REF}"

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
    --allow OURBOX_SUBSTRATE_REF \
    --allow OURBOX_SUBSTRATE_DIGEST \
    --allow OURBOX_SUBSTRATE_SOURCE \
    --allow OURBOX_SUBSTRATE_REVISION \
    --allow OURBOX_SUBSTRATE_VERSION \
    --allow OURBOX_SUBSTRATE_CREATED \
    --allow OURBOX_SUBSTRATE_ARCH \
    --allow OURBOX_SUBSTRATE_PROFILE \
    --allow OURBOX_SUBSTRATE_K3S_VERSION \
    --allow OURBOX_SUBSTRATE_IMAGES_LOCK_SHA256 \
    --allow OURBOX_BASE_ISO_URL \
    --allow OURBOX_BASE_ISO_SHA256 \
    --allow K3S_VERSION \
    --allow GITHUB_RUN_ID \
    --allow GITHUB_RUN_ATTEMPT \
    --require OS_ARTIFACT_TYPE \
    --print OS_ARTIFACT_TYPE \
    --print OURBOX_SUBSTRATE_REF \
    --print OURBOX_SUBSTRATE_DIGEST \
    --print OURBOX_SUBSTRATE_SOURCE \
    --print OURBOX_SUBSTRATE_REVISION \
    --print OURBOX_SUBSTRATE_VERSION \
    --print OURBOX_SUBSTRATE_CREATED \
    --print OURBOX_SUBSTRATE_ARCH \
    --print OURBOX_SUBSTRATE_PROFILE \
    --print OURBOX_SUBSTRATE_K3S_VERSION \
    --print OURBOX_SUBSTRATE_IMAGES_LOCK_SHA256 \
    --print OURBOX_VERSION \
    --print OURBOX_VARIANT \
    --print OURBOX_TARGET \
    --print OURBOX_SKU
)"
mapfile -t os_meta_fields <<<"${os_meta_dump}"
[[ "${#os_meta_fields[@]}" -eq 15 ]] || die "failed to parse ${OS_META_ENV}"

OS_ARTIFACT_TYPE="${os_meta_fields[0]}"
BAKED_SUBSTRATE_REF="${os_meta_fields[1]}"
BAKED_SUBSTRATE_DIGEST="${os_meta_fields[2]}"
BAKED_SUBSTRATE_SOURCE="${os_meta_fields[3]}"
BAKED_SUBSTRATE_REVISION="${os_meta_fields[4]}"
BAKED_SUBSTRATE_VERSION="${os_meta_fields[5]}"
BAKED_SUBSTRATE_CREATED="${os_meta_fields[6]}"
BAKED_SUBSTRATE_ARCH="${os_meta_fields[7]}"
BAKED_SUBSTRATE_PROFILE="${os_meta_fields[8]}"
BAKED_SUBSTRATE_K3S_VERSION="${os_meta_fields[9]}"
BAKED_SUBSTRATE_IMAGES_LOCK_SHA256="${os_meta_fields[10]}"
OURBOX_VERSION="${os_meta_fields[11]}"
OURBOX_VARIANT="${os_meta_fields[12]}"
OURBOX_TARGET="${os_meta_fields[13]}"
OURBOX_SKU="${os_meta_fields[14]}"

[[ "${OS_ARTIFACT_TYPE}" == "${EXPECTED_OS_ARTIFACT_TYPE}" ]] || die "unexpected OS artifact type in ${OS_META_ENV}: ${OS_ARTIFACT_TYPE}"

APPLICATION_SOURCE_RESOLUTIONS_JSON="$(parse_application_source_resolutions_spec "${APP_SOURCE_RESOLUTIONS_SPEC}")"
SELECTED_INSTALLER_SUBSTRATE_RELEASE_CHANNEL="$(selected_installer_release_channel)"
SELECTED_INSTALLER_SUBSTRATE_REF="${INSTALLER_REPO}:$(installer_channel_tag_for "${SELECTED_INSTALLER_SUBSTRATE_RELEASE_CHANNEL}")"

if [[ "${TARGET_SUPPORTS_APPLICATION_CATALOGS}" == "1" ]]; then
  determine_application_catalog_sources
  selected_catalog_cache_refs=()
  while IFS=$'\x1f' read -r _requested_catalog_id _requested_catalog_name requested_artifact_ref requested_catalog_ref _requested_release_channel; do
    if [[ -n "${requested_artifact_ref}" ]]; then
      selected_catalog_cache_refs+=("${requested_artifact_ref}")
    elif [[ -n "${requested_catalog_ref}" ]]; then
      selected_catalog_cache_refs+=("${requested_catalog_ref}")
    fi
  done < <(extract_selected_application_catalog_source_entries)
  maybe_confirm_cache_reuse "the selected mission artifacts" "${SELECTED_OS_REF}" "${selected_catalog_cache_refs[@]}" "${SELECTED_INSTALLER_SUBSTRATE_REF}"
  prepare_merged_application_catalog "catalog-defaults" "[]"
  determine_application_selection
  prepare_merged_application_catalog "${SELECTED_APPLICATION_SELECTION_MODE}" "${SELECTED_APPLICATION_IDS_JSON}"
  log_application_catalog_merge_summary
else
  determine_substrate_ref
  maybe_confirm_cache_reuse "the selected mission artifacts" "${SELECTED_OS_REF}" "${SELECTED_SUBSTRATE_REF}" "${SELECTED_INSTALLER_SUBSTRATE_REF}"
fi

determine_installed_target_ssh_key

cache_pull_oci_artifact "${SELECTED_INSTALLER_SUBSTRATE_REF}" "${CACHE_REUSE_ENABLED}" INSTALLER_SUBSTRATE_CACHE_DIR
SELECTED_INSTALLER_SUBSTRATE_DIGEST="${OURBOX_CACHE_LAST_DIGEST}"
SELECTED_INSTALLER_SUBSTRATE_PINNED_REF="${OURBOX_CACHE_LAST_PINNED_REF}"
log_resolved_artifact_ref "installer substrate" "${SELECTED_INSTALLER_SUBSTRATE_REF}" "${SELECTED_INSTALLER_SUBSTRATE_PINNED_REF}"
verify_installer_substrate_cache_dir "${INSTALLER_SUBSTRATE_CACHE_DIR}" "${INSTALLER_SUBSTRATE_FILENAME}"
INSTALLER_SUBSTRATE_PATH="$(find_pulled_file "${INSTALLER_SUBSTRATE_CACHE_DIR}" "${INSTALLER_SUBSTRATE_FILENAME}")"
[[ -f "${INSTALLER_SUBSTRATE_PATH}" ]] || die "cached installer substrate missing ${INSTALLER_SUBSTRATE_FILENAME}: ${INSTALLER_SUBSTRATE_CACHE_DIR}"

COMPOSER_REVISION="$(git -C "${ROOT}" rev-parse HEAD 2>/dev/null || echo unknown)"
if [[ -n "$(git -C "${ROOT}" status --short 2>/dev/null || true)" ]]; then
  COMPOSER_REVISION="${COMPOSER_REVISION}-dirty"
fi

COMPOSED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
COMPOSE_ID="${TARGET}-${OURBOX_VERSION}-${COMPOSED_AT//[:]/}"

STAGING_OUTPUT_DIR="${TMP_ROOT}/prepared-output"
MISSION_DIR="${STAGING_OUTPUT_DIR}/mission"
OS_STAGE_DIR="${MISSION_DIR}/artifacts/os"
SUBSTRATE_STAGE_DIR="${MISSION_DIR}/artifacts/substrate"
mkdir -p "${OS_STAGE_DIR}" "${SUBSTRATE_STAGE_DIR}"

cp -f "${OS_PAYLOAD}" "${OS_STAGE_DIR}/os-payload.tar.gz"
cp -f "${OS_PAYLOAD_SHA_FILE}" "${OS_STAGE_DIR}/os-payload.tar.gz.sha256"
cp -f "${OS_META_ENV}" "${OS_STAGE_DIR}/os.meta.env"
printf '%s\n' "${SELECTED_OS_PINNED_REF}" > "${OS_STAGE_DIR}/artifact.ref"

if [[ "${TARGET_SUPPORTS_APPLICATION_CATALOGS}" == "1" ]]; then
  synthesize_selected_application_bundle
  if [[ "${APPLICATION_CATALOG_PRESENT}" == "1" ]]; then
    cp -f "${MERGED_APPLICATION_CATALOG_FILE}" "${SUBSTRATE_STAGE_DIR}/catalog.json"
    cp -f "${MERGED_SELECTED_APPLICATIONS_FILE}" "${SUBSTRATE_STAGE_DIR}/selected-apps.json"
    cp -f "${MERGED_IMAGES_LOCK_FILE}" "${SUBSTRATE_STAGE_DIR}/application-images.lock.json"
  fi
else
  stage_selected_substrate_bundle
fi
stage_selected_installed_target_ssh_artifacts "${MISSION_DIR}"
validate_staged_installed_target_ssh_artifacts "${MISSION_DIR}"
if [[ "${SELECTED_INSTALLED_TARGET_SSH_MODE}" == "host-generated-authorized-key" ]]; then
  log "Installed-target SSH mission artifact: ${MISSION_DIR}/artifacts/installed-target-ssh/authorized-key.pub"
fi

export MISSION_DIR COMPOSE_ID COMPOSED_AT TARGET COMPOSER_REVISION ADAPTER_SOURCE_REPO ADAPTER_SOURCE_REVISION
export VENDORED_ADAPTER_ROOT ADAPTER_RUNTIME_PROMPTS_JSON MINIMUM_MEDIA_SIZE_BYTES OUTPUT_KIND
export SELECTED_INSTALLER_SUBSTRATE_REF SELECTED_OS_REF SELECTED_SUBSTRATE_REF
export SELECTED_INSTALLER_SUBSTRATE_PINNED_REF SELECTED_INSTALLER_SUBSTRATE_DIGEST SELECTED_INSTALLER_SUBSTRATE_RELEASE_CHANNEL
export SELECTED_OS_PINNED_REF SELECTED_OS_DIGEST EXPECTED_OS_ARTIFACT_TYPE SELECTED_OS_SELECTION_SOURCE SELECTED_OS_RELEASE_CHANNEL
export SELECTED_SUBSTRATE_PINNED_REF SELECTED_SUBSTRATE_DIGEST SELECTED_SUBSTRATE_SELECTION_MODE SELECTED_SUBSTRATE_SELECTION_SOURCE SELECTED_SUBSTRATE_RELEASE_CHANNEL
export SELECTED_SUBSTRATE_SOURCE SELECTED_SUBSTRATE_REVISION SELECTED_SUBSTRATE_VERSION SELECTED_SUBSTRATE_CREATED
export SELECTED_SUBSTRATE_ARCH SELECTED_SUBSTRATE_PROFILE SELECTED_SUBSTRATE_K3S_VERSION
export SELECTED_SUBSTRATE_IMAGES_LOCK_SHA256 MISSION_ONLY BAKED_SUBSTRATE_DIGEST
export APPLICATION_CATALOG_PRESENT APPLICATION_CATALOG_ID APPLICATION_CATALOG_NAME APPLICATION_CATALOG_DESCRIPTION
export SELECTED_APPLICATION_SELECTION_MODE SELECTED_APPLICATION_IDS_JSON MERGED_APPLICATION_SUMMARY_FILE
export SELECTED_INSTALLED_TARGET_SSH_MODE SELECTED_INSTALLED_TARGET_SSH_KEY_NAME
export SELECTED_INSTALLED_TARGET_SSH_PUBLIC_KEY_FINGERPRINT SELECTED_INSTALLED_TARGET_SSH_KEY_TYPE
export ADAPTER_JSON_RELPATH="vendor/${TARGET}/adapter.json"
case "${TARGET}" in
  woodbox)
    export MISSION_COMPOSE_STRATEGY="woodbox-fat-iso-with-host-selected-os-application-catalog-and-app-selection"
    ;;
  matchbox)
    export MISSION_COMPOSE_STRATEGY="matchbox-fat-image-with-host-selected-os-and-substrate"
    ;;
  *)
    die "unsupported target during mission-manifest generation: ${TARGET}"
    ;;
esac

python3 - <<'PY'
import hashlib
import json
import os
from pathlib import Path

mission_dir = Path(os.environ["MISSION_DIR"])
os_payload = mission_dir / "artifacts" / "os" / "os-payload.tar.gz"
os_meta = mission_dir / "artifacts" / "os" / "os.meta.env"
substrate_payload = mission_dir / "artifacts" / "substrate" / "ourbox-substrate.tar.gz"
substrate_manifest = mission_dir / "artifacts" / "substrate" / "manifest.env"
application_catalog = mission_dir / "artifacts" / "substrate" / "catalog.json"
selected_apps = mission_dir / "artifacts" / "substrate" / "selected-apps.json"
application_images_lock = mission_dir / "artifacts" / "substrate" / "application-images.lock.json"
installed_target_ssh_key = mission_dir / "artifacts" / "installed-target-ssh" / "authorized-key.pub"

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
requested_os_ref = ""
if os.environ["SELECTED_OS_SELECTION_SOURCE"] != "catalog":
    requested_os_ref = os.environ.get("SELECTED_OS_REF", "")

requested_substrate_ref = ""
if os.environ["SELECTED_SUBSTRATE_SELECTION_SOURCE"] not in {"catalog", "application-catalogs"}:
    requested_substrate_ref = os.environ.get("SELECTED_SUBSTRATE_REF", "")

requested_source_catalogs = []
resolved_source_catalogs = []
summary_path = os.environ.get("MERGED_APPLICATION_SUMMARY_FILE", "")
if os.environ.get("APPLICATION_CATALOG_PRESENT") == "1" and summary_path:
    with open(summary_path, "r", encoding="utf-8") as handle:
        summary = json.load(handle)
    raw_sources = summary.get("source_catalogs") or []
    if isinstance(raw_sources, list):
        resolved_source_catalogs = raw_sources
        for raw_source in raw_sources:
            if not isinstance(raw_source, dict):
                continue
            requested_source_catalogs.append(
                {
                    "catalog_id": str(raw_source.get("catalog_id", "")),
                    "catalog_name": str(raw_source.get("catalog_name", "")),
                }
            )

manifest = {
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
        "adapter_json_relpath": os.environ["ADAPTER_JSON_RELPATH"],
        "runtime_prompts_kept": runtime_prompts,
    },
    "operator_mode": {
        "mode": "install",
        "prompt_hostname_on_target": True,
        "prompt_identity_on_target": True,
    },
    "mission_media": {
      "compose_strategy": os.environ["MISSION_COMPOSE_STRATEGY"],
      "mission_only": os.environ["MISSION_ONLY"] == "1",
    },
    "requested": {
        "substrate": {
            "strategy": "published-installer-substrate",
            "release_channel": os.environ["SELECTED_INSTALLER_SUBSTRATE_RELEASE_CHANNEL"],
            "requested_ref": os.environ["SELECTED_INSTALLER_SUBSTRATE_REF"],
        },
        "os": {
            "selection_source": os.environ["SELECTED_OS_SELECTION_SOURCE"],
            "release_channel": os.environ["SELECTED_OS_RELEASE_CHANNEL"],
            "requested_ref": requested_os_ref,
        },
        "selected_substrate": {
            "selection_mode": os.environ["SELECTED_SUBSTRATE_SELECTION_MODE"],
            "selection_source": os.environ["SELECTED_SUBSTRATE_SELECTION_SOURCE"],
            "release_channel": os.environ["SELECTED_SUBSTRATE_RELEASE_CHANNEL"],
            "requested_ref": requested_substrate_ref,
        },
    },
    "resolved": {
        "substrate": {
            "strategy": "published-installer-substrate",
            "artifact_ref": os.environ["SELECTED_INSTALLER_SUBSTRATE_PINNED_REF"],
            "artifact_digest": os.environ["SELECTED_INSTALLER_SUBSTRATE_DIGEST"],
            "release_channel": os.environ["SELECTED_INSTALLER_SUBSTRATE_RELEASE_CHANNEL"],
            "compose_entrypoint": "tools/media-adapter/compose-media.sh",
        },
        "os": {
            "selection_source": os.environ["SELECTED_OS_SELECTION_SOURCE"],
            "release_channel": os.environ["SELECTED_OS_RELEASE_CHANNEL"],
            "artifact_ref": os.environ["SELECTED_OS_PINNED_REF"],
            "artifact_digest": os.environ["SELECTED_OS_DIGEST"],
            "artifact_type": os.environ["EXPECTED_OS_ARTIFACT_TYPE"],
            "payload": {
                "relpath": os_payload.relative_to(mission_dir).as_posix(),
                "sha256": sha256(os_payload),
                "size_bytes": os_payload.stat().st_size,
            },
            "metadata_relpath": os_meta.relative_to(mission_dir).as_posix(),
        },
        "selected_substrate": {
            "selection_mode": os.environ["SELECTED_SUBSTRATE_SELECTION_MODE"],
            "selection_source": os.environ["SELECTED_SUBSTRATE_SELECTION_SOURCE"],
            "release_channel": os.environ["SELECTED_SUBSTRATE_RELEASE_CHANNEL"],
            "artifact_ref": os.environ["SELECTED_SUBSTRATE_PINNED_REF"],
            "artifact_digest": os.environ["SELECTED_SUBSTRATE_DIGEST"],
            "arch": os.environ["SELECTED_SUBSTRATE_ARCH"],
            "profile": os.environ["SELECTED_SUBSTRATE_PROFILE"],
            "version": os.environ["SELECTED_SUBSTRATE_VERSION"],
            "created": os.environ["SELECTED_SUBSTRATE_CREATED"],
            "k3s_version": os.environ["SELECTED_SUBSTRATE_K3S_VERSION"],
            "images_lock_sha256": os.environ["SELECTED_SUBSTRATE_IMAGES_LOCK_SHA256"],
            "payload_relpath": substrate_payload.relative_to(mission_dir).as_posix(),
            "manifest_relpath": substrate_manifest.relative_to(mission_dir).as_posix(),
            "present_in_selected_os_payload": os.environ["SELECTED_SUBSTRATE_DIGEST"] == os.environ["BAKED_SUBSTRATE_DIGEST"],
        },
    },
    "staged_files": staged_files,
}

if os.environ.get("APPLICATION_CATALOG_PRESENT") == "1":
    manifest["requested"]["applications"] = {
        "catalog_id": os.environ["APPLICATION_CATALOG_ID"],
        "catalog_name": os.environ["APPLICATION_CATALOG_NAME"],
        "selection_mode": os.environ["SELECTED_APPLICATION_SELECTION_MODE"],
        "selected_app_ids": json.loads(os.environ["SELECTED_APPLICATION_IDS_JSON"]),
        "source_catalogs": requested_source_catalogs,
    }
    manifest["resolved"]["applications"] = {
        "catalog_id": os.environ["APPLICATION_CATALOG_ID"],
        "catalog_name": os.environ["APPLICATION_CATALOG_NAME"],
        "selection_mode": os.environ["SELECTED_APPLICATION_SELECTION_MODE"],
        "selected_app_ids": json.loads(os.environ["SELECTED_APPLICATION_IDS_JSON"]),
        "catalog_relpath": application_catalog.relative_to(mission_dir).as_posix(),
        "selection_relpath": selected_apps.relative_to(mission_dir).as_posix(),
        "images_lock_relpath": application_images_lock.relative_to(mission_dir).as_posix(),
        "source_catalogs": resolved_source_catalogs,
    }

if os.environ.get("SELECTED_INSTALLED_TARGET_SSH_MODE") == "host-generated-authorized-key":
    manifest["requested"]["installed_target_ssh"] = {
        "mode": os.environ["SELECTED_INSTALLED_TARGET_SSH_MODE"],
        "key_name": os.environ["SELECTED_INSTALLED_TARGET_SSH_KEY_NAME"],
    }
    manifest["resolved"]["installed_target_ssh"] = {
        "mode": os.environ["SELECTED_INSTALLED_TARGET_SSH_MODE"],
        "key_name": os.environ["SELECTED_INSTALLED_TARGET_SSH_KEY_NAME"],
        "authorized_key_relpath": installed_target_ssh_key.relative_to(mission_dir).as_posix(),
        "key_type": os.environ["SELECTED_INSTALLED_TARGET_SSH_KEY_TYPE"],
        "public_key_fingerprint": os.environ["SELECTED_INSTALLED_TARGET_SSH_PUBLIC_KEY_FINGERPRINT"],
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
if [[ "${TARGET_SUPPORTS_APPLICATION_CATALOGS}" == "1" ]]; then
  log "Selected application catalogs: ${SELECTED_APPLICATION_CATALOG_SOURCE_DISPLAY}"
  log "Synthesized application bundle: ${SELECTED_SUBSTRATE_PINNED_REF} (${SELECTED_SUBSTRATE_SELECTION_SOURCE})"
fi
if [[ "${APPLICATION_CATALOG_PRESENT}" == "1" ]]; then
  log "Selected applications: ${SELECTED_APPLICATION_IDS_DISPLAY} (${SELECTED_APPLICATION_SELECTION_MODE})"
fi
if [[ "${TARGET_SUPPORTS_APPLICATION_CATALOGS}" != "1" ]]; then
  log "Selected application bundle: ${SELECTED_SUBSTRATE_PINNED_REF} (${SELECTED_SUBSTRATE_SELECTION_SOURCE})"
fi
log_installed_target_ssh_selection_summary
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
  --output-dir "${COMPOSE_OUTPUT_DIR}"
)
case "${TARGET}" in
  woodbox)
    compose_cmd+=(--substrate-iso "${INSTALLER_SUBSTRATE_PATH}")
    ;;
  matchbox)
    compose_cmd+=(--substrate-artifact "${INSTALLER_SUBSTRATE_PATH}")
    ;;
  *)
    die "unsupported target during media compose: ${TARGET}"
    ;;
esac
if [[ -n "${FLASH_DEVICE}" ]]; then
  compose_cmd+=(--flash-device "${FLASH_DEVICE}")
fi

log "Invoking vendored ${TARGET} media adapter"
case "${TARGET}" in
  woodbox)
    WOODBOX_ADAPTER_ROOT="${VENDORED_ADAPTER_ROOT}" \
    OURBOX_MEDIA_COMPOSE_WORK_ROOT="${WORK_ROOT}" \
      "${compose_cmd[@]}"
    ;;
  matchbox)
    MATCHBOX_ADAPTER_ROOT="${VENDORED_ADAPTER_ROOT}" \
    OURBOX_MEDIA_COMPOSE_WORK_ROOT="${WORK_ROOT}" \
      "${compose_cmd[@]}"
    ;;
esac

if [[ "${COMPOSE_ONLY}" == "1" || -n "${OUTPUT_DIR}" ]]; then
  log "Mission media output directory: ${COMPOSE_OUTPUT_DIR}"
else
  log "Mission media flashed from managed scratch workspace; no persistent ISO was kept"
fi

offer_cache_cleanup
