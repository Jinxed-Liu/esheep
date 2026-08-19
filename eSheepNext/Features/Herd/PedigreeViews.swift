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
    @Environment(AppSession.self) private var session
    @Environment(\.modelContext) private var modelContext

    let account: AccountProfile
    let farm: FarmRecord
    let sheepID: UUID

    @State private var profile: PedigreeProfileSnapshot?
    @State private var sireCandidates: [PedigreeSireCandidate] = []
    @State private var isLoadingCandidates = false
    @State private var selectedCandidate: PedigreeSireCandidate?
    @State private var gestationDays = 150
    @State private var isLoading = true
    @State private var editing = false
    @State private var errorMessage: String?
    private let service = FarmCommandService()

    private var canEdit: Bool { CapabilitySet(role: farm.role).allows(.editHistoricalFacts) }

    var body: some View {
        Group {
            if let profile {
                List {
                    Section("两代系谱树") {
                        PedigreeTreeDiagram(
                            profile: profile,
                            sireCandidates: sireCandidates,
                            isLoadingCandidates: isLoadingCandidates,
                            canConfirmCandidate: canEdit,
                            onSelectSheep: openRelatedSheep,
                            onSelectCandidate: { selectedCandidate = $0 }
                        )
                        .listRowInsets(.init(top: 12, leading: 0, bottom: 8, trailing: 0))
                        .listRowSeparator(.hidden)
                    }

                    Section("父母") {
                        pedigreeLink(label: "母本", relation: profile.record.damProvenance, sheep: profile.dam)
                        if let donor = profile.donor {
                            VStack(alignment: .leading, spacing: 4) {
                                LabeledContent("父本来源", value: "冻精供体")
                                Text(donorTitle(donor)).font(.footnote).foregroundStyle(.secondary)
                                if let sire = profile.sire {
                                    pedigreeLink(label: "关联种公羊", relation: profile.record.sireProvenance, sheep: sire)
                                }
                            }
                        } else {
                            pedigreeLink(label: "父本", relation: profile.record.sireProvenance, sheep: profile.sire)
                        }
                    }

                    sireCandidateSection(profile)

                    ancestorSection(profile.grandparents)
                    relationshipSection("同胎羊", records: profile.littermates)
                    relationshipSection("同母羊", records: profile.maternalSiblings)
                    relationshipSection("同父羊", records: profile.paternalSiblings)
                    relationshipSection("直接后代", records: profile.descendants)

                    if profile.record.sex == .ram {
                        Section("种公羊资格") {
                            Toggle("纳入种公羊父本候选", isOn: Binding(
                                get: { profile.record.isBreedingRam },
                                set: { updateBreedingRam(profile.record, active: $0) }
                            ))
                            .disabled(!canEdit)
                            Text("已确认种公羊会参与候选；旧档用途只会作为待人工核实线索，普通公羊不会参与。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !profile.audits.isEmpty {
                        Section("变更审计") {
                            ForEach(profile.audits) { audit in
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
            } else if isLoading {
                ProgressView("正在读取系谱")
            } else {
                ContentUnavailableView("羊只档案不存在", systemImage: "exclamationmark.triangle")
            }
        }
        .navigationTitle(profile.map { "系谱 · \($0.record.earTag)" } ?? "系谱")
        .toolbar {
            if profile != nil {
                Button("编辑") { editing = true }
                    .disabled(!canEdit)
            }
        }
        .sheet(isPresented: $editing, onDismiss: { Task { await reload() } }) {
            NavigationStack {
                SheepPedigreeEditorView(account: account, farm: farm, sheepID: sheepID)
            }
        }
        .sheet(item: $selectedCandidate, onDismiss: { Task { await reload() } }) { candidate in
            if let profile {
                NavigationStack {
                    PedigreeCandidateConfirmationView(
                        account: account,
                        farm: farm,
                        child: profile.record,
                        candidate: candidate
                    )
                }
            }
        }
        .task(id: sheepID) { await reload() }
        .recordErrorAlert($errorMessage)
    }

    @ViewBuilder
    private func pedigreeLink(label: String, relation: PedigreeRelationSource?, sheep related: PedigreeRelatedSheep?) -> some View {
        if let related {
            Button {
                openRelatedSheep(related)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    LabeledContent(label, value: related.earTag)
                    Text("来源：\(relation?.displayName ?? "历史资料")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        } else {
            LabeledContent(label, value: "未知")
        }
    }

    @ViewBuilder
    private func ancestorSection(_ grandparents: [PedigreeRelatedSheep]) -> some View {
        if !grandparents.isEmpty {
            Section("两代祖先") {
                ForEach(grandparents) { ancestor in
                    Button {
                        openRelatedSheep(ancestor)
                    } label: {
                        LabeledContent(ancestor.sex == .ewe ? "祖母系" : "祖父系", value: ancestor.earTag)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func relationshipSection(_ title: String, records: [PedigreeRelatedSheep]) -> some View {
        if !records.isEmpty {
            Section(LocalizedStringKey(title)) {
                ForEach(records) { related in
                    Button {
                        openRelatedSheep(related)
                    } label: {
                        LabeledContent(related.earTag, value: related.sex.displayName)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func donorTitle(_ donor: PedigreeDonorSummary) -> String {
        [donor.name, donor.registrationNumber.nilIfEmpty, donor.breed.nilIfEmpty].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder
    private func sireCandidateSection(_ profile: PedigreeProfileSnapshot) -> some View {
        if profile.record.sireID == nil && profile.record.semenDonorID == nil {
            Section("父本推测") {
                if profile.record.damID == nil {
                    Text("需要先确认母本，才能按母本历史圈舍推算父本。")
                        .foregroundStyle(.secondary)
                } else if profile.record.birthAt == nil {
                    Text("缺少出生日期，无法向前推算受胎日。")
                        .foregroundStyle(.secondary)
                } else if isLoadingCandidates {
                    ProgressView("正在核对出生前 \(gestationDays)～\(minimumCandidateGestationDays) 天的母本圈舍")
                } else if sireCandidates.isEmpty {
                    Text("出生前 \(gestationDays)～\(minimumCandidateGestationDays) 天内，没有找到与母本同舍的已确认种公羊或可人工核实的旧档线索。")
                        .foregroundStyle(.secondary)
                } else {
                    Text("以出生前 \(gestationDays) 天为标准受胎日，并向出生方向保留最多 \(PedigreeAnalysis.prematureBirthToleranceDays) 天早产容差。只展示窗口内在场且与母本同舍的种公羊，候选不会自动确权。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    ForEach(sireCandidates) { candidate in
                        Button {
                            selectedCandidate = candidate
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(candidate.earTag)
                                    Spacer()
                                    Text(candidate.isConfirmedBreedingRam ? LocalizedStringKey("已确认种公羊") : LocalizedStringKey("旧档线索 · 待核实"))
                                        .font(.caption)
                                        .foregroundStyle(candidate.isConfirmedBreedingRam ? .green : .orange)
                                }
                                Text(candidateEvidence(candidate))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .disabled(!canEdit)
                    }
                }
            }
        }
    }

    private func candidateEvidence(_ candidate: PedigreeSireCandidate) -> String {
        candidate.displayEvidence
    }

    private var minimumCandidateGestationDays: Int {
        max(1, gestationDays - PedigreeAnalysis.prematureBirthToleranceDays)
    }

    private func openRelatedSheep(_ related: PedigreeRelatedSheep) {
        session.pendingSearchQuery = related.earTag
        session.pendingSheepID = related.id
        session.selectedTab = .search
    }

    private func updateBreedingRam(_ sheep: PedigreeSheepSnapshot, active: Bool) {
        do {
            try service.execute(
                .care(.setBreedingRam(sheepID: sheep.id, isBreedingRam: active, expectedRevision: sheep.revision)),
                in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role),
                context: modelContext
            )
            Task { await reload() }
        } catch { errorMessage = error.localizedDescription }
    }

    @MainActor
    private func reload() async {
        isLoading = true
        isLoadingCandidates = true
        sireCandidates = []
        await Task.yield()
        do {
            let snapshot = try await PedigreeSnapshotActor(
                container: modelContext.container
            ).load(sheepID: sheepID, farmID: farm.id)
            try Task.checkCancellation()
            profile = snapshot.profile
            sireCandidates = snapshot.sireCandidates
            gestationDays = snapshot.gestationDays
        } catch is CancellationError {
            return
        } catch {
            profile = nil
            errorMessage = error.localizedDescription
        }
        isLoadingCandidates = false
        isLoading = false
    }
}

private struct PedigreeCandidateConfirmationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let account: AccountProfile
    let farm: FarmRecord
    let child: PedigreeSheepSnapshot
    let candidate: PedigreeSireCandidate

    @State private var reason = ""
    @State private var errorMessage: String?
    private let service = FarmCommandService()

    var body: some View {
        Form {
            Section("候选父本") {
                LabeledContent("后代", value: child.earTag)
                LabeledContent("候选种公羊", value: candidate.earTag)
                LabeledContent(
                    "标准回推日",
                    value: candidate.conceptionAt.formatted(date: .abbreviated, time: .omitted)
                )
                LabeledContent(
                    "同舍记录日",
                    value: candidate.matchedAt.formatted(date: .abbreviated, time: .omitted)
                )
                LabeledContent("同舍圈舍", value: candidate.historicalPenName ?? "未知圈舍")
                LabeledContent("推定妊娠期", value: "\(candidate.inferredGestationDays) 天")
                LabeledContent(
                    "资格依据",
                    value: candidate.isConfirmedBreedingRam ? "已确认种公羊" : "旧档用途线索，尚未确认"
                )
            }

            if candidate.isPrematurityWindowMatch {
                Section("早产容差候选") {
                    LabeledContent("较标准回推日晚", value: "\(candidate.prematurityAllowanceDays) 天")
                    Text("该种公羊并非在标准 \(candidate.configuredGestationDays) 天回推日命中，而是在早产容差窗口内与母本同舍。确认前必须结合配种、转群或产羔记录人工核实。")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            if !candidate.isConfirmedBreedingRam {
                Section("资格确认") {
                    Text("该记录目前不是已确认种公羊。保存时会先将这一个体明确标记为种公羊，再写入父本关系；不会批量修改其他旧档公羊。")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            Section("审计原因") {
                TextField("例如：核对配种舍记录后确认（必填）", text: $reason, axis: .vertical)
                Text("推测和点击均不会直接确权，只有保存后才通过命令管道写入。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("确认父本")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存", action: save)
                    .disabled(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .recordErrorAlert($errorMessage)
    }

    private func save() {
        let humanReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !humanReason.isEmpty else {
            errorMessage = "请填写人工核实原因。"
            return
        }
        var commands: [FarmCommand] = []
        if !candidate.isConfirmedBreedingRam {
            commands.append(.care(.setBreedingRam(
                sheepID: candidate.ramID,
                isBreedingRam: true,
                expectedRevision: candidate.ramRevision
            )))
        }
        commands.append(.care(.updateSheepPedigree(.init(
            sheepID: child.id,
            damID: child.damID,
            sireID: candidate.ramID,
            semenDonorID: nil,
            reason: candidate.auditReason(appendingTo: humanReason),
            expectedRevision: child.revision
        ))))

        do {
            try service.executeBatch(
                commands,
                in: FarmContext(
                    accountID: account.effectiveAccountID,
                    farmID: farm.id,
                    role: farm.role
                ),
                context: modelContext
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
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
    private var selectedUnconfirmedCandidate: PedigreeSireCandidate? {
        selectedCandidateEvidence.flatMap { $0.isConfirmedBreedingRam ? nil : $0 }
    }
    private var selectedCandidateEvidence: PedigreeSireCandidate? { candidates.first { $0.ramID == sireID } }
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
                        ForEach(PedigreePaternalSelection.allCases) { Text(LocalizedStringKey($0.displayName)).tag($0) }
                    }
                    if paternalSelection == .breedingRam {
                        Picker("种公羊", selection: $sireID) {
                            Text("请选择").tag(UUID?.none)
                            ForEach(breedingRams, id: \.id) { Text($0.earTag).tag(UUID?.some($0.id)) }
                            if let selectedUnconfirmedCandidate {
                                Text("\(selectedUnconfirmedCandidate.earTag)（待确认资格）")
                                    .tag(UUID?.some(selectedUnconfirmedCandidate.ramID))
                            }
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
                        Text("核对出生前 \(gestationDays)～\(max(1, gestationDays - PedigreeAnalysis.prematureBirthToleranceDays)) 天内与母羊同舍且在场的种公羊。早产容差候选会明确标注；Core ML 只参与排序，点击候选不会立即确权。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        ForEach(candidates) { candidate in
                            Button {
                                paternalSelection = .breedingRam
                                sireID = candidate.ramID
                                donorID = nil
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(candidate.earTag)
                                        Spacer()
                                        Text(candidate.isConfirmedBreedingRam ? LocalizedStringKey("已确认种公羊") : LocalizedStringKey("旧档线索 · 待核实"))
                                            .font(.caption)
                                            .foregroundStyle(candidate.isConfirmedBreedingRam ? .green : .orange)
                                    }
                                    Text(LocalizedStringKey(candidate.displayEvidence))
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
        let humanReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !humanReason.isEmpty else {
            errorMessage = "请填写修改原因。"
            return
        }
        let recordedReason = selectedCandidateEvidence?.auditReason(appendingTo: humanReason) ?? humanReason
        let pedigreeCommand = FarmCommand.care(.updateSheepPedigree(.init(
            sheepID: record.id,
            damID: damID,
            sireID: paternalSelection == .breedingRam ? sireID : nil,
            semenDonorID: paternalSelection == .semenDonor ? donorID : nil,
            reason: recordedReason,
            expectedRevision: record.revision
        )))
        let farmContext = FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role)
        do {
            if paternalSelection == .breedingRam, let candidate = selectedUnconfirmedCandidate {
                try service.executeBatch([
                    .care(.setBreedingRam(
                        sheepID: candidate.ramID,
                        isBreedingRam: true,
                        expectedRevision: candidate.ramRevision
                    )),
                    pedigreeCommand,
                ], in: farmContext, context: modelContext)
            } else {
                try service.execute(pedigreeCommand, in: farmContext, context: modelContext)
            }
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

struct PedigreeCheckView: View {
    @Environment(\.modelContext) private var modelContext
    let account: AccountProfile
    let farm: FarmRecord

    @State private var issues: [PedigreeIssue] = []
    @State private var batchSireProposals: [PedigreeBatchSireProposal] = []
    @State private var earTagsByID: [UUID: String] = [:]
    @State private var isLoading = false
    @State private var hasLoaded = false
    @State private var visibleLimit = 100
    @State private var errorMessage: String?

    private var batchSireCount: Int { Set(batchSireProposals.map(\.candidate.ramID)).count }
    private var ambiguousSireCount: Int {
        issues.count { $0.kind == .candidateSire && $0.candidateRamIDs.count > 1 }
    }

    var body: some View {
        List {
            Section {
                NavigationLink {
                    BreedingRamManagementView(account: account, farm: farm)
                } label: {
                    Label("种公羊管理", systemImage: "checklist")
                }
                Text("父本候选优先使用已确认种公羊；旧档用途仅作为待人工核实线索，普通公羊不参与。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if !batchSireProposals.isEmpty {
                Section("批量处理") {
                    NavigationLink {
                        PedigreeBatchSireReviewView(
                            account: account,
                            farm: farm,
                            proposals: batchSireProposals,
                            onSaved: { Task { await refresh() } }
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("批量确认唯一父本", systemImage: "checkmark.rectangle.stack")
                            Text("\(batchSireProposals.count) 只后代 · \(batchSireCount) 个候选父本")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("只汇总唯一候选且通过日期、循环检查的记录；可按父本一次确认多只。多候选 \(ambiguousSireCount) 条仍保留人工选择。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if isLoading || !hasLoaded {
                Section {
                    HStack {
                        Spacer()
                        ProgressView("正在建立系谱索引")
                        Spacer()
                    }
                }
            } else if issues.isEmpty {
                ContentUnavailableView("没有发现系谱问题", systemImage: "checkmark.seal")
            } else {
                Section("待检查 · \(issues.count)") {
                    ForEach(issues.prefix(visibleLimit)) { issue in
                        NavigationLink {
                            SheepPedigreeView(account: account, farm: farm, sheepID: issue.sheepID)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(LocalizedStringKey(issue.title))
                                Text(LocalizedStringKey(issue.detail)).font(.footnote).foregroundStyle(.secondary)
                                if !issue.candidateRamIDs.isEmpty {
                                    Text(issue.candidateRamIDs.compactMap { earTagsByID[$0] }.joined(separator: "、"))
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                    if visibleLimit < issues.count {
                        Button("继续加载（剩余 \(issues.count - visibleLimit) 项）") {
                            visibleLimit = min(visibleLimit + 100, issues.count)
                        }
                    }
                }
            }
        }
        .navigationTitle("全场系谱检查")
        .recordErrorAlert($errorMessage)
        .farmExcelImport(account: account, farm: farm, sheets: ["系谱关系"])
        .task { await refresh() }
        .refreshable { await refresh() }
        .toolbar {
            Button("重新检查", systemImage: "arrow.clockwise") { Task { await refresh() } }
                .disabled(isLoading)
        }
    }

    @MainActor
    private func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }
        visibleLimit = 100
        await Task.yield()
        do {
            let snapshot = try await PedigreeSnapshotActor(
                container: modelContext.container
            ).loadCheck(farmID: farm.id)
            try Task.checkCancellation()
            earTagsByID = snapshot.earTagsByID
            issues = snapshot.issues
            batchSireProposals = snapshot.batchSireProposals
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct PedigreeBatchSireGroup: Identifiable {
    var id: UUID { ramID }
    let ramID: UUID
    let ramEarTag: String
    let proposals: [PedigreeBatchSireProposal]

    var isConfirmedBreedingRam: Bool {
        proposals.first?.candidate.isConfirmedBreedingRam == true
    }

    var prematurityMatchCount: Int {
        proposals.count { $0.candidate.isPrematurityWindowMatch }
    }
}

private struct PedigreeBatchSireReviewView: View {
    let account: AccountProfile
    let farm: FarmRecord
    let onSaved: @MainActor () -> Void

    @State private var proposals: [PedigreeBatchSireProposal]

    init(
        account: AccountProfile,
        farm: FarmRecord,
        proposals: [PedigreeBatchSireProposal],
        onSaved: @escaping @MainActor () -> Void
    ) {
        self.account = account
        self.farm = farm
        self.onSaved = onSaved
        _proposals = State(initialValue: proposals)
    }

    private var groups: [PedigreeBatchSireGroup] {
        Dictionary(grouping: proposals, by: \.candidate.ramID)
            .compactMap { ramID, values in
                guard let candidate = values.first?.candidate else { return nil }
                return PedigreeBatchSireGroup(
                    ramID: ramID,
                    ramEarTag: candidate.earTag,
                    proposals: values.sorted {
                        $0.child.earTag.localizedStandardCompare($1.child.earTag) == .orderedAscending
                    }
                )
            }
            .sorted {
                $0.ramEarTag.localizedStandardCompare($1.ramEarTag) == .orderedAscending
            }
    }

    var body: some View {
        List {
            Section {
                Text("这里按唯一候选父本分组。进入一个父本后可全选或取消部分后代，只填写一次核实原因。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if groups.isEmpty {
                ContentUnavailableView("本轮批量确认已完成", systemImage: "checkmark.seal")
            } else {
                Section("候选父本 · \(groups.count)") {
                    ForEach(groups) { group in
                        NavigationLink {
                            PedigreeBatchSireConfirmationView(
                                account: account,
                                farm: farm,
                                group: group,
                                onSaved: { confirmedIDs in
                                    proposals.removeAll { confirmedIDs.contains($0.child.id) }
                                    onSaved()
                                }
                            )
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    // Ear tags are user-entered farm data, not localization keys.
                                    Text(verbatim: group.ramEarTag)
                                    Spacer()
                                    Text("\(group.proposals.count) 只")
                                        .foregroundStyle(.secondary)
                                }
                                Text(group.isConfirmedBreedingRam ? LocalizedStringKey("已确认种公羊") : LocalizedStringKey("旧档种公羊线索 · 本批同时确认资格"))
                                    .font(.caption)
                                    .foregroundStyle(group.isConfirmedBreedingRam ? .green : .orange)
                                if group.prematurityMatchCount > 0 {
                                    Text("含 \(group.prematurityMatchCount) 条早产容差证据")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("批量确认父本")
    }
}

private struct PedigreeBatchSireConfirmationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let account: AccountProfile
    let farm: FarmRecord
    let group: PedigreeBatchSireGroup
    let onSaved: @MainActor (Set<UUID>) -> Void

    @State private var selectedChildIDs: Set<UUID>
    @State private var reason = "核对历史配种圈舍，批量确认唯一父本"
    @State private var showsConfirmation = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    private let service = FarmCommandService()

    init(
        account: AccountProfile,
        farm: FarmRecord,
        group: PedigreeBatchSireGroup,
        onSaved: @escaping @MainActor (Set<UUID>) -> Void
    ) {
        self.account = account
        self.farm = farm
        self.group = group
        self.onSaved = onSaved
        _selectedChildIDs = State(initialValue: Set(group.proposals.map(\.child.id)))
    }

    private var selectedProposals: [PedigreeBatchSireProposal] {
        group.proposals.filter { selectedChildIDs.contains($0.child.id) }
    }

    private var canEdit: Bool {
        CapabilitySet(role: farm.role).allows(.editHistoricalFacts)
    }

    var body: some View {
        List {
            Section("候选父本") {
                LabeledContent("种公羊", value: group.ramEarTag)
                LabeledContent("本组后代", value: "\(group.proposals.count) 只")
                LabeledContent(
                    "种公羊资格",
                    value: group.isConfirmedBreedingRam ? "已确认" : "旧档线索，保存时一并确认"
                )
            }

            Section {
                HStack {
                    Button("全选") {
                        selectedChildIDs = Set(group.proposals.map(\.child.id))
                    }
                    Spacer()
                    Button("清空") {
                        selectedChildIDs.removeAll()
                    }
                }
            }

            Section("待确认后代 · \(selectedChildIDs.count)/\(group.proposals.count)") {
                ForEach(group.proposals) { proposal in
                    Toggle(isOn: Binding(
                        get: { selectedChildIDs.contains(proposal.child.id) },
                        set: { isSelected in
                            if isSelected {
                                selectedChildIDs.insert(proposal.child.id)
                            } else {
                                selectedChildIDs.remove(proposal.child.id)
                            }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(proposal.child.earTag)
                            if let birthAt = proposal.child.birthAt {
                                Text("出生 \(birthAt.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(LocalizedStringKey(proposal.candidate.displayEvidence))
                                .font(.caption)
                                .foregroundStyle(
                                    proposal.candidate.isPrematurityWindowMatch ? .orange : .secondary
                                )
                        }
                    }
                }
            }

            Section("审计原因") {
                TextField("批量确认原因（必填）", text: $reason, axis: .vertical)
                Text("每只后代仍会生成独立系谱审计和云同步操作；任一记录校验失败，整批全部回滚。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("确认 \(group.ramEarTag)")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("确认 \(selectedChildIDs.count) 只") {
                    showsConfirmation = true
                }
                .disabled(
                    !canEdit ||
                    isSaving ||
                    selectedChildIDs.isEmpty ||
                    reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .alert("确认批量写入父本？", isPresented: $showsConfirmation) {
            Button("取消", role: .cancel) {}
            Button("确认 \(selectedChildIDs.count) 只") {
                Task { await save() }
            }
        } message: {
            Text("父本将写为 \(group.ramEarTag)。保存后可从每只羊的系谱审计中追溯。")
        }
        .recordErrorAlert($errorMessage)
    }

    @MainActor
    private func save() async {
        let humanReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !humanReason.isEmpty, !selectedProposals.isEmpty else { return }
        isSaving = true
        await Task.yield()
        defer { isSaving = false }

        do {
            let farmID = farm.id
            let ramID = group.ramID
            guard let ram = try modelContext.fetch(FetchDescriptor<SheepRecord>(predicate: #Predicate {
                $0.id == ramID && $0.farmID == farmID && $0.deletedAt == nil
            })).first else {
                errorMessage = "候选种公羊档案已不存在，请重新检查。"
                return
            }

            var commands: [FarmCommand] = []
            if !ram.isBreedingRam {
                commands.append(.care(.setBreedingRam(
                    sheepID: ram.id,
                    isBreedingRam: true,
                    expectedRevision: ram.revision
                )))
            }
            let batchReason = "\(humanReason)；本次批量确认 \(selectedProposals.count) 只"
            commands.append(contentsOf: selectedProposals.map { proposal in
                .care(.updateSheepPedigree(.init(
                    sheepID: proposal.child.id,
                    damID: proposal.child.damID,
                    sireID: group.ramID,
                    semenDonorID: nil,
                    reason: proposal.candidate.auditReason(appendingTo: batchReason),
                    expectedRevision: proposal.child.revision
                )))
            })

            try service.executeBatch(
                commands,
                in: FarmContext(
                    accountID: account.effectiveAccountID,
                    farmID: farm.id,
                    role: farm.role
                ),
                context: modelContext
            )
            let confirmedIDs = selectedChildIDs
            onSaved(confirmedIDs)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
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
                            Text(ram.isBreedingRam ? LocalizedStringKey("种公羊") : LocalizedStringKey("普通公羊"))
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

private extension PedigreeSireCandidate {
    var displayEvidence: String {
        let date = matchedAt.formatted(date: .abbreviated, time: .omitted)
        let pen = historicalPenName ?? "历史圈舍"
        if isPrematurityWindowMatch {
            return "早产容差 +\(prematurityAllowanceDays) 天 · 同舍 \(date) · 推定妊娠 \(inferredGestationDays) 天 · \(pen)"
        }
        return "标准回推日同舍 \(date) · 推定妊娠 \(inferredGestationDays) 天 · \(pen)"
    }

    func auditReason(appendingTo humanReason: String) -> String {
        let date = matchedAt.formatted(date: .numeric, time: .omitted)
        let pen = historicalPenName ?? "未知圈舍"
        let boundary = isPrematurityWindowMatch
            ? "早产容差 \(prematurityAllowanceDays) 天"
            : "标准 \(configuredGestationDays) 天回推日命中"
        return "\(humanReason)；父本候选依据：\(boundary)，同舍日期 \(date)，推定妊娠 \(inferredGestationDays) 天，圈舍 \(pen)"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
