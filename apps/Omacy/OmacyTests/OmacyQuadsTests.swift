import CoreGraphics
import XCTest
@testable import Omacy

final class OmacyQuadsTests: XCTestCase {
    private let white = AtlasGlyph(uvOrigin: SIMD2(0.1, 0.2), uvSize: SIMD2(0.3, 0.4))
    private let glyph = AtlasGlyph(uvOrigin: SIMD2(0.5, 0.6), uvSize: SIMD2(0.7, 0.8))

    func testEmptyCellProducesNoQuads() {
        XCTAssertEqual(pack(occupancy: 0, glyphCode: 0).count, 0)
    }

    func testBackgroundOnlyCellProducesBackgroundQuad() {
        let result = pack(occupancy: UInt8(OMACY_CELL_HAS_BACKGROUND), glyphCode: 0)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.quads[0].uvOrigin, white.uvOrigin)
        assertColor(result.quads[0].color, equals: SIMD4(10.0 / 255, 20.0 / 255, 30.0 / 255, 40.0 / 255))
    }

    func testGlyphOnlyCellProducesGlyphQuad() {
        let result = pack(occupancy: UInt8(OMACY_CELL_HAS_GLYPH), glyphCode: 65)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.quads[0].uvOrigin, glyph.uvOrigin)
        assertColor(result.quads[0].color, equals: SIMD4(50.0 / 255, 60.0 / 255, 70.0 / 255, 80.0 / 255))
    }

    func testBackgroundAndGlyphCellProducesBackgroundThenGlyph() {
        let result = pack(occupancy: UInt8(OMACY_CELL_HAS_BACKGROUND | OMACY_CELL_HAS_GLYPH), glyphCode: 65)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.quads[0].uvOrigin, white.uvOrigin)
        XCTAssertEqual(result.quads[1].uvOrigin, glyph.uvOrigin)
    }

    func testGlyphOccupancyWithZeroGlyphProducesNoQuad() {
        XCTAssertEqual(pack(occupancy: UInt8(OMACY_CELL_HAS_GLYPH), glyphCode: 0).count, 0)
    }

    func testMissingGlyphProducesNoQuad() {
        XCTAssertEqual(pack(occupancy: UInt8(OMACY_CELL_HAS_GLYPH), glyphCode: 66).count, 0)
    }

    func testCapacityStopsPackingBeforeGlyph() {
        var cell = makeCell(occupancy: UInt8(OMACY_CELL_HAS_BACKGROUND | OMACY_CELL_HAS_GLYPH), glyphCode: 65)
        var destination = QuadInstance(origin: .zero, size: .zero, uvOrigin: .zero, uvSize: .zero, color: .zero)

        let count = withUnsafePointer(to: &cell) { cells in
            OmacyQuads.pack(cells: cells, cols: 1, rows: 1, origin: .zero, cell: CGSize(width: 4, height: 5), white: white, glyph: { $0 == 65 ? glyph : nil }, into: &destination, capacity: 1)
        }

        XCTAssertEqual(count, 1)
        XCTAssertEqual(destination.uvOrigin, white.uvOrigin)
    }

    func testMultiCellGridUsesRowAndColumnCoordinates() {
        var cells = (0..<4).map { _ in makeCell(occupancy: UInt8(OMACY_CELL_HAS_BACKGROUND), glyphCode: 0) }
        var quads = Array(repeating: QuadInstance(origin: .zero, size: .zero, uvOrigin: .zero, uvSize: .zero, color: .zero), count: 4)

        let count = cells.withUnsafeBufferPointer { source in
            quads.withUnsafeMutableBufferPointer { destination in
                OmacyQuads.pack(cells: source.baseAddress!, cols: 2, rows: 2, origin: CGPoint(x: 1, y: 2), cell: CGSize(width: 4, height: 5), white: white, glyph: { _ in nil }, into: destination.baseAddress!, capacity: destination.count)
            }
        }

        XCTAssertEqual(count, 4)
        XCTAssertEqual(quads.map(\.origin), [SIMD2(1, 2), SIMD2(5, 2), SIMD2(1, 7), SIMD2(5, 7)])
    }

    private func pack(occupancy: UInt8, glyphCode: UInt32) -> (count: Int, quads: [QuadInstance]) {
        var cell = makeCell(occupancy: occupancy, glyphCode: glyphCode)

        var quads = Array(repeating: QuadInstance(origin: .zero, size: .zero, uvOrigin: .zero, uvSize: .zero, color: .zero), count: 2)
        let count = quads.withUnsafeMutableBufferPointer { destination in
            withUnsafePointer(to: &cell) { cells in
                OmacyQuads.pack(cells: cells, cols: 1, rows: 1, origin: CGPoint(x: 2, y: 3), cell: CGSize(width: 4, height: 5), white: white, glyph: { $0 == 65 ? glyph : nil }, into: destination.baseAddress!, capacity: destination.count)
            }
        }
        return (count, Array(quads.prefix(count)))
    }

    private func makeCell(occupancy: UInt8, glyphCode: UInt32) -> OmacyCell {
        var cell = OmacyCell()
        cell.glyph = glyphCode
        cell.fg_r = 50; cell.fg_g = 60; cell.fg_b = 70; cell.fg_a = 80
        cell.bg_r = 10; cell.bg_g = 20; cell.bg_b = 30; cell.bg_a = 40
        cell.occupancy = occupancy
        return cell
    }

    private func assertColor(_ actual: SIMD4<Float>, equals expected: SIMD4<Float>, file: StaticString = #filePath, line: UInt = #line) {
        for index in 0..<4 {
            XCTAssertEqual(actual[index], expected[index], accuracy: 0.000_001, file: file, line: line)
        }
    }
}
