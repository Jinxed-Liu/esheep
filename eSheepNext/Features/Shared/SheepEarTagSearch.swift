import Foundation
import SwiftData
import SwiftUI

struct SheepEarTagSearchCandidate: Identifiable, Hashable, Sendable {
    let id: UUID
    let earTag: String
    let detail: String
    /// The structured values used by the row renderer. Keeping these separate
    /// prevents a localized sex label and a user-entered breed from being
    /// flattened into one string and then treated as a localization key.
    let sex: SheepSex?
    let breed: String?
    let normalizedEarTag: String
    let birthAt: Date?

    init(
        id: UUID,
        earTag: String,
        detail: String = "",
        birthAt: Date? = nil,
        sex: SheepSex? = nil,
        breed: String? = nil
    ) {
        self.id = id
        self.earTag = earTag
        self.detail = detail
        self.sex = sex
        self.breed = breed
        self.normalizedEarTag = EarTag.normalized(earTag)
        self.birthAt = birthAt
    }

    init(sheep: SheepRecord, detail: String? = nil) {
        self.id = sheep.id
        self.earTag = sheep.earTag
        self.detail = detail ?? [sheep.sex.displayName, sheep.breed]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        self.sex = detail == nil ? sheep.sex : nil
        self.breed = detail == nil ? sheep.breed : nil
        self.normalizedEarTag = EarTag.normalized(sheep.earTag)
        self.birthAt = sheep.birthAt
    }
}

enum SheepEarTagCandidateScope: Sendable {
    case active
    case allNonDeleted
}

/// Produces the lightweight values used by form ear-tag search without
/// making the form hold a live, farm-wide @Query collection on the main
/// actor. The command still saves through the regular ModelContext and only
/// the selected UUID crosses back to the form.
actor SheepEarTagCandidateSnapshotActor {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func load(
        farmID: UUID,
        scope: SheepEarTagCandidateScope
    ) throws -> [SheepEarTagSearchCandidate] {
        try Task.checkCancellation()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let records: [SheepRecord]
        switch scope {
        case .active:
            let activeStatus = SheepStatus.active.rawValue
            records = try context.fetch(FetchDescriptor<SheepRecord>(
                predicate: #Predicate {
                    $0.farmID == farmID &&
                        $0.deletedAt == nil &&
                        $0.statusRawValue == activeStatus &&
                        $0.isHistoricalArchive == false
                },
                sortBy: [SortDescriptor(\.earTag)]
            ))
        case .allNonDeleted:
            records = try context.fetch(FetchDescriptor<SheepRecord>(
                predicate: #Predicate {
                    $0.farmID == farmID && $0.deletedAt == nil
                },
                sortBy: [SortDescriptor(\.earTag)]
            ))
        }
        try Task.checkCancellation()
        return records.map { SheepEarTagSearchCandidate(sheep: $0) }
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
                Text(LocalizedStringKey(emptySelectionText))
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
            TextField(
                LocalizedStringKey(selection == nil ? prompt : "重新搜索耳号"),
                text: $query
            )
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
                    Text(LocalizedStringKey(emptySelectionText))
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
            TextField(LocalizedStringKey(prompt), text: $query)
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
                if let sex = candidate.sex {
                    HStack(spacing: 0) {
                        Text(LocalizedStringKey(sex.displayName))
                        if let breed = candidate.breed, !breed.isEmpty {
                            Text(" · ")
                            Text(verbatim: breed)
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                } else if !candidate.detail.isEmpty {
                    Text(verbatim: candidate.detail)
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
