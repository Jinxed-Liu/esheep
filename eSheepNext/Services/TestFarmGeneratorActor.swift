import Foundation
import SwiftData
import UIKit

enum TestFarmGeneratorError: LocalizedError {
    case unavailableInRelease
    case notDevelopmentEnvironment
    case farmMissing
    case nonEmptyFarm
    case markerMismatch
    case localOnlyMigration
    case countMismatch(String)

    var errorDescription: String? {
        switch self {
        case .unavailableInRelease: "测试牧场生成器只存在于 Debug 构建。"
        case .notDevelopmentEnvironment: "测试牧场生成器只允许连接 Development CloudKit。"
        case .farmMissing: "找不到目标测试牧场。"
        case .nonEmptyFarm: "目标牧场不是空牧场，禁止写入生成数据。"
        case .markerMismatch: "牧场缺少完全匹配的 Development 测试标记，禁止清理。"
        case .localOnlyMigration: "迁移提交的牧场已永久锁定为仅本地，不能生成 Development 测试数据或启用云协作。"
        case .countMismatch(let detail): "测试数据数量校验失败：\(detail)"
        }
    }
}

struct TestFarmGenerationProgress: Sendable, Equatable {
    let completed: Int
    let total: Int
    let stage: String
}

struct TestFarmGenerationResult: Sendable, Equatable {
    let farmID: UUID
    let seed: String
    let penCount: Int
    let sheepCount: Int
    let productionEventCount: Int
    let photoCount: Int
}

actor TestFarmGeneratorActor {
    static let seed = "ESHEEP-DEVELOPMENT-7DAY-v1"

    private let modelContainer: ModelContainer
    private let photoTransfers: PhotoTransferActor

    init(modelContainer: ModelContainer, photoTransfers: PhotoTransferActor) {
        self.modelContainer = modelContainer
        self.photoTransfers = photoTransfers
    }

    func generate(
        farmID: UUID,
        accountID: UUID,
        progress: @escaping @Sendable (TestFarmGenerationProgress) async -> Void = { _ in }
    ) async throws -> TestFarmGenerationResult {
        #if !DEBUG
        throw TestFarmGeneratorError.unavailableInRelease
        #else
        guard Self.isDevelopmentEnvironment else { throw TestFarmGeneratorError.notDevelopmentEnvironment }
        let bridge = await TestFarmCommandBridge(container: modelContainer, farmID: farmID, accountID: accountID)
        try await bridge.prepareFarmMarker(seed: Self.seed)
        let base = Date(timeIntervalSince1970: 1_767_225_600)
        let totalWork = 10 + 100 + 500 + 50
        var completed = 0

        var penIDs: [UUID] = []
        for index in 0..<10 {
            penIDs.append(try await bridge.execute(.createPen(name: String(format: "测试圈舍-%02d", index + 1), note: "七日验收固定数据")))
            completed += 1
            await progress(.init(completed: completed, total: totalWork, stage: "圈舍"))
        }

        var sheepIDs: [UUID] = []
        for index in 0..<100 {
            let sex: SheepSex = index % 8 == 0 ? .ram : .ewe
            let enteredAt = base.addingTimeInterval(TimeInterval(index % 30) * 86_400)
            sheepIDs.append(try await bridge.execute(.addSheep(
                earTag: String(format: "DEV-%04d", index + 1),
                breed: index % 2 == 0 ? "湖羊" : "寒羊",
                sex: sex,
                penID: penIDs[index % penIDs.count],
                occurredAt: enteredAt,
                birthAt: enteredAt.addingTimeInterval(-TimeInterval(180 + index) * 86_400),
                note: "\(Self.seed)"
            )))
            completed += 1
            await progress(.init(completed: completed, total: totalWork, stage: "羊只"))
        }

        let ingredientID = try await bridge.execute(.addIngredient(name: "Development 测试日粮", unit: "千克", dryMatterText: "88"))
        for index in 0..<150 {
            _ = try await bridge.execute(.recordWeight(
                sheepID: sheepIDs[index % sheepIDs.count],
                kilogramsText: String(format: "%.1f", 35 + Double(index % 45) * 0.4),
                occurredAt: base.addingTimeInterval(TimeInterval(31 + index / 12) * 86_400),
                note: "固定种子称重"
            ))
            completed += 1
            await progress(.init(completed: completed, total: totalWork, stage: "称重"))
        }
        for index in 0..<80 {
            _ = try await bridge.execute(.transferSheep(
                sheepID: sheepIDs[index],
                toPenID: penIDs[(index + 3) % penIDs.count],
                occurredAt: base.addingTimeInterval(TimeInterval(45 + index / 10) * 86_400),
                note: "固定种子转群"
            ))
            completed += 1
            await progress(.init(completed: completed, total: totalWork, stage: "转群"))
        }
        for index in 0..<100 {
            _ = try await bridge.execute(.recordFeed(
                penID: penIDs[index % penIDs.count],
                recipeID: nil,
                mode: index % 3 == 0 ? .freeChoice : .limited,
                occurredAt: base.addingTimeInterval(TimeInterval(60 + index / 10) * 86_400 + TimeInterval(index % 10) * 300),
                lines: [FeedLineDraft(id: StableCloudUUID.derived(namespace: farmID, name: "test-feed-line-\(index)"), ingredientID: ingredientID, kilogramsText: String(20 + index % 8))],
                note: "固定种子投喂"
            ))
            completed += 1
            await progress(.init(completed: completed, total: totalWork, stage: "投喂"))
        }
        for index in 0..<60 {
            _ = try await bridge.execute(.recordHealth(
                sheepID: sheepIDs[index],
                penID: nil,
                kind: index % 4 == 0 ? .vaccination : .treatment,
                itemName: index % 4 == 0 ? "测试疫苗" : "测试治疗",
                occurredAt: base.addingTimeInterval(TimeInterval(75 + index / 10) * 86_400),
                note: "固定种子健康记录",
                inventoryLotID: nil,
                quantityText: nil
            ))
            completed += 1
            await progress(.init(completed: completed, total: totalWork, stage: "健康"))
        }
        let ramID = sheepIDs[0]
        let eweIDs = sheepIDs.enumerated().filter { $0.offset % 8 != 0 }.map(\.element)
        for index in 0..<40 {
            _ = try await bridge.execute(.recordReproduction(
                eweID: eweIDs[index],
                kind: .breeding,
                occurredAt: base.addingTimeInterval(TimeInterval(90 + index / 8) * 86_400),
                sireID: ramID,
                semenName: nil,
                result: "测试配种",
                lambCount: 0,
                parity: nil,
                birthDeadCount: nil,
                offspring: [],
                note: "固定种子繁殖记录"
            ))
            completed += 1
            await progress(.init(completed: completed, total: totalWork, stage: "繁殖"))
        }
        for index in 0..<50 {
            _ = try await bridge.execute(.addNote(
                sheepID: sheepIDs[index],
                penID: nil,
                text: "七日验收测试备注 \(index + 1)",
                occurredAt: base.addingTimeInterval(TimeInterval(105 + index / 10) * 86_400)
            ))
            completed += 1
            await progress(.init(completed: completed, total: totalWork, stage: "备注"))
        }
        for index in 0..<10 {
            let batchID = try await bridge.execute(.createBatch(
                name: String(format: "测试批次-%02d", index + 1),
                purpose: "七日验收",
                startedAt: base.addingTimeInterval(TimeInterval(115 + index) * 86_400),
                note: Self.seed
            ))
            _ = try await bridge.execute(.assignSheepToBatch(batchID: batchID, sheepID: sheepIDs[index], joinedAt: base.addingTimeInterval(TimeInterval(115 + index) * 86_400)))
            completed += 2
            await progress(.init(completed: completed, total: totalWork, stage: "生产批次"))
        }

        for index in 0..<50 {
            let data = await Self.testImageData(index: index + 1)
            _ = try await photoTransfers.enqueue(data: data, farmID: farmID, entityID: sheepIDs[index])
            completed += 1
            await progress(.init(completed: completed, total: totalWork, stage: "测试照片"))
        }
        let result = try await bridge.verifyCounts()
        return result
        #endif
    }

    func deleteMarkedTestFarm(farmID: UUID) async throws {
        #if !DEBUG
        throw TestFarmGeneratorError.unavailableInRelease
        #else
        let bridge = await TestFarmCommandBridge(container: modelContainer, farmID: farmID, accountID: UUID())
        try await bridge.deleteMarkedTestFarm(seed: Self.seed)
        #endif
    }

    private static var isDevelopmentEnvironment: Bool {
        let container = Bundle.main.object(forInfoDictionaryKey: "CLOUDKIT_CONTAINER_IDENTIFIER") as? String
        return CloudFeatureConfiguration.isEnabled && container == "iCloud.com.sheepfarm.next.dev"
    }

    @MainActor
    private static func testImageData(index: Int) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1600, height: 1200))
        let image = renderer.image { context in
            UIColor(red: 0.04, green: 0.34 + CGFloat(index % 5) * 0.03, blue: 0.78, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1600, height: 1200))
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 150, weight: .bold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph,
            ]
            NSString(string: String(format: "TEST-%03d", index)).draw(in: CGRect(x: 100, y: 480, width: 1400, height: 240), withAttributes: attributes)
        }
        return image.jpegData(compressionQuality: 0.94) ?? Data()
    }
}

@MainActor
private final class TestFarmCommandBridge {
    private let container: ModelContainer
    private let farmID: UUID
    private let accountID: UUID
    private let service = FarmCommandService()

    init(container: ModelContainer, farmID: UUID, accountID: UUID) {
        self.container = container
        self.farmID = farmID
        self.accountID = accountID
    }

    func prepareFarmMarker(seed: String) throws {
        let context = ModelContext(container)
        guard let farm = try context.fetch(FetchDescriptor<FarmRecord>()).first(where: { $0.id == farmID }) else { throw TestFarmGeneratorError.farmMissing }
        guard !farm.isLocalOnlyMigration else { throw TestFarmGeneratorError.localOnlyMigration }
        let existingOperations = try context.fetch(FetchDescriptor<DomainOperation>()).filter { $0.farmID == farmID && $0.kindRawValue != DomainOperationKind.createFarm.rawValue }
        guard existingOperations.isEmpty else { throw TestFarmGeneratorError.nonEmptyFarm }
        farm.isDevelopmentTestFarm = true
        farm.developmentSeed = seed
        farm.updatedAt = .now
        try context.save()
    }

    func execute(_ command: FarmCommand) throws -> UUID {
        let context = ModelContext(container)
        let before = Set(try context.fetch(FetchDescriptor<DomainOperation>()).map(\.id))
        try service.execute(command, in: FarmContext(accountID: accountID, farmID: farmID, role: .owner), context: context)
        guard let operation = try context.fetch(FetchDescriptor<DomainOperation>()).first(where: { $0.farmID == farmID && !before.contains($0.id) }), let entityID = operation.entityID else {
            throw TestFarmGeneratorError.countMismatch("命令没有生成稳定目标")
        }
        return entityID
    }

    func verifyCounts() throws -> TestFarmGenerationResult {
        let context = ModelContext(container)
        let pens = try context.fetch(FetchDescriptor<PenRecord>()).filter { $0.farmID == farmID }.count
        let sheep = try context.fetch(FetchDescriptor<SheepRecord>()).filter { $0.farmID == farmID }.count
        let weights = try context.fetch(FetchDescriptor<WeightRecord>()).filter { $0.farmID == farmID }.count
        let transfers = try context.fetch(FetchDescriptor<TransferRecord>()).filter { $0.farmID == farmID }.count
        let feeds = try context.fetch(FetchDescriptor<FeedRecord>()).filter { $0.farmID == farmID }.count
        let health = try context.fetch(FetchDescriptor<HealthRecord>()).filter { $0.farmID == farmID }.count
        let reproduction = try context.fetch(FetchDescriptor<ReproductionRecord>()).filter { $0.farmID == farmID }.count
        let notes = try context.fetch(FetchDescriptor<NoteRecord>()).filter { $0.farmID == farmID }.count
        let batches = try context.fetch(FetchDescriptor<ProductionBatchRecord>()).filter { $0.farmID == farmID }.count
        let memberships = try context.fetch(FetchDescriptor<BatchMembershipRecord>()).filter { $0.farmID == farmID }.count
        let photos = try context.fetch(FetchDescriptor<PhotoAssetRecord>()).filter { $0.farmID == farmID }.count
        guard pens == 10, sheep == 100 else { throw TestFarmGeneratorError.countMismatch("圈舍 \(pens)，羊只 \(sheep)") }
        let events = weights + transfers + feeds + health + reproduction + notes + batches + memberships
        guard events == 500 else { throw TestFarmGeneratorError.countMismatch("生产事件 \(events)") }
        guard photos == 50 else { throw TestFarmGeneratorError.countMismatch("照片 \(photos)") }
        return TestFarmGenerationResult(farmID: farmID, seed: TestFarmGeneratorActor.seed, penCount: pens, sheepCount: sheep, productionEventCount: events, photoCount: photos)
    }

    func deleteMarkedTestFarm(seed: String) throws {
        let context = ModelContext(container)
        guard let farm = try context.fetch(FetchDescriptor<FarmRecord>()).first(where: { $0.id == farmID }), farm.isDevelopmentTestFarm, farm.developmentSeed == seed else {
            throw TestFarmGeneratorError.markerMismatch
        }
        context.delete(farm)
        try context.save()
    }
}
