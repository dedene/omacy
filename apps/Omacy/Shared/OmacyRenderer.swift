import AppKit
import Metal
import QuartzCore

private let log = AppexLog.logger("Renderer")

private struct QuadInstance {
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    var uvOrigin: SIMD2<Float>
    var uvSize: SIMD2<Float>
    var color: SIMD4<Float>
}

@MainActor
final class OmacyRenderer {
    private weak var view: NSView?
    private var session: OpaquePointer?
    private var displayLink: CADisplayLink?
    private var device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var metalLayer: CAMetalLayer?
    private let atlas = OmacyAtlas()
    private var instanceBuffer: MTLBuffer?
    private var lastTimestamp: CFTimeInterval?
    private var fontSize: CGFloat = OmacyLayout.defaultFontSize
    private var cols: UInt32 = 1
    private var rows: UInt32 = 1
    private var pendingCols: UInt32?
    private var pendingRows: UInt32?
    private var debounce: TimeInterval = 0
    private var isPreview = false
    private var stopped = true
    private var copiedCells: [OmacyCell] = []

    var usesEngine: Bool { session != nil }

    func attach(to view: NSView, isPreview: Bool) {
        self.view = view
        self.isPreview = isPreview
        view.wantsLayer = true
        let settings = OmacyStore.loadSettings()
        fontSize = CGFloat(settings.fontSize)
        guard let device = MTLCreateSystemDefaultDevice() else {
            log.error("no Metal device")
            return
        }
        self.device = device
        queue = device.makeCommandQueue()
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        view.layer = layer
        metalLayer = layer
        pipeline = makePipeline(device: device)
        let font = OmacyFont.makeFont(size: fontSize)
        let layout = OmacyLayout.grid(
            viewSize: view.bounds.size,
            scale: view.window?.backingScaleFactor ?? 2,
            font: font
        )
        cols = layout.cols
        rows = layout.rows
        atlas.rebuild(device: device, font: font, cell: layout.cell)
        createSession(cols: cols, rows: rows, settings: settings)
    }

    func start() {
        guard let view else { return }
        stopped = false
        displayLink?.invalidate()
        guard let link = view.displayLink(target: self, selector: #selector(tick(_:))) else { return }
        link.add(to: .main, forMode: .common)
        if isPreview {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 30, preferred: 30)
        }
        displayLink = link
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(willStop),
            name: Notification.Name("com.apple.screensaver.willstop"),
            object: nil
        )
    }

    func stop() {
        stopped = true
        NotificationCenter.default.removeObserver(self)
        if let session {
            omacy_session_destroy(session)
            self.session = nil
        }
        displayLink?.invalidate()
        displayLink = nil
        metalLayer = nil
        pipeline = nil
        queue = nil
        device = nil
    }

    deinit {
        if session != nil {
            assertionFailure("OmacyRenderer.deinit with live session")
            if Thread.isMainThread {
                omacy_session_destroy(session)
            }
        }
    }

    func updateGeometry() {
        guard let view, let device else { return }
        let font = OmacyFont.makeFont(size: fontSize)
        let layout = OmacyLayout.grid(
            viewSize: view.bounds.size,
            scale: view.window?.backingScaleFactor ?? view.layer?.contentsScale ?? 2,
            font: font
        )
        metalLayer?.drawableSize = CGSize(
            width: view.bounds.width * (view.window?.backingScaleFactor ?? 2),
            height: view.bounds.height * (view.window?.backingScaleFactor ?? 2)
        )
        if layout.cols != cols || layout.rows != rows {
            pendingCols = layout.cols
            pendingRows = layout.rows
            debounce = CACurrentMediaTime()
        }
        atlas.rebuild(device: device, font: font, cell: layout.cell)
    }

    func applyPendingConfig() {
        guard let session else { return }
        let settings = OmacyStore.loadSettings()
        fontSize = CGFloat(settings.fontSize)
        let art = OmacyStore.loadArt()
        var cfg = OmacyPendingConfig()
        art.withCString { ptr in
            let bytes = UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self)
            cfg.ascii = bytes
            cfg.ascii_len = art.utf8.count
            settings.effect.withCString { eptr in
                cfg.effect = UnsafeRawPointer(eptr).assumingMemoryBound(to: UInt8.self)
                cfg.effect_len = settings.effect.utf8.count
                let bg = settings.backgroundRGBA
                cfg.bg_r = bg.0
                cfg.bg_g = bg.1
                cfg.bg_b = bg.2
                cfg.bg_a = bg.3
                _ = omacy_session_set_pending_config(session, &cfg)
            }
        }
        updateGeometry()
    }

    @objc private func willStop() {
        stop()
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard !stopped, let session else { return }
        let now = link.timestamp
        let elapsed: Double
        if let lastTimestamp {
            elapsed = now - lastTimestamp
        } else {
            elapsed = 1.0 / 60.0
        }
        lastTimestamp = now

        var result = OmacyStepResult()
        let status = omacy_session_step(session, elapsed, &result)
        guard status == OMACY_OK, let cells = result.frame.cells else { return }

        let count = Int(result.frame.cols) * Int(result.frame.rows)
        copiedCells = Array(UnsafeBufferPointer(start: cells, count: count))
        present(frame: result.frame, cells: copiedCells)

        if result.needs_begin_next != 0 {
            if CACurrentMediaTime() - debounce >= 0.05, let pc = pendingCols, let pr = pendingRows {
                _ = omacy_session_resize(session, pc, pr)
                cols = pc
                rows = pr
                pendingCols = nil
                pendingRows = nil
            }
            _ = omacy_session_begin_next(session)
        } else if let pc = pendingCols, let pr = pendingRows, CACurrentMediaTime() - debounce >= 0.05 {
            _ = omacy_session_resize(session, pc, pr)
        }
    }

    private func present(frame: OmacyFrame, cells: [OmacyCell]) {
        guard let view, let metalLayer, let queue, let pipeline, let drawable = metalLayer.nextDrawable() else { return }
        let font = OmacyFont.makeFont(size: fontSize)
        let layout = OmacyLayout.grid(
            viewSize: view.bounds.size,
            scale: view.window?.backingScaleFactor ?? 2,
            font: font
        )
        var instances: [QuadInstance] = []
        instances.reserveCapacity(cells.count * 2)
        let cell = layout.cell
        let origin = layout.origin
        let cols = Int(frame.cols)
        let rows = Int(frame.rows)
        for r in 0..<rows {
            for c in 0..<cols {
                let cellData = cells[r * cols + c]
                let px = Float(origin.x + CGFloat(c) * cell.width)
                let py = Float(origin.y + CGFloat(r) * cell.height)
                let size = SIMD2<Float>(Float(cell.width), Float(cell.height))
                if cellData.occupancy & 1 != 0 {
                    instances.append(QuadInstance(
                        origin: SIMD2(px, py),
                        size: size,
                        uvOrigin: SIMD2(0, 0),
                        uvSize: SIMD2(1 / 1024, 1 / 1024),
                        color: SIMD4(
                            Float(cellData.bg_r) / 255,
                            Float(cellData.bg_g) / 255,
                            Float(cellData.bg_b) / 255,
                            Float(cellData.bg_a) / 255
                        )
                    ))
                }
                if cellData.occupancy & 2 != 0, cellData.glyph != 0,
                   let g = atlas.glyph(for: cellData.glyph, font: font, device: device!) {
                    instances.append(QuadInstance(
                        origin: SIMD2(px, py),
                        size: size,
                        uvOrigin: g.uvOrigin,
                        uvSize: g.uvSize,
                        color: SIMD4(
                            Float(cellData.fg_r) / 255,
                            Float(cellData.fg_g) / 255,
                            Float(cellData.fg_b) / 255,
                            Float(cellData.fg_a) / 255
                        )
                    ))
                }
            }
        }
        let clear = MTLClearColor(
            red: Double(frame.clear_r) / 255,
            green: Double(frame.clear_g) / 255,
            blue: Double(frame.clear_b) / 255,
            alpha: Double(max(frame.clear_a, 255)) / 255
        )
        guard let cmd = queue.makeCommandBuffer(),
              let pass = MTLRenderPassDescriptor() as MTLRenderPassDescriptor? else { return }
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = clear
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(pipeline)
        if !instances.isEmpty {
            let bytes = instances.count * MemoryLayout<QuadInstance>.stride
            if instanceBuffer == nil || instanceBuffer!.length < bytes {
                instanceBuffer = device?.makeBuffer(length: max(bytes, 4096), options: .storageModeShared)
            }
            instances.withUnsafeBytes { raw in
                instanceBuffer!.contents().copyMemory(from: raw.baseAddress!, byteCount: bytes)
            }
            enc.setVertexBuffer(instanceBuffer, offset: 0, index: 0)
            var viewport = SIMD2<Float>(Float(view.bounds.width), Float(view.bounds.height))
            enc.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
            enc.setFragmentTexture(atlas.texture, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: instances.count)
        }
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    private func createSession(cols: UInt32, rows: UInt32, settings: OmacySettings) {
        if OmacyStore.forceCanary { return }
        let art = OmacyStore.loadArt()
        let bg = settings.backgroundRGBA
        var cfg = OmacySessionConfig()
        let artBytes = Array(art.utf8)
        let effectBytes = Array(settings.effect.utf8)
        let dir = OmacyStore.containerURL?.path
        let dirBytes = dir.map { Array($0.utf8) }
        artBytes.withUnsafeBufferPointer { artPtr in
            effectBytes.withUnsafeBufferPointer { effectPtr in
                cfg.ascii = artPtr.baseAddress
                cfg.ascii_len = artBytes.count
                cfg.effect = effectPtr.baseAddress
                cfg.effect_len = effectBytes.count
                cfg.bg_r = bg.0
                cfg.bg_g = bg.1
                cfg.bg_b = bg.2
                cfg.bg_a = bg.3
                cfg.has_seed = 0
                if let dirBytes {
                    dirBytes.withUnsafeBufferPointer { dirPtr in
                        cfg.config_dir = dirPtr.baseAddress
                        cfg.config_dir_len = dirBytes.count
                        var out: OpaquePointer?
                        let status = omacy_session_create(&cfg, cols, rows, &out)
                        if status == OMACY_OK {
                            session = out
                        } else {
                            log.error("session create failed: \(Int(status), privacy: .public)")
                        }
                    }
                } else {
                    var out: OpaquePointer?
                    let status = omacy_session_create(&cfg, cols, rows, &out)
                    if status == OMACY_OK {
                        session = out
                    } else {
                        log.error("session create failed: \(Int(status), privacy: .public)")
                    }
                }
            }
        }
    }

    private func makePipeline(device: MTLDevice) -> MTLRenderPipelineState? {
        guard let library = device.makeDefaultLibrary() else { return nil }
        return build(device: device, library: library)
    }

    private func build(device: MTLDevice, library: MTLLibrary) -> MTLRenderPipelineState? {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "omacy_vertex")
        desc.fragmentFunction = library.makeFunction(name: "omacy_fragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        desc.colorAttachments[0].sourceAlphaBlendFactor = .one
        desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try? device.makeRenderPipelineState(descriptor: desc)
    }
}
