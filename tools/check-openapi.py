#!/usr/bin/env python3
"""Check docs/openapi.yaml against the committed fixtures.

The spec claims a shape for every request type. Every claim is checked here
against a real captured response, so the file stays documentation of what the
server does rather than of what we think it does.

Each response in the spec carries `x-fixtures`, naming the captures it was
read from. This script validates each of those files against that response's
schema, and reports:

  * schema violations                -- the spec is wrong, or the server changed
  * fields in a capture that the spec does not describe  -- the spec is behind
  * fixtures no response claims      -- a capture nobody documented

Needs PyYAML. Everything else is stdlib: the JSON Schema subset used by the
spec ($ref, type, properties, required, items, oneOf, allOf, enum, const,
pattern, minimum, maxItems, additionalProperties: false/true) is checked by the
~90 lines below rather than by a dependency.

Usage: tools/check-openapi.py [--spec docs/openapi.yaml] [--fixtures fixtures]
"""

import argparse
import json
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("needs PyYAML: apt install python3-yaml (or pip install pyyaml)")

TYPES = {
    "object": dict, "array": list, "string": str,
    "number": (int, float), "integer": int, "boolean": bool, "null": type(None),
}


def resolve(doc, ref):
    node = doc
    for part in ref.lstrip("#/").split("/"):
        node = node[part.replace("~1", "/").replace("~0", "~")]
    return node


def check(doc, schema, value, path="$", errors=None, undocumented=None):
    """Validate `value` against `schema`. Returns the error list."""
    errors = errors if errors is not None else []
    undocumented = undocumented if undocumented is not None else set()

    if "$ref" in schema:
        return check(doc, resolve(doc, schema["$ref"]), value, path,
                     errors, undocumented)

    def bad(msg):
        errors.append(f"{path}: {msg}")

    if "allOf" in schema:
        for sub in schema["allOf"]:
            check(doc, sub, value, path, errors, undocumented)

    if "oneOf" in schema:
        matched = None
        for sub in schema["oneOf"]:
            if not check(doc, sub, value, path, [], set()):
                matched = sub
                break
        if matched is None:
            bad(f"matches none of the {len(schema['oneOf'])} allowed shapes: "
                f"{json.dumps(value)[:120]}")
        else:
            check(doc, matched, value, path, errors, undocumented)
        return errors

    t = schema.get("type")
    if t:
        expected = TYPES[t]
        # JSON booleans are not integers, whatever Python thinks.
        if isinstance(value, bool) and t in ("integer", "number"):
            bad(f"expected {t}, got boolean")
            return errors
        if not isinstance(value, expected):
            bad(f"expected {t}, got {type(value).__name__}: "
                f"{json.dumps(value)[:80]}")
            return errors

    if "const" in schema and value != schema["const"]:
        bad(f"expected const {schema['const']!r}, got {value!r}")
    if "enum" in schema and value not in schema["enum"]:
        bad(f"{value!r} not in {schema['enum']}")
    if "pattern" in schema and isinstance(value, str):
        if not re.search(schema["pattern"], value):
            bad(f"{value!r} does not match /{schema['pattern']}/")
    if "minimum" in schema and isinstance(value, (int, float)):
        if value < schema["minimum"]:
            bad(f"{value} < minimum {schema['minimum']}")
    if "maxItems" in schema and isinstance(value, list):
        if len(value) > schema["maxItems"]:
            bad(f"{len(value)} items > maxItems {schema['maxItems']}")

    if isinstance(value, dict):
        props = schema.get("properties", {})
        for key in schema.get("required", []):
            if key not in value:
                bad(f"missing required property {key!r}")
        if schema.get("additionalProperties") is False:
            for key in value:
                if key not in props:
                    bad(f"unexpected property {key!r}")
        elif props and schema.get("additionalProperties") is not True:
            for key in value:
                if key not in props:
                    undocumented.add(f"{path}.{key}")
        for key, sub in props.items():
            if key in value:
                check(doc, sub, value[key], f"{path}.{key}", errors, undocumented)

    if isinstance(value, list) and "items" in schema:
        for i, item in enumerate(value):
            check(doc, schema["items"], item, f"{path}[{i}]", errors, undocumented)

    return errors


def main():
    here = Path(__file__).resolve().parent.parent
    ap = argparse.ArgumentParser()
    ap.add_argument("--spec", type=Path, default=here / "docs/openapi.yaml")
    ap.add_argument("--fixtures", type=Path, default=here / "fixtures")
    args = ap.parse_args()

    doc = yaml.safe_load(args.spec.read_text())

    checked, failures, claimed = 0, 0, set()
    warnings = []

    for path, item in doc["paths"].items():
        for method, op in item.items():
            if method not in ("get", "post"):
                continue
            for status, response in op.get("responses", {}).items():
                names = response.get("x-fixtures", [])
                if not names:
                    continue
                schema = (response.get("content", {})
                          .get("application/json", {}).get("schema"))
                if schema is None:
                    print(f"FAIL {op['operationId']} {status}: "
                          f"x-fixtures on a response with no JSON schema")
                    failures += 1
                    continue
                for name in names:
                    claimed.add(name)
                    f = args.fixtures / name
                    if not f.exists():
                        print(f"FAIL {op['operationId']}: missing fixture {name}")
                        failures += 1
                        continue
                    value = json.loads(f.read_text())
                    undocumented = set()
                    errors = check(doc, schema, value,
                                   undocumented=undocumented)
                    checked += 1
                    if errors:
                        failures += 1
                        print(f"FAIL {name}  ({op['operationId']})")
                        for e in errors[:10]:
                            print(f"       {e}")
                        if len(errors) > 10:
                            print(f"       ... and {len(errors) - 10} more")
                    else:
                        print(f"ok   {name}  ({op['operationId']})")
                    for u in sorted(undocumented):
                        warnings.append(f"{name}: {u} is not in the spec")

    unclaimed = sorted(p.name for p in args.fixtures.glob("*.json")
                       if p.name not in claimed)
    for name in unclaimed:
        warnings.append(f"{name}: no response claims this fixture")

    print(f"\n{checked} fixture(s) checked against the spec, {failures} failed")
    for w in warnings:
        print(f"warn {w}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
