import Foundation
import UIKit
import XCTest
import zlib
@testable import eSheepNext

@MainActor
final class InsightDocumentAnalysisTests: XCTestCase {
    func testTextRequiresSelectionAndPreservesOriginalLineCitation() throws {
        let document = try InsightDocumentAnalysis.parse(data: Data("first line\nsecond line\n".utf8), fileName: "notes.md")
        XCTAssertFalse(document.isReadyToSend)
        XCTAssertThrowsError(try document.modelContextText()) { XCTAssertEqual($0 as? InsightDocumentError, .selectionRequired) }
        let range = InsightDocumentRange(sectionID: "text", firstBlock: 2, lastBlock: 2)
        XCTAssertThrowsError(try document.selecting([range])) { XCTAssertEqual($0 as? InsightDocumentError, .partialAcknowledgementRequired) }
        let selected = try document.selecting([range], acknowledgesPartialContent: true)
        XCTAssertTrue(selected.isReadyToSend)
        let context = try selected.modelContextText()
        XCTAssertTrue(context.contains("notes.md，行 2"))
        XCTAssertTrue(context.contains("second line"))
        XCTAssertFalse(context.contains("first line"))
        XCTAssertThrowsError(try document.selecting([range, range], acknowledgesPartialContent: true)) { XCTAssertEqual($0 as? InsightDocumentError, .invalidRange) }
        XCTAssertThrowsError(try document.selecting([.init(sectionID: "text", firstBlock: 2, lastBlock: 1)], acknowledgesPartialContent: true)) { XCTAssertEqual($0 as? InsightDocumentError, .invalidRange) }
    }

    func testInvalidTypesEncodingAndJSONNeverBecomeReady() throws {
        for (data, name) in [
            (Data("%PDF-binary".utf8), "fake.txt"),
            (Data("not a PDF".utf8), "fake.pdf"),
            (Data([0xff, 0x00, 0x01]), "bad.txt"),
            (Data("{broken".utf8), "bad.json"),
            (Data("plain".utf8), "unsupported.exe"),
        ] {
            XCTAssertThrowsError(try InsightDocumentAnalysis.parse(data: data, fileName: name))
        }
        let encryptedOffice = Data([0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1, 0])
        XCTAssertThrowsError(try InsightDocumentAnalysis.parse(data: encryptedOffice, fileName: "locked.docx")) { XCTAssertTrue($0.localizedDescription.contains("容器")) }
        let json = try InsightDocumentAnalysis.parse(data: Data("{\n  \"count\": 3\n}".utf8), fileName: "facts.json")
        XCTAssertEqual(json.sections.first?.blocks[1].citation, "facts.json，行 2")
    }

    func testCSVMultilineRecordsKeepOriginalLinesAndCellReferences() throws {
        let document = try InsightDocumentAnalysis.parse(data: Data("tag,note\n001,\"line two\nline three\"\n".utf8), fileName: "weighing.csv")
        let row = try XCTUnwrap(document.sections.first?.blocks.last)
        XCTAssertEqual(row.id, 2)
        XCTAssertTrue(row.text.contains("A2=001"))
        XCTAssertTrue(row.text.contains("B2=line two\nline three"))
        XCTAssertEqual(row.citation, "weighing.csv，记录 2，原文行 2–3")
        XCTAssertThrowsError(try InsightDocumentAnalysis.parse(data: Data("a,\"unfinished".utf8), fileName: "bad.csv"))
    }

    func testDOCXExtractsBodyParagraphsWithRealParagraphLocations() throws {
        let data = package([
            ("[Content_Types].xml", contentTypes("/word/document.xml", "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml")),
            ("word/document.xml", "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body><w:p><w:r><w:t>first &amp; fact</w:t></w:r></w:p><w:p><w:r><w:t>second</w:t><w:tab/><w:t>fact</w:t></w:r></w:p></w:body></w:document>"),
        ])
        let document = try InsightDocumentAnalysis.parse(data: data, fileName: "report.docx")
        XCTAssertEqual(document.sections.first?.blocks.map(\.text), ["first & fact", "second\tfact"])
        XCTAssertEqual(document.sections.first?.blocks.last?.citation, "report.docx，段落 2")
        let selected = try document.selecting([.init(sectionID: "text", firstBlock: 1, lastBlock: 2)])
        XCTAssertTrue(selected.isReadyToSend)
    }

    func testXLSXResolvesRelationshipTargetsAndRetainsSparseCellCoordinates() throws {
        let document = try InsightDocumentAnalysis.parse(data: workbookPackage(), fileName: "weights.xlsx")
        let sheet = try XCTUnwrap(document.sections.first)
        XCTAssertEqual(sheet.id, "rId42")
        XCTAssertEqual(sheet.title, "称重记录")
        XCTAssertEqual(sheet.totalBlockCount, 10)
        XCTAssertEqual(sheet.blocks.first?.id, 10)
        XCTAssertEqual(sheet.blocks.first?.text, "A10=001 | B10=12.5")
        XCTAssertEqual(sheet.blocks.first?.citation, "weights.xlsx，工作表“称重记录”，行 10")
        XCTAssertTrue(try document.selecting([.init(sectionID: sheet.id, firstBlock: 10, lastBlock: 10)]).isReadyToSend)
    }

    func testExistingXLSXEncoderCreatesAnalyzableWorkbookWithoutBusinessImport() throws {
        let data = try XLSXCodec.encode(sheets: [.init(name: "体重", rows: [["耳号", "体重"], ["001", "12"]])])
        let document = try InsightDocumentAnalysis.parse(data: data, fileName: "export.xlsx")
        XCTAssertEqual(document.sections.first?.blocks.count, 2)
        XCTAssertTrue(document.sections.first?.blocks.last?.text.contains("A2=001") == true)
        XCTAssertTrue(document.issues.contains { $0.id == "xlsx-raw-values" })
    }

    func testPartiallyBrokenWorkbookNeedsExplicitAcknowledgement() throws {
        let document = try InsightDocumentAnalysis.parse(data: workbookPackage(includeBrokenSheet: true), fileName: "partial.xlsx")
        XCTAssertEqual(document.sections.count, 2)
        XCTAssertFalse(document.sections[1].isReadable)
        XCTAssertFalse(document.issues.isEmpty)
        let range = InsightDocumentRange(sectionID: "rId42", firstBlock: 10, lastBlock: 10)
        XCTAssertThrowsError(try document.selecting([range])) { XCTAssertEqual($0 as? InsightDocumentError, .partialAcknowledgementRequired) }
        XCTAssertTrue(try document.selecting([range], acknowledgesPartialContent: true).isReadyToSend)
    }

    func testScanPDFIsRecoverableErrorAndMixedPDFReportsMissingPage() throws {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 300))
        let scan = renderer.pdfData { $0.beginPage() }
        XCTAssertThrowsError(try InsightDocumentAnalysis.parse(data: scan, fileName: "scan.pdf")) { error in
            guard let documentError = error as? InsightDocumentError,
                  case .noReadableContent(let reason) = documentError else { return XCTFail("Expected OCR recovery error") }
            XCTAssertTrue(reason.contains("OCR"))
        }
        let mixed = renderer.pdfData { context in
            context.beginPage()
            ("Actual page one fact" as NSString).draw(at: CGPoint(x: 20, y: 20), withAttributes: [.font: UIFont.systemFont(ofSize: 16)])
            context.beginPage()
        }
        let document = try InsightDocumentAnalysis.parse(data: mixed, fileName: "mixed.pdf")
        XCTAssertEqual(document.sections.count, 2)
        XCTAssertEqual(document.sections.first?.blocks.first?.citation, "mixed.pdf，第 1 页")
        XCTAssertTrue(document.issues.contains { $0.id == "page-2" })
        XCTAssertFalse(document.isReadyToSend)
    }

    func testArchiveRejectsEncryptionPathsDuplicateEntriesExpansionAndCorruption() throws {
        XCTAssertThrowsError(try InsightDocumentArchive.decode(package([("a.xml", "safe")], flags: 1))) { XCTAssertEqual($0 as? InsightDocumentError, .encrypted) }
        XCTAssertThrowsError(try InsightDocumentArchive.decode(package([("../a.xml", "safe")]))) { XCTAssertEqual($0 as? InsightDocumentError, .unsafeArchive) }
        XCTAssertThrowsError(try InsightDocumentArchive.decode(package([("a.xml", "first"), ("a.xml", "second")]))) { XCTAssertEqual($0 as? InsightDocumentError, .unsafeArchive) }
        XCTAssertThrowsError(try InsightDocumentArchive.decode(package([("a.xml", "small")], claimedExpandedSize: UInt32(InsightDocumentAnalysis.maximumTotalBytes + 1)))) { XCTAssertEqual($0 as? InsightDocumentError, .expandedArchiveTooLarge) }
        var corrupt = package([("a.xml", "safe")])
        corrupt[30 + "a.xml".utf8.count] ^= 0x01
        XCTAssertThrowsError(try InsightDocumentArchive.decode(corrupt))
        XCTAssertThrowsError(try InsightDocumentArchive.decode(Data(corrupt.dropLast(10))))
    }

    func testDTDAndMissingFormulaResultsAreNotSuccessfulParse() throws {
        let unsafe = package([
            ("[Content_Types].xml", contentTypes("/word/document.xml", "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml")),
            ("word/document.xml", "<!DOCTYPE document [<!ENTITY bomb 'value'>]><document><p><t>&bomb;</t></p></document>"),
        ])
        XCTAssertThrowsError(try InsightDocumentAnalysis.parse(data: unsafe, fileName: "unsafe.docx"))
        let missing = workbookPackage(worksheet: "<worksheet><sheetData><row r=\"10\"><c r=\"A10\"><f>1+1</f></c></row></sheetData></worksheet>")
        XCTAssertThrowsError(try InsightDocumentAnalysis.parse(data: missing, fileName: "missing-cache.xlsx"))
    }

    func testCapacityLimitsFailWithoutTruncatingSelectedContent() throws {
        let first = try readyText(String(repeating: "a", count: 110_000), name: "one.txt")
        let second = try readyText(String(repeating: "b", count: 110_000), name: "two.txt")
        XCTAssertThrowsError(try InsightDocumentAnalysis.combinedModelContextText([first, second])) { XCTAssertEqual($0 as? InsightDocumentError, .contextTooLarge) }
        XCTAssertEqual(first.rawData.count, 110_000)
        XCTAssertThrowsError(try first.modelContextText(maxUTF8Bytes: 1_000)) { XCTAssertEqual($0 as? InsightDocumentError, .contextTooLarge) }
        XCTAssertThrowsError(try InsightDocumentAnalysis.validate([first, second, try readyText("c"), try readyText("d")])) { XCTAssertEqual($0 as? InsightDocumentError, .tooManyFiles) }
        XCTAssertThrowsError(try InsightDocumentAnalysis.parse(data: Data(repeating: 65, count: InsightDocumentAnalysis.maximumFileBytes + 1), fileName: "large.txt")) { XCTAssertEqual($0 as? InsightDocumentError, .fileTooLarge) }
    }

    func testTotalRawByteLimitAppliesEvenWhenOnlySmallRangeIsSelected() throws {
        var data = Data(repeating: 32, count: 18 * 1_024 * 1_024)
        data.append(Data("\nsmall fact".utf8))
        let parsed = try InsightDocumentAnalysis.parse(data: data, fileName: "large-source.txt")
        let selected = try parsed.selecting([.init(sectionID: "text", firstBlock: 2, lastBlock: 2)])
        let documents = (0..<3).map { _ in
            PendingInsightDocument(id: UUID(), fileName: selected.fileName, mimeType: selected.mimeType,
                                   rawData: selected.rawData, digest: selected.digest, sections: selected.sections,
                                   issues: selected.issues, selection: selected.selection)
        }
        XCTAssertThrowsError(try InsightDocumentAnalysis.validate(documents)) { XCTAssertEqual($0 as? InsightDocumentError, .totalFilesTooLarge) }
    }

    func testEncryptedStorePreservesCitationsAndRejectsCrossFarmReplay() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "insight-document-store-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = InsightLocalDocumentStore(rootDirectory: directory)
        let accountID = UUID(), farmID = UUID(), conversationID = UUID(), messageID = UUID()
        let document = try readyText("unique private document fact")
        try await store.save([document], messageID: messageID, conversationID: conversationID, accountID: accountID, farmID: farmID)
        let loaded = try await store.load(messageID: messageID, conversationID: conversationID, accountID: accountID, farmID: farmID)
        XCTAssertEqual(try loaded.first?.modelContextText(), try document.modelContextText())
        let previews = try await store.previews(messageID: messageID, conversationID: conversationID, accountID: accountID, farmID: farmID)
        XCTAssertEqual(try previews.first?.modelContextText(), try document.modelContextText())
        let files = try XCTUnwrap(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let url as URL in files where url.pathExtension == "bin" {
            let encrypted = try Data(contentsOf: url)
            XCTAssertFalse(String(decoding: encrypted, as: UTF8.self).contains("unique private document fact"))
        }
        let otherFarm = UUID()
        let source = directory.appending(path: accountID.uuidString.lowercased()).appending(path: farmID.uuidString.lowercased()).appending(path: conversationID.uuidString.lowercased()).appending(path: messageID.uuidString.lowercased())
        let target = directory.appending(path: accountID.uuidString.lowercased()).appending(path: otherFarm.uuidString.lowercased()).appending(path: conversationID.uuidString.lowercased()).appending(path: messageID.uuidString.lowercased())
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: target)
        do {
            _ = try await store.load(messageID: messageID, conversationID: conversationID, accountID: accountID, farmID: otherFarm)
            XCTFail("Cross-farm ciphertext replay must fail")
        } catch { XCTAssertTrue(error is InsightSecurityError) }
        try await store.removeConversation(conversationID: conversationID, accountID: accountID, farmID: farmID)
        let removed = try await store.load(messageID: messageID, conversationID: conversationID, accountID: accountID, farmID: farmID)
        XCTAssertTrue(removed.isEmpty)
    }

    func testDeletedConversationCannotBeRestoredByLateAttachmentSave() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "insight-document-race-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cipher = PausingDocumentCipher()
        let store = InsightLocalDocumentStore(rootDirectory: directory, crypto: cipher)
        let accountID = UUID(), farmID = UUID(), conversationID = UUID(), messageID = UUID()
        let document = try readyText("late source must not return")
        let pending = Task {
            try await store.save([document], messageID: messageID, conversationID: conversationID, accountID: accountID, farmID: farmID)
        }
        await cipher.waitUntilPaused()
        try await store.removeConversation(conversationID: conversationID, accountID: accountID, farmID: farmID)
        await cipher.resume()
        do { try await pending.value; XCTFail("Deleted scope must reject its old save") }
        catch { XCTAssertEqual(error as? InsightDocumentError, .storageScopeDeleted) }
        let loaded = try await store.previews(messageID: messageID, conversationID: conversationID, accountID: accountID, farmID: farmID)
        XCTAssertTrue(loaded.isEmpty)
        let path = directory.appending(path: accountID.uuidString.lowercased()).appending(path: farmID.uuidString.lowercased()).appending(path: conversationID.uuidString.lowercased())
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }

    func testRestoringConsentPermitsNewSaveButRejectsOldAccountEpoch() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "insight-document-consent-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cipher = PausingDocumentCipher()
        let store = InsightLocalDocumentStore(rootDirectory: directory, crypto: cipher)
        let accountID = UUID(), farmID = UUID(), conversationID = UUID()
        let document = try readyText("consented document")
        let oldMessageID = UUID()
        let pending = Task {
            try await store.save([document], messageID: oldMessageID, conversationID: conversationID, accountID: accountID, farmID: farmID)
        }
        await cipher.waitUntilPaused()
        try await store.removeAccount(accountID: accountID)
        await store.enableAccount(accountID: accountID)
        await cipher.resume()
        do { try await pending.value; XCTFail("Re-consent must not authorize an old save") }
        catch { XCTAssertEqual(error as? InsightDocumentError, .storageScopeDeleted) }
        let newMessageID = UUID()
        try await store.save([document], messageID: newMessageID, conversationID: conversationID, accountID: accountID, farmID: farmID)
        let old = try await store.previews(messageID: oldMessageID, conversationID: conversationID, accountID: accountID, farmID: farmID)
        let current = try await store.previews(messageID: newMessageID, conversationID: conversationID, accountID: accountID, farmID: farmID)
        XCTAssertTrue(old.isEmpty)
        XCTAssertEqual(current.map(\.id), [document.id])
    }

    private func readyText(_ text: String, name: String = "notes.txt") throws -> PendingInsightDocument {
        let document = try InsightDocumentAnalysis.parse(data: Data(text.utf8), fileName: name)
        return try document.selecting([.init(sectionID: "text", firstBlock: 1, lastBlock: 1)])
    }

    private func contentTypes(_ path: String, _ type: String) -> String {
        "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Override PartName=\"\(path)\" ContentType=\"\(type)\"/></Types>"
    }

    private func workbookPackage(includeBrokenSheet: Bool = false, worksheet: String? = nil) -> Data {
        let extraSheet = includeBrokenSheet ? "<sheet name=\"损坏表\" sheetId=\"2\" r:id=\"rIdBroken\"/>" : ""
        let extraLink = includeBrokenSheet ? "<Relationship Id=\"rIdBroken\" Target=\"worksheets/broken.xml\"/>" : ""
        var entries = [
            ("[Content_Types].xml", contentTypes("/xl/workbook.xml", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml")),
            ("xl/workbook.xml", "<workbook xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets><sheet name=\"称重记录\" sheetId=\"42\" r:id=\"rId42\"/>\(extraSheet)</sheets></workbook>"),
            ("xl/_rels/workbook.xml.rels", "<Relationships><Relationship Id=\"rId42\" Target=\"worksheets/custom-name.xml\"/>\(extraLink)</Relationships>"),
            ("xl/worksheets/custom-name.xml", worksheet ?? "<worksheet><sheetData><row r=\"10\"><c r=\"A10\" t=\"inlineStr\"><is><t>001</t></is></c><c r=\"B10\"><v>12.5</v></c></row></sheetData></worksheet>"),
        ]
        if includeBrokenSheet { entries.append(("xl/worksheets/broken.xml", "<worksheet><sheetData>")) }
        return package(entries)
    }

    private func package(_ entries: [(String, String)], flags: UInt16 = 0, claimedExpandedSize: UInt32? = nil) -> Data {
        var output = Data(), central = Data()
        for (name, text) in entries {
            let bytes = Data(text.utf8), nameBytes = Data(name.utf8)
            let checksum = bytes.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(bytes.count))) }
            let offset = UInt32(output.count), expanded = claimedExpandedSize ?? UInt32(bytes.count)
            output.testAppendLE(UInt32(0x04034b50)); output.testAppendLE(UInt16(20)); output.testAppendLE(flags); output.testAppendLE(UInt16(0))
            output.testAppendLE(UInt16(0)); output.testAppendLE(UInt16(0)); output.testAppendLE(checksum)
            output.testAppendLE(UInt32(bytes.count)); output.testAppendLE(expanded); output.testAppendLE(UInt16(nameBytes.count)); output.testAppendLE(UInt16(0))
            output.append(nameBytes); output.append(bytes)
            central.testAppendLE(UInt32(0x02014b50)); central.testAppendLE(UInt16(20)); central.testAppendLE(UInt16(20)); central.testAppendLE(flags); central.testAppendLE(UInt16(0))
            central.testAppendLE(UInt16(0)); central.testAppendLE(UInt16(0)); central.testAppendLE(checksum)
            central.testAppendLE(UInt32(bytes.count)); central.testAppendLE(expanded); central.testAppendLE(UInt16(nameBytes.count)); central.testAppendLE(UInt16(0)); central.testAppendLE(UInt16(0))
            central.testAppendLE(UInt16(0)); central.testAppendLE(UInt16(0)); central.testAppendLE(UInt32(0)); central.testAppendLE(offset); central.append(nameBytes)
        }
        let centralOffset = UInt32(output.count)
        output.append(central)
        output.testAppendLE(UInt32(0x06054b50)); output.testAppendLE(UInt16(0)); output.testAppendLE(UInt16(0)); output.testAppendLE(UInt16(entries.count)); output.testAppendLE(UInt16(entries.count))
        output.testAppendLE(UInt32(central.count)); output.testAppendLE(centralOffset); output.testAppendLE(UInt16(0))
        return output
    }
}

private actor PausingDocumentCipher: InsightDocumentCipher {
    private var pausesNextSeal = true
    private var isPaused = false
    private var pause: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?

    func waitUntilPaused() async {
        if isPaused { return }
        await withCheckedContinuation { observer = $0 }
    }

    func resume() {
        pause?.resume()
        pause = nil
    }

    func seal(_ data: Data, accountID: UUID, recordID: String) async throws -> Data {
        if pausesNextSeal {
            pausesNextSeal = false
            await withCheckedContinuation { continuation in
                pause = continuation
                isPaused = true
                observer?.resume()
                observer = nil
            }
        }
        return try await InsightPersonalCryptoActor.shared.seal(data, accountID: accountID, recordID: recordID)
    }

    func open(_ data: Data, accountID: UUID, recordID: String) async throws -> Data {
        try await InsightPersonalCryptoActor.shared.open(data, accountID: accountID, recordID: recordID)
    }
}

private extension Data {
    mutating func testAppendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
