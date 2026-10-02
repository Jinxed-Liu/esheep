#!/usr/bin/env python3
"""Parse changed Swift sources using an actual Swift compiler, without an SDK.

This is a syntax check only. It does not type-check SwiftUI, SwiftData, UIKit,
target availability, signing, or runtime behavior and never replaces iOS gates.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys


def changed_sources(root: Path) -> list[Path]:
    names: set[str] = set()
    for command in (
        ["git", "diff", "--name-only", "--diff-filter=ACMR", "-z", "HEAD"],
        ["git", "ls-files", "--others", "--exclude-standard", "-z"],
    ):
        output = subprocess.check_output(command, cwd=root)
        names.update(os.fsdecode(name) for name in output.split(b"\0") if name)
    return sorted(
        root / name
        for name in names
        if name.endswith(".swift") and (root / name).is_file()
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--swiftc", default=os.environ.get("SWIFTC", "swiftc"),
        help="Swift compiler executable; defaults to SWIFTC or swiftc on PATH",
    )
    parser.add_argument("files", nargs="*", help="Optional explicit Swift files")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    compiler = shutil.which(args.swiftc)
    if compiler is None:
        print("Swift syntax check unavailable: no Swift compiler found.", file=sys.stderr)
        return 2
    try:
        sources = (
            [Path(file).resolve() for file in args.files]
            if args.files else changed_sources(root)
        )
    except subprocess.CalledProcessError as error:
        print(f"Cannot enumerate changed sources: git exited {error.returncode}.", file=sys.stderr)
        return 2
    if not sources:
        print("Swift syntax check: no changed Swift sources.")
        return 0
    missing = [str(source) for source in sources if not source.is_file()]
    if missing:
        print("Missing source files: " + ", ".join(missing), file=sys.stderr)
        return 2
    result = subprocess.run(
        [compiler, "-frontend", "-parse", *(str(source) for source in sources)],
        cwd=root,
    )
    if result.returncode:
        print("Swift syntax check failed.", file=sys.stderr)
        return result.returncode
    print(f"Swift syntax check passed: {len(sources)} sources; iOS type-check/build not performed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
