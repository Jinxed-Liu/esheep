import SwiftUI
import XCTest
@testable import eSheepNext

/// Visual evidence uses the same SwiftUI surface as the extension, with explicit
/// fixtures. It does not claim SpringBoard or physical-device acceptance.
@MainActor
final class FarmWidgetVisualTests: XCTestCase {
    func testLightWidgetGallery() throws { try render(scheme: .light, name: "widgets-light") }
    func testDarkWidgetGallery() throws { try render(scheme: .dark, name: "widgets-dark") }

    func testColorfulLightGallery() throws { try renderColorful(scheme: .light, name: "colorful-light") }
    func testColorfulDarkGallery() throws { try renderColorful(scheme: .dark, name: "colorful-dark") }

    private func renderColorful(scheme: ColorScheme, name: String) throws {
        let time = ISO8601DateFormatter().date(from: "2026-09-22T04:00:00Z")!
        let content = VStack(alignment: .leading, spacing: 18) {
            ForEach(FarmWidgetPalette.colorful) { palette in
                VStack(alignment: .leading, spacing: 8) {
                    Text(palette.title).font(.headline)
                    HStack(spacing: 18) {
                        self.surface(kind: palette.suggestedKind, medium: false, time: time, palette: palette)
                        self.surface(kind: palette.suggestedKind, medium: true, time: time, palette: palette)
                    }
                }
            }
        }
        .padding(20).background(Color(uiColor: .systemGroupedBackground))
        .environment(\.colorScheme, scheme).environment(\.locale, Locale(identifier: "zh_CN"))
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage)
        XCTAssertGreaterThan(image.size.height, 700)
        let attachment = XCTAttachment(image: image)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func render(scheme: ColorScheme, name: String) throws {
        let time = ISO8601DateFormatter().date(from: "2026-09-22T04:00:00Z")!
        let content = VStack(alignment: .leading, spacing: 18) {
            ForEach(FarmWidgetKind.allCases) { kind in
                VStack(alignment: .leading, spacing: 8) {
                    Text(kind.title).font(.headline)
                    HStack(spacing: 18) {
                        self.surface(kind: kind, medium: false, time: time)
                        self.surface(kind: kind, medium: true, time: time)
                    }
                }
            }
        }
        .padding(20)
        .background(Color(uiColor: .systemGroupedBackground))
        .environment(\.colorScheme, scheme)
        .environment(\.locale, Locale(identifier: "zh_CN"))
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage)
        XCTAssertGreaterThan(image.size.height, 2000)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    private func surface(kind: FarmWidgetKind, medium: Bool, time: Date, palette: FarmWidgetPalette? = nil) -> some View {
        var card = fixture(kind)
        card.palette = palette ?? kind.defaultPalette
        return FarmWidgetCardView(card: card, farmName: "青禾牧场", generatedAt: time, medium: medium)
            .padding(16).frame(width: medium ? 364 : 174, height: 174)
            .background { FarmWidgetBackground(palette: palette ?? kind.defaultPalette) }
            .clipShape(.rect(cornerRadius: 25))
    }
    private func fixture(_ kind: FarmWidgetKind) -> FarmWidgetCard {
        var card = FarmWidgetCard(kind: kind, palette: kind.defaultPalette, title: kind.title, subtitle: "当前在场",
                                 value: "1,286", unit: "只", note: "本机数据快照",
                                 rows: [.init(label: "在用圈舍", value: "24 个"), .init(label: "今日投喂", value: "8 条")])
        switch kind {
        case .journal:
            card.subtitle = "今日投喂记录"; card.value = "8"; card.unit = "条"
            card.note = "按记录条数统计"
        case .breeding:
            card.subtitle = "未来 7 天预产提醒"; card.value = "6"; card.unit = "条"
            card.note = "预产日期为估算 · 按提醒条数"
            card.upcomingDates = ["2026-09-22T04:00:00Z", "2026-09-24T04:00:00Z", "2026-09-26T04:00:00Z"].compactMap { ISO8601DateFormatter().date(from: $0) }
            card.rows = [.init(label: "今日预产提醒", value: "2 条"), .init(label: "涉及母羊", value: "6 只")]
        case .pregnancy, .weaning, .alerts:
            card.subtitle = "到期与逾期提醒"; card.value = "7"; card.unit = "项"
            card.note = "沿用牧场已配置的提醒规则"
            card.rows = [.init(label: "即将到期", value: "5 项"), .init(label: "已逾期", value: "2 项")]
        case .feeding:
            card.title = "03 舍"; card.subtitle = "计划中已有投喂量的顿数"; card.value = "2"; card.unit = "/ 3 顿"
            card.progress = 2.0/3; card.note = "记录覆盖不代表投喂达标"
            card.rows = [.init(label: "早 · 实投/目标", value: "120/120 kg"), .init(label: "中 · 实投/目标", value: "116/120 kg"), .init(label: "晚 · 实投/目标", value: "0/120 kg")]
        case .coverage, .gain:
            card.title = kind == .gain ? "秋季育肥批次" : "03 舍"
            card.subtitle = kind == .gain ? "期间平均日增重" : "当前在场羊只 · 已称重"
            card.value = kind == .gain ? "280" : "86"; card.unit = kind == .gain ? "g/天" : "/ 100 只"
            card.progress = kind == .coverage ? 0.86 : nil
            card.rows = [.init(label: "可计算 / 期间对象", value: "72 / 100 只"), .init(label: "当前名单已称重", value: "86 / 100 只")]
            if kind == .coverage { card.rows = [.init(label: "尚未称重", value: "14 只"), .init(label: "当前在场", value: "100 只")] }
            card.note = kind == .gain ? "批次期间表现 · 逐羊等权平均" : "当前名单 · 期间有效称重去重"
            card.rangeStart = Date(timeIntervalSince1970: 1789488000); card.rangeEnd = Date(timeIntervalSince1970: 1790006400)
        case .sync:
            card.subtitle = "本机待同步指令"; card.value = "2"; card.unit = "项"
            card.note = "不包含照片传输 · 非云端确认"
            card.rows = [.init(label: "数据来源", value: "本机快照"), .init(label: "云端状态", value: "进入 App 查看")]
        default: break
        }
        return card
    }
}
