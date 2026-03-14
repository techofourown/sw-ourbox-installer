#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMP_ROOT}"' EXIT

# shellcheck disable=SC1091
source "${ROOT}/tools/lib.sh"
need_cmd oras
need_cmd tar
need_cmd python3
need_cmd sha256sum

pull_bundle() {
  local ref="$1"
  local out_dir="$2"
  local bundle_tar=""

  mkdir -p "${out_dir}"
  oras pull -o "${out_dir}" "${ref}"
  bundle_tar="$(find "${out_dir}" -maxdepth 4 -type f -name 'application-catalog-bundle.tar.gz' | head -n 1)"
  [[ -f "${bundle_tar}" ]] || die "missing bundle tarball after oras pull: ${ref}"

  mkdir -p "${out_dir}/extract"
  tar -xzf "${bundle_tar}" -C "${out_dir}/extract"
  [[ -f "${out_dir}/extract/catalog.json" ]] || die "published bundle missing catalog.json after extract: ${ref}"
  [[ -f "${out_dir}/extract/images.lock.json" ]] || die "published bundle missing images.lock.json after extract: ${ref}"
  [[ -f "${out_dir}/extract/profile.env" ]] || die "published bundle missing profile.env after extract: ${ref}"
  [[ -f "${out_dir}/extract/manifest.env" ]] || die "published bundle missing manifest.env after extract: ${ref}"
}

pull_bundle "ghcr.io/techofourown/sw-ourbox-catalog-demo:latest" "${TMP_ROOT}/demo"
pull_bundle "ghcr.io/techofourown/sw-ourbox-catalog-hello-world:latest" "${TMP_ROOT}/hello"

cat > "${TMP_ROOT}/sources.json" <<EOF
[
  {
    "catalog_id": "demo-apps",
    "catalog_name": "Demo Application Catalog",
    "artifact_ref": "ghcr.io/techofourown/sw-ourbox-catalog-demo:latest",
    "artifact_digest": "$(oras resolve ghcr.io/techofourown/sw-ourbox-catalog-demo:latest)",
    "catalog_path": "${TMP_ROOT}/demo/extract/catalog.json",
    "images_lock_path": "${TMP_ROOT}/demo/extract/images.lock.json"
  },
  {
    "catalog_id": "hello-world",
    "catalog_name": "Hello World Catalog",
    "artifact_ref": "ghcr.io/techofourown/sw-ourbox-catalog-hello-world:latest",
    "artifact_digest": "$(oras resolve ghcr.io/techofourown/sw-ourbox-catalog-hello-world:latest)",
    "catalog_path": "${TMP_ROOT}/hello/extract/catalog.json",
    "images_lock_path": "${TMP_ROOT}/hello/extract/images.lock.json"
  }
]
EOF

python3 "${ROOT}/tools/merge-application-catalogs.py" \
  --sources-json "${TMP_ROOT}/sources.json" \
  --selection-mode catalog-defaults \
  --source-resolutions-json '{"techofourown/hello-world":"hello-world"}' \
  --out-catalog "${TMP_ROOT}/merged.catalog.json" \
  --out-selected-apps "${TMP_ROOT}/merged.selected-apps.json" \
  --out-images-lock "${TMP_ROOT}/merged.images.lock.json" \
  --out-summary "${TMP_ROOT}/merged.summary.json"

python3 - <<'PY' "${TMP_ROOT}/merged.catalog.json" "${TMP_ROOT}/merged.selected-apps.json" "${TMP_ROOT}/merged.summary.json"
import json
import sys

catalog = json.load(open(sys.argv[1], "r", encoding="utf-8"))
selected = json.load(open(sys.argv[2], "r", encoding="utf-8"))
summary = json.load(open(sys.argv[3], "r", encoding="utf-8"))

app_ids = {app["id"] for app in catalog["apps"]}
if "techofourown/hello-world" not in app_ids:
    raise SystemExit("expected merged published catalog to contain hello-world")
if "techofourown/todo-bloom" not in app_ids:
    raise SystemExit("expected merged published catalog to contain todo-bloom")
if selected["selection_mode"] != "catalog-defaults":
    raise SystemExit(f"unexpected selection mode: {selected['selection_mode']}")
if selected["source_resolutions"] != {"techofourown/hello-world": "hello-world"}:
    raise SystemExit(f"unexpected source resolutions payload: {selected['source_resolutions']}")
if len(summary.get("source_catalogs", [])) != 2:
    raise SystemExit("expected two published source catalogs in summary")
PY

printf '[%s] published catalog bundle smoke passed\n' "$(date -Is)"
