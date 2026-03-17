#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

output="$(OURBOX_FLASH_HELPER_SELFTEST=1 bash "${ROOT}/vendor/matchbox/flash-installer-media.sh")"
grep -q "flash helper self-test passed" <<<"${output}" || {
  echo "vendored matchbox flash helper self-test did not report success" >&2
  exit 1
}

echo "vendored matchbox flash helper smoke passed"
