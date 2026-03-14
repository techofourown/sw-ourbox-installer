#!/usr/bin/env python3
import argparse
import json
import re
from pathlib import Path

CATALOG_ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")


def sanitize_token(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-") or "app"


def load_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


def validate_catalog(catalog: dict, catalog_path: Path) -> None:
    if catalog.get("schema") != 1:
        raise SystemExit(f"{catalog_path} must declare schema=1")
    if catalog.get("kind") != "ourbox-application-catalog":
        raise SystemExit(f"{catalog_path} must declare kind=ourbox-application-catalog")
    catalog_id = str(catalog.get("catalog_id", "")).strip()
    catalog_name = str(catalog.get("catalog_name", "")).strip()
    if not catalog_id:
        raise SystemExit(f"{catalog_path} must declare catalog_id")
    if not CATALOG_ID_RE.fullmatch(catalog_id):
        raise SystemExit(
            f"{catalog_path} declares invalid catalog_id {catalog_id!r}; expected lowercase machine token"
        )
    if not catalog_name:
        raise SystemExit(f"{catalog_path} must declare catalog_name")
    apps = catalog.get("apps")
    defaults = catalog.get("default_app_ids")
    if not isinstance(apps, list) or not apps:
        raise SystemExit(f"{catalog_path} must declare a non-empty apps list")
    if not isinstance(defaults, list) or not defaults:
        raise SystemExit(f"{catalog_path} must declare non-empty default_app_ids")
    seen_ids: set[str] = set()
    for app in apps:
        app_id = str(app.get("id", "")).strip()
        if not app_id:
            raise SystemExit(f"{catalog_path} contains an app without an id")
        if app_id in seen_ids:
            raise SystemExit(f"{catalog_path} contains duplicate app id {app_id}")
        seen_ids.add(app_id)
    unknown_defaults = sorted(set(str(item).strip() for item in defaults) - seen_ids)
    if unknown_defaults:
        raise SystemExit(f"{catalog_path} declares unknown default_app_ids: {', '.join(unknown_defaults)}")
    default_backends = 0
    for app in apps:
        if bool(app.get("default_backend", False)):
            default_backends += 1
    if default_backends > 1:
        raise SystemExit(f"{catalog_path} declares more than one default_backend app")


def validate_images_lock(images_lock: dict, images_lock_path: Path) -> dict[str, dict]:
    if images_lock.get("schema") != 1:
        raise SystemExit(f"{images_lock_path} must declare schema=1")
    images = images_lock.get("images")
    if not isinstance(images, list) or not images:
        raise SystemExit(f"{images_lock_path} must declare a non-empty images list")
    by_name: dict[str, dict] = {}
    for image in images:
        name = str(image.get("name", "")).strip()
        ref = str(image.get("ref", "")).strip()
        if not name:
            raise SystemExit(f"{images_lock_path} contains an image without a name")
        if not ref:
            raise SystemExit(f"{images_lock_path} contains an image without a ref")
        if name in by_name:
            raise SystemExit(f"{images_lock_path} contains duplicate image name {name}")
        by_name[name] = image
    return by_name


def canonical_app_uid(source: dict, app: dict) -> str:
    explicit = str(app.get("app_uid", "")).strip()
    if explicit:
        return explicit
    return f"{source['catalog_id']}/{str(app['id']).strip()}"


def canonical_source_key(source: dict) -> tuple[str, str, str]:
    return (
        str(source["catalog_id"]).strip(),
        str(source["artifact_ref"]).strip(),
        str(source["artifact_digest"]).strip(),
    )


def app_signature(app: dict, resolved_images: list[dict]) -> str:
    comparable = {
        "display_name": str(app.get("display_name", "")),
        "description": str(app.get("description", "")),
        "renderer": str(app.get("renderer", "")),
        "service_name": str(app.get("service_name", "")),
        "service_port": int(app.get("service_port", 0)),
        "host_template": str(app.get("host_template", "")),
        "path": str(app.get("path", "/")),
        "expected_status": int(app.get("expected_status", 0)),
        "body_marker": str(app.get("body_marker", "")),
        "route_description": str(app.get("route_description", "")),
        "default_backend": bool(app.get("default_backend", False)),
        "resolved_images": resolved_images,
    }
    return json.dumps(comparable, sort_keys=True)


def parse_source_resolutions(raw_value: str) -> dict[str, str]:
    if not raw_value.strip():
        return {}
    parsed = json.loads(raw_value)
    if not isinstance(parsed, dict):
        raise SystemExit("--source-resolutions-json must be a JSON object")

    resolutions: dict[str, str] = {}
    for raw_app_uid, raw_catalog_id in parsed.items():
        app_uid = str(raw_app_uid).strip()
        catalog_id = str(raw_catalog_id).strip()
        if not app_uid or not catalog_id:
            raise SystemExit("source resolution entries must map non-empty app_uids to non-empty catalog_ids")
        resolutions[app_uid] = catalog_id
    return resolutions


def build_source_catalogs(sources: list[dict]) -> tuple[list[dict], dict[tuple[str, str, str], int]]:
    canonical_source_catalogs: list[dict] = []
    seen_catalog_ids: set[str] = set()
    for source in sources:
        catalog_id = str(source.get("catalog_id", "")).strip()
        catalog_name = str(source.get("catalog_name", "")).strip()
        artifact_ref = str(source.get("artifact_ref", "")).strip()
        artifact_digest = str(source.get("artifact_digest", "")).strip()
        if not catalog_id or not catalog_name or not artifact_ref or not artifact_digest:
            raise SystemExit("source catalog entries must declare catalog_id, catalog_name, artifact_ref, and artifact_digest")
        if catalog_id in seen_catalog_ids:
            raise SystemExit(
                f"sources list declares duplicate catalog_id {catalog_id!r}; select at most one version of each catalog per merge"
            )
        seen_catalog_ids.add(catalog_id)
        canonical_source_catalogs.append(
            {
                "catalog_id": catalog_id,
                "catalog_name": catalog_name,
                "artifact_ref": artifact_ref,
                "artifact_digest": artifact_digest,
            }
        )
    canonical_source_catalogs.sort(key=canonical_source_key)
    canonical_source_positions = {
        canonical_source_key(source): index for index, source in enumerate(canonical_source_catalogs)
    }
    return canonical_source_catalogs, canonical_source_positions


def build_candidate_records(sources: list[dict]) -> tuple[dict[str, list[dict]], set[str]]:
    candidates_by_uid: dict[str, list[dict]] = {}
    merged_defaults: set[str] = set()

    for source_index, source in enumerate(sources):
        catalog_path = Path(source["catalog_path"]).resolve()
        images_lock_path = Path(source["images_lock_path"]).resolve()
        artifact_ref = str(source["artifact_ref"]).strip()
        artifact_digest = str(source["artifact_digest"]).strip()
        catalog = load_json(catalog_path)
        images_lock = load_json(images_lock_path)
        validate_catalog(catalog, catalog_path)
        image_by_name = validate_images_lock(images_lock, images_lock_path)

        default_ids = [str(item).strip() for item in catalog["default_app_ids"]]
        defaults_set = set(default_ids)
        seen_source_app_uids: set[str] = set()
        source_meta = {
            "catalog_id": str(catalog["catalog_id"]).strip(),
            "catalog_name": str(catalog["catalog_name"]).strip(),
            "artifact_ref": artifact_ref,
            "artifact_digest": artifact_digest,
        }

        for app_index, raw_app in enumerate(catalog["apps"]):
            app = dict(raw_app)
            local_app_id = str(app["id"]).strip()
            app_uid = canonical_app_uid(source_meta, app)
            if app_uid in seen_source_app_uids:
                raise SystemExit(f"{catalog_path} contains duplicate canonical app identity {app_uid!r}")
            seen_source_app_uids.add(app_uid)

            image_names = app.get("image_names")
            if not isinstance(image_names, list) or not image_names:
                raise SystemExit(f"{catalog_path} app {local_app_id!r} must declare a non-empty image_names list")

            resolved_images: list[dict] = []
            for image_name in image_names:
                lookup = str(image_name).strip()
                if lookup not in image_by_name:
                    raise SystemExit(
                        f"{catalog_path} app {local_app_id!r} references unknown image name {lookup!r}"
                    )
                resolved_images.append({"name": lookup, "ref": str(image_by_name[lookup]["ref"])})

            candidate = {
                "app_uid": app_uid,
                "local_app_id": local_app_id,
                "display_name": str(app.get("display_name", local_app_id)),
                "description": str(app.get("description", "")),
                "renderer": str(app.get("renderer", "")),
                "service_name": str(app.get("service_name", local_app_id)),
                "service_port": int(app.get("service_port", 80)),
                "host_template": str(app.get("host_template", "{box_host}")),
                "path": str(app.get("path", "/")),
                "expected_status": int(app.get("expected_status", 200)),
                "body_marker": str(app.get("body_marker", "")),
                "route_description": str(app.get("route_description", app_uid)),
                "default_backend": bool(app.get("default_backend", False)),
                "catalog_id": source_meta["catalog_id"],
                "catalog_name": source_meta["catalog_name"],
                "artifact_ref": source_meta["artifact_ref"],
                "artifact_digest": source_meta["artifact_digest"],
                "default_selected": local_app_id in defaults_set,
                "_resolved_images": resolved_images,
                "_signature": app_signature(app, resolved_images),
                "_source_order": (source_index, app_index),
            }
            candidates_by_uid.setdefault(app_uid, []).append(candidate)
            if local_app_id in defaults_set:
                merged_defaults.add(app_uid)

    return candidates_by_uid, merged_defaults


def ordered_candidates(candidates: list[dict]) -> list[dict]:
    return sorted(candidates, key=lambda item: item["_source_order"])


def build_duplicate_report(candidates_by_uid: dict[str, list[dict]]) -> list[dict]:
    report: list[dict] = []
    for app_uid in sorted(candidates_by_uid):
        candidates = ordered_candidates(candidates_by_uid[app_uid])
        if len(candidates) <= 1:
            continue
        signatures = {candidate["_signature"] for candidate in candidates}
        report.append(
            {
                "app_uid": app_uid,
                "display_name": candidates[0]["display_name"],
                "definitions_identical": len(signatures) == 1,
                "candidates": [
                    {
                        "catalog_id": candidate["catalog_id"],
                        "catalog_name": candidate["catalog_name"],
                        "artifact_ref": candidate["artifact_ref"],
                        "artifact_digest": candidate["artifact_digest"],
                        "local_app_id": candidate["local_app_id"],
                        "display_name": candidate["display_name"],
                        "description": candidate["description"],
                        "default_selected": candidate["default_selected"],
                        "default_backend": candidate["default_backend"],
                        "resolved_images": candidate["_resolved_images"],
                    }
                    for candidate in candidates
                ],
            }
        )
    return report


def render_unresolved_duplicate_error(duplicate_report: list[dict]) -> str:
    lines = ["duplicate application source choices are required before catalogs can be merged:"]
    for item in duplicate_report:
        app_uid = str(item["app_uid"])
        available = ", ".join(
            f"{candidate['catalog_id']} ({candidate['catalog_name']})"
            for candidate in item["candidates"]
        )
        lines.append(f"  - {app_uid}: choose one of {available}")
    return "\n".join(lines)


def select_candidate_for_app(
    app_uid: str,
    candidates: list[dict],
    source_resolutions: dict[str, str],
    used_resolution_keys: set[str],
    canonical_source_positions: dict[tuple[str, str, str], int],
) -> tuple[dict, dict | None]:
    ordered = ordered_candidates(candidates)
    if len(ordered) == 1:
        return ordered[0], None

    selected_catalog_id = source_resolutions.get(app_uid, "").strip()
    if not selected_catalog_id:
        available = ", ".join(candidate["catalog_id"] for candidate in ordered)
        raise SystemExit(f"duplicate application source choice required for {app_uid}: choose one of {available}")

    chosen = None
    for candidate in ordered:
        if candidate["catalog_id"] == selected_catalog_id:
            chosen = candidate
            break
    if chosen is None:
        available = ", ".join(candidate["catalog_id"] for candidate in ordered)
        raise SystemExit(
            f"invalid source choice for {app_uid}: {selected_catalog_id!r}; expected one of {available}"
        )

    used_resolution_keys.add(app_uid)

    ordered_sources = sorted(ordered, key=lambda item: canonical_source_positions[canonical_source_key(item)])
    ordered_sources = [chosen] + [item for item in ordered_sources if item is not chosen]
    signatures = {candidate["_signature"] for candidate in ordered}
    conflict_record = {
        "type": "duplicate-app-source",
        "app_uid": app_uid,
        "selected_catalog_id": chosen["catalog_id"],
        "selected_catalog_name": chosen["catalog_name"],
        "available_catalog_ids": [candidate["catalog_id"] for candidate in ordered_sources],
        "available_catalog_names": [candidate["catalog_name"] for candidate in ordered_sources],
        "definitions_identical": len(signatures) == 1,
        "policy": "operator-selected-source",
    }
    return chosen, conflict_record


def build_merged_entries(
    candidates_by_uid: dict[str, list[dict]],
    merged_defaults: set[str],
    source_resolutions: dict[str, str],
    canonical_source_positions: dict[tuple[str, str, str], int],
) -> tuple[dict[str, dict], list[dict]]:
    merged_by_uid: dict[str, dict] = {}
    conflict_records: list[dict] = []
    used_resolution_keys: set[str] = set()

    for app_uid in sorted(candidates_by_uid):
        candidates = ordered_candidates(candidates_by_uid[app_uid])
        chosen, duplicate_record = select_candidate_for_app(
            app_uid,
            candidates,
            source_resolutions,
            used_resolution_keys,
            canonical_source_positions,
        )

        ordered_sources = sorted(candidates, key=lambda item: canonical_source_positions[canonical_source_key(item)])
        ordered_sources = [chosen] + [item for item in ordered_sources if item is not chosen]

        merged_by_uid[app_uid] = {
            "app_uid": app_uid,
            "id": app_uid,
            "local_app_id": chosen["local_app_id"],
            "display_name": chosen["display_name"],
            "description": chosen["description"],
            "renderer": chosen["renderer"],
            "service_name": chosen["service_name"],
            "service_port": chosen["service_port"],
            "host_template": chosen["host_template"],
            "path": chosen["path"],
            "expected_status": chosen["expected_status"],
            "body_marker": chosen["body_marker"],
            "route_description": chosen["route_description"],
            "default_backend": chosen["default_backend"],
            "image_names": [],
            "_resolved_images": chosen["_resolved_images"],
            "_source_order": chosen["_source_order"],
            "source_catalog_ids": [candidate["catalog_id"] for candidate in ordered_sources],
            "source_catalog_names": [candidate["catalog_name"] for candidate in ordered_sources],
            "source_artifact_refs": [candidate["artifact_ref"] for candidate in ordered_sources],
            "source_artifact_digests": [candidate["artifact_digest"] for candidate in ordered_sources],
            "selected_source_catalog_id": chosen["catalog_id"],
            "selected_source_catalog_name": chosen["catalog_name"],
        }
        if duplicate_record is not None:
            conflict_records.append(duplicate_record)

    unused_resolution_keys = sorted(set(source_resolutions) - used_resolution_keys)
    if unused_resolution_keys:
        raise SystemExit(
            "source choices were provided for apps that are not duplicated in the selected catalogs: "
            + ", ".join(unused_resolution_keys)
        )

    default_backend_entries = [
        (app_uid, merged_by_uid[app_uid])
        for app_uid in merged_by_uid
        if merged_by_uid[app_uid]["default_backend"]
    ]
    if len(default_backend_entries) > 1:
        default_backend_entries.sort(key=lambda item: item[1]["_source_order"])
        kept_app_uid, kept_entry = default_backend_entries[0]
        for app_uid, entry in default_backend_entries[1:]:
            entry["default_backend"] = False
            conflict_records.append(
                {
                    "type": "default-backend",
                    "app_uid": app_uid,
                    "kept_app_uid": kept_app_uid,
                    "kept_catalog_id": kept_entry["source_catalog_ids"][0],
                    "dropped_catalog_id": entry["source_catalog_ids"][0],
                    "policy": "first-selected-default-backend-wins",
                }
            )

    if not merged_defaults:
        raise SystemExit("merged catalogs produced an empty default app set")

    return merged_by_uid, conflict_records


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Merge one or more application catalogs into a host-selected effective catalog."
    )
    parser.add_argument("--sources-json", required=True)
    parser.add_argument("--analysis-only", action="store_true")
    parser.add_argument("--selection-mode", choices=["catalog-defaults", "all-apps", "custom"], default="catalog-defaults")
    parser.add_argument("--selected-app-ids", default="")
    parser.add_argument("--source-resolutions-json", default="{}")
    parser.add_argument("--out-duplicates")
    parser.add_argument("--out-catalog")
    parser.add_argument("--out-selected-apps")
    parser.add_argument("--out-images-lock")
    parser.add_argument("--out-summary")
    args = parser.parse_args()

    sources_path = Path(args.sources_json).resolve()
    sources = load_json(sources_path)
    if not isinstance(sources, list) or not sources:
        raise SystemExit(f"{sources_path} must declare a non-empty source catalog list")

    canonical_source_catalogs, canonical_source_positions = build_source_catalogs(sources)
    candidates_by_uid, merged_defaults = build_candidate_records(sources)
    duplicate_report = build_duplicate_report(candidates_by_uid)
    if args.out_duplicates:
        Path(args.out_duplicates).write_text(json.dumps(duplicate_report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    if args.analysis_only:
        if not args.out_duplicates:
            print(json.dumps(duplicate_report, indent=2, sort_keys=True))
        return 0

    if not args.out_catalog or not args.out_selected_apps or not args.out_images_lock or not args.out_summary:
        raise SystemExit("merge mode requires --out-catalog, --out-selected-apps, --out-images-lock, and --out-summary")

    source_resolutions = parse_source_resolutions(args.source_resolutions_json)
    unresolved_duplicates = [
        item for item in duplicate_report if str(item["app_uid"]) not in source_resolutions
    ]
    if unresolved_duplicates:
        raise SystemExit(render_unresolved_duplicate_error(unresolved_duplicates))

    merged_by_uid, conflict_records = build_merged_entries(
        candidates_by_uid,
        merged_defaults,
        source_resolutions,
        canonical_source_positions,
    )

    all_app_uids = sorted(merged_by_uid)
    merged_defaults_list = [app_uid for app_uid in all_app_uids if app_uid in merged_defaults]
    if args.selection_mode == "catalog-defaults":
        selected_app_ids = list(merged_defaults_list)
    elif args.selection_mode == "all-apps":
        selected_app_ids = list(all_app_uids)
    else:
        raw_ids = [item.strip() for item in args.selected_app_ids.split(",") if item.strip()]
        if not raw_ids:
            raise SystemExit("custom selection mode requires --selected-app-ids")
        selected_app_ids = []
        seen_ids: set[str] = set()
        known_ids = set(all_app_uids)
        for app_uid in raw_ids:
            if app_uid in seen_ids:
                raise SystemExit(f"duplicate selected app id {app_uid}")
            if app_uid not in known_ids:
                raise SystemExit(f"unknown selected app id {app_uid}")
            seen_ids.add(app_uid)
            selected_app_ids.append(app_uid)

    merged_image_entries: list[dict] = []
    ref_to_name: dict[str, str] = {}
    for app_uid in selected_app_ids:
        app = merged_by_uid[app_uid]
        rewritten_names: list[str] = []
        for image_index, resolved_image in enumerate(app["_resolved_images"], start=1):
            image_ref = resolved_image["ref"]
            merged_name = ref_to_name.get(image_ref)
            if not merged_name:
                base_name = sanitize_token(app_uid.replace("/", "--"))
                suffix = sanitize_token(resolved_image["name"])
                merged_name = f"{base_name}--{suffix}" if suffix and suffix != base_name else base_name
                if image_index > 1 and merged_name in {entry["name"] for entry in merged_image_entries}:
                    merged_name = f"{merged_name}-{image_index}"
                while merged_name in {entry["name"] for entry in merged_image_entries}:
                    merged_name = f"{merged_name}-x"
                ref_to_name[image_ref] = merged_name
                merged_image_entries.append(
                    {
                        "name": merged_name,
                        "ref": image_ref,
                        "used_by": [app_uid],
                    }
                )
            else:
                for image_entry in merged_image_entries:
                    if image_entry["name"] == merged_name and app_uid not in image_entry["used_by"]:
                        image_entry["used_by"].append(app_uid)
                        break
            rewritten_names.append(merged_name)
        app["image_names"] = rewritten_names

    source_catalogs = canonical_source_catalogs
    if len(source_catalogs) == 1:
        merged_catalog_id = source_catalogs[0]["catalog_id"]
        merged_catalog_name = source_catalogs[0]["catalog_name"]
    else:
        merged_catalog_id = "merged--" + "--".join(sanitize_token(item["catalog_id"]) for item in source_catalogs)
        merged_catalog_name = "Merged Application Catalog"

    merged_catalog = {
        "schema": 1,
        "kind": "ourbox-application-catalog",
        "catalog_id": merged_catalog_id,
        "catalog_name": merged_catalog_name,
        "catalog_description": "Host-merged application catalog assembled from the selected source catalogs.",
        "default_app_ids": merged_defaults_list,
        "source_catalogs": source_catalogs,
        "apps": [
            {key: value for key, value in merged_by_uid[app_uid].items() if not key.startswith("_")}
            for app_uid in all_app_uids
        ],
    }

    selected_apps = {
        "schema": 1,
        "kind": "ourbox-selected-applications",
        "catalog_id": merged_catalog_id,
        "catalog_name": merged_catalog_name,
        "selection_mode": args.selection_mode,
        "selected_app_ids": selected_app_ids,
        "source_catalogs": source_catalogs,
        "source_resolutions": {
            app_uid: source_resolutions[app_uid] for app_uid in sorted(source_resolutions)
        },
    }

    merged_images_lock = {
        "schema": 1,
        "profile": "host-selected-apps",
        "images": merged_image_entries,
    }

    conflict_records.sort(
        key=lambda item: (
            str(item.get("app_uid", "")),
            str(item.get("selected_catalog_id", item.get("kept_catalog_id", ""))),
            str(item.get("dropped_catalog_id", "")),
        )
    )
    summary = {
        "merged_catalog_id": merged_catalog_id,
        "merged_catalog_name": merged_catalog_name,
        "default_app_ids": merged_defaults_list,
        "all_app_ids": all_app_uids,
        "selected_app_ids": selected_app_ids,
        "source_catalogs": source_catalogs,
        "source_resolutions": {
            app_uid: source_resolutions[app_uid] for app_uid in sorted(source_resolutions)
        },
        "duplicate_apps": duplicate_report,
        "conflicts": conflict_records,
    }

    Path(args.out_catalog).write_text(json.dumps(merged_catalog, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    Path(args.out_selected_apps).write_text(json.dumps(selected_apps, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    Path(args.out_images_lock).write_text(json.dumps(merged_images_lock, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    Path(args.out_summary).write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
