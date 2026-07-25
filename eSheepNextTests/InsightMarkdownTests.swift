import XCTest
@testable import eSheepNext

final class InsightMarkdownTests: XCTestCase {
    func testParsesGFMTableWithAlignmentAndRows() {
        let document = InsightMarkdownDocument(
            """
            ## 圈舍投喂

            | 圈舍 | 投喂量 | 状态 |
            |:---|---:|:---:|
            | 一舍 | 120 kg | 正常 |
            | 二舍 | 98 kg | 偏低 |
            """
        )

        XCTAssertEqual(document.blocks.count, 2)
        guard case .table(let table) = document.blocks[1] else {
            return XCTFail("Expected a Markdown table")
        }
        XCTAssertEqual(table.headers, ["圈舍", "投喂量", "状态"])
        XCTAssertEqual(table.alignments, [.leading, .trailing, .center])
        XCTAssertEqual(table.rows, [
            ["一舍", "120 kg", "正常"],
            ["二舍", "98 kg", "偏低"],
        ])
    }

    func testTableKeepsEscapedAndInlineCodePipesInsideCell() {
        let document = InsightMarkdownDocument(
            """
            | 项目 | 内容 |
            | --- | --- |
            | 备注 | A\\|B |
            | 代码 | `x|y` |
            """
        )

        guard case .table(let table) = document.blocks.first else {
            return XCTFail("Expected a Markdown table")
        }
        XCTAssertEqual(table.rows[0], ["备注", "A|B"])
        XCTAssertEqual(table.rows[1], ["代码", "`x|y`"])
    }

    func testPipeTextWithoutSeparatorRemainsParagraph() {
        let document = InsightMarkdownDocument("羊只 A | 羊只 B\n这不是表格")

        XCTAssertEqual(
            document.blocks,
            [.paragraph("羊只 A | 羊只 B\n这不是表格")]
        )
    }

    func testFencedMarkdownIsShownAsCodeInsteadOfRenderedTable() {
        let document = InsightMarkdownDocument(
            """
            ```markdown
            | 羊只 | 体重 |
            | --- | --- |
            | 001 | 50 |
            ```
            """
        )

        XCTAssertEqual(document.blocks.count, 1)
        guard case .code(let language, let text) = document.blocks[0] else {
            return XCTFail("Expected a code block")
        }
        XCTAssertEqual(language, "markdown")
        XCTAssertTrue(text.contains("| 001 | 50 |"))
    }

    func testShortDashRowIsNotAcceptedAsTableSeparator() {
        let document = InsightMarkdownDocument(
            """
            | A | B |
            | -- | --- |
            """
        )

        XCTAssertEqual(
            document.blocks,
            [.paragraph("| A | B |\n| -- | --- |")]
        )
    }
}
