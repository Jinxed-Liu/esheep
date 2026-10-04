import CoreGraphics
import UIKit
import XCTest
@testable import eSheepNext

final class SettingsAvatarIslandGeometryTests: XCTestCase {
    func testCompactContactIsLimitedToVerifiedProModels() {
        for identifier in ["iPhone19,2", "iPhone19,3", "iPhone19,7"] {
            XCTAssertTrue(SettingsAvatarIslandGeometry.usesCompactAttachment(deviceIdentifier: identifier))
        }
        for identifier in ["iPhone15,2", "iPhone16,1", "iPhone17,2", "iPhone18,1", "iPhone20,2", "x86_64", ""] {
            XCTAssertFalse(SettingsAvatarIslandGeometry.usesCompactAttachment(deviceIdentifier: identifier))
            XCTAssertNil(SettingsAvatarIslandGeometry.contact(for: identifier, displayScale: 3))
        }
    }

    func testContactCannotExposeSideFinsAtTheClippingEdge() throws {
        for scale in [CGFloat(2), 3] {
            let contact = try XCTUnwrap(SettingsAvatarIslandGeometry.contact(
                for: "iPhone19,2", displayScale: scale
            ))
            for offset in stride(from: 0.0, through: 120.0, by: 0.5) {
                let path = mask(offset: CGFloat(offset), contact: contact)
                // Inspect the actual combined mask at the first visible pixels
                // of its canvas, where the former 96.8pt strip formed fins.
                for y in [CGFloat(0.5 / scale), 1 / scale] {
                    for side in [CGFloat(-1), 1] {
                        XCTAssertFalse(path.contains(CGPoint(x: 85.5 + side * 29, y: y)), "offset \(offset)")
                    }
                }
            }
        }
    }

    func testCompactShoulderDoesNotTurnUpAtItsRoot() throws {
        let contact = try XCTUnwrap(SettingsAvatarIslandGeometry.contact(for: "iPhone19,3", displayScale: 3))
        for offset in stride(from: 0.0, through: 120.0, by: 0.5) {
            var subpathCount = 0
            var shoulderControls: [CGPoint]?
            mask(offset: CGFloat(offset), contact: contact).applyWithBlock { element in
                switch element.pointee.type {
                case .moveToPoint:
                    subpathCount += 1
                case .addCurveToPoint where subpathCount == 2 && shoulderControls == nil:
                    let points = element.pointee.points
                    shoulderControls = [points[0], points[1], points[2]]
                default:
                    break
                }
            }
            let shoulder = try XCTUnwrap(shoulderControls)
            XCTAssertEqual(shoulder[0].x, 85.5 + contact.halfWidth, accuracy: 0.0001)
            XCTAssertGreaterThan(shoulder[0].y, contact.top)
            XCTAssertGreaterThanOrEqual(shoulder[1].y, shoulder[0].y)
            XCTAssertGreaterThanOrEqual(shoulder[2].y, shoulder[1].y)
        }
    }

    func testFullExpansionKeepsTheEntirePhotoAndNameExtension() throws {
        let contact = try XCTUnwrap(SettingsAvatarIslandGeometry.contact(for: "iPhone19,7", displayScale: 3))
        let photo = CGRect(x: 0, y: 0, width: 402, height: 402)
        let path = SettingsAvatarMaskPath.make(
            photo: photo, extensionHeight: 60, cornerRadius: 0,
            maskOrigin: CGPoint(x: (402 - 171) / 2, y: 47.5),
            progress: 1, strength: 0, compactContact: contact
        )
        for point in [CGPoint(x: 1, y: 1), CGPoint(x: 401, y: 1),
                      CGPoint(x: 1, y: 461), CGPoint(x: 401, y: 461)] {
            XCTAssertTrue(path.contains(point))
        }
        XCTAssertFalse(path.contains(CGPoint(x: 201, y: 463)))
    }

    func testBackingPaintCoversTheFirstExposedMaskPixels() throws {
        let contact = try XCTUnwrap(SettingsAvatarIslandGeometry.contact(for: "iPhone19,2", displayScale: 3))
        let origin = CGPoint(x: 115.5, y: 47.5)
        let canvas = CGRect(origin: origin, size: CGSize(width: 171, height: 171))
        let painted = SettingsAvatarIslandGeometry.paintBounds(in: canvas, topOverscan: contact.paintOverscan)
        // At offset 42, the photo covers only the narrow center above y=47.5.
        // The connection's sides need their own pixels all the way to the clip.
        let path = SettingsAvatarMaskPath.make(
            photo: CGRect(x: 160, y: 46.5, width: 82, height: 82),
            extensionHeight: 0, cornerRadius: 41, maskOrigin: origin,
            progress: 42 / 120, strength: 1, compactContact: contact
        )
        for side in [CGFloat(-1), 1] {
            for y in [CGFloat(47 + 1.0 / 6), 47.5] {
                let pixel = CGPoint(x: 201 + side * 24, y: y)
                XCTAssertTrue(path.contains(pixel))
                XCTAssertTrue(painted.contains(pixel))
            }
        }
        XCTAssertEqual(painted.maxY, canvas.maxY)
        XCTAssertEqual(SettingsAvatarIslandGeometry.paintBounds(in: canvas, topOverscan: 0), canvas)
    }

    @MainActor
    func testAllEffectLayersCoverTheOverscannedContact() throws {
        let contact = try XCTUnwrap(SettingsAvatarIslandGeometry.contact(for: "iPhone19,3", displayScale: 3))
        let effect = AvatarIslandEffectUIView(frame: CGRect(x: 0, y: 0, width: 171, height: 171))
        effect.setProgress(0.35, topOverscan: contact.paintOverscan)
        effect.layoutIfNeeded()
        XCTAssertEqual(effect.subviews.count, 3)
        for layer in effect.subviews {
            XCTAssertTrue(layer.frame.contains(CGPoint(x: 85.5 - 24, y: -1.0 / 3)))
            XCTAssertTrue(layer.frame.contains(CGPoint(x: 85.5 + 24, y: -1.0 / 3)))
        }
        // Returning to the legacy profile must undo the extended paint bounds.
        effect.setProgress(0.35)
        effect.layoutIfNeeded()
        for layer in effect.subviews {
            XCTAssertEqual(layer.frame.minY, 0)
        }
    }

    @MainActor
    func testRadialPaintExtendsAboveCanvasWithoutMovingItsArtwork() throws {
        let contact = try XCTUnwrap(SettingsAvatarIslandGeometry.contact(for: "iPhone19,7", displayScale: 3))
        let baseline = radialImage(topOverscan: 0)
        let extended = radialImage(topOverscan: contact.paintOverscan)
        let firstPixel = CGPoint(x: 74, y: contact.paintOverscan - 1.0 / 3)
        XCTAssertGreaterThan(try alpha(in: extended, at: firstPixel), 0.95)
        for point in [CGPoint(x: 50, y: 88), CGPoint(x: 50, y: 3), CGPoint(x: 25, y: 5)] {
            XCTAssertEqual(
                try alpha(in: baseline, at: point),
                try alpha(in: extended, at: CGPoint(x: point.x, y: point.y + contact.paintOverscan)),
                accuracy: 0.02
            )
        }
    }

    @MainActor
    private func radialImage(topOverscan: CGFloat) -> UIImage {
        let size = CGSize(width: 100, height: 100 + topOverscan)
        let view = AvatarIslandRadialShadeView(frame: CGRect(origin: .zero, size: size))
        view.topOverscan = topOverscan
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            view.draw(view.bounds)
        }
    }

    @MainActor
    private func alpha(in image: UIImage, at point: CGPoint) throws -> CGFloat {
        let source = try XCTUnwrap(image.cgImage)
        let pixel = try XCTUnwrap(source.cropping(to: CGRect(
            x: floor(point.x * image.scale), y: floor(point.y * image.scale), width: 1, height: 1
        )))
        var rgba = [UInt8](repeating: 0, count: 4)
        return try rgba.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return CGFloat(bytes[3]) / 255
        }
    }

    private func mask(offset: CGFloat, contact: SettingsAvatarIslandGeometry.Contact) -> CGPath {
        SettingsAvatarMaskPath.make(
            photo: CGRect(x: 35.5, y: 28, width: 100, height: 100),
            extensionHeight: 0, cornerRadius: 50, maskOrigin: .zero,
            progress: offset / 120, strength: 1, compactContact: contact
        )
    }
}
