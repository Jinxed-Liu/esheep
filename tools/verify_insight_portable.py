#!/usr/bin/env python3
"""Run SDK-independent checks against production Insight logic with real Swift.

The MiMo checks compile unchanged production value types, wire builders, parsers,
budget and harness. URLSession's Apple-only byte transport is excluded, not
replaced with an SDK stub. Model streams are explicit test fixtures. No remote
provider, subscription login, business database, or iOS build is exercised.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import io
import struct
import warnings
import zipfile


def between(text: str, start: str, end: str) -> str:
    return text[text.index(start):text.index(end)]


def stage_mimo_value_types(root: Path, directory: Path) -> Path:
    source = (root / "eSheepNext/Services/MiMoClient.swift").read_text()
    models = (root / "eSheepNext/Models/InsightModels.swift").read_text()
    security = (root / "eSheepNext/Services/InsightSecurity.swift").read_text()
    agent_tools = (root / "eSheepNext/Services/InsightAgentTools.swift").read_text()
    wire = between(source, "    func makeResponsesURLRequest(", "    private static func validate(")
    content = "import Foundation\n#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif\n"
    content += between(models, "enum InsightMessageRole:", "enum InsightMessageStatus:")
    content += between(security, "enum MiMoCredentialKind:", "actor MiMoCredentialVault")
    content += between(agent_tools, "struct InsightGeneratedFile:", "struct InsightToolExecution {")
    content += source[:source.index("final class MiMoClient:")]
    content += "\nfinal class MiMoClientWire {\n" + wire + "\n}\n"
    content += source[source.index("enum MiMoSSEParser {"):]
    # The answer contract needs only the canonical tool name, not a farm DB.
    content += '\nenum InsightFarmCalculationEngine { static let toolName = "calculate_farm_data" }\n'
    target = directory / "MiMoPortableTypes.swift"
    target.write_text(content)
    return target


def stage_document_types(root: Path, directory: Path) -> Path:
    source = (root / "eSheepNext/Services/InsightDocumentAnalysis.swift").read_text()
    content = "import Foundation\nimport FoundationXML\n"
    content += between(source, "enum InsightDocumentError:", "enum InsightDocumentAnalysis {")
    content += "\nenum InsightDocumentAnalysis { static let maximumContextBytes = 200_000 }\n"
    content += source[source.index("private class InsightDocumentXMLParser:"):]
    content += (root / "tools/test_insight_document_archive.swift").read_text()
    target = directory / "DocumentPortableTypes.swift"
    target.write_text(content)
    return target


def stage_draft_types(root: Path, directory: Path) -> Path:
    media = (root / "eSheepNext/Services/InsightMediaServices.swift").read_text()
    documents = (root / "eSheepNext/Services/InsightDocumentAnalysis.swift").read_text()
    cipher_fixture = (root / "tools/test_insight_runtime_epoch.swift").read_text()
    content = "import Foundation\n"
    content += between(media, "struct PendingInsightImage:", "enum InsightVoicePrivacyPreference {")
    content += between(documents, "enum InsightDocumentError:", "enum InsightDocumentAnalysis {")
    content += "\nenum InsightDocumentAnalysis { static let maximumContextBytes = 200_000 }\n"
    content += cipher_fixture[:cipher_fixture.index("@main")]
    target = directory / "DraftAppOwnedTypes.swift"
    target.write_text(content)
    return target


def document_fixtures(directory: Path) -> None:
    payload = "真实称重文件内容".encode()
    def archive(name: str, content: bytes = payload, compression: int = zipfile.ZIP_STORED) -> bytes:
        output = io.BytesIO()
        with zipfile.ZipFile(output, "w", compression=compression) as value:
            value.writestr(name, content)
        return output.getvalue()
    fixtures = {
        "stored": archive("word/document.xml"),
        "deflated": archive("word/document.xml", compression=zipfile.ZIP_DEFLATED),
        "traversal": archive("../word/document.xml"),
        "bomb": archive("word/document.xml", b"x" * 1_000_000, zipfile.ZIP_DEFLATED),
    }
    class Unseekable(io.BytesIO):
        def seekable(self) -> bool: return False
        def seek(self, *args: object) -> int: raise io.UnsupportedOperation("not seekable")
    stream = Unseekable()
    with zipfile.ZipFile(stream, "w", compression=zipfile.ZIP_DEFLATED) as value:
        value.writestr("word/document.xml", payload)
    fixtures["descriptor"] = stream.getvalue()
    duplicate = io.BytesIO()
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", UserWarning)
        with zipfile.ZipFile(duplicate, "w") as value:
            value.writestr("word/document.xml", payload)
            value.writestr("word/document.xml", payload)
    fixtures["duplicate"] = duplicate.getvalue()
    original = fixtures["stored"]
    central = original.index(b"PK\x01\x02")
    encrypted = bytearray(original)
    struct.pack_into("<H", encrypted, 6, 1)
    struct.pack_into("<H", encrypted, central + 8, 1)
    fixtures["encrypted"] = encrypted
    corrupt = bytearray(original)
    checksum = struct.unpack_from("<I", original, 14)[0] ^ 1
    struct.pack_into("<I", corrupt, 14, checksum)
    struct.pack_into("<I", corrupt, central + 16, checksum)
    fixtures["corrupt"] = corrupt
    zip64 = bytearray(original)
    struct.pack_into("<I", zip64, central + 42, 0xFFFFFFFF)
    fixtures["zip64"] = zip64
    for name, data in fixtures.items():
        (directory / f"{name}.zip").write_bytes(data)


def run(compiler: str, root: Path, directory: Path, label: str, sources: list[Path], extra: list[str] | None = None, arguments: list[str] | None = None) -> None:
    binary = directory / label
    subprocess.run([compiler, "-swift-version", "6", "-strict-concurrency=complete", *(extra or []), *(str(path) for path in sources), "-o", str(binary)], check=True, cwd=root)
    subprocess.run([str(binary), *(arguments or [])], check=True, cwd=root)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swiftc", default=os.environ.get("SWIFTC", "swiftc"))
    parser.add_argument("--only", choices=["queue", "codex", "analysis", "workflow", "documents", "runtime", "drafts"], action="append")
    args = parser.parse_args()
    compiler = shutil.which(args.swiftc)
    if compiler is None:
        parser.error("No actual Swift compiler found; set --swiftc or SWIFTC.")
    root = Path(__file__).resolve().parent.parent
    selected = set(args.only or ["queue", "codex", "analysis", "workflow", "documents", "runtime", "drafts"])
    with tempfile.TemporaryDirectory(prefix="esheep-insight-portable-") as temporary:
        directory = Path(temporary)
        if "queue" in selected:
            run(compiler, root, directory, "session-queue", [
                root / "eSheepNext/Services/InsightSessionRequestQueue.swift",
                root / "tools/test_insight_session_queue.swift",
            ])
        if "codex" in selected:
            run(compiler, root, directory, "codex-protocol", [
                root / "eSheepNext/Services/InsightCodexProtocol.swift",
                root / "eSheepNext/Services/InsightCodexClient.swift",
                root / "tools/test_insight_codex_protocol.swift",
            ])
        if "analysis" in selected:
            run(compiler, root, directory, "analysis-budget", [
                stage_mimo_value_types(root, directory),
                root / "eSheepNext/Services/InsightAnalysisConfiguration.swift",
                root / "eSheepNext/Services/InsightAgentHarness.swift",
                root / "tools/test_insight_analysis_budget.swift",
            ])
        if "workflow" in selected:
            run(compiler, root, directory, "workflow", [
                root / "eSheepNext/Services/InsightAssistantWorkflow.swift",
                root / "tools/test_insight_workflow.swift",
            ])
        if "documents" in selected:
            header = Path("/usr/include/zlib.h")
            if not header.is_file():
                parser.error("Portable archive checks require the real zlib development header.")
            module = directory / "zlib"
            module.mkdir()
            (module / "module.modulemap").write_text(f'module zlib {{ header "{header}" link "z" export * }}\n')
            document_fixtures(directory)
            run(compiler, root, directory, "documents", [
                stage_document_types(root, directory),
                root / "eSheepNext/Services/InsightDocumentArchive.swift",
            ], extra=["-I", str(directory)], arguments=[str(directory)])
        if "runtime" in selected:
            run(compiler, root, directory, "runtime-epoch", [
                stage_mimo_value_types(root, directory),
                root / "eSheepNext/Services/InsightAnalysisConfiguration.swift",
                root / "eSheepNext/Services/InsightAssistantWorkflow.swift",
                root / "eSheepNext/Services/InsightRuntimeStore.swift",
                root / "tools/test_insight_runtime_epoch.swift",
            ])
        if "drafts" in selected:
            run(compiler, root, directory, "composer-drafts", [
                stage_draft_types(root, directory),
                root / "eSheepNext/Services/InsightSessionRequestQueue.swift",
                root / "eSheepNext/Services/InsightComposerDraftStore.swift",
                root / "tools/test_insight_composer_drafts.swift",
            ])
    print("Portable Insight checks passed; iOS compile, UI/device acceptance and real provider authorization remain separate.")


if __name__ == "__main__":
    main()
