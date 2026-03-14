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

python3 - <<'PY' "${ADAPTER_JSON}" "${MISSION_DIR}/mission-manifest.json" "${OS_PAYLOAD}" "${OS_META_ENV}" "${STRICT_METADATA_PARSER}"
import hashlib
import json
import pathlib
import re
import subprocess
import sys
import tarfile

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    adapter = json.load(handle)
with open(sys.argv[2], "r", encoding="utf-8") as handle:
    manifest = json.load(handle)

mission_dir = pathlib.Path(sys.argv[2]).resolve().parent
expected_payload = pathlib.Path(sys.argv[3]).resolve()
expected_meta = pathlib.Path(sys.argv[4]).resolve()
strict_metadata_parser = pathlib.Path(sys.argv[5]).resolve()

expected_type = adapter["expected_os_artifact_type"]
expected_arch = adapter["expected_airgap_arch"]
sha256_re = re.compile(r"^sha256:[0-9a-f]{64}$")
pinned_ref_re = re.compile(r"^[^\s]+@sha256:[0-9a-f]{64}$")
plain_sha256_re = re.compile(r"^[0-9a-f]{64}$")
key_name_re = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
ssh_fingerprint_re = re.compile(r"^SHA256:[A-Za-z0-9+/=]+$")


def ensure_relpath_within_mission(label: str, relpath: str) -> pathlib.Path:
    candidate = (mission_dir / relpath).resolve()
    try:
        candidate.relative_to(mission_dir)
    except ValueError as exc:
        raise SystemExit(f"{label} must stay within the mission directory") from exc
    return candidate


def require_staged_file(label: str, relpath: str) -> pathlib.Path:
    candidate = ensure_relpath_within_mission(label, relpath)
    if not candidate.is_file():
        raise SystemExit(f"{label} must point to a staged file")
    return candidate


def require_ref_digest_match(label: str, artifact_ref: str, artifact_digest: str) -> None:
    ref_digest = artifact_ref.rsplit("@", 1)[1]
    if ref_digest != artifact_digest:
        raise SystemExit(f"{label}.artifact_ref digest must match {label}.artifact_digest")


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_sha256_sidecar(label: str, payload_relpath: str, payload_path: pathlib.Path) -> None:
    checksum_path = ensure_relpath_within_mission(f"{label}.sha256", f"{payload_relpath}.sha256")
    if not checksum_path.is_file():
        raise SystemExit(f"{label} requires a matching .sha256 sidecar")

    expected = ""
    with checksum_path.open("r", encoding="utf-8") as handle:
        for raw_line in handle:
            fields = raw_line.strip().split()
            if fields:
                expected = fields[0].lower()
                break

    if not plain_sha256_re.fullmatch(expected):
        raise SystemExit(f"{label}.sha256 must start with a 64-character sha256 hex digest")

    actual = sha256_file(payload_path)
    if actual != expected:
        raise SystemExit(f"{label}.sha256 does not match {label}")


def validate_authorized_key_file(label: str, path: pathlib.Path) -> None:
    lines = [line.strip() for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
    if len(lines) != 1:
        raise SystemExit(f"{label} must contain exactly one non-empty SSH public key line")
    if not lines[0].startswith("ssh-ed25519 "):
        raise SystemExit(f"{label} must contain an ssh-ed25519 public key")


def normalize_tar_member_name(name: str) -> str:
    member_path = pathlib.PurePosixPath(name)
    if member_path.is_absolute():
        raise SystemExit("mission selected_airgap.payload_relpath must not contain absolute paths")
    if ".." in member_path.parts:
        raise SystemExit("mission selected_airgap.payload_relpath must not escape the extracted bundle root")
    parts = [part for part in member_path.parts if part not in ("", ".")]
    return pathlib.PurePosixPath(*parts).as_posix() if parts else ""


def validate_airgap_bundle(payload_path: pathlib.Path, manifest_path: pathlib.Path, required_contract: str) -> None:
    try:
        with tarfile.open(payload_path, "r:gz") as archive:
            file_members: dict[str, tarfile.TarInfo] = {}
            has_platform_image_tar = False
            for member in archive.getmembers():
                normalized_name = normalize_tar_member_name(member.name)
                if member.issym() or member.islnk():
                    raise SystemExit("mission selected_airgap.payload_relpath must not contain symlinks or hard links")
                if not normalized_name or member.isdir():
                    continue
                file_members[normalized_name] = member
                if normalized_name.startswith("platform/images/") and normalized_name.endswith(".tar"):
                    has_platform_image_tar = True

            required_files = {
                "manifest.env": "mission selected_airgap.payload_relpath bundle missing manifest.env",
                "k3s/k3s": "mission selected_airgap.payload_relpath bundle missing k3s binary",
                f"k3s/k3s-airgap-images-{expected_arch}.tar": f"mission selected_airgap.payload_relpath bundle missing k3s airgap images tar for {expected_arch}",
                "platform/images.lock.json": "mission selected_airgap.payload_relpath bundle missing platform/images.lock.json",
                "platform/profile.env": "mission selected_airgap.payload_relpath bundle missing platform/profile.env",
            }
            for required_name, error_message in required_files.items():
                if required_name not in file_members:
                    raise SystemExit(error_message)
            if not has_platform_image_tar:
                raise SystemExit("mission selected_airgap.payload_relpath bundle missing platform image tar payloads")

            manifest_member = file_members["manifest.env"]
            extracted_manifest = archive.extractfile(manifest_member)
            if extracted_manifest is None:
                raise SystemExit("mission selected_airgap.payload_relpath bundle manifest.env is unreadable")
            if extracted_manifest.read() != manifest_path.read_bytes():
                raise SystemExit("mission selected_airgap.manifest_relpath must match the tarball manifest.env content")

            parse_result = subprocess.run(
                [
                    sys.executable,
                    str(strict_metadata_parser),
                    str(manifest_path),
                    "--allow",
                    "OURBOX_AIRGAP_PLATFORM_SCHEMA",
                    "--allow",
                    "OURBOX_AIRGAP_PLATFORM_KIND",
                    "--allow",
                    "OURBOX_AIRGAP_PLATFORM_SOURCE",
                    "--allow",
                    "OURBOX_AIRGAP_PLATFORM_REVISION",
                    "--allow",
                    "OURBOX_AIRGAP_PLATFORM_VERSION",
                    "--allow",
                    "OURBOX_AIRGAP_PLATFORM_CREATED",
                    "--allow",
                    "OURBOX_PLATFORM_CONTRACT_REF",
                    "--allow",
                    "OURBOX_PLATFORM_CONTRACT_DIGEST",
                    "--allow",
                    "AIRGAP_PLATFORM_ARCH",
                    "--allow",
                    "K3S_VERSION",
                    "--allow",
                    "OURBOX_PLATFORM_PROFILE",
                    "--allow",
                    "OURBOX_PLATFORM_IMAGES_LOCK_PATH",
                    "--allow",
                    "OURBOX_PLATFORM_IMAGES_LOCK_SHA256",
                    "--require",
                    "OURBOX_AIRGAP_PLATFORM_SOURCE",
                    "--require",
                    "OURBOX_AIRGAP_PLATFORM_REVISION",
                    "--require",
                    "OURBOX_AIRGAP_PLATFORM_VERSION",
                    "--require",
                    "OURBOX_AIRGAP_PLATFORM_CREATED",
                    "--require",
                    "OURBOX_PLATFORM_CONTRACT_DIGEST",
                    "--require",
                    "AIRGAP_PLATFORM_ARCH",
                    "--require",
                    "K3S_VERSION",
                    "--require",
                    "OURBOX_PLATFORM_PROFILE",
                    "--require",
                    "OURBOX_PLATFORM_IMAGES_LOCK_PATH",
                    "--require",
                    "OURBOX_PLATFORM_IMAGES_LOCK_SHA256",
                    "--print",
                    "OURBOX_AIRGAP_PLATFORM_SOURCE",
                    "--print",
                    "OURBOX_AIRGAP_PLATFORM_REVISION",
                    "--print",
                    "OURBOX_AIRGAP_PLATFORM_VERSION",
                    "--print",
                    "OURBOX_AIRGAP_PLATFORM_CREATED",
                    "--print",
                    "OURBOX_PLATFORM_CONTRACT_DIGEST",
                    "--print",
                    "AIRGAP_PLATFORM_ARCH",
                    "--print",
                    "K3S_VERSION",
                    "--print",
                    "OURBOX_PLATFORM_PROFILE",
                    "--print",
                    "OURBOX_PLATFORM_IMAGES_LOCK_PATH",
                    "--print",
                    "OURBOX_PLATFORM_IMAGES_LOCK_SHA256",
                ],
                capture_output=True,
                check=False,
                text=True,
            )
            if parse_result.returncode != 0:
                detail = (parse_result.stderr or parse_result.stdout).strip()
                raise SystemExit(f"failed to parse staged airgap-platform manifest: {detail}")

            manifest_fields = parse_result.stdout.splitlines()
            if len(manifest_fields) != 10:
                raise SystemExit("staged airgap-platform manifest parse produced an unexpected field set")
            if not sha256_re.fullmatch(manifest_fields[4]):
                raise SystemExit("staged airgap-platform manifest carries invalid OURBOX_PLATFORM_CONTRACT_DIGEST")
            if manifest_fields[4] != required_contract:
                raise SystemExit(
                    "staged airgap-platform manifest contract digest must match mission selected_airgap.platform_contract_digest"
                )
            if manifest_fields[5] != expected_arch:
                raise SystemExit(f"staged airgap-platform manifest arch mismatch: expected {expected_arch}, got {manifest_fields[5]}")
            if not plain_sha256_re.fullmatch(manifest_fields[9]):
                raise SystemExit("staged airgap-platform manifest carries invalid OURBOX_PLATFORM_IMAGES_LOCK_SHA256")
    except tarfile.TarError as exc:
        raise SystemExit(f"mission selected_airgap.payload_relpath must be a valid gzip tar archive: {exc}") from exc

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
require_ref_digest_match("mission selected_os", os_artifact_ref, os_artifact_digest)
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
os_payload_path = require_staged_file("mission selected_os.payload.relpath", os_payload_relpath)
os_meta_path = require_staged_file("mission selected_os.metadata_relpath", os_meta_relpath)
if os_payload_path != expected_payload:
    raise SystemExit("mission selected_os.payload.relpath must match the explicit --os-payload input")
if os_meta_path != expected_meta:
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
require_ref_digest_match("mission selected_airgap", airgap_artifact_ref, airgap_artifact_digest)
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
airgap_payload_path = require_staged_file("mission selected_airgap.payload_relpath", payload_relpath)
airgap_manifest_path = require_staged_file("mission selected_airgap.manifest_relpath", manifest_relpath)
validate_sha256_sidecar("mission selected_airgap.payload.relpath", payload_relpath, airgap_payload_path)
validate_airgap_bundle(airgap_payload_path, airgap_manifest_path, airgap_contract)

installed_target_ssh = manifest.get("installed_target_ssh")
if installed_target_ssh is not None:
    if not isinstance(installed_target_ssh, dict) or not installed_target_ssh:
        raise SystemExit("mission installed_target_ssh must be an object when present")
    mode = str(installed_target_ssh.get("mode", ""))
    key_name = str(installed_target_ssh.get("key_name", ""))
    authorized_key_relpath = str(installed_target_ssh.get("authorized_key_relpath", ""))
    key_type = str(installed_target_ssh.get("key_type", ""))
    public_key_fingerprint = str(installed_target_ssh.get("public_key_fingerprint", ""))
    if mode != "host-generated-authorized-key":
        raise SystemExit("mission installed_target_ssh.mode must be 'host-generated-authorized-key'")
    if not key_name_re.fullmatch(key_name):
        raise SystemExit("mission installed_target_ssh.key_name must match the supported key-name pattern")
    if not authorized_key_relpath:
        raise SystemExit("mission installed_target_ssh.authorized_key_relpath must be set")
    if key_type != "ssh-ed25519":
        raise SystemExit("mission installed_target_ssh.key_type must be 'ssh-ed25519'")
    if not ssh_fingerprint_re.fullmatch(public_key_fingerprint):
        raise SystemExit("mission installed_target_ssh.public_key_fingerprint must be a SHA256 SSH fingerprint")
    authorized_key_path = require_staged_file(
        "mission installed_target_ssh.authorized_key_relpath",
        authorized_key_relpath,
    )
    validate_authorized_key_file("mission installed_target_ssh.authorized_key_relpath", authorized_key_path)

selected_applications = manifest.get("selected_applications")
if selected_applications is not None:
    if not isinstance(selected_applications, dict) or not selected_applications:
        raise SystemExit("mission selected_applications must be an object when present")
    catalog_id = str(selected_applications.get("catalog_id", ""))
    catalog_name = str(selected_applications.get("catalog_name", ""))
    selection_mode = str(selected_applications.get("selection_mode", ""))
    catalog_relpath = selected_applications.get("catalog_relpath")
    selection_relpath = selected_applications.get("selection_relpath")
    selected_app_ids = selected_applications.get("selected_app_ids")
    if not catalog_id:
        raise SystemExit("mission selected_applications.catalog_id must be set")
    if not catalog_name:
        raise SystemExit("mission selected_applications.catalog_name must be set")
    if not selection_mode:
        raise SystemExit("mission selected_applications.selection_mode must be set")
    if not catalog_relpath:
        raise SystemExit("mission selected_applications.catalog_relpath must be set")
    if not selection_relpath:
        raise SystemExit("mission selected_applications.selection_relpath must be set")
    if not isinstance(selected_app_ids, list) or not selected_app_ids:
        raise SystemExit("mission selected_applications.selected_app_ids must be a non-empty list")

    normalized_app_ids = []
    seen_ids = set()
    for raw_app_id in selected_app_ids:
        app_id = str(raw_app_id).strip()
        if not app_id:
            raise SystemExit("mission selected_applications.selected_app_ids contains an empty app id")
        if app_id in seen_ids:
            raise SystemExit(f"mission selected_applications.selected_app_ids duplicates app id {app_id}")
        seen_ids.add(app_id)
        normalized_app_ids.append(app_id)

    catalog_path = require_staged_file("mission selected_applications.catalog_relpath", catalog_relpath)
    selection_path = require_staged_file("mission selected_applications.selection_relpath", selection_relpath)

    with catalog_path.open("r", encoding="utf-8") as handle:
        catalog_data = json.load(handle)
    if catalog_data.get("schema") != 1:
        raise SystemExit("mission application catalog must declare schema=1")
    if catalog_data.get("kind") != "ourbox-application-catalog":
        raise SystemExit("mission application catalog kind must be 'ourbox-application-catalog'")
    if str(catalog_data.get("catalog_id", "")) != catalog_id:
        raise SystemExit("mission application catalog catalog_id must match selected_applications.catalog_id")
    if str(catalog_data.get("catalog_name", "")) != catalog_name:
        raise SystemExit("mission application catalog catalog_name must match selected_applications.catalog_name")
    catalog_apps = catalog_data.get("apps")
    if not isinstance(catalog_apps, list) or not catalog_apps:
        raise SystemExit("mission application catalog must declare a non-empty apps list")
    catalog_app_ids = set()
    for app in catalog_apps:
        app_id = str(app.get("id", "")).strip()
        if not app_id:
            raise SystemExit("mission application catalog contains an app without an id")
        catalog_app_ids.add(app_id)
    unknown_app_ids = [app_id for app_id in normalized_app_ids if app_id not in catalog_app_ids]
    if unknown_app_ids:
        raise SystemExit(
            "mission selected_applications.selected_app_ids must be a subset of mission application catalog apps"
        )

    with selection_path.open("r", encoding="utf-8") as handle:
        selection_data = json.load(handle)
    if selection_data.get("schema") != 1:
        raise SystemExit("mission selected applications file must declare schema=1")
    if selection_data.get("kind") != "ourbox-selected-applications":
        raise SystemExit("mission selected applications file kind must be 'ourbox-selected-applications'")
    if str(selection_data.get("catalog_id", "")) != catalog_id:
        raise SystemExit("mission selected applications file catalog_id must match selected_applications.catalog_id")
    if str(selection_data.get("selection_mode", "")) != selection_mode:
        raise SystemExit("mission selected applications file selection_mode must match selected_applications.selection_mode")

    selection_ids = selection_data.get("selected_app_ids")
    if not isinstance(selection_ids, list) or not selection_ids:
        raise SystemExit("mission selected applications file must declare a non-empty selected_app_ids list")

    normalized_selection_ids = []
    seen_selection_ids = set()
    for raw_app_id in selection_ids:
        app_id = str(raw_app_id).strip()
        if not app_id:
            raise SystemExit("mission selected applications file contains an empty app id")
        if app_id in seen_selection_ids:
            raise SystemExit(f"mission selected applications file duplicates app id {app_id}")
        seen_selection_ids.add(app_id)
        normalized_selection_ids.append(app_id)

    if normalized_selection_ids != normalized_app_ids:
        raise SystemExit("mission selected applications file does not match selected_applications.selected_app_ids")
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
