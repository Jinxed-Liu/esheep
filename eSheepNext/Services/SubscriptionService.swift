import Observation
import StoreKit

enum SubscriptionStoreError: LocalizedError {
    case verificationFailed
    case accountMismatch
    case productUnavailable

    var errorDescription: String? {
        switch self {
        case .verificationFailed: "App Store 交易验证失败。"
        case .accountMismatch: "该订阅不属于当前 eSheep+ 账户，不能自动绑定。"
        case .productUnavailable: "订阅商品暂时不可用，请稍后重试。"
        }
    }
}

@MainActor
@Observable
final class SubscriptionService {
    private(set) var products: [Product] = []
    private(set) var entitlement: AccountEntitlement = .basic()
    private(set) var isLoading = false
    private(set) var lastMessage: String?
    private(set) var lastErrorMessage: String?

    private var activeAccountID: UUID?
    private var updatesTask: Task<Void, Never>?

    func activate(accountID: UUID) async {
        activeAccountID = accountID
        startTransactionListenerIfNeeded()
        await refresh()
    }

    func reset() {
        activeAccountID = nil
        entitlement = .basic()
        lastMessage = nil
        lastErrorMessage = nil
    }

    func refresh() async {
        guard let activeAccountID else {
            reset()
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            products = try await Product.products(for: Array(SubscriptionProductID.all))
                .sorted { $0.price < $1.price }
            entitlement = try await currentEntitlement(accountID: activeAccountID)
            lastErrorMessage = nil
        } catch {
            entitlement = .basic(accountID: activeAccountID)
            lastErrorMessage = error.localizedDescription
        }
    }

    func purchase(_ product: Product) async {
        guard let activeAccountID else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            guard SubscriptionProductID.all.contains(product.id) else {
                throw SubscriptionStoreError.productUnavailable
            }
            switch try await product.purchase(options: [.appAccountToken(activeAccountID)]) {
            case .success(let verification):
                let transaction = try Self.verified(verification)
                guard transaction.appAccountToken == activeAccountID else {
                    throw SubscriptionStoreError.accountMismatch
                }
                await transaction.finish()
                entitlement = try await currentEntitlement(accountID: activeAccountID)
                lastMessage = "订阅已生效。"
                lastErrorMessage = nil
            case .pending:
                entitlement = .basic(accountID: activeAccountID, state: .pending)
                lastMessage = "购买等待 App Store 确认。"
            case .userCancelled:
                lastMessage = nil
            @unknown default:
                lastErrorMessage = "App Store 返回了未知购买状态。"
            }
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func restorePurchases() async {
        guard activeAccountID != nil else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            try await AppStore.sync()
            await refresh()
            lastMessage = entitlement.allowsOwnerProFeatures ? "购买已恢复。" : "没有找到属于当前账户的有效订阅。"
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func currentEntitlement(accountID: UUID) async throws -> AccountEntitlement {
        var foundUnboundTransaction = false
        var best: AccountEntitlement?

        for product in products {
            guard let subscription = product.subscription else { continue }
            for status in try await subscription.status {
                let transaction = try Self.verified(status.transaction)
                guard SubscriptionProductID.all.contains(transaction.productID) else { continue }
                guard let appAccountToken = transaction.appAccountToken else {
                    foundUnboundTransaction = true
                    continue
                }
                guard appAccountToken == accountID else { continue }

                let state: SubscriptionAccessState
                switch status.state {
                case .subscribed: state = .active
                case .inGracePeriod: state = .gracePeriod
                case .inBillingRetryPeriod: state = .billingRetry
                case .expired: state = .expired
                case .revoked: state = .revoked
                default: state = .expired
                }
                let candidate = AccountEntitlement(
                    accountID: accountID,
                    tier: [.active, .gracePeriod, .billingRetry].contains(state) ? .farmPro : .basic,
                    state: state,
                    productID: transaction.productID,
                    validUntil: transaction.expirationDate
                )
                if best == nil || Self.priority(candidate.state) > Self.priority(best!.state) {
                    best = candidate
                }
            }
        }
        return best ?? .basic(accountID: accountID, state: foundUnboundTransaction ? .unboundTransaction : .basic)
    }

    private func startTransactionListenerIfNeeded() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self, !Task.isCancelled else { return }
                do {
                    let transaction = try Self.verified(result)
                    await transaction.finish()
                    await self.refresh()
                } catch {
                    self.lastErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private static func verified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let value): value
        case .unverified: throw SubscriptionStoreError.verificationFailed
        }
    }

    private static func priority(_ state: SubscriptionAccessState) -> Int {
        switch state {
        case .active: 6
        case .gracePeriod: 5
        case .billingRetry: 4
        case .pending: 3
        case .expired: 2
        case .revoked: 1
        case .basic, .unboundTransaction: 0
        }
    }
}
