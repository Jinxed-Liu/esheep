import Foundation
import zlib

/// Reads OOXML ZIP packages without extracting paths to the filesystem.
/// Central-directory sizes are checked before allocation, then verified against
/// local headers, decompression output, and CRC. Data-descriptor ZIPs are supported.
enum InsightDocumentArchive {
    static func decode(_ source: Data, maximumExpandedBytes: Int = 50 * 1_024 * 1_024) throws -> [String: Data] {
        let archive = Data(source)
        guard archive.count >= 22, maximumExpandedBytes > 0 else { throw InsightDocumentError.malformed("ZIP 文件不完整。") }
        let searchStart = max(0, archive.count - 65_557)
        let endOffset = stride(from: archive.count - 22, through: searchStart, by: -1).first { offset in
            archive.documentUInt32(at: offset) == 0x06054b50 &&
                offset + 22 + Int(archive.documentUInt16(at: offset + 20)) == archive.count
        }
        guard let endOffset else { throw InsightDocumentError.malformed("缺少 ZIP 中央目录；请重新导出文件。") }
        let disk = archive.documentUInt16(at: endOffset + 4)
        let directoryDisk = archive.documentUInt16(at: endOffset + 6)
        let diskEntries = archive.documentUInt16(at: endOffset + 8)
        let entryCount = archive.documentUInt16(at: endOffset + 10)
        let directorySize = Int(archive.documentUInt32(at: endOffset + 12))
        let directoryOffset = Int(archive.documentUInt32(at: endOffset + 16))
        guard disk == 0, directoryDisk == 0, diskEntries == entryCount,
              entryCount != UInt16.max, entryCount > 0, entryCount <= 10_000,
              directorySize != Int(UInt32.max), directoryOffset != Int(UInt32.max),
              directoryOffset <= endOffset, directorySize == endOffset - directoryOffset else {
            throw InsightDocumentError.malformed("不支持多卷、ZIP64 或异常 ZIP 目录；请另存为普通 DOCX/XLSX。")
        }
        var result: [String: Data] = [:]
        var names = Set<String>()
        var spans: [Range<Int>] = []
        var cursor = directoryOffset
        var expandedTotal = 0
        for _ in 0..<Int(entryCount) {
            try Task.checkCancellation()
            guard cursor <= endOffset - 46, archive.documentUInt32(at: cursor) == 0x02014b50 else {
                throw InsightDocumentError.malformed("ZIP 中央目录已损坏。")
            }
            let flags = archive.documentUInt16(at: cursor + 8)
            let method = archive.documentUInt16(at: cursor + 10)
            let checksum = archive.documentUInt32(at: cursor + 16)
            let compressedSize = Int(archive.documentUInt32(at: cursor + 20))
            let expandedSize = Int(archive.documentUInt32(at: cursor + 24))
            let nameLength = Int(archive.documentUInt16(at: cursor + 28))
            let extraLength = Int(archive.documentUInt16(at: cursor + 30))
            let commentLength = Int(archive.documentUInt16(at: cursor + 32))
            let startDisk = archive.documentUInt16(at: cursor + 34)
            let localOffset = Int(archive.documentUInt32(at: cursor + 42))
            let next = cursor + 46 + nameLength + extraLength + commentLength
            guard next <= endOffset, nameLength > 0, startDisk == 0,
                  compressedSize != Int(UInt32.max), expandedSize != Int(UInt32.max), localOffset != Int(UInt32.max) else {
                throw InsightDocumentError.malformed("ZIP 条目已损坏或使用 ZIP64。")
            }
            guard flags & 0x2041 == 0 else { throw InsightDocumentError.encrypted }
            guard method == 0 || method == 8 else { throw InsightDocumentError.malformed("不支持此压缩方式；请重新另存为 DOCX/XLSX。") }
            guard expandedSize <= maximumExpandedBytes - expandedTotal else { throw InsightDocumentError.expandedArchiveTooLarge }
            expandedTotal += expandedSize
            let nameData = archive.subdata(in: (cursor + 46)..<(cursor + 46 + nameLength))
            guard let name = String(data: nameData, encoding: .utf8), isSafePath(name),
                  names.insert(name).inserted else { throw InsightDocumentError.unsafeArchive }
            guard localOffset <= directoryOffset - 30, archive.documentUInt32(at: localOffset) == 0x04034b50 else {
                throw InsightDocumentError.malformed("ZIP 条目定位无效。")
            }
            let localFlags = archive.documentUInt16(at: localOffset + 6)
            let localMethod = archive.documentUInt16(at: localOffset + 8)
            let localNameLength = Int(archive.documentUInt16(at: localOffset + 26))
            let localExtraLength = Int(archive.documentUInt16(at: localOffset + 28))
            let contentOffset = localOffset + 30 + localNameLength + localExtraLength
            guard localFlags == flags, localMethod == method, contentOffset <= directoryOffset,
                  compressedSize <= directoryOffset - contentOffset,
                  localNameLength == nameLength,
                  archive.subdata(in: (localOffset + 30)..<(localOffset + 30 + localNameLength)) == nameData else {
                throw InsightDocumentError.malformed("ZIP 本地条目与目录不一致。")
            }
            if flags & 0x08 == 0 {
                guard archive.documentUInt32(at: localOffset + 14) == checksum,
                      archive.documentUInt32(at: localOffset + 18) == UInt32(compressedSize),
                      archive.documentUInt32(at: localOffset + 22) == UInt32(expandedSize) else {
                    throw InsightDocumentError.malformed("ZIP 条目大小或校验值不一致。")
                }
            }
            let span = localOffset..<(contentOffset + compressedSize)
            guard !spans.contains(where: { $0.overlaps(span) }) else { throw InsightDocumentError.malformed("ZIP 条目重叠。") }
            spans.append(span)
            let compressed = archive.subdata(in: contentOffset..<(contentOffset + compressedSize))
            let contents: Data
            if method == 0 {
                guard compressedSize == expandedSize else { throw InsightDocumentError.malformed("ZIP 存储条目的大小不一致。") }
                contents = compressed
            } else {
                contents = try inflate(compressed, expectedSize: expandedSize)
            }
            let crc = contents.withUnsafeBytes { bytes in
                crc32(0, bytes.bindMemory(to: Bytef.self).baseAddress, uInt(contents.count))
            }
            guard UInt32(crc) == checksum else { throw InsightDocumentError.malformed("ZIP 内容校验失败；文件可能已损坏。") }
            if !name.hasSuffix("/") { result[name] = contents }
            cursor = next
        }
        guard cursor == endOffset else { throw InsightDocumentError.malformed("ZIP 目录含未识别内容。") }
        return result
    }

    private static func isSafePath(_ name: String) -> Bool {
        !name.hasPrefix("/") && !name.contains("\\") && !name.contains(":") &&
            !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) &&
            !name.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." })
    }

    private static func inflate(_ inputData: Data, expectedSize: Int) throws -> Data {
        var stream = z_stream()
        var output = Data(count: expectedSize + 1)
        let status = inputData.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { destination -> Int32 in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(inputData.count)
                stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(expectedSize + 1)
                guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                    return Z_MEM_ERROR
                }
                defer { inflateEnd(&stream) }
                return zlib.inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END, Int(stream.total_out) == expectedSize,
              Int(stream.total_in) == inputData.count else {
            throw InsightDocumentError.malformed("ZIP 解压失败或实际展开大小不符。")
        }
        output.count = expectedSize
        return output
    }
}

private extension Data {
    func documentUInt16(at offset: Int) -> UInt16 {
        withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self).littleEndian }
    }
    func documentUInt32(at offset: Int) -> UInt32 {
        withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian }
    }
}
