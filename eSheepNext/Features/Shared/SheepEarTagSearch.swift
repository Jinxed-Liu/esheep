import Foundation
import SwiftUI

struct SheepEarTagSearchCandidate: Identifiable, Hashable, Sendable {
    let id: UUID
    let earTag: String
    let detail: String
    let normalizedEarTag: String

    init(id: UUID, earTag: String, detail: String = "") {
        self.id = id
        self.earTag = earTag
        self.detail = detail
        self.normalizedEarTag = EarTag.normalized(earTag)
    }

    init(sheep: SheepRecord, detail: String? = nil) {
        self.id = sheep.id
        self.earTag = sheep.earTag
        self.detail = detail ?? [sheep.sex.displayName, sheep.breed]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        self.normalizedEarTag = EarTag.normalized(sheep.earTag)
    }
}

struct SheepEarTagSearchResultSet: Equatable {
    let matches: [SheepEarTagSearchCandidate]
    let totalCount: Int

    var hasMore: Bool { totalCount > matches.count }
}

enum SheepEarTagSearchMatcher {
    static let defaultLimit = 8

    static func search(
        query: String,
        candidates: [SheepEarTagSearchCandidate],
        excluding excludedIDs: Set<UUID> = [],
        limit: Int = defaultLimit
    ) -> SheepEarTagSearchResultSet {
        let normalizedQuery = EarTag.normalized(query)
        guard !normalizedQuery.isEmpty else {
            return SheepEarTagSearchResultSet(matches: [], totalCount: 0)
        }

        let boundedLimit = max(0, limit)
        var totalCount = 0
        var topMatches: [(candidate: SheepEarTagSearchCandidate, rank: Int)] = []
        topMatches.reserveCapacity(boundedLimit)

        for candidate in candidates {
            guard !excludedIDs.contains(candidate.id),
                  let rank = matchRank(normalizedEarTag: candidate.normalizedEarTag, query: normalizedQuery)
            else { continue }
            totalCount += 1

            guard boundedLimit > 0 else { continue }
            let match = (candidate: candidate, rank: rank)
            let insertionIndex = topMatches.firstIndex { isOrderedBefore(match, $0) } ?? topMatches.endIndex
            if insertionIndex < boundedLimit {
                topMatches.insert(match, at: insertionIndex)
                if topMatches.count > boundedLimit {
                    topMatches.removeLast()
                }
            } else if topMatches.count < boundedLimit {
                topMatches.append(match)
            }
        }

        return SheepEarTagSearchResultSet(
            matches: topMatches.map(\.candidate),
            totalCount: totalCount
        )
    }

    private static func matchRank(normalizedEarTag: String, query: String) -> Int? {
        if normalizedEarTag == query { return 0 }
        if normalizedEarTag.hasPrefix(query) { return 1 }
        if normalizedEarTag.contains(query) { return 2 }
        return nil
    }

    private static func isOrderedBefore(
        _ lhs: (candidate: SheepEarTagSearchCandidate, rank: Int),
        _ rhs: (candidate: SheepEarTagSearchCandidate, rank: Int)
    ) -> Bool {
        if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
        let tagOrder = lhs.candidate.earTag.localizedStandardCompare(rhs.candidate.earTag)
        if tagOrder != .orderedSame { return tagOrder == .orderedAscending }
        return lhs.candidate.id.uuidString < rhs.candidate.id.uuidString
    }
}

struct SheepEarTagSingleSearchField: View {
    let candidates: [SheepEarTagSearchCandidate]
    @Binding var selection: UUID?
    var prompt = "输入耳号搜索"
    var emptySelectionText = "尚未选择羊只"
    var accessibilityName = "羊只耳号"

    @State private var query = ""

    private var selectedCandidate: SheepEarTagSearchCandidate? {
        selection.flatMap { selectedID in candidates.first { $0.id == selectedID } }
    }

    var body: some View {
        let hasQuery = !EarTag.normalized(query).isEmpty
        let resultSet = hasQuery
            ? SheepEarTagSearchMatcher.search(
                query: query,
                candidates: candidates,
                excluding: selection.map { Set([$0]) } ?? []
            )
            : SheepEarTagSearchResultSet(matches: [], totalCount: 0)

        Group {
            if let selectedCandidate {
                selectedRow(selectedCandidate)
            } else if selection != nil {
                unavailableSelectionRow
            } else if !hasQuery {
                Text(emptySelectionText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            searchField

            if hasQuery {
                searchResults(resultSet)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(selection == nil ? prompt : "重新搜索耳号", text: $query)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .accessibilityLabel(accessibilityName)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("清除搜索词")
            }
        }
    }

    @ViewBuilder
    private func searchResults(_ resultSet: SheepEarTagSearchResultSet) -> some View {
        if resultSet.matches.isEmpty {
            Text("没有匹配的耳号")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            ForEach(resultSet.matches) { candidate in
                Button {
                    selection = candidate.id
                    query = ""
                } label: {
                    SheepEarTagSearchCandidateRow(candidate: candidate, systemImage: "plus.circle")
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityLabel("选择耳号 \(candidate.earTag)")
            }
            if resultSet.hasMore {
                remainingResultHint(resultSet.totalCount - resultSet.matches.count)
            }
        }
    }

    private func selectedRow(_ candidate: SheepEarTagSearchCandidate) -> some View {
        HStack(spacing: 12) {
            SheepEarTagSearchCandidateRow(candidate: candidate, systemImage: "checkmark.circle.fill")
            Button {
                selection = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("清除已选耳号 \(candidate.earTag)")
        }
    }

    private var unavailableSelectionRow: some View {
        HStack {
            Text("已选羊只不再符合当前条件")
                .font(.footnote)
                .foregroundStyle(.orange)
            Spacer()
            Button("清除") { selection = nil }
                .buttonStyle(.borderless)
        }
    }
}

struct SheepEarTagMultiSearchField: View {
    let candidates: [SheepEarTagSearchCandidate]
    @Binding var selection: Set<UUID>
    var maximumSelectionCount: Int? = nil
    var showsSelectedCandidates = true
    var prompt = "输入耳号搜索并添加"
    var emptySelectionText = "尚未添加羊只"
    var accessibilityName = "羊只耳号"

    @State private var query = ""

    private var selectedCandidates: [SheepEarTagSearchCandidate] {
        candidates
            .filter { selection.contains($0.id) }
            .sorted { lhs, rhs in
                let tagOrder = lhs.earTag.localizedStandardCompare(rhs.earTag)
                if tagOrder != .orderedSame { return tagOrder == .orderedAscending }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    var body: some View {
        let hasQuery = !EarTag.normalized(query).isEmpty
        let selectedCandidates = selectedCandidates
        let resultSet = hasQuery
            ? SheepEarTagSearchMatcher.search(
                query: query,
                candidates: candidates,
                excluding: selection
            )
            : SheepEarTagSearchResultSet(matches: [], totalCount: 0)

        Group {
            if showsSelectedCandidates {
                if selectedCandidates.isEmpty, !hasQuery {
                    Text(emptySelectionText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(selectedCandidates) { candidate in
                        selectedRow(candidate)
                    }
                }
            }

            searchField

            if hasQuery {
                searchResults(resultSet)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(prompt, text: $query)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .accessibilityLabel(accessibilityName)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("清除搜索词")
            }
        }
    }

    @ViewBuilder
    private func searchResults(_ resultSet: SheepEarTagSearchResultSet) -> some View {
        if resultSet.matches.isEmpty {
            Text("没有匹配的耳号")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            ForEach(resultSet.matches) { candidate in
                Button {
                    add(candidate.id)
                    query = ""
                } label: {
                    SheepEarTagSearchCandidateRow(candidate: candidate, systemImage: "plus.circle")
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityLabel("添加耳号 \(candidate.earTag)")
            }
            if resultSet.hasMore {
                remainingResultHint(resultSet.totalCount - resultSet.matches.count)
            }
        }
    }

    private func selectedRow(_ candidate: SheepEarTagSearchCandidate) -> some View {
        HStack(spacing: 12) {
            SheepEarTagSearchCandidateRow(candidate: candidate, systemImage: "checkmark.circle.fill")
            Button {
                selection.remove(candidate.id)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("移除耳号 \(candidate.earTag)")
        }
    }

    private func add(_ id: UUID) {
        if maximumSelectionCount == 1 {
            selection = [id]
        } else if let maximumSelectionCount, selection.count >= maximumSelectionCount {
            return
        } else {
            selection.insert(id)
        }
    }
}

private struct SheepEarTagSearchCandidateRow: View {
    let candidate: SheepEarTagSearchCandidate
    let systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.earTag)
                    .foregroundStyle(.primary)
                if !candidate.detail.isEmpty {
                    Text(candidate.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
        }
    }
}

private func remainingResultHint(_ count: Int) -> some View {
    Text("另有 \(count) 条匹配，请继续输入耳号缩小范围。")
        .font(.footnote)
        .foregroundStyle(.secondary)
}
