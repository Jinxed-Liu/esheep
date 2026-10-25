import SwiftData
import UIKit
import XCTest
import CoreText
@testable import eSheepNext

@MainActor
final class SheepSharePosterTests: XCTestCase {
    func testTemplatesCoverBothPhotoDirectionsAndBothThemesOnOneCanvasRatio() {
        let combinations = Set(SheepSharePosterTemplate.allCases.map {
            "\($0.photoLayout.rawValue)-\($0.theme.rawValue)"
        })

        XCTAssertEqual(SheepSharePosterTemplate.allCases.count, 4)
        XCTAssertEqual(combinations, [
            "landscape-dark",
            "landscape-light",
            "portrait-dark",
            "portrait-light"
        ])
        XCTAssertTrue(SheepSharePosterTemplate.allCases.allSatisfy {
            $0.canvasAspectRatio == 9.0 / 16.0
                && $0.canvasSize == CGSize(width: 360, height: 640)
        })
    }

    func testRecommendedTemplateUsesSourcePhotoDirectionWithoutChangingCanvas() {
        let landscape = image(size: CGSize(width: 1200, height: 800))
        let portrait = image(size: CGSize(width: 800, height: 1200))

        XCTAssertEqual(SheepSharePosterTemplate.recommended(for: landscape), .landscapeLight)
        XCTAssertEqual(SheepSharePosterTemplate.recommended(for: portrait), .portraitLight)
        XCTAssertEqual(
            SheepSharePosterTemplate.recommended(for: landscape).canvasSize,
            SheepSharePosterTemplate.recommended(for: portrait).canvasSize
        )
    }

    func testRecommendedTemplateUsesDisplayedExifOrientation() throws {
        let source = image(size: CGSize(width: 1200, height: 800))
        let cgImage = try XCTUnwrap(source.cgImage)
        let rotatedPortrait = UIImage(cgImage: cgImage, scale: 1, orientation: .right)

        XCTAssertEqual(
            SheepSharePosterTemplate.recommended(for: rotatedPortrait),
            .portraitLight
        )
    }

    func testEweMetricsUseLatestTwoLambingsAndReferenceDate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let first = try date(2026, 1, 1, calendar: calendar)
        let latest = try date(2026, 2, 20, calendar: calendar)
        let reference = try date(2026, 3, 1, calendar: calendar)

        let metrics = SheepSharePosterMetrics.make(
            sex: .ewe,
            currentParity: 2,
            lambings: [
                SheepSharePosterLambing(occurredAt: latest),
                SheepSharePosterLambing(occurredAt: first)
            ],
            referenceDate: reference,
            calendar: calendar
        )

        XCTAssertEqual(metrics.currentParity, 2)
        XCTAssertEqual(metrics.recentIntervalDays, 50)
        XCTAssertEqual(metrics.lastLambingAt, latest)
        XCTAssertEqual(metrics.postpartumDays, 9)
    }

    func testRamMetricsDoNotPresentEweReproductionValues() {
        let metrics = SheepSharePosterMetrics.make(
            sex: .ram,
            currentParity: 3,
            lambings: [SheepSharePosterLambing(occurredAt: .now)],
            referenceDate: .now
        )

        XCTAssertNil(metrics.currentParity)
        XCTAssertNil(metrics.recentIntervalDays)
        XCTAssertNil(metrics.lastLambingAt)
        XCTAssertNil(metrics.postpartumDays)
    }

    func testRendererProducesDistinctStylesOnSame1080By1920Canvas() throws {
        for template in SheepSharePosterTemplate.allCases {
            var renderedStyles = Set<Data>()
            for style in SheepSharePosterStyle.allCases {
                let rendered = try XCTUnwrap(SheepSharePosterRenderer.render(
                    snapshot: posterSnapshot,
                    image: image(size: CGSize(width: 1200, height: 800)),
                    template: template,
                    style: style
                ))
                let cgImage = try XCTUnwrap(rendered.cgImage)
                XCTAssertEqual(cgImage.width, 1080, "\(style.title) / \(template.displayName)")
                XCTAssertEqual(cgImage.height, 1920, "\(style.title) / \(template.displayName)")
                renderedStyles.insert(try XCTUnwrap(rendered.pngData()))
            }
            XCTAssertEqual(renderedStyles.count, SheepSharePosterStyle.allCases.count,
                           "Selecting a style must change the exported composition")
        }
    }

    func testPosterUsesCurrentAppIconWithTransparentCorners() throws {
        let mark = try XCTUnwrap(UIImage(named: "PosterAppIcon"))
        let cgImage = try XCTUnwrap(mark.cgImage)

        XCTAssertNotEqual(cgImage.alphaInfo, .none)
        XCTAssertNotEqual(cgImage.alphaInfo, .noneSkipFirst)
        XCTAssertNotEqual(cgImage.alphaInfo, .noneSkipLast)

        let corner = try XCTUnwrap(cgImage.cropping(to: CGRect(x: 0, y: 0, width: 1, height: 1)))
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(corner, in: CGRect(x: 0, y: 0, width: 1, height: 1))

        XCTAssertEqual(pixel[3], 0, "品牌图形的方形底色没有被完全移除")
    }

    func testReusableTemplateKeepsDesignButNeverCarriesAnotherSheepsFacts() {
        var edits = SheepSharePosterCustomization()
        edits.photoData = Data([1, 2, 3])
        edits.overrides["earTag"] = .init(x: 40, fontSize: 60, text: "OLD-SHEEP")
        edits.overrides["metric.0.value"] = .init(text: "第 9 胎")
        edits.overrides["family.dam.earTag"] = .init(text: "OLD-DAM")
        edits.overrides["brand"] = .init(text: "My Farm")
        edits.overrides["photo"] = .init(x: 10, imageData: Data([4, 5]))
        edits.additions = [.init(id: "custom.caption", title: "自定义文字", text: "我的牧场",
                                 x: 10, y: 40, width: 200, height: 40)]
        let reusable = edits.reusable
        XCTAssertNil(reusable.photoData)
        XCTAssertNil(reusable.overrides["earTag"]?.text)
        XCTAssertNil(reusable.overrides["metric.0.value"]?.text)
        XCTAssertNil(reusable.overrides["family.dam.earTag"]?.text)
        XCTAssertNil(reusable.overrides["photo"]?.imageData)
        XCTAssertEqual(reusable.overrides["earTag"]?.x, 40)
        XCTAssertEqual(reusable.overrides["earTag"]?.fontSize, 60)
        XCTAssertEqual(reusable.overrides["brand"]?.text, "My Farm")
        XCTAssertEqual(reusable.additions.first?.text, "我的牧场")
        XCTAssertEqual(edits.overrides["earTag"]?.text, "OLD-SHEEP", "Saving must not alter the current poster")
    }

    func testSavedTemplateRoundTripsWithoutLosingCustomElements() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("templates.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        var edits = SheepSharePosterCustomization()
        edits.overrides["earTag"] = .init(x: 48, rotation: -12, font: .brush, color: .yellow)
        edits.additions = [.init(id: "custom.caption", title: "自定义文字", text: "A caption",
                                 x: 30, y: 50, width: 200, height: 30)]
        let saved = SheepSharePosterSavedTemplate(id: UUID(), name: "My design",
                                                  style: "minimal", template: "portraitDark",
                                                  customization: edits, updatedAt: .now)
        try SheepSharePosterTemplateStore.save([saved], to: url)
        let readBack = try SheepSharePosterTemplateStore.load(from: url)
        XCTAssertEqual(readBack.count, 1)
        XCTAssertEqual(readBack.first?.id, saved.id)
        XCTAssertEqual(readBack.first?.customization, edits)
    }

    func testBilingualNamesFitAndFollowChineseNameAcrossStyles() {
        for farmName in ["青禾牧场", "青禾生态畜牧养殖专业合作社"] {
            for latin in ["Qinghe Farm", "Qinghe Ecological Livestock Breeding Cooperative", ""] {
                var snapshot = posterSnapshot
                snapshot.farmLatinName = latin
                for style in SheepSharePosterStyle.allCases {
                    var custom = SheepSharePosterCustomization()
                    custom.overrides["farm"] = .init(x: 31, y: 23, text: farmName)
                    let elements = custom.elements(from: SheepSharePosterLayout.elements(snapshot: snapshot, style: style, template: .portraitLight))
                    let name = elements.first { $0.id == "farm" }!
                    let subtitle = elements.first { $0.id == "farm.latinName" }!
                    XCTAssertEqual(subtitle.x, name.x, accuracy: 0.01)
                    XCTAssertLessThanOrEqual(SheepPosterNameAlignment.width(name), name.width + 0.1)
                    XCTAssertLessThanOrEqual(SheepPosterNameAlignment.width(subtitle), subtitle.width + 0.1)
                    XCTAssertGreaterThan(subtitle.y, name.y + name.height / 2)
                    XCTAssertLessThanOrEqual(subtitle.x + subtitle.width, name.x + name.width + 0.1)
                    if let signature = elements.first(where: { $0.id == "farm.signature" }),
                       let english = elements.first(where: { $0.id == "farm.latinSignature" }) {
                        XCTAssertEqual(signature.rotation, english.rotation)
                    }
                }
            }
        }
    }

    func testManualSubtitlePlacementSurvivesAutomaticNameAlignment() {
        var custom = SheepSharePosterCustomization()
        custom.overrides["farm.latinName"] = .init(x: 88, y: 76, width: 190, rotation: 7, fontSize: 13, tracking: 1)
        let elements = custom.elements(from: SheepSharePosterLayout.elements(snapshot: posterSnapshot, style: .magazine, template: .portraitLight))
        let subtitle = elements.first { $0.id == "farm.latinName" }!
        XCTAssertEqual(subtitle.x, 88)
        XCTAssertEqual(subtitle.y, 76)
        XCTAssertEqual(subtitle.width, 190)
        XCTAssertEqual(subtitle.rotation, 7)
        XCTAssertEqual(subtitle.fontSize, 13)
        XCTAssertEqual(subtitle.tracking, 1)
    }

    func testGlobalLatinNameFlowsIntoEveryStyleAndReusableTemplateKeepsItLive() {
        var snapshot = posterSnapshot
        snapshot.farmLatinName = "Qinghe Farm"
        var custom = SheepSharePosterCustomization()
        custom.overrides["farm.latinName"] = .init(text: "Other Farm")
        for style in SheepSharePosterStyle.allCases {
            let defaults = SheepSharePosterLayout.elements(snapshot: snapshot, style: style, template: .portraitLight)
            let elements = custom.reusable.elements(from: defaults)
            XCTAssertEqual(elements.first { $0.id == "farm.latinName" }?.text, "Qinghe Farm")
            XCTAssertFalse(elements.contains { $0.text.contains("P O R T R A I T S") })
        }
        snapshot.farmLatinName = nil
        XCTAssertEqual(SheepSharePosterLayout.elements(snapshot: snapshot, style: .magazine, template: .portraitLight).first { $0.id == "farm.latinName" }?.text, "")
    }

    func testEveryTemplateElementCanBeAddressedIndividually() {
        for style in SheepSharePosterStyle.allCases {
            let elements = SheepSharePosterLayout.elements(snapshot: posterSnapshot, style: style, template: .portraitLight)
            XCTAssertEqual(Set(elements.map(\.id)).count, elements.count)
            XCTAssertTrue(elements.contains { $0.id == "photo" })
            XCTAssertTrue(elements.contains { $0.id == "logo" })
            XCTAssertTrue(elements.contains { $0.id == "earTag" })
        }
    }

    func testCustomizationChangesExportAndResetRestoresDefaultElements() throws {
        let baseline = try XCTUnwrap(SheepSharePosterRenderer.render(snapshot: posterSnapshot, image: nil,
                                                                   template: .portraitLight)?.pngData())
        var edits = SheepSharePosterCustomization()
        edits.overrides["earTag"] = .init(x: 75, fontSize: 45, color: .yellow, text: "CUSTOM")
        let modified = try XCTUnwrap(SheepSharePosterRenderer.render(snapshot: posterSnapshot, image: nil,
                                                                   template: .portraitLight, customization: edits))
        XCTAssertEqual(modified.cgImage?.width, 1080)
        XCTAssertEqual(modified.cgImage?.height, 1920)
        XCTAssertNotEqual(modified.pngData(), baseline)
        let defaults = SheepSharePosterLayout.elements(snapshot: posterSnapshot, style: .magazine, template: .portraitLight)
        XCTAssertNotEqual(edits.elements(from: defaults), SheepSharePosterCustomization().elements(from: defaults))
        edits = .init()
        XCTAssertEqual(edits.elements(from: defaults), SheepSharePosterCustomization().elements(from: defaults))
    }

    func testBundledPosterFontsRegisterForOfflineExport() {
        _ = SheepSharePosterTypography.brush(size: 20)
        _ = SheepSharePosterTypography.handwriting(size: 20)
        XCTAssertNotNil(UIFont(name: "Knewave-Regular", size: 20))
        XCTAssertNotNil(UIFont(name: "MaShanZheng-Regular", size: 20))
    }

    func testChineseFontChoicesResolveToDistinctFacesWithActualHanGlyphs() throws {
        SheepSharePosterTypography.register()
        let sample = "青禾牧场种羊展示卡繁殖母羊在场"
        let names = SheepPosterFont.allCases.compactMap { $0.postScriptName(for: sample) }
        XCTAssertEqual(Set(names).count, 4)
        for name in names {
            XCTAssertNotNil(UIFont(name: name, size: 24), name)
            let font = CTFontCreateWithName(name as CFString, 24, nil)
            XCTAssertEqual(CTFontCopyPostScriptName(font) as String, name)
            let characters = Array(sample.utf16)
            var glyphs = [CGGlyph](repeating: 0, count: characters.count)
            XCTAssertTrue(CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count), name)
            XCTAssertFalse(glyphs.contains(0), name)
        }
        XCTAssertEqual(SheepPosterFont.editorial.postScriptName(for: "E0387"), "Didot-Bold")
        XCTAssertEqual(SheepPosterFont.brush.postScriptName(for: "E0387"), "Knewave-Regular")
        XCTAssertEqual(SheepPosterFont.brush.postScriptName(for: "牧场 E0387"), "ZhiMangXing-Regular")
    }

    func testBreedingCardOnlyShowsEweMetricsForEwes() {
        for sex in [SheepSex.ram, .unknown] {
            let snapshot = cardSnapshot(sex: sex)
            let elements = SheepSharePosterLayout.elements(snapshot: snapshot, style: .breeding, template: .portraitLight)
            XCTAssertEqual(snapshot.posterCardFields.map(\.title), ["月龄", "出生日期", "当前羊舍"])
            XCTAssertFalse(elements.contains { $0.id.hasPrefix("metric.") || $0.id.hasPrefix("lastLambing.") })
            XCTAssertFalse(elements.contains { ["当前胎次", "最近胎间距", "当前产后天数", "上次产羔"].contains($0.text) })
        }
        XCTAssertEqual(posterSnapshot.posterCardFields.map(\.title), ["当前胎次", "最近胎间距", "当前产后天数"])
    }

    func testSavedEweTemplateCannotReintroduceEweFieldsOnRamCard() {
        var custom = SheepSharePosterCustomization()
        custom.overrides["metric.0.title"] = .init(text: "我的胎次")
        custom.overrides["metric.0.value"] = .init(text: "第 9 胎")
        custom.overrides["lastLambing.title"] = .init(text: "上次产羔")
        custom.overrides["identity.pen.value"] = .init(text: "旧羊舍")
        let defaults = SheepSharePosterLayout.elements(snapshot: cardSnapshot(sex: .ram),
                                                       style: .breeding, template: .portraitLight)
        let resolved = custom.reusable.elements(from: defaults)
        XCTAssertFalse(resolved.contains { $0.text == "我的胎次" || $0.text == "第 9 胎" || $0.text == "上次产羔" })
        XCTAssertEqual(resolved.first { $0.id == "identity.pen.value" }?.text, "种公羊舍")
    }

    func testRamAgeUsesSnapshotDateAndDoesNotInventMissingBirthDate() {
        let ref = posterSnapshot.generatedAt
        let birth = Calendar.current.date(byAdding: .month, value: -18, to: ref)!
        let known = cardSnapshot(sex: .ram, birthAt: birth)
        XCTAssertEqual(known.posterCardFields[0].value, String(localized: "\(18) 月龄"))
        XCTAssertEqual(cardSnapshot(sex: .ram).posterCardFields[0].value, String(localized: "未填写"))
        XCTAssertEqual(cardSnapshot(sex: .ram, birthAt: ref.addingTimeInterval(86400)).posterCardFields[0].value,
                       String(localized: "未填写"))
    }

    private func cardSnapshot(sex: SheepSex, birthAt: Date? = nil) -> SheepSharePosterSnapshot {
        let source = posterSnapshot
        return .init(farmName: source.farmName,
                     subject: .init(id: UUID(), earTag: "R0387", breed: "杜泊", purpose: sex == .ram ? "种公羊" : "",
                                    sex: sex, status: .active, initialPenID: nil, currentPenID: nil,
                                    birthAt: birthAt, enteredAt: source.generatedAt, removedAt: nil),
                     penName: "种公羊舍", photoReference: nil, pedigree: source.pedigree,
                     metrics: .make(sex: sex, currentParity: nil, lambings: [], referenceDate: source.generatedAt),
                     generatedAt: source.generatedAt)
    }

    func testSnapshotLoadsSelectedSheepPhotoPedigreePenAndLambingMetrics() async throws {
        let container = try AppSchema.makeContainer(
            name: "share-poster-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        let pen = PenRecord(farmID: farmID, name: "繁殖母羊舍")
        let dam = SheepRecord(
            farmID: farmID,
            earTag: "E0216",
            breed: "湖羊",
            sex: .ewe,
            penID: nil,
            enteredAt: .distantPast
        )
        let sire = SheepRecord(
            farmID: farmID,
            earTag: "R0182",
            breed: "杜泊",
            sex: .ram,
            penID: nil,
            enteredAt: .distantPast
        )
        let ewe = SheepRecord(
            farmID: farmID,
            earTag: "E0387",
            breed: "杜湖杂交",
            purpose: "繁殖母羊",
            sex: .ewe,
            penID: pen.id,
            enteredAt: .distantPast,
            damID: dam.id,
            sireID: sire.id
        )
        let photo = PhotoAssetRecord(
            farmID: farmID,
            sheepID: ewe.id,
            legacySourceKey: "share-poster-photo",
            originalEarTag: ewe.earTag,
            relativePath: "Assets/share-poster.jpg",
            sha256: "poster-photo-digest"
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let firstLambing = ReproductionRecord(
            farmID: farmID,
            eweID: ewe.id,
            kind: .lambing,
            occurredAt: try date(2026, 1, 1, calendar: calendar),
            lambCount: 2,
            parity: 1
        )
        let latestLambing = ReproductionRecord(
            farmID: farmID,
            eweID: ewe.id,
            kind: .lambing,
            occurredAt: try date(2026, 2, 20, calendar: calendar),
            lambCount: 2,
            parity: 2
        )
        context.insert(ESheepCloudFarmState(farmID: farmID, farmGeneration: 3, activityState: .active))
        context.insert(ESheepCloudFarmIdentityState(farmID: farmID, farmGeneration: 3, name: "青禾牧场", revision: 1, latinName: "Qinghe Farm"))
        context.insert(ESheepCloudFarmIdentityState(farmID: farmID, farmGeneration: 2, name: "旧代牧场", revision: 99, latinName: "Old Farm"))
        context.insert(pen)
        [dam, sire, ewe].forEach(context.insert)
        context.insert(photo)
        [firstLambing, latestLambing].forEach(context.insert)
        try context.save()

        let snapshot = try await SheepSharePosterSnapshotActor(container: container).load(
            farmID: farmID,
            farmName: "青禾牧场",
            sheepID: ewe.id,
            referenceDate: try date(2026, 3, 1, calendar: calendar)
        )

        XCTAssertEqual(snapshot.farmName, "青禾牧场")
        XCTAssertEqual(snapshot.farmLatinName, "Qinghe Farm")
        XCTAssertEqual(snapshot.subject.earTag, "E0387")
        XCTAssertEqual(snapshot.penName, "繁殖母羊舍")
        XCTAssertEqual(snapshot.photoReference, SheepPhotoReference(
            id: photo.id,
            digest: photo.sha256
        ))
        XCTAssertEqual(snapshot.pedigree.dam?.earTag, "E0216")
        XCTAssertEqual(snapshot.pedigree.dam?.breed, "湖羊")
        XCTAssertEqual(snapshot.pedigree.sire?.earTag, "R0182")
        XCTAssertEqual(snapshot.pedigree.sire?.breed, "杜泊")
        XCTAssertEqual(snapshot.metrics.currentParity, 2)
        XCTAssertEqual(snapshot.metrics.recentIntervalDays, 50)
        XCTAssertEqual(snapshot.metrics.postpartumDays, 9)
    }

    func testDiskTemplateRebindsAllLiveFieldsAcrossStylesAndSexes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("templates.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldPhoto = try XCTUnwrap(image(size: CGSize(width: 64, height: 48)).pngData())
        let artwork = try XCTUnwrap(image(size: CGSize(width: 24, height: 24)).pngData())
        let liveIDs: Set<String> = ["farm", "farm.latinName", "farm.signature", "farm.latinSignature",
            "earTag", "breed", "role", "sex", "status", "date.value", "lastLambing.value",
            "family.dam.earTag", "family.sire.earTag", "family.maternalGranddam.earTag",
            "family.maternalGrandsire.earTag", "family.paternalGranddam.earTag", "family.paternalGrandsire.earTag",
            "metric.0.value", "metric.1.value", "metric.2.value",
            "identity.age.value", "identity.birth.value", "identity.pen.value"]
        for style in SheepSharePosterStyle.allCases {
            var custom = SheepSharePosterCustomization()
            custom.background = .sky
            custom.photoData = oldPhoto
            for id in liveIDs {
                custom.overrides[id] = .init(x: 40, y: 50, rotation: 5, font: .serif,
                                             color: .yellow, text: "OLD-" + id, layerOrder: 23)
            }
            for id in ["photo", "photo.backdrop"] {
                custom.overrides[id] = .init(x: 8, imageData: oldPhoto, photoZoom: 1.8, photoX: 12, photoY: -20)
            }
            custom.additions = [
                .init(id: "custom.caption", title: "自定义文字", text: "保留用户设计", x: 20, y: 30, width: 200, height: 30),
                .init(id: "custom.art", title: "自定义图片", kind: .image, x: 20, y: 60, width: 24, height: 24, imageData: artwork)
            ]
            custom.overrides["custom.caption"] = .init(font: .brush, text: "修改后的新增文字")
            let saved = SheepSharePosterSavedTemplate(id: UUID(), name: "Isolation",
                style: style.rawValue, template: "portraitLight", customization: custom.reusable, updatedAt: .now)
            try SheepSharePosterTemplateStore.save([saved], to: url)
            let loaded = try XCTUnwrap(SheepSharePosterTemplateStore.load(from: url).first)
            XCTAssertNil(loaded.customization.photoData)
            XCTAssertEqual(loaded.customization.background, .sky)
            XCTAssertEqual(loaded.customization.additions, custom.additions)
            for id in liveIDs {
                XCTAssertNil(loaded.customization.overrides[id]?.text, id)
                XCTAssertEqual(loaded.customization.overrides[id]?.x, 40, id)
                XCTAssertEqual(loaded.customization.overrides[id]?.font, .serif, id)
                XCTAssertEqual(loaded.customization.overrides[id]?.color, .yellow, id)
                XCTAssertEqual(loaded.customization.overrides[id]?.layerOrder, 23, id)
            }
            for id in ["photo", "photo.backdrop"] {
                XCTAssertNil(loaded.customization.overrides[id]?.imageData)
                XCTAssertEqual(loaded.customization.overrides[id]?.photoZoom, 1.8)
                XCTAssertEqual(loaded.customization.overrides[id]?.photoX, 12)
                XCTAssertEqual(loaded.customization.overrides[id]?.photoY, -20)
            }
            for sex in [SheepSex.ewe, .ram, .unknown] {
                let snapshot = cardSnapshot(sex: sex)
                let defaults = SheepSharePosterLayout.elements(snapshot: snapshot, style: style, template: .portraitLight)
                let resolved = loaded.customization.reusable.elements(from: defaults)
                for original in defaults where liveIDs.contains(original.id) {
                    XCTAssertEqual(resolved.first { $0.id == original.id }?.text, original.text, original.id)
                }
                XCTAssertFalse(resolved.contains { $0.text.hasPrefix("OLD-") })
                XCTAssertEqual(resolved.first { $0.id == "custom.caption" }?.text, "修改后的新增文字")
                XCTAssertEqual(resolved.first { $0.id == "custom.art" }?.imageData, artwork)
            }
            XCTAssertEqual(custom.photoData, oldPhoto, "Saving must leave the current editor intact")
        }
    }

    func testReusedTemplateRendersCurrentPhotoAndPreservesCrop() throws {
        let old = image(size: CGSize(width: 120, height: 80))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let current = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80), format: format).image { ctx in
            UIColor.blue.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
            UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 30, height: 80))
        }
        for style in SheepSharePosterStyle.allCases {
            var edits = SheepSharePosterCustomization()
            edits.photoData = try XCTUnwrap(old.pngData())
            edits.overrides["photo"] = .init(imageData: old.pngData(), photoZoom: 1.6, photoX: 24, photoY: -10)
            edits.overrides["photo.backdrop"] = .init(imageData: old.pngData())
            let loaded = try JSONDecoder().decode(SheepSharePosterCustomization.self,
                from: JSONEncoder().encode(edits.reusable))
            // Construct the expected design independently of the sanitization routine.
            var expected = SheepSharePosterCustomization()
            expected.overrides["photo"] = .init(photoZoom: 1.6, photoX: 24, photoY: -10)
            func rendered(_ design: SheepSharePosterCustomization, _ photo: UIImage) throws -> Data {
                try XCTUnwrap(SheepSharePosterRenderer.render(snapshot: posterSnapshot, image: photo,
                    template: .portraitLight, style: style, customization: design)?.pngData())
            }
            let actual = try rendered(loaded, current)
            XCTAssertEqual(actual, try rendered(expected, current), style.rawValue)
            XCTAssertNotEqual(actual, try rendered(expected, old), "Must not use previous sheep's photo")
            XCTAssertNotEqual(actual, try rendered(.init(), current), "Saved crop must affect the rendered image")
        }
    }

    func testCorruptPersonalTemplateFileThrowsWithoutOverwritingEvidence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("templates.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertTrue(try SheepSharePosterTemplateStore.load(from: url).isEmpty)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let corrupt = Data("[{broken-template".utf8)
        try corrupt.write(to: url)
        XCTAssertThrowsError(try SheepSharePosterTemplateStore.load(from: url))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    private func image(size: CGSize) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        calendar: Calendar
    ) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day)))
    }

    private var posterSnapshot: SheepSharePosterSnapshot {
        let generatedAt = Date(timeIntervalSince1970: 1_785_628_800)
        return SheepSharePosterSnapshot(
            farmName: "测试牧场",
            subject: SheepDetailSubjectSnapshot(
                id: UUID(),
                earTag: "E0387",
                breed: "杜湖杂交",
                purpose: "繁殖母羊",
                sex: .ewe,
                status: .active,
                initialPenID: nil,
                currentPenID: nil,
                birthAt: nil,
                enteredAt: generatedAt,
                removedAt: nil
            ),
            penName: nil,
            photoReference: nil,
            pedigree: SheepSharePosterPedigree(
                maternalGrandsire: .init(earTag: "R0061", breed: "湖羊"),
                dam: .init(earTag: "E0216", breed: "湖羊"),
                sire: .init(earTag: "R0182", breed: "杜泊")
            ),
            metrics: SheepSharePosterMetrics(
                currentParity: 3,
                recentIntervalDays: 342,
                lastLambingAt: generatedAt.addingTimeInterval(-225 * 86_400),
                postpartumDays: 225
            ),
            generatedAt: generatedAt
        )
    }
}
