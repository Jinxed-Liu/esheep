import Foundation

struct SheepPresenceSnapshot: Sendable, Hashable {
    let sheepID: UUID
    let initialPenID: UUID?
    let enteredAt: Date
    let removedAt: Date?
}

struct TransferSnapshot: Sendable, Hashable {
    let sheepID: UUID
    let toPenID: UUID?
    let occurredAt: Date
    let recordedAt: Date
    let stableID: UUID

    init(sheepID: UUID, toPenID: UUID?, occurredAt: Date, recordedAt: Date? = nil, stableID: UUID = UUID()) {
        self.sheepID = sheepID
        self.toPenID = toPenID
        self.occurredAt = occurredAt
        self.recordedAt = recordedAt ?? occurredAt
        self.stableID = stableID
    }
}

struct FeedSnapshot: Sendable, Hashable {
    let feedID: UUID
    let penID: UUID
    let ingredientID: UUID
    let ingredientName: String
    let kilograms: Decimal
    let mode: FeedMode
    let occurredAt: Date
}

struct IngredientIntakeResult: Sendable, Hashable, Identifiable {
    var id: UUID { ingredientID }
    let ingredientID: UUID
    let ingredientName: String
    let kilograms: Decimal
    let sheepDays: Decimal
    let kilogramsPerSheepDay: Decimal?
    let completeIntervals: Int
    let hasMissingFinalBoundary: Bool
}

enum FarmAnalytics {
    static func sheepCount(
        in penID: UUID,
        at date: Date,
        sheep: [SheepPresenceSnapshot],
        transfers: [TransferSnapshot]
    ) -> Int {
        sheep.reduce(into: 0) { count, sheepItem in
            guard sheepItem.enteredAt <= date, sheepItem.removedAt.map({ $0 > date }) ?? true else { return }
            let currentPen = pen(at: date, for: sheepItem, transfers: transfers)
            if currentPen == penID { count += 1 }
        }
    }

    static func sheepDays(
        in penID: UUID,
        from start: Date,
        to end: Date,
        sheep: [SheepPresenceSnapshot],
        transfers: [TransferSnapshot],
        calendar: Calendar = .current
    ) -> Decimal {
        guard start < end else { return 0 }
        _ = calendar // Retained in the public API so callers keep their farm-calendar contract.
        var boundaries = [start, end]
        boundaries.append(contentsOf: sheep.flatMap { item in
            [item.enteredAt, item.removedAt].compactMap { instant in
                guard let instant, start < instant, instant < end else { return nil }
                return instant
            }
        })
        boundaries.append(contentsOf: transfers.compactMap { transfer in
            guard start < transfer.occurredAt, transfer.occurredAt < end else { return nil }
            return transfer.occurredAt
        })

        let orderedBoundaries = Array(Set(boundaries)).sorted()
        var total = Decimal.zero
        for (segmentStart, segmentEnd) in zip(orderedBoundaries, orderedBoundaries.dropFirst()) {
            guard segmentStart < segmentEnd else { continue }
            let duration = segmentEnd.timeIntervalSince(segmentStart) / 86_400
            let headCount = sheepCount(in: penID, at: segmentStart, sheep: sheep, transfers: transfers)
            total += Decimal(headCount) * Decimal(duration)
        }
        return total
    }

    static func freeChoiceIntake(
        from feeds: [FeedSnapshot],
        sheep: [SheepPresenceSnapshot],
        transfers: [TransferSnapshot],
        calendar: Calendar = .current
    ) -> [IngredientIntakeResult] {
        let presenceIndex = PenPresenceIndex(sheep: sheep, transfers: transfers)
        let freeFeeds = feeds.filter { $0.mode == .freeChoice }
        let groups = Dictionary(grouping: freeFeeds) { snapshot in
            "\(snapshot.penID.uuidString)|\(snapshot.ingredientID.uuidString)"
        }

        return groups.values.compactMap { group in
            guard let first = group.first else { return nil }
            let byDay = Dictionary(grouping: group) { calendar.startOfDay(for: $0.occurredAt) }
            let days = byDay.keys.sorted()
            guard !days.isEmpty else { return nil }

            var kilograms = Decimal.zero
            var totalSheepDays = Decimal.zero
            var intervals = 0
            for index in days.indices.dropLast() {
                let day = days[index]
                guard let nextDay = days[safe: index + 1] else { continue }
                let dayQuantity = (byDay[day] ?? []).reduce(Decimal.zero) { $0 + $1.kilograms }
                kilograms += dayQuantity
                totalSheepDays += presenceIndex.sheepDays(in: first.penID, from: day, to: nextDay)
                intervals += 1
            }
            let isComplete = days.count > 1
            return IngredientIntakeResult(
                ingredientID: first.ingredientID,
                ingredientName: first.ingredientName,
                kilograms: kilograms,
                sheepDays: totalSheepDays,
                kilogramsPerSheepDay: totalSheepDays > 0 ? kilograms / totalSheepDays : nil,
                completeIntervals: intervals,
                hasMissingFinalBoundary: !isComplete || days.count >= 1
            )
        }
        .sorted { $0.ingredientName.localizedStandardCompare($1.ingredientName) == .orderedAscending }
    }

    private struct PenPresenceIndex {
        private struct Point {
            let date: Date
            let count: Int
        }

        private let pointsByPen: [UUID: [Point]]

        init(sheep: [SheepPresenceSnapshot], transfers: [TransferSnapshot]) {
            let transfersBySheep = Dictionary(grouping: transfers, by: \.sheepID).mapValues {
                $0.sorted {
                    if $0.occurredAt == $1.occurredAt {
                        if $0.recordedAt == $1.recordedAt { return $0.stableID.uuidString < $1.stableID.uuidString }
                        return $0.recordedAt < $1.recordedAt
                    }
                    return $0.occurredAt < $1.occurredAt
                }
            }
            var changes: [UUID: [Date: Int]] = [:]

            func apply(_ delta: Int, penID: UUID?, at date: Date) {
                guard let penID else { return }
                changes[penID, default: [:]][date, default: 0] += delta
            }

            for sheepItem in sheep {
                let history = transfersBySheep[sheepItem.sheepID] ?? []
                var currentPen = sheepItem.initialPenID
                var firstFutureIndex = history.startIndex
                for index in history.indices {
                    let transfer = history[index]
                    guard transfer.occurredAt <= sheepItem.enteredAt else {
                        firstFutureIndex = index
                        break
                    }
                    currentPen = transfer.toPenID
                    firstFutureIndex = history.index(after: index)
                }

                apply(1, penID: currentPen, at: sheepItem.enteredAt)
                for index in history.indices where index >= firstFutureIndex {
                    let transfer = history[index]
                    guard transfer.occurredAt < (sheepItem.removedAt ?? .distantFuture) else { break }
                    apply(-1, penID: currentPen, at: transfer.occurredAt)
                    currentPen = transfer.toPenID
                    apply(1, penID: currentPen, at: transfer.occurredAt)
                }
                if let removedAt = sheepItem.removedAt {
                    apply(-1, penID: currentPen, at: removedAt)
                }
            }

            pointsByPen = changes.mapValues { datedChanges in
                var runningCount = 0
                return datedChanges.keys.sorted().map { date in
                    runningCount += datedChanges[date] ?? 0
                    return Point(date: date, count: runningCount)
                }
            }
        }

        func sheepDays(in penID: UUID, from start: Date, to end: Date) -> Decimal {
            guard start < end, let points = pointsByPen[penID], !points.isEmpty else { return 0 }
            let firstAfterStart = upperBound(of: start, in: points)
            var currentCount = firstAfterStart > 0 ? points[firstAfterStart - 1].count : 0
            var currentDate = start
            var sheepDays = Decimal.zero

            for point in points[firstAfterStart...] {
                guard point.date < end else { break }
                sheepDays += Decimal(currentCount) * Decimal(point.date.timeIntervalSince(currentDate) / 86_400)
                currentDate = point.date
                currentCount = point.count
            }
            sheepDays += Decimal(currentCount) * Decimal(end.timeIntervalSince(currentDate) / 86_400)
            return sheepDays
        }

        private func upperBound(of date: Date, in points: [Point]) -> Int {
            var lower = 0
            var upper = points.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if points[middle].date <= date { lower = middle + 1 } else { upper = middle }
            }
            return lower
        }
    }

    static func inferredSireCandidates(
        for eweID: UUID,
        lambingAt: Date,
        sheep: [SheepPresenceSnapshot],
        sexes: [UUID: SheepSex],
        transfers: [TransferSnapshot],
        calendar: Calendar = .current
    ) -> [UUID] {
        let conceptionDate = calendar.date(byAdding: .day, value: -150, to: lambingAt) ?? lambingAt
        guard let ewe = sheep.first(where: { $0.sheepID == eweID }), let penID = pen(at: conceptionDate, for: ewe, transfers: transfers) else {
            return []
        }
        return sheep.compactMap { candidate in
            guard sexes[candidate.sheepID] == .ram else { return nil }
            return pen(at: conceptionDate, for: candidate, transfers: transfers) == penID ? candidate.sheepID : nil
        }
    }

    private static func pen(at date: Date, for sheep: SheepPresenceSnapshot, transfers: [TransferSnapshot]) -> UUID? {
        let relevant = transfers
            .filter { $0.sheepID == sheep.sheepID && $0.occurredAt <= date }
            .sorted {
                if $0.occurredAt == $1.occurredAt {
                    if $0.recordedAt == $1.recordedAt {
                        return $0.stableID.uuidString < $1.stableID.uuidString
                    }
                    return $0.recordedAt < $1.recordedAt
                }
                return $0.occurredAt < $1.occurredAt
            }
        return relevant.last?.toPenID ?? sheep.initialPenID
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}

struct LocalFarmAnswer: Sendable, Equatable {
    let text: String
    let sources: [String]
}

enum LocalFarmAssistant {
    static func answer(
        question: String,
        activeSheep: [SheepRecord],
        pens: [PenRecord],
        feedRecords: [FeedRecord],
        healthRecords: [HealthRecord],
        analyticsSnapshot: FarmAnalyticsSnapshot? = nil
    ) -> LocalFarmAnswer {
        let normalized = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return LocalFarmAnswer(text: "请输入要查询的牧场问题。", sources: []) }

        if let analyticsSnapshot {
            if normalized.contains("全场") || normalized.contains("全群") || normalized.contains("群体统计") {
                return answer(from: SheepAnalyticsEngine.herdSummary(snapshot: analyticsSnapshot))
            }
            if let matchedSheep = analyticsSnapshot.sheep.first(where: { normalized.localizedCaseInsensitiveContains($0.earTag) }) {
                if normalized.contains("繁殖") || normalized.contains("产羔") || normalized.contains("胎间距") {
                    return answer(from: SheepAnalyticsEngine.reproduction(sheepID: matchedSheep.id, snapshot: analyticsSnapshot))
                }
                if normalized.contains("生命周期") || normalized.contains("体重") || normalized.contains("日龄") {
                    return answer(from: SheepAnalyticsEngine.lifecycle(sheepID: matchedSheep.id, snapshot: analyticsSnapshot))
                }
            }
            if normalized.contains("圈舍") || normalized.contains("圈") {
                if let pen = analyticsSnapshot.pens.first(where: { normalized.localizedCaseInsensitiveContains($0.name) }) {
                    return answer(from: SheepAnalyticsEngine.penHerd(penID: pen.id, snapshot: analyticsSnapshot))
                }
            }
        }

        if normalized.contains("羊") && (normalized.contains("多少") || normalized.contains("数量")) {
            return LocalFarmAnswer(text: "当前牧场共有 \(activeSheep.filter { $0.status == .active && $0.deletedAt == nil }.count) 只在场羊只。", sources: ["本地羊只档案"])
        }
        if normalized.contains("圈") {
            return LocalFarmAnswer(text: "当前共有 \(pens.filter { $0.isActive && $0.deletedAt == nil }.count) 个启用圈舍。", sources: ["本地圈舍档案"])
        }
        if normalized.contains("投喂") {
            let today = Calendar.current.startOfDay(for: .now)
            let count = feedRecords.filter { $0.deletedAt == nil && $0.occurredAt >= today }.count
            return LocalFarmAnswer(text: "今天已记录 \(count) 条投喂。", sources: ["本地投喂记录"])
        }
        if normalized.contains("治疗") || normalized.contains("疫苗") || normalized.contains("健康") {
            let count = healthRecords.filter { $0.deletedAt == nil }.count
            return LocalFarmAnswer(text: "当前牧场共有 \(count) 条健康记录。", sources: ["本地健康记录"])
        }
        return LocalFarmAnswer(text: "我只能基于当前牧场本地数据回答羊只数量、圈舍、投喂和健康记录。请换一种问法。", sources: [])
    }

    private static func answer(from insight: FarmInsight) -> LocalFarmAnswer {
        LocalFarmAnswer(text: ([insight.summary] + insight.details).joined(separator: "\n"), sources: ["Plus 同口径分析引擎"])
    }
}
