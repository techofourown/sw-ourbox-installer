#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tools/lib.sh"

help_output="$("${ROOT}/tools/prepare-installer-media.sh" --help)"
[[ "${help_output}" == *"--compose-only"* ]] || die "--help output is missing --compose-only"
[[ "${help_output}" == *"--mission-only"* ]] || die "--help output is missing --mission-only"
[[ "${help_output}" == *"--flash-device"* ]] || die "--help output is missing --flash-device"

OURBOX_PREPARE_INSTALLER_LIBRARY_ONLY=1
# shellcheck disable=SC1091
source "${ROOT}/tools/prepare-installer-media.sh"
unset OURBOX_PREPARE_INSTALLER_LIBRARY_ONLY

interactive_selection_enabled() {
  return 1
}

TARGET="woodbox"
OUTPUT_DIR=""
MISSION_ONLY=0
COMPOSE_ONLY=0
FLASH_DEVICE=""
if (require_flash_path_or_explicit_mode >/dev/null 2>&1); then
  die "expected non-interactive default mode to require --flash-device, --compose-only, or --mission-only"
fi

MISSION_ONLY=1
COMPOSE_ONLY=0
FLASH_DEVICE=""
require_flash_path_or_explicit_mode

MISSION_ONLY=0
COMPOSE_ONLY=1
FLASH_DEVICE=""
require_flash_path_or_explicit_mode

MISSION_ONLY=0
COMPOSE_ONLY=0
FLASH_DEVICE="/dev/sdz"
require_flash_path_or_explicit_mode

printf '[%s] flash-first policy smoke passed\n' "$(date -Is)"
