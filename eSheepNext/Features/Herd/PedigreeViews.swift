import SwiftData
import SwiftUI

private enum PedigreePaternalSelection: String, CaseIterable, Identifiable {
    case unknown
    case breedingRam
    case semenDonor

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .unknown: "未知"
        case .breedingRam: "本场种公羊"
        case .semenDonor: "冻精供体"
        }
    }
}

struct SheepPedigreeView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SheepRecord.earTag) private var sheep: [SheepRecord]
    @Query(sort: \PenRecord.name) private var pens: [PenRecord]
    @Query(sort: \SemenDonorRecord.name) private var donors: [SemenDonorRecord]
    @Query(sort: \PedigreeChangeRecord.occurredAt, order: .reverse) private var audits: [PedigreeChangeRecord]

    let account: AccountProfile
    let farm: FarmRecord
    let sheepID: UUID

    @State private var editing = false
    @State private var errorMessage: String?
    private let service = FarmCommandService()

    private var farmSheep: [SheepRecord] { sheep.filter { $0.farmID == farm.id && $0.deletedAt == nil } }
    private var record: SheepRecord? { farmSheep.first { $0.id == sheepID } }
    private var byID: [UUID: SheepRecord] { Dictionary(uniqueKeysWithValues: farmSheep.map { ($0.id, $0) }) }
    private var penNames: [UUID: String] { Dictionary(uniqueKeysWithValues: pens.filter { $0.farmID == farm.id }.map { ($0.id, $0.name) }) }
    private var donor: SemenDonorRecord? { guard let id = record?.semenDonorID else { return nil }; return donors.first { $0.id == id && $0.farmID == farm.id } }
    private var canEdit: Bool { CapabilitySet(role: farm.role).allows(.editHistoricalFacts) }

    var body: some View {
        Group {
            if let record {
                List {
                    Section("父母") {
                        pedigreeLink(label: "母本", relation: record.damProvenance, sheep: record.damID.flatMap { byID[$0] })
                        if let donor {
                            VStack(alignment: .leading, spacing: 4) {
                                LabeledContent("父本来源", value: "冻精供体")
                                Text(donorTitle(donor)).font(.footnote).foregroundStyle(.secondary)
                                if let sireID = record.sireID, let sire = byID[sireID] {
                                    pedigreeLink(label: "关联种公羊", relation: record.sireProvenance, sheep: sire)
                                }
                            }
                        } else {
                            pedigreeLink(label: "父本", relation: record.sireProvenance, sheep: record.sireID.flatMap { byID[$0] })
                        }
                    }

                    ancestorSection(record)
                    relationshipSection("同母羊", records: siblings(of: record, keyPath: \.damID))
                    relationshipSection("同父羊", records: paternalSiblings(of: record))
                    relationshipSection("直接后代", records: farmSheep.filter { $0.damID == record.id || $0.sireID == record.id })

                    if record.sex == .ram {
                        Section("种公羊资格") {
                            Toggle("纳入种公羊父本候选", isOn: Binding(
                                get: { record.isBreedingRam },
                                set: { updateBreedingRam(record, active: $0) }
                            ))
                            .disabled(!canEdit)
                            Text("只有明确标记的种公羊，才会参与同舍 150 天父本候选推算；普通公羊不会参与。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    let recordAudits = audits.filter { $0.farmID == farm.id && $0.sheepID == record.id }
                    if !recordAudits.isEmpty {
                        Section("变更审计") {
                            ForEach(recordAudits, id: \.id) { audit in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(audit.reason)
                                    Text(audit.occurredAt, format: .dateTime.year().month().day().hour().minute())
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .navigationTitle("系谱 · \(record.earTag)")
                .toolbar {
                    Button("编辑") { editing = true }
                        .disabled(!canEdit)
                }
                .sheet(isPresented: $editing) {
                    NavigationStack {
                        SheepPedigreeEditorView(account: account, farm: farm, sheepID: record.id)
                    }
                }
            } else {
                ContentUnavailableView("羊只档案不存在", systemImage: "exclamationmark.triangle")
            }
        }
        .recordErrorAlert($errorMessage)
    }

    @ViewBuilder
    private func pedigreeLink(label: String, relation: PedigreeRelationSource?, sheep related: SheepRecord?) -> some View {
        if let related {
            NavigationLink {
                SheepPedigreeView(account: account, farm: farm, sheepID: related.id)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    LabeledContent(label, value: related.earTag)
                    Text("来源：\(relation?.displayName ?? "历史资料")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            LabeledContent(label, value: "未知")
        }
    }

    @ViewBuilder
    private func ancestorSection(_ child: SheepRecord) -> some View {
        let parents = [child.damID, child.sireID].compactMap { $0.flatMap { byID[$0] } }
        let grandparents = parents.flatMap { parent in [parent.damID, parent.sireID].compactMap { $0.flatMap { byID[$0] } } }
        if !grandparents.isEmpty {
            Section("两代祖先") {
                ForEach(grandparents.uniquedByID, id: \.id) { ancestor in
                    NavigationLink {
                        SheepPedigreeView(account: account, farm: farm, sheepID: ancestor.id)
                    } label: {
                        LabeledContent(ancestor.sex == .ewe ? "祖母系" : "祖父系", value: ancestor.earTag)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func relationshipSection(_ title: String, records: [SheepRecord]) -> some View {
        if !records.isEmpty {
            Section(title) {
                ForEach(records.sorted { $0.earTag.localizedStandardCompare($1.earTag) == .orderedAscending }, id: \.id) { related in
                    NavigationLink {
                        SheepDetailView(account: account, farm: farm, sheep: related, penName: related.currentPenID.flatMap { penNames[$0] })
                    } label: {
                        LabeledContent(related.earTag, value: related.sex.displayName)
                    }
                }
            }
        }
    }

    private func siblings(of child: SheepRecord, keyPath: KeyPath<SheepRecord, UUID?>) -> [SheepRecord] {
        guard let parentID = child[keyPath: keyPath] else { return [] }
        return farmSheep.filter { $0.id != child.id && $0[keyPath: keyPath] == parentID }
    }

    private func paternalSiblings(of child: SheepRecord) -> [SheepRecord] {
        if let donorID = child.semenDonorID {
            return farmSheep.filter { $0.id != child.id && $0.semenDonorID == donorID }
        }
        guard let sireID = child.sireID else { return [] }
        return farmSheep.filter { $0.id != child.id && $0.sireID == sireID && $0.semenDonorID == nil }
    }

    private func donorTitle(_ donor: SemenDonorRecord) -> String {
        [donor.name, donor.registrationNumber.nilIfEmpty, donor.breed.nilIfEmpty].compactMap { $0 }.joined(separator: " · ")
    }

    private func updateBreedingRam(_ sheep: SheepRecord, active: Bool) {
        do {
            try service.execute(
                .care(.setBreedingRam(sheepID: sheep.id, isBreedingRam: active, expectedRevision: sheep.revision)),
                in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role),
                context: modelContext
            )
        } catch { errorMessage = error.localizedDescription }
    }
}

struct SheepPedigreeEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SheepRecord.earTag) private var sheep: [SheepRecord]
    @Query(sort: \SemenDonorRecord.name) private var donors: [SemenDonorRecord]
    @Query private var rules: [FarmCareRuleRecord]

    let account: AccountProfile
    let farm: FarmRecord
    let sheepID: UUID

    @State private var damID: UUID?
    @State private var paternalSelection = PedigreePaternalSelection.unknown
    @State private var sireID: UUID?
    @State private var donorID: UUID?
    @State private var reason = ""
    @State private var candidates: [PedigreeSireCandidate] = []
    @State private var errorMessage: String?
    private let service = FarmCommandService()

    private var farmSheep: [SheepRecord] { sheep.filter { $0.farmID == farm.id && $0.deletedAt == nil } }
    private var record: SheepRecord? { farmSheep.first { $0.id == sheepID } }
    private var dams: [SheepRecord] { farmSheep.filter { $0.id != sheepID && $0.sex == .ewe } }
    private var breedingRams: [SheepRecord] { farmSheep.filter { $0.id != sheepID && $0.sex == .ram && $0.isBreedingRam } }
    private var farmDonors: [SemenDonorRecord] { donors.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.status == .active } }
    private var gestationDays: Int { rules.first { $0.farmID == farm.id }?.gestationDays ?? 150 }

    var body: some View {
        Form {
            if let record {
                Section("当前羊只") {
                    LabeledContent("耳号", value: record.earTag)
                    if let birthAt = record.birthAt { LabeledContent("出生日期", value: birthAt.formatted(date: .abbreviated, time: .omitted)) }
                }
                Section("母系") {
                    Picker("母本", selection: $damID) {
                        Text("未知").tag(UUID?.none)
                        ForEach(dams, id: \.id) { Text($0.earTag).tag(UUID?.some($0.id)) }
                    }
                }
                Section("父系") {
                    Picker("父本来源", selection: $paternalSelection) {
                        ForEach(PedigreePaternalSelection.allCases) { Text($0.displayName).tag($0) }
                    }
                    if paternalSelection == .breedingRam {
                        Picker("种公羊", selection: $sireID) {
                            Text("请选择").tag(UUID?.none)
                            ForEach(breedingRams, id: \.id) { Text($0.earTag).tag(UUID?.some($0.id)) }
                        }
                    } else if paternalSelection == .semenDonor {
                        Picker("冻精供体", selection: $donorID) {
                            Text("请选择").tag(UUID?.none)
                            ForEach(farmDonors, id: \.id) { Text($0.name).tag(UUID?.some($0.id)) }
                        }
                    }
                }

                if !candidates.isEmpty {
                    Section("历史同舍种公羊候选") {
                        Text("按出生日期向前推 \(gestationDays) 天，核对当时与母羊同舍且在场的种公羊。若内置 Core ML 模型可用，仅用于排序；否则使用确定性规则。点击候选也不会立即确权。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        ForEach(candidates) { candidate in
                            Button {
                                paternalSelection = .breedingRam
                                sireID = candidate.ramID
                                donorID = nil
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(candidate.earTag)
                                    Text("推定受胎日 \(candidate.conceptionAt.formatted(date: .abbreviated, time: .omitted)) · 排序分 \(candidate.rankingScore, format: .number.precision(.fractionLength(2)))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section("审计") {
                    TextField("修改原因（必填）", text: $reason, axis: .vertical)
                    Text("保存后才会通过命令管道写入；候选本身永远不会自动确认父本。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("编辑系谱")
        .toolbar { EntrySaveToolbar(action: save) }
        .recordErrorAlert($errorMessage)
        .onAppear(perform: load)
        .onChange(of: paternalSelection) { _, value in
            if value != .breedingRam { sireID = nil }
            if value != .semenDonor { donorID = nil }
        }
    }

    private func load() {
        guard let record else { return }
        damID = record.damID
        if let donorID = record.semenDonorID {
            paternalSelection = .semenDonor
            self.donorID = donorID
        } else if let sireID = record.sireID {
            paternalSelection = .breedingRam
            self.sireID = sireID
        }
        guard let eweID = record.damID, let birthAt = record.birthAt else { return }
        do {
            candidates = try PedigreeAnalysis.sireCandidates(eweID: eweID, lambingAt: birthAt, gestationDays: gestationDays, farmID: farm.id, context: modelContext)
        } catch { errorMessage = error.localizedDescription }
    }

    private func save() {
        guard let record else { return }
        do {
            try service.execute(
                .care(.updateSheepPedigree(.init(
                    sheepID: record.id,
                    damID: damID,
                    sireID: paternalSelection == .breedingRam ? sireID : nil,
                    semenDonorID: paternalSelection == .semenDonor ? donorID : nil,
                    reason: reason,
                    expectedRevision: record.revision
                ))),
                in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role),
                context: modelContext
            )
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

struct PedigreeCheckView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SheepRecord.earTag) private var sheep: [SheepRecord]
    @Query private var rules: [FarmCareRuleRecord]
    let account: AccountProfile
    let farm: FarmRecord

    @State private var issues: [PedigreeIssue] = []
    @State private var errorMessage: String?

    private var farmSheep: [SheepRecord] { sheep.filter { $0.farmID == farm.id && $0.deletedAt == nil } }
    private var byID: [UUID: SheepRecord] { Dictionary(uniqueKeysWithValues: farmSheep.map { ($0.id, $0) }) }
    private var gestationDays: Int { rules.first { $0.farmID == farm.id }?.gestationDays ?? 150 }
    private var revisionSignature: [String] { farmSheep.map { "\($0.id):\($0.revision)" }.sorted() }

    var body: some View {
        List {
            Section {
                NavigationLink {
                    BreedingRamManagementView(account: account, farm: farm)
                } label: {
                    Label("种公羊管理", systemImage: "checklist")
                }
                Text("父本候选只使用明确标记的种公羊；普通公羊不参与。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if issues.isEmpty {
                ContentUnavailableView("没有发现系谱问题", systemImage: "checkmark.seal")
            } else {
                Section("待检查 · \(issues.count)") {
                    ForEach(issues) { issue in
                        NavigationLink {
                            SheepPedigreeView(account: account, farm: farm, sheepID: issue.sheepID)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(issue.title)
                                Text(issue.detail).font(.footnote).foregroundStyle(.secondary)
                                if !issue.candidateRamIDs.isEmpty {
                                    Text(issue.candidateRamIDs.compactMap { byID[$0]?.earTag }.joined(separator: "、"))
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("全场系谱检查")
        .recordErrorAlert($errorMessage)
        .farmExcelImport(account: account, farm: farm, sheets: ["系谱关系"])
        .onAppear(perform: refresh)
        .onChange(of: revisionSignature) { _, _ in refresh() }
    }

    private func refresh() {
        do { issues = try PedigreeAnalysis.issues(farmID: farm.id, gestationDays: gestationDays, context: modelContext) }
        catch { errorMessage = error.localizedDescription }
    }
}

private struct BreedingRamManagementView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SheepRecord.earTag) private var sheep: [SheepRecord]
    let account: AccountProfile
    let farm: FarmRecord
    @State private var errorMessage: String?
    private let service = FarmCommandService()

    private var rams: [SheepRecord] { sheep.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.sex == .ram } }
    private var canEdit: Bool { CapabilitySet(role: farm.role).allows(.editHistoricalFacts) }

    var body: some View {
        List {
            Section {
                Text("只将实际用于繁殖的公羊标记为种公羊。这个标记决定父本候选集合。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("公羊档案") {
                ForEach(rams, id: \.id) { ram in
                    Toggle(isOn: Binding(
                        get: { ram.isBreedingRam },
                        set: { update(ram, active: $0) }
                    )) {
                        VStack(alignment: .leading) {
                            Text(ram.earTag)
                            Text(ram.isBreedingRam ? "种公羊" : "普通公羊")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!canEdit)
                }
            }
        }
        .navigationTitle("种公羊管理")
        .recordErrorAlert($errorMessage)
    }

    private func update(_ ram: SheepRecord, active: Bool) {
        do {
            try service.execute(
                .care(.setBreedingRam(sheepID: ram.id, isBreedingRam: active, expectedRevision: ram.revision)),
                in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role),
                context: modelContext
            )
        } catch { errorMessage = error.localizedDescription }
    }
}

private extension Array where Element == SheepRecord {
    var uniquedByID: [SheepRecord] {
        var seen = Set<UUID>()
        return filter { seen.insert($0.id).inserted }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
