import CryptoKit
import Foundation
import SwiftData

enum ESheepCloudCheckpointError: Error, LocalizedError {
    case schemaCoverage(String), malformedRecord, duplicateRecord, foreignFarm
    case unsupportedVersion, digestMismatch, sizeLimit, incomplete, insufficientDiskSpace

    var errorDescription: String? {
        if case .insufficientDiskSpace = self { return "本机空间不足，已保留接收进度，请释放空间后继续。" }
        return "业务检查点核对未通过，已保留原有资料。"
    }
}

/// Untagged JSON values keep the wire as ordinary JSON, without wrapping the
/// business document in Base64. Integer decoding precedes floating point.
indirect enum ESheepCloudCheckpointJSON: Codable, Sendable, Equatable {
    case null, bool(Bool), integer(Int64), number(Double), string(String)
    case array([Self]), object([String: Self])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int64.self) { self = .integer(v) }
        else if let v = try? c.decode(Double.self), v.isFinite { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([Self].self) { self = .array(v) }
        else { self = .object(try c.decode([String: Self].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

struct ESheepCloudCheckpointRecord: Codable, Sendable, Equatable {
    let model: String
    let values: [String: ESheepCloudCheckpointJSON]
}

enum ESheepCloudCheckpointDisposition: String, Codable, Sendable {
    case transfer, rebuild, localOnly
}

/// Typed key paths are the allowlist. No SQL names, dynamic setters, or model
/// types supplied by a downloaded document are ever executed.
enum ESheepCloudCheckpointDataEncoding {
    case canonicalJSON
}

struct ESheepCloudCheckpointField<M: PersistentModel> {
    let name: String
    let read: (M) throws -> ESheepCloudCheckpointJSON
    let write: (any BackingData<M>, ESheepCloudCheckpointJSON) throws -> Void

    // SwiftData stores Date as the exact Double seconds since 2001. Converting
    // through Unix milliseconds introduces an epoch-offset rounding error.
    // Checkpoint v1 dates preserve that reference-epoch Double exactly.
    init(_ name: String, _ keyPath: KeyPath<M, Date>) {
        self.name = name
        read = { .number($0[keyPath: keyPath].timeIntervalSinceReferenceDate) }
        write = { backing, value in
            backing.setValue(forKey: keyPath, to: Date(timeIntervalSinceReferenceDate: try Self.dateSeconds(value)))
        }
    }

    init(_ name: String, _ keyPath: KeyPath<M, Date?>) {
        self.name = name
        read = { $0[keyPath: keyPath].map { .number($0.timeIntervalSinceReferenceDate) } ?? .null }
        write = { backing, value in
            let date: Date? = value == .null ? nil : Date(timeIntervalSinceReferenceDate: try Self.dateSeconds(value))
            backing.setValue(forKey: keyPath, to: date)
        }
    }

    private static func dateSeconds(_ value: ESheepCloudCheckpointJSON) throws -> Double {
        switch value {
        case .number(let number) where number.isFinite: return number
        case .integer(let integer): return Double(integer)
        default: throw ESheepCloudCheckpointError.malformedRecord
        }
    }

    /// JSON stored as Data need not carry a second Base64 envelope on the wire.
    /// Only canonical bytes use this representation; other bytes are preserved
    /// explicitly, including whitespace and numeric spelling from older stores.
    init(_ name: String, _ keyPath: KeyPath<M, Data>, encoding: ESheepCloudCheckpointDataEncoding) {
        self.name = name
        read = { model in
            let bytes = model[keyPath: keyPath]
            if let value = try? ESheepCloudCanonicalCodec.decode(ESheepCloudCheckpointJSON.self, from: bytes),
               let canonical = try? ESheepCloudCanonicalCodec.encode(value), canonical == bytes {
                return .object(["json": value])
            }
            return .object(["base64": .string(bytes.base64EncodedString())])
        }
        write = { backing, value in
            let bytes: Data
            switch value {
            case .object(let fields) where fields.count == 1:
                if let json = fields["json"] {
                    bytes = try ESheepCloudCanonicalCodec.encode(json)
                } else if case .string(let encoded) = fields["base64"],
                          let decoded = Data(base64Encoded: encoded) {
                    bytes = decoded
                } else {
                    throw ESheepCloudCheckpointError.malformedRecord
                }
            case .string(let encoded):
                // Earlier unpublished v1 candidates used plain Base64 fields.
                guard let decoded = Data(base64Encoded: encoded) else {
                    throw ESheepCloudCheckpointError.malformedRecord
                }
                bytes = decoded
            default:
                throw ESheepCloudCheckpointError.malformedRecord
            }
            backing.setValue(forKey: keyPath, to: bytes)
        }
    }

    init<V: Codable>(_ name: String, _ keyPath: KeyPath<M, V>) {
        self.name = name
        read = { model in
            try ESheepCloudCanonicalCodec.decode(ESheepCloudCheckpointJSON.self,
                from: ESheepCloudCanonicalCodec.encode(model[keyPath: keyPath]))
        }
        write = { backing, value in
            let decoded = try ESheepCloudCanonicalCodec.decode(V.self,
                from: ESheepCloudCanonicalCodec.encode(value))
            backing.setValue(forKey: keyPath, to: decoded)
        }
    }
}

struct ESheepCloudCheckpointModelAdapter {
    let name: String
    let disposition: ESheepCloudCheckpointDisposition
    let fieldNames: Set<String>
    let exportRows: (UUID, ModelContext) throws -> [ESheepCloudCheckpointRecord]
    let exportRecord: (any PersistentModel) throws -> ESheepCloudCheckpointRecord
    let insertRow: (ESheepCloudCheckpointRecord, UUID, ModelContext) throws -> Void
    let validateSchema: () throws -> Void

    init<M: PersistentModel>(
        _ model: M.Type,
        disposition: ESheepCloudCheckpointDisposition,
        fields: [ESheepCloudCheckpointField<M>],
        farmID: KeyPath<M, UUID>?,
        recordID: KeyPath<M, UUID>
    ) {
        name = String(describing: model)
        self.disposition = disposition
        fieldNames = Set(fields.map(\.name))
        let modelName = String(describing: model)
        validateSchema = {
            let actual = Set(Schema([M.self]).entities.flatMap { $0.properties.map(\.name) })
            guard actual == Set(fields.map(\.name)) else {
                throw ESheepCloudCheckpointError.schemaCoverage(modelName)
            }
        }
        let encodeRecord: (M) throws -> ESheepCloudCheckpointRecord = { value in
            if let operation = value as? DomainOperation {
                try ESheepCloudPurposeHistory.validateCheckpointOperation(operation)
            }
            return ESheepCloudCheckpointRecord(model: modelName,
                values: try Dictionary(uniqueKeysWithValues: fields.map { ($0.name, try $0.read(value)) }))
        }
        exportRecord = { value in
            guard let typed = value as? M else { throw ESheepCloudCheckpointError.malformedRecord }
            return try encodeRecord(typed)
        }
        exportRows = { requestedFarm, context in
            guard disposition == .transfer else { return [] }
            return try context.fetch(FetchDescriptor<M>()).filter { value in
                farmID.map { value[keyPath: $0] == requestedFarm }
                    ?? (value[keyPath: recordID] == requestedFarm)
            }.sorted { $0[keyPath: recordID].uuidString < $1[keyPath: recordID].uuidString }
                .map(encodeRecord)
        }
        insertRow = { row, requestedFarm, context in
            guard disposition == .transfer, row.model == modelName,
                  Set(row.values.keys) == Set(fields.map(\.name)) else {
                throw ESheepCloudCheckpointError.malformedRecord
            }
            // Fill a new, unattached backing object before constructing the
            // model. This avoids invoking business command initializers, which
            // legitimately create current timestamps and inferred defaults.
            let backing: any BackingData<M> = M.createBackingData()
            for field in fields { try field.write(backing, row.values[field.name]!) }
            let value = M(backingData: backing)
            let owner = farmID.map { value[keyPath: $0] } ?? value[keyPath: recordID]
            guard owner == requestedFarm else { throw ESheepCloudCheckpointError.foreignFarm }
            if let operation = value as? DomainOperation {
                try ESheepCloudPurposeHistory.validateCheckpointOperation(operation)
            }
            context.insert(value)
        }
    }
}
