#if DEBUG
import Foundation
import SwiftUI

/// Sidecar required before opening a pre-copied store in the explicit offline
/// launch path. Production bootstrap is skipped by --design-acceptance.
struct DevelopmentRealFarmAcceptanceMarker: Codable {
    let fixtureID: UUID
    let farmID: UUID
    let sheepRecordCount: Int
    let offlineOnly: Bool
}

struct DevelopmentRealFarmAcceptanceView: View {
    let account: AccountProfile
    let farm: FarmRecord
    @State private var analytics = FarmDeepAnalyticsStore()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("真实资料的本机隔离副本").font(.headline)
                    Text("使用独立数据库，不启动云端连接。此处显示快照保留的牧场名称与历史资料。")
                    Text(farm.name)
                }
                NavigationLink("羊只列表与详情") { HerdManagementView(account: account, farm: farm) }
                NavigationLink("圈舍与成员") { PenManagementView(account: account, farm: farm) }
                NavigationLink("繁殖分析") { ReproductionAnalysisHomeView(account: account, farm: farm, dataStore: analytics) }
                NavigationLink("繁殖资料待核实") { ReproductionReviewCenter(account: account, farm: farm) }
                NavigationLink("待办与异常") { FarmOperationalAlertCenterView(account: account, farm: farm) }
            }
            .navigationTitle("真实副本验收")
        }
    }
}
#endif
