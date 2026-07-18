import CloudKit
import Foundation

struct CloudZoneChangePage: @unchecked Sendable {
    let index: Int
    let records: [CKRecord]
    let deletions: [CKDatabase.RecordZoneChange.Deletion]
    let changeToken: CKServerChangeToken?
    let moreComing: Bool
}

actor CloudZoneChangeFetcher {
    private let database: CKDatabase

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
                        pageIndex += 1
                        continuation.yield(CloudZoneChangePage(
                            index: pageIndex,
                            records: records,
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
}

