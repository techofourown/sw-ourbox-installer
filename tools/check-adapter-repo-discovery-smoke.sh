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

printf '[%s] published substrate selection smoke passed\n' "$(date -Is)"
