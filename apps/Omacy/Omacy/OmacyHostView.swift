import AppKit

final class OmacyHostView: NSView {
    private let renderer = OmacyRenderer()
    private let canary = OmacyCanaryAnimator()
    private var usingCanary = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            start()
        } else {
            stop()
        }
    }

    override func layout() {
        super.layout()
        if usingCanary {
            canary.updateBounds(bounds)
        } else {
            renderer.updateGeometry()
        }
    }

    func applyPendingConfig() {
        renderer.applyPendingConfig()
    }

    private func start() {
        renderer.attach(to: self, isPreview: false)
        if renderer.usesEngine && !OmacyStore.forceCanary {
            usingCanary = false
            renderer.start()
        } else {
            usingCanary = true
            if let layer {
                canary.attach(to: layer)
                canary.updateBounds(bounds)
            }
            canary.start()
        }
    }

    private func stop() {
        renderer.stop()
        canary.stop()
    }

    deinit {
        renderer.stop()
        canary.stop()
    }
}
