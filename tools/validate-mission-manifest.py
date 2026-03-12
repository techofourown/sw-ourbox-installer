#!/usr/bin/env python3
import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate a JSON instance against the mission schema subset used in this repo."
    )
    parser.add_argument("schema", help="Schema JSON path")
    parser.add_argument("instance", help="Instance JSON path")
    return parser.parse_args()


def fail(path: str, message: str) -> None:
    raise SystemExit(f"{path}: {message}")


def validate(instance: Any, schema: dict[str, Any], path: str) -> None:
    if "const" in schema and instance != schema["const"]:
        fail(path, f"expected constant {schema['const']!r}, got {instance!r}")

    expected_type = schema.get("type")
    if expected_type == "object":
        if not isinstance(instance, dict):
            fail(path, "expected object")
        required = schema.get("required", [])
        for key in required:
            if key not in instance:
                fail(path, f"missing required property {key!r}")
        properties = schema.get("properties", {})
        if schema.get("additionalProperties") is False:
            unexpected = sorted(set(instance) - set(properties))
            if unexpected:
                fail(path, f"unexpected properties: {', '.join(unexpected)}")
        for key, value in instance.items():
            if key in properties:
                validate(value, properties[key], f"{path}.{key}")
        return

    if expected_type == "array":
        if not isinstance(instance, list):
            fail(path, "expected array")
        item_schema = schema.get("items")
        if item_schema is not None:
            for index, item in enumerate(instance):
                validate(item, item_schema, f"{path}[{index}]")
        return

    if expected_type == "string":
        if not isinstance(instance, str):
            fail(path, "expected string")
        min_length = schema.get("minLength")
        if min_length is not None and len(instance) < min_length:
            fail(path, f"string shorter than minLength {min_length}")
        pattern = schema.get("pattern")
        if pattern is not None and re.search(pattern, instance) is None:
            fail(path, f"string does not match pattern {pattern!r}")
        return

    if expected_type == "integer":
        if not isinstance(instance, int) or isinstance(instance, bool):
            fail(path, "expected integer")
        minimum = schema.get("minimum")
        if minimum is not None and instance < minimum:
            fail(path, f"value below minimum {minimum}")
        return

    if expected_type == "boolean":
        if not isinstance(instance, bool):
            fail(path, "expected boolean")
        return

    if expected_type is not None:
        fail(path, f"unsupported schema type {expected_type!r}")


def main() -> int:
    args = parse_args()
    schema_path = Path(args.schema)
    instance_path = Path(args.instance)

    with schema_path.open("r", encoding="utf-8") as handle:
        schema = json.load(handle)
    with instance_path.open("r", encoding="utf-8") as handle:
        instance = json.load(handle)

    validate(instance, schema, "$")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
