import Foundation
import SwiftUI

struct InsightMarkdownDocument: Equatable {
    enum Block: Equatable {
        case paragraph(String)
        case heading(level: Int, text: String)
        case unorderedList([String])
        case orderedList([String])
        case quote(String)
        case code(language: String?, text: String)
        case divider
        case table(InsightMarkdownTable)
    }

    let blocks: [Block]

    init(_ source: String) {
        blocks = Self.parse(source)
    }

    private static func parse(_ source: String) -> [Block] {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [Block] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let text = paragraph.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                blocks.append(.paragraph(text))
            }
            paragraph.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let marker = String(trimmed.prefix(3))
                let languageText = String(trimmed.dropFirst(3))
                    .trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                index += 1
                while index < lines.count {
                    let candidate = lines[index]
                    if candidate.trimmingCharacters(in: .whitespaces).hasPrefix(marker) {
                        index += 1
                        break
                    }
                    codeLines.append(candidate)
                    index += 1
                }
                blocks.append(.code(
                    language: languageText.isEmpty ? nil : languageText,
                    text: codeLines.joined(separator: "\n")
                ))
                continue
            }

            if index + 1 < lines.count,
               let table = InsightMarkdownTable(
                   headerLine: line,
                   separatorLine: lines[index + 1]
               ) {
                flushParagraph()
                index += 2
                var rows: [[String]] = []
                while index < lines.count {
                    let candidate = lines[index]
                    guard !candidate.trimmingCharacters(in: .whitespaces).isEmpty,
                          InsightMarkdownTable.containsUnescapedPipe(candidate) else {
                        break
                    }
                    rows.append(InsightMarkdownTable.cells(in: candidate))
                    index += 1
                }
                blocks.append(.table(table.withRows(rows)))
                continue
            }

            if let heading = heading(from: trimmed) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if isDivider(trimmed) {
                flushParagraph()
                blocks.append(.divider)
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoteLines: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    quoteLines.append(
                        String(candidate.dropFirst())
                            .trimmingCharacters(in: .whitespaces)
                    )
                    index += 1
                }
                blocks.append(.quote(quoteLines.joined(separator: "\n")))
                continue
            }

            if unorderedItem(from: trimmed) != nil {
                flushParagraph()
                var items: [String] = []
                while index < lines.count,
                      let item = unorderedItem(
                          from: lines[index].trimmingCharacters(in: .whitespaces)
                      ) {
                    items.append(item)
                    index += 1
                }
                blocks.append(.unorderedList(items))
                continue
            }

            if orderedItem(from: trimmed) != nil {
                flushParagraph()
                var items: [String] = []
                while index < lines.count,
                      let item = orderedItem(
                          from: lines[index].trimmingCharacters(in: .whitespaces)
                      ) {
                    items.append(item)
                    index += 1
                }
                blocks.append(.orderedList(items))
                continue
            }

            paragraph.append(line)
            index += 1
        }

        flushParagraph()
        return blocks
    }

    private static func heading(from line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes),
              line.dropFirst(hashes).first == " " else {
            return nil
        }
        let text = line.dropFirst(hashes)
            .trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return (hashes, text)
    }

    private static func isDivider(_ line: String) -> Bool {
        let compact = line.filter { !$0.isWhitespace }
        guard compact.count >= 3, let marker = compact.first else { return false }
        return ["-", "*", "_"].contains(marker) && compact.allSatisfy { $0 == marker }
    }

    private static func unorderedItem(from line: String) -> String? {
        guard line.count >= 2 else { return nil }
        let prefix = line.prefix(2)
        guard prefix == "- " || prefix == "* " || prefix == "+ " else { return nil }
        return String(line.dropFirst(2))
    }

    private static func orderedItem(from line: String) -> String? {
        guard let period = line.firstIndex(of: "."),
              period != line.startIndex else {
            return nil
        }
        let number = line[..<period]
        let afterPeriod = line.index(after: period)
        guard number.allSatisfy(\.isNumber),
              afterPeriod < line.endIndex,
              line[afterPeriod] == " " else {
            return nil
        }
        return String(line[line.index(after: afterPeriod)...])
    }
}

struct InsightMarkdownTable: Equatable {
    enum Alignment: Equatable {
        case leading
        case center
        case trailing
    }

    let headers: [String]
    let alignments: [Alignment]
    let rows: [[String]]

    init?(headerLine: String, separatorLine: String) {
        guard Self.containsUnescapedPipe(headerLine),
              Self.containsUnescapedPipe(separatorLine) else {
            return nil
        }
        let headers = Self.cells(in: headerLine)
        let separators = Self.cells(in: separatorLine)
        guard headers.count >= 2,
              separators.count == headers.count,
              separators.allSatisfy(Self.isSeparatorCell) else {
            return nil
        }
        self.headers = headers
        self.alignments = separators.map(Self.alignment)
        self.rows = []
    }

    private init(
        headers: [String],
        alignments: [Alignment],
        rows: [[String]]
    ) {
        self.headers = headers
        self.alignments = alignments
        self.rows = rows
    }

    func withRows(_ rows: [[String]]) -> Self {
        Self(
            headers: headers,
            alignments: alignments,
            rows: rows.map(normalizedRow)
        )
    }

    func width(forColumn index: Int) -> CGFloat {
        let values = [headers[index]] + rows.map { $0[index] }
        let longest = values.map(\.count).max() ?? 0
        return min(max(CGFloat(longest) * 7.2 + 28, 96), 220)
    }

    static func containsUnescapedPipe(_ line: String) -> Bool {
        var escaped = false
        var inCode = false
        for character in line {
            if escaped {
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
            } else if character == "`" {
                inCode.toggle()
            } else if character == "|", !inCode {
                return true
            }
        }
        return false
    }

    static func cells(in line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        var cells: [String] = []
        var current = ""
        var escaped = false
        var inCode = false

        for character in trimmed {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            if character == "`" {
                inCode.toggle()
                current.append(character)
                continue
            }
            if character == "|", !inCode {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped {
            current.append("\\")
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))

        if trimmed.hasPrefix("|"), cells.first?.isEmpty == true {
            cells.removeFirst()
        }
        if trimmed.hasSuffix("|"), cells.last?.isEmpty == true {
            cells.removeLast()
        }
        return cells
    }

    private func normalizedRow(_ row: [String]) -> [String] {
        if row.count == headers.count {
            return row
        }
        if row.count > headers.count {
            return Array(row.prefix(headers.count))
        }
        return row + Array(repeating: "", count: headers.count - row.count)
    }

    private static func isSeparatorCell(_ cell: String) -> Bool {
        let trimmed = cell.trimmingCharacters(in: .whitespaces)
        let withoutColons = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        return withoutColons.count >= 3 && withoutColons.allSatisfy { $0 == "-" }
    }

    private static func alignment(_ cell: String) -> Alignment {
        let trimmed = cell.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix(":"), trimmed.hasSuffix(":") {
            return .center
        }
        if trimmed.hasSuffix(":") {
            return .trailing
        }
        return .leading
    }
}

struct InsightMarkdownView: View {
    private let document: InsightMarkdownDocument
    let foregroundColor: Color
    let tableBackgroundColor: Color
    let tableAccentColor: Color
    let expandsHorizontally: Bool

    init(
        _ markdown: String,
        foregroundColor: Color = .primary,
        tableBackgroundColor: Color = Color(uiColor: .secondarySystemBackground),
        tableAccentColor: Color = .accentColor,
        expandsHorizontally: Bool = true
    ) {
        document = InsightMarkdownDocument(markdown)
        self.foregroundColor = foregroundColor
        self.tableBackgroundColor = tableBackgroundColor
        self.tableAccentColor = tableAccentColor
        self.expandsHorizontally = expandsHorizontally
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(
            maxWidth: expandsHorizontally ? .infinity : nil,
            alignment: .leading
        )
        .textSelection(.enabled)
        .tint(foregroundColor)
    }

    @ViewBuilder
    private func blockView(_ block: InsightMarkdownDocument.Block) -> some View {
        switch block {
        case .paragraph(let text):
            InsightMarkdownInlineText(text: text, foregroundColor: foregroundColor)
        case .heading(let level, let text):
            InsightMarkdownInlineText(text: text, foregroundColor: foregroundColor)
                .font(headingFont(level))
                .padding(.top, level <= 2 ? 2 : 0)
        case .unorderedList(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("•")
                        InsightMarkdownInlineText(
                            text: item,
                            foregroundColor: foregroundColor
                        )
                    }
                }
            }
        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("\(index + 1).")
                            .monospacedDigit()
                        InsightMarkdownInlineText(
                            text: item,
                            foregroundColor: foregroundColor
                        )
                    }
                }
            }
        case .quote(let text):
            HStack(alignment: .top, spacing: 9) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(foregroundColor.opacity(0.35))
                    .frame(width: 3)
                InsightMarkdownInlineText(
                    text: text,
                    foregroundColor: foregroundColor.opacity(0.82)
                )
            }
        case .code(let language, let text):
            VStack(alignment: .leading, spacing: 5) {
                if let language {
                    Text(language.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(foregroundColor.opacity(0.62))
                }
                ScrollView(.horizontal) {
                    Text(text)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(foregroundColor)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(10)
                }
                .scrollIndicators(.visible)
                .background(tableBackgroundColor, in: .rect(cornerRadius: 9))
            }
        case .divider:
            Divider()
                .overlay(foregroundColor.opacity(0.18))
        case .table(let table):
            InsightMarkdownTableView(
                table: table,
                foregroundColor: foregroundColor,
                backgroundColor: tableBackgroundColor,
                accentColor: tableAccentColor
            )
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1:
            .title3.bold()
        case 2:
            .headline
        default:
            .subheadline.weight(.semibold)
        }
    }
}

private struct InsightMarkdownInlineText: View {
    let text: String
    let foregroundColor: Color

    var body: some View {
        Text(attributedText)
            .foregroundStyle(foregroundColor)
    }

    private var attributedText: AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}

private struct InsightMarkdownTableView: View {
    private enum ColumnRole {
        case index
        case text
        case number
        case status
    }

    private enum StatusKind {
        case success
        case pending
        case warning
        case failure

        var symbol: String {
            switch self {
            case .success:
                "checkmark.circle.fill"
            case .pending:
                "clock.fill"
            case .warning:
                "exclamationmark.triangle.fill"
            case .failure:
                "xmark.circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .success:
                .green
            case .pending, .warning:
                .orange
            case .failure:
                .red
            }
        }
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption) private var headerHeight: CGFloat = 38
    @ScaledMetric(relativeTo: .caption) private var bodyRowHeight: CGFloat = 42

    let table: InsightMarkdownTable
    let foregroundColor: Color
    let backgroundColor: Color
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if usesHorizontalScrolling {
                Label("横向滑动查看更多列", systemImage: "arrow.left.and.right")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(foregroundColor.opacity(0.72))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(foregroundColor.opacity(0.07), in: .capsule)
            }

            Group {
                if usesHorizontalScrolling {
                    ScrollView(.horizontal) {
                        tableBody(widths: naturalColumnWidths)
                    }
                    .scrollIndicators(.hidden)
                } else {
                    GeometryReader { proxy in
                        tableBody(widths: compactColumnWidths(totalWidth: proxy.size.width))
                    }
                    .frame(height: tableHeight)
                }
            }
            .background(backgroundColor, in: .rect(cornerRadius: 12))
            .clipShape(.rect(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(foregroundColor.opacity(0.10), lineWidth: 0.75)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Markdown 表格，\(table.headers.count) 列，\(table.rows.count) 行")
    }

    private var usesHorizontalScrolling: Bool {
        table.headers.count > 4 || dynamicTypeSize.isAccessibilitySize
    }

    private var tableHeight: CGFloat {
        headerHeight + bodyRowHeight * CGFloat(table.rows.count)
    }

    private var naturalColumnWidths: [CGFloat] {
        table.headers.indices.map { table.width(forColumn: $0) }
    }

    private func compactColumnWidths(totalWidth: CGFloat) -> [CGFloat] {
        let weights = table.headers.indices.map { index -> CGFloat in
            switch role(forColumn: index) {
            case .index:
                0.48
            case .text:
                1.55
            case .number:
                0.72
            case .status:
                0.62
            }
        }
        let totalWeight = max(weights.reduce(0, +), 1)
        return weights.map { totalWidth * $0 / totalWeight }
    }

    private func tableBody(widths: [CGFloat]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            row(table.headers, rowIndex: nil, widths: widths)
            ForEach(Array(table.rows.enumerated()), id: \.offset) { index, cells in
                row(cells, rowIndex: index, widths: widths)
            }
        }
    }

    private func row(
        _ cells: [String],
        rowIndex: Int?,
        widths: [CGFloat]
    ) -> some View {
        let isHeader = rowIndex == nil
        return HStack(spacing: 0) {
            ForEach(table.headers.indices, id: \.self) { index in
                cell(
                    cells[index],
                    columnIndex: index,
                    isHeader: isHeader
                )
                .padding(.horizontal, horizontalPadding(forColumn: index))
                .frame(
                    width: widths[index],
                    height: isHeader ? headerHeight : bodyRowHeight,
                    alignment: frameAlignment(table.alignments[index])
                )
            }
        }
        .background(rowBackground(rowIndex: rowIndex))
        .overlay(alignment: .bottom) {
            if rowIndex != table.rows.indices.last {
                Rectangle()
                    .fill(foregroundColor.opacity(isHeader ? 0.12 : 0.075))
                    .frame(height: 0.5)
            }
        }
    }

    @ViewBuilder
    private func cell(
        _ text: String,
        columnIndex: Int,
        isHeader: Bool
    ) -> some View {
        if !isHeader,
           role(forColumn: columnIndex) == .status,
           let status = statusKind(for: text) {
            HStack(spacing: 4) {
                Image(systemName: status.symbol)
                    .symbolRenderingMode(.hierarchical)
                if let label = statusLabel(from: text) {
                    Text(label)
                        .lineLimit(1)
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(status.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(status.color.opacity(0.12), in: .capsule)
            .accessibilityLabel(text)
        } else {
            InsightMarkdownInlineText(
                text: text,
                foregroundColor: isHeader
                    ? foregroundColor.opacity(0.78)
                    : foregroundColor
            )
            .font(isHeader ? .caption.weight(.semibold) : .caption)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.78)
        }
    }

    private func rowBackground(rowIndex: Int?) -> Color {
        guard let rowIndex else {
            return accentColor.opacity(0.11)
        }
        return rowIndex.isMultiple(of: 2)
            ? Color.clear
            : foregroundColor.opacity(0.035)
    }

    private func horizontalPadding(forColumn index: Int) -> CGFloat {
        switch role(forColumn: index) {
        case .index, .status:
            6
        case .text, .number:
            10
        }
    }

    private func role(forColumn index: Int) -> ColumnRole {
        let header = table.headers[index]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if ["#", "序号", "编号", "index", "no.", "no"].contains(header) {
            return .index
        }
        if header.contains("状态")
            || header.contains("结果")
            || header.contains("确认")
            || header.contains("status") {
            return .status
        }
        if header.contains("公斤")
            || header == "kg"
            || header.contains("重量")
            || header.contains("数量")
            || header.contains("数值")
            || header.contains("weight")
            || header.contains("amount") {
            return .number
        }
        return .text
    }

    private func statusKind(for text: String) -> StatusKind? {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalized.contains("✅")
            || ["已执行", "已完成", "成功", "正常", "通过", "已确认"].contains(normalized) {
            return .success
        }
        if normalized.contains("⏳")
            || normalized.contains("待确认")
            || normalized.contains("待处理") {
            return .pending
        }
        if normalized.contains("⚠")
            || normalized.contains("注意")
            || normalized.contains("模糊") {
            return .warning
        }
        if normalized.contains("❌")
            || normalized.contains("失败")
            || normalized.contains("异常")
            || normalized.contains("未录入") {
            return .failure
        }
        return nil
    }

    private func statusLabel(from text: String) -> String? {
        let label = text
            .replacingOccurrences(of: "✅", with: "")
            .replacingOccurrences(of: "⏳", with: "")
            .replacingOccurrences(of: "⚠️", with: "")
            .replacingOccurrences(of: "⚠", with: "")
            .replacingOccurrences(of: "❌", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? nil : label
    }

    private func frameAlignment(_ alignment: InsightMarkdownTable.Alignment) -> Alignment {
        switch alignment {
        case .leading:
            .leading
        case .center:
            .center
        case .trailing:
            .trailing
        }
    }
}
