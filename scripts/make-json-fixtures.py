#!/usr/bin/env python3
"""Regenerate the JSON interop fixtures under Tests/DuplicateCoreTests/Fixtures/.

The fixtures are produced by the same call the CLI uses to save a scan --
`json.dumps(obj, indent=2) + "\\n"`, written as UTF-8 -- see
`src/rav/core/duplicates.py:107` in the rav CLI. That provenance is the point: the Swift
encoder is asserted byte-for-byte against files a Python `json.dumps` really wrote, so the
compatibility claim is a measurement and not an argument.

The content is synthetic on purpose. The user's real state directory holds private paths, and a
test fixture is a published file. Byte-compatibility is a property of the *format*, so synthetic
paths that exercise every escape rule prove it just as well. The real corpus is covered at runtime
instead, by `make selftest MODE=json-roundtrip ARGS="--file <path>"`.

Usage:
    python3 scripts/make-json-fixtures.py
"""

from __future__ import annotations

import json
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent.parent
OUT = HERE / "Tests" / "DuplicateCoreTests" / "Fixtures"

# A path with a precomposed a-acute (U+00E1) and one with the decomposed form
# (U+0061 U+0301). Both shapes occur in a single real scan file, because APFS preserves whatever
# bytes each writer used. Python treats them as different strings; Swift's String == does not.
PRECOMPOSED = "/Volumes/Disk/Suárez/clip.mp4"
DECOMPOSED = "/Volumes/Disk/Suárez/clip.mp4"

FIXTURES: dict[str, object] = {
    # A scan with no groups: proves the empty array stays inline as [].
    "scan-empty.json": {
        "scan_id": "20260511-102731-267798",
        "root": "/Volumes/Disk/Tmp",
        "created_at": "2026-05-11T10:27:31.267798Z",
        "groups": [],
    },
    # A scan with groups, nesting four levels deep, and both Unicode normalisation forms.
    "scan-groups.json": {
        "scan_id": "20260511-064716-685054",
        "root": "/Volumes/Disk/Tmp",
        "created_at": "2026-05-11T06:47:16.685054Z",
        "groups": [
            {
                "size": 496243319,
                "sha256": "e562f2d3dcdff32ae80ad07fbda639183b3311f7bf252f9c7506a6760b9f9046",
                "files": [PRECOMPOSED, DECOMPOSED],
            },
            {
                "size": 0,
                "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
                "files": [
                    "/Volumes/Disk/Tmp/\U0001f600 emoji.txt",
                    "/Volumes/Disk/Tmp/中文.txt",
                    '/Volumes/Disk/Tmp/quote".txt',
                    "/Volumes/Disk/Tmp/back\\slash.txt",
                    "/Volumes/Disk/Tmp/tab\there.txt",
                    "/Volumes/Disk/Tmp/slash/not/escaped.txt",
                ],
            },
        ],
    },
    # A folder scan: the only place a float appears in the shared format. similarity 1.0 must keep
    # its decimal point, and the long value is a real Dice result for 39 matching of 39 vs 40.
    "folder-scan.json": {
        "scan_id": "20260511-072142-823976",
        "root": "/Volumes/Disk/Tmp",
        "created_at": "2026-05-11T07:21:42.823976Z",
        "threshold": 0.9,
        "pairs": [
            {
                "folder_a": "/Volumes/Disk/Tmp/a",
                "folder_b": "/Volumes/Disk/Tmp/b",
                "similarity": 1.0,
                "matching": 12,
                "only_in_a": [],
                "only_in_b": [],
                "changed": [],
                "total_a": 12,
                "total_b": 12,
            },
            {
                "folder_a": "/Volumes/Disk/Tmp/c",
                "folder_b": "/Volumes/Disk/Tmp/d",
                "similarity": 0.9873417721518988,
                "matching": 39,
                "only_in_a": [],
                "only_in_b": ["extra.txt"],
                "changed": ["changed.txt"],
                "total_a": 39,
                "total_b": 40,
            },
        ],
    },
    # Decisions use a wrapper object, and the group key is "<size>:<sha256>".
    "decisions-wrapped.json": {
        "scan_id": "20260511-064716-685054",
        "created_at": "2026-05-11T06:50:00.000001Z",
        "decisions": {
            "496243319:e562f2d3dcdff32ae80ad07fbda639183b3311f7bf252f9c7506a6760b9f9046": [
                PRECOMPOSED
            ],
            "0:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855": [],
        },
    },
    # Similar-decisions have NO wrapper: a bare map from "<file_a>||<file_b>" to a verdict.
    # One type cannot honestly represent both shapes, which is why there are two stores.
    "similar-decisions-bare.json": {
        "/Volumes/Disk/a.mp4||/Volumes/Disk/b.mp4": "keep_a",
        "/Volumes/Disk/c.jpg||/Volumes/Disk/d.jpg": "keep_both",
    },
    # Every escape rule in one document, including the ones a hand-written encoder gets wrong.
    "escapes.json": {
        "quote": '"',
        "backslash": "\\",
        "slash_not_escaped": "/",
        "newline": "\n",
        "carriage_return": "\r",
        "tab": "\t",
        "backspace": "\x08",
        "form_feed": "\x0c",
        "control_01": "\x01",
        "control_1f": "\x1f",
        "delete_7f": "\x7f",
        "nbsp": "\xa0",
        "precomposed": "é",
        "decomposed": "é",
        "cjk": "中",
        "emoji_surrogate_pair": "\U0001f600",
        "flag_two_pairs": "\U0001f1f2\U0001f1fd",
        "empty_string": "",
        "empty_object": {},
        "empty_array": [],
        "null": None,
        "true": True,
        "false": False,
        "zero": 0,
        "negative": -1,
        "int64_max": 9223372036854775807,
        "float_whole": 1.0,
        "float_zero": 0.0,
        "float_small_exponent": 1e-05,
        "float_large_exponent": 1e16,
        "float_third": 0.3333333333333333,
    },
}


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    for name, payload in FIXTURES.items():
        text = json.dumps(payload, indent=2) + "\n"
        (OUT / name).write_text(text, encoding="utf-8")
        print(f"wrote {name} ({len(text.encode('utf-8'))} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
