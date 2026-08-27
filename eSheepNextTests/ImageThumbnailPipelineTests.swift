import XCTest
import UIKit
@testable import eSheepNext

@MainActor
final class ImageThumbnailPipelineTests: XCTestCase {
    func testDownsamplesLargeImageToRequestedPixelBound() async throws {
        let pipeline = ImageThumbnailPipeline(countLimit: 4, totalCostLimit: 2 * 1_024 * 1_024)
        let data = try XCTUnwrap(makeJPEG(size: CGSize(width: 1_200, height: 800)))

        let thumbnail = await pipeline.thumbnail(
            data: data,
            digest: "large-image",
            targetSize: CGSize(width: 120, height: 80),
            scale: 2
        )

        let image = try XCTUnwrap(thumbnail?.cgImage)
        XCTAssertLessThanOrEqual(max(image.width, image.height), 240)
        XCTAssertGreaterThan(image.width, 0)
        XCTAssertGreaterThan(image.height, 0)
    }

    func testInvalidImageDataReturnsNil() async {
        let pipeline = ImageThumbnailPipeline(countLimit: 4, totalCostLimit: 1_024)

        let thumbnail = await pipeline.thumbnail(
            data: Data("not-an-image".utf8),
            digest: "invalid",
            targetSize: CGSize(width: 64, height: 64),
            scale: 2
        )

        XCTAssertNil(thumbnail)
    }

    func testInvalidatingDigestDoesNotBreakSubsequentDecode() async throws {
        let pipeline = ImageThumbnailPipeline(countLimit: 4, totalCostLimit: 2 * 1_024 * 1_024)
        let data = try XCTUnwrap(makeJPEG(size: CGSize(width: 400, height: 400)))
        let first = await pipeline.thumbnail(
            data: data,
            digest: "avatar",
            targetSize: CGSize(width: 80, height: 80),
            scale: 2
        )
        await pipeline.invalidate(digest: "avatar")
        let second = await pipeline.thumbnail(
            data: data,
            digest: "avatar",
            targetSize: CGSize(width: 80, height: 80),
            scale: 2
        )

        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
    }

    private func makeJPEG(size: CGSize) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return image.jpegData(compressionQuality: 0.9)
    }
}
