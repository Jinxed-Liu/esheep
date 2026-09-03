#!/usr/bin/env python3
"""Fail CI when V2 leaks provider SDKs or internal sync jargon into its UI."""

from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
V2_ROOT = ROOT / "eSheepNext" / "Services" / "ESheepCloud"
INFRASTRUCTURE = V2_ROOT / "Infrastructure"
MIGRATION_READER = V2_ROOT / "ESheepCloudMigrationCoordinator.swift"
UI_FILES = (
    ROOT / "eSheepNext" / "Features" / "Account" / "ESheepCloudCenterView.swift",
    ROOT / "eSheepNext" / "Features" / "Collaboration" / "SupabaseFarmSharingView.swift",
    ROOT / "eSheepNext" / "Features" / "Account" / "SupabaseFarmRestoreProgressView.swift",
)
FORBIDDEN_UI_WORDS = (
    "Supabase",
    "Revision",
    "Cursor",
    "Outbox",
    "Checkpoint",
    "Baseline",
    "Projection",
    "同步冲突",
)
STRING_LITERAL = re.compile(r'"(?:\\.|[^"\\])*"')
FORBIDDEN_V1_RUNTIME_SYMBOLS = (
    "CloudOperationEnvelope",
    "RemoteDomainApplyService",
    "FarmRemoteSyncCoordinator",
    "FarmCommandCloudPayload",
    "OutboxItem",
    "SyncConflictRecord",
    "baseRevision",
)


def report(path: Path, line_number: int, message: str) -> None:
    relative = path.relative_to(ROOT)
    print(f"{relative}:{line_number}: {message}", file=sys.stderr)


def check_domain_boundary() -> int:
    failures = 0
    for path in sorted(V2_ROOT.rglob("*.swift")):
        if INFRASTRUCTURE in path.parents:
            continue
        for line_number, line in enumerate(path.read_text().splitlines(), 1):
            if re.search(r"\b(?:import|@_exported\s+import)\s+Supabase\b", line):
                report(path, line_number, "provider SDK import escaped Infrastructure")
                failures += 1
            if re.search(r"\bSupabase(?:Client|Error|Response|Query|Storage)\b", line):
                report(path, line_number, "provider SDK type escaped Infrastructure")
                failures += 1
    return failures


def check_v1_runtime_boundary() -> int:
    """V1 persistence is readable only by the one-way migration reader."""
    failures = 0
    for path in sorted(V2_ROOT.rglob("*.swift")):
        if path == MIGRATION_READER:
            continue
        for line_number, line in enumerate(path.read_text().splitlines(), 1):
            for symbol in FORBIDDEN_V1_RUNTIME_SYMBOLS:
                if re.search(rf"\b{re.escape(symbol)}\b", line):
                    report(
                        path,
                        line_number,
                        f"V1 sync symbol {symbol!r} escaped the migration reader",
                    )
                    failures += 1
    return failures


def check_user_strings() -> int:
    failures = 0
    for path in UI_FILES:
        for line_number, line in enumerate(path.read_text().splitlines(), 1):
            for literal in STRING_LITERAL.findall(line):
                # Old invitations remain decode-only by contract and are never
                # rendered or generated, so this exact compatibility token is safe.
                if literal == '"supabase-invite"':
                    continue
                for word in FORBIDDEN_UI_WORDS:
                    if word.lower() in literal.lower():
                        report(
                            path,
                            line_number,
                            f"V2 user-facing string contains forbidden term {word!r}",
                        )
                        failures += 1
    return failures


def main() -> int:
    failures = (
        check_domain_boundary()
        + check_v1_runtime_boundary()
        + check_user_strings()
    )
    if failures:
        print(f"eSheep+ Cloud brand boundary failed with {failures} issue(s).", file=sys.stderr)
        return 1
    print("eSheep+ Cloud brand and provider boundary: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
