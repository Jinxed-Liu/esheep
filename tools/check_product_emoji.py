#!/usr/bin/env python3
"""Reject Emoji in developer-authored product content and test fixtures."""

from __future__ import annotations

import argparse
import pathlib
import re
import sys

SCANNED_EXTENSIONS = {".swift", ".strings", ".stringsdict", ".json", ".plist", ".md", ".csv", ".yaml", ".yml"}
SKIPPED_PARTS = {".git", "backups", "DerivedData", ".build"}
EMOJI = re.compile(
    "["
    "\\U0001F000-\\U0001FAFF"
    "\\U0001FC00-\\U0001FFFD"
    "\\U0001F1E6-\\U0001F1FF"
    "\\u2600-\\u27BF"
    "\\u2300-\\u23FF"
    "\\u2B00-\\u2BFF"
    "\\uFE0F\\u200D"
    "]"
)


def candidate_files(root: pathlib.Path) -> list[pathlib.Path]:
    return [
        path
        for path in root.rglob("*")
        if path.is_file()
        and path.suffix.lower() in SCANNED_EXTENSIONS
        and not any(part in SKIPPED_PARTS for part in path.parts)
    ]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("paths", nargs="+", type=pathlib.Path)
    args = parser.parse_args()
    violations: list[str] = []
    for root in args.paths:
        for path in candidate_files(root):
            try:
                text = path.read_text(encoding="utf-8")
            except UnicodeDecodeError:
                continue
            for line_number, line in enumerate(text.splitlines(), start=1):
                if EMOJI.search(line):
                    violations.append(f"{path}:{line_number}: {line.strip()}")
    if violations:
        print("Developer-authored product content must not contain Emoji:", file=sys.stderr)
        print("\n".join(violations), file=sys.stderr)
        return 1
    print("Emoji scan passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
