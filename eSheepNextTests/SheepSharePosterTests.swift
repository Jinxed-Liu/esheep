import SwiftData
import UIKit
import XCTest
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

    func testRendererProducesSame1080By1920CanvasForEveryTemplate() throws {
        for template in SheepSharePosterTemplate.allCases {
            let rendered = try XCTUnwrap(SheepSharePosterRenderer.render(
                snapshot: posterSnapshot,
                image: image(size: CGSize(width: 1200, height: 800)),
                template: template
            ))
            let cgImage = try XCTUnwrap(rendered.cgImage)

            XCTAssertEqual(cgImage.width, 1080, template.displayName)
            XCTAssertEqual(cgImage.height, 1920, template.displayName)
        }
    }

    func testPedigreeLayoutKeepsAllThreeGenerationsInSeparateTracks() {
        for compact in [true, false] {
            let layout = SheepSharePosterPedigreeLayout(compact: compact)

            XCTAssertEqual(layout.grandY - layout.grandNodeHeight / 2, 0)
            XCTAssertLessThan(layout.grandBottom, layout.parentTop)
            XCTAssertEqual(layout.parentTop - layout.grandBottom, compact ? 18 : 20)
            XCTAssertGreaterThan(layout.grandJunctionY, layout.grandBottom)
            XCTAssertLessThan(layout.grandJunctionY, layout.parentTop)
            XCTAssertLessThan(layout.parentBottom, layout.subjectTop)
            XCTAssertEqual(layout.subjectTop - layout.parentBottom, compact ? 18 : 20)
            XCTAssertGreaterThan(layout.parentJunctionY, layout.parentBottom)
            XCTAssertLessThan(layout.parentJunctionY, layout.subjectTop)
            XCTAssertEqual(layout.subjectBottom, layout.height)
        }
    }

    func testPosterBrandMarkAssetHasTransparency() throws {
        let mark = try XCTUnwrap(UIImage(named: "PosterBrandMark"))
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
