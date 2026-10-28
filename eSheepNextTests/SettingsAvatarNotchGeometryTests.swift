import CoreGraphics
import XCTest
@testable import eSheepNext

final class SettingsAvatarNotchGeometryTests: XCTestCase {
    func testKnownNotchFamiliesHaveSeparateShoulderProfiles() {
        for identifier in ["iPhone12,1", "iPhone12,3", "iPhone12,5",
                           "iPhone13,1", "iPhone13,2", "iPhone13,3", "iPhone13,4"] {
            XCTAssertEqual(SettingsAvatarNotchGeometry.profile(for: identifier), .wide)
        }
        for identifier in ["iPhone14,2", "iPhone14,3", "iPhone14,4", "iPhone14,5",
                           "iPhone14,7", "iPhone14,8", "iPhone17,5", "iPhone18,5"] {
            XCTAssertEqual(SettingsAvatarNotchGeometry.profile(for: identifier), .narrow)
        }
    }

    func testIslandDuoHomeButtonAndUnknownModelsDoNotReceiveANotch() {
        for identifier in ["iPhone15,2", "iPhone19,2", "iPhone20,2", "iPhone14,6", "", "future-device"] {
            XCTAssertNil(SettingsAvatarNotchGeometry.attachment(
                for: identifier, viewportWidth: 390, topInset: 47, displayScale: 3
            ))
        }
    }

    func testAbsentOrTransientInsetsAndInvalidWidthsDoNotAttach() {
        for inset in [CGFloat(0), 20, 43, 59, 64, .nan, .infinity] {
            XCTAssertNil(attachment(topInset: inset))
        }
        for width in [CGFloat(0), -1, .nan, .infinity] {
            XCTAssertNil(SettingsAvatarNotchGeometry.attachment(
                for: "iPhone14,7", viewportWidth: width, topInset: 47, displayScale: 3
            ))
        }
    }

    func testNotchAnchorFollowsTheSameBaselineAsTheAvatar() throws {
        let wide = try XCTUnwrap(SettingsAvatarNotchGeometry.attachment(
            for: "iPhone12,1", viewportWidth: 414, topInset: 44, displayScale: 2
        ))
        let narrow = try XCTUnwrap(attachment())
        XCTAssertEqual(wide.anchorY, 32.5)
        XCTAssertEqual(narrow.anchorY, 35.5)
        XCTAssertGreaterThan(wide.contact.halfWidth, narrow.contact.halfWidth)
        XCTAssertLessThan(narrow.anchorY + narrow.contact.top, 34)
    }

    func testWiderShoulderHasPaintAndStaysInsideItsCanvas() throws {
        for identifier in ["iPhone12,1", "iPhone14,7"] {
            let attachment = try XCTUnwrap(SettingsAvatarNotchGeometry.attachment(
                for: identifier, viewportWidth: 390, topInset: 47, displayScale: 3
            ))
            let paint = SettingsAvatarIslandGeometry.paintBounds(
                in: CGRect(x: 0, y: 0, width: 171, height: 171),
                topOverscan: attachment.contact.paintOverscan
            )
            let path = mask(offset: 53.33, attachment: attachment)
            for side in [CGFloat(-1), 1] {
                // Stay inside the concave corner while still sampling beyond
                // the former island clip's 39pt half-width on this viewport.
                let point = CGPoint(x: 85.5 + side * attachment.contact.halfWidth * 0.75,
                                    y: attachment.contact.top + 0.5)
                XCTAssertTrue(paint.contains(point))
                XCTAssertTrue(path.contains(point))
            }
            for offset in stride(from: 0.0, through: 120.0, by: 0.5) {
                let bounds = mask(offset: offset, attachment: attachment).boundingBoxOfPath
                XCTAssertGreaterThanOrEqual(bounds.minX, 0)
                XCTAssertLessThanOrEqual(bounds.maxX, 171)
                XCTAssertGreaterThanOrEqual(bounds.minY, paint.minY)
                XCTAssertLessThanOrEqual(bounds.maxY, paint.maxY)
            }
        }
    }

    func testCompleteRetreatLeavesNoSeparateBlackStrip() throws {
        let attachment = try XCTUnwrap(attachment())
        let path = mask(offset: 120, attachment: attachment)
        XCTAssertEqual(path.boundingBoxOfPath.height, 0, accuracy: 0.0001)
        XCTAssertFalse(path.contains(CGPoint(x: 85.5, y: -0.25)))
        XCTAssertFalse(path.contains(CGPoint(x: 85.5, y: 0.25)))
    }

    func testExpansionPreservesTheFullPhotoAndNameExtension() throws {
        let attachment = try XCTUnwrap(attachment())
        let path = SettingsAvatarMaskPath.make(
            photo: CGRect(x: 0, y: 0, width: 390, height: 390),
            extensionHeight: 60, cornerRadius: 0,
            maskOrigin: CGPoint(x: (390 - 171) / 2, y: attachment.anchorY),
            progress: 0, strength: 0, compactContact: attachment.contact
        )
        for point in [CGPoint(x: 1, y: 1), CGPoint(x: 389, y: 1),
                      CGPoint(x: 1, y: 449), CGPoint(x: 389, y: 449)] {
            XCTAssertTrue(path.contains(point))
        }
        XCTAssertFalse(path.contains(CGPoint(x: 195, y: 451)))
    }

    private func attachment(topInset: CGFloat = 47) -> SettingsAvatarNotchGeometry.Attachment? {
        SettingsAvatarNotchGeometry.attachment(
            for: "iPhone14,7", viewportWidth: 390, topInset: topInset, displayScale: 3
        )
    }

    private func mask(offset: CGFloat, attachment: SettingsAvatarNotchGeometry.Attachment) -> CGPath {
        SettingsAvatarMaskPath.make(
            photo: CGRect(x: 35.5, y: 30, width: 100, height: 100),
            extensionHeight: 0, cornerRadius: 50, maskOrigin: .zero,
            progress: offset / 120, strength: 1, compactContact: attachment.contact
        )
    }
}
