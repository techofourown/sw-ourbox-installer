#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${WOODBOX_ADAPTER_ROOT:=${SCRIPT_DIR}}"
: "${WOODBOX_REPO_ROOT:=$(cd "${SCRIPT_DIR}/../.." && pwd)}"
ROOT="${WOODBOX_REPO_ROOT}"
# shellcheck disable=SC1091
source "${ROOT}/tools/lib.sh"

ADAPTER_JSON="${WOODBOX_ADAPTER_ROOT}/adapter.json"
STRICT_METADATA_PARSER="${WOODBOX_ADAPTER_ROOT}/strict-kv-metadata.py"
if [[ ! -f "${STRICT_METADATA_PARSER}" ]]; then
  STRICT_METADATA_PARSER="${ROOT}/tools/strict-kv-metadata.py"
fi
MISSION_DIR=""
OS_PAYLOAD=""
OS_META_ENV=""

usage() {
  cat <<EOF
Usage: $0 --mission-dir DIR --os-payload PATH --os-meta-env PATH

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
    --os-meta-env)
      [[ $# -ge 2 ]] || die "--os-meta-env requires a value"
      OS_META_ENV="$2"
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
[[ -n "${OS_META_ENV}" ]] || die "--os-meta-env is required"
[[ -d "${MISSION_DIR}" ]] || die "mission dir not found: ${MISSION_DIR}"
[[ -f "${MISSION_DIR}/mission-manifest.json" ]] || die "mission-manifest.json missing from ${MISSION_DIR}"
[[ -f "${OS_PAYLOAD}" ]] || die "os payload not found: ${OS_PAYLOAD}"
[[ -f "${OS_META_ENV}" ]] || die "os metadata not found: ${OS_META_ENV}"
[[ -f "${STRICT_METADATA_PARSER}" ]] || die "strict metadata parser not found: ${STRICT_METADATA_PARSER}"

python3 - <<'PY' "${ADAPTER_JSON}" "${MISSION_DIR}/mission-manifest.json" "${OS_PAYLOAD}" "${OS_META_ENV}"
import json
import pathlib
import re
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    adapter = json.load(handle)
with open(sys.argv[2], "r", encoding="utf-8") as handle:
    manifest = json.load(handle)

mission_dir = pathlib.Path(sys.argv[2]).parent
expected_payload = pathlib.Path(sys.argv[3]).resolve()
expected_meta = pathlib.Path(sys.argv[4]).resolve()

expected_type = adapter["expected_os_artifact_type"]
expected_arch = adapter["expected_airgap_arch"]
sha256_re = re.compile(r"^sha256:[0-9a-f]{64}$")
pinned_ref_re = re.compile(r"^[^\s]+@sha256:[0-9a-f]{64}$")

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
os_selection_source = str(selected_os.get("selection_source", ""))
if not os_selection_source:
    raise SystemExit("mission selected_os.selection_source must be set")
os_artifact_ref = str(selected_os.get("artifact_ref", ""))
if not pinned_ref_re.fullmatch(os_artifact_ref):
    raise SystemExit("mission selected_os.artifact_ref must be a digest-pinned OCI ref")
os_artifact_digest = str(selected_os.get("artifact_digest", ""))
if not sha256_re.fullmatch(os_artifact_digest):
    raise SystemExit("mission selected_os.artifact_digest must be a sha256 digest")
contract = str(selected_os.get("platform_contract_digest", ""))
if not sha256_re.fullmatch(contract):
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
if (mission_dir / os_payload_relpath).resolve() != expected_payload:
    raise SystemExit("mission selected_os.payload.relpath must match the explicit --os-payload input")
if (mission_dir / os_meta_relpath).resolve() != expected_meta:
    raise SystemExit("mission selected_os.metadata_relpath must match the explicit --os-meta-env input")
selected_airgap = manifest.get("selected_airgap")
if not isinstance(selected_airgap, dict) or not selected_airgap:
    raise SystemExit("mission selected_airgap must be present")
airgap_selection_mode = str(selected_airgap.get("selection_mode", ""))
if not airgap_selection_mode:
    raise SystemExit("mission selected_airgap.selection_mode must be set")
airgap_selection_source = str(selected_airgap.get("selection_source", ""))
if not airgap_selection_source:
    raise SystemExit("mission selected_airgap.selection_source must be set")
airgap_artifact_ref = str(selected_airgap.get("artifact_ref", ""))
if not pinned_ref_re.fullmatch(airgap_artifact_ref):
    raise SystemExit("mission selected_airgap.artifact_ref must be a digest-pinned OCI ref")
airgap_artifact_digest = str(selected_airgap.get("artifact_digest", ""))
if not sha256_re.fullmatch(airgap_artifact_digest):
    raise SystemExit("mission selected_airgap.artifact_digest must be a sha256 digest")
if selected_airgap.get("arch") != expected_arch:
    raise SystemExit(f"mission selected_airgap.arch must be {expected_arch}")
airgap_contract = str(selected_airgap.get("platform_contract_digest", ""))
if not sha256_re.fullmatch(airgap_contract):
    raise SystemExit("mission selected_airgap.platform_contract_digest must be a sha256 digest")
if airgap_contract != contract:
    raise SystemExit("mission selected_airgap.platform_contract_digest must match selected_os.platform_contract_digest")
if not isinstance(selected_airgap.get("present_in_selected_os_payload"), bool):
    raise SystemExit("mission selected_airgap.present_in_selected_os_payload must be a boolean")
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

payload_check="$(
  python3 "${STRICT_METADATA_PARSER}" "${OS_META_ENV}" \
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
    --print OS_ARTIFACT_TYPE \
    --print OURBOX_PLATFORM_CONTRACT_DIGEST
)"
mapfile -t payload_fields <<<"${payload_check}"
[[ "${#payload_fields[@]}" -eq 2 ]] || die "failed to parse ${OS_META_ENV}"
[[ "${payload_fields[0]}" == "application/vnd.techofourown.ourbox.woodbox.os-payload.v1" ]] \
  || die "payload meta artifact type mismatch in ${OS_META_ENV}"
[[ "${payload_fields[1]}" =~ ^sha256:[0-9a-f]{64}$ ]] \
  || die "payload meta contract digest missing or invalid in ${OS_META_ENV}"

log "Woodbox media adapter validation passed"
