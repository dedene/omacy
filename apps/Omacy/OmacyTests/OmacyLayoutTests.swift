import AppKit
import XCTest
@testable import Omacy

final class OmacyLayoutTests: XCTestCase {
    func testArtGridPreservesEmptyLinesAndFindsWidestRow() {
        let grid = OmacyLayout.artGrid("ab\n\nwxyz")
        XCTAssertEqual(grid.cols, 4)
        XCTAssertEqual(grid.rows, 3)
    }

    func testGridCapsEachAxisAndTotalCellCount() {
        let font = NSFont.monospacedSystemFont(ofSize: 8, weight: .regular)
        let grid = OmacyLayout.grid(viewSize: CGSize(width: 100_000, height: 100_000), scale: 2, font: font)
        XCTAssertLessThanOrEqual(grid.cols, UInt32(OmacyLayout.maxAxis))
        XCTAssertLessThanOrEqual(grid.rows, UInt32(OmacyLayout.maxAxis))
        XCTAssertLessThanOrEqual(Int(grid.cols) * Int(grid.rows), OmacyLayout.maxCells)
    }

    func testTreatsPixelSizedBoundsAsPointsOnRetinaDisplay() {
        let points = OmacyLayout.treatedAsPoints(viewSize: CGSize(width: 1920, height: 1080), backing: CGSize(width: 1920, height: 1080), scale: 2)
        XCTAssertEqual(points.width, 960)
        XCTAssertEqual(points.height, 540)
    }

    func testKeepsPointSizedBoundsWhenBackingSizeMatchesScale() {
        let points = OmacyLayout.treatedAsPoints(viewSize: CGSize(width: 960, height: 540), backing: CGSize(width: 1920, height: 1080), scale: 2)
        XCTAssertEqual(points.width, 960)
        XCTAssertEqual(points.height, 540)
    }

    func testGridGeometryMatchesDeterministicFixture() {
        let grid = OmacyLayout.grid(
            viewSize: CGSize(width: 100, height: 50),
            backing: CGSize(width: 200, height: 100),
            scale: 2,
            cell: CGSize(width: 6.25, height: 10)
        )

        XCTAssertEqual(grid.cols, 16)
        XCTAssertEqual(grid.rows, 5)
        XCTAssertEqual(grid.cell.width, 6.25)
        XCTAssertEqual(grid.cell.height, 10)
        XCTAssertEqual(grid.origin.x, 0)
        XCTAssertEqual(grid.origin.y, 0)
    }

    func testPublishedOriginAndPixelAlignmentMatchFixture() {
        let origin = OmacyLayout.publishedOrigin(
            cols: 3,
            rows: 2,
            cell: CGSize(width: 7, height: 9),
            points: CGSize(width: 100, height: 50),
            scale: 2
        )

        XCTAssertEqual(origin, CGPoint(x: 39.5, y: 16))
        XCTAssertEqual(OmacyLayout.pixelAlign(CGPoint(x: 1.24, y: 2.26), scale: 2), CGPoint(x: 1, y: 2.5))
    }

    func testDrawableAndViewportSizesMatchRetinaFixtures() {
        let pixelBounds = CGSize(width: 1920, height: 1080)

        XCTAssertEqual(
            OmacyLayout.viewportSize(viewSize: pixelBounds, backing: pixelBounds, scale: 2),
            CGSize(width: 960, height: 540)
        )
        XCTAssertEqual(
            OmacyLayout.drawableSize(viewSize: pixelBounds, backing: pixelBounds, scale: 2),
            CGSize(width: 1920, height: 1080)
        )
        XCTAssertFalse(OmacyLayout.drawableSizeChanged(current: CGSize(width: 100, height: 100), proposed: CGSize(width: 100.9, height: 99.1)))
        XCTAssertTrue(OmacyLayout.drawableSizeChanged(current: CGSize(width: 100, height: 100), proposed: CGSize(width: 101, height: 100)))
    }

    func testArtCanvasColumnPreviewHeightAccountsForCaptionBottomPadding() {
        // Mirrors ArtCanvasColumn's layout arithmetic: previewH must absorb the
        // caption's bottom padding so editorH + previewH + captionH + padding
        // exactly fills the available height (no overflow/clipping).
        let availableHeight: CGFloat = 700
        let editorH = ArtMetrics.editorHeight(availableHeight: availableHeight)
        let captionH = ArtMetrics.captionHeight
        let captionBottomPadding = ArtMetrics.captionBottomPadding
        let previewH = max(120, availableHeight - editorH - captionH - captionBottomPadding)

        XCTAssertEqual(editorH + previewH + captionH + captionBottomPadding, availableHeight)
    }

    func testFittingFontHonorsCapWithDeterministicBinarySearchResult() {
        XCTAssertEqual(
            OmacyLayout.fittingFontSize(art: "M", in: CGSize(width: 2_000, height: 2_000), cap: 20),
            19.8125,
            accuracy: 0.000_001
        )
    }
}
