#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tools/lib.sh"

help_output="$("${ROOT}/tools/prepare-installer-media.sh" --help)"
grep -q -- "--target TARGET" <<<"${help_output}" || die "--help missing target option"
grep -q -- "--compose-only" <<<"${help_output}" || die "--help missing compose-only option"
if grep -q -- "--adapter-repo-root" <<<"${help_output}"; then
  die "--help should not require or advertise a checked-out target repo"
fi

adapter_dump="$(
  python3 - <<'PY' "${ROOT}/vendor/woodbox/adapter.json"
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    adapter = json.load(handle)

official = adapter["official"]
print(official["installer_repo"])
print(official["installer_channel_tags"]["stable"])
print(official["installer_channel_tags"]["nightly"])
print(adapter["notes"][0])
PY
)"
mapfile -t adapter_fields <<<"${adapter_dump}"
[[ "${#adapter_fields[@]}" -eq 4 ]] || die "failed to parse vendored woodbox adapter metadata"

[[ "${adapter_fields[0]}" == "ghcr.io/techofourown/ourbox-woodbox-installer" ]] \
  || die "unexpected installer substrate repo in vendored adapter metadata"
[[ "${adapter_fields[1]}" == "x86-installer-stable" ]] \
  || die "stable installer channel tag mismatch in vendored adapter metadata"
[[ "${adapter_fields[2]}" == "x86-installer-nightly" ]] \
  || die "nightly installer channel tag mismatch in vendored adapter metadata"
grep -q "published Woodbox installer substrate artifact" <<<"${adapter_fields[3]}" \
  || die "vendored adapter notes should describe published substrate composition"

# shellcheck disable=SC2034
OURBOX_PREPARE_INSTALLER_LIBRARY_ONLY=1
# shellcheck disable=SC1091
source "${ROOT}/tools/prepare-installer-media.sh"
unset OURBOX_PREPARE_INSTALLER_LIBRARY_ONLY

# shellcheck disable=SC2034
TARGET="woodbox"
# shellcheck disable=SC2034
OS_CHANNEL="stable"
load_target_adapter_metadata
[[ "${AIRGAP_SELECTION_MODEL}" == "application-catalogs" ]] \
  || die "woodbox should resolve to the application-catalogs selection model"
[[ "${TARGET_SUPPORTS_APPLICATION_CATALOGS}" == "1" ]] \
  || die "woodbox should advertise application catalog support"
[[ "${TARGET_SUPPORTS_INSTALLED_TARGET_SSH}" == "1" ]] \
  || die "woodbox should advertise installed-target SSH support"
[[ "${AIRGAP_REPO}" == "" ]] || die "woodbox should not set an airgap bundle repo"
[[ "${AIRGAP_CATALOG_TAG}" == "" ]] || die "woodbox should not set an airgap bundle catalog tag"
grep -q '"catalog_id": "demo-apps"' <<<"${APPLICATION_CATALOG_SOURCES_JSON}" \
  || die "woodbox should expose vendored application catalog sources"

# shellcheck disable=SC2034
TARGET="matchbox"
# shellcheck disable=SC2034
OS_CHANNEL="stable"
load_target_adapter_metadata
[[ "${AIRGAP_SELECTION_MODEL}" == "published-airgap-bundle" ]] \
  || die "matchbox should resolve to the published-airgap-bundle selection model"
[[ "${TARGET_SUPPORTS_APPLICATION_CATALOGS}" == "0" ]] \
  || die "matchbox should not advertise application catalog support"
[[ "${TARGET_SUPPORTS_INSTALLED_TARGET_SSH}" == "0" ]] \
  || die "matchbox should not advertise installed-target SSH support"
[[ "${APPLICATION_CATALOG_SOURCES_JSON}" == "[]" ]] \
  || die "matchbox should not advertise application catalog sources"
[[ "${AIRGAP_REPO}" == "ghcr.io/techofourown/sw-ourbox-os/airgap-platform" ]] \
  || die "matchbox airgap bundle repo mismatch"
[[ "${AIRGAP_CATALOG_TAG}" == "catalog-arm64" ]] \
  || die "matchbox airgap bundle catalog tag mismatch"

printf '[%s] adapter metadata discovery smoke passed\n' "$(date -Is)"
