import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct LegacyFeedMergeView: View {
    @Environment(\.modelContext) private var modelContext
    let account: AccountProfile
    let farm: FarmRecord

    @State private var isSelectingFile = false
    @State private var preview: LegacyFeedMergePreview?
    @State private var isConfirmationPresented = false
    @State private var errorMessage: String?
    @State private var result: LegacyFeedMergeResult?

    var body: some View {
        List {
            Section("安全范围") {
                Label("只新增当前牧场缺失的投喂记录", systemImage: "checkmark.shield")
                Text("不会覆盖或删除羊只、圈舍、繁殖、健康、现有原料批次和库存；历史投喂也不会追溯扣库存。旧文件最多只能补入尚缺的旧投喂，不能抹掉新记录。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("选择来源") {
                Button("选择 Plus 当前牧场最新导出文件") { isSelectingFile = true }
                Text("建议先在 eSheep+ 当前牧场导出最新 JSON。文件日期会显示在预览中，确认后才会写入。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let preview {
                Section("合并预览") {
                    LabeledContent("文件", value: preview.sourceFileName)
                    if let date = preview.sourceFileDate {
                        LabeledContent("文件日期") { Text(date, format: .dateTime.year().month().day().hour().minute()) }
                    }
                    LabeledContent("Plus 投喂记录", value: "\(preview.sourceRecordCount)")
                    LabeledContent("将新增", value: "\(preview.newFeeds.count)")
                    LabeledContent("已存在／重复", value: "\(preview.duplicateCount)")
                    LabeledContent("需补建历史原料", value: "\(preview.newIngredientCount)")
                    LabeledContent("来源校验", value: String(preview.sourceChecksum.prefix(12)))
                }

                if !preview.unmatchedPenNames.isEmpty {
                    Section("圈舍未对应") {
                        ForEach(preview.unmatchedPenNames, id: \.self) { Text($0).foregroundStyle(.red) }
                        Text("定向合并不会自动新建或改名圈舍。请先核对当前牧场圈舍名称，再重新选择文件。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button("确认仅合并 \(preview.newFeeds.count) 条投喂") { isConfirmationPresented = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(!preview.canCommit)
                    if preview.newFeeds.isEmpty && preview.unmatchedPenNames.isEmpty {
                        Text("这份文件中的投喂记录已全部存在，没有需要写入的数据。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("首次完整迁移") {
                Text("完整迁移只用于尚未建立 Next 牧场的首次建场。当前牧场不提供完整覆盖入口。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("合并 Plus 投喂")
        .fileImporter(isPresented: $isSelectingFile, allowedContentTypes: [.json]) { selection in
            do {
                let url = try selection.get()
                guard url.startAccessingSecurityScopedResource() else { throw CocoaError(.fileReadNoPermission) }
                defer { url.stopAccessingSecurityScopedResource() }
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                preview = try LegacyFeedIncrementalImportService.preview(source: Data(contentsOf: url), sourceFileName: url.lastPathComponent, sourceFileDate: values?.contentModificationDate, farmID: farm.id, context: modelContext)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .confirmationDialog("确认只追加缺失投喂？", isPresented: $isConfirmationPresented, titleVisibility: .visible) {
            Button("确认合并") { commit() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("不会改写当前羊群、圈舍、繁殖、健康和库存。导入的历史投喂保留全舍总量，不产生库存扣减流水。")
        }
        .alert("合并完成", isPresented: Binding(get: { result != nil }, set: { if !$0 { result = nil } })) {
            Button("知道了") { result = nil; preview = nil }
        } message: {
            if let result { Text("新增 \(result.importedFeedCount) 条投喂、\(result.importedLineCount) 条明细，补建 \(result.createdIngredientCount) 个历史原料快照。") }
        }
        .alert("无法合并", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("知道了", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private func commit() {
        guard let preview else { return }
        do {
            result = try LegacyFeedIncrementalImportService.commit(preview, account: account, farm: farm, context: modelContext)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
