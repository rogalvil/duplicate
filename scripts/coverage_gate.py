#!/usr/bin/env python3
"""Enforce a line-coverage floor over one source subtree.

Reads the JSON that `llvm-cov export -summary-only` writes and reports coverage for the
files under a given path prefix only. Scoping matters here: a whole-repo percentage would
be diluted by the AppKit glue -- windows, menus, panels, Quick Look -- which cannot run
without a window server and so never executes under test. Gating on the pure-logic target
keeps the number honest.

The prefix is matched as a substring, so a nested layout like
Sources/DuplicateCore/Hash/ContentHasher.swift still counts under the prefix
Sources/DuplicateCore.
"""

from __future__ import annotations

import argparse
import json
import sys


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("summary", help="path to the llvm-cov export JSON")
    parser.add_argument(
        "--prefix",
        required=True,
        help="only count files whose path contains this substring",
    )
    parser.add_argument(
        "--min",
        type=float,
        required=True,
        help="minimum line coverage percentage required to pass",
    )
    args = parser.parse_args()

    try:
        with open(args.summary, encoding="utf-8") as handle:
            report = json.load(handle)
    except (OSError, json.JSONDecodeError) as error:
        print(f"error: cannot read coverage summary {args.summary}: {error}", file=sys.stderr)
        return 2

    files = [
        entry
        for export in report.get("data", [])
        for entry in export.get("files", [])
        if args.prefix in entry.get("filename", "")
    ]

    if not files:
        print(
            f"error: no covered files matched prefix {args.prefix!r}.\n"
            "       Either the prefix is wrong or the test run produced no profile data.",
            file=sys.stderr,
        )
        return 2

    total = covered = 0
    rows = []
    for entry in sorted(files, key=lambda item: item["filename"]):
        lines = entry["summary"]["lines"]
        total += lines["count"]
        covered += lines["covered"]
        rows.append((entry["filename"].split(args.prefix, 1)[-1].lstrip("/"), lines))

    percent = 100.0 * covered / total if total else 0.0

    width = max(len(name) for name, _ in rows)
    print(f"Line coverage under {args.prefix}\n")
    for name, lines in rows:
        share = 100.0 * lines["covered"] / lines["count"] if lines["count"] else 0.0
        print(f"  {name:<{width}}  {lines['covered']:>5}/{lines['count']:<5}  {share:6.2f}%")
    print(f"\n  {'TOTAL':<{width}}  {covered:>5}/{total:<5}  {percent:6.2f}%")

    if percent + 1e-9 < args.min:
        print(f"\nFAIL: {percent:.2f}% is below the required {args.min:.2f}%", file=sys.stderr)
        return 1

    print(f"\nOK: {percent:.2f}% meets the required {args.min:.2f}%")
    return 0


if __name__ == "__main__":
    sys.exit(main())
