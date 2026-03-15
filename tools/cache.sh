#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tools/lib.sh"

: "${OURBOX_INSTALLER_CACHE_ROOT:=${ROOT}/cache}"
OURBOX_CACHE_REF_ALIAS_LAYOUT_VERSION="2"
OURBOX_CACHE_LAST_DIGEST=""
OURBOX_CACHE_LAST_PINNED_REF=""

cache_alias_key() {
  printf '%s' "$1" | sha256sum | awk '{print $1}'
}

cache_alias_dir() {
  local ref="$1"
  printf '%s/ref-aliases/%s\n' "${OURBOX_INSTALLER_CACHE_ROOT}" "$(cache_alias_key "${ref}")"
}

cache_alias_layout_version_file() {
  printf '%s/ref-aliases/.layout-version\n' "${OURBOX_INSTALLER_CACHE_ROOT}"
}

cache_migrate_ref_alias_layout() {
  local alias_root="${OURBOX_INSTALLER_CACHE_ROOT}/ref-aliases"
  local version_file=""
  local version=""

  [[ -d "${alias_root}" ]] || return 0

  version_file="$(cache_alias_layout_version_file)"
  if [[ -f "${version_file}" ]]; then
    version="$(<"${version_file}")"
    [[ "${version}" == "${OURBOX_CACHE_REF_ALIAS_LAYOUT_VERSION}" ]] && return 0
  fi

  rm -rf "${alias_root}"
}

cache_write_ref_alias_layout_version() {
  local version_file=""

  version_file="$(cache_alias_layout_version_file)"
  mkdir -p "$(dirname "${version_file}")"
  printf '%s\n' "${OURBOX_CACHE_REF_ALIAS_LAYOUT_VERSION}" > "${version_file}"
}

cache_record_ref_alias() {
  local ref="$1"
  local pinned_ref="$2"
  local digest="$3"
  local alias_dir=""

  alias_dir="$(cache_alias_dir "${ref}")"
  cache_write_ref_alias_layout_version
  mkdir -p "${alias_dir}"
  printf '%s\n' "${ref}" > "${alias_dir}/source-ref.txt"
  printf '%s\n' "${pinned_ref}" > "${alias_dir}/pinned-ref.txt"
  printf '%s\n' "${digest}" > "${alias_dir}/resolved-digest.txt"
}

cache_lookup_ref_alias() {
  local ref="$1"
  local alias_dir=""
  local pinned_ref=""
  local digest=""

  alias_dir="$(cache_alias_dir "${ref}")"
  [[ -f "${alias_dir}/pinned-ref.txt" ]] || return 1
  [[ -f "${alias_dir}/resolved-digest.txt" ]] || return 1

  pinned_ref="$(<"${alias_dir}/pinned-ref.txt")"
  digest="$(<"${alias_dir}/resolved-digest.txt")"
  is_pinned_ref "${pinned_ref}" || return 1
  is_sha256_digest "${digest}" || return 1

  OURBOX_CACHE_LAST_PINNED_REF="${pinned_ref}"
  OURBOX_CACHE_LAST_DIGEST="${digest}"
  return 0
}

cache_dir_for_digest() {
  local digest="$1"
  printf '%s/oci/%s\n' "${OURBOX_INSTALLER_CACHE_ROOT}" "${digest#sha256:}"
}

cache_has_cached_ref() {
  local ref="$1"
  local digest=""

  if is_pinned_ref "${ref}"; then
    digest="${ref##*@}"
    OURBOX_CACHE_LAST_DIGEST="${digest}"
    OURBOX_CACHE_LAST_PINNED_REF="${ref}"
  else
    resolve_ref_with_cache_policy "${ref}" "0" || return 1
    digest="${OURBOX_CACHE_LAST_DIGEST}"
  fi

  [[ -f "$(cache_dir_for_digest "${digest}")/.pull-complete" ]]
}

cache_has_any_content() {
  [[ -d "${OURBOX_INSTALLER_CACHE_ROOT}" ]] || return 1
  find "${OURBOX_INSTALLER_CACHE_ROOT}" -mindepth 1 -print -quit | grep -q .
}

cache_clear_all() {
  rm -rf "${OURBOX_INSTALLER_CACHE_ROOT}"
}

resolve_ref_with_cache_policy() {
  local ref="$1"
  local _reuse_cache="${2:-0}"
  local digest=""
  local repo_base=""

  if is_pinned_ref "${ref}"; then
    digest="${ref##*@}"
    OURBOX_CACHE_LAST_DIGEST="${digest}"
    OURBOX_CACHE_LAST_PINNED_REF="${ref}"
    return 0
  fi

  need_cmd oras
  digest="$(oras resolve "${ref}" 2>/dev/null || true)"
  is_sha256_digest "${digest}" || return 1
  repo_base="$(ref_repo_base "${ref}")"
  OURBOX_CACHE_LAST_DIGEST="${digest}"
  OURBOX_CACHE_LAST_PINNED_REF="${repo_base}@${digest}"
  cache_record_ref_alias "${ref}" "${OURBOX_CACHE_LAST_PINNED_REF}" "${OURBOX_CACHE_LAST_DIGEST}"
  return 0
}

resolve_ref_for_pull() {
  local ref="$1"
  local reuse_cache="$2"

  if resolve_ref_with_cache_policy "${ref}" "${reuse_cache}"; then
    return 0
  fi
  die "failed to resolve digest for ${ref}"
}

try_cache_pull_oci_artifact() {
  local ref="$1"
  local reuse_cache="$2"
  local outvar="$3"
  local cache_dir=""
  local tmpdir=""

  resolve_ref_with_cache_policy "${ref}" "${reuse_cache}" || return 1

  cache_dir="$(cache_dir_for_digest "${OURBOX_CACHE_LAST_DIGEST}")"
  if [[ "${reuse_cache}" == "1" && -f "${cache_dir}/.pull-complete" ]]; then
    printf -v "${outvar}" '%s' "${cache_dir}"
    return 0
  fi

  need_cmd oras
  mkdir -p "${OURBOX_INSTALLER_CACHE_ROOT}/oci"
  tmpdir="$(mktemp -d)"

  log "Pulling ${OURBOX_CACHE_LAST_PINNED_REF} into cache"
  if ! oras pull "${OURBOX_CACHE_LAST_PINNED_REF}" -o "${tmpdir}" >/dev/null; then
    rm -rf "${tmpdir}"
    return 1
  fi

  rm -rf "${cache_dir}"
  mkdir -p "${cache_dir}"
  cp -a "${tmpdir}/." "${cache_dir}/"
  rm -rf "${tmpdir}"
  printf '%s\n' "${ref}" > "${cache_dir}/source-ref.txt"
  printf '%s\n' "${OURBOX_CACHE_LAST_PINNED_REF}" > "${cache_dir}/pinned-ref.txt"
  printf '%s\n' "${OURBOX_CACHE_LAST_DIGEST}" > "${cache_dir}/resolved-digest.txt"
  cache_record_ref_alias "${ref}" "${OURBOX_CACHE_LAST_PINNED_REF}" "${OURBOX_CACHE_LAST_DIGEST}"
  touch "${cache_dir}/.pull-complete"

  printf -v "${outvar}" '%s' "${cache_dir}"
  return 0
}

cache_pull_oci_artifact() {
  local ref="$1"
  local reuse_cache="$2"
  local outvar="$3"

  if try_cache_pull_oci_artifact "${ref}" "${reuse_cache}" "${outvar}"; then
    return 0
  fi
  die "failed to cache OCI artifact: ${ref}"
}

cache_migrate_ref_alias_layout
