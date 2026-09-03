import ScreenSaver
import QuartzCore

private let logger = AppexLog.logger("View")

final class OmacySaverView: ScreenSaverView {
    private let renderer = OmacyRenderer()
    private let canary = OmacyCanaryAnimator()
    private var usingCanary = true
    private var started = false
    private var observingScreen = false
    private var settledFallback: DispatchWorkItem?

    override init?(frame: NSRect, isPreview: Bool) {
        logger.info("init(frame: \(frame.size.width, privacy: .public)x\(frame.size.height, privacy: .public), isPreview: \(isPreview))")
        super.init(frame: frame, isPreview: isPreview)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        autoresizingMask = [.width, .height]
        animationTimeInterval = 1.0 / 60.0
        renderer.onEngineUnavailable = { [weak self] in
            self?.switchToCanary()
        }
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        autoresizingMask = [.width, .height]
        renderer.onEngineUnavailable = { [weak self] in
            self?.switchToCanary()
        }
    }

    deinit {
        settledFallback?.cancel()
        logger.info("deinit")
    }

    override func startAnimation() {
        logger.info("startAnimation() isPreview=\(self.isPreview) bounds=\(self.bounds.size.width, privacy: .public)x\(self.bounds.size.height, privacy: .public)")
        super.startAnimation()
        if looksLikePreview {
            start()
        } else {
            attemptSettledStart()
        }
    }

    override func animateOneFrame() {
        if looksLikePreview {
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if looksLikePreview {
            drawPreviewArt()
            return
        }
        super.draw(dirtyRect)
    }

    override func stopAnimation() {
        logger.info("stopAnimation()")
        teardown()
        super.stopAnimation()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        logger.info("viewDidMoveToWindow() hasWindow=\(self.window != nil)")
        settledFallback?.cancel()
        settledFallback = nil
        unobserveScreen()
        if let window {
            autoresizingMask = [.width, .height]
            if let superview {
                frame = superview.bounds
            }
            observeScreen(window)
            if !started {
                if looksLikePreview {
                    start()
                } else {
                    scheduleSettledFallback()
                    attemptSettledStart()
                }
            }
        } else {
            teardown()
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if started {
            refreshGeometry()
            retargetDisplayLink()
        } else {
            attemptSettledStart()
        }
    }

    override func layout() {
        super.layout()
        if started {
            refreshGeometry()
        } else {
            attemptSettledStart()
        }
    }

    @objc private func windowDidChangeScreen(_ notification: Notification) {
        let name = window?.screen?.localizedName ?? "nil"
        logger.info("windowDidChangeScreen screen=\(name, privacy: .public) bounds=\(self.bounds.size.width, privacy: .public)x\(self.bounds.size.height, privacy: .public)")
        if started {
            refreshGeometry()
            retargetDisplayLink()
        } else {
            attemptSettledStart()
        }
    }

    private func attemptSettledStart() {
        guard window != nil, !started else { return }
        guard geometryLooksSettled() else { return }
        start()
    }

    /// Tahoe's Settings preview often has `isPreview == false` on a small
    /// hosted view. Full-screen idle is the only path that should wait to match
    /// the display.
    private var looksLikePreview: Bool {
        if isPreview { return true }
        if bounds.width > 0, bounds.width < 500 { return true }
        if let screen = window?.screen {
            return bounds.width < screen.frame.width * 0.5
                || bounds.height < screen.frame.height * 0.5
        }
        return false
    }

    /// ScreenSaverEngine parks every saver window on the main display, then
    /// migrates it (~30–200 ms) and resizes. Starting before that settle
    /// sizes every session to `NSScreen.main`.
    private func geometryLooksSettled() -> Bool {
        if looksLikePreview { return bounds.width >= 1 && bounds.height >= 1 }
        guard let screen = window?.screen else { return false }
        return abs(bounds.width - screen.frame.width) < 8
            && abs(bounds.height - screen.frame.height) < 8
    }

    private func scheduleSettledFallback() {
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.window != nil, !self.started else { return }
            logger.info("settled-setup fallback bounds=\(self.bounds.size.width, privacy: .public)x\(self.bounds.size.height, privacy: .public)")
            self.start()
        }
        settledFallback = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    private func start() {
        renderer.stop()
        canary.stop()
        started = true
        settledFallback?.cancel()
        settledFallback = nil
        let scale = OmacyLayout.backingScale(for: self)
        logger.info("start() isPreview=\(self.isPreview) looksLikePreview=\(self.looksLikePreview) bounds=\(self.bounds.size.width, privacy: .public)x\(self.bounds.size.height, privacy: .public) scale=\(scale, privacy: .public)")
        // Settings snapshots the view. Metal sublayers and replacing
        // `self.layer` both present black there. Preview uses `draw(_:)`.
        if looksLikePreview {
            usingCanary = true
            needsDisplay = true
            return
        }
        renderer.displayCoordinator = OmacyDisplayCoordinator.shared
        switch renderer.attach(to: self, isPreview: false) {
        case .engine:
            usingCanary = false
            renderer.start()
        case .canary:
            switchToCanary()
        }
    }

    private func drawPreviewArt() {
        let configuration = OmacyStore.loadConfiguration()
        let settings = configuration.settings
        let rgba = settings.backgroundRGBA
        NSColor(
            srgbRed: CGFloat(rgba.0) / 255,
            green: CGFloat(rgba.1) / 255,
            blue: CGFloat(rgba.2) / 255,
            alpha: CGFloat(rgba.3) / 255
        ).setFill()
        bounds.fill()

        let art = configuration.art
        let fontSize = OmacyLayout.fittingFontSize(art: art, in: bounds.size, cap: 18)
        let font = OmacyFont.makeFont(size: fontSize)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let textSize = art.size(withAttributes: attrs)
        let origin = CGPoint(
            x: max((bounds.width - textSize.width) / 2, 8),
            y: max((bounds.height - textSize.height) / 2, 8)
        )
        art.draw(in: CGRect(origin: origin, size: textSize), withAttributes: attrs)
    }

    private func refreshGeometry() {
        if looksLikePreview {
            needsDisplay = true
            return
        }
        let scale = OmacyLayout.backingScale(for: self)
        if usingCanary {
            canary.updateBounds(bounds, scale: scale)
        } else if started {
            renderer.updateGeometry()
        }
    }

    private func retargetDisplayLink() {
        guard started, !usingCanary else { return }
        renderer.retargetDisplayLink()
    }

    private func switchToCanary() {
        usingCanary = true
        if let layer {
            let scale = OmacyLayout.backingScale(for: self)
            canary.attach(to: layer, scale: scale)
            canary.updateBounds(bounds, scale: scale)
        }
        canary.start()
    }

    private func teardown() {
        started = false
        settledFallback?.cancel()
        settledFallback = nil
        unobserveScreen()
        renderer.stop()
        renderer.displayCoordinator = nil
        canary.stop()
    }

    private func observeScreen(_ window: NSWindow) {
        unobserveScreen()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidChangeScreen(_:)),
            name: NSWindow.didChangeScreenNotification,
            object: window
        )
        observingScreen = true
    }

    private func unobserveScreen() {
        guard observingScreen else { return }
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didChangeScreenNotification,
            object: nil
        )
        observingScreen = false
    }
}
