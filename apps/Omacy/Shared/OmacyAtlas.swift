import AppKit
import CoreText
import Metal

struct AtlasGlyph {
    var uvOrigin: SIMD2<Float>
    var uvSize: SIMD2<Float>
}

final class OmacyAtlas {
    private(set) var texture: MTLTexture?
    private(set) var generation: UInt64 = 0
    private var map: [UInt32: AtlasGlyph] = [:]
    private var extraCount = 0
    private let extraCap = 256
    private let pad = 1
    private var cell: CGSize = .zero
    private var pixels: [UInt8] = []
    private var texWidth = 1
    private var texHeight = 1
    private var glyphW = 1
    private var glyphH = 1
    private var slotW = 1
    private var slotH = 1
    private var cols = 1
    private var nextSlot = 1
    private var builtCell: CGSize = .zero
    private var builtScale: CGFloat = 0
    private var builtFontName = ""
    private var builtFontSize: CGFloat = 0

    private let preload: [UInt32] = {
        var codes: [UInt32] = Array(0x20...0x7E)
        codes.append(contentsOf: 0x2800...0x28FF)
        codes.append(contentsOf: [0x2580, 0x2584, 0x2588, 0x2591, 0x2592, 0x2593])
        return codes
    }()

    func needsRebuild(font: NSFont, cell: CGSize, scale: CGFloat) -> Bool {
        abs(cell.width - builtCell.width) >= 0.5
            || abs(cell.height - builtCell.height) >= 0.5
            || abs(scale - builtScale) >= 0.01
            || font.fontName != builtFontName
            || abs(font.pointSize - builtFontSize) >= 0.01
    }

    func rebuild(device: MTLDevice, font: NSFont, cell: CGSize, scale: CGFloat) {
        self.cell = cell
        builtCell = cell
        builtScale = max(scale, 1)
        builtFontName = font.fontName
        builtFontSize = font.pointSize
        extraCount = 0
        map.removeAll()
        nextSlot = 1
        generation &+= 1
        glyphW = max(Int(ceil(cell.width * builtScale)), 1)
        glyphH = max(Int(ceil(cell.height * builtScale)), 1)
        slotW = glyphW + pad * 2
        slotH = glyphH + pad * 2
        let count = preload.count + extraCap + 1
        cols = Int(ceil(sqrt(Double(count))))
        let rows = Int(ceil(Double(count) / Double(cols)))
        texWidth = max(cols * slotW, 1)
        texHeight = max(rows * slotH, 1)
        pixels = Array(repeating: 0, count: texWidth * texHeight * 4)
        writeWhitePixel(x: 0, y: 0)
        map[0] = AtlasGlyph(
            uvOrigin: SIMD2(0, 0),
            uvSize: SIMD2(1 / Float(texWidth), 1 / Float(texHeight))
        )
        let pixelFont = CTFontCreateCopyWithAttributes(font as CTFont, font.pointSize * builtScale, nil, nil)
        for scalar in preload {
            _ = stamp(font: pixelFont, scalar: scalar)
        }
        uploadFull(device: device)
    }

    var whitePixel: AtlasGlyph {
        map[0] ?? AtlasGlyph(uvOrigin: SIMD2(0, 0), uvSize: SIMD2(1 / Float(max(texWidth, 1)), 1 / Float(max(texHeight, 1))))
    }

    func lookup(_ scalar: UInt32) -> AtlasGlyph? {
        map[scalar]
    }

    func glyph(for scalar: UInt32, font: NSFont, device: MTLDevice) -> AtlasGlyph? {
        if let hit = map[scalar] { return hit }
        if extraCount >= extraCap { return nil }
        let pixelFont = CTFontCreateCopyWithAttributes(font as CTFont, font.pointSize * max(builtScale, 1), nil, nil)
        guard let g = stamp(font: pixelFont, scalar: scalar) else { return nil }
        extraCount += 1
        generation &+= 1
        uploadSlot(device: device, slot: nextSlot - 1)
        return g
    }

    private func uploadFull(device: MTLDevice) {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: texWidth,
            height: texHeight,
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: desc) else { return }
        pixels.withUnsafeBytes { raw in
            texture.replace(
                region: MTLRegionMake2D(0, 0, texWidth, texHeight),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: texWidth * 4
            )
        }
        self.texture = texture
    }

    private func uploadSlot(device: MTLDevice, slot: Int) {
        guard let texture else {
            uploadFull(device: device)
            return
        }
        let col = slot % cols
        let row = slot / cols
        let x = col * slotW
        let y = row * slotH
        var rowBytes = [UInt8](repeating: 0, count: slotW * slotH * 4)
        for gy in 0..<slotH {
            let src = (y + gy) * texWidth * 4 + x * 4
            let dst = gy * slotW * 4
            if src + slotW * 4 <= pixels.count {
                rowBytes.replaceSubrange(dst..<(dst + slotW * 4), with: pixels[src..<(src + slotW * 4)])
            }
        }
        rowBytes.withUnsafeBytes { raw in
            texture.replace(
                region: MTLRegionMake2D(x, y, slotW, slotH),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: slotW * 4
            )
        }
    }

    private func writeWhitePixel(x: Int, y: Int) {
        let i = (y * texWidth + x) * 4
        if i + 3 < pixels.count {
            pixels[i] = 255
            pixels[i + 1] = 255
            pixels[i + 2] = 255
            pixels[i + 3] = 255
        }
    }

    private func stamp(font: CTFont, scalar: UInt32) -> AtlasGlyph? {
        guard UnicodeScalar(scalar) != nil else { return nil }
        let slot = nextSlot
        nextSlot += 1
        let col = slot % cols
        let row = slot / cols
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: slotW,
            height: slotH,
            bitsPerComponent: 8,
            bytesPerRow: slotW * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: slotW, height: slotH))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        var utf16 = Array(String(UnicodeScalar(scalar)!).utf16)
        var glyph: CGGlyph = 0
        _ = utf16.withUnsafeMutableBufferPointer { buf in
            CTFontGetGlyphsForCharacters(font, buf.baseAddress!, &glyph, 1)
        }
        let descent = CTFontGetDescent(font)
        let baselineY = CGFloat(pad) + min(max(descent, 0), CGFloat(glyphH))
        var point = CGPoint(x: CGFloat(pad), y: baselineY)
        CTFontDrawGlyphs(font, &glyph, &point, 1, ctx)
        if let data = ctx.data {
            let src = data.bindMemory(to: UInt8.self, capacity: slotW * slotH * 4)
            let destX = col * slotW
            let destY = row * slotH
            for gy in 0..<slotH {
                let si = gy * slotW * 4
                let di = ((destY + gy) * texWidth + destX) * 4
                if di + slotW * 4 <= pixels.count {
                    pixels.replaceSubrange(di..<(di + slotW * 4), with: UnsafeBufferPointer(start: src + si, count: slotW * 4))
                }
            }
        }
        let g = AtlasGlyph(
            uvOrigin: SIMD2(
                Float(col * slotW + pad) / Float(texWidth),
                Float(row * slotH + pad) / Float(texHeight)
            ),
            uvSize: SIMD2(Float(glyphW) / Float(texWidth), Float(glyphH) / Float(texHeight))
        )
        map[scalar] = g
        return g
    }
}
