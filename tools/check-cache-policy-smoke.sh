#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tools/lib.sh"
# shellcheck disable=SC1091
source "${ROOT}/tools/cache.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

OURBOX_INSTALLER_CACHE_ROOT="${TMP}/cache"
export OURBOX_INSTALLER_CACHE_ROOT

mkdir -p "${TMP}/bin"
cat > "${TMP}/bin/oras" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" != "resolve" ]]; then
  echo "unexpected oras command: $*" >&2
  exit 1
fi
printf 'sha256:%064d\n' 1
EOF
chmod +x "${TMP}/bin/oras"
export PATH="${TMP}/bin:${PATH}"

REF="ghcr.io/example/thing:stable"
resolve_ref_with_cache_policy "${REF}" "1"
[[ "${OURBOX_CACHE_LAST_DIGEST}" == "sha256:0000000000000000000000000000000000000000000000000000000000000001" ]] \
  || die "cache policy did not fall back to network resolution on alias miss"
[[ "${OURBOX_CACHE_LAST_PINNED_REF}" == "ghcr.io/example/thing@sha256:0000000000000000000000000000000000000000000000000000000000000001" ]] \
  || die "cache policy did not capture pinned ref after fallback resolve"

cache_lookup_ref_alias "${REF}"
[[ "${OURBOX_CACHE_LAST_PINNED_REF}" == "ghcr.io/example/thing@sha256:0000000000000000000000000000000000000000000000000000000000000001" ]] \
  || die "resolved alias was not recorded in cache"

printf '[%s] cache policy smoke passed\n' "$(date -Is)"
