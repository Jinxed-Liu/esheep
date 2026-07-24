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
                ("数据与可用性", "本机数据可离线使用；云端同步依赖 Apple iCloud 和网络服务。同步故障不会被描述为保存成功，应用会保留待处理状态。"),
                ("订阅", "牧场 Pro 由 App Store 提供月度或年度自动续期订阅。订阅到期不会锁定已有数据、员工基础录入、查看或导出。"),
                ("责任边界", "养殖分析用于生产辅助，不替代兽医诊断、法规要求或用户的现场判断。"),
            ]
        case .privacy:
            [
                ("收集范围", "应用处理账号标识、设备身份、牧场生产数据和用户主动添加的照片。应用不投放广告、不跨 App 跟踪，也不出售个人信息。"),
                ("用途", "数据仅用于登录、离线记录、用户授权的牧场协作、恢复、订阅校验和故障诊断。"),
                ("存储与共享", "不同牧场的数据彼此隔离。启用云协作后，受邀成员只能在其角色允许的范围内查看或操作当前牧场。"),
                ("控制权", "用户可导出数据、退出共享牧场或申请删除账户。账户删除会撤销服务端会话、设备和共享关系；自有云端牧场需先处理。"),
            ]
        case .iCloud:
            [
                ("使用方式", "启用云协作后，当前牧场会保存到你的 iCloud，并可通过系统共享邀请指定成员。每个牧场的数据彼此独立。"),
                ("旧版牧场导入", "导入旧版数据时，应用会先在本机完整检查；确认成功后再保存并同步。网络不可用时仍可继续使用本机数据。"),
                ("删除与恢复", "退出共享牧场后，本机会移除该牧场的共享数据。牧场主可使用恢复包或恢复点找回数据；iCloud 账户状态和网络会影响同步时效。"),
            ]
        }
    }
}

struct LegalDocumentView: View {
    let document: LegalDocument

    var body: some View {
        List {
            Section {
                Text("生效版本：3.0.0")
                Text("更新日期：2026 年 7 月 18 日")
            }
            ForEach(Array(document.sections.enumerated()), id: \.offset) { _, section in
                Section(section.heading) {
                    Text(section.body)
                }
            }
        }
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
