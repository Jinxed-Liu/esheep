import StoreKit
import SwiftUI

struct SubscriptionSettingsView: View {
    @Environment(SubscriptionService.self) private var subscription
    @Environment(\.openURL) private var openURL

    let account: AccountProfile

    var body: some View {
        List {
            Section("当前权益") {
                LabeledContent("方案", value: subscription.entitlement.tier == .farmPro ? "场主专业版" : "基础版")
                LabeledContent("状态", value: statusText)
                if let validUntil = subscription.entitlement.validUntil {
                    LabeledContent("有效期", value: validUntil.formatted(date: .abbreviated, time: .omitted))
                }
                Text("订阅按 eSheep+ 账户生效，覆盖该账户拥有的全部牧场。员工的查看、称重、投喂、治疗等基础生产操作不需要单独购买。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("场主专业版") {
                if subscription.products.isEmpty {
                    ContentUnavailableView(
                        "订阅商品暂不可用",
                        systemImage: "cart.badge.questionmark",
                        description: Text("请检查网络和 App Store Connect 商品配置后重试。")
                    )
                } else {
                    ForEach(subscription.products, id: \.id) { product in
                        Button {
                            Task { await subscription.purchase(product) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(product.displayName)
                                    Text(product.description)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(product.displayPrice)
                                    .fontWeight(.semibold)
                            }
                        }
                        .disabled(subscription.isLoading)
                    }
                }
            }

            Section("购买管理") {
                Button("恢复购买") {
                    Task { await subscription.restorePurchases() }
                }
                .disabled(subscription.isLoading)
                Button("管理订阅") {
                    openURL(URL(string: "https://apps.apple.com/account/subscriptions")!)
                }
                if subscription.entitlement.state == .unboundTransaction {
                    Text("发现没有账户绑定标识的旧交易。为防止串用，该交易不会自动授予当前账户；请通过支持渠道核验。")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            if let message = subscription.lastMessage {
                Section { Text(LocalizedStringKey(message)).foregroundStyle(.secondary) }
            }
            if let error = subscription.lastErrorMessage {
                Section { Text(LocalizedStringKey(error)).foregroundStyle(.red) }
            }
        }
        .navigationTitle("订阅与购买")
        .refreshable { await subscription.refresh() }
        .task(id: account.effectiveAccountID) {
            await subscription.activate(accountID: account.effectiveAccountID)
        }
        .overlay {
            if subscription.isLoading { ProgressView() }
        }
    }

    private var statusText: String {
        switch subscription.entitlement.state {
        case .basic: "未订阅"
        case .active: "有效"
        case .gracePeriod: "宽限期"
        case .billingRetry: "续费重试中"
        case .expired: "已到期"
        case .revoked: "已退款或撤销"
        case .pending: "等待确认"
        case .unboundTransaction: "需要核验旧交易"
        }
    }
}

