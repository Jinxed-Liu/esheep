import CoreGraphics
import Foundation
import ImageIO
import SwiftData
import UniformTypeIdentifiers
import XCTest
@testable import eSheepNext

final class WorkspacePerformanceTests: XCTestCase {
    func testEarTagSearchOnTenXFixture() {
        let candidates = (0..<20_000).map { index in
            SheepEarTagSearchCandidate(
                id: UUID(),
                earTag: String(format: "SH-%05d", index),
                detail: index.isMultiple(of: 2) ? "母羊 · 湖羊" : "公羊 · 杜泊"
            )
        }
        let expected = SheepEarTagSearchMatcher.search(
            query: "123",
            candidates: candidates,
            limit: 8
        )
        var measured = SheepEarTagSearchResultSet(matches: [], totalCount: 0)

        measure(
            metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()],
            options: measureOptions()
        ) {
            measured = SheepEarTagSearchMatcher.search(
                query: "123",
                candidates: candidates,
                limit: 8
            )
        }

        XCTAssertEqual(measured, expected)
    }

    func testHomeSnapshotOnTenXFixture() throws {
        let fixture = try PerformanceFixtureFactory.makeHomeFixture()
        let loader = FarmHomeSnapshotActor(container: fixture.container)
        let farmID = fixture.farmID
        let now = fixture.now
        let calendar = fixture.calendar
        let expected = try waitForAsync {
            try await loader.load(
                farmID: farmID,
                now: now,
                calendar: calendar
            )
        }
        var measured = FarmHomeSnapshot.empty
        var measuredError: (any Error)?

        measure(
            metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()],
            options: measureOptions()
        ) {
            do {
                measured = try waitForAsync {
                    try await loader.load(
                        farmID: farmID,
                        now: now,
                        calendar: calendar
                    )
                }
            } catch {
                measuredError = error
            }
        }

        if let measuredError { throw measuredError }
        XCTAssertEqual(measured, expected)
        XCTAssertEqual(measured.activeSheepCount, 2_000)
        XCTAssertEqual(measured.occupiedPenCount, 24)
    }

    func testCareSummaryOnTenXFixture() throws {
        let fixture = try PerformanceFixtureFactory.makeCareFixture()
        let loader = CareManagementSummarySnapshotActor(container: fixture.container)
        let farmID = fixture.farmID
        let expected = try waitForAsync {
            try await loader.load(farmID: farmID)
        }
        var measured = CareManagementSummarySnapshot.empty
        var measuredError: (any Error)?

        measure(
            metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()],
            options: measureOptions()
        ) {
            do {
                measured = try waitForAsync {
                    try await loader.load(farmID: farmID)
                }
            } catch {
                measuredError = error
            }
        }

        if let measuredError { throw measuredError }
        XCTAssertEqual(measured, expected)
        XCTAssertEqual(measured.healthRecordCount, 1_000)
        XCTAssertEqual(measured.reproductionRecordCount, 800)
    }

    func testFeedingSummaryOnTenXFixture() throws {
        let fixture = try PerformanceFixtureFactory.makeFeedingFixture()
        let loader = FeedingOverviewSnapshotActor(container: fixture.container)
        let farmID = fixture.farmID
        let now = fixture.now
        let calendar = fixture.calendar
        let expected = try waitForAsync {
            try await loader.load(
                farmID: farmID,
                now: now,
                calendar: calendar
            )
        }
        var measured = FeedingOverviewSnapshot.empty
        var measuredError: (any Error)?

        measure(
            metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()],
            options: measureOptions()
        ) {
            do {
                measured = try waitForAsync {
                    try await loader.load(
                        farmID: farmID,
                        now: now,
                        calendar: calendar
                    )
                }
            } catch {
                measuredError = error
            }
        }

        if let measuredError { throw measuredError }
        XCTAssertEqual(measured, expected)
        XCTAssertEqual(measured.todayFeedCount, 800)
    }

    func testSheepHistoryProjectionOnTenXFixture() throws {
        let fixture = try PerformanceFixtureFactory.makeHistoryFixture()
        let loader = SheepRecordHistoryActor(container: fixture.container)
        let farmID = fixture.farmID
        let sheepID = fixture.sheepID
        let expected = try waitForAsync {
            let snapshot = try await loader.load(
                farmID: farmID,
                sheepID: sheepID
            )
            return HistoryMeasurement(snapshot)
        }
        var measured = HistoryMeasurement.empty
        var measuredError: (any Error)?

        measure(
            metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()],
            options: measureOptions()
        ) {
            do {
                measured = try waitForAsync {
                    let snapshot = try await loader.load(
                        farmID: farmID,
                        sheepID: sheepID
                    )
                    return HistoryMeasurement(snapshot)
                }
            } catch {
                measuredError = error
            }
        }

        if let measuredError { throw measuredError }
        XCTAssertEqual(measured, expected)
        XCTAssertEqual(measured.weightCount, 1_500)
        XCTAssertEqual(measured.transferCount, 1_000)
    }

    func testThumbnailDecodeOnLargeOfflineImage() throws {
        let data = try PerformanceFixtureFactory.makeJPEGData()
        let pipeline = ImageThumbnailPipeline(countLimit: 2, totalCostLimit: 2 * 1_024 * 1_024)
        var iteration = 0
        var measuredSize = CGSize.zero
        var measuredError: (any Error)?

        measure(
            metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()],
            options: measureOptions()
        ) {
            iteration += 1
            let digest = "offline-fixture-\(iteration)"
            do {
                let thumbnail = try waitForAsync {
                    await pipeline.thumbnail(
                        data: data,
                        digest: digest,
                        targetSize: CGSize(width: 160, height: 160),
                        scale: 2
                    )
                }
                measuredSize = thumbnail.map {
                    CGSize(width: $0.cgImage.width, height: $0.cgImage.height)
                } ?? .zero
            } catch {
                measuredError = error
            }
        }

        if let measuredError { throw measuredError }
        XCTAssertGreaterThan(measuredSize.width, 0)
        XCTAssertLessThanOrEqual(measuredSize.width, 320)
        XCTAssertLessThanOrEqual(measuredSize.height, 320)
    }

    private func measureOptions() -> XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        return options
    }
}

private struct PerformanceFixture {
    let container: ModelContainer
    let farmID: UUID
    let sheepID: UUID
    let now: Date
    let calendar: Calendar
}

private enum PerformanceFixtureFactory {
    private static let now = Date(timeIntervalSince1970: 1_800_014_400)

    static func makeHomeFixture() throws -> PerformanceFixture {
        let base = try makeBaseFixture(penCount: 24)
        let context = base.context

        for index in 0..<2_000 {
            context.insert(SheepRecord(
                farmID: base.farmID,
                earTag: String(format: "H-%05d", index),
                breed: index.isMultiple(of: 2) ? "湖羊" : "杜泊",
                sex: index.isMultiple(of: 2) ? .ewe : .ram,
                penID: base.penIDs[index % base.penIDs.count],
                enteredAt: now.addingTimeInterval(-86_400)
            ))
        }
        for index in 0..<600 {
            context.insert(FeedRecord(
                farmID: base.farmID,
                penID: base.penIDs[index % base.penIDs.count],
                mode: .limited,
                occurredAt: now.addingTimeInterval(-Double(index % 360) * 60),
                mealName: "早",
                feederName: "槽\(index % 48)"
            ))
        }
        for index in 0..<400 {
            context.insert(HealthRecord(
                farmID: base.farmID,
                sheepID: nil,
                penID: base.penIDs[index % base.penIDs.count],
                kind: .treatment,
                itemNameSnapshot: "离线健康样本",
                occurredAt: now.addingTimeInterval(-Double(index) * 60)
            ))
        }
        for _ in 0..<120 {
            context.insert(OutboxItem(
                farmID: base.farmID,
                accountID: base.accountID,
                operationID: UUID(),
                deliveryProvider: .supabase,
                authorityGeneration: 3
            ))
        }
        try context.save()
        return base.fixture
    }

    static func makeCareFixture() throws -> PerformanceFixture {
        let base = try makeBaseFixture(penCount: 12)
        let context = base.context
        var eweIDs: [UUID] = []
        eweIDs.reserveCapacity(200)
        for index in 0..<200 {
            let ewe = SheepRecord(
                farmID: base.farmID,
                earTag: String(format: "C-%04d", index),
                breed: "湖羊",
                sex: .ewe,
                penID: base.penIDs[index % base.penIDs.count],
                enteredAt: now.addingTimeInterval(-86_400)
            )
            context.insert(ewe)
            eweIDs.append(ewe.id)
        }
        for index in 0..<1_000 {
            context.insert(HealthRecord(
                farmID: base.farmID,
                sheepID: eweIDs[index % eweIDs.count],
                penID: nil,
                kind: index.isMultiple(of: 2) ? .treatment : .vaccination,
                itemNameSnapshot: "离线健康样本",
                occurredAt: now.addingTimeInterval(-Double(index) * 60)
            ))
            context.insert(ReproductionRecord(
                farmID: base.farmID,
                eweID: eweIDs[index % eweIDs.count],
                kind: index.isMultiple(of: 5) ? .parityBaseline : .breeding,
                occurredAt: now.addingTimeInterval(-Double(index) * 120),
                parity: index.isMultiple(of: 5) ? index % 4 : nil
            ))
        }
        try context.save()
        return base.fixture
    }

    static func makeFeedingFixture() throws -> PerformanceFixture {
        let base = try makeBaseFixture(penCount: 24)
        let context = base.context
        let ingredientIDs = (0..<6).map { _ in UUID() }

        for index in 0..<800 {
            let feed = FeedRecord(
                farmID: base.farmID,
                penID: base.penIDs[index % base.penIDs.count],
                mode: index.isMultiple(of: 2) ? .freeChoice : .limited,
                occurredAt: now.addingTimeInterval(-Double(index % 360) * 60),
                mealName: ["早", "中", "晚"][index % 3],
                feederName: "槽\(index % 48)"
            )
            context.insert(feed)
            for lineIndex in 0..<3 {
                context.insert(FeedRecordLine(
                    farmID: base.farmID,
                    feedRecordID: feed.id,
                    ingredientID: ingredientIDs[(index + lineIndex) % ingredientIDs.count],
                    kilogramsText: String(20 + lineIndex),
                    ingredientNameSnapshot: "离线原料\(lineIndex)"
                ))
            }
        }
        for index in 0..<400 {
            context.insert(FeedTroughObservationRecord(
                farmID: base.farmID,
                penID: base.penIDs[index % base.penIDs.count],
                feederName: "槽\(index % 48)",
                observedAt: now.addingTimeInterval(-Double(index % 240) * 60),
                actualRemainingKilogramsText: "4.5",
                measurementMethod: .weighed
            ))
        }
        try context.save()
        return base.fixture
    }

    static func makeHistoryFixture() throws -> PerformanceFixture {
        let base = try makeBaseFixture(penCount: 20)
        let context = base.context
        let sheep = SheepRecord(
            farmID: base.farmID,
            earTag: "HISTORY-001",
            breed: "湖羊",
            sex: .ewe,
            penID: base.penIDs[0],
            enteredAt: now.addingTimeInterval(-365 * 86_400)
        )
        context.insert(sheep)
        var relatedWeightIDs: [UUID] = []
        relatedWeightIDs.reserveCapacity(500)
        for index in 0..<1_500 {
            let weight = WeightRecord(
                farmID: base.farmID,
                sheepID: sheep.id,
                kilogramsText: String(35 + index % 40),
                occurredAt: now.addingTimeInterval(-Double(index) * 3_600)
            )
            context.insert(weight)
            if index < 500 { relatedWeightIDs.append(weight.id) }
        }
        for index in 0..<1_000 {
            context.insert(TransferRecord(
                farmID: base.farmID,
                sheepID: sheep.id,
                fromPenID: base.penIDs[index % base.penIDs.count],
                toPenID: base.penIDs[(index + 1) % base.penIDs.count],
                occurredAt: now.addingTimeInterval(-Double(index) * 7_200)
            ))
        }
        for index in 0..<500 {
            context.insert(TombstoneRecord(
                farmID: base.farmID,
                entityType: "WeightRecord",
                entityID: relatedWeightIDs[index],
                deletedByAccountID: base.accountID,
                reason: "离线历史样本"
            ))
            context.insert(TombstoneRecord(
                farmID: base.farmID,
                entityType: "WeightRecord",
                entityID: UUID(),
                deletedByAccountID: base.accountID,
                reason: "无关离线历史样本"
            ))
        }
        try context.save()
        return PerformanceFixture(
            container: base.container,
            farmID: base.farmID,
            sheepID: sheep.id,
            now: now,
            calendar: calendar
        )
    }

    static func makeJPEGData() throws -> Data {
        let width = 2_048
        let height = 2_048
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw PerformanceFixtureError.imageCreationFailed
        }
        for band in 0..<64 {
            let hue = CGFloat(band) / 64
            context.setFillColor(red: hue, green: 1 - hue, blue: 0.45, alpha: 1)
            context.fill(CGRect(x: 0, y: band * 32, width: width, height: 32))
        }
        guard let image = context.makeImage() else {
            throw PerformanceFixtureError.imageCreationFailed
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw PerformanceFixtureError.imageCreationFailed
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.9,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw PerformanceFixtureError.imageCreationFailed
        }
        return data as Data
    }

    private static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private static func makeBaseFixture(penCount: Int) throws -> BaseFixture {
        let container = try AppSchema.makeContainer(
            name: "Performance-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let accountID = UUID()
        let farm = FarmRecord(ownerAccountID: accountID, name: "匿名性能牧场")
        context.insert(farm)
        var penIDs: [UUID] = []
        penIDs.reserveCapacity(penCount)
        for index in 0..<penCount {
            let pen = PenRecord(farmID: farm.id, name: "性能圈舍 \(index + 1)")
            context.insert(pen)
            penIDs.append(pen.id)
        }
        try context.save()
        return BaseFixture(
            container: container,
            context: context,
            farmID: farm.id,
            accountID: accountID,
            penIDs: penIDs,
            fixture: PerformanceFixture(
                container: container,
                farmID: farm.id,
                sheepID: UUID(),
                now: now,
                calendar: calendar
            )
        )
    }

    private struct BaseFixture {
        let container: ModelContainer
        let context: ModelContext
        let farmID: UUID
        let accountID: UUID
        let penIDs: [UUID]
        let fixture: PerformanceFixture
    }
}

private struct HistoryMeasurement: Sendable, Equatable {
    let weightCount: Int
    let transferCount: Int
    let removalCount: Int
    let tombstoneCount: Int
    let penCount: Int

    init(_ snapshot: SheepRecordHistorySnapshot) {
        weightCount = snapshot.weights.count
        transferCount = snapshot.transfers.count
        removalCount = snapshot.removals.count
        tombstoneCount = snapshot.tombstones.count
        penCount = snapshot.pens.count
    }

    static let empty = HistoryMeasurement(
        weightCount: 0,
        transferCount: 0,
        removalCount: 0,
        tombstoneCount: 0,
        penCount: 0
    )

    private init(
        weightCount: Int,
        transferCount: Int,
        removalCount: Int,
        tombstoneCount: Int,
        penCount: Int
    ) {
        self.weightCount = weightCount
        self.transferCount = transferCount
        self.removalCount = removalCount
        self.tombstoneCount = tombstoneCount
        self.penCount = penCount
    }
}

private final class AsyncMeasurementBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, any Error>?

    func store(_ result: Result<Value, any Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func load() -> Result<Value, any Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

private func waitForAsync<Value: Sendable>(
    timeout: TimeInterval = 20,
    operation: @escaping @Sendable () async throws -> Value
) throws -> Value {
    let resultBox = AsyncMeasurementBox<Value>()
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached(priority: .userInitiated) {
        do {
            resultBox.store(.success(try await operation()))
        } catch {
            resultBox.store(.failure(error))
        }
        semaphore.signal()
    }
    guard semaphore.wait(timeout: .now() + timeout) == .success else {
        throw AsyncMeasurementError.timedOut
    }
    guard let result = resultBox.load() else {
        throw AsyncMeasurementError.missingResult
    }
    return try result.get()
}

private enum AsyncMeasurementError: Error {
    case timedOut
    case missingResult
}

private enum PerformanceFixtureError: Error {
    case imageCreationFailed
}
