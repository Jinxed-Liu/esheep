import CloudKit
import XCTest
@testable import eSheepNext

final class OwnerFarmRecoveryCoordinatorTests: XCTestCase {
    func testActiveCacheIsKeptOnlyWhenReadyV2IdentityMatchesExactly() {
        let identity = makeIdentity()

        XCTAssertEqual(
            OwnerFarmRecoveryDecision.evaluate(
                bindingState: .active,
                local: identity,
                readyCloudV2: identity
            ),
            .keepCurrentCache
        )

        let changedDigest = OwnerFarmRecoveryBaselineIdentity(
            digest: "different",
            entityCount: identity.entityCount,
            photoCount: identity.photoCount,
            version: identity.version,
            cutoffAtMilliseconds: identity.cutoffAtMilliseconds
        )
        XCTAssertEqual(
            OwnerFarmRecoveryDecision.evaluate(
                bindingState: .active,
                local: identity,
                readyCloudV2: changedDigest
            ),
            .stageFullRebuild
        )
        XCTAssertEqual(
            OwnerFarmRecoveryDecision.evaluate(
                bindingState: .active,
                local: nil,
                readyCloudV2: identity
            ),
            .stageFullRebuild
        )
    }

    func testActiveCacheWaitsUntilCloudRootHasCompleteReadyV2Identity() {
        XCTAssertEqual(
            OwnerFarmRecoveryDecision.evaluate(
                bindingState: .active,
                local: makeIdentity(),
                readyCloudV2: nil
            ),
            .waitForReadyCloud
        )
    }

    func testExistingRebuildLockIsNeverDowngradedByPreflight() {
        XCTAssertEqual(
            OwnerFarmRecoveryDecision.evaluate(
                bindingState: .rebuildingCache,
                local: nil,
                readyCloudV2: makeIdentity()
            ),
            .keepCurrentCache
        )
    }

    func testCloudRootParserRequiresEveryReadyV2IdentityField() {
        let farmID = UUID()
        let zoneID = CKRecordZone.ID(zoneName: CloudZoneName.forFarm(farmID), ownerName: CKCurrentUserDefaultName)
        let root = CKRecord(
            recordType: CloudRecordType.farmRoot.rawValue,
            recordID: CKRecord.ID(recordName: "root_\(farmID.uuidString.lowercased())", zoneID: zoneID)
        )
        root[CloudRecordField.bootstrapState] = "ready" as CKRecordValue
        root[CloudRecordField.bootstrapDigest] = "digest" as CKRecordValue
        root[CloudRecordField.bootstrapEntityCount] = 21_387 as CKRecordValue
        root[CloudRecordField.bootstrapPhotoCount] = 7 as CKRecordValue
        root[CloudRecordField.bootstrapVersion] = 2 as CKRecordValue

        XCTAssertNil(OwnerFarmRecoveryCoordinator.readyCloudV2Identity(from: root))

        let cutoff = Date(timeIntervalSince1970: 1_800_000_000.125)
        root[CloudRecordField.bootstrapCutoffAt] = cutoff as CKRecordValue
        XCTAssertEqual(
            OwnerFarmRecoveryCoordinator.readyCloudV2Identity(from: root),
            OwnerFarmRecoveryBaselineIdentity(
                digest: "digest",
                entityCount: 21_387,
                photoCount: 7,
                version: 2,
                cutoffAtMilliseconds: 1_800_000_000_125
            )
        )
    }

    func testCompletedRebuildBootstrapProducesTheSameRecoveryIdentity() {
        let cutoff = Date(timeIntervalSince1970: 1_800_000_000.125)
        let bootstrap = CloudRebuildBootstrapSnapshot(
            digest: "digest",
            entityCount: 21_387,
            photoCount: 7,
            version: 2,
            cutoffAt: cutoff
        )

        XCTAssertEqual(
            OwnerFarmRecoveryCoordinator.baselineIdentity(from: bootstrap),
            OwnerFarmRecoveryBaselineIdentity(
                digest: "digest",
                entityCount: 21_387,
                photoCount: 7,
                version: 2,
                cutoffAtMilliseconds: 1_800_000_000_125
            )
        )
    }

    private func makeIdentity() -> OwnerFarmRecoveryBaselineIdentity {
        OwnerFarmRecoveryBaselineIdentity(
            digest: "digest",
            entityCount: 21_387,
            photoCount: 7,
            version: 2,
            cutoffAtMilliseconds: 1_800_000_000_000
        )
    }
}
