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

DEMO_CATALOG_REF="${DEMO_CATALOG_REF:-ghcr.io/techofourown/sw-ourbox-catalog-demo:latest}"
HELLO_WORLD_CATALOG_REF="${HELLO_WORLD_CATALOG_REF:-ghcr.io/techofourown/sw-ourbox-catalog-hello-world:latest}"

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

pull_bundle "${DEMO_CATALOG_REF}" "${TMP_ROOT}/demo"
pull_bundle "${HELLO_WORLD_CATALOG_REF}" "${TMP_ROOT}/hello"

cat > "${TMP_ROOT}/sources.json" <<EOF
[
  {
    "catalog_id": "demo-apps",
    "catalog_name": "Demo Application Catalog",
    "artifact_ref": "${DEMO_CATALOG_REF}",
    "artifact_digest": "$(oras resolve "${DEMO_CATALOG_REF}")",
    "catalog_path": "${TMP_ROOT}/demo/extract/catalog.json",
    "images_lock_path": "${TMP_ROOT}/demo/extract/images.lock.json"
  },
  {
    "catalog_id": "hello-world",
    "catalog_name": "Hello World Catalog",
    "artifact_ref": "${HELLO_WORLD_CATALOG_REF}",
    "artifact_digest": "$(oras resolve "${HELLO_WORLD_CATALOG_REF}")",
    "catalog_path": "${TMP_ROOT}/hello/extract/catalog.json",
    "images_lock_path": "${TMP_ROOT}/hello/extract/images.lock.json"
  }
]
EOF

python3 "${ROOT}/tools/merge-application-catalogs.py" \
  --analysis-only \
  --sources-json "${TMP_ROOT}/sources.json" \
  --out-duplicates "${TMP_ROOT}/duplicates.json"

SOURCE_RESOLUTIONS_JSON="$(
  python3 - <<'PY' "${TMP_ROOT}/duplicates.json"
import json
import json as json_module
import sys

duplicate_report = json.load(open(sys.argv[1], "r", encoding="utf-8"))
for item in duplicate_report:
    if str(item.get("app_uid", "")).strip() != "techofourown/hello-world":
        continue
    chosen = ""
    for candidate in item.get("candidates") or []:
        catalog_id = str(candidate.get("catalog_id", "")).strip()
        if catalog_id == "hello-world":
            chosen = catalog_id
            break
    if not chosen:
        candidates = item.get("candidates") or []
        if candidates:
            chosen = str(candidates[-1].get("catalog_id", "")).strip()
    if not chosen:
        raise SystemExit("duplicate hello-world app is missing candidate catalog ids")
    print(json_module.dumps({"techofourown/hello-world": chosen}, sort_keys=True))
    raise SystemExit(0)

print("{}")
PY
)"

python3 "${ROOT}/tools/merge-application-catalogs.py" \
  --sources-json "${TMP_ROOT}/sources.json" \
  --selection-mode catalog-defaults \
  --source-resolutions-json "${SOURCE_RESOLUTIONS_JSON}" \
  --out-catalog "${TMP_ROOT}/merged.catalog.json" \
  --out-selected-apps "${TMP_ROOT}/merged.selected-apps.json" \
  --out-images-lock "${TMP_ROOT}/merged.images.lock.json" \
  --out-summary "${TMP_ROOT}/merged.summary.json"

python3 - <<'PY' "${TMP_ROOT}/merged.catalog.json" "${TMP_ROOT}/merged.selected-apps.json" "${TMP_ROOT}/merged.images.lock.json" "${TMP_ROOT}/merged.summary.json" "${SOURCE_RESOLUTIONS_JSON}"
import json
import sys

catalog = json.load(open(sys.argv[1], "r", encoding="utf-8"))
selected = json.load(open(sys.argv[2], "r", encoding="utf-8"))
images_lock = json.load(open(sys.argv[3], "r", encoding="utf-8"))
summary = json.load(open(sys.argv[4], "r", encoding="utf-8"))
expected_source_resolutions = json.loads(sys.argv[5])

app_ids = {app["id"] for app in catalog["apps"]}
if "techofourown/hello-world" not in app_ids:
    raise SystemExit("expected merged published catalog to contain hello-world")
if "techofourown/todo-bloom" not in app_ids:
    raise SystemExit("expected merged published catalog to contain todo-bloom")
if selected["selection_mode"] != "catalog-defaults":
    raise SystemExit(f"unexpected selection mode: {selected['selection_mode']}")
if selected["source_resolutions"] != expected_source_resolutions:
    raise SystemExit(f"unexpected source resolutions payload: {selected['source_resolutions']}")
if len(summary.get("source_catalogs", [])) != 2:
    raise SystemExit("expected two published source catalogs in summary")

selected_ids = set(selected["selected_app_ids"])
image_names_in_lock = {str(image.get("name", "")).strip() for image in images_lock.get("images", [])}
for app in catalog["apps"]:
    app_id = str(app.get("id", "")).strip()
    if app_id not in selected_ids:
        continue
    app_image_names = {str(item).strip() for item in (app.get("image_names") or []) if str(item).strip()}
    services = app.get("services")
    if not isinstance(services, list) or not services:
        raise SystemExit(f"expected selected published app {app_id} to keep a non-empty services list")
    for service in services:
        image_name = str(service.get("image", "")).strip()
        if image_name not in app_image_names:
            raise SystemExit(
                f"selected published app {app_id} service image {image_name!r} is not listed in image_names"
            )
        if image_name not in image_names_in_lock:
            raise SystemExit(
                f"selected published app {app_id} service image {image_name!r} is not present in merged images lock"
            )
PY

printf '[%s] published catalog bundle smoke passed\n' "$(date -Is)"
