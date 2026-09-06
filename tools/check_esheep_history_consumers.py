#!/usr/bin/env python3
"""Keep persistent-history retention closed to untracked application consumers.

The current app has no persistent-history readers. A future consumer must add
its durable position and a runtime pruning guard before this gate is extended.
This check never opens a database or deletes history.
"""
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
readers = []
pruners = []
for directory in (ROOT / 'eSheepNext', ROOT / 'eSheepNextWidget'):
    for path in directory.rglob('*.swift'):
        source = path.read_text()
        # Check API spellings as well as function references passed as values.
        if re.search(r'\b(fetchHistory|NSPersistentHistoryChangeRequest|NSPersistentHistoryToken)\b', source):
            readers.append(str(path.relative_to(ROOT)))
        if re.search(r'\bdeleteHistory\s*\(', source):
            pruners.append(str(path.relative_to(ROOT)))

expected_pruner = 'eSheepNext/Services/LocalStorageOptimizationService.swift'
passed = not readers and pruners == [expected_pruner]
report = dict(passed=passed, applicationHistoryConsumers=readers,
              pruningEntrypoints=pruners, databaseMutated=False,
              policy='Existing retention only; new history readers require durable consumer positions and pruning guards.')
print(json.dumps(report, ensure_ascii=False))
if not passed:
    sys.exit('Persistent-history consumer/pruner changed. Implement and verify consumer-position retention before release.')
