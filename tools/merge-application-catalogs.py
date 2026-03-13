#!/usr/bin/env python3
import argparse
import json
import re
from pathlib import Path


def sanitize_token(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-") or "app"


def load_json(path: Path) -> dict:
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


def main() -> int:
    parser = argparse.ArgumentParser(description="Merge one or more application catalogs into a host-selected effective catalog.")
    parser.add_argument("--sources-json", required=True)
    parser.add_argument("--selection-mode", required=True, choices=["catalog-defaults", "all-apps", "custom"])
    parser.add_argument("--selected-app-ids", default="")
    parser.add_argument("--out-catalog", required=True)
    parser.add_argument("--out-selected-apps", required=True)
    parser.add_argument("--out-images-lock", required=True)
    parser.add_argument("--out-summary", required=True)
    args = parser.parse_args()

    sources_path = Path(args.sources_json).resolve()
    sources = load_json(sources_path)
    if not isinstance(sources, list) or not sources:
        raise SystemExit(f"{sources_path} must declare a non-empty source catalog list")

    merged_by_uid: dict[str, dict] = {}
    ordered_uids: list[str] = []
    merged_defaults: list[str] = []
    conflict_records: list[dict] = []

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

        for app_index, raw_app in enumerate(catalog["apps"]):
            app = dict(raw_app)
            local_app_id = str(app["id"]).strip()
            app_uid = canonical_app_uid(source, app)
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

            source_meta = {
                "catalog_id": str(catalog["catalog_id"]),
                "catalog_name": str(catalog["catalog_name"]),
                "artifact_ref": artifact_ref,
                "artifact_digest": artifact_digest,
            }
            signature = app_signature(app, resolved_images)

            merged_entry = {
                "app_uid": app_uid,
                "id": app_uid,
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
                "image_names": [],
                "_resolved_images": resolved_images,
                "_signature": signature,
                "_source_order": (source_index, app_index),
                "source_catalog_ids": [source_meta["catalog_id"]],
                "source_catalog_names": [source_meta["catalog_name"]],
                "source_artifact_refs": [source_meta["artifact_ref"]],
                "source_artifact_digests": [source_meta["artifact_digest"]],
            }

            if app_uid not in merged_by_uid:
                merged_by_uid[app_uid] = merged_entry
                ordered_uids.append(app_uid)
            else:
                existing = merged_by_uid[app_uid]
                if existing["_signature"] == signature:
                    for field_name, field_value in (
                        ("source_catalog_ids", source_meta["catalog_id"]),
                        ("source_catalog_names", source_meta["catalog_name"]),
                        ("source_artifact_refs", source_meta["artifact_ref"]),
                        ("source_artifact_digests", source_meta["artifact_digest"]),
                    ):
                        if field_value not in existing[field_name]:
                            existing[field_name].append(field_value)
                else:
                    conflict_records.append(
                        {
                            "app_uid": app_uid,
                            "kept_catalog_id": existing["source_catalog_ids"][0],
                            "dropped_catalog_id": source_meta["catalog_id"],
                            "policy": "first-selected-source-wins",
                        }
                    )
            if local_app_id in defaults_set and app_uid not in merged_defaults:
                merged_defaults.append(app_uid)

    if not merged_defaults:
        raise SystemExit("merged catalogs produced an empty default app set")

    all_app_uids = ordered_uids
    if args.selection_mode == "catalog-defaults":
        selected_app_ids = list(merged_defaults)
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

    source_catalogs = [
        {
            "catalog_id": str(source["catalog_id"]),
            "catalog_name": str(source["catalog_name"]),
            "artifact_ref": str(source["artifact_ref"]),
            "artifact_digest": str(source["artifact_digest"]),
        }
        for source in sources
    ]
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
        "default_app_ids": merged_defaults,
        "source_catalogs": source_catalogs,
        "apps": [
            {
                key: value
                for key, value in merged_by_uid[app_uid].items()
                if not key.startswith("_")
            }
            for app_uid in ordered_uids
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
    }

    merged_images_lock = {
        "schema": 1,
        "profile": "host-selected-apps",
        "images": merged_image_entries,
    }

    summary = {
        "merged_catalog_id": merged_catalog_id,
        "merged_catalog_name": merged_catalog_name,
        "default_app_ids": merged_defaults,
        "all_app_ids": all_app_uids,
        "selected_app_ids": selected_app_ids,
        "source_catalogs": source_catalogs,
        "conflicts": conflict_records,
    }

    Path(args.out_catalog).write_text(json.dumps(merged_catalog, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    Path(args.out_selected_apps).write_text(json.dumps(selected_apps, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    Path(args.out_images_lock).write_text(json.dumps(merged_images_lock, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    Path(args.out_summary).write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
