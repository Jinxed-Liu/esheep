#!/usr/bin/env python3
"""Audit business-domain references in an eSheep Cloud V2 snapshot.

The cryptographic V2 integrity report proves that the event and stream chains
are internally consistent.  It does not prove that a command which references
another business object can be replayed into an empty local store.  This
small, read-only gate checks the latter property for feed records without
building the iOS target or connecting to Supabase.

The input is either the directory containing ``chunk-*.json`` files or a
single chunk file copied from a device.  A non-zero exit status means that a
feed command references an ``ingredientBatchID`` for which the snapshot has
no ``feedIngredientBatch`` stream.  The output is JSON so it can be retained
with migration/release evidence and inspected without exposing credentials.
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Iterable, Iterator


def chunk_paths(input_path: Path) -> list[Path]:
    if input_path.is_file():
        return [input_path]
    if not input_path.is_dir():
        raise FileNotFoundError(input_path)
    paths = sorted(input_path.glob("chunk-*.json"))
    if not paths:
        raise FileNotFoundError(f"no chunk-*.json files under {input_path}")
    return paths


def records(paths: Iterable[Path]) -> Iterator[dict[str, Any]]:
    for path in paths:
        with path.open("r", encoding="utf-8") as handle:
            value = json.load(handle)
        if not isinstance(value, list):
            raise ValueError(f"{path} is not a JSON array")
        for record in value:
            if not isinstance(record, dict):
                raise ValueError(f"{path} contains a non-object record")
            yield record


def decode_event_body(record: dict[str, Any]) -> dict[str, Any] | None:
    body = record.get("event_body_canonical")
    if not isinstance(body, str):
        return None
    try:
        value = json.loads(body)
    except json.JSONDecodeError:
        return None
    return value if isinstance(value, dict) else None


def feed_batch_references(records_iter: Iterable[dict[str, Any]]) -> dict[str, Any]:
    stream_types: Counter[str] = Counter()
    batch_stream_ids: set[str] = set()
    command_kinds: Counter[str] = Counter()
    references: dict[str, list[dict[str, Any]]] = defaultdict(list)
    event_count = 0
    stream_count = 0

    for record in records_iter:
        kind = record.get("record_kind")
        if kind == "stream":
            stream_count += 1
            stream_type = record.get("stream_type")
            if isinstance(stream_type, str):
                stream_types[stream_type] += 1
                if stream_type == "feedIngredientBatch":
                    stream_id = record.get("stream_id")
                    if isinstance(stream_id, str):
                        batch_stream_ids.add(stream_id.upper())
            continue
        if kind != "event":
            continue

        event_count += 1
        body = decode_event_body(record)
        if body is None:
            continue
        command_kind = body.get("command_kind")
        if not isinstance(command_kind, str):
            continue
        command_kinds[command_kind] += 1
        if command_kind not in {"feed.record", "feed.recordV2"}:
            continue

        payload = body.get("command_payload")
        if not isinstance(payload, dict):
            continue
        body_payload = payload.get("body")
        if not isinstance(body_payload, dict):
            continue
        record_payload = body_payload.get("record")
        if not isinstance(record_payload, dict):
            continue

        # Historical payloads use a keyed envelope (usually ``_0``).  Keep the
        # audit tolerant of a future single-record shape as well.
        candidates: list[dict[str, Any]] = []
        for value in record_payload.values():
            if isinstance(value, dict):
                candidates.append(value)
        if not candidates and "lines" in record_payload:
            candidates.append(record_payload)

        for candidate in candidates:
            lines = candidate.get("lines")
            if not isinstance(lines, list):
                continue
            for line_index, line in enumerate(lines):
                if not isinstance(line, dict):
                    continue
                batch_id = line.get("ingredientBatchID")
                if not isinstance(batch_id, str) or not batch_id:
                    continue
                normalized = batch_id.upper()
                references[normalized].append(
                    {
                        "event_sequence": record.get("event_sequence"),
                        "event_id": record.get("event_id"),
                        "command_id": record.get("command_id"),
                        "command_kind": command_kind,
                        "stream_id": record.get("stream_id"),
                        "line_index": line_index,
                    }
                )

    missing = [
        {
            "ingredient_batch_id": batch_id,
            "reference_count": len(refs),
            "first_reference": refs[0],
            "last_reference": refs[-1],
        }
        for batch_id, refs in sorted(references.items())
        if batch_id not in batch_stream_ids
    ]

    return {
        "stream_count": stream_count,
        "event_count": event_count,
        "stream_type_counts": dict(sorted(stream_types.items())),
        "command_kind_counts": dict(sorted(command_kinds.items())),
        "feed_record_reference_count": sum(len(refs) for refs in references.values()),
        "feed_record_distinct_batch_reference_count": len(references),
        "feed_ingredient_batch_stream_count": len(batch_stream_ids),
        "missing_feed_ingredient_batch_count": len(missing),
        "missing_feed_ingredient_batches": missing,
        "passed": not missing,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("snapshot", type=Path, help="snapshot directory or chunk JSON")
    parser.add_argument("--json", dest="json_path", type=Path, help="also write the report")
    args = parser.parse_args()

    try:
        paths = chunk_paths(args.snapshot.resolve())
        report = {
            "protocol": "eSheep+ Cloud V2",
            "snapshot_input": str(args.snapshot.resolve()),
            "chunk_count": len(paths),
            **feed_batch_references(records(paths)),
        }
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"business-reference audit failed: {error}", file=sys.stderr)
        return 2

    output = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    if args.json_path:
        args.json_path.write_text(output, encoding="utf-8")
    print(output, end="")
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
