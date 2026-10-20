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
    static func apply(_ identity: ESheepCloudFarmIdentityV2,
                      state: ESheepCloudFarmState, context: ModelContext) throws {
        try identity.validate(farmID: state.farmID, generation: state.farmGeneration)
        let farmID = state.farmID
        let generation = state.farmGeneration
        let watermark = try context.fetch(FetchDescriptor<ESheepCloudFarmIdentityState>(predicate: #Predicate {
            $0.farmID == farmID && $0.farmGeneration == generation
        })).first
        guard identity.revision >= (watermark?.revision ?? -1) else { return }
        guard let farm = try context.fetch(FetchDescriptor<FarmRecord>(predicate: #Predicate {
            $0.id == farmID && $0.deletedAt == nil
        })).first else { throw ESheepCloudMembershipError.malformedResponse }
        if identity.revision == watermark?.revision, (watermark?.name != identity.name || watermark?.latinName != identity.latinName) {
            throw ESheepCloudMembershipError.malformedResponse
        }
        if farm.name != identity.name {
            farm.name = identity.name
            farm.updatedAt = max(farm.updatedAt, .now)
        }
        if let watermark {
            if watermark.revision != identity.revision { watermark.revision = identity.revision }
            if watermark.name != identity.name { watermark.name = identity.name }
            watermark.latinName = identity.latinName
        } else {
            context.insert(ESheepCloudFarmIdentityState(farmID: farmID, farmGeneration: generation,
                name: identity.name, revision: identity.revision, latinName: identity.latinName))
        }
    }
}
