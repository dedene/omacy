import AppKit
import CoreText

enum OmacyFont {
    private static var graphicsFont: CGFont?
    private static var cached: (size: CGFloat, font: NSFont)?

    static func makeFont(size: CGFloat) -> NSFont {
        if let cached, abs(cached.size - size) < 0.01 {
            return cached.font
        }
        if graphicsFont == nil, let url = OmacyStore.bundledFontURL {
            if let data = try? Data(contentsOf: url) as CFData,
               let provider = CGDataProvider(data: data) {
                graphicsFont = CGFont(provider)
            }
        }
        if let cg = graphicsFont,
           let font = CTFontCreateWithGraphicsFont(cg, size, nil, nil) as NSFont? {
            cached = (size, font)
            return font
        }
        let fallback = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        cached = (size, fallback)
        return fallback
    }
}
