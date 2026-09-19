import UIKit
import XCTest
@testable import eSheepNext

@MainActor
final class AccountAvatarCropTests: XCTestCase {
    func testExtremeDragsNeverExposeBlankPixels() {
        for size in [CGSize(width: 2400, height: 800), CGSize(width: 800, height: 2400), CGSize(width: 600, height: 600)] {
            for zoom: CGFloat in [0.5, 1, 2, 4, 8] {
                for offset in [CGSize(width: -100, height: 100), CGSize(width: 100, height: -100), .zero] {
                    let rect = AvatarCropGeometry.drawRect(imageSize: size, side: 384, zoom: zoom, offset: offset)
                    XCTAssertLessThanOrEqual(rect.minX, 0.001)
                    XCTAssertLessThanOrEqual(rect.minY, 0.001)
                    XCTAssertGreaterThanOrEqual(rect.maxX, 383.999)
                    XCTAssertGreaterThanOrEqual(rect.maxY, 383.999)
                }
            }
        }
    }

    func testExportMatchesPreviewAcrossViewportSizes() {
        let size = CGSize(width: 1200, height: 1800)
        let offset = CGSize(width: 0.15, height: -0.4)
        let preview = AvatarCropGeometry.drawRect(imageSize: size, side: 290, zoom: 2.3, offset: offset)
        let export = AvatarCropGeometry.drawRect(imageSize: size, side: 384, zoom: 2.3, offset: offset)
        XCTAssertEqual(preview.minX / 290, export.minX / 384, accuracy: 0.00001)
        XCTAssertEqual(preview.minY / 290, export.minY / 384, accuracy: 0.00001)
        XCTAssertEqual(preview.width / 290, export.width / 384, accuracy: 0.00001)
        XCTAssertEqual(preview.height / 290, export.height / 384, accuracy: 0.00001)
    }

    func testSelectingLeftAndRightCropExportsDifferentPixels() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 400), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 400, y: 0, width: 400, height: 400))
        }
        let left = try XCTUnwrap(ProfileAvatarProcessor.makeJPEG(from: image, zoom: 1, offset: CGSize(width: 0.5, height: 0)))
        let right = try XCTUnwrap(ProfileAvatarProcessor.makeJPEG(from: image, zoom: 1, offset: CGSize(width: -0.5, height: 0)))
        XCTAssertNotEqual(left, right)
        for (data, expectedRed) in [(left, true), (right, false)] {
            let decoded = try XCTUnwrap(UIImage(data: data)?.cgImage)
            XCTAssertEqual(decoded.width, 384)
            XCTAssertEqual(decoded.height, 384)
            var pixel = [UInt8](repeating: 0, count: 4)
            let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(decoded, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            XCTAssertGreaterThan(expectedRed ? pixel[0] : pixel[2], 240)
            XCTAssertLessThan(expectedRed ? pixel[2] : pixel[0], 15)
        }
    }

    func testPreviewDownsamplesAndNormalizesOrientation() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 3000, height: 1500), format: format).image { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 3000, height: 1500))
        }
        let rotated = UIImage(cgImage: try XCTUnwrap(image.cgImage), scale: 1, orientation: .right)
        let data = try XCTUnwrap(rotated.jpegData(compressionQuality: 0.9))
        let preview = try XCTUnwrap(ProfileAvatarProcessor.previewImage(from: data))
        XCTAssertEqual(preview.imageOrientation, .up)
        XCTAssertEqual(max(preview.size.width, preview.size.height), 2048)
        XCTAssertGreaterThan(preview.size.height, preview.size.width)
    }

    func testUnreadableImageIsRejected() {
        XCTAssertNil(ProfileAvatarProcessor.previewImage(from: Data("invalid image".utf8)))
        XCTAssertEqual(AvatarCropGeometry.drawRect(imageSize: .zero, side: 384, zoom: 1, offset: .zero), .zero)
    }
}
