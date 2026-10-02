import Foundation

// The portable runner appends this file to the unchanged production Foundation
// document types and XML/CSV parsers so private parser hooks are tested in place.
@main
struct InsightDocumentPortableRegression {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(description: message) }
    }
    static func reject(_ label: String, _ action: () throws -> Void) throws {
        do { try action(); throw Failure(description: "Unsafe document accepted: \(label)") }
        catch let error as InsightDocumentError {
            let category: String
            switch error {
            case .encrypted: category = "encrypted"
            case .unsafeArchive: category = "unsafe"
            case .expandedArchiveTooLarge: category = "expanded"
            case .malformed: category = "malformed"
            case .partialAcknowledgementRequired: category = "partial"
            case .invalidRange: category = "range"
            default: throw error
            }
            try require(category == label, "Expected \(label), got \(category)")
        }
    }
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw Failure(description: "Missing ZIP fixture directory.") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        func fixture(_ name: String) throws -> Data { try Data(contentsOf: root.appendingPathComponent(name + ".zip")) }
        let expected = Data("真实称重文件内容".utf8)
        for name in ["stored", "deflated", "descriptor"] {
            let entries = try InsightDocumentArchive.decode(fixture(name))
            try require(entries["word/document.xml"] == expected && entries.count == 1,
                        "ZIP \(name) did not decode the exact bytes.")
        }
        print("PASS: actual stored, raw deflate and data-descriptor ZIP decoding")
        try reject("unsafe") { _ = try InsightDocumentArchive.decode(fixture("traversal")) }
        try reject("unsafe") { _ = try InsightDocumentArchive.decode(fixture("duplicate")) }
        try reject("encrypted") { _ = try InsightDocumentArchive.decode(fixture("encrypted")) }
        try reject("expanded") { _ = try InsightDocumentArchive.decode(fixture("bomb"), maximumExpandedBytes: 32_768) }
        try reject("malformed") { _ = try InsightDocumentArchive.decode(fixture("corrupt")) }
        try reject("malformed") { _ = try InsightDocumentArchive.decode(fixture("zip64")) }
        try reject("malformed") { _ = try InsightDocumentArchive.decode(Data([0x50, 0x4b, 3, 4])) }
        print("PASS: ZIP traversal/duplicates/encryption/bomb/CRC/ZIP64/truncation rejected")

        let word = InsightDOCXParser()
        try word.read(Data(#"<w:document xmlns:w="urn:word"><w:body><w:p><w:r><w:t>实际</w:t><w:tab/><w:t>正文</w:t></w:r></w:p><w:p><w:r><w:t>第二段</w:t></w:r></w:p></w:body></w:document>"#.utf8))
        try require(word.paragraphs == ["实际\t正文", "第二段"], "XML delegate did not extract exact DOCX paragraphs.")
        let strings = InsightSharedStringsParser()
        try strings.read(Data(#"<sst><si><r><t>真实</t></r><r><t>数据</t></r></si></sst>"#.utf8))
        try require(strings.values == ["真实数据"], "Rich shared strings were not reconstructed.")
        let sheet = InsightWorksheetParser(sharedStrings: strings.values)
        try sheet.read(Data(#"<worksheet><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1"><f>1+1</f><v>2</v></c></row></sheetData></worksheet>"#.utf8))
        try require(sheet.rows[1]?.map(\.reference) == ["A1", "B1"] && sheet.rows[1]?.map(\.text) == ["真实数据", "2"] && sheet.hasFormula,
                    "Worksheet citations, shared strings or saved formula values were wrong.")
        try reject("malformed") { try InsightDOCXParser().read(Data(#"<!DOCTYPE x [<!ENTITY secret SYSTEM "file:///etc/passwd">]><x>&secret;</x>"#.utf8)) }
        try reject("malformed") { try InsightWorksheetParser(sharedStrings: []).read(Data(#"<worksheet><row r="1"><c r="A2"><v>7</v></c></row></worksheet>"#.utf8)) }
        let csv = try InsightCSVParser.parse("耳号,说明\n001,\"跨\n行\"\n")
        try require(csv.count == 2 && csv[1].cells == ["001", "跨\n行"] && csv[1].startLine == 2 && csv[1].endLine == 3,
                    "Quoted CSV lost content or original line citations.")
        try reject("malformed") { _ = try InsightCSVParser.parse("\"unterminated") }
        print("PASS: real DOCX/XLSX XML callbacks, citation checks, entity rejection and multiline CSV")

        let document = PendingInsightDocument(id: UUID(), fileName: "data.txt", mimeType: "text/plain",
            rawData: Data("source".utf8), digest: "fixture-digest",
            sections: [.init(id: "text", title: "文本", blocks: [
                .init(id: 1, text: "可发送第一行", citation: "data.txt · 行 1"),
                .init(id: 2, text: "未选第二行", citation: "data.txt · 行 2"),
            ], totalBlockCount: 2)], issues: [])
        let range = InsightDocumentRange(sectionID: "text", firstBlock: 1, lastBlock: 1)
        try reject("partial") { _ = try document.selecting([range]) }
        let selected = try document.selecting([range], acknowledgesPartialContent: true)
        let context = try selected.modelContextText()
        try require(context.contains("可发送第一行") && !context.contains("未选第二行") && context.contains("data.txt · 行 1"),
                    "Unselected evidence entered model context or lost its citation.")
        try reject("range") { _ = try document.selecting([range, range], acknowledgesPartialContent: true) }
        print("PASS: explicit partial selection, source citations and no unselected model content")
        print("Document regression passed: 4 behavioral checks; real zlib/FoundationXML only, PDFKit and encrypted iOS storage not exercised.")
    }
}
