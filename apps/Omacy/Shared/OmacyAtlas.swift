import AppKit
import CoreText
import Metal

struct AtlasGlyph {
    var uvOrigin: SIMD2<Float>
    var uvSize: SIMD2<Float>
}

final class OmacyAtlas {
    private(set) var texture: MTLTexture?
    private var map: [UInt32: AtlasGlyph] = [:]
    private var extraCount = 0
    private let extraCap = 256
    private var cell: CGSize = .zero
    private var pixels: [UInt8] = []
    private var texWidth = 1
    private var texHeight = 1
    private var glyphW = 1
    private var glyphH = 1
    private var cols = 1
    private var nextSlot = 1

    private let preload: [UInt32] = {
        var codes: [UInt32] = Array(0x20...0x7E)
        codes.append(contentsOf: 0x2800...0x28FF)
        codes.append(contentsOf: [0x2580, 0x2584, 0x2588, 0x2591, 0x2592, 0x2593])
        return codes
    }()

    func rebuild(device: MTLDevice, font: NSFont, cell: CGSize) {
        self.cell = cell
        extraCount = 0
        map.removeAll()
        nextSlot = 1
        let scale = max(NSScreen.main?.backingScaleFactor ?? 2, 1)
        glyphW = max(Int(ceil(cell.width * scale)), 1)
        glyphH = max(Int(ceil(cell.height * scale)), 1)
        let count = preload.count + extraCap + 1
        cols = Int(ceil(sqrt(Double(count))))
        let rows = Int(ceil(Double(count) / Double(cols)))
        texWidth = max(cols * glyphW, 1)
        texHeight = max(rows * glyphH, 1)
        pixels = Array(repeating: 0, count: texWidth * texHeight * 4)
        writeWhitePixel(x: 0, y: 0)
        map[0] = AtlasGlyph(
            uvOrigin: SIMD2(0, 0),
            uvSize: SIMD2(1 / Float(texWidth), 1 / Float(texHeight))
        )
        let ctFont = font as CTFont
        for scalar in preload {
            _ = stamp(font: ctFont, scalar: scalar)
        }
        upload(device: device)
    }

    var whitePixel: AtlasGlyph {
        map[0] ?? AtlasGlyph(uvOrigin: SIMD2(0, 0), uvSize: SIMD2(1 / Float(max(texWidth, 1)), 1 / Float(max(texHeight, 1))))
    }

    func glyph(for scalar: UInt32, font: NSFont, device: MTLDevice) -> AtlasGlyph? {
        if let hit = map[scalar] { return hit }
        if extraCount >= extraCap { return nil }
        extraCount += 1
        let g = stamp(font: font as CTFont, scalar: scalar)
        upload(device: device)
        return g
    }

    private func upload(device: MTLDevice) {
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
            width: glyphW,
            height: glyphH,
            bitsPerComponent: 8,
            bytesPerRow: glyphW * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: glyphW, height: glyphH))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        var utf16 = Array(String(UnicodeScalar(scalar)!).utf16)
        var glyph: CGGlyph = 0
        _ = utf16.withUnsafeMutableBufferPointer { buf in
            CTFontGetGlyphsForCharacters(font, buf.baseAddress!, &glyph, 1)
        }
        var point = CGPoint(x: 0, y: CGFloat(glyphH) * 0.18)
        CTFontDrawGlyphs(font, &glyph, &point, 1, ctx)
        if let data = ctx.data {
            let src = data.bindMemory(to: UInt8.self, capacity: glyphW * glyphH * 4)
            let destX = col * glyphW
            let destY = row * glyphH
            for gy in 0..<glyphH {
                for gx in 0..<glyphW {
                    let si = (gy * glyphW + gx) * 4
                    let di = ((destY + gy) * texWidth + destX + gx) * 4
                    pixels[di] = src[si]
                    pixels[di + 1] = src[si + 1]
                    pixels[di + 2] = src[si + 2]
                    pixels[di + 3] = src[si + 3]
                }
            }
        }
        let g = AtlasGlyph(
            uvOrigin: SIMD2(Float(col * glyphW) / Float(texWidth), Float(row * glyphH) / Float(texHeight)),
            uvSize: SIMD2(Float(glyphW) / Float(texWidth), Float(glyphH) / Float(texHeight))
        )
        map[scalar] = g
        return g
    }
}
