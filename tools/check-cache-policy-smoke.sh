#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

OURBOX_INSTALLER_CACHE_ROOT="${TMP}/cache"
export OURBOX_INSTALLER_CACHE_ROOT

# shellcheck disable=SC1091
source "${ROOT}/tools/lib.sh"
# shellcheck disable=SC1091
source "${ROOT}/tools/cache.sh"

FIXTURE_ROOT="${TMP}/fixture"
mkdir -p "${FIXTURE_ROOT}/bin" "${FIXTURE_ROOT}/resolve-map" "${FIXTURE_ROOT}/resolve-fail"
export OURBOX_ORAS_FIXTURE_ROOT="${FIXTURE_ROOT}"

cat > "${FIXTURE_ROOT}/bin/oras" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

fixture_root="${OURBOX_ORAS_FIXTURE_ROOT:?missing OURBOX_ORAS_FIXTURE_ROOT}"
cmd="${1:-}"
shift || true

key_for() {
  printf '%s' "$1" | sha256sum | awk '{print $1}'
}

case "${cmd}" in
  resolve)
    ref="${1:-}"
    [[ -n "${ref}" ]] || exit 1
    printf 'resolve\t%s\n' "${ref}" >> "${fixture_root}/oras.calls"
    key="$(key_for "${ref}")"
    if [[ -f "${fixture_root}/resolve-fail/${key}" ]]; then
      exit 1
    fi
    [[ -f "${fixture_root}/resolve-map/${key}" ]] || exit 1
    cat "${fixture_root}/resolve-map/${key}"
    ;;
  pull)
    ref=""
    out_dir=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -o)
          [[ $# -ge 2 ]] || exit 1
          out_dir="$2"
          shift 2
          ;;
        *)
          [[ -z "${ref}" ]] || exit 1
          ref="$1"
          shift
          ;;
      esac
    done
    [[ -n "${ref}" && -n "${out_dir}" ]] || exit 1
    printf 'pull\t%s\t%s\n' "${ref}" "${out_dir}" >> "${fixture_root}/oras.calls"
    mkdir -p "${out_dir}"
    printf '%s\n' "${ref}" > "${out_dir}/pinned-ref.txt"
    ;;
  *)
    echo "unexpected oras command: ${cmd} $*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "${FIXTURE_ROOT}/bin/oras"
export PATH="${FIXTURE_ROOT}/bin:${PATH}"

make_digest() {
  local value="$1"
  printf 'sha256:%064x\n' "${value}"
}

make_pinned_ref() {
  local repo="$1"
  local digest="$2"
  printf '%s@%s\n' "${repo}" "${digest}"
}

fixture_key() {
  local value="$1"
  printf '%s' "${value}" | sha256sum | awk '{print $1}'
}

reset_oras_fixture() {
  rm -rf "${FIXTURE_ROOT}/resolve-map" "${FIXTURE_ROOT}/resolve-fail"
  mkdir -p "${FIXTURE_ROOT}/resolve-map" "${FIXTURE_ROOT}/resolve-fail"
  : > "${FIXTURE_ROOT}/oras.calls"
}

set_resolve_result() {
  local ref="$1"
  local digest="$2"
  local key=""

  key="$(fixture_key "${ref}")"
  rm -f "${FIXTURE_ROOT}/resolve-fail/${key}"
  printf '%s\n' "${digest}" > "${FIXTURE_ROOT}/resolve-map/${key}"
}

set_resolve_failure() {
  local ref="$1"
  local key=""

  key="$(fixture_key "${ref}")"
  rm -f "${FIXTURE_ROOT}/resolve-map/${key}"
  : > "${FIXTURE_ROOT}/resolve-fail/${key}"
}

oras_call_count() {
  local command_name="$1"

  awk -F '\t' -v command_name="${command_name}" '$1 == command_name {count += 1} END {print count + 0}' "${FIXTURE_ROOT}/oras.calls"
}

reset_cache_fixture() {
  rm -rf "${OURBOX_INSTALLER_CACHE_ROOT}"
  OURBOX_CACHE_LAST_DIGEST=""
  OURBOX_CACHE_LAST_PINNED_REF=""
}

seed_cached_digest() {
  local digest="$1"
  local cache_dir=""

  cache_dir="$(cache_dir_for_digest "${digest}")"
  mkdir -p "${cache_dir}"
  printf '%s\n' "${digest}" > "${cache_dir}/payload.txt"
  touch "${cache_dir}/.pull-complete"
}

seed_alias() {
  local ref="$1"
  local pinned_ref="$2"
  local digest="$3"

  cache_record_ref_alias "${ref}" "${pinned_ref}" "${digest}"
}

REF="ghcr.io/example/thing:stable"
REPO_BASE="ghcr.io/example/thing"
OLD_DIGEST="$(make_digest 1)"
NEW_DIGEST="$(make_digest 2)"
OLD_PINNED_REF="$(make_pinned_ref "${REPO_BASE}" "${OLD_DIGEST}")"
NEW_PINNED_REF="$(make_pinned_ref "${REPO_BASE}" "${NEW_DIGEST}")"

reset_cache_fixture
mkdir -p "${OURBOX_INSTALLER_CACHE_ROOT}/ref-aliases/legacy"
printf '%s\n' "${OLD_PINNED_REF}" > "${OURBOX_INSTALLER_CACHE_ROOT}/ref-aliases/legacy/pinned-ref.txt"
printf '%s\n' "${OLD_DIGEST}" > "${OURBOX_INSTALLER_CACHE_ROOT}/ref-aliases/legacy/resolved-digest.txt"
cache_migrate_ref_alias_layout
[[ ! -d "${OURBOX_INSTALLER_CACHE_ROOT}/ref-aliases/legacy" ]] \
  || die "legacy floating-ref alias state should be cleared during cache migration"

reset_cache_fixture
reset_oras_fixture
seed_cached_digest "${OLD_DIGEST}"
seed_alias "${REF}" "${OLD_PINNED_REF}" "${OLD_DIGEST}"
set_resolve_result "${REF}" "${NEW_DIGEST}"

resolved_dir=""
try_cache_pull_oci_artifact "${REF}" "1" resolved_dir
[[ "${resolved_dir}" == "$(cache_dir_for_digest "${NEW_DIGEST}")" ]] \
  || die "floating refs must pull into the current resolved digest cache dir"
[[ "$(oras_call_count resolve)" == "1" ]] \
  || die "floating refs must live-resolve before cache reuse"
[[ "$(oras_call_count pull)" == "1" ]] \
  || die "stale floating-ref aliases must not suppress a pull for the current digest"
[[ "$(<"${resolved_dir}/pinned-ref.txt")" == "${NEW_PINNED_REF}" ]] \
  || die "pull should target the current resolved pinned ref"
cache_lookup_ref_alias "${REF}"
[[ "${OURBOX_CACHE_LAST_PINNED_REF}" == "${NEW_PINNED_REF}" ]] \
  || die "floating ref alias metadata should track the last live-resolved digest"

reset_cache_fixture
reset_oras_fixture
seed_cached_digest "${OLD_DIGEST}"
seed_cached_digest "${NEW_DIGEST}"
seed_alias "${REF}" "${OLD_PINNED_REF}" "${OLD_DIGEST}"
set_resolve_result "${REF}" "${NEW_DIGEST}"

resolved_dir=""
cache_has_cached_ref "${REF}" \
  || die "cache reuse should be available when the current resolved digest is already cached"
[[ "${OURBOX_CACHE_LAST_PINNED_REF}" == "${NEW_PINNED_REF}" ]] \
  || die "cache availability checks must use the current resolved pinned ref"
try_cache_pull_oci_artifact "${REF}" "1" resolved_dir
[[ "${resolved_dir}" == "$(cache_dir_for_digest "${NEW_DIGEST}")" ]] \
  || die "cache reuse should return the cache dir for the current resolved digest"
[[ "$(oras_call_count resolve)" == "2" ]] \
  || die "floating refs should resolve for cache checks and cache pulls"
[[ "$(oras_call_count pull)" == "0" ]] \
  || die "current resolved digest cache hits must not perform a fresh pull"

reset_cache_fixture
reset_oras_fixture
seed_cached_digest "${OLD_DIGEST}"
seed_alias "${REF}" "${OLD_PINNED_REF}" "${OLD_DIGEST}"
set_resolve_failure "${REF}"

resolved_dir=""
if cache_has_cached_ref "${REF}"; then
  die "floating refs must not report a cache hit when live resolve fails"
fi
if try_cache_pull_oci_artifact "${REF}" "1" resolved_dir; then
  die "floating refs must fail closed when live resolve fails"
fi
[[ "$(oras_call_count resolve)" == "2" ]] \
  || die "failed floating-ref resolution should still reflect attempted live resolves"
[[ "$(oras_call_count pull)" == "0" ]] \
  || die "failed floating-ref resolution must not fall back to stale cached pulls"

PINNED_ONLY_DIGEST="$(make_digest 3)"
PINNED_ONLY_REF="$(make_pinned_ref "ghcr.io/example/pinned" "${PINNED_ONLY_DIGEST}")"

reset_cache_fixture
reset_oras_fixture
seed_cached_digest "${PINNED_ONLY_DIGEST}"

resolved_dir=""
cache_has_cached_ref "${PINNED_ONLY_REF}" \
  || die "pinned refs with cached content should report a cache hit"
try_cache_pull_oci_artifact "${PINNED_ONLY_REF}" "1" resolved_dir
[[ "${resolved_dir}" == "$(cache_dir_for_digest "${PINNED_ONLY_DIGEST}")" ]] \
  || die "pinned refs should reuse the digest-keyed cache dir directly"
[[ "$(oras_call_count resolve)" == "0" ]] \
  || die "pinned refs must not require oras resolve for cache reuse"
[[ "$(oras_call_count pull)" == "0" ]] \
  || die "pinned refs with cached content must not trigger a pull"

printf '[%s] cache policy smoke passed\n' "$(date -Is)"
