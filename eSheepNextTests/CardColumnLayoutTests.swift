import CoreGraphics
import XCTest
@testable import eSheepNext

final class CardColumnLayoutTests: XCTestCase {
    func testNarrowProposalDoesNotSqueezeCardsIntoTwoColumns() {
        XCTAssertNil(CardColumnWidths.resolve(width: 466, spacing: 18, division: nil))
        XCTAssertNil(CardColumnWidths.resolve(width: 0, spacing: 18, division: nil))
    }

    func testWideProposalReflowsAroundAnEvenGutter() throws {
        let columns = try XCTUnwrap(CardColumnWidths.resolve(width: 800, spacing: 18, division: nil))
        XCTAssertEqual(columns.leading, 391)
        XCTAssertEqual(columns.trailingOrigin, 409)
        XCTAssertEqual(columns.trailing, 391)
    }

    func testActiveFoldUsesItsAsymmetricFrameWithoutAddingMarginsAgain() throws {
        let division = CardLayoutDivision(frame: CGRect(x: 400, y: 0, width: 60, height: 600), isActive: true)
        let columns = try XCTUnwrap(CardColumnWidths.resolve(width: 800, spacing: 18, division: division))
        XCTAssertEqual(columns.leading, 400)
        XCTAssertEqual(columns.trailingOrigin, 460)
        XCTAssertEqual(columns.trailing, 340)
        XCTAssertEqual(columns.trailingOrigin + columns.trailing, 800)
    }

    func testInactiveFoldKeepsItsGutterWithoutConsumingActiveMargins() throws {
        let division = CardLayoutDivision(frame: CGRect(x: 420, y: 0, width: 12, height: 600), isActive: false)
        let columns = try XCTUnwrap(CardColumnWidths.resolve(width: 800, spacing: 18, division: division))
        XCTAssertEqual(columns.leading, 417)
        XCTAssertEqual(columns.trailingOrigin, 435)
    }

    func testHorizontalFoldDoesNotSplitScrollingCards() throws {
        let division = CardLayoutDivision(frame: CGRect(x: 0, y: 300, width: 800, height: 12), isActive: true)
        XCTAssertEqual(CardColumnWidths.resolve(width: 800, spacing: 18, division: division),
                       CardColumnWidths.resolve(width: 800, spacing: 18, division: nil))
    }

    func testInsufficientRoomBesideTheFoldFallsBackToOneColumn() {
        let division = CardLayoutDivision(frame: CGRect(x: 250, y: 0, width: 12, height: 600), isActive: true)
        XCTAssertNil(CardColumnWidths.resolve(width: 800, spacing: 18, division: division))
    }
}
