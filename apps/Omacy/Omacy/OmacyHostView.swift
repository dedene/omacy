import AppKit

final class OmacyHostView: NSView {
    private let renderer = OmacyRenderer()
    private let canary = OmacyCanaryAnimator()
    private var usingCanary = false
    private var observingConfig = false
    private var started = false
    private var pinned: OmacyPinnedContent?
    private var lastLaidOutSize: CGSize = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        renderer.appliesGeometryLive = true
        renderer.onEngineUnavailable = { [weak self] in
            self?.switchToCanary()
        }
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        renderer.appliesGeometryLive = true
        renderer.onEngineUnavailable = { [weak self] in
            self?.switchToCanary()
        }
    }

    override var isOpaque: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didChangeScreenNotification,
            object: nil
        )
        if let window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidChangeScreen(_:)),
                name: NSWindow.didChangeScreenNotification,
                object: window
            )
            startIfReady()
        } else {
            stop()
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refreshGeometry()
        retargetDisplayLink()
    }

    @objc private func windowDidChangeScreen(_ notification: Notification) {
        refreshGeometry()
        retargetDisplayLink()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        startIfReady()
        refreshGeometry()
    }

    override func layout() {
        super.layout()
        startIfReady()
        if bounds.size != lastLaidOutSize {
            lastLaidOutSize = bounds.size
            refreshGeometry()
        }
    }

    func refreshGeometry() {
        let scale = OmacyLayout.backingScale(for: self)
        if usingCanary {
            canary.updateBounds(bounds, scale: scale)
        } else if started {
            renderer.updateGeometry()
        }
    }

    func pin(art: String, effect: String, background: String, fontSize: Double) {
        let content = OmacyPinnedContent(
            art: art,
            effect: effect,
            background: background,
            fontSize: fontSize
        )
        if pinned == content { return }
        pinned = content
        if started {
            renderer.pin(content)
        } else {
            renderer.pinnedContent = content
        }
    }

    private func startIfReady() {
        guard window != nil, bounds.width >= 32, bounds.height >= 32 else { return }
        if started {
            return
        }
        start()
    }

    func applyPendingConfig() {
        renderer.applyPendingConfig()
    }

    private func retargetDisplayLink() {
        guard started, !usingCanary else { return }
        renderer.retargetDisplayLink()
    }

    private func start() {
        stop()
        if pinned == nil {
            observeConfig()
        }
        started = true
        if let pinned {
            renderer.pinnedContent = pinned
        }
        switch renderer.attach(to: self, isPreview: pinned != nil) {
        case .engine:
            usingCanary = false
            renderer.start()
        case .canary:
            switchToCanary()
        }
    }

    private func stop() {
        started = false
        renderer.stop()
        canary.stop()
        if observingConfig {
            NotificationCenter.default.removeObserver(self, name: .omacyConfigDidChange, object: nil)
            observingConfig = false
        }
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

    private func observeConfig() {
        guard !observingConfig else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(configDidChange),
            name: .omacyConfigDidChange,
            object: nil
        )
        observingConfig = true
    }

    @objc private func configDidChange() {
        applyPendingConfig()
    }
}
