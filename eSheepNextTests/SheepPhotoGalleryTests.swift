import XCTest
@testable import eSheepNext

final class SheepPhotoGalleryTests: XCTestCase {
    func testTimelineSelectionKeepsWholeGalleryAndMatchingDate() throws {
        let first = photo(at: 1_000)
        let second = photo(at: 2_000)
        let third = photo(at: 3_000)
        let gallery = try XCTUnwrap(SheepPhotoPreviewItem(
            photos: [first, second, third], selectedPhotoID: second.id
        ))
        XCTAssertEqual(gallery.photos.map(\.id), [first.id, second.id, third.id])
        XCTAssertEqual(gallery.initialPhotoID, second.id)
        XCTAssertEqual(gallery.photos.first { $0.id == gallery.initialPhotoID }?.displayedAt, second.displayedAt)
    }

    func testDuplicateCoverPhotoDoesNotCreateAnExtraPage() throws {
        let first = photo(at: 1_000)
        let second = photo(at: 2_000)
        let gallery = try XCTUnwrap(SheepPhotoPreviewItem(photos: [first, first, second]))
        XCTAssertEqual(gallery.photos.map(\.id), [first.id, second.id])
        XCTAssertEqual(gallery.initialPhotoID, first.id)
    }

    func testMissingSelectionStartsAtFirstAvailablePhoto() throws {
        let first = photo(at: 1_000)
        let gallery = try XCTUnwrap(SheepPhotoPreviewItem(photos: [first], selectedPhotoID: UUID()))
        XCTAssertEqual(gallery.initialPhotoID, first.id)
    }

    func testEmptyGalleryDoesNotPresent() {
        XCTAssertNil(SheepPhotoPreviewItem(photos: []))
    }

    private func photo(at timestamp: TimeInterval) -> SheepPhotoPreviewItem.Photo {
        .init(
            reference: SheepPhotoReference(id: UUID(), digest: "photo-\(timestamp)"),
            displayedAt: Date(timeIntervalSince1970: timestamp)
        )
    }
}
