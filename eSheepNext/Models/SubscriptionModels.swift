import Foundation

enum SubscriptionProductID {
    static let monthly = "com.sheepfarm.ios.pro.monthly"
    static let yearly = "com.sheepfarm.ios.pro.yearly"
    static let all: Set<String> = [monthly, yearly]
}

enum SubscriptionTier: String, Codable, Sendable {
    case basic
    case farmPro
}

enum SubscriptionAccessState: String, Codable, Sendable {
    case basic
    case active
    case gracePeriod
    case billingRetry
    case expired
    case revoked
    case pending
    case unboundTransaction
}

struct AccountEntitlement: Equatable, Sendable {
    let accountID: UUID?
    let tier: SubscriptionTier
    let state: SubscriptionAccessState
    let productID: String?
    let validUntil: Date?

    static func basic(accountID: UUID? = nil, state: SubscriptionAccessState = .basic) -> AccountEntitlement {
        AccountEntitlement(accountID: accountID, tier: .basic, state: state, productID: nil, validUntil: nil)
    }

    var allowsOwnerProFeatures: Bool {
        tier == .farmPro && [.active, .gracePeriod, .billingRetry].contains(state)
    }
}

struct FarmPlanStatus: Codable, Equatable, Sendable {
    let farmID: UUID
    let tier: SubscriptionTier
    let validUntil: Date?
    let graceUntil: Date?
    let issuedAt: Date
    let ownerAccountID: UUID
    let issuerDeviceID: UUID
    let signature: Data
}

enum SubscriptionCapabilityPolicy {
    static func canCreateFarm(existingOwnedFarmCount: Int, entitlement: AccountEntitlement) -> Bool {
        existingOwnedFarmCount == 0 || entitlement.allowsOwnerProFeatures
    }

    static func canCreateAdditionalFarm(role: FarmRole, entitlement: AccountEntitlement) -> Bool {
        role == .owner && entitlement.allowsOwnerProFeatures
    }

    static func canRecordProduction(role: FarmRole, entitlement: AccountEntitlement) -> Bool {
        CapabilitySet(role: role).allows(.recordProduction)
    }
}

enum FarmCreationEntitlementError: LocalizedError {
    case additionalFarmRequiresFarmPro

    var errorDescription: String? {
        switch self {
        case .additionalFarmRequiresFarmPro:
            "首个自有牧场可免费使用；创建额外牧场需要有效的牧场 Pro 订阅。已有牧场、受邀牧场和生产记录不会被锁定。"
        }
    }
}
