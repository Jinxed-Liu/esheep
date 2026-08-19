import SwiftUI

enum LegalDocument: String, CaseIterable, Identifiable {
    case terms
    case privacy
    case iCloud

    var id: String { rawValue }

    var title: String {
        switch self {
        case .terms: "服务条款"
        case .privacy: "隐私政策"
        case .iCloud: "iCloud 数据说明"
        }
    }

    var systemImage: String {
        switch self {
        case .terms: "doc.text"
        case .privacy: "hand.raised"
        case .iCloud: "icloud"
        }
    }

    var sections: [(heading: String, body: String)] {
        switch self {
        case .terms:
            [
                ("适用范围", "eSheep+ 用于牧场生产记录、分析和协作。用户应确保录入内容合法、准确，并妥善管理成员权限。"),
                ("数据与可用性", "本机数据可离线使用；云端同步依赖 Supabase 和网络服务。同步故障不会被描述为保存成功，应用会保留待处理状态。"),
                ("费用", "eSheep+ 3.1 首发版本完全免费，不提供 App 内购买或自动续期订阅。"),
                ("责任边界", "养殖分析用于生产辅助，不替代兽医诊断、法规要求或用户的现场判断。"),
            ]
        case .privacy:
            [
                ("收集范围", "应用处理账号标识、设备身份、牧场生产数据和用户主动添加的照片。应用不投放广告、不跨 App 跟踪，也不出售个人信息。"),
                ("用途", "数据仅用于登录、离线记录、用户授权的牧场协作、恢复和故障诊断。"),
                ("存储与共享", "不同牧场的数据彼此隔离。启用云协作后，受邀成员只能在其角色允许的范围内查看或操作当前牧场。"),
                ("控制权", "用户可导出数据、退出共享牧场或申请删除账户。账户删除会撤销服务端会话、设备和共享关系；自有云端牧场需先处理。"),
            ]
        case .iCloud:
            [
                ("使用方式", "CloudKit 仅用于读取和迁移旧牧场。3.1 新建云端牧场以 Supabase 为权威；每个牧场的数据彼此独立。"),
                ("旧版牧场导入", "迁移旧版牧场时，应用会先在本机完整检查，再按用户确认逐牧场上传、核对并切换权威。网络不可用时可续跑，不会自动切回。"),
                ("删除与恢复", "退出共享牧场后，本机会移除该牧场的共享数据。牧场主可使用恢复包或 Supabase 检查点找回数据；服务状态和网络会影响同步时效。"),
            ]
        }
    }
}

struct LegalDocumentView: View {
    let document: LegalDocument

    var body: some View {
        List {
            Section {
                Text("生效版本：3.1.0")
                Text("更新日期：2026 年 8 月 18 日")
            }
            ForEach(Array(document.sections.enumerated()), id: \.offset) { _, section in
                Section(LocalizedStringKey(section.heading)) {
                    Text(LocalizedStringKey(section.body))
                }
            }
        }
        .navigationTitle(LocalizedStringKey(document.title))
        .navigationBarTitleDisplayMode(.inline)
    }
}
