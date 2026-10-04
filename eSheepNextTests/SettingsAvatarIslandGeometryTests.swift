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
            XCTAssertNil(SettingsAvatarIslandGeometry.contact(for: identifier, viewportWidth: 402, displayScale: 3))
        }
    }

    func testFlaredContactStaysInsideTheSoftwareClip() throws {
        for width in [CGFloat(393), 402, 430, 440] {
            for scale in [CGFloat(2), 3] {
                let contact = try XCTUnwrap(SettingsAvatarIslandGeometry.contact(
                    for: "iPhone19,2", viewportWidth: width, displayScale: scale
                ))
                XCTAssertLessThan(contact.halfWidth, width / 10)
                // The shoulder must spread outside the body's 33.4pt radius,
                // rather than turn outward from the rejected narrow bucket lip.
                let attached = mask(offset: 53.33, contact: contact)
                for side in [CGFloat(-1), 1] {
                    XCTAssertTrue(attached.contains(CGPoint(x: 85.5 + side * 34.5, y: 0.1)))
                }
                for offset in stride(from: 0.0, through: 120.0, by: 0.5) {
                    let path = mask(offset: CGFloat(offset), contact: contact)
                    for y in [CGFloat(-0.5 + 0.5 / scale), 0, 1 / scale] {
                        for side in [CGFloat(-1), 1] {
                            XCTAssertFalse(path.contains(CGPoint(x: 85.5 + side * width / 10, y: y)), "offset \(offset)")
                        }
                    }
                }
            }
        }
    }

    func testCompactShoulderRestoresHorizontalInwardFlare() throws {
        let contact = try XCTUnwrap(SettingsAvatarIslandGeometry.contact(
            for: "iPhone19,3", viewportWidth: 402, displayScale: 3
        ))
        for offset in [CGFloat(34), 42, 53.33, 73.33, 93.33, 100] {
            let curves = connectionCurves(in: mask(offset: offset, contact: contact))
            let shoulder = try XCTUnwrap(curves.first)
            XCTAssertLessThan(shoulder.first.x, shoulder.start.x)
            XCTAssertEqual(shoulder.first.y, shoulder.start.y, accuracy: 0.0001)
            XCTAssertGreaterThanOrEqual(shoulder.second.y, shoulder.first.y)
            XCTAssertGreaterThanOrEqual(shoulder.end.y, shoulder.second.y)
            XCTAssertGreaterThanOrEqual(shoulder.first.x, shoulder.second.x)
            XCTAssertGreaterThanOrEqual(shoulder.second.x, shoulder.end.x)
            // Adjacent shoulders/body curves must share their direction at
            // each join, even during the final shallow-bowl retreat.
            for (a, b) in zip(curves, curves.dropFirst()) {
                let incoming = CGPoint(x: a.end.x - a.second.x, y: a.end.y - a.second.y)
                let outgoing = CGPoint(x: b.first.x - b.start.x, y: b.first.y - b.start.y)
                let lengths = hypot(incoming.x, incoming.y) * hypot(outgoing.x, outgoing.y)
                guard lengths > 0.0001 else { continue }
                let cross = incoming.x * outgoing.y - incoming.y * outgoing.x
                XCTAssertEqual(cross / lengths, 0, accuracy: 0.0001)
                XCTAssertGreaterThan(incoming.x * outgoing.x + incoming.y * outgoing.y, 0)
            }
        }
    }

    func testRetreatedConnectionLeavesNoSeparateTopStrip() throws {
        let contact = try XCTUnwrap(SettingsAvatarIslandGeometry.contact(
            for: "iPhone19,7", viewportWidth: 440, displayScale: 3
        ))
        let path = mask(offset: 120, contact: contact)
        XCTAssertEqual(path.boundingBoxOfPath.height, 0, accuracy: 0.0001)
        XCTAssertFalse(path.contains(CGPoint(x: 85.5, y: -0.25)))
    }

    func testLegacyShoulderKeepsItsOriginalControlPoints() throws {
        let shoulder = try XCTUnwrap(connectionCurves(in: mask(offset: 53.33, contact: nil)).first)
        XCTAssertEqual(shoulder.start.x, 85.5 + 45.7, accuracy: 0.0001)
        XCTAssertEqual(shoulder.start.y, 0, accuracy: 0.0001)
        XCTAssertEqual(shoulder.first.x, 85.5 + 42.34, accuracy: 0.0001)
        XCTAssertEqual(shoulder.first.y, 0, accuracy: 0.0001)
        XCTAssertEqual(shoulder.end.x, 85.5 + 28.9, accuracy: 0.0001)
        XCTAssertEqual(shoulder.end.y, 10.4, accuracy: 0.0001)
    }

    func testFullExpansionKeepsTheEntirePhotoAndNameExtension() throws {
        let contact = try XCTUnwrap(SettingsAvatarIslandGeometry.contact(for: "iPhone19,7", viewportWidth: 402, displayScale: 3))
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
        let contact = try XCTUnwrap(SettingsAvatarIslandGeometry.contact(for: "iPhone19,2", viewportWidth: 402, displayScale: 3))
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
        let contact = try XCTUnwrap(SettingsAvatarIslandGeometry.contact(for: "iPhone19,3", viewportWidth: 402, displayScale: 3))
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
        let contact = try XCTUnwrap(SettingsAvatarIslandGeometry.contact(for: "iPhone19,7", viewportWidth: 402, displayScale: 3))
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

    private struct ConnectionCurve {
        let start: CGPoint
        let first: CGPoint
        let second: CGPoint
        let end: CGPoint
    }

    private func connectionCurves(in path: CGPath) -> [ConnectionCurve] {
        var subpathCount = 0
        var point = CGPoint.zero
        var curves: [ConnectionCurve] = []
        path.applyWithBlock { element in
            let points = element.pointee.points
            switch element.pointee.type {
            case .moveToPoint:
                subpathCount += 1
                point = points[0]
            case .addLineToPoint:
                point = points[0]
            case .addCurveToPoint:
                if subpathCount == 2 {
                    curves.append(ConnectionCurve(start: point, first: points[0], second: points[1], end: points[2]))
                }
                point = points[2]
            default:
                break
            }
        }
        return curves
    }

    private func mask(offset: CGFloat, contact: SettingsAvatarIslandGeometry.Contact?) -> CGPath {
        SettingsAvatarMaskPath.make(
            photo: CGRect(x: 35.5, y: 28, width: 100, height: 100),
            extensionHeight: 0, cornerRadius: 50, maskOrigin: .zero,
            progress: offset / 120, strength: 1, compactContact: contact
        )
    }
}
