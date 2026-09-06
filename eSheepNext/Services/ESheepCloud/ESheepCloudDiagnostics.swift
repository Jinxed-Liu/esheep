import Foundation
import OSLog

/// Bounded numeric telemetry. Never emits command bodies, account identifiers,
/// sheep tags, credentials, or signed resource URLs.
enum ESheepCloudDiagnostics {
    private static let logger = Logger(subsystem: "com.sheepfarm.cloud", category: "sync-performance")
    struct Phase: Sendable {
        let name: String
        private let start = ContinuousClock.now
        init(_ name: String) { self.name = name }
        func end(items: Int = 0, fullTableReads: Int = -1) {
            let parts = start.duration(to: .now).components
            let milliseconds = Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
            logger.info("phase=\(name, privacy: .public) duration_ms=\(milliseconds) items=\(items) full_table_reads=\(fullTableReads)")
        }
    }
}
