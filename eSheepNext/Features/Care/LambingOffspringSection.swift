import SwiftData
import SwiftUI

/// Resolve a stable record ID only after navigation, from either history entry.
struct ReproductionRecordDetailEntryView: View, Equatable {
    @Environment(\.modelContext) private var context
    let account: AccountProfile
    let farm: FarmRecord
    let recordID: UUID
    @State private var record: ReproductionRecord?
    @State private var error: String?
    @State private var loaded = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.account === rhs.account && lhs.farm === rhs.farm && lhs.recordID == rhs.recordID
    }

    var body: some View {
        Group {
            if let record { ReproductionRecordDetailView(account: account, farm: farm, record: record).equatable() }
            else if loaded {
                ContentUnavailableView("繁殖记录暂不可用", systemImage: "exclamationmark.triangle",
                    description: Text(error ?? "请返回刷新事件历史后重试。"))
            } else { ProgressView("正在读取繁殖记录") }
        }
        .task(id: recordID) {
            let farmID = farm.id, targetID = recordID
            do {
                record = try context.fetch(FetchDescriptor<ReproductionRecord>(predicate: #Predicate {
                    $0.farmID == farmID && $0.id == targetID
                })).first
            } catch { self.error = error.localizedDescription }
            loaded = true
        }
    }
}

struct LambingOffspringSection: View, Equatable {
    private let accountIdentity: ObjectIdentifier
    private let farmIdentity: ObjectIdentifier
    @Environment(\.modelContext) private var modelContext
    let account: AccountProfile
    let farm: FarmRecord
    let recordID: UUID
    let revision: Int
    @State private var snapshot: LambingDetailSnapshot?
    @State private var error: String?
    @State private var reloadID = 0

    init(account: AccountProfile, farm: FarmRecord, recordID: UUID, revision: Int) {
        self.account = account; self.farm = farm
        self.recordID = recordID; self.revision = revision
        accountIdentity = ObjectIdentifier(account); farmIdentity = ObjectIdentifier(farm)
    }

    // The section's link can lead back through a sheep profile to reproduction
    // history. Bound comparisons here instead of traversing that reference graph.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.accountIdentity == rhs.accountIdentity && lhs.farmIdentity == rhs.farmIdentity &&
            lhs.recordID == rhs.recordID && lhs.revision == rhs.revision
    }

    private var request: String { "\(recordID)-\(revision)-\(reloadID)" }

    var body: some View {
        Section("本次羔羊") {
            if let snapshot {
                ForEach(snapshot.children) { child in
                    if let sheepID = child.sheepID {
                        NavigationLink {
                            LambingChildProfileDestination(account: account, farm: farm, sheepID: sheepID)
                        } label: { childLabel(child) }
                        .accessibilityIdentifier("lambing-child-" + child.earTag)
                    } else { childLabel(child) }
                }
                if snapshot.missingCount > 0 {
                    Text("另有 \(snapshot.missingCount) 只羔羊缺少逐只明细。")
                        .foregroundStyle(.orange)
                }
                if snapshot.countMismatch {
                    Text("逐只明细与产羔汇总不一致，请核对原始记录。")
                        .foregroundStyle(.orange)
                }
                if snapshot.children.isEmpty && snapshot.missingCount == 0 { Text("未记录羔羊明细") }
                Text("当前状态读取于 \(snapshot.readAt.formatted(date: .numeric, time: .shortened))")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if error == nil { ProgressView("正在读取羔羊明细") }
            if let error {
                Text(error).foregroundStyle(.orange)
                Button("重新读取") { reloadID &+= 1 }
            }
        }
        .task(id: request) {
            do {
                let result = try await LambingDetailSnapshotActor(container: modelContext.container)
                    .load(farmID: farm.id, recordID: recordID)
                try Task.checkCancellation()
                snapshot = result
                error = result == nil ? "产羔记录暂不可用" : nil
            } catch is CancellationError { return }
            catch { self.error = error.localizedDescription }
        }
    }

    private func childLabel(_ child: LambingChildSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(verbatim: child.earTag).font(.headline)
                Spacer()
                Text(child.isStillborn ? "死胎" : "活产").foregroundStyle(.secondary)
            }
            Text(verbatim: child.sex + " · " + (child.birthWeight.map { "初生重 \(WeightPrecision.displayText($0)) 千克" } ?? "初生重未记录"))
                .font(.subheadline)
            if !child.recordedEarTag.isEmpty && child.recordedEarTag != child.earTag {
                Text("记录时耳号：\(child.recordedEarTag)").font(.footnote).foregroundStyle(.secondary)
            }
            if let laterWeight = child.laterWeight, let weighedAt = child.weighedAt {
                Text("后续称重：\(WeightPrecision.displayText(laterWeight)) 千克 · \(weighedAt.formatted(date: .numeric, time: .omitted))")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if !child.isStillborn {
                Text(verbatim: "当前：" + child.currentState + (child.currentPen.map { " · " + $0 } ?? "") +
                    (child.removedAt.map { " · " + $0.formatted(date: .numeric, time: .omitted) } ?? ""))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

private struct LambingChildProfileDestination: View, Equatable {
    let account: AccountProfile
    let farm: FarmRecord
    let sheepID: UUID
    private let accountIdentity: ObjectIdentifier
    private let farmIdentity: ObjectIdentifier

    init(account: AccountProfile, farm: FarmRecord, sheepID: UUID) {
        self.account = account; self.farm = farm; self.sheepID = sheepID
        accountIdentity = ObjectIdentifier(account); farmIdentity = ObjectIdentifier(farm)
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.accountIdentity == rhs.accountIdentity && lhs.farmIdentity == rhs.farmIdentity && lhs.sheepID == rhs.sheepID
    }

    var body: some View {
        // A sheep profile can navigate back to this lambing detail. Erase only
        // this recursive screen boundary so AttributeGraph does not expand the
        // complete profile -> evidence -> lambing -> profile type graph.
        AnyView(SheepDetailEntryView(account: account, farm: farm, sheepID: sheepID))
    }
}

struct ReproductionAssociationLabel: View {
    @Environment(\.modelContext) private var context
    let farmID: UUID
    let recordID: UUID
    @State private var date: Date?
    @State private var unavailable = false
    var body: some View {
        LabeledContent("关联配种") {
            if let date { Text(date, format: .dateTime.year().month().day()) }
            else { Text(unavailable ? "关联记录暂不可用" : "正在读取") }
        }
        .task(id: recordID) {
            do {
                let farmID = farmID, recordID = recordID
                date = try context.fetch(FetchDescriptor<ReproductionRecord>(predicate: #Predicate {
                    $0.farmID == farmID && $0.id == recordID && $0.deletedAt == nil
                })).first?.occurredAt
                unavailable = date == nil
            } catch { unavailable = true }
        }
    }
}
