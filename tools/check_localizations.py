#!/usr/bin/env python3
"""Fail release verification when String Catalog coverage is incomplete."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


PLACEHOLDER = re.compile(r"%(?:\d+\$)?(?:lld|ld|d|@|f|%)")


def placeholders(value: str) -> list[str]:
    return [re.sub(r"%\d+\$", "%", item) for item in PLACEHOLDER.findall(value)]


def validate(path: Path) -> list[str]:
    catalog = json.loads(path.read_text(encoding="utf-8"))
    errors: list[str] = []
    for key, entry in catalog.get("strings", {}).items():
        if not key.strip() or entry.get("shouldTranslate") is False:
            continue
        english = entry.get("localizations", {}).get("en", {}).get("stringUnit", {})
        value = english.get("value", "").strip()
        if not value:
            errors.append(f"{path}: missing en translation: {key!r}")
            continue
        if placeholders(key) != placeholders(value):
            errors.append(
                f"{path}: placeholder mismatch: {key!r} -> {value!r}"
            )
    return errors


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    paths = [
        root / "eSheepNext" / "Localizable.xcstrings",
        root / "eSheepNextWidget" / "Localizable.xcstrings",
    ]
    errors = [error for path in paths for error in validate(path)]
    if errors:
        for error in errors[:200]:
            print(error, file=sys.stderr)
        if len(errors) > 200:
            print(f"... and {len(errors) - 200} more", file=sys.stderr)
        print(f"Localization gate failed with {len(errors)} issue(s).", file=sys.stderr)
        return 1
    print("Localization gate passed: zh-Hans and en catalogs are complete.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
