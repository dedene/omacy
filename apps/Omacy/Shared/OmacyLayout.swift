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

    static func artGrid(_ art: String) -> (cols: Int, rows: Int) {
        let lines = art.split(separator: "\n", omittingEmptySubsequences: false)
        let rows = max(lines.count, 1)
        let cols = max(lines.map(\.count).max() ?? 1, 1)
        return (cols, rows)
    }

    /// Largest font ≤ `cap` whose cell grid still contains `art` inside `size`.
    static func fittingFontSize(art: String, in size: CGSize, cap: CGFloat) -> CGFloat {
        let grid = artGrid(art)
        let padX = max(size.width * 0.08, 24)
        let padY = max(size.height * 0.08, 24)
        let inset = CGSize(
            width: max(size.width - padX * 2, 1),
            height: max(size.height - padY * 2, 1)
        )
        guard grid.cols > 0, grid.rows > 0 else { return max(cap, 8) }
        var lo: CGFloat = 8
        var hi = max(cap, lo)
        var best = lo
        while hi - lo > 0.25 {
            let mid = (lo + hi) / 2
            let cell = cellSize(font: OmacyFont.makeFont(size: mid))
            if cell.width * CGFloat(grid.cols) <= inset.width
                && cell.height * CGFloat(grid.rows) <= inset.height {
                best = mid
                lo = mid
            } else {
                hi = mid
            }
        }
        return best
    }

    /// Scale of this view's window/screen. Never `NSScreen.main` — that is the
    /// key-window display, not this one. Mixed-DPI desks would rasterize the
    /// atlas at the wrong density.
    static func backingScale(for view: NSView) -> CGFloat {
        if let scale = view.window?.backingScaleFactor, scale > 0 {
            return scale
        }
        if let scale = view.window?.screen?.backingScaleFactor, scale > 0 {
            return scale
        }
        if let scale = view.layer?.contentsScale, scale > 0 {
            return scale
        }
        return 2
    }

    static func grid(view: NSView, font: NSFont) -> (cols: UInt32, rows: UInt32, cell: CGSize, origin: CGPoint) {
        let scale = backingScale(for: view)
        let backing = view.convertToBacking(view.bounds.size)
        return grid(viewSize: view.bounds.size, backing: backing, scale: scale, font: font)
    }

    static func grid(viewSize: CGSize, scale: CGFloat, font: NSFont) -> (cols: UInt32, rows: UInt32, cell: CGSize, origin: CGPoint) {
        grid(viewSize: viewSize, backing: CGSize(width: viewSize.width * scale, height: viewSize.height * scale), scale: scale, font: font)
    }

    static func grid(
        viewSize: CGSize,
        backing: CGSize,
        scale: CGFloat,
        font: NSFont
    ) -> (cols: UInt32, rows: UInt32, cell: CGSize, origin: CGPoint) {
        grid(
            viewSize: viewSize,
            backing: backing,
            scale: scale,
            cell: cellSize(font: font)
        )
    }

    /// Pure geometry path. Keeping cell metrics separate from font lookup makes
    /// the grid math deterministic and independently testable across OS fonts.
    static func grid(
        viewSize: CGSize,
        backing: CGSize,
        scale: CGFloat,
        cell: CGSize
    ) -> (cols: UInt32, rows: UInt32, cell: CGSize, origin: CGPoint) {
        let points = treatedAsPoints(viewSize: viewSize, backing: backing, scale: scale)
        var cols = max(Self.minCells, Int(floor(points.width / cell.width)))
        var rows = max(Self.minCells, Int(floor(points.height / cell.height)))
        cols = min(cols, Self.maxAxis)
        rows = min(rows, Self.maxAxis)
        if cols * rows > Self.maxCells {
            let ratio = sqrt(Double(Self.maxCells) / Double(cols * rows))
            cols = max(Self.minCells, Int(Double(cols) * ratio))
            rows = max(Self.minCells, Int(Double(rows) * ratio))
        }
        let origin = publishedOrigin(
            cols: UInt32(cols),
            rows: UInt32(rows),
            cell: cell,
            points: points,
            scale: scale
        )
        return (UInt32(cols), UInt32(rows), cell, origin)
    }

    /// Center a published engine grid in the view. `grid()` origin is the view-fitted
    /// cell mesh remainder — wrong when the live session is still the previous size.
    static func publishedOrigin(
        cols: UInt32,
        rows: UInt32,
        cell: CGSize,
        points: CGSize,
        scale: CGFloat
    ) -> CGPoint {
        pixelAlign(
            CGPoint(
                x: (points.width - CGFloat(cols) * cell.width) / 2,
                y: (points.height - CGFloat(rows) * cell.height) / 2
            ),
            scale: scale
        )
    }

    static func pixelAlign(_ point: CGPoint, scale: CGFloat) -> CGPoint {
        let s = max(scale, 1)
        return CGPoint(
            x: (point.x * s).rounded() / s,
            y: (point.y * s).rounded() / s
        )
    }

    /// Tahoe may hand backing pixels as bounds. An exact 2× jump vs backingScale is scale, not a giant canvas.
    static func treatedAsPoints(viewSize: CGSize, backing: CGSize, scale: CGFloat) -> CGSize {
        guard scale > 1 else { return viewSize }
        if abs(backing.width - viewSize.width * scale) < 1, abs(backing.height - viewSize.height * scale) < 1 {
            return viewSize
        }
        if abs(backing.width - viewSize.width) < 1, abs(backing.height - viewSize.height) < 1 {
            return CGSize(width: viewSize.width / scale, height: viewSize.height / scale)
        }
        return viewSize
    }

    static func viewportSize(viewSize: CGSize, backing: CGSize, scale: CGFloat) -> CGSize {
        treatedAsPoints(viewSize: viewSize, backing: backing, scale: scale)
    }

    static func drawableSize(viewSize: CGSize, backing: CGSize, scale: CGFloat) -> CGSize {
        let points = treatedAsPoints(viewSize: viewSize, backing: backing, scale: scale)
        return CGSize(
            width: max((points.width * scale).rounded(), 1),
            height: max((points.height * scale).rounded(), 1)
        )
    }

    static func drawableSize(viewSize: CGSize, scale: CGFloat) -> CGSize {
        drawableSize(
            viewSize: viewSize,
            backing: CGSize(width: viewSize.width * scale, height: viewSize.height * scale),
            scale: scale
        )
    }

    static func drawableSizeChanged(current: CGSize, proposed: CGSize) -> Bool {
        abs(current.width - proposed.width) >= 1 || abs(current.height - proposed.height) >= 1
    }
}
