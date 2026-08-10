import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct MigrationWorkspaceView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppSession.self) private var appSession
    @Query private var accounts: [AccountProfile]
    @Query private var migrationCommits: [MigrationCommitRecord]
    @State private var isImporting = false
    @State private var isImportingBaseline = false
    @State private var session: MigrationSession?
    @State private var savedSessions: [MigrationSession] = []
    @State private var temporaryFarm: MigrationTemporaryFarm?
    @State private var errorMessage: String?
    @State private var isBuildingTemporaryFarm = false
    @State private var isCommittingMigration = false
    @State private var isCommitConfirmationPresented = false
    @State private var commitResult: MigrationCommitResult?

    var body: some View {
        List {
            Section {
                Text("此入口仅用于尚未建立 Next 牧场的首次完整迁移。已有牧场请从“录入 → 合并 eSheep+ 投喂”进入，只追加缺失投喂，不得用完整备份覆盖当前牧场。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("选择 eSheep+ 导出文件") { isImporting = true }
            }
            if !savedSessions.isEmpty {
                Section("已保存的迁移会话") {
                    ForEach(savedSessions) { saved in
                        Button {
                            session = saved
                            temporaryFarm = try? LegacyMigrationImporter.openTemporaryFarm(sessionID: saved.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(saved.manifest.importedAt, format: .dateTime.year().month().day().hour().minute())
                                Text(saved.isReadyForTemporaryBuild ? "可建立临时牧场" : "仍有 \(saved.blockingIssues.count) 项待处理")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button("删除", role: .destructive) { deleteSession(saved.id) }
                        }
                    }
                }
            }
            if let session {
                Section("迁移会话") {
                    LabeledContent("来源校验", value: String(session.manifest.sourceChecksum.prefix(12)))
                    LabeledContent("羊只", value: "\(session.sheep.count)")
                    LabeledContent("待归属历史记录", value: "\(session.assignments.filter { !$0.isResolved }.count)")
                }
                if !session.duplicateGroups.isEmpty {
                    Section("重复耳号") {
                        ForEach(session.duplicateGroups, id: \.first!.id) { group in
                            NavigationLink("\(group[0].legacyEarTag)（\(group.count) 只）") {
                                MigrationDuplicateResolutionView(session: requiredSessionBinding, sourceKeys: group.map(\.id))
                            }
                        }
                    }
                }
                if !session.assignments.filter({ !$0.isResolved }).isEmpty {
                    Section("历史记录待归属") {
                        ForEach(session.assignments.filter { !$0.isResolved }) { assignment in
                            NavigationLink("\(assignment.kind) · \(assignment.legacyEarTag) · \(assignment.dateText)") {
                                MigrationAssignmentResolutionView(session: requiredSessionBinding, assignmentID: assignment.id)
                            }
                        }
                    }
                }
                if !session.issues.isEmpty {
                    Section("迁移问题") {
                        ForEach(session.issues) { issue in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(issue.title).font(.headline).foregroundStyle(issue.severity == .blocking ? .red : .secondary)
                                Text(issue.detail).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("临时转换") {
                    Button(isBuildingTemporaryFarm ? "正在建立临时牧场" : "建立临时牧场", action: buildTemporaryFarm)
                        .disabled(!session.isReadyForTemporaryBuild || isBuildingTemporaryFarm)
                    if isBuildingTemporaryFarm { ProgressView("正在转换、重建历史并对账") }
                    Button("导入只读统计基线") { isImportingBaseline = true }.disabled(isBuildingTemporaryFarm)
                    Text("基线文件只接受 JSON：{ \"expectedCounts\": { \"羊只\": 0 } }。导入后会重建临时库，不会写入正式牧场。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let result = temporaryFarm?.reconciliation {
                        LabeledContent("已转换羊只／圈舍", value: "\(result.convertedSheep)／\(result.convertedPens)")
                        LabeledContent("自动补建历史归档羊只", value: "\(result.archivalSheep)")
                        LabeledContent("称重／转群／离场", value: "\(result.convertedWeights)／\(result.convertedTransfers)／\(result.convertedRemovals)")
                        ForEach(result.convertedByType.sorted(by: { $0.key < $1.key }), id: \.key) { item in
                            LabeledContent(item.key, value: "\(item.value)")
                        }
                        LabeledContent("阻断项／警告项", value: "\(result.blockingDiscrepancies.count)／\(result.discrepancies.filter { $0.severity == .warning }.count)")
                        NavigationLink("打开迁移验收中心") { MigrationReviewCenterView(farmID: temporaryFarm!.farmID, report: result).modelContainer(temporaryFarm!.container) }
                        if result.blockingDiscrepancies.isEmpty {
                            Button(isCommittingMigration ? commitProgressTitle : commitActionTitle) {
                                isCommitConfirmationPresented = true
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isCommittingMigration || activeAccount == nil)
                            Text(commitHelpText)
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            Text("对账阻断项清零后才能创建正式牧场。")
                                .font(.footnote).foregroundStyle(.red)
                        }
                        Text("临时转换完成；只有点击并确认创建正式牧场后才会写入业务数据库。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("从 eSheep+ 导入")
        .task { savedSessions = MigrationWorkspaceStore.allSessions() }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get(); guard url.startAccessingSecurityScopedResource() else { throw CocoaError(.fileReadNoPermission) }; defer { url.stopAccessingSecurityScopedResource() }
                session = try LegacyMigrationImporter.preview(source: Data(contentsOf: url)); temporaryFarm = nil; savedSessions = MigrationWorkspaceStore.allSessions()
            } catch { errorMessage = error.localizedDescription }
        }
        .fileImporter(isPresented: $isImportingBaseline, allowedContentTypes: [.json]) { result in
            do {
                guard let session else { return }
                let url = try result.get(); guard url.startAccessingSecurityScopedResource() else { throw CocoaError(.fileReadNoPermission) }; defer { url.stopAccessingSecurityScopedResource() }
                let data = try Data(contentsOf: url)
                _ = try JSONDecoder().decode(MigrationBaselineSnapshot.self, from: data)
                try MigrationWorkspaceStore.saveBaseline(data, for: session.id)
                if temporaryFarm != nil { buildTemporaryFarm() }
            } catch { errorMessage = error.localizedDescription }
        }
        .confirmationDialog(
            commitConfirmationTitle,
            isPresented: $isCommitConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("确认创建") { commitMigration() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(commitConfirmationMessage)
        }
        .alert(
            "迁移完成",
            isPresented: Binding(get: { commitResult != nil }, set: { if !$0 { commitResult = nil } })
        ) {
            Button("进入牧场") {
                if let result = commitResult {
                    appSession.selectedFarmID = result.farmID
                    appSession.selectedTab = .home
                }
                commitResult = nil
            }
        } message: {
            if let result = commitResult {
                Text(result.wasAlreadyCommitted
                    ? "\(result.farmName) 已补齐缺失的 eSheep+ 历史数据。当前共核对 \(result.committedRecordCount) 条记录。\(cloudStatusText(for: result.farmID))"
                    : "\(result.farmName) 已创建，共导入 \(result.committedRecordCount) 条记录和 \(result.photoCount) 张照片。\(cloudStatusText(for: result.farmID))")
            }
        }
        .alert("迁移操作失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("知道了", role: .cancel) {} } message: { Text(errorMessage ?? "") }
    }

    private var requiredSessionBinding: Binding<MigrationSession> {
        Binding(get: { session! }, set: { session = $0 })
    }

    private var activeAccount: AccountProfile? {
        guard let profileID = appSession.activeAccountProfileID else { return nil }
        return accounts.first(where: { $0.id == profileID })
    }

    private var isRepairingExistingMigration: Bool {
        guard let session, let account = activeAccount else { return false }
        return migrationCommits.contains {
            $0.sourceChecksum == session.manifest.sourceChecksum
                && $0.ownerAccountID == account.effectiveAccountID
                && $0.status == .completed
        }
    }

    private var commitActionTitle: String { isRepairingExistingMigration ? "补齐已迁移数据" : "创建正式牧场" }
    private var commitProgressTitle: String { isRepairingExistingMigration ? "正在补齐历史数据" : "正在创建正式牧场" }
    private var commitConfirmationTitle: String { isRepairingExistingMigration ? "确认补齐历史数据" : "确认创建正式牧场" }
    private var commitHelpText: String {
        isRepairingExistingMigration
            ? "只补入这份 eSheep+ 备份中尚未进入 Next 的历史记录；不会重复羊只，也不会追溯扣减饲料库存。"
            : "创建后即可离线使用。Development 会在登录与 iCloud 可用时自动上传；失败不会影响本机录入。"
    }
    private var commitConfirmationMessage: String {
        isRepairingExistingMigration
            ? "系统会按来源校验补齐缺失的投喂及明细，并刷新云端基线。已有业务记录不会重复，eSheep+ 不会被修改。"
            : "系统会将已对账数据和云端基线原子写入当前账号。旧版 eSheep+ 不会被修改，iCloud 上传将在建场成功后自动进行。"
    }

    private func buildTemporaryFarm() {
        guard let session else { return }
        let sessionID = session.id
        isBuildingTemporaryFarm = true
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try LegacyMigrationImporter.buildTemporaryFarm(sessionID: sessionID)
                }.value
                temporaryFarm = result
            } catch {
                errorMessage = error.localizedDescription
            }
            isBuildingTemporaryFarm = false
        }
    }

    private func commitMigration() {
        guard let session, let account = activeAccount else { return }
        isCommittingMigration = true
        do {
            let result = try MigrationCommitService().commit(
                sessionID: session.id,
                account: account,
                destinationContext: modelContext
            )
            commitResult = result
        } catch {
            errorMessage = error.localizedDescription
        }
        isCommittingMigration = false
    }

    private func deleteSession(_ sessionID: UUID) {
        do {
            try MigrationWorkspaceStore.delete(sessionID: sessionID)
            if session?.id == sessionID { session = nil; temporaryFarm = nil }
            savedSessions = MigrationWorkspaceStore.allSessions()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func cloudStatusText(for farmID: UUID) -> String {
        guard let commit = migrationCommits.first(where: { $0.farmID == farmID }) else { return "已保存在本机。" }
        return commit.cloudState.displayName + (commit.cloudLastError.map { "：\($0)" } ?? "。")
    }
}

private struct MigrationDuplicateResolutionView: View {
    @Binding var session: MigrationSession
    let sourceKeys: [String]
    @State private var errorMessage: String?

    private var candidates: [MigrationSheepCandidate] { session.sheep.filter { sourceKeys.contains($0.id) } }

    var body: some View {
        Form {
            Section("确认新耳号") {
                Text("每只羊都必须拥有全牧场永久唯一的耳号。原耳号会保留为迁移来源，不会丢失。")
                    .font(.footnote).foregroundStyle(.secondary)
                ForEach(candidates) { candidate in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("原耳号：\(candidate.legacyEarTag)").font(.headline)
                        Text("\(candidate.sex) · \(candidate.breed) · \(candidate.pen) · \(candidate.birth)").font(.footnote).foregroundStyle(.secondary)
                        TextField("最终耳号", text: earTagBinding(candidate.id))
                            .textInputAutocapitalization(.characters)
                    }
                }
            }
        }
        .navigationTitle("重复耳号确认")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("保存", action: save) } }
        .alert("无法保存", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("知道了", role: .cancel) {} } message: { Text(errorMessage ?? "") }
    }

    private func earTagBinding(_ sourceKey: String) -> Binding<String> {
        Binding(get: { session.sheep.first(where: { $0.id == sourceKey })?.finalEarTag ?? "" }, set: { value in
            guard let index = session.sheep.firstIndex(where: { $0.id == sourceKey }) else { return }
            session.sheep[index].finalEarTag = value
        })
    }

    private func save() {
        do {
            let values = candidates.map { candidate in
                (candidate.id, session.sheep.first(where: { $0.id == candidate.id })?.finalEarTag ?? "")
            }
            for (sourceKey, tag) in values { try MigrationResolutionService.apply(.renameSheep(sourceKey: sourceKey, finalEarTag: tag), to: &session) }
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct MigrationAssignmentResolutionView: View {
    @Binding var session: MigrationSession
    let assignmentID: String
    @State private var selectedSourceKey: String?
    @State private var exclusionReason = ""
    @State private var errorMessage: String?

    private var assignment: MigrationRecordAssignment? { session.assignments.first { $0.id == assignmentID } }
    private var candidates: [MigrationSheepCandidate] { guard let assignment else { return [] }; return session.sheep.filter { EarTag.normalized($0.legacyEarTag) == EarTag.normalized(assignment.legacyEarTag) } }

    var body: some View {
        Form {
            if let assignment {
                Section("来源记录") { LabeledContent("类型", value: assignment.kind); LabeledContent("耳号", value: assignment.legacyEarTag); LabeledContent("日期", value: assignment.dateText) }
            }
            Section("归属羊只") { Picker("羊只", selection: $selectedSourceKey) { Text("请选择").tag(String?.none); ForEach(candidates) { candidate in Text("\(candidate.finalEarTag ?? candidate.legacyEarTag) · \(candidate.pen)").tag(String?.some(candidate.id)) } } }
            Section("或标记来源无效") { TextField("排除原因", text: $exclusionReason); Button("标记为无效", role: .destructive, action: exclude) }
        }
        .navigationTitle("确认历史归属")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("保存归属", action: assign).disabled(selectedSourceKey == nil) } }
        .alert("无法保存", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("知道了", role: .cancel) {} } message: { Text(errorMessage ?? "") }
    }

    private func assign() { guard let selectedSourceKey else { return }; do { try MigrationResolutionService.apply(.assignRecord(recordKey: assignmentID, sheepSourceKey: selectedSourceKey), to: &session) } catch { errorMessage = error.localizedDescription } }
    private func exclude() { do { try MigrationResolutionService.apply(.excludeRecord(recordKey: assignmentID, reason: exclusionReason), to: &session) } catch { errorMessage = error.localizedDescription } }
}
