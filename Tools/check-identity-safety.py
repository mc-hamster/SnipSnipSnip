#!/usr/bin/env python3
"""Prevent duplicate-key trapping dictionary constructors in production Swift."""

import argparse
from pathlib import Path
import re
import sys


TRAPPING_LABEL = re.compile(r"\buniqueKeysWithValues\s*:")
REPOSITORY = Path(__file__).resolve().parent.parent
SOURCE_ROOTS = ("SnipSnipSnip", "SnipSnipSnipCLI", "SnipSnipSnipShareExtension")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", action="append", type=Path,
                        help="Override production source roots; may be repeated.")
    args = parser.parse_args()
    roots = args.source_root or [REPOSITORY / name for name in SOURCE_ROOTS]
    failures = []
    for root in roots:
        if not root.is_dir():
            failures.append(f"{root}: source directory is missing")
            continue
        for path in sorted(root.rglob("*.swift")):
            source = path.read_text(encoding="utf-8")
            # Intentionally conservative token check: also covers generic and
            # inferred .init constructors without maintaining a Swift parser.
            for match in TRAPPING_LABEL.finditer(source):
                line = source.count("\n", 0, match.start()) + 1
                failures.append(f"{path}:{line}: duplicate-key trapping constructor")
    if failures:
        print("\n".join(failures), file=sys.stderr)
        print("Use an explicit duplicate-key policy for derived lookups. "
              "Reject conflicting document identities at the shared validation "
              "boundary; do not silently discard content.", file=sys.stderr)
        return 1
    print("Identity safety check passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
