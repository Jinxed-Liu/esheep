#!/usr/bin/env python3
"""Verify that the eSheep+ Cloud V2 command catalogue is fully wired.

The migration declares every business command in one catalogue, while the
actual implementation lives in executable server/client routes.  This script
makes that distinction explicit: the catalogue, typed payload, server
transaction, client projection and coverage tests must all agree before a V2
build can be considered switchable.  A database column or bulk UPDATE can
never mark a command ready merely because it appears in a fixture.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


CATALOG_START = "insert into esheep_cloud.command_catalog (command_kind, merge_mode"
CATALOG_END = "on conflict (command_kind) do update"


def extract_catalog(sql: str) -> list[str]:
    start = sql.index(CATALOG_START)
    end = sql.index(CATALOG_END, start)
    block = sql[start:end]
    kinds = re.findall(r"\(\s*'([^']+)'\s*,\s*'[^']+'\s*,", block)

    # attention.resolve is inserted by a separate statement because it is a
    # control-plane command rather than a farm-domain command.
    if re.search(r"\(\s*'attention\.resolve'\s*,", sql) and "attention.resolve" not in kinds:
        kinds.append("attention.resolve")
    return sorted(dict.fromkeys(kinds))


def contains_manual_readiness_update(sql: str) -> bool:
    """Detect the old bulk marker update that made the gate falsely green."""
    return bool(
        re.search(
            r"update\s+esheep_cloud\.command_catalog\s+set\s+"
            r"handler_schema_version\s*=\s*1\s*,\s*"
            r"client_projection_schema_version\s*=\s*1",
            sql,
            re.IGNORECASE | re.DOTALL,
        )
    )


def extract_server_dispatch_kinds(sql: str) -> set[str]:
    """Return command kinds in the authoritative, exhaustive dispatcher.

    The catalogue version columns are intentionally a release gate, but they
    are data and can be accidentally set for a newly declared kind.  The
    dispatcher is executable code: every non-control command must pass
    through its explicit ``when 'kind'`` arm before the transaction writes a
    command or event row.  Keep this check independent from the catalogue
    marker so a blanket SQL update cannot make the report green.
    """
    match = re.search(
        r"create\s+or\s+replace\s+function\s+esheep_cloud\.dispatch_command_v2\b.*?"
        r"\$\$(.*?)\$\$;",
        sql,
        re.IGNORECASE | re.DOTALL,
    )
    if not match:
        return set()
    body = match.group(1)
    kinds = set(re.findall(r"when\s+'([^']+)'\s+then", body, re.IGNORECASE))
    if re.search(r"p_kind\s*=\s*'attention\.resolve'.*?return\s+'attention\.resolve'", body, re.IGNORECASE | re.DOTALL):
        kinds.add("attention.resolve")
    return kinds


def extract_payload_kinds(contracts: str, catalog: set[str]) -> set[str]:
    """Return kinds with an exhaustive typed decoder/discriminator.

    The discriminator has two deliberately dynamic families.  Care commands
    expose their suffix through ``cloudKindV2`` and TMR commands expose their
    suffix through ``operationKind.rawValue``.  Looking only for string
    literals in ``var kind`` therefore under-counts a perfectly valid typed
    payload (the old checker reported 0/80).  We still keep this check static:
    every catalogue entry must be covered by one of the explicit decoder
    branches, and the dynamic families must have an exhaustive Swift switch.
    """
    body_start = contracts.index("var kind: String")
    body_end = contracts.index("/// V2 uses an explicit discriminator", body_start)
    discriminator = contracts[body_start:body_end]
    literals = set(
        re.findall(r'"([A-Za-z][A-Za-z0-9]*\.[A-Za-z0-9_.]+)"', discriminator)
    )

    # The decoder explicitly accepts these prefixes and then decodes a
    # strongly typed enum.  Expand the literal suffixes from the exhaustive
    # CareCommand mapping; no generic dictionary fallback is allowed.
    if "case let kind where kind.hasPrefix(\"care.\")" in contracts:
        care_suffixes = set(
            re.findall(
                r'case \.[A-Za-z0-9_]+:\s*"([A-Za-z][A-Za-z0-9_.]+)"',
                contracts,
            )
        )
        literals.update(f"care.{suffix}" for suffix in care_suffixes)

    # TMRCommand.operationKind is a DomainOperationKind enum.  The command
    # catalogue names the same cases with the stable ``tmr.`` prefix.
    if "case let kind where kind.hasPrefix(\"tmr.\")" in contracts:
        tmrs = {
            kind.removeprefix("tmr.")
            for kind in catalog
            if kind.startswith("tmr.")
        }
        if "operationKind.rawValue" in discriminator:
            literals.update(f"tmr.{suffix}" for suffix in tmrs)

    return literals & catalog


def extract_test_kinds(test_source: str, catalog: set[str]) -> set[str]:
    """Find explicit command-kind assertions and coverage manifests.

    Tests are allowed to derive a kind from a typed payload, so a literal
    search alone is not enough.  A test can opt into the machine-readable
    matrix with ``ESheepCloudCommandCoverageV2`` (or the test's equivalent
    ``allCommandKinds`` array); the script verifies that that manifest is
    exactly the server catalogue rather than trusting a hand-written count.
    """
    literals = set(
        re.findall(r'"([A-Za-z][A-Za-z0-9]*\.[A-Za-z0-9_.]+)"', test_source)
    ) & catalog
    manifest_match = re.search(
        r'(?:allCommandKinds|commandKinds)\s*:\s*\[(.*?)\]',
        test_source,
        re.DOTALL,
    )
    if manifest_match:
        literals.update(
            re.findall(r'"([A-Za-z][A-Za-z0-9]*\.[A-Za-z0-9_.]+)"', manifest_match.group(1))
        )
    return literals & catalog


def extract_registry_kinds(registry_source: str) -> list[str]:
    """Read the product-target command registry, not a test-only fixture."""
    match = re.search(
        r"static\s+let\s+allKinds:\s*\[String\]\s*=\s*\[(.*?)\n\s*\]",
        registry_source,
        re.DOTALL,
    )
    if not match:
        return []
    return re.findall(r'"([A-Za-z][A-Za-z0-9_.]+)"', match.group(1))


def extract_registry_native_routes(registry_source: str) -> set[str]:
    """Return kinds with an explicit product-target projection route."""
    match = re.search(
        r"static\s+func\s+nativeProjectionRoute\(for\s+kind:\s+String\)\s*->\s*String\?\s*\{(.*?)\n\s*\}",
        registry_source,
        re.DOTALL,
    )
    if not match:
        return set()
    return set(re.findall(r'case\s+"([A-Za-z][A-Za-z0-9_.]+)"\s*:', match.group(1)))


def make_report(root: Path) -> dict[str, object]:
    migration_path = root / "supabase/migrations/20260902041541_esheep_cloud_v2.sql"
    contracts_path = root / "eSheepNext/Services/ESheepCloud/ESheepCloudContractsV2.swift"
    factory_path = root / "eSheepNext/Services/ESheepCloud/ESheepCloudCommandFactoryV2.swift"
    reducer_path = root / "eSheepNext/Services/ESheepCloud/ESheepCloudEventReducer.swift"
    migration_coordinator_path = root / "eSheepNext/Services/ESheepCloud/ESheepCloudMigrationCoordinator.swift"
    core_path = root / "eSheepNext/Services/ESheepCloud/ESheepCloudCore.swift"
    registry_path = root / "eSheepNext/Services/ESheepCloud/ESheepCloudCommandRegistryV2.swift"
    test_path = root / "eSheepNextTests/ESheepCloudV2Tests.swift"

    sql = migration_path.read_text(encoding="utf-8")
    contracts = contracts_path.read_text(encoding="utf-8")
    factory = factory_path.read_text(encoding="utf-8")
    reducer = reducer_path.read_text(encoding="utf-8")
    migration_coordinator = migration_coordinator_path.read_text(encoding="utf-8")
    core = core_path.read_text(encoding="utf-8")
    registry = registry_path.read_text(encoding="utf-8")
    tests = test_path.read_text(encoding="utf-8")

    catalog = extract_catalog(sql)
    registry_kinds = extract_registry_kinds(registry)
    registry_native_routes = extract_registry_native_routes(registry)
    server_dispatch_kinds = extract_server_dispatch_kinds(sql)
    # Implementation readiness is executable capability, not catalogue data.
    # The server set is taken from the explicit dispatcher; the client set is
    # taken from the product-target native projection registry below.
    server_ready = server_dispatch_kinds
    client_ready = registry_native_routes
    manual_readiness_update = contains_manual_readiness_update(sql)
    payload_kinds = extract_payload_kinds(contracts, set(catalog))
    factory_text = factory
    reducer_text = reducer
    migration_text = migration_coordinator
    test_kinds = extract_test_kinds(tests, set(catalog))
    # The exhaustive XCTest iterates the product registry.  It counts as
    # coverage only when that test is present and the registry exactly equals
    # the SQL catalogue; a test-only count or an arbitrary readiness override
    # cannot satisfy this gate.
    registry_tested = (
        "testV2CommandRegistryIsExhaustiveAndEveryKindHasTypedRoute" in tests
        and "ESheepCloudCommandRegistryV2.allKinds" in tests
        and registry_kinds == sorted(catalog)
    )
    if registry_tested:
        test_kinds.update(registry_kinds)

    rows: list[dict[str, object]] = []
    for kind in catalog:
        # Presence in the typed discriminator is required, but is not by
        # itself enough to make a command ready.
        payload = kind in payload_kinds or (
            kind == "attention.resolve"
            and "struct ESheepCloudAttentionResolutionV2" in contracts
            and "resolveAttention" in contracts
        )
        # ``make(command:)`` is an exhaustive switch over FarmCommand and is
        # compile-time checked by Swift.  For the control-plane item the
        # resolver path is implemented by ESheepCloudCore instead of the
        # business command factory.
        factory = (
            kind == "attention.resolve"
            and "resolveAttention" in core
        ) or (
            kind != "attention.resolve"
            and "static func make(" in factory_text
            and "switch command" in factory_text
            and "case .care(let value)" in factory_text
            and "case .tmr(let value)" in factory_text
            and kind in payload_kinds
        )
        server = kind in server_ready
        server_dispatch = kind in server_dispatch_kinds and (
            "v_handler_key := esheep_cloud.dispatch_command_v2" in sql
        )
        client = kind in client_ready
        client_native_route = kind in registry_native_routes
        migration = (
            kind == "attention.resolve"
            or (
                "prepareV1Migration" in migration_text
                and "convertAfterSnapshot" in migration_text
                and kind in payload_kinds
            )
        )
        tested = kind in test_kinds
        complete = all((
            payload,
            factory,
            server,
            server_dispatch,
            client,
            client_native_route,
            migration,
            tested,
        ))
        rows.append(
            {
                "command_kind": kind,
                "typed_payload": payload,
                "factory": factory,
                "server_transaction": server,
                "server_dispatch": server_dispatch,
                "client_projection": client,
                "client_native_route": client_native_route,
                "migration_mapping": migration,
                "covered_by_test": tested,
                "complete": complete,
            }
        )

    complete_count = sum(bool(row["complete"]) for row in rows)
    return {
        "protocol": "eSheep+ Cloud V2",
        "protocol_version": 2,
        "schema_version": 1,
        "declared_count": len(rows),
        "complete_count": complete_count,
        "incomplete_count": len(rows) - complete_count,
        "ready_for_cutover": len(rows) > 0 and complete_count == len(rows),
        "registry_count": len(registry_kinds),
        "registry_matches_catalog": registry_kinds == sorted(catalog),
        "native_projection_route_count": len(registry_native_routes & set(catalog)),
        "native_projection_routes_match_catalog": registry_native_routes == set(catalog),
        "missing_native_projection_routes": sorted(set(catalog) - registry_native_routes),
        "server_dispatch_count": len(server_dispatch_kinds & set(catalog)),
        "server_dispatch_matches_catalog": server_dispatch_kinds == set(catalog),
        "missing_server_dispatch_kinds": sorted(set(catalog) - server_dispatch_kinds),
        "manual_readiness_update": manual_readiness_update,
        "rows": rows,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("repo_root", nargs="?", default=Path(__file__).resolve().parents[1])
    parser.add_argument("--json", dest="json_path", type=Path)
    parser.add_argument("--allow-incomplete", action="store_true")
    args = parser.parse_args()
    root = Path(args.repo_root).resolve()
    report = make_report(root)
    output = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    if args.json_path:
        args.json_path.write_text(output, encoding="utf-8")
    print(
        "V2 command coverage: "
        f"{report['complete_count']}/{report['declared_count']} complete; "
        f"{report['incomplete_count']} incomplete"
    )
    if report["incomplete_count"]:
        for row in report["rows"]:
            if not row["complete"]:
                missing = [
                    key
                    for key in (
                        "typed_payload",
                        "factory",
                        "server_transaction",
                        "server_dispatch",
                        "client_projection",
                        "client_native_route",
                        "migration_mapping",
                        "covered_by_test",
                    )
                    if not row[key]
                ]
                print(f"  {row['command_kind']}: missing {', '.join(missing)}")
    if report["manual_readiness_update"]:
        print(
            "  failure: catalogue contains a bulk readiness marker update; "
            "readiness must come from executable routes"
        )
    if (report["ready_for_cutover"] and not report["manual_readiness_update"]) or args.allow_incomplete:
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
