import AppKit
import QuartzCore

/// Fixed asymmetric canary grid: glyph in the top-right cell, colored blank in the bottom-left.
/// Used to prove the appex paints before (and if) the engine is wired in.
final class OmacyCanaryAnimator {
    private weak var parentLayer: CALayer?
    private let gridLayer = CALayer()
    private let glyphLayer = CATextLayer()
    private let blankLayer = CALayer()

    var currentBackgroundColor: NSColor { .black }

    func attach(to layer: CALayer) {
        parentLayer = layer
        layer.backgroundColor = NSColor.black.cgColor
        layer.isOpaque = true
        gridLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        if gridLayer.superlayer == nil {
            layer.addSublayer(gridLayer)
        }
        blankLayer.backgroundColor = NSColor(red: 0.15, green: 0.45, blue: 0.95, alpha: 1).cgColor
        glyphLayer.string = "X"
        glyphLayer.foregroundColor = NSColor.white.cgColor
        glyphLayer.alignmentMode = .center
        glyphLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        if blankLayer.superlayer == nil { gridLayer.addSublayer(blankLayer) }
        if glyphLayer.superlayer == nil { gridLayer.addSublayer(glyphLayer) }
    }

    func start() {}
    func stop() {}

    func updateBounds(_ bounds: CGRect) {
        gridLayer.frame = bounds
        let font = OmacyFont.makeFont(size: OmacyLayout.defaultFontSize)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let layout = OmacyLayout.grid(viewSize: bounds.size, scale: scale, font: font)
        let cell = layout.cell
        let origin = layout.origin
        blankLayer.frame = CGRect(
            x: origin.x,
            y: origin.y + CGFloat(layout.rows - 1) * cell.height,
            width: cell.width,
            height: cell.height
        )
        glyphLayer.frame = CGRect(
            x: origin.x + CGFloat(layout.cols - 1) * cell.width,
            y: origin.y,
            width: cell.width,
            height: cell.height
        )
        glyphLayer.font = font
        glyphLayer.fontSize = font.pointSize
    }
}

enum OmacyFont {
    static func makeFont(size: CGFloat) -> NSFont {
        if let url = OmacyStore.bundledFontURL,
           let data = try? Data(contentsOf: url) as CFData,
           let provider = CGDataProvider(data: data),
           let cg = CGFont(provider),
           let font = CTFontCreateWithGraphicsFont(cg, size, nil, nil) as NSFont? {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}
