import CloudKit
import Foundation

struct CloudZoneChangePage: @unchecked Sendable {
    let index: Int
    let records: [CKRecord]
    let deletions: [CKDatabase.RecordZoneChange.Deletion]
    let changeToken: CKServerChangeToken?
    let moreComing: Bool
}

private struct CloudZoneFetchedPage: @unchecked Sendable {
    let records: [CKRecord]
    let deletions: [CKDatabase.RecordZoneChange.Deletion]
    let changeToken: CKServerChangeToken
    let moreComing: Bool
}

actor CloudZoneChangeFetcher {
    private let database: CKDatabase
    private static let maximumPageAttempts = 8

    init(database: CKDatabase) {
        self.database = database
    }

    func fetchAll(zoneID: CKRecordZone.ID) -> AsyncThrowingStream<CloudZoneChangePage, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var token: CKServerChangeToken?
                    var pageIndex = 0
                    repeat {
                        try Task.checkCancellation()
                        let result = try await fetchPage(zoneID: zoneID, token: token)
                        pageIndex += 1
                        continuation.yield(CloudZoneChangePage(
                            index: pageIndex,
                            records: result.records,
                            deletions: result.deletions,
                            changeToken: result.changeToken,
                            moreComing: result.moreComing
                        ))
                        token = result.changeToken
                        if !result.moreComing { break }
                    } while true
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private func fetchPage(
        zoneID: CKRecordZone.ID,
        token: CKServerChangeToken?
    ) async throws -> CloudZoneFetchedPage {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                let result = try await database.recordZoneChanges(
                    inZoneWith: zoneID,
                    since: token,
                    desiredKeys: nil,
                    resultsLimit: 200
                )
                var records: [CKRecord] = []
                var firstFailure: Error?
                for (_, value) in result.modificationResultsByID {
                    do {
                        records.append(try value.get().record)
                    } catch {
                        firstFailure = firstFailure ?? error
                    }
                }
                if let firstFailure { throw firstFailure }
                return CloudZoneFetchedPage(
                    records: records,
                    deletions: result.deletions,
                    changeToken: result.changeToken,
                    moreComing: result.moreComing
                )
            } catch {
                attempt += 1
                guard attempt < Self.maximumPageAttempts,
                      let delay = Self.retryDelay(for: error, attempt: attempt) else {
                    throw error
                }
                try await Task.sleep(for: .seconds(delay))
            }
        }
    }

    static func retryDelay(for error: Error, attempt: Int) -> TimeInterval? {
        let nsError = error as NSError
        guard nsError.domain == CKErrorDomain,
              let code = CKError.Code(rawValue: nsError.code),
              [
                  .networkFailure,
                  .networkUnavailable,
                  .serviceUnavailable,
                  .requestRateLimited,
                  .zoneBusy,
              ].contains(code) else {
            return nil
        }
        if let serverDelay = nsError.userInfo[CKErrorRetryAfterKey] as? TimeInterval {
            return min(max(serverDelay, 0.25), 60)
        }
        let exponent = min(max(attempt - 1, 0), 4)
        return min(pow(2, Double(exponent)), 16)
    }
}
