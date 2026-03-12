#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tools/lib.sh"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMP_ROOT}"' EXIT

make_fake_installer_root() {
  local destination="$1"
  mkdir -p "${destination}/tools"
  cp "${ROOT}/tools/prepare-installer-media.sh" "${destination}/tools/"
  cp "${ROOT}/tools/lib.sh" "${destination}/tools/"
  cp "${ROOT}/tools/cache.sh" "${destination}/tools/"
}

make_git_repo() {
  local destination="$1"
  mkdir -p "${destination}"
  git -C "${destination}" init -q
  git -C "${destination}" config user.name "Codex Smoke"
  git -C "${destination}" config user.email "codex-smoke@example.invalid"
  printf 'smoke\n' >"${destination}/.keep"
  git -C "${destination}" add .keep
  git -C "${destination}" commit -q --no-verify -m "chore(smoke): initialize repo" -m "Seed a temporary repository for adapter discovery smoke coverage."
}

resolve_from_fake_root() {
  local fake_root="$1"
  local explicit_root="${2:-}"
  local env_root="${3:-}"
  OURBOX_PREPARE_INSTALLER_LIBRARY_ONLY=1 WOODBOX_REPO_ROOT="${env_root}" bash -lc '
set -euo pipefail
explicit_root="$1"
script_path="$2"
source "${script_path}"
resolve_woodbox_repo_root "${explicit_root}" "${WOODBOX_REPO_ROOT:-}"
' _ "${explicit_root}" "${fake_root}/tools/prepare-installer-media.sh"
}

FAKE_INSTALLER_ROOT="${TMP_ROOT}/installer"
make_fake_installer_root "${FAKE_INSTALLER_ROOT}"

NESTED_REPO="${FAKE_INSTALLER_ROOT}/img-ourbox-woodbox"
SIBLING_REPO="${TMP_ROOT}/img-ourbox-woodbox"
EXPLICIT_REPO="${TMP_ROOT}/custom-woodbox"

make_git_repo "${SIBLING_REPO}"
make_git_repo "${NESTED_REPO}"
make_git_repo "${EXPLICIT_REPO}"

resolved_root="$(resolve_from_fake_root "${FAKE_INSTALLER_ROOT}")"
[[ "${resolved_root}" == "$(cd "${NESTED_REPO}" && pwd -P)" ]] || die "expected nested Woodbox repo to win autodiscovery, got ${resolved_root}"

rm -rf "${NESTED_REPO}"
resolved_root="$(resolve_from_fake_root "${FAKE_INSTALLER_ROOT}")"
[[ "${resolved_root}" == "$(cd "${SIBLING_REPO}" && pwd -P)" ]] || die "expected sibling Woodbox repo to win autodiscovery, got ${resolved_root}"

resolved_root="$(resolve_from_fake_root "${FAKE_INSTALLER_ROOT}" "${EXPLICIT_REPO}")"
[[ "${resolved_root}" == "$(cd "${EXPLICIT_REPO}" && pwd -P)" ]] || die "expected explicit adapter repo root to win autodiscovery, got ${resolved_root}"

printf '[%s] adapter repo discovery smoke passed\n' "$(date -Is)"
