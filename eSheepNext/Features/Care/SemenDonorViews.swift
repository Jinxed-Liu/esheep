import SwiftData
import SwiftUI

private struct SemenDonorEditorDestination: Identifiable {
    let id: UUID
}

struct SemenDonorManagementView: View {
    @Query(sort: \SemenDonorRecord.name) private var donors: [SemenDonorRecord]
    let account: AccountProfile
    let farm: FarmRecord
    @State private var editor: SemenDonorEditorDestination?

    private var farmDonors: [SemenDonorRecord] {
        donors.filter { $0.farmID == farm.id && $0.deletedAt == nil }
    }

    var body: some View {
        List {
            ForEach(farmDonors, id: \.id) { donor in
                Button { editor = .init(id: donor.id) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(donor.name)
                            if donor.status == .inactive {
                                Text("已停用").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Text([donor.registrationNumber, donor.breed].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .overlay {
            if farmDonors.isEmpty {
                ContentUnavailableView("还没有冻精供体", systemImage: "person.crop.circle.badge.plus", description: Text("供体快照会保留在后代档案中。"))
            }
        }
        .navigationTitle("冻精供体")
        .toolbar {
            Button { editor = .init(id: UUID()) } label: { Image(systemName: "plus") }
                .disabled(!CapabilitySet(role: farm.role).allows(.manageCatalogs))
        }
        .sheet(item: $editor) { destination in
            NavigationStack {
                SemenDonorEditorView(account: account, farm: farm, donorID: destination.id)
            }
        }
        .farmExcelImport(account: account, farm: farm, sheets: ["冻精供体"])
    }
}

private struct SemenDonorEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var donors: [SemenDonorRecord]
    @Query(sort: \SheepRecord.earTag) private var sheep: [SheepRecord]
    @Query(sort: \SemenRecord.code) private var semen: [SemenRecord]

    let account: AccountProfile
    let farm: FarmRecord
    let donorID: UUID

    @State private var name = ""
    @State private var registrationNumber = ""
    @State private var breed = ""
    @State private var linkedRamID: UUID?
    @State private var note = ""
    @State private var status = SemenDonorStatus.active
    @State private var errorMessage: String?
    private let service = FarmCommandService()

    private var existing: SemenDonorRecord? { donors.first { $0.id == donorID && $0.farmID == farm.id && $0.deletedAt == nil } }
    private var breedingRams: [SheepRecord] {
        sheep.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.sex == .ram && $0.isBreedingRam }
    }
    private var descendants: [SheepRecord] {
        sheep.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.semenDonorID == donorID }
    }
    private var linkedSemen: [SemenRecord] {
        semen.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.donorID == donorID }
    }

    var body: some View {
        Form {
            Section("供体档案") {
                TextField("供体名称", text: $name)
                TextField("登记号", text: $registrationNumber)
                TextField("品种", text: $breed)
                Picker("状态", selection: $status) {
                    ForEach(SemenDonorStatus.allCases, id: \.self) { Text(LocalizedStringKey($0.displayName)).tag($0) }
                }
            }
            Section("本场关联") {
                Picker("关联种公羊", selection: $linkedRamID) {
                    Text("外部供体，不关联").tag(UUID?.none)
                    ForEach(breedingRams, id: \.id) { Text($0.earTag).tag(UUID?.some($0.id)) }
                }
                Text("只能关联已明确标记的种公羊。关联后，后代会同时投影父本羊只并永久保留当时的供体快照。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if existing != nil {
                Section("使用情况") {
                    LabeledContent("冻精批次", value: "\(linkedSemen.count)")
                    LabeledContent("已记录后代", value: "\(descendants.count)")
                    ForEach(descendants, id: \.id) { child in
                        NavigationLink {
                            SheepPedigreeView(account: account, farm: farm, sheepID: child.id)
                        } label: {
                            LabeledContent(child.earTag, value: child.sex.displayName)
                        }
                    }
                }
            }
            Section("备注") { TextField("备注", text: $note, axis: .vertical) }
        }
        .navigationTitle(existing == nil ? "新增供体" : "编辑供体")
        .toolbar { EntrySaveToolbar(action: save) }
        .recordErrorAlert($errorMessage)
        .onAppear(perform: load)
    }

    private func load() {
        guard let existing else { return }
        name = existing.name
        registrationNumber = existing.registrationNumber
        breed = existing.breed
        linkedRamID = existing.linkedRamID
        note = existing.note
        status = existing.status
    }

    private func save() {
        let farmContext = FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role)
        do {
            if let existing {
                try service.execute(
                    .care(.upsertSemenDonor(.init(id: existing.id, name: name, registrationNumber: registrationNumber, breed: breed, linkedRamID: linkedRamID, note: note, status: status, expectedRevision: existing.revision))),
                    in: farmContext,
                    context: modelContext
                )
            } else if let linkedRamID {
                // 分成两个权威操作，云端重建时可先恢复供体，再恢复其本场种公羊引用。
                try service.executeBatch([
                    .care(.upsertSemenDonor(.init(id: donorID, name: name, registrationNumber: registrationNumber, breed: breed, linkedRamID: nil, note: note, status: status, expectedRevision: 0))),
                    .care(.upsertSemenDonor(.init(id: donorID, name: name, registrationNumber: registrationNumber, breed: breed, linkedRamID: linkedRamID, note: note, status: status, expectedRevision: 1))),
                ], in: farmContext, context: modelContext)
            } else {
                try service.execute(
                    .care(.upsertSemenDonor(.init(id: donorID, name: name, registrationNumber: registrationNumber, breed: breed, linkedRamID: nil, note: note, status: status, expectedRevision: 0))),
                    in: farmContext,
                    context: modelContext
                )
            }
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
