import AppKit
import Metal
import QuartzCore

private let log = AppexLog.logger("Renderer")

enum OmacyAttachMode {
    case engine
    case canary
}

struct OmacyPinnedContent: Equatable {
    var art: String
    var effect: String
    var background: String
    var fontSize: Double
}

@MainActor
final class OmacyRenderer: NSObject {
    var onEngineUnavailable: (() -> Void)?
    /// Host preview: recreate the session when the view's cell count changes.
    /// Screensaver keeps mid-effect size until the effect ends.
    var appliesGeometryLive = false
    /// Art-window live canvas: loop this content and skip the App Group shuffle.
    var pinnedContent: OmacyPinnedContent?

    override init() {
        super.init()
    }

    private weak var view: NSView?
    private var session: OpaquePointer?
    private var displayLink: CADisplayLink?
    private var device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var metalLayer: CAMetalLayer?
    private let atlas = OmacyAtlas()
    private var instanceBuffers: [MTLBuffer?] = [nil, nil, nil]
    private var bufferIndex = 0
    private var inFlight = DispatchSemaphore(value: 3)
    private var lastTimestamp: CFTimeInterval?
    private var fontSize: CGFloat = OmacyLayout.defaultFontSize
    private var cachedFont: NSFont?
    private var cols: UInt32 = 1
    private var rows: UInt32 = 1
    private var pendingCols: UInt32?
    private var pendingRows: UInt32?
    private var debounce: TimeInterval = 0
    private var isPreview = false
    private var stopped = true
    private var lastSettings = OmacySettings()
    private var lastArt = ""
    private var lastInstanceBuffer: MTLBuffer?
    private var lastInstanceCount = 0
    private var lastLayoutOrigin = CGPoint.zero
    private var lastLayoutCell = CGSize.zero
    private var lastViewport = CGSize.zero
    private var lastAtlasGeneration: UInt64 = 0
    private var forceRepack = true
    private var hasPresented = false

    var usesEngine: Bool { session != nil }

    @discardableResult
    func attach(to view: NSView, isPreview: Bool) -> OmacyAttachMode {
        stopSessionAndLink()
        hasPresented = false
        self.view = view
        self.isPreview = isPreview
        view.wantsLayer = true
        loadContent()
        fontSize = resolvedFontSize()
        cachedFont = OmacyFont.makeFont(size: fontSize)
        let font = cachedFont!
        let layout = OmacyLayout.grid(view: view, font: font)
        cols = layout.cols
        rows = layout.rows

        if OmacyStore.forceCanary || !createSession(cols: cols, rows: rows, settings: lastSettings, art: lastArt) {
            installPlainLayer(on: view)
            return .canary
        }
        guard installMetal(on: view, font: font, cell: layout.cell) else {
            destroySession()
            installPlainLayer(on: view)
            return .canary
        }
        return .engine
    }

    func start() {
        guard let view, session != nil else { return }
        stopped = false
        displayLink?.invalidate()
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        if isPreview || pinnedContent != nil {
            link.add(to: .main, forMode: .default)
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 30, preferred: 30)
        } else {
            link.add(to: .main, forMode: .common)
        }
        displayLink = link
        let willStopName = Notification.Name("com.apple.screensaver.willstop")
        NotificationCenter.default.removeObserver(self, name: willStopName, object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(willStop),
            name: willStopName,
            object: nil
        )
    }

    /// Recreate the display link for a new screen's refresh rate. No-op until
    /// `start()` has run once, so the saver's deferred first start stays deferred.
    func retargetDisplayLink() {
        guard displayLink != nil else { return }
        start()
    }

    func stop() {
        stopped = true
        NotificationCenter.default.removeObserver(self)
        stopSessionAndLink()
        metalLayer = nil
        pipeline = nil
        queue = nil
        device = nil
        instanceBuffers = [nil, nil, nil]
        lastInstanceBuffer = nil
        lastInstanceCount = 0
        for _ in 0..<3 { inFlight.signal() }
        inFlight = DispatchSemaphore(value: 3)
        forceRepack = true
        hasPresented = false
        cachedFont = nil
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
        guard let view, view.bounds.width > 1, view.bounds.height > 1 else { return }
        let fitted = resolvedFontSize()
        if abs(fitted - fontSize) > 0.5 {
            fontSize = fitted
            cachedFont = OmacyFont.makeFont(size: fontSize)
        }
        let font = cachedFont ?? OmacyFont.makeFont(size: fontSize)
        cachedFont = font
        let layout = OmacyLayout.grid(view: view, font: font)
        let scale = OmacyLayout.backingScale(for: view)
        let backing = view.convertToBacking(view.bounds.size)
        let size = OmacyLayout.drawableSize(viewSize: view.bounds.size, backing: backing, scale: scale)
        let viewport = OmacyLayout.viewportSize(viewSize: view.bounds.size, backing: backing, scale: scale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if metalLayer?.contentsScale != scale {
            metalLayer?.contentsScale = scale
        }
        if let metalLayer, OmacyLayout.drawableSizeChanged(current: metalLayer.drawableSize, proposed: size) {
            metalLayer.drawableSize = size
        }
        metalLayer?.frame = CGRect(origin: .zero, size: view.bounds.size)
        CATransaction.commit()
        if layout.cols != cols || layout.rows != rows {
            pendingCols = layout.cols
            pendingRows = layout.rows
            debounce = CACurrentMediaTime()
            forceRepack = true
            applyUnpresentedGeometry()
        }
        if let device, atlas.needsRebuild(font: font, cell: layout.cell, scale: scale) {
            atlas.rebuild(device: device, font: font, cell: layout.cell, scale: scale)
            lastAtlasGeneration = atlas.generation
            forceRepack = true
        }
        if layout.origin != lastLayoutOrigin
            || layout.cell != lastLayoutCell
            || viewport != lastViewport {
            lastLayoutOrigin = layout.origin
            lastLayoutCell = layout.cell
            lastViewport = viewport
            forceRepack = true
        }
    }

    func pin(_ content: OmacyPinnedContent) {
        if pinnedContent == content { return }
        let effectChanged = pinnedContent?.effect != content.effect
        let artChanged = pinnedContent?.art != content.art
        let bgChanged = pinnedContent?.background != content.background
        pinnedContent = content
        lastArt = content.art
        lastSettings.effect = content.effect
        lastSettings.background = content.background
        lastSettings.fontSize = content.fontSize
        let fitted = resolvedFontSize()
        if abs(fitted - fontSize) > 0.5 {
            fontSize = fitted
            cachedFont = OmacyFont.makeFont(size: fontSize)
            forceRepack = true
            updateGeometry()
        }
        guard session != nil, effectChanged || artChanged || bgChanged else { return }
        let nextCols = pendingCols ?? cols
        let nextRows = pendingRows ?? rows
        if createSession(cols: nextCols, rows: nextRows, settings: lastSettings, art: lastArt) {
            cols = nextCols
            rows = nextRows
            forceRepack = true
        }
    }

    func applyPendingConfig() {
        loadContent()
        fontSize = resolvedFontSize()
        cachedFont = OmacyFont.makeFont(size: fontSize)
        forceRepack = true
        let nextCols = pendingCols ?? cols
        let nextRows = pendingRows ?? rows
        if createSession(cols: nextCols, rows: nextRows, settings: lastSettings, art: lastArt) {
            cols = nextCols
            rows = nextRows
        }
        updateGeometry()
    }

    @objc private func willStop() {
        stop()
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard !stopped else { return }
        guard let session else { return }
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
        if status == OMACY_ERR_DEAD || status == OMACY_ERR_PANIC {
            recoverDeadSession()
            return
        }
        guard status == OMACY_OK, let cells = result.frame.cells else { return }

        if atlas.generation != lastAtlasGeneration {
            lastAtlasGeneration = atlas.generation
            forceRepack = true
        }
        let mustPack = forceRepack || result.steps_taken != 0
        present(frame: result.frame, cells: mustPack ? cells : nil)
        applyWaitingWork(result)
        applyLiveGeometryIfNeeded()
    }

    /// ScreenSaverEngine sizes every saver window to the main display first,
    /// then migrates it. If that resize lands before the first present, apply
    /// it now so the first effect is not locked to `NSScreen.main`.
    private func applyUnpresentedGeometry() {
        guard !hasPresented else { return }
        guard let pc = pendingCols, let pr = pendingRows else { return }
        pendingCols = nil
        pendingRows = nil
        debounce = 0
        guard pc != cols || pr != rows else { return }
        if createSession(cols: pc, rows: pr, settings: lastSettings, art: lastArt) {
            cols = pc
            rows = pr
            forceRepack = true
        }
    }

    private func applyLiveGeometryIfNeeded() {
        guard appliesGeometryLive else { return }
        guard CACurrentMediaTime() - debounce >= 0.05,
              let pc = pendingCols, let pr = pendingRows else { return }
        pendingCols = nil
        pendingRows = nil
        guard pc != cols || pr != rows else { return }
        if createSession(cols: pc, rows: pr, settings: lastSettings, art: lastArt) {
            cols = pc
            rows = pr
            forceRepack = true
        }
    }

    private func applyWaitingWork(_ result: OmacyStepResult) {
        guard let session else { return }
        if result.needs_begin_next != 0 {
            if CGFloat(lastSettings.fontSize) != fontSize {
                fontSize = CGFloat(lastSettings.fontSize)
                cachedFont = OmacyFont.makeFont(size: fontSize)
                forceRepack = true
                updateGeometry()
            }
            if CACurrentMediaTime() - debounce >= 0.05, let pc = pendingCols, let pr = pendingRows {
                _ = omacy_session_resize(session, pc, pr)
                cols = pc
                rows = pr
                pendingCols = nil
                pendingRows = nil
                forceRepack = true
            }
            _ = omacy_session_begin_next(session)
        } else if !appliesGeometryLive, let pc = pendingCols, let pr = pendingRows,
                  CACurrentMediaTime() - debounce >= 0.05 {
            _ = omacy_session_resize(session, pc, pr)
        }
    }

    private func present(frame: OmacyFrame, cells: UnsafePointer<OmacyCell>?) {
        guard let view, let metalLayer, let queue, let pipeline else { return }
        let font = cachedFont ?? OmacyFont.makeFont(size: fontSize)
        cachedFont = font
        let backing = view.convertToBacking(view.bounds.size)
        let scale = OmacyLayout.backingScale(for: view)
        let vp = OmacyLayout.viewportSize(viewSize: view.bounds.size, backing: backing, scale: scale)
        let cell = OmacyLayout.cellSize(font: font)
        let origin = OmacyLayout.publishedOrigin(
            cols: frame.cols,
            rows: frame.rows,
            cell: cell,
            points: vp,
            scale: scale
        )
        syncMetalLayer(view: view, metalLayer: metalLayer, backing: backing, scale: scale, viewport: vp)
        if origin != lastLayoutOrigin || cell != lastLayoutCell || vp != lastViewport {
            lastLayoutOrigin = origin
            lastLayoutCell = cell
            lastViewport = vp
            forceRepack = true
        }

        var packCells = cells
        if packCells == nil, forceRepack {
            packCells = frame.cells
        }
        var drawBuffer = lastInstanceBuffer
        var drawCount = lastInstanceCount

        if let packCells, let device {
            inFlight.wait()
            let idx = bufferIndex
            let cellCount = Int(frame.cols) * Int(frame.rows)
            let needed = OmacyQuads.maxCount(cellCount: cellCount) * MemoryLayout<QuadInstance>.stride
            if instanceBuffers[idx] == nil || instanceBuffers[idx]!.length < needed {
                instanceBuffers[idx] = device.makeBuffer(length: max(needed, 4096), options: .storageModeShared)
            }
            guard let buffer = instanceBuffers[idx] else {
                inFlight.signal()
                return
            }
            let packed = OmacyQuads.pack(
                cells: packCells,
                cols: Int(frame.cols),
                rows: Int(frame.rows),
                origin: origin,
                cell: cell,
                white: atlas.whitePixel,
                glyph: { [weak self] scalar in
                    guard let self else { return nil }
                    if let hit = self.atlas.lookup(scalar) { return hit }
                    return self.atlas.glyph(for: scalar, font: font, device: device)
                },
                into: buffer.contents().assumingMemoryBound(to: QuadInstance.self),
                capacity: OmacyQuads.maxCount(cellCount: cellCount)
            )
            lastInstanceBuffer = buffer
            lastInstanceCount = packed
            lastLayoutOrigin = origin
            lastLayoutCell = cell
            lastViewport = vp
            lastAtlasGeneration = atlas.generation
            drawBuffer = buffer
            drawCount = packed
            bufferIndex = (idx + 1) % 3
            forceRepack = false
        }

        guard let drawable = metalLayer.nextDrawable(),
              let cmd = queue.makeCommandBuffer() else {
            if packCells != nil { inFlight.signal() }
            return
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(frame.clear_r) / 255,
            green: Double(frame.clear_g) / 255,
            blue: Double(frame.clear_b) / 255,
            alpha: Double(max(frame.clear_a, 255)) / 255
        )
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else {
            if packCells != nil { inFlight.signal() }
            return
        }
        enc.setRenderPipelineState(pipeline)
        if let drawBuffer, drawCount > 0 {
            enc.setVertexBuffer(drawBuffer, offset: 0, index: 0)
            var viewport = SIMD2<Float>(Float(vp.width), Float(vp.height))
            enc.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
            enc.setFragmentTexture(atlas.texture, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: drawCount)
        }
        if packCells != nil {
            cmd.addCompletedHandler { [weak self] _ in
                self?.inFlight.signal()
            }
        }
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
        hasPresented = true
    }

    @discardableResult
    private func createSession(cols: UInt32, rows: UInt32, settings: OmacySettings, art: String) -> Bool {
        destroySession()
        let bg = settings.backgroundRGBA
        var cfg = OmacySessionConfig()
        let artBytes = Array(art.utf8)
        let effectBytes = Array(settings.effect.utf8)
        let dir = pinnedContent == nil ? OmacyStore.containerURL?.path : nil
        let dirBytes = dir.map { Array($0.utf8) }
        var created = false
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
                        created = finishCreate(&cfg, cols: cols, rows: rows)
                    }
                } else {
                    created = finishCreate(&cfg, cols: cols, rows: rows)
                }
            }
        }
        return created
    }

    private func finishCreate(_ cfg: inout OmacySessionConfig, cols: UInt32, rows: UInt32) -> Bool {
        var out: OpaquePointer?
        let status = omacy_session_create(&cfg, cols, rows, &out)
        if status == OMACY_OK, let out {
            session = out
            return true
        }
        log.error("session create failed: \(String(describing: status), privacy: .public)")
        return false
    }

    private func recoverDeadSession() {
        let geometryCols = pendingCols ?? cols
        let geometryRows = pendingRows ?? rows
        if createSession(cols: geometryCols, rows: geometryRows, settings: lastSettings, art: lastArt) {
            cols = geometryCols
            rows = geometryRows
            pendingCols = nil
            pendingRows = nil
            forceRepack = true
            return
        }
        failToCanary()
    }

    private func failToCanary() {
        stopSessionAndLink()
        stopped = true
        metalLayer = nil
        if let view {
            installPlainLayer(on: view)
        }
        onEngineUnavailable?()
    }

    private func stopSessionAndLink() {
        destroySession()
        displayLink?.invalidate()
        displayLink = nil
        lastTimestamp = nil
    }

    private func resolvedFontSize() -> CGFloat {
        let cap = CGFloat(lastSettings.fontSize)
        guard let view else { return cap }
        if pinnedContent != nil || isPreview {
            return OmacyLayout.fittingFontSize(art: lastArt, in: view.bounds.size, cap: cap)
        }
        return cap
    }

    private func loadContent() {
        if let pinned = pinnedContent {
            lastArt = pinned.art
            lastSettings.effect = pinned.effect
            lastSettings.background = pinned.background
            lastSettings.fontSize = pinned.fontSize
        } else {
            lastSettings = OmacyStore.loadSettings()
            lastArt = OmacyStore.loadArt()
        }
    }

    private func destroySession() {
        if let session {
            omacy_session_destroy(session)
            self.session = nil
        }
    }

    private func syncMetalLayer(
        view: NSView,
        metalLayer: CAMetalLayer,
        backing: CGSize,
        scale: CGFloat,
        viewport: CGSize
    ) {
        let size = OmacyLayout.drawableSize(viewSize: view.bounds.size, backing: backing, scale: scale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if metalLayer.contentsScale != scale {
            metalLayer.contentsScale = scale
        }
        if OmacyLayout.drawableSizeChanged(current: metalLayer.drawableSize, proposed: size) {
            metalLayer.drawableSize = size
        }
        metalLayer.frame = CGRect(origin: .zero, size: view.bounds.size)
        CATransaction.commit()
        if viewport != lastViewport {
            lastViewport = viewport
            forceRepack = true
        }
    }

    private func installPlainLayer(on view: NSView) {
        let layer = CALayer()
        layer.backgroundColor = NSColor.black.cgColor
        layer.isOpaque = true
        view.layer = layer
        metalLayer = nil
    }

    private func installMetal(on view: NSView, font: NSFont, cell: CGSize) -> Bool {
        guard let device = MTLCreateSystemDefaultDevice() else {
            log.error("no Metal device")
            return false
        }
        self.device = device
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
        forceRepack = true
        return pipeline != nil
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
