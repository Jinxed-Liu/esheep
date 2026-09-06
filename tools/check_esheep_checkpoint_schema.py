#!/usr/bin/env python3
"""Fail the static build gate when a current model is not explicitly classified.

Runtime metadata tests additionally verify SwiftData's exact stored fields.
This source check is intentionally independent of the generated Swift registry.
"""
import json
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
registry = json.loads((root / 'tools/esheep_cloud_checkpoint_schema_v1.json').read_text())
models = {}
for path in (root / 'eSheepNext/Models').glob('*.swift'):
    source = path.read_text()
    for match in re.finditer(r'@Model\s+(?:final\s+)?class\s+(\w+)\s*\{', source):
        start, depth, end = match.end(), 1, match.end()
        # Strip comments and string contents before looking for braces.
        body = source[start:]
        body = re.sub(r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"', '', body, flags=re.S)
        lines, stored = [], {}
        for line in body.splitlines():
            if depth == 1:
                field = re.search(r'\bvar\s+(\w+)\s*:\s*([\w\[\]:<>?., ]+?)(?:\s*=|\s*\{|\s*$)', line)
                if field and '{' not in line and '@Transient' not in line:
                    stored[field[1]] = field[2].strip()
            depth += line.count('{') - line.count('}')
            if depth <= 0:
                break
        models[match[1]] = stored
errors = []
if set(models) != set(registry):
    errors.append(f'model registration changed: missing={sorted(set(models)-set(registry))}, obsolete={sorted(set(registry)-set(models))}')
for name, fields in models.items():
    known = registry.get(name, {})
    if known.get('disposition') not in ('transfer', 'rebuild', 'localOnly'):
        errors.append(f'{name}: missing disposition')
    if fields != known.get('fields'):
        errors.append(f'{name}: stored fields differ from reviewed checkpoint schema')
if errors:
    print('\n'.join(errors), file=sys.stderr)
    sys.exit(1)
print(f'Checkpoint schema: {len(models)} models explicitly classified; source fields match')
