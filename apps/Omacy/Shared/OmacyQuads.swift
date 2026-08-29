import CoreGraphics
import simd

struct QuadInstance {
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    var uvOrigin: SIMD2<Float>
    var uvSize: SIMD2<Float>
    var color: SIMD4<Float>
}

enum OmacyQuads {
    private static let occupancyBackground = UInt8(OMACY_CELL_HAS_BACKGROUND)
    private static let occupancyGlyph = UInt8(OMACY_CELL_HAS_GLYPH)
    private static let inv255: Float = 1.0 / 255.0

    static func maxCount(cellCount: Int) -> Int { cellCount * 2 }

    @discardableResult
    static func pack(
        cells: UnsafePointer<OmacyCell>,
        cols: Int,
        rows: Int,
        origin: CGPoint,
        cell: CGSize,
        white: AtlasGlyph,
        glyph: (UInt32) -> AtlasGlyph?,
        into dest: UnsafeMutablePointer<QuadInstance>,
        capacity: Int
    ) -> Int {
        var n = 0
        let size = SIMD2<Float>(Float(cell.width), Float(cell.height))
        let ox = Float(origin.x)
        let oy = Float(origin.y)
        let cw = Float(cell.width)
        let ch = Float(cell.height)
        for r in 0..<rows {
            let py = oy + Float(r) * ch
            let row = cells + r * cols
            for c in 0..<cols {
                let cellData = row[c]
                let px = ox + Float(c) * cw
                if cellData.occupancy & occupancyBackground != 0 {
                    guard n < capacity else { return n }
                    dest[n] = QuadInstance(
                        origin: SIMD2(px, py),
                        size: size,
                        uvOrigin: white.uvOrigin,
                        uvSize: white.uvSize,
                        color: SIMD4(
                            Float(cellData.bg_r) * inv255,
                            Float(cellData.bg_g) * inv255,
                            Float(cellData.bg_b) * inv255,
                            Float(cellData.bg_a) * inv255
                        )
                    )
                    n += 1
                }
                if cellData.occupancy & occupancyGlyph != 0, cellData.glyph != 0,
                   let g = glyph(cellData.glyph) {
                    guard n < capacity else { return n }
                    dest[n] = QuadInstance(
                        origin: SIMD2(px, py),
                        size: size,
                        uvOrigin: g.uvOrigin,
                        uvSize: g.uvSize,
                        color: SIMD4(
                            Float(cellData.fg_r) * inv255,
                            Float(cellData.fg_g) * inv255,
                            Float(cellData.fg_b) * inv255,
                            Float(cellData.fg_a) * inv255
                        )
                    )
                    n += 1
                }
            }
        }
        return n
    }
}
