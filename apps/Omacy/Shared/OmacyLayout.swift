import AppKit

enum OmacyLayout {
    static let defaultFontSize: CGFloat = 18
    static let minCells = 1
    static let maxAxis = 512
    static let maxCells = 32_768

    static func cellSize(font: NSFont) -> CGSize {
        let advance = font.advancement(forGlyph: font.glyph(withName: "M")).width
        let width = advance > 0 ? advance : font.maximumAdvancement.width
        return CGSize(width: max(width, 1), height: max(font.pointSize, 1))
    }

    static func grid(viewSize: CGSize, scale: CGFloat, font: NSFont) -> (cols: UInt32, rows: UInt32, cell: CGSize, origin: CGPoint) {
        let points = treatedAsPoints(viewSize: viewSize, scale: scale)
        let cell = cellSize(font: font)
        var cols = max(Self.minCells, Int(floor(points.width / cell.width)))
        var rows = max(Self.minCells, Int(floor(points.height / cell.height)))
        cols = min(cols, Self.maxAxis)
        rows = min(rows, Self.maxAxis)
        if cols * rows > Self.maxCells {
            let ratio = sqrt(Double(Self.maxCells) / Double(cols * rows))
            cols = max(Self.minCells, Int(Double(cols) * ratio))
            rows = max(Self.minCells, Int(Double(rows) * ratio))
        }
        let gridWidth = CGFloat(cols) * cell.width
        let gridHeight = CGFloat(rows) * cell.height
        let origin = CGPoint(
            x: (points.width - gridWidth) / 2,
            y: (points.height - gridHeight) / 2
        )
        return (UInt32(cols), UInt32(rows), cell, origin)
    }

    /// Tahoe may hand backing pixels as bounds. An exact 2× jump vs backingScale is scale, not a giant canvas.
    static func treatedAsPoints(viewSize: CGSize, scale: CGFloat) -> CGSize {
        guard scale == 2 else { return viewSize }
        return viewSize
    }
}
