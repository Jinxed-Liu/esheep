import Foundation
import SwiftUI
import CoreText

enum SheepPosterFont: String, Codable, CaseIterable, Identifiable {
    case editorial, serif, sans, brush, handwriting
    var id: String { rawValue }
    var title: String {
        switch self {
        case .editorial: "杂志衬线"
        case .serif: "小薇宋体"
        case .sans: "简洁黑体"
        case .brush: "行草笔刷"
        case .handwriting: "毛笔手写"
        }
    }
    /// Latin display fonts do not contain Han glyphs. Resolve Chinese text to
    /// a bundled face instead of silently falling back to the system font.
    func postScriptName(for text: String) -> String? {
        let hasCJK = text.unicodeScalars.contains {
            (0x2E80...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value)
                || (0x20000...0x323AF).contains($0.value)
        }
        switch self {
        case .editorial: return hasCJK ? "NotoSerifSC-Bold" : "Didot-Bold"
        case .serif: return "ZCOOLXiaoWei-Regular"
        case .sans: return nil
        case .brush: return hasCJK ? "ZhiMangXing-Regular" : "Knewave-Regular"
        case .handwriting: return "MaShanZheng-Regular"
        }
    }
    func font(size: CGFloat, text: String = "") -> Font {
        SheepSharePosterTypography.register()
        guard let name = postScriptName(for: text) else { return .system(size: size, weight: .medium) }
        return .custom(name, fixedSize: size)
    }
}

struct SheepPosterColor: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var color: Color { Color(red: red, green: green, blue: blue) }
    static let cream = Self(red: 0.98, green: 0.97, blue: 0.91)
    static let navy = Self(red: 0.025, green: 0.12, blue: 0.22)
    static let yellow = Self(red: 0.98, green: 0.82, blue: 0.18)
    static let sky = Self(red: 0.24, green: 0.58, blue: 0.79)
}

struct SheepPosterElementOverride: Codable, Equatable {
    var x: Double?
    var y: Double?
    var width: Double?
    var height: Double?
    var rotation: Double?
    var opacity: Double?
    var fontSize: Double?
    var font: SheepPosterFont?
    var color: SheepPosterColor?
    var text: String?
    var isHidden = false
    var layerOrder: Double?
    var imageData: Data?
    var photoZoom: Double?
    var photoX: Double?
    var photoY: Double?
    var centered: Bool?
    var tracking: Double?
}

enum SheepPosterElementKind: String, Codable {
    case text, photo, photoBackdrop, logo, image, rule, brush, mountains, shade
    var isImage: Bool { self == .photo || self == .photoBackdrop || self == .logo || self == .image }
}

struct SheepPosterElement: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var kind: SheepPosterElementKind = .text
    var text = ""
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var font: SheepPosterFont = .sans
    var fontSize: Double = 12
    var color: SheepPosterColor = .cream
    var rotation: Double = 0
    var opacity: Double = 1
    var order: Double = 10
    var centered = false
    var tracking: Double = 0
    var isHidden = false
    var imageData: Data?
    var photoZoom: Double = 1
    var photoX: Double = 0
    var photoY: Double = 0

    func applying(_ value: SheepPosterElementOverride?) -> Self {
        guard let value else { return self }
        var result = self
        result.x = value.x ?? x
        result.y = value.y ?? y
        result.width = value.width ?? width
        result.height = value.height ?? height
        result.rotation = value.rotation ?? rotation
        result.opacity = value.opacity ?? opacity
        result.fontSize = value.fontSize ?? fontSize
        result.font = value.font ?? font
        result.color = value.color ?? color
        result.text = value.text ?? text
        result.isHidden = value.isHidden
        result.order = value.layerOrder ?? order
        result.imageData = value.imageData ?? imageData
        result.photoZoom = value.photoZoom ?? photoZoom
        result.photoX = value.photoX ?? photoX
        result.photoY = value.photoY ?? photoY
        result.centered = value.centered ?? centered
        result.tracking = value.tracking ?? tracking
        return result
    }
}

struct SheepSharePosterCustomization: Codable, Equatable {
    var overrides: [String: SheepPosterElementOverride] = [:]
    var additions: [SheepPosterElement] = []
    var background: SheepPosterColor?
    var photoData: Data?

    func elements(from defaults: [SheepPosterElement]) -> [SheepPosterElement] {
        let resolved = (defaults + additions).map { $0.applying(overrides[$0.id]) }
        return SheepPosterNameAlignment.resolve(resolved, overrides: overrides)
            .sorted { $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order }
    }

    /// Built-in text is a live field from the selected sheep. Only the design
    /// and user-added captions are reusable; animal-specific edits stay here.
    var reusable: Self {
        var result = self
        result.photoData = nil
        let liveFields: Set<String> = ["farm", "farm.signature", "farm.latinName", "farm.latinSignature", "masthead.caption", "footer.caption", "earTag", "breed", "role",
                                       "sex", "status", "date.value", "lastLambing.value"]
        for id in result.overrides.keys {
            if liveFields.contains(id) || (id.hasPrefix("family.") && id.hasSuffix(".earTag"))
                || (id.hasPrefix("metric.") && id.hasSuffix(".value"))
                || (id.hasPrefix("identity.") && id.hasSuffix(".value")) {
                result.overrides[id]?.text = nil
            }
            if id == "photo" || id == "photo.backdrop" {
                result.overrides[id]?.imageData = nil
            }
        }
        return result
    }
}

/// A name pair uses actual font advances, not character-count thresholds.
/// Explicit edits of the subtitle's layout win over automatic placement.
enum SheepPosterNameAlignment {
    static func width(_ element: SheepPosterElement) -> Double {
        SheepSharePosterTypography.register()
        let font = element.font.postScriptName(for: element.text).map {
            CTFontCreateWithName($0 as CFString, element.fontSize, nil)
        } ?? CTFontCreateUIFontForLanguage(.system, element.fontSize, nil)!
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTKernAttributeName as String): element.tracking
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: element.text, attributes: attributes))
        return max(0, CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    static func resolve(_ elements: [SheepPosterElement],
                        overrides: [String: SheepPosterElementOverride]) -> [SheepPosterElement] {
        var result = elements
        for (nameID, latinID) in [("farm", "farm.latinName"), ("farm.signature", "farm.latinSignature")] {
            guard let nameIndex = result.firstIndex(where: { $0.id == nameID }),
                  let latinIndex = result.firstIndex(where: { $0.id == latinID }) else { continue }
            var name = result[nameIndex]
            var latin = result[latinIndex]
            let manual = overrides[latinID]
            // Match the actual one-line width after fitting inside the user's box.
            let naturalWidth = width(name)
            if naturalWidth > name.width, naturalWidth > 0 {
                let scale = max(1, name.width) / naturalWidth
                name.fontSize *= scale
                name.tracking *= scale
            }
            let nameWidth = min(name.width, width(name))
            let left = name.x + (name.centered ? (name.width - nameWidth) / 2 : 0)
            if manual?.width == nil { latin.width = max(1, nameWidth) }
            if manual?.fontSize == nil {
                let naturalLatinWidth = width(latin)
                if naturalLatinWidth > latin.width {
                    latin.fontSize *= latin.width / naturalLatinWidth
                    latin.tracking *= latin.width / naturalLatinWidth
                }
            }
            if manual?.tracking == nil, latin.text.count > 1 {
                // Add modest spacing to a shorter Latin line, without stretching
                // very short names into widely separated letters.
                latin.tracking += min(2, max(0, latin.width - width(latin)) / Double(latin.text.count))
            }
            if manual?.height == nil { latin.height = max(10, ceil(latin.fontSize * 1.4)) }
            if manual?.centered == nil { latin.centered = false }
            let lineHeight = min(name.height, name.fontSize * 1.4)
            let unrotatedX = left + latin.width / 2
            let unrotatedY = name.y + name.height / 2 + lineHeight / 2 + 3 + latin.height / 2
            let pivotX = name.x + name.width / 2
            let pivotY = name.y + name.height / 2
            let angle = name.rotation * .pi / 180
            let dx = unrotatedX - pivotX, dy = unrotatedY - pivotY
            if manual?.x == nil { latin.x = pivotX + dx * cos(angle) - dy * sin(angle) - latin.width / 2 }
            if manual?.y == nil { latin.y = pivotY + dx * sin(angle) + dy * cos(angle) - latin.height / 2 }
            if manual?.rotation == nil { latin.rotation = name.rotation }
            result[nameIndex] = name
            result[latinIndex] = latin
        }
        return result
    }
}

struct SheepSharePosterSavedTemplate: Identifiable, Codable {
    let id: UUID
    var name: String
    var style: String
    var template: String
    var customization: SheepSharePosterCustomization
    var updatedAt: Date
}

enum SheepSharePosterTemplateStore {
    static var fileURL: URL {
        #if DEBUG
        if let directory = DevelopmentPosterAcceptance.directory {
            return directory.appending(path: "templates-v1.json")
        }
        #endif
        return URL.applicationSupportDirectory
            .appending(path: "SheepPosterTemplates", directoryHint: .isDirectory)
            .appending(path: "templates-v1.json")
    }

    static func load(from url: URL = fileURL) throws -> [SheepSharePosterSavedTemplate] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([SheepSharePosterSavedTemplate].self, from: Data(contentsOf: url))
    }

    static func save(_ templates: [SheepSharePosterSavedTemplate], to url: URL = fileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(templates).write(to: url, options: .atomic)
    }
}

enum SheepSharePosterLayout {
    static func elements(snapshot: SheepSharePosterSnapshot, style: SheepSharePosterStyle,
                         template: SheepSharePosterTemplate) -> [SheepPosterElement] {
        let light = style == .breeding && template.theme == .light
        let ink: SheepPosterColor = light ? .navy : .cream
        let portrait = template.photoLayout == .portrait
        var items: [SheepPosterElement] = []
        func text(_ id: String, _ title: String, _ value: String, _ x: Double, _ y: Double,
                  _ w: Double, _ h: Double, _ size: Double, _ font: SheepPosterFont = .sans,
                  color: SheepPosterColor? = nil, rotation: Double = 0, centered: Bool = false,
                  tracking: Double = 0) {
            items.append(.init(id: id, title: title, text: value, x: x, y: y, width: w, height: h,
                               font: font, fontSize: size, color: color ?? ink, rotation: rotation,
                               centered: centered, tracking: tracking))
        }
        func art(_ id: String, _ title: String, _ kind: SheepPosterElementKind, _ x: Double, _ y: Double,
                 _ w: Double, _ h: Double, color: SheepPosterColor? = nil, order: Double = 1,
                 opacity: Double = 1, rotation: Double = 0) {
            items.append(.init(id: id, title: title, kind: kind, x: x, y: y, width: w, height: h,
                               color: color ?? ink, rotation: rotation, opacity: opacity, order: order))
        }

        if style == .breeding {
            art("photo", "羊只照片", .photo, 0, 222, 360, 245, order: 1)
            art("mountains", "底部山形", .mountains, 0, 545, 360, 95, color: .sky, order: 0)
            art("footer.brush", "底部黄色笔触", .brush, -15, 618, 145, 17, color: .yellow, order: 1,
                opacity: 0.65, rotation: -6)
        } else {
            art("photo.backdrop", "照片背景", .photoBackdrop, 0, 0, 360, 640, order: 0)
            art("photo", "羊只照片", .photo, 0, portrait ? 185 : 275, 360, portrait ? 450 : 335, order: 1)
            art("shade", "光影渐变", .shade, 0, 0, 360, 640,
                color: .init(red: 0.08, green: 0.065, blue: 0.025), order: 2,
                opacity: template.theme == .dark ? 1 : 0.82)
        }
        text("farm", "牧场名称", snapshot.farmName, 22, 20, 228, 26, 18, .serif, tracking: 3)
        text("farm.latinName", "牧场英文名／拼音名", snapshot.farmLatinName ?? "", 23,
             49, 228, 12, 9, .editorial)
        art("logo", "品牌 Logo", .logo, 276, 20, 23, 23, order: 10)
        text("brand", "品牌文字", "eSheep+", 304, 24, 47, 14, 10)
        let breed = snapshot.subject.breed.isEmpty ? String(localized: "未填写") : snapshot.subject.breed
        let status = [snapshot.subject.sex.displayName, snapshot.subject.status.displayName].joined(separator: " · ")

        switch style {
        case .magazine:
            text("earTag", "耳号", snapshot.subject.earTag, 16, 45, 330, 140, 126, .editorial,
                 tracking: snapshot.subject.earTag.count > 10 ? -0.5 : -4)
            text("breed", "品种", breed, 22, 170, 224, 33, 28, .serif)
            text("role", "用途", String(localized: String.LocalizationValue(snapshot.roleTitle)), 22, 203, 220, 28, 22, .serif)
            art("identity.rule", "身份分隔线", .rule, 23, 245, 54, 0.6, order: 10, opacity: 0.6)
            text("sex", "性别", snapshot.subject.sex.displayName, 23, 256, 115, 20, 14, .serif, tracking: 2)
            text("status", "在场状态", snapshot.subject.status.displayName, 23, 277, 115, 20, 14, .serif, tracking: 2)
            text("farm.signature", "牧场手写落款", snapshot.farmName, 22, 553, 300, 45, 38, .handwriting, rotation: -4)
            text("farm.latinSignature", "牧场英文落款", snapshot.farmLatinName ?? "", 24, 608, 270, 14, 10, .editorial)
        case .breeding:
            text("earTag", "耳号", snapshot.subject.earTag, 17, 48, 329, 137, 117, .editorial,
                 tracking: snapshot.subject.earTag.count > 10 ? -0.5 : -4)
            text("breed", "品种", breed, 22, 169, 225, 33, 27, .serif)
            art("identity.rule", "黄色短线", .rule, 23, 207, 32, 2, color: .yellow, order: 10)
            text("role", "用途", String(localized: String.LocalizationValue(snapshot.roleTitle)), 23, 214, 145, 25, 14, .serif)
            text("status", "手写状态", status, 181, 192, 163, 32, 27, .handwriting,
                 color: light ? .sky : .yellow, rotation: -10)
            art("status.brush", "状态下划线", .brush, 182, 226, 160, 3, color: .yellow, order: 10, rotation: -10)
            for (index, metric) in snapshot.posterCardFields.enumerated() {
                let x = 22 + Double(index) * 112
                text("\(metric.id).title", metric.title, String(localized: String.LocalizationValue(metric.title)),
                     x, 476, 98, 14, 9)
                text("\(metric.id).value", metric.title + "数值", metric.value, x, 492, 98, 34,
                     metric.id == "identity.birth" || metric.id == "identity.pen" ? 19 : 27, .editorial)
                if index < 2 {
                    art("\(metric.id).rule", "指标分隔线", .rule, x + 103, 480, 0.5, 41, order: 10, opacity: 0.35)
                }
            }
            let family: [(String, String, SheepSharePosterRelative?, Double, Double)] = [
                ("dam", "母本", snapshot.pedigree.dam, 23, 543),
                ("sire", "父本", snapshot.pedigree.sire, 199, 543),
                ("maternalGranddam", "外祖母", snapshot.pedigree.maternalGranddam, 23, 591),
                ("maternalGrandsire", "外祖父", snapshot.pedigree.maternalGrandsire, 105, 591),
                ("paternalGranddam", "祖母", snapshot.pedigree.paternalGranddam, 199, 591),
                ("paternalGrandsire", "祖父", snapshot.pedigree.paternalGrandsire, 281, 591)
            ]
            for (id, title, relative, x, y) in family {
                let parent = id == "dam" || id == "sire"
                let width: Double = parent ? 138 : 65
                text("family.\(id).title", title + "标签", String(localized: String.LocalizationValue(title)),
                     x, y, width, 11, parent ? 8 : 6, centered: true)
                text("family.\(id).earTag", title + "耳号", relative?.earTag ?? String(localized: "未确认"),
                     x, y + 12, width, parent ? 23 : 16, parent ? 19 : 10, parent ? .editorial : .sans, centered: true)
            }
            for (index, x) in [23.0, 199.0].enumerated() {
                art("family.\(index).rule", "系谱分隔线", .rule, x, 582, 138, 0.5, order: 10, opacity: 0.3)
            }
            if snapshot.subject.sex == .ewe {
                text("lastLambing.title", "上次产羔标签", String(localized: "上次产羔"), 23, 628, 35, 8, 5)
                text("lastLambing.value", "上次产羔日期", snapshot.metrics.lastLambingText, 59, 628, 85, 8, 5)
            }
        case .minimal:
            text("breed", "品种", breed, 23, 79, 208, 24, 16, .serif)
            text("role", "用途", String(localized: String.LocalizationValue(snapshot.roleTitle)), 23, 103, 230, 22, 16, .serif)
            art("identity.rule", "黄色短线", .rule, 241, 91, 32, 2, color: .yellow, order: 10)
            text("earTag", "笔刷耳号", snapshot.subject.earTag, 19, 122, 324, 152, 125, .brush,
                 color: .yellow, rotation: -9, tracking: -2)
            text("status", "手写状态", status, 28, 269, 230, 43, 34, .handwriting, rotation: -12)
            art("status.brush", "状态下划线", .brush, 25, 313, 208, 2, order: 10, opacity: 0.8, rotation: -12)
            text("farm.latinSignature", "牧场英文落款", snapshot.farmLatinName ?? "", 23, 532, 200, 54, 7, .editorial)
        }
        let components = Calendar.current.dateComponents([.year, .month, .day], from: snapshot.generatedAt)
        let date = String(format: "%04d.%02d.%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
        text("date.title", "生成日期标签", String(localized: "生成日期"), 252, 628, 36, 8, 5)
        text("date.value", "生成日期", date, 290, 628, 54, 8, 5)
        return items
    }
}
