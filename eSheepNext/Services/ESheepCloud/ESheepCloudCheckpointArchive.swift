import CryptoKit
import Foundation
import SwiftData
import zlib

struct ESheepCloudCheckpointManifest: Codable, Sendable, Equatable {
    struct Chunk: Codable, Sendable, Equatable {
        let index: Int
        let objectKey: String
        let compressedBytes: Int
        let uncompressedBytes: Int
        let compressedSHA256: String
        let contentSHA256: String
        let recordCount: Int
        let modelNames: [String]?

        init(index: Int, objectKey: String, compressedBytes: Int, uncompressedBytes: Int,
             compressedSHA256: String, contentSHA256: String, recordCount: Int,
             modelNames: [String]? = nil) {
            self.index = index; self.objectKey = objectKey
            self.compressedBytes = compressedBytes; self.uncompressedBytes = uncompressedBytes
            self.compressedSHA256 = compressedSHA256; self.contentSHA256 = contentSHA256
            self.recordCount = recordCount; self.modelNames = modelNames
        }
    }
    let formatVersion: Int
    let minimumClientCapability: Int
    let checkpointID: UUID
    let farmID: UUID
    let farmGeneration: Int
    let boundaryEventSequence: Int64
    let boundaryEventDigest: String
    let receiptChainDigest: String
    let businessDigest: String
    let modelCounts: [String: Int]
    let chunks: [Chunk]

    func validate() throws {
        guard formatVersion == 1, minimumClientCapability <= 1 else {
            throw ESheepCloudCheckpointError.unsupportedVersion
        }
        let prefix = "\(farmID.uuidString.lowercased())/\(checkpointID.uuidString.lowercased())/"
        guard farmGeneration >= 0, boundaryEventSequence >= 0,
              [boundaryEventDigest, receiptChainDigest, businessDigest].allSatisfy(Self.validDigest),
              chunks.count <= 10_000, chunks.map(\.index) == Array(chunks.indices),
              modelCounts.values.allSatisfy({ $0 >= 0 }),
              Set(chunks.map(\.objectKey)).count == chunks.count,
              chunks.allSatisfy({ c in
                  c.objectKey == prefix + String(format: "%05d.json.gz", c.index) &&
                  c.compressedBytes > 0 && c.compressedBytes <= 8 * 1_024 * 1_024 &&
                  c.uncompressedBytes > 0 && c.uncompressedBytes <= 8 * 1_024 * 1_024 &&
                  c.recordCount > 0 && (c.modelNames.map { !$0.isEmpty && $0 == Array(Set($0)).sorted() &&
                      Set($0).isSubset(of: Set(modelCounts.keys)) } ?? true) && Self.validDigest(c.compressedSHA256) && Self.validDigest(c.contentSHA256)
              }) else { throw ESheepCloudCheckpointError.malformedRecord }
    }

    private static func validDigest(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
    }
}

enum ESheepCloudCheckpointGzip {
    static let limit = 8 * 1_024 * 1_024

    static func compress(_ data: Data) throws -> Data { try transform(data, compress: true, expected: nil) }
    static func decompress(_ data: Data, expected: Int) throws -> Data {
        guard expected > 0, expected <= limit else { throw ESheepCloudCheckpointError.sizeLimit }
        return try transform(data, compress: false, expected: expected)
    }

    private static func transform(_ data: Data, compress: Bool, expected: Int?) throws -> Data {
        guard !data.isEmpty, data.count <= limit else { throw ESheepCloudCheckpointError.sizeLimit }
        var stream = z_stream()
        let status = compress
            ? deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY,
                            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            : inflateInit2_(&stream, 31, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw ESheepCloudCheckpointError.malformedRecord }
        defer { if compress { deflateEnd(&stream) } else { inflateEnd(&stream) } }
        return try data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress!)
            stream.avail_in = uInt(data.count)
            var output = Data()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let code = buffer.withUnsafeMutableBytes { bytes -> Int32 in
                    stream.next_out = bytes.bindMemory(to: Bytef.self).baseAddress!
                    stream.avail_out = uInt(bytes.count)
                    return compress ? deflate(&stream, Z_FINISH) : inflate(&stream, Z_NO_FLUSH)
                }
                let count = buffer.count - Int(stream.avail_out)
                guard output.count + count <= limit,
                      expected.map({ output.count + count <= $0 }) ?? true else {
                    throw ESheepCloudCheckpointError.sizeLimit
                }
                output.append(contentsOf: buffer.prefix(count))
                if code == Z_STREAM_END {
                    guard stream.avail_in == 0, expected.map({ output.count == $0 }) ?? true else {
                        throw ESheepCloudCheckpointError.malformedRecord
                    }
                    return output
                }
                guard code == Z_OK, count > 0 else { throw ESheepCloudCheckpointError.malformedRecord }
            }
        }
    }
}

/// Used only by the controlled publisher and verification fixtures. It accepts
/// a rebuilt cloud projection, never selects or discovers a device store.
enum ESheepCloudCheckpointArchive {
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func export(farmID: UUID, context: ModelContext, directory: URL) throws -> ESheepCloudCheckpointManifest {
        try ESheepCloudCheckpointRegistry.validateCoverage()
        let states = try context.fetch(FetchDescriptor<ESheepCloudFarmState>(predicate: #Predicate { $0.farmID == farmID }))
        guard states.count == 1, let state = states.first, state.integrityState == .passed else {
            throw ESheepCloudCheckpointError.incomplete
        }
        let head = state.lastAppliedEventSequence
        let generation = state.farmGeneration
        let receipts = try context.fetch(FetchDescriptor<ESheepCloudEventReceipt>(predicate: #Predicate {
            $0.farmID == farmID && $0.farmGeneration == generation && $0.eventSequence == head
        }))
        guard head == 0 || receipts.count == 1 else { throw ESheepCloudCheckpointError.incomplete }
        let id = UUID()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var chunks: [ESheepCloudCheckpointManifest.Chunk] = []
        var counts: [String: Int] = [:]
        var buffer: [ESheepCloudCheckpointRecord] = []
        var bufferBytes = 2
        var businessHasher = SHA256()
        func flush() throws {
            guard !buffer.isEmpty else { return }
            let raw = try ESheepCloudCanonicalCodec.encode(buffer)
            let compressed = try ESheepCloudCheckpointGzip.compress(raw)
            let index = chunks.count
            let name = String(format: "%05d.json.gz", index)
            try compressed.write(to: directory.appending(path: name), options: .atomic)
            chunks.append(.init(index: index,
                objectKey: "\(farmID.uuidString.lowercased())/\(id.uuidString.lowercased())/\(name)",
                compressedBytes: compressed.count, uncompressedBytes: raw.count,
                compressedSHA256: digest(compressed), contentSHA256: digest(raw), recordCount: buffer.count,
                modelNames: Array(Set(buffer.map(\.model))).sorted()))
            buffer.removeAll(keepingCapacity: true)
            bufferBytes = 2
        }
        for adapter in ESheepCloudCheckpointRegistry.adapters where adapter.disposition == .transfer {
            let rows = try adapter.exportRows(farmID, context)
            counts[adapter.name] = rows.count
            for row in rows {
                let bytes = try ESheepCloudCanonicalCodec.encode(row)
                guard bytes.count + 2 <= ESheepCloudCheckpointGzip.limit else { throw ESheepCloudCheckpointError.sizeLimit }
                if bufferBytes + bytes.count > 1_024 * 1_024 { try flush() }
                businessHasher.update(data: bytes)
                businessHasher.update(data: Data([10]))
                buffer.append(row)
                bufferBytes += bytes.count + 1
            }
        }
        try flush()
        let manifest = ESheepCloudCheckpointManifest(formatVersion: 1, minimumClientCapability: 1,
            checkpointID: id, farmID: farmID, farmGeneration: generation, boundaryEventSequence: head,
            boundaryEventDigest: receipts.first?.eventDigest ?? String(repeating: "0", count: 64),
            receiptChainDigest: state.projectionDigest,
            businessDigest: businessHasher.finalize().map { String(format: "%02x", $0) }.joined(),
            modelCounts: counts, chunks: chunks)
        try manifest.validate()
        try ESheepCloudCanonicalCodec.encode(manifest).write(to: directory.appending(path: "manifest.json"), options: .atomic)
        return manifest
    }
}
