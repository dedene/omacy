import AppKit
import Metal
import QuartzCore

/// Owns the Metal layer, glyph atlas, frame resources, packing, and drawing.
@MainActor
final class OmacyMetalGridRenderer {
    private var device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var metalLayer: CAMetalLayer?
    private let atlas = OmacyAtlas()
    private let frameResourceLifecycle = OmacyFrameResourceLifecycle()
    private var lastInstanceSlot: Int?
    private var lastInstanceCount = 0
    private var lastLayoutOrigin = CGPoint.zero
    private var lastLayoutCell = CGSize.zero
    private var lastViewport = CGSize.zero
    private var lastAtlasGeneration: UInt64 = 0
    private(set) var needsRepack = true
    private(set) var hasPresented = false

    func install(on view: NSView, font: NSFont, cell: CGSize) -> Bool {
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        self.device = device
        replaceFrameResources()
        queue = device.makeCommandQueue()
        let scale = OmacyLayout.backingScale(for: view)
        let backing = view.convertToBacking(view.bounds.size)
        let container = CALayer()
        container.backgroundColor = NSColor.black.cgColor
        container.isOpaque = true
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contentsScale = scale
        layer.drawableSize = OmacyLayout.drawableSize(viewSize: view.bounds.size, backing: backing, scale: scale)
        layer.frame = CGRect(origin: .zero, size: view.bounds.size)
        CATransaction.commit()
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer = container
        container.addSublayer(layer)
        metalLayer = layer
        pipeline = makePipeline(device: device)
        atlas.rebuild(device: device, font: font, cell: cell, scale: scale)
        lastAtlasGeneration = atlas.generation
        needsRepack = true
        guard pipeline != nil else {
            retireFrameResources()
            return false
        }
        return true
    }

    func installPlainLayer(on view: NSView) {
        retireFrameResources()
        let layer = CALayer()
        layer.backgroundColor = NSColor.black.cgColor
        layer.isOpaque = true
        view.layer = layer
        metalLayer = nil
    }

    func stop() {
        metalLayer = nil
        pipeline = nil
        queue = nil
        device = nil
        retireFrameResources()
        needsRepack = true
        hasPresented = false
    }

    func resetPresentation() {
        retireFrameResources()
        hasPresented = false
    }

    func markNeedsRepack() {
        needsRepack = true
    }

    func updateGeometry(view: NSView, font: NSFont, cell: CGSize, viewport: CGSize) {
        guard let metalLayer else { return }
        let scale = OmacyLayout.backingScale(for: view)
        let backing = view.convertToBacking(view.bounds.size)
        syncLayer(view: view, layer: metalLayer, backing: backing, scale: scale)
        if let device, atlas.needsRebuild(font: font, cell: cell, scale: scale) {
            atlas.rebuild(device: device, font: font, cell: cell, scale: scale)
            lastAtlasGeneration = atlas.generation
            needsRepack = true
        }
        if cell != lastLayoutCell || viewport != lastViewport {
            lastLayoutCell = cell
            lastViewport = viewport
            needsRepack = true
        }
    }

    func present(frame: OmacyFrame, cells: UnsafePointer<OmacyCell>?, view: NSView, font: NSFont) {
        guard let metalLayer, let queue, let pipeline else { return }
        let backing = view.convertToBacking(view.bounds.size)
        let scale = OmacyLayout.backingScale(for: view)
        let viewport = OmacyLayout.viewportSize(viewSize: view.bounds.size, backing: backing, scale: scale)
        let cell = OmacyLayout.cellSize(font: font)
        let origin = OmacyLayout.publishedOrigin(
            cols: frame.cols, rows: frame.rows, cell: cell, points: viewport, scale: scale
        )
        syncLayer(view: view, layer: metalLayer, backing: backing, scale: scale)
        if origin != lastLayoutOrigin || cell != lastLayoutCell || viewport != lastViewport {
            lastLayoutOrigin = origin
            lastLayoutCell = cell
            lastViewport = viewport
            needsRepack = true
        }
        if atlas.generation != lastAtlasGeneration {
            lastAtlasGeneration = atlas.generation
            needsRepack = true
        }

        var packCells = cells
        if packCells == nil, needsRepack { packCells = frame.cells }
        var drawBuffer: MTLBuffer?
        var drawCount = lastInstanceCount
        var frameLease: OmacyFrameLease?
        if let packCells, let device, let frameResources = frameResourceLifecycle.current {
            guard let lease = frameResources.acquireWritable() else { return }
            frameLease = lease
            let cellCount = Int(frame.cols) * Int(frame.rows)
            let needed = OmacyQuads.maxCount(cellCount: cellCount) * MemoryLayout<QuadInstance>.stride
            guard let buffer = frameResources.buffer(for: lease, device: device, minimumLength: needed) else {
                lease.complete()
                return
            }
            let packed = OmacyQuads.pack(
                cells: packCells,
                cols: Int(frame.cols), rows: Int(frame.rows), origin: origin, cell: cell,
                white: atlas.whitePixel,
                glyph: { [weak self] scalar in
                    guard let self else { return nil }
                    if let hit = atlas.lookup(scalar) { return hit }
                    return atlas.glyph(for: scalar, font: font, device: device)
                },
                into: buffer.contents().assumingMemoryBound(to: QuadInstance.self),
                capacity: OmacyQuads.maxCount(cellCount: cellCount)
            )
            lastInstanceSlot = packed > 0 ? lease.slot : nil
            lastInstanceCount = packed
            lastLayoutOrigin = origin
            lastLayoutCell = cell
            lastViewport = viewport
            lastAtlasGeneration = atlas.generation
            drawBuffer = buffer
            drawCount = packed
            needsRepack = false
            if packed == 0 {
                lease.complete()
                frameLease = nil
            }
        } else if drawCount > 0,
                  let slot = lastInstanceSlot,
                  let resources = frameResourceLifecycle.current,
                  let lease = resources.acquireReader(for: slot) {
            frameLease = lease
            drawBuffer = resources.buffer(for: lease)
            if drawBuffer == nil {
                lease.complete()
                frameLease = nil
                drawCount = 0
            }
        } else {
            drawCount = 0
        }

        guard let drawable = metalLayer.nextDrawable(), let command = queue.makeCommandBuffer() else {
            frameLease?.complete()
            return
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(frame.clear_r) / 255, green: Double(frame.clear_g) / 255,
            blue: Double(frame.clear_b) / 255, alpha: Double(max(frame.clear_a, 255)) / 255
        )
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            frameLease?.complete()
            return
        }
        encoder.setRenderPipelineState(pipeline)
        if let drawBuffer, drawCount > 0 {
            encoder.setVertexBuffer(drawBuffer, offset: 0, index: 0)
            var size = SIMD2<Float>(Float(viewport.width), Float(viewport.height))
            encoder.setVertexBytes(&size, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
            encoder.setFragmentTexture(atlas.texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: drawCount)
        }
        if let frameLease { command.addCompletedHandler { _ in frameLease.complete() } }
        encoder.endEncoding()
        command.present(drawable)
        command.commit()
        hasPresented = true
    }

    private func syncLayer(view: NSView, layer: CAMetalLayer, backing: CGSize, scale: CGFloat) {
        let size = OmacyLayout.drawableSize(viewSize: view.bounds.size, backing: backing, scale: scale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if layer.contentsScale != scale { layer.contentsScale = scale }
        if OmacyLayout.drawableSizeChanged(current: layer.drawableSize, proposed: size) {
            layer.drawableSize = size
        }
        layer.frame = CGRect(origin: .zero, size: view.bounds.size)
        CATransaction.commit()
    }

    private func replaceFrameResources() {
        lastInstanceSlot = nil
        lastInstanceCount = 0
        frameResourceLifecycle.replace()
    }

    private func retireFrameResources() {
        frameResourceLifecycle.stop()
        lastInstanceSlot = nil
        lastInstanceCount = 0
    }

    private func makePipeline(device: MTLDevice) -> MTLRenderPipelineState? {
        guard let library = device.makeDefaultLibrary() else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "omacy_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "omacy_fragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }
}
