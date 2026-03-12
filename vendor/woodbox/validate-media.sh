#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${WOODBOX_ADAPTER_ROOT:=${SCRIPT_DIR}}"
: "${WOODBOX_REPO_ROOT:=$(cd "${SCRIPT_DIR}/../.." && pwd)}"
ROOT="${WOODBOX_REPO_ROOT}"
# shellcheck disable=SC1091
source "${ROOT}/tools/lib.sh"

ADAPTER_JSON="${WOODBOX_ADAPTER_ROOT}/adapter.json"
MISSION_DIR=""
OS_PAYLOAD=""

usage() {
  cat <<EOF
Usage: $0 --mission-dir DIR --os-payload PATH

Validates the phase-one Woodbox mission directory contract before compose.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mission-dir)
      [[ $# -ge 2 ]] || die "--mission-dir requires a value"
      MISSION_DIR="$2"
      shift 2
      ;;
    --os-payload)
      [[ $# -ge 2 ]] || die "--os-payload requires a value"
      OS_PAYLOAD="$2"
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

[[ -n "${MISSION_DIR}" ]] || die "--mission-dir is required"
[[ -n "${OS_PAYLOAD}" ]] || die "--os-payload is required"
[[ -d "${MISSION_DIR}" ]] || die "mission dir not found: ${MISSION_DIR}"
[[ -f "${MISSION_DIR}/mission-manifest.json" ]] || die "mission-manifest.json missing from ${MISSION_DIR}"
[[ -f "${OS_PAYLOAD}" ]] || die "os payload not found: ${OS_PAYLOAD}"

PAYLOAD_META="${OS_PAYLOAD%.tar.gz}.meta.env"

python3 - <<'PY' "${ADAPTER_JSON}" "${MISSION_DIR}/mission-manifest.json"
import json
import pathlib
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    adapter = json.load(handle)
with open(sys.argv[2], "r", encoding="utf-8") as handle:
    manifest = json.load(handle)

mission_dir = pathlib.Path(sys.argv[2]).parent

expected_type = adapter["expected_os_artifact_type"]
expected_arch = adapter["expected_airgap_arch"]

if manifest.get("schema") != 1:
    raise SystemExit("mission manifest schema must be 1")
if manifest.get("kind") != "ourbox-mission":
    raise SystemExit("mission manifest kind must be 'ourbox-mission'")
target = manifest.get("target", {})
if target.get("id") != "woodbox":
    raise SystemExit("mission target.id must be 'woodbox'")
if target.get("media_kind") != "installer-usb":
    raise SystemExit("mission target.media_kind must be 'installer-usb'")
operator_mode = manifest.get("operator_mode", {})
if operator_mode.get("mode") != "install":
    raise SystemExit("mission operator_mode.mode must be 'install'")
platform_contract = manifest.get("platform_contract", {})
platform_digest = str(platform_contract.get("digest", ""))
if not platform_digest.startswith("sha256:") or len(platform_digest) != 71:
    raise SystemExit("mission platform_contract.digest must be a sha256 digest")
selected_os = manifest.get("selected_os", {})
if selected_os.get("artifact_type") != expected_type:
    raise SystemExit(f"mission selected_os.artifact_type must be {expected_type}")
contract = str(selected_os.get("platform_contract_digest", ""))
if not contract.startswith("sha256:") or len(contract) != 71:
    raise SystemExit("mission selected_os.platform_contract_digest must be a sha256 digest")
if contract != platform_digest:
    raise SystemExit("mission selected_os.platform_contract_digest must match mission platform_contract.digest")
selected_os_payload = selected_os.get("payload", {})
os_payload_relpath = selected_os_payload.get("relpath")
os_meta_relpath = selected_os.get("metadata_relpath")
if not os_payload_relpath:
    raise SystemExit("mission selected_os.payload.relpath must be set")
if not os_meta_relpath:
    raise SystemExit("mission selected_os.metadata_relpath must be set")
if not (mission_dir / os_payload_relpath).is_file():
    raise SystemExit("mission selected_os.payload.relpath must point to a staged file")
if not (mission_dir / os_meta_relpath).is_file():
    raise SystemExit("mission selected_os.metadata_relpath must point to a staged file")
selected_airgap = manifest.get("selected_airgap", {})
if selected_airgap:
    if selected_airgap.get("arch") != expected_arch:
        raise SystemExit(f"mission selected_airgap.arch must be {expected_arch}")
    airgap_contract = selected_airgap.get("platform_contract_digest")
    if airgap_contract not in ("", None) and airgap_contract != contract:
        raise SystemExit("mission selected_airgap.platform_contract_digest must match selected_os.platform_contract_digest")
    payload_relpath = selected_airgap.get("payload_relpath")
    manifest_relpath = selected_airgap.get("manifest_relpath")
    if not payload_relpath:
        raise SystemExit("mission selected_airgap.payload_relpath must be set")
    if not manifest_relpath:
        raise SystemExit("mission selected_airgap.manifest_relpath must be set")
    if not (mission_dir / payload_relpath).is_file():
        raise SystemExit("mission selected_airgap.payload_relpath must point to a staged file")
    if not (mission_dir / manifest_relpath).is_file():
        raise SystemExit("mission selected_airgap.manifest_relpath must point to a staged file")
PY

if [[ -f "${PAYLOAD_META}" ]]; then
  payload_check="$(
    (
      unset OS_ARTIFACT_TYPE OURBOX_PLATFORM_CONTRACT_DIGEST
      # shellcheck disable=SC1090
      source "${PAYLOAD_META}"
      printf '%s\n%s\n' "${OS_ARTIFACT_TYPE-}" "${OURBOX_PLATFORM_CONTRACT_DIGEST-}"
    )
  )"
  mapfile -t payload_fields <<<"${payload_check}"
  [[ "${#payload_fields[@]}" -eq 2 ]] || die "failed to parse ${PAYLOAD_META}"
  [[ "${payload_fields[0]}" == "application/vnd.techofourown.ourbox.woodbox.os-payload.v1" ]] \
    || die "payload meta artifact type mismatch in ${PAYLOAD_META}"
  [[ "${payload_fields[1]}" =~ ^sha256:[0-9a-f]{64}$ ]] \
    || die "payload meta contract digest missing or invalid in ${PAYLOAD_META}"
fi

log "Woodbox media adapter validation passed"
