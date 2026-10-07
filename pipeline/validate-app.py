#!/usr/bin/env python3
"""Validate app.yaml against the JSON schema; print it as JSON on success.

usage: validate-app.py <app.yaml> <app.schema.json>
exit 0 valid, 1 invalid (messages on stderr), 2 usage/dependency error
"""
import json
import sys

try:
    import yaml
    import jsonschema
except ImportError as e:  # pragma: no cover
    print(f"missing python module: {e.name} (install python3-yaml and python3-jsonschema)", file=sys.stderr)
    sys.exit(2)

if len(sys.argv) != 3:
    print(__doc__, file=sys.stderr)
    sys.exit(2)

app_path, schema_path = sys.argv[1], sys.argv[2]
try:
    with open(app_path) as f:
        data = yaml.safe_load(f)
except FileNotFoundError:
    print(f"{app_path}: not found (the app must contain app.yaml, see CONTRACT.md)", file=sys.stderr)
    sys.exit(1)
except yaml.YAMLError as e:
    print(f"{app_path}: invalid YAML: {e}", file=sys.stderr)
    sys.exit(1)

with open(schema_path) as f:
    schema = json.load(f)

errors = sorted(jsonschema.Draft7Validator(schema).iter_errors(data), key=lambda e: list(e.path))
if errors:
    for e in errors:
        where = "/".join(str(p) for p in e.path) or "<root>"
        print(f"{app_path}: {where}: {e.message}", file=sys.stderr)
    sys.exit(1)

json.dump(data, sys.stdout)
