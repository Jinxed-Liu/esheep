import Observation
import SwiftData
import SwiftUI

struct ProductionEntryPrefill: Equatable, Sendable {
    var sheepID: UUID? = nil
    var penID: UUID? = nil
    var relatedFeedID: UUID? = nil
}

extension EnvironmentValues {
    @Entry var productionEntryPrefill = ProductionEntryPrefill()
    @Entry var productionEntryFocusRevision = 0
}

@MainActor
struct ProductionDraftField {
    let name: String
    let read: () throws -> Data
    let restore: (Data) throws -> Void
    let reset: () -> Void
    let carriesForward: Bool

    init<Value: Codable>(_ name: String, _ value: Binding<Value>, carry: Bool = false, reset: (() -> Value)? = nil) {
        self.name = name
        let initial = value.wrappedValue
        read = {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(value.wrappedValue)
        }
        restore = { value.wrappedValue = try JSONDecoder().decode(Value.self, from: $0) }
        self.reset = { value.wrappedValue = reset?() ?? initial }
        carriesForward = carry
    }
}

@MainActor
@Observable
final class ProductionEntrySession {
    var failure: String?
    var hasRecoverableDraft = false
    var isSubmitting = false
    var continuesAfterSave = false
    var completionRevision = 0
    var focusRevision = 0
    var statusText: String?
    var recoveryNotice: String?
    var usesCurrentTime = true
    var isApplyingFields = false
    private(set) var draft: ProductionDraft?
    private(set) var isReady = false
    @ObservationIgnored private var key: ProductionDraftKey?
    @ObservationIgnored private var pendingRecovery: ProductionDraft?
    @ObservationIgnored private var submittedSummary: String?
    @ObservationIgnored private var fields: [ProductionDraftField] = []
    @ObservationIgnored private var initialFields: [ProductionDraftField] = []
    @ObservationIgnored private var deferredSubmission = false
    @ObservationIgnored private var baseline: [String: Data] = [:]
    @ObservationIgnored private var store = ProductionDraftStore.application
    @ObservationIgnored private var appSession: AppSession?
    @ObservationIgnored private var accountProfileID: UUID?
    @ObservationIgnored private var lastReceipts: [FarmCommandExecutionReceipt] = []

    var hasChanges: Bool { draft != nil }

    init(store: ProductionDraftStore = .application) { self.store = store }

    func configure(form: String, account: AccountProfile, farm: FarmRecord, fields: [ProductionDraftField], appSession: AppSession, context: ModelContext, prefill: ProductionEntryPrefill) {
        guard !isReady else { self.fields = fields; return }
        self.fields = fields
        self.initialFields = fields
        self.appSession = appSession
        accountProfileID = account.id
        key = ProductionDraftKey(environment: Bundle.main.bundleIdentifier ?? "eSheepNext", accountID: account.effectiveAccountID, farmID: farm.id, form: form)
        do {
            baseline = try snapshot()
            if let key, let recovered = try store.load(key) {
                draft = recovered
                let ids = Set(recovered.requestIDs)
                let receipts = try context.fetch(FetchDescriptor<InsightExecutionReceiptRecord>()).filter {
                    ids.contains($0.sourceRequestID) && $0.accountID == key.accountID && $0.farmID == key.farmID
                }
                if !ids.isEmpty && receipts.count == ids.count {
                    try store.remove(key)
                    draft = nil
                    recoveryNotice = "上次记录已提交到本机，无需重复录入。云保存进度可在首页查看。"
                } else if !receipts.isEmpty {
                    throw ProductionDraftError.incompleteRecovery
                } else { pendingRecovery = recovered; hasRecoverableDraft = true }
            } else {
                try applyPrefill(prefill)
            }
            isReady = true
        } catch { failure = error.localizedDescription }
    }

    private func applyPrefill(_ value: ProductionEntryPrefill) throws {
        if let sheepID = value.sheepID {
            for field in fields {
                if ["sheepID", "eweID"].contains(field.name) { try field.restore(JSONEncoder().encode(sheepID)) }
                if ["selectedIDs", "selected"].contains(field.name) { try field.restore(JSONEncoder().encode(Set([sheepID]))) }
            }
        }
        if let relatedFeedID = value.relatedFeedID, let field = fields.first(where: { $0.name == "relatedFeedID" }) {
            try field.restore(JSONEncoder().encode(relatedFeedID))
        }
        if let penID = value.penID, let field = fields.first(where: { $0.name == "penID" }) {
            try field.restore(JSONEncoder().encode(penID))
        }
    }

    /// Synchronous form setup is a baseline, not input entered by the operator.
    func acceptInitialValues(fields: [ProductionDraftField]) {
        guard draft == nil, pendingRecovery == nil, !isSubmitting else { return }
        self.fields = fields
        do { baseline = try snapshot() }
        catch { failure = "表单暂时无法准备：\(error.localizedDescription)" }
    }

    func update(fields: [ProductionDraftField]) {
        self.fields = fields
        guard isReady, pendingRecovery == nil, !isSubmitting, !isApplyingFields else { return }
        do {
            let values = try snapshot()
            if values == baseline && draft == nil { return }
            if draft?.fields == values { return }
            let previous = draft?.fields ?? baseline
            if fields.contains(where: { ["occurredAt", "observedAt", "producedAt"].contains($0.name) && previous[$0.name] != values[$0.name] }) { usesCurrentTime = false }
            if draft == nil { draft = ProductionDraft(fields: values) }
            draft?.fields = values
            draft?.updatedAt = .now
            try persist()
        } catch { failure = "草稿未能保存：\(error.localizedDescription)" }
    }

    func recover() {
        do {
            guard let draft = pendingRecovery ?? draft else { return }
            isApplyingFields = true
            for field in fields { if let data = draft.fields[field.name] { try field.restore(data) } }
            pendingRecovery = nil
            hasRecoverableDraft = false
            usesCurrentTime = draft.usesCurrentTime ?? false
            recoveryNotice = "已恢复草稿，请核对对象、发生时间和库存；保存前会重新校验。"
            focusRevision &+= 1
        } catch { failure = error.localizedDescription }
    }

    func discard() {
        do {
            if let key { try store.remove(key) }
            draft = nil
            pendingRecovery = nil
            hasRecoverableDraft = false
            usesCurrentTime = true
            isApplyingFields = true
            for field in initialFields { field.reset() }
            baseline = try snapshot()
        } catch { failure = error.localizedDescription }
    }

    func begin(continuing: Bool) -> Bool {
        guard isReady, pendingRecovery == nil, !isSubmitting, !isApplyingFields else { return false }
        if usesCurrentTime && fields.contains(where: { ["occurredAt", "observedAt", "producedAt"].contains($0.name) }) {
            do {
                isApplyingFields = true
                for field in fields where ["occurredAt", "observedAt", "producedAt"].contains(field.name) {
                    try field.restore(JSONEncoder().encode(Date.now))
                }
            } catch { failure = error.localizedDescription; isApplyingFields = false; return false }
        }
        continuesAfterSave = continuing
        failure = nil
        isSubmitting = true
        return true
    }

    func holdSubmission() { deferredSubmission = true }

    func endAttempt() { if !deferredSubmission { isSubmitting = false } }

    func cancelDeferredSubmission() { deferredSubmission = false; isSubmitting = false }

    func complete() {
        do {
            if let key { try store.remove(key) }
            draft = nil
            statusText = (submittedSummary.map { $0 + " · " } ?? "") + "本机已接收"
            if continuesAfterSave {
                isApplyingFields = true
                for field in initialFields where !field.carriesForward { field.reset() }
                if usesCurrentTime {
                    for field in fields where ["occurredAt", "observedAt", "producedAt"].contains(field.name) {
                        try field.restore(JSONEncoder().encode(Date.now))
                    }
                }
                baseline = try snapshot()
                focusRevision &+= 1
            }
            baseline = try snapshot()
            deferredSubmission = false
            isSubmitting = false
            completionRevision &+= 1
        } catch { failure = error.localizedDescription; isSubmitting = false }
    }

    func execute(_ command: FarmCommand, in farm: FarmContext, context: ModelContext) throws {
        try executeBatch([command], in: farm, context: context)
    }

    func executeBatch(_ commands: [FarmCommand], in farm: FarmContext, context: ModelContext) throws {
        guard let key, let appSession,
              appSession.activeAccountProfileID == accountProfileID,
              appSession.selectedFarmID == key.farmID,
              farm.accountID == key.accountID, farm.farmID == key.farmID else { throw ProductionDraftError.contextChanged }
        let farmID = farm.farmID
        guard let currentFarm = try context.fetch(FetchDescriptor<FarmRecord>(predicate: #Predicate { $0.id == farmID && $0.deletedAt == nil })).first,
              currentFarm.membershipStatusRawValue == "active",
              CapabilitySet(role: currentFarm.role).allows(.recordProduction) else { throw ProductionDraftError.contextChanged }
        let values = try snapshot()
        if draft == nil { draft = ProductionDraft(fields: values) }
        draft?.fields = values
        if draft?.requestIDs.isEmpty == true { draft?.requestIDs = commands.map { _ in UUID() } }
        if draft?.requestIDs.count != commands.count {
            let oldIDs = Set(draft?.requestIDs ?? [])
            let existing = try context.fetch(FetchDescriptor<InsightExecutionReceiptRecord>()).contains { oldIDs.contains($0.sourceRequestID) && $0.farmID == key.farmID && $0.accountID == key.accountID }
            guard !existing else { throw ProductionDraftError.incompleteRecovery }
            draft?.requestIDs = commands.map { _ in UUID() }
        }
        guard let ids = draft?.requestIDs else { throw ProductionDraftError.incompleteRecovery }
        var summaryParts: [String] = []
        for field in fields where ["kilograms", "weanWeight", "amount", "totalKilogramsText", "actualRemaining", "earTag"].contains(field.name) {
            if let data = try? field.read(), let text = try? JSONDecoder().decode(String.self, from: data), !text.isEmpty { summaryParts.append(text) }
        }
        for field in fields where ["sheepID", "eweID"].contains(field.name) {
            if let data = try? field.read(), let id = try? JSONDecoder().decode(UUID.self, from: data),
               let sheep = try context.fetch(FetchDescriptor<SheepRecord>(predicate: #Predicate { $0.id == id && $0.farmID == farmID })).first { summaryParts.insert(sheep.earTag, at: 0) }
        }
        for field in fields where ["selected", "selectedIDs"].contains(field.name) {
            if let data = try? field.read(), let ids = try? JSONDecoder().decode(Set<UUID>.self, from: data), !ids.isEmpty {
                summaryParts.insert("\(ids.count) 只羊", at: 0)
            }
        }
        if let field = fields.first(where: { $0.name == "penID" }), let data = try? field.read(), let id = try? JSONDecoder().decode(UUID.self, from: data),
           let pen = try context.fetch(FetchDescriptor<PenRecord>(predicate: #Predicate { $0.id == id && $0.farmID == farmID })).first {
            summaryParts.insert(pen.name, at: 0)
        }
        submittedSummary = summaryParts.isEmpty ? "上一条记录" : summaryParts.joined(separator: " · ")
        try persist()
        let freshContext = FarmContext(accountID: farm.accountID, farmID: farm.farmID, role: currentFarm.role, grantedWorkerCapabilities: farm.capabilities.grantedWorkerCapabilities)
        lastReceipts = try FarmCommandService().executeBatch(Array(zip(commands, ids)).map { (command: $0.0, sourceRequestID: $0.1) }, in: freshContext, context: context)
    }

    func produceTMRBatch(_ value: TMRBatchProductionDraft, in farm: FarmContext, context: ModelContext) throws {
        try execute(.tmr(.produceBatch(value)), in: farm, context: context)
    }

    func recordTMRFeeding(_ value: TMRFeedingRunDraft, in farm: FarmContext, context: ModelContext) throws {
        try execute(.tmr(.recordFeeding(value)), in: farm, context: context)
    }

    func refreshStatus(context: ModelContext) {
        guard !lastReceipts.isEmpty else { return }
        let operationIDs = Set(lastReceipts.map(\.operationID))
        do {
            let intents = try context.fetch(FetchDescriptor<ESheepCloudPendingIntent>()).filter { operationIDs.contains($0.id) }
            let prefix = submittedSummary.map { $0 + " · " } ?? ""
            if intents.count == operationIDs.count {
                if intents.contains(where: { $0.lifecycle == .needsConfirmation || $0.lifecycle == .rejected || $0.lifecycle == .supersededLocally }) {
                    statusText = prefix + "需要处理，请打开首页保存状态"
                } else if intents.allSatisfy({ $0.lifecycle == .accepted }) {
                    statusText = prefix + "云端已确认"
                } else { statusText = prefix + "本机已接收，等待云端确认" }
            } else {
                let outbox = try context.fetch(FetchDescriptor<OutboxItem>()).filter { operationIDs.contains($0.operationID) }
                if outbox.count == operationIDs.count {
                    if outbox.allSatisfy({ $0.status == .notRequiredLocalOnly }) {
                        statusText = prefix + "已保存到本机"
                    } else if outbox.allSatisfy({ $0.status == .confirmed }) {
                        statusText = prefix + "云端已确认"
                    } else if outbox.contains(where: { [.retryableFailure, .blockedConflict, .rejectedPermission, .quarantinedMembershipRevoked].contains($0.status) }) {
                        statusText = prefix + "需要处理，请打开首页保存状态"
                    } else { statusText = prefix + "本机已接收，等待云端确认" }
                } else if let key, try context.fetch(FetchDescriptor<FarmStorageProfile>()).contains(where: { $0.farmID == key.farmID && $0.mode == .localOnly }) {
                    statusText = prefix + "已保存到本机"
                } else { statusText = prefix + "本机已接收，云保存状态尚未确认" }
            }
        } catch { statusText = "本机已接收，暂时无法读取云保存状态" }
    }

    private func snapshot() throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: fields.map { ($0.name, try $0.read()) })
    }

    func persist() throws {
        draft?.usesCurrentTime = usesCurrentTime
        if let key, let draft { try store.save(draft, for: key) }
    }
}

struct ProductionEntryFeedback: View {
    let session: ProductionEntrySession

    var body: some View {
        if session.failure != nil || session.recoveryNotice != nil || session.statusText != nil {
            Section {
                if let failure = session.failure { Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                if let notice = session.recoveryNotice { Text(notice).foregroundStyle(.secondary) }
                if let status = session.statusText { Text(status).foregroundStyle(.secondary) }
            }
            .font(.footnote)
        }
    }
}

private struct ProductionEntryModifier: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.productionEntryPrefill) private var prefill
    @Environment(AppSession.self) private var appSession
    let session: ProductionEntrySession
    let form: String
    let account: AccountProfile
    let farm: FarmRecord
    let fields: [ProductionDraftField]
    let save: () -> Void
    @State private var showsExit = false
    @State private var savesAndContinues = false

    private var snapshot: [Data] { fields.map { (try? $0.read()) ?? Data() } }

    func body(content: Content) -> some View {
        @Bindable var session = session
        content
            .disabled(session.isSubmitting)
            .environment(\.productionEntryFocusRevision, session.focusRevision)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .interactiveDismissDisabled(session.hasChanges || session.hasRecoverableDraft)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { if session.hasChanges { showsExit = true } else { dismiss() } }
                        .disabled(session.isSubmitting)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("保存选项", systemImage: "ellipsis") {
                        Toggle("保存后继续录入", isOn: $savesAndContinues)
                    }
                    .disabled(session.isSubmitting || !session.isReady || session.hasRecoverableDraft)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(savesAndContinues ? "保存并继续" : "保存") {
                        performSave(continuing: savesAndContinues)
                    }
                    .disabled(session.isSubmitting || !session.isReady || session.hasRecoverableDraft)
                    .accessibilityHint(savesAndContinues ? "保存后清空对象与结果，继续下一条" : "保存后返回")
                }
            }
            .onAppear { session.configure(form: form, account: account, farm: farm, fields: fields, appSession: appSession, context: context, prefill: prefill) }
            .onChange(of: snapshot) { _, _ in
                session.update(fields: fields)
                if session.isApplyingFields {
                    DispatchQueue.main.async { session.isApplyingFields = false; session.update(fields: fields) }
                }
            }
            .onChange(of: scenePhase) { _, phase in if phase != .active { session.update(fields: fields) } }
            .onChange(of: session.usesCurrentTime) { _, _ in
                do { try session.persist() } catch { session.failure = "草稿未能保存：\(error.localizedDescription)" }
            }
            .onDisappear { session.update(fields: fields) }
            .sensoryFeedback(.success, trigger: session.completionRevision)
            .onChange(of: session.completionRevision) { _, _ in session.refreshStatus(context: context); if !session.continuesAfterSave { dismiss() } }
            .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { _ in session.refreshStatus(context: context) }
            .onChange(of: appSession.selectedFarmID) { _, value in if value != farm.id { session.update(fields: fields); dismiss() } }
            .onChange(of: appSession.activeAccountProfileID) { _, value in if value != account.id { session.update(fields: fields); dismiss() } }
            .confirmationDialog("发现未完成的草稿", isPresented: $session.hasRecoverableDraft, titleVisibility: .visible) {
                Button("继续草稿") { session.recover() }
                Button("新建并替换", role: .destructive) { session.discard() }
                Button("返回", role: .cancel) { dismiss() }
            }
            .confirmationDialog("保留未完成的输入？", isPresented: $showsExit, titleVisibility: .visible) {
                Button("保存草稿并退出") {
                    session.update(fields: fields)
                    do { try session.persist(); dismiss() } catch { session.failure = error.localizedDescription }
                }
                Button("放弃修改", role: .destructive) { session.discard(); dismiss() }
                Button("继续填写", role: .cancel) { }
            }
    }

    private func performSave(continuing: Bool) {
        session.update(fields: fields)
        guard session.begin(continuing: continuing) else { return }
        save()
        session.endAttempt()
    }
}

extension View {
    func productionEntry(_ session: ProductionEntrySession, form: String, account: AccountProfile, farm: FarmRecord, fields: [ProductionDraftField], save: @escaping () -> Void) -> some View {
        modifier(ProductionEntryModifier(session: session, form: form, account: account, farm: farm, fields: fields, save: save))
    }
}

/// Persistent field names and units remain visible while entering production results.
struct ProductionValueField: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @FocusState private var localFocus: Bool
    let title: String
    @Binding var text: String
    var unit: String = ""
    var keyboard: UIKeyboardType = .decimalPad
    var focus: FocusState<Bool>.Binding? = nil

    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        layout {
            Text(title).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                TextField("填写", text: $text)
                    .keyboardType(keyboard)
                    .focused(focus ?? $localFocus)
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel(title)
                    .accessibilityHint(unit)
                if !unit.isEmpty { Text(unit).foregroundStyle(.secondary).fixedSize() }
            }
        }
    }
}

struct ProductionTimeModeControl: View {
    @Bindable var session: ProductionEntrySession

    var body: some View {
        HStack {
            Text("时间模式").foregroundStyle(.secondary)
            Spacer()
            Menu {
                Button("保存时使用当前时间") { session.usesCurrentTime = true }
                Button("使用上方填写的时间") { session.usesCurrentTime = false }
            } label: {
                Text(session.usesCurrentTime ? "保存时的当前时间" : "使用上方时间")
            }
            .disabled(session.isSubmitting)
        }
        .font(.footnote)
    }
}
