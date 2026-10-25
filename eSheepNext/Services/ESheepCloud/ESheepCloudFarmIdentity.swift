import Foundation
import SwiftData

/// Live, authenticated identity metadata; independent of immutable business snapshots.
struct ESheepCloudFarmIdentityV2: Codable, Sendable, Equatable {
    let farmID: UUID
    let farmGeneration: Int
    let name: String
    let revision: Int64
    var latinName: String? = nil

    func validate(farmID: UUID, generation: Int) throws {
        guard self.farmID == farmID, farmGeneration == generation, revision >= 0,
              Self.validName(name), latinName == nil || Self.validName(latinName!) else {
            throw ESheepCloudMembershipError.malformedResponse
        }
    }

    static func validName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            name.unicodeScalars.count <= 80 &&
            !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

/// The watermark and display name commit together, so delayed responses and
/// app restarts cannot put an older name back over a newer acknowledged rename.
enum ESheepCloudFarmIdentityProjection {
    /// A V18 client could acknowledge revision N while discarding its Latin
    /// name. V19 then mistook the migrated nil for a conflicting known value.
    /// Only that unverified, same-revision enrichment is compatible; a known
    /// nil, a different non-nil value, or a changed Chinese name still fails.
    static func isLegacyEnrichment(_ identity: ESheepCloudFarmIdentityV2,
                                   watermark: ESheepCloudFarmIdentityState) -> Bool {
        !watermark.latinNameVerified && watermark.latinName == nil && identity.latinName != nil &&
            watermark.farmID == identity.farmID && watermark.farmGeneration == identity.farmGeneration &&
            watermark.revision == identity.revision && watermark.name == identity.name
    }

    static func canRecoverLegacyHold(_ identity: ESheepCloudFarmIdentityV2?,
                                     state: ESheepCloudFarmState, context: ModelContext) throws -> Bool {
        guard let identity, state.activityState == .integrityHold, state.integrityState == .failed,
              state.lastAppliedEventSequence == state.lastVerifiedEventSequence else { return false }
        let farmID = state.farmID, generation = state.farmGeneration
        guard let watermark = try context.fetch(FetchDescriptor<ESheepCloudFarmIdentityState>(predicate: #Predicate {
            $0.farmID == farmID && $0.farmGeneration == generation
        })).first else { return false }
        return !watermark.legacyIntegrityRecoveryBlocked && isLegacyEnrichment(identity, watermark: watermark)
    }

    /// A failure observed by this fixed client cannot be the old V19 bug.
    /// Retain the hold even if its next response also enriches legacy metadata.
    static func blockLegacyHoldRecovery(farmID: UUID, generation: Int, context: ModelContext) throws {
        for watermark in try context.fetch(FetchDescriptor<ESheepCloudFarmIdentityState>(predicate: #Predicate {
            $0.farmID == farmID && $0.farmGeneration == generation
        })) {
            watermark.legacyIntegrityRecoveryBlocked = true
        }
    }

    static func apply(_ identity: ESheepCloudFarmIdentityV2,
                      state: ESheepCloudFarmState, context: ModelContext,
                      allowLegacyHoldEnrichment: Bool = false) throws {
        try identity.validate(farmID: state.farmID, generation: state.farmGeneration)
        // Membership discovery and name settings can run before event pull.
        // Keep the legacy marker until the event page can validate the prefix
        // and commit the enrichment together with recovery of the held state.
        if !allowLegacyHoldEnrichment,
           try canRecoverLegacyHold(identity, state: state, context: context) { return }
        let farmID = state.farmID
        let generation = state.farmGeneration
        let watermark = try context.fetch(FetchDescriptor<ESheepCloudFarmIdentityState>(predicate: #Predicate {
            $0.farmID == farmID && $0.farmGeneration == generation
        })).first
        guard identity.revision >= (watermark?.revision ?? -1) else { return }
        guard let farm = try context.fetch(FetchDescriptor<FarmRecord>(predicate: #Predicate {
            $0.id == farmID && $0.deletedAt == nil
        })).first else { throw ESheepCloudMembershipError.malformedResponse }
        if let watermark, identity.revision == watermark.revision {
            guard watermark.name == identity.name,
                  watermark.latinName == identity.latinName || isLegacyEnrichment(identity, watermark: watermark) else {
                throw ESheepCloudMembershipError.malformedResponse
            }
        }
        if farm.name != identity.name {
            farm.name = identity.name
            farm.updatedAt = max(farm.updatedAt, .now)
        }
        if let watermark {
            if watermark.revision != identity.revision { watermark.revision = identity.revision }
            if watermark.name != identity.name { watermark.name = identity.name }
            watermark.latinName = identity.latinName
            watermark.latinNameVerified = true
        } else {
            context.insert(ESheepCloudFarmIdentityState(farmID: farmID, farmGeneration: generation,
                name: identity.name, revision: identity.revision, latinName: identity.latinName))
        }
    }
}
