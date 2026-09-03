import CryptoKit
import Foundation

enum ESheepCloudProtocolV2 {
    static let protocolVersion = 2
    static let schemaVersion = 1
}

enum ESheepCloudValueV2: Codable, Sendable, Equatable {
    case null
    case string(String)
    case integer(Int)
    case decimal(String)
    case boolean(Bool)
    case date(Date)
    case identifier(UUID)
    case strings([String])
    case identifiers([UUID])

    var digest: String {
        ESheepCloudValueDigestV2.hex(self)
    }

    private enum CodingKeys: String, CodingKey { case type, value }
    private enum Kind: String, Codable {
        case null, string, integer, decimal, boolean, date, identifier, strings, identifiers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .null: self = .null
        case .string: self = .string(try container.decode(String.self, forKey: .value))
        case .integer: self = .integer(try container.decode(Int.self, forKey: .value))
        case .decimal: self = .decimal(try container.decode(String.self, forKey: .value))
        case .boolean: self = .boolean(try container.decode(Bool.self, forKey: .value))
        case .date: self = .date(try container.decode(Date.self, forKey: .value))
        case .identifier: self = .identifier(try container.decode(UUID.self, forKey: .value))
        case .strings: self = .strings(try container.decode([String].self, forKey: .value))
        case .identifiers: self = .identifiers(try container.decode([UUID].self, forKey: .value))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .null:
            try container.encode(Kind.null, forKey: .type)
        case .string(let value):
            try container.encode(Kind.string, forKey: .type)
            try container.encode(value, forKey: .value)
        case .integer(let value):
            try container.encode(Kind.integer, forKey: .type)
            try container.encode(value, forKey: .value)
        case .decimal(let value):
            try container.encode(Kind.decimal, forKey: .type)
            try container.encode(value, forKey: .value)
        case .boolean(let value):
            try container.encode(Kind.boolean, forKey: .type)
            try container.encode(value, forKey: .value)
        case .date(let value):
            try container.encode(Kind.date, forKey: .type)
            try container.encode(value, forKey: .value)
        case .identifier(let value):
            try container.encode(Kind.identifier, forKey: .type)
            try container.encode(value, forKey: .value)
        case .strings(let value):
            try container.encode(Kind.strings, forKey: .type)
            try container.encode(value, forKey: .value)
        case .identifiers(let value):
            try container.encode(Kind.identifiers, forKey: .type)
            try container.encode(value, forKey: .value)
        }
    }
}

enum ESheepCloudValueDigestV2 {
    static func hex(_ value: ESheepCloudValueV2) -> String {
        let canonical: String
        switch value {
        case .null:
            canonical = "null"
        case .string(let value):
            canonical = "string:\(value.utf8.count):\(value)"
        case .integer(let value):
            canonical = "integer:\(value)"
        case .decimal(let value):
            canonical = "decimal:\(value)"
        case .boolean(let value):
            canonical = "boolean:\(value ? "true" : "false")"
        case .date(let value):
            canonical = "date:\(Int64((value.timeIntervalSince1970 * 1_000).rounded()))"
        case .identifier(let value):
            canonical = "identifier:\(value.uuidString.lowercased())"
        case .strings(let values):
            canonical = "strings:" + values.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        case .identifiers(let values):
            canonical = "identifiers:" + values.map { $0.uuidString.lowercased() }.joined(separator: "|")
        }
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

enum ESheepCloudFieldMutationV2: Codable, Sendable, Equatable {
    case set(ESheepCloudValueV2)
    case clear

    var value: ESheepCloudValueV2 {
        switch self {
        case .set(let value): value
        case .clear: .null
        }
    }

    private enum CodingKeys: String, CodingKey { case action, value }
    private enum Action: String, Codable { case set, clear }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Action.self, forKey: .action) {
        case .set:
            self = .set(try container.decode(ESheepCloudValueV2.self, forKey: .value))
        case .clear:
            self = .clear
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .set(let value):
            try container.encode(Action.set, forKey: .action)
            try container.encode(value, forKey: .value)
        case .clear:
            try container.encode(Action.clear, forKey: .action)
        }
    }
}

struct ESheepCloudFieldPatchV2: Codable, Sendable, Equatable {
    let field: String
    let mutation: ESheepCloudFieldMutationV2
}

struct ESheepCloudStreamReferenceV2: Codable, Sendable, Hashable {
    let type: String
    let id: UUID
}

struct ESheepCloudFieldObservationV2: Codable, Sendable, Equatable {
    let stream: ESheepCloudStreamReferenceV2
    let field: String
    let observedVersion: Int64
    let baseValueDigest: String
}

struct ESheepCloudFieldVersionEntryV2: Codable, Sendable, Equatable {
    let field: String
    let version: Int64
    let valueDigest: String
    let value: ESheepCloudValueV2?
    let accountID: UUID?
    let deviceID: UUID?
    let deviceSequence: Int64?
    let occurredAt: Date?
    let receivedAt: Date?

    init(
        field: String,
        version: Int64,
        valueDigest: String,
        value: ESheepCloudValueV2? = nil,
        accountID: UUID? = nil,
        deviceID: UUID? = nil,
        deviceSequence: Int64? = nil,
        occurredAt: Date? = nil,
        receivedAt: Date? = nil
    ) {
        self.field = field
        self.version = version
        self.valueDigest = valueDigest
        self.value = value
        self.accountID = accountID
        self.deviceID = deviceID
        self.deviceSequence = deviceSequence
        self.occurredAt = occurredAt
        self.receivedAt = receivedAt
    }
}

struct ESheepCloudFarmMutationV2: Codable, Sendable, Equatable {
    enum Action: Codable, Sendable, Equatable {
        case updateLocation(
            displayName: String,
            latitude: Double,
            longitude: Double,
            addressSnapshot: String?,
            timeZoneIdentifier: String,
            source: FarmLocationSource,
            horizontalAccuracyMeters: Double?
        )
    }

    let action: Action
}

enum ESheepCloudPenCommandV2: Codable, Sendable, Equatable {
    case create(name: String, note: String)
    case update(penID: UUID, name: String, note: String)
    case setActive(penID: UUID, isActive: Bool)
}

enum ESheepCloudSheepCommandV2: Codable, Sendable, Equatable {
    case add(
        earTag: String,
        breed: String,
        sex: SheepSex,
        penID: UUID?,
        occurredAt: Date,
        birthAt: Date?,
        currentParity: Int?,
        note: String
    )
    case patchProfile(sheepID: UUID, fields: [ESheepCloudFieldPatchV2])
    case setAvatar(sheepID: UUID, photoAssetID: UUID)
    case clearAvatar(sheepID: UUID)
}

enum ESheepCloudFactCommandV2: Codable, Sendable, Equatable {
    case recordWeight(sheepID: UUID, kilogramsText: String, occurredAt: Date, note: String)
    case correctWeight(originalID: UUID, kilogramsText: String, occurredAt: Date, note: String, reason: String)
    case recordWeaning(
        sheepID: UUID,
        weanWeightText: String,
        occurredAt: Date,
        birthAt: Date?,
        birthWeightText: String?,
        averageDailyGainText: String?,
        damID: UUID?,
        litterSize: Int?,
        note: String
    )
    case transferSheep(sheepID: UUID, toPenID: UUID?, occurredAt: Date, note: String)
    case correctTransfer(originalID: UUID, toPenID: UUID?, occurredAt: Date, note: String, reason: String)
    case removeSheep(
        sheepID: UUID,
        kind: RemovalKind,
        reason: String,
        amountText: String?,
        occurredAt: Date,
        note: String,
        recordID: UUID?,
        removalBatchID: UUID?,
        batchTotalAmountText: String?
    )
    case correctRemoval(
        originalID: UUID,
        kind: RemovalKind,
        reason: String,
        amountText: String?,
        occurredAt: Date,
        note: String,
        correctionReason: String
    )
    case restoreSheep(removalID: UUID)
    case recordHealth(
        sheepID: UUID?,
        penID: UUID?,
        kind: HealthRecordKind,
        itemName: String,
        occurredAt: Date,
        note: String,
        inventoryLotID: UUID?,
        quantityText: String?
    )
    case receiveInventory(
        catalogName: String,
        kind: HealthRecordKind,
        expiresAt: Date?,
        quantityText: String,
        occurredAt: Date,
        note: String
    )
    case addSemen(code: String, breed: String, source: String, batchNumber: String, quantityText: String)
    case recordReproduction(
        eweID: UUID,
        kind: ReproductionRecordKind,
        occurredAt: Date,
        sireID: UUID?,
        semenName: String?,
        result: String,
        lambCount: Int,
        parity: Int?,
        birthDeadCount: Int?,
        offspring: [LambingOffspringDraft],
        note: String
    )
    case addNote(sheepID: UUID?, penID: UUID?, text: String, occurredAt: Date)
}

enum ESheepCloudCollectionCommandV2: Codable, Sendable, Equatable {
    case createBreedingProgram(name: String, createdAt: Date, steps: [BreedingProgramStepDraft])
    case createBatch(name: String, purpose: String, startedAt: Date, sheepIDs: [UUID], note: String)
    case assignSheepToBatch(batchID: UUID, sheepID: UUID, joinedAt: Date)
    case leaveBatch(batchID: UUID, sheepID: UUID, leftAt: Date, reason: String)
    case restoreBatchMembership(membershipID: UUID, restoredAt: Date, reason: String)
    case addIngredient(name: String, unit: String, dryMatterText: String?)
    case createRecipe(name: String, note: String)
    case addRecipeComponent(recipeID: UUID, ingredientID: UUID, kilogramsText: String)
}

enum ESheepCloudFeedCommandV2: Codable, Sendable, Equatable {
    case recordLegacy(
        penID: UUID,
        recipeID: UUID?,
        mode: FeedMode,
        occurredAt: Date,
        lines: [FeedLineDraft],
        note: String
    )
    case saveIngredient(FeedIngredientDraft)
    case saveBatch(FeedBatchDraft)
    case adjustStock(
        batchID: UUID,
        kind: FeedStockTransactionKind,
        quantityText: String,
        occurredAt: Date,
        note: String
    )
    case countStock(
        countID: UUID,
        batchID: UUID,
        actualKilogramsText: String?,
        method: FeedStockCountMethod,
        occurredAt: Date,
        note: String
    )
    case saveRecipe(FeedRecipeDraft)
    case record(FeedEntryDraft)
    case recordTroughObservation(FeedTroughObservationDraft)
    case importHistorical(HistoricalFeedEntryDraft)
}

enum ESheepCloudDeletionCommandV2: Codable, Sendable, Equatable {
    case tombstone(entityType: CloudEntityType, entityID: UUID, reason: String)
    case restore(tombstoneID: UUID)
}

enum ESheepCloudPhotoCommandV2: Codable, Sendable, Equatable {
    case register(
        assetID: UUID,
        sheepID: UUID?,
        capturedAt: Date?,
        mimeType: String,
        contentSHA256: String,
        metadata: [String: String],
        metadataDigest: String,
        thumbnailSHA256: String,
        avatarSHA256: String,
        originalSHA256: String,
        thumbnailByteCount: Int64,
        avatarByteCount: Int64,
        originalByteCount: Int64
    )
    case moveToRecycleBin(assetID: UUID, reason: String)
    case restore(assetID: UUID)
}

/// Exhaustive, versioned business payload. Unknown enum cases or schemas fail
/// decoding, so no command can silently fall back to an untyped key/value bag.
enum ESheepCloudCommandPayloadV2: Codable, Sendable, Equatable {
    case farm(ESheepCloudFarmMutationV2)
    case pen(ESheepCloudPenCommandV2)
    case sheep(ESheepCloudSheepCommandV2)
    case fact(ESheepCloudFactCommandV2)
    case collection(ESheepCloudCollectionCommandV2)
    case feed(ESheepCloudFeedCommandV2)
    case care(CareCommand)
    case tmr(TMRCommand)
    case deletion(ESheepCloudDeletionCommandV2)
    case photo(ESheepCloudPhotoCommandV2)

    var kind: String {
        switch self {
        case .farm: "farm.updateLocation"
        case .pen(let command):
            switch command {
            case .create: "pen.create"
            case .update: "pen.update"
            case .setActive: "pen.setActive"
            }
        case .sheep(let command):
            switch command {
            case .add: "sheep.add"
            case .patchProfile: "sheep.patchProfile"
            case .setAvatar: "sheepAvatar.set"
            case .clearAvatar: "sheepAvatar.clear"
            }
        case .fact(let command):
            switch command {
            case .recordWeight: "weight.record"
            case .correctWeight: "weight.correct"
            case .recordWeaning: "weaning.record"
            case .transferSheep: "transfer.record"
            case .correctTransfer: "transfer.correct"
            case .removeSheep: "removal.record"
            case .correctRemoval: "removal.correct"
            case .restoreSheep: "removal.restore"
            case .recordHealth: "health.record"
            case .receiveInventory: "inventory.receive"
            case .addSemen: "semen.add"
            case .recordReproduction: "reproduction.record"
            case .addNote: "note.add"
            }
        case .collection(let command):
            switch command {
            case .createBreedingProgram: "breedingProgram.create"
            case .createBatch: "productionBatch.create"
            case .assignSheepToBatch: "batchMembership.assign"
            case .leaveBatch: "batchMembership.leave"
            case .restoreBatchMembership: "batchMembership.restore"
            case .addIngredient: "feedIngredient.add"
            case .createRecipe: "feedRecipe.create"
            case .addRecipeComponent: "feedRecipe.member.add"
            }
        case .feed(let command):
            switch command {
            case .recordLegacy: "feed.recordLegacy"
            case .saveIngredient: "feedIngredient.save"
            case .saveBatch: "feedBatch.save"
            case .adjustStock: "feedStock.adjust"
            case .countStock: "feedStock.count"
            case .saveRecipe: "feedRecipe.save"
            case .record: "feed.record"
            case .recordTroughObservation: "feedTrough.record"
            case .importHistorical: "feed.importHistorical"
            }
        case .care(let command): "care.\(command.cloudKindV2)"
        case .tmr(let command): "tmr.\(command.operationKind.rawValue)"
        case .deletion(let command):
            switch command {
            case .tombstone: "record.revoke"
            case .restore: "record.restore"
            }
        case .photo(let command):
            switch command {
            case .register: "photoAsset.register"
            case .moveToRecycleBin: "photoAsset.recycle"
            case .restore: "photoAsset.restore"
            }
        }
    }

    /// V2 uses an explicit discriminator instead of Swift's synthesized enum
    /// wire shape. The server can therefore prove that `commandKind` and the
    /// strongly typed payload describe the same business operation before it
    /// enters the durable command ledger.
    private enum CodingKeys: String, CodingKey {
        case kind
        case body
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let declaredKind = try container.decode(String.self, forKey: .kind)
        let decoded: Self

        switch declaredKind {
        case "farm.updateLocation":
            decoded = .farm(try container.decode(ESheepCloudFarmMutationV2.self, forKey: .body))
        case "pen.create", "pen.update", "pen.setActive":
            decoded = .pen(try container.decode(ESheepCloudPenCommandV2.self, forKey: .body))
        case "sheep.add", "sheep.patchProfile", "sheepAvatar.set", "sheepAvatar.clear":
            decoded = .sheep(try container.decode(ESheepCloudSheepCommandV2.self, forKey: .body))
        case "weight.record", "weight.correct", "weaning.record",
             "transfer.record", "transfer.correct", "removal.record",
             "removal.correct", "removal.restore", "health.record",
             "inventory.receive", "semen.add", "reproduction.record", "note.add":
            decoded = .fact(try container.decode(ESheepCloudFactCommandV2.self, forKey: .body))
        case "breedingProgram.create", "productionBatch.create",
             "batchMembership.assign", "batchMembership.leave",
             "batchMembership.restore", "feedIngredient.add",
             "feedRecipe.create", "feedRecipe.member.add":
            decoded = .collection(try container.decode(ESheepCloudCollectionCommandV2.self, forKey: .body))
        case "feed.recordLegacy", "feedIngredient.save", "feedBatch.save",
             "feedStock.adjust", "feedStock.count", "feedRecipe.save",
             "feed.record", "feedTrough.record", "feed.importHistorical":
            decoded = .feed(try container.decode(ESheepCloudFeedCommandV2.self, forKey: .body))
        case let kind where kind.hasPrefix("care."):
            decoded = .care(try container.decode(CareCommand.self, forKey: .body))
        case let kind where kind.hasPrefix("tmr."):
            decoded = .tmr(try container.decode(TMRCommand.self, forKey: .body))
        case "record.revoke", "record.restore":
            decoded = .deletion(try container.decode(ESheepCloudDeletionCommandV2.self, forKey: .body))
        case "photoAsset.register", "photoAsset.recycle", "photoAsset.restore":
            decoded = .photo(try container.decode(ESheepCloudPhotoCommandV2.self, forKey: .body))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown eSheep+ Cloud V2 command kind: \(declaredKind)"
            )
        }

        guard decoded.kind == declaredKind else {
            throw DecodingError.dataCorruptedError(
                forKey: .body,
                in: container,
                debugDescription: "The eSheep+ Cloud V2 command discriminator does not match its typed body."
            )
        }
        self = decoded
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .farm(let value): try container.encode(value, forKey: .body)
        case .pen(let value): try container.encode(value, forKey: .body)
        case .sheep(let value): try container.encode(value, forKey: .body)
        case .fact(let value): try container.encode(value, forKey: .body)
        case .collection(let value): try container.encode(value, forKey: .body)
        case .feed(let value): try container.encode(value, forKey: .body)
        case .care(let value): try container.encode(value, forKey: .body)
        case .tmr(let value): try container.encode(value, forKey: .body)
        case .deletion(let value): try container.encode(value, forKey: .body)
        case .photo(let value): try container.encode(value, forKey: .body)
        }
    }
}

private extension CareCommand {
    var cloudKindV2: String {
        switch self {
        case .upsertHealthCatalog: "healthCatalog.upsert"
        case .recordHealth: "health.recordBatch"
        case .correctHealth: "health.correct"
        case .receiveInventory: "inventory.receive"
        case .adjustInventory: "inventory.adjust"
        case .setInventoryLotActive: "inventoryLot.setActive"
        case .adjustSemen: "semen.adjust"
        case .upsertSemenDonor: "semenDonor.upsert"
        case .setSemenDonor: "semen.setDonor"
        case .updateSheepPedigree: "sheepPedigree.update"
        case .setBreedingRam: "sheep.setBreedingRam"
        case .setSheepPurpose: "sheep.setPurpose"
        case .restorePedigreeAudit: "sheepPedigree.restoreAudit"
        case .recordReproductionBatch: "reproduction.recordBatch"
        case .recordLambing: "lambing.record"
        case .correctReproduction: "reproduction.correct"
        case .correctLambing: "lambing.correct"
        case .revokeLambing: "lambing.revoke"
        case .restoreLambing: "lambing.restore"
        case .updateRules: "careRules.update"
        case .updateOperationalAlertRules: "operationalAlertRules.update"
        case .deferOperationalAlert: "operationalAlert.defer"
        case .setReminderStatus: "careReminder.setStatus"
        }
    }
}

struct ESheepCloudCommandEnvelopeV2: Codable, Sendable, Equatable {
    let protocolVersion: Int
    let schemaVersion: Int
    let commandID: UUID
    let sourceRequestID: UUID
    let bundleID: UUID?
    let farmID: UUID
    let farmGeneration: Int
    let accountID: UUID
    let deviceID: UUID
    let deviceSequence: Int64
    let createdAt: Date
    let occurredAt: Date
    let commandKind: String
    let payload: ESheepCloudCommandPayloadV2
    let affectedStreams: [ESheepCloudStreamReferenceV2]
    let affectedFields: [ESheepCloudFieldObservationV2]
    let fieldChanges: [ESheepCloudFieldPatchV2]
    let prerequisiteCommandIDs: [UUID]
    let requiredAssetIDs: [UUID]
    let contentDigest: String

    init(
        commandID: UUID,
        sourceRequestID: UUID,
        bundleID: UUID? = nil,
        farmID: UUID,
        farmGeneration: Int,
        accountID: UUID,
        deviceID: UUID,
        deviceSequence: Int64,
        createdAt: Date,
        occurredAt: Date,
        payload: ESheepCloudCommandPayloadV2,
        affectedStreams: [ESheepCloudStreamReferenceV2],
        affectedFields: [ESheepCloudFieldObservationV2],
        fieldChanges: [ESheepCloudFieldPatchV2] = [],
        prerequisiteCommandIDs: [UUID] = [],
        requiredAssetIDs: [UUID] = []
    ) throws {
        try Self.validateStructure(
            commandKind: payload.kind,
            farmGeneration: farmGeneration,
            deviceSequence: deviceSequence,
            commandID: commandID,
            affectedStreams: affectedStreams,
            affectedFields: affectedFields,
            fieldChanges: fieldChanges,
            prerequisiteCommandIDs: prerequisiteCommandIDs,
            requiredAssetIDs: requiredAssetIDs
        )
        let unsigned = ESheepCloudUnsignedCommandV2(
            protocolVersion: ESheepCloudProtocolV2.protocolVersion,
            schemaVersion: ESheepCloudProtocolV2.schemaVersion,
            commandID: commandID,
            sourceRequestID: sourceRequestID,
            bundleID: bundleID,
            farmID: farmID,
            farmGeneration: farmGeneration,
            accountID: accountID,
            deviceID: deviceID,
            deviceSequence: deviceSequence,
            createdAt: createdAt,
            occurredAt: occurredAt,
            commandKind: payload.kind,
            payload: payload,
            affectedStreams: affectedStreams.sorted(by: Self.streamOrdering),
            affectedFields: affectedFields.sorted(by: Self.fieldOrdering),
            fieldChanges: fieldChanges.sorted { $0.field < $1.field },
            prerequisiteCommandIDs: prerequisiteCommandIDs.sorted(by: Self.uuidOrdering),
            requiredAssetIDs: requiredAssetIDs.sorted(by: Self.uuidOrdering)
        )
        self.protocolVersion = unsigned.protocolVersion
        self.schemaVersion = unsigned.schemaVersion
        self.commandID = unsigned.commandID
        self.sourceRequestID = unsigned.sourceRequestID
        self.bundleID = unsigned.bundleID
        self.farmID = unsigned.farmID
        self.farmGeneration = unsigned.farmGeneration
        self.accountID = unsigned.accountID
        self.deviceID = unsigned.deviceID
        self.deviceSequence = unsigned.deviceSequence
        self.createdAt = unsigned.createdAt
        self.occurredAt = unsigned.occurredAt
        self.commandKind = unsigned.commandKind
        self.payload = unsigned.payload
        self.affectedStreams = unsigned.affectedStreams
        self.affectedFields = unsigned.affectedFields
        self.fieldChanges = unsigned.fieldChanges
        self.prerequisiteCommandIDs = unsigned.prerequisiteCommandIDs
        self.requiredAssetIDs = unsigned.requiredAssetIDs
        self.contentDigest = try ESheepCloudCanonicalCodec.digest(unsigned)
    }

    var canonicalSigningData: Data {
        Data([
            "esheep-cloud-command-v2",
            farmID.uuidString.lowercased(),
            String(farmGeneration),
            accountID.uuidString.lowercased(),
            deviceID.uuidString.lowercased(),
            String(deviceSequence),
            commandID.uuidString.lowercased(),
            contentDigest,
        ].joined(separator: "\n").utf8)
    }

    var canonicalUnsignedData: Data {
        get throws {
            try ESheepCloudCanonicalCodec.encode(ESheepCloudUnsignedCommandV2(
                protocolVersion: protocolVersion,
                schemaVersion: schemaVersion,
                commandID: commandID,
                sourceRequestID: sourceRequestID,
                bundleID: bundleID,
                farmID: farmID,
                farmGeneration: farmGeneration,
                accountID: accountID,
                deviceID: deviceID,
                deviceSequence: deviceSequence,
                createdAt: createdAt,
                occurredAt: occurredAt,
                commandKind: commandKind,
                payload: payload,
                affectedStreams: affectedStreams,
                affectedFields: affectedFields,
                fieldChanges: fieldChanges,
                prerequisiteCommandIDs: prerequisiteCommandIDs,
                requiredAssetIDs: requiredAssetIDs
            ))
        }
    }

    func validateDigest() throws {
        try Self.validateStructure(
            commandKind: commandKind,
            farmGeneration: farmGeneration,
            deviceSequence: deviceSequence,
            commandID: commandID,
            affectedStreams: affectedStreams,
            affectedFields: affectedFields,
            fieldChanges: fieldChanges,
            prerequisiteCommandIDs: prerequisiteCommandIDs,
            requiredAssetIDs: requiredAssetIDs,
            requiresCanonicalOrder: true
        )
        let unsigned = ESheepCloudUnsignedCommandV2(
            protocolVersion: protocolVersion,
            schemaVersion: schemaVersion,
            commandID: commandID,
            sourceRequestID: sourceRequestID,
            bundleID: bundleID,
            farmID: farmID,
            farmGeneration: farmGeneration,
            accountID: accountID,
            deviceID: deviceID,
            deviceSequence: deviceSequence,
            createdAt: createdAt,
            occurredAt: occurredAt,
            commandKind: commandKind,
            payload: payload,
            affectedStreams: affectedStreams,
            affectedFields: affectedFields,
            fieldChanges: fieldChanges,
            prerequisiteCommandIDs: prerequisiteCommandIDs,
            requiredAssetIDs: requiredAssetIDs
        )
        guard protocolVersion == ESheepCloudProtocolV2.protocolVersion,
              schemaVersion == ESheepCloudProtocolV2.schemaVersion,
              commandKind == payload.kind,
              contentDigest == (try ESheepCloudCanonicalCodec.digest(unsigned)) else {
            throw ESheepCloudContractError.invalidCommandDigest
        }
    }

    private static func streamOrdering(_ lhs: ESheepCloudStreamReferenceV2, _ rhs: ESheepCloudStreamReferenceV2) -> Bool {
        lhs.type == rhs.type
            ? lhs.id.uuidString < rhs.id.uuidString
            : lhs.type < rhs.type
    }

    private static func fieldOrdering(_ lhs: ESheepCloudFieldObservationV2, _ rhs: ESheepCloudFieldObservationV2) -> Bool {
        if lhs.stream.type != rhs.stream.type { return lhs.stream.type < rhs.stream.type }
        if lhs.stream.id != rhs.stream.id { return uuidOrdering(lhs.stream.id, rhs.stream.id) }
        return lhs.field < rhs.field
    }

    private static func uuidOrdering(_ lhs: UUID, _ rhs: UUID) -> Bool {
        lhs.uuidString < rhs.uuidString
    }

    private static func validateStructure(
        commandKind: String,
        farmGeneration: Int,
        deviceSequence: Int64,
        commandID: UUID,
        affectedStreams: [ESheepCloudStreamReferenceV2],
        affectedFields: [ESheepCloudFieldObservationV2],
        fieldChanges: [ESheepCloudFieldPatchV2],
        prerequisiteCommandIDs: [UUID],
        requiredAssetIDs: [UUID],
        requiresCanonicalOrder: Bool = false
    ) throws {
        let streamSet = Set(affectedStreams)
        let fieldKeys = affectedFields.map {
            "\($0.stream.type)\u{1f}\($0.stream.id.uuidString.lowercased())\u{1f}\($0.field)"
        }
        let changeFields = fieldChanges.map(\.field)
        guard !commandKind.isEmpty,
              farmGeneration >= 0,
              deviceSequence > 0,
              !affectedStreams.isEmpty,
              streamSet.count == affectedStreams.count,
              affectedStreams.allSatisfy({
                  !$0.type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }),
              Set(fieldKeys).count == fieldKeys.count,
              affectedFields.allSatisfy({ observation in
                  streamSet.contains(observation.stream) &&
                      !observation.field.isEmpty &&
                      observation.observedVersion >= 0 &&
                      isSHA256Hex(observation.baseValueDigest)
              }),
              Set(changeFields).count == changeFields.count,
              fieldChanges.allSatisfy({ !$0.field.isEmpty }),
              Set(prerequisiteCommandIDs).count == prerequisiteCommandIDs.count,
              !prerequisiteCommandIDs.contains(commandID),
              Set(requiredAssetIDs).count == requiredAssetIDs.count else {
            throw ESheepCloudContractError.malformedPayload
        }
        if !fieldChanges.isEmpty {
            guard affectedStreams.count == 1,
                  Set(changeFields) == Set(affectedFields.map(\.field)),
                  affectedFields.allSatisfy({ $0.stream == affectedStreams[0] }) else {
                throw ESheepCloudContractError.malformedPayload
            }
        }
        let fieldPatchKinds: Set<String> = [
            "farm.updateLocation",
            "pen.update",
            "pen.setActive",
            "sheep.patchProfile",
            "sheepAvatar.set",
            "sheepAvatar.clear",
        ]
        if fieldPatchKinds.contains(commandKind) {
            guard !fieldChanges.isEmpty,
                  affectedFields.count == fieldChanges.count else {
                throw ESheepCloudContractError.malformedPayload
            }
        }
        if requiresCanonicalOrder {
            guard affectedStreams == affectedStreams.sorted(by: streamOrdering),
                  affectedFields == affectedFields.sorted(by: fieldOrdering),
                  fieldChanges == fieldChanges.sorted(by: { $0.field < $1.field }),
                  prerequisiteCommandIDs == prerequisiteCommandIDs.sorted(by: uuidOrdering),
                  requiredAssetIDs == requiredAssetIDs.sorted(by: uuidOrdering) else {
                throw ESheepCloudContractError.malformedPayload
            }
        }
    }

    private static func isSHA256Hex(_ value: String) -> Bool {
        value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    }
}

private struct ESheepCloudUnsignedCommandV2: Codable {
    let protocolVersion: Int
    let schemaVersion: Int
    let commandID: UUID
    let sourceRequestID: UUID
    let bundleID: UUID?
    let farmID: UUID
    let farmGeneration: Int
    let accountID: UUID
    let deviceID: UUID
    let deviceSequence: Int64
    let createdAt: Date
    let occurredAt: Date
    let commandKind: String
    let payload: ESheepCloudCommandPayloadV2
    let affectedStreams: [ESheepCloudStreamReferenceV2]
    let affectedFields: [ESheepCloudFieldObservationV2]
    let fieldChanges: [ESheepCloudFieldPatchV2]
    let prerequisiteCommandIDs: [UUID]
    let requiredAssetIDs: [UUID]
}

struct ESheepCloudSignedCommandV2: Codable, Sendable, Equatable {
    let command: ESheepCloudCommandEnvelopeV2
    let deviceSignature: Data
}

enum ESheepCloudRejectionReasonV2: Codable, Sendable, Equatable {
    case authenticationRequired
    case permissionDenied
    case applicationUpdateRequired
    case farmGenerationChanged
    case prerequisiteRejected(commandID: UUID)
    case resourceUnavailable(assetID: UUID)
    case businessRule(code: String, explanation: String, allowedActions: [String])
    case integrityHold(traceID: String)
    case malformedCommand(explanation: String)
}

struct ESheepCloudAttentionPayloadV2: Codable, Sendable, Equatable {
    let id: UUID
    let commandID: UUID
    let stream: ESheepCloudStreamReferenceV2
    let recordType: String
    let recordID: UUID
    let recordDisplayName: String
    let field: String
    let fieldDisplayName: String
    let deviceValue: ESheepCloudValueV2
    let cloudValue: ESheepCloudValueV2
    let baseValueDigest: String
    let deviceAccountID: UUID
    let deviceAccountDisplayName: String?
    let deviceID: UUID
    let deviceDisplayName: String?
    let deviceOccurredAt: Date
    let cloudAccountID: UUID?
    let cloudAccountDisplayName: String?
    let cloudDeviceID: UUID?
    let cloudDeviceDisplayName: String?
    let cloudReceivedAt: Date?
    let explanation: String
}

enum ESheepCloudEventPayloadV2: Codable, Sendable, Equatable {
    /// The server-accepted, strongly typed business command. Facts, ledgers,
    /// OR-sets and state machines are replayed from this payload; the source
    /// command digest in the enclosing event prevents payload substitution.
    case businessCommandApplied(
        commandKind: String,
        payload: ESheepCloudCommandPayloadV2
    )
    case factAppended(kind: String, recordID: UUID, bodyDigest: String)
    case fieldsPatched(
        stream: ESheepCloudStreamReferenceV2,
        changes: [ESheepCloudAppliedFieldChangeV2]
    )
    case relationshipChanged(kind: String, subjectID: UUID, objectID: UUID?)
    case stateTransitioned(kind: String, recordID: UUID, from: String?, to: String)
    case assetChanged(assetID: UUID, state: String, contentSHA256: String)
    case attentionResolved(
        attentionID: UUID,
        field: String,
        choice: ESheepCloudAttentionResolutionChoiceV2,
        chosenValue: ESheepCloudValueV2
    )
}

/// Event discriminators emitted by the V2 authority.  The wire decoders must
/// keep this allow-list deliberately small: treating an unknown discriminator
/// as a generic business command would let a newer/incorrect event mutate a
/// local store without a reducer that understands its semantics.
enum ESheepCloudEventKindV2 {
    static let fieldPatch = "fields_patched"
    static let attentionResolved = "attention_resolved"
    static let businessMergeModes: Set<String> = [
        "append_fact",
        "or_set",
        "ledger",
        "state_machine",
        "lifecycle",
    ]

    static func isKnown(_ kind: String) -> Bool {
        kind == fieldPatch || kind == attentionResolved || businessMergeModes.contains(kind)
    }
}

struct ESheepCloudAppliedFieldChangeV2: Codable, Sendable, Equatable {
    let field: String
    let value: ESheepCloudValueV2
    let valueDigest: String
    let fieldVersion: Int64
}

struct ESheepCloudNonFieldStreamStateV2: Codable, Sendable, Equatable {
    let eventCount: Int64
    let lastCommandDigest: String
    let lastCommandID: String
    let lastCommandKind: String
}

struct ESheepCloudEventEnvelopeV2: Codable, Sendable, Equatable {
    let protocolVersion: Int
    let schemaVersion: Int
    let farmID: UUID
    let farmGeneration: Int
    let eventSequence: Int64
    let eventID: UUID
    let commandID: UUID
    let sourceCommandDigest: String
    let stream: ESheepCloudStreamReferenceV2
    let payload: ESheepCloudEventPayloadV2
    let affectedFields: [String]
    /// Digest of the exact canonical event-body JSON received from the
    /// authority. The wire decoder verifies the canonical bytes before it
    /// constructs the typed payload, and the outer receipt digest binds this
    /// value into the farm event chain.
    let eventBodyDigest: String
    let beforeDigest: String
    let afterDigest: String
    let actorAccountID: UUID
    let sourceDeviceID: UUID
    let sourceDeviceSequence: Int64
    let occurredAt: Date
    let receivedAt: Date
    let eventDigest: String

    func validateDigest() throws {
        guard protocolVersion == ESheepCloudProtocolV2.protocolVersion,
              schemaVersion == ESheepCloudProtocolV2.schemaVersion,
              eventSequence > 0,
              sourceDeviceSequence > 0,
              sourceCommandDigest.range(
                of: "^[0-9a-f]{64}$",
                options: .regularExpression
              ) != nil,
              eventBodyDigest.range(
                of: "^[0-9a-f]{64}$",
                options: .regularExpression
              ) != nil,
              beforeDigest.range(
                of: "^[0-9a-f]{64}$",
                options: .regularExpression
              ) != nil,
              afterDigest.range(
                of: "^[0-9a-f]{64}$",
                options: .regularExpression
              ) != nil,
              eventDigest == ESheepCloudEventDigestV2.hex(for: self) else {
            throw ESheepCloudContractError.invalidEventDigest
        }
    }
}

enum ESheepCloudEventDigestV2 {
    static func hex(for event: ESheepCloudEventEnvelopeV2) -> String {
        let canonical = [
            "esheep-cloud-event-v2",
            event.farmID.uuidString.lowercased(),
            String(event.farmGeneration),
            String(event.eventSequence),
            event.eventID.uuidString.lowercased(),
            event.commandID.uuidString.lowercased(),
            event.stream.type,
            event.stream.id.uuidString.lowercased(),
            event.affectedFields.sorted().joined(separator: ","),
            event.eventBodyDigest,
            event.beforeDigest,
            event.afterDigest,
            event.actorAccountID.uuidString.lowercased(),
            event.sourceDeviceID.uuidString.lowercased(),
            String(event.sourceDeviceSequence),
            String(Int64((event.occurredAt.timeIntervalSince1970 * 1_000).rounded())),
            String(Int64((event.receivedAt.timeIntervalSince1970 * 1_000).rounded())),
            event.sourceCommandDigest,
        ].joined(separator: "\n")
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

enum ESheepCloudEventBodyIntegrityV2 {
    static func digest(canonicalJSON: String) -> String {
        SHA256.hash(data: Data(canonicalJSON.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func validate(canonicalJSON: String, expectedDigest: String) throws {
        guard expectedDigest.range(
            of: "^[0-9a-f]{64}$",
            options: .regularExpression
        ) != nil,
        digest(canonicalJSON: canonicalJSON) == expectedDigest else {
            throw ESheepCloudContractError.invalidEventDigest
        }
    }
}

enum ESheepCloudCommandResultV2: Codable, Sendable, Equatable {
    case accepted(events: [ESheepCloudEventEnvelopeV2], cloudHead: Int64)
    case duplicate(original: ESheepCloudOriginalResultV2)
    /// A multi-field patch can merge some fields and require a decision for
    /// more than one other field. Keep both the accepted event and every
    /// durable decision item in one result so the client cannot strand either.
    case needsConfirmation(
        items: [ESheepCloudAttentionPayloadV2],
        acceptedEvents: [ESheepCloudEventEnvelopeV2],
        cloudHead: Int64
    )
    case rejected(ESheepCloudRejectionReasonV2)
}

struct ESheepCloudOriginalResultV2: Codable, Sendable, Equatable {
    let commandID: UUID
    let events: [ESheepCloudEventEnvelopeV2]
    let attention: ESheepCloudAttentionPayloadV2?
    let rejection: ESheepCloudRejectionReasonV2?
    let cloudHead: Int64
}

struct ESheepCloudSnapshotRecordCountV2: Codable, Sendable, Equatable {
    let recordType: String
    let count: Int
}

struct ESheepCloudSnapshotChunkDescriptorV2: Codable, Sendable, Equatable {
    let index: Int
    let byteCount: Int64
    let contentSHA256: String
}

struct ESheepCloudAssetManifestEntryV2: Codable, Sendable, Equatable {
    let assetID: UUID
    let sheepID: UUID?
    let contentSHA256: String
    let thumbnailSHA256: String?
    let avatarSHA256: String?
    let originalSHA256: String
    let thumbnailByteCount: Int64
    let avatarByteCount: Int64
    let originalByteCount: Int64
    let isCurrentAvatar: Bool
}

/// Account-independent farm identity captured in the same immutable database
/// view as an initial-sync snapshot. Membership is deliberately not part of
/// this value: the server re-evaluates the requesting account's current role
/// every time it opens an initial-sync session.
struct ESheepCloudFarmProfileV2: Codable, Sendable, Equatable {
    let farmID: UUID
    let ownerAccountID: UUID
    let name: String
    let createdAt: Date
    let updatedAt: Date
    let locationDisplayName: String?
    let latitude: Double?
    let longitude: Double?
    let coordinateReferenceSystem: String
    let addressSnapshot: String?
    let timeZoneIdentifier: String
    let locationSourceRawValue: String?
    let horizontalAccuracyMeters: Double?
    let locationUpdatedAt: Date?
}

struct ESheepCloudSnapshotManifestV2: Codable, Sendable, Equatable {
    let snapshotID: UUID
    let farmID: UUID
    let farmGeneration: Int
    let schemaVersion: Int
    let boundaryEventSequence: Int64
    let eventHeadAtCreation: Int64
    let recordCounts: [ESheepCloudSnapshotRecordCountV2]
    let chunks: [ESheepCloudSnapshotChunkDescriptorV2]
    let businessHistoryStartedAt: Date?
    let businessHistoryEndedAt: Date?
    let relationshipDigest: String
    let fieldVersionDigest: String
    let farmProfileDigest: String
    let assets: [ESheepCloudAssetManifestEntryV2]
    let totalDigest: String
    let createdAt: Date
}

struct ESheepCloudInitialSyncTicketV2: Codable, Sendable, Equatable {
    let manifest: ESheepCloudSnapshotManifestV2
    let farmProfile: ESheepCloudFarmProfileV2
    let memberAccountID: UUID
    let memberRole: FarmRole
    let membershipStatus: String
    let expiresAt: Date
}

struct ESheepCloudEventPageV2: Codable, Sendable, Equatable {
    let events: [ESheepCloudEventEnvelopeV2]
    let cloudHead: Int64
    let hasMore: Bool
}

enum ESheepCloudAttentionResolutionChoiceV2: String, Codable, Sendable, Equatable {
    case useThisDevice = "use_this_device"
    case keepCloud = "keep_cloud"
    case abandonOperation = "abandon_operation"
    case resubmit

    var signingValue: String {
        rawValue
    }
}

struct ESheepCloudAttentionResolutionV2: Codable, Sendable {
    let attentionID: UUID
    let resolutionCommandID: UUID
    let choice: ESheepCloudAttentionResolutionChoiceV2
    let expectedCloudValueDigest: String
    let farmGeneration: Int
    let accountID: UUID
    let deviceID: UUID
    let deviceSequence: Int64
    let deviceSignature: Data

    var canonicalSigningData: Data {
        Data([
            "esheep-cloud-attention-resolution-v2",
            attentionID.uuidString.lowercased(),
            resolutionCommandID.uuidString.lowercased(),
            choice.signingValue,
            expectedCloudValueDigest.lowercased(),
            String(farmGeneration),
            accountID.uuidString.lowercased(),
            deviceID.uuidString.lowercased(),
            String(deviceSequence),
        ].joined(separator: "\n").utf8)
    }
}

enum ESheepCloudAssetVariantV2: String, Codable, Sendable {
    case thumbnail
    case avatar
    case original
}

enum ESheepCloudAssetTransferDirectionV2: String, Codable, Sendable {
    case upload
    case download
}

struct ESheepCloudAssetTransferRequestV2: Codable, Sendable {
    let farmID: UUID
    let farmGeneration: Int
    let assetID: UUID
    let sheepID: UUID?
    /// Stable identity of the logical photo asset (the optimized original).
    let contentSHA256: String
    /// Digest of the exact bytes transferred for the selected variant.
    let variantSHA256: String
    let metadata: [String: String]
    let metadataDigest: String
    let variant: ESheepCloudAssetVariantV2
    let direction: ESheepCloudAssetTransferDirectionV2
    let byteOffset: Int64
    let byteCount: Int64
}

struct ESheepCloudAssetTransferTicketV2: Codable, Sendable {
    let assetID: UUID
    let variant: ESheepCloudAssetVariantV2
    let objectKey: String
    let signedURL: URL
    /// Opaque short-lived credential used only by the Infrastructure transfer
    /// implementation. It is never persisted as cloud or business state.
    let authorizationToken: String?
    /// The server has already verified these immutable bytes. An interrupted
    /// client can therefore finish locally without overwriting the object.
    let isAlreadyVerified: Bool
    let byteOffset: Int64
    let expiresAt: Date
}

struct ESheepCloudStatusV2: Codable, Sendable, Equatable {
    let farmID: UUID
    let farmGeneration: Int
    let cloudHead: Int64
    let latestSnapshotID: UUID?
    let v2Ready: Bool
    let writeFrozen: Bool
    let writeFreezeTraceID: String?
    let attentionItems: [ESheepCloudAttentionPayloadV2]
    let serverTime: Date
}

protocol ESheepCloudGateway: Sendable {
    func openInitialSync(farmID: UUID, farmGeneration: Int?) async throws -> ESheepCloudInitialSyncTicketV2
    func downloadSnapshotChunk(snapshotID: UUID, chunkIndex: Int, byteOffset: Int64) async throws -> Data
    func pullEvents(farmID: UUID, farmGeneration: Int, after eventSequence: Int64, limit: Int) async throws -> ESheepCloudEventPageV2
    func submitCommands(_ commands: [ESheepCloudSignedCommandV2]) async throws -> [UUID: ESheepCloudCommandResultV2]
    func queryCommandStatus(farmID: UUID, commandIDs: [UUID]) async throws -> [UUID: ESheepCloudCommandResultV2]
    func resolveAttention(farmID: UUID, resolution: ESheepCloudAttentionResolutionV2) async throws -> ESheepCloudCommandResultV2
    func prepareAssetTransfer(_ request: ESheepCloudAssetTransferRequestV2) async throws -> ESheepCloudAssetTransferTicketV2
    func fetchCloudStatus(farmID: UUID) async throws -> ESheepCloudStatusV2
}

enum ESheepCloudContractError: LocalizedError, Equatable {
    case unsupportedProtocol
    case unsupportedSchema
    case invalidCommandDigest
    case invalidEventDigest
    case missingStream
    case missingDeviceIdentity
    case malformedPayload

    var errorDescription: String? {
        switch self {
        case .unsupportedProtocol: "需要更新 eSheep+ 后才能继续使用云端牧场。"
        case .unsupportedSchema: "这部分牧场资料需要新版 eSheep+ 才能读取。"
        case .invalidCommandDigest: "待保存内容的完整性检查未通过。"
        case .invalidEventDigest: "接收到的牧场资料完整性检查未通过。"
        case .missingStream: "未找到这项业务对应的云端资料流。"
        case .missingDeviceIdentity: "当前设备尚未完成安全登记。"
        case .malformedPayload: "这项业务内容不完整，无法安全保存。"
        }
    }
}

enum ESheepCloudCanonicalCodec {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder().encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder().decode(type, from: data)
    }

    static func digest<T: Encodable>(_ value: T) throws -> String {
        SHA256.hash(data: try encode(value))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
