import AppKit

final class OmacyHostView: NSView {
    private let renderer = OmacyRenderer()
    private let canary = OmacyCanaryAnimator()
    private var usingCanary = false
    private var observingConfig = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        renderer.onEngineUnavailable = { [weak self] in
            self?.switchToCanary()
        }
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        renderer.onEngineUnavailable = { [weak self] in
            self?.switchToCanary()
        }
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
        stop()
        observeConfig()
        switch renderer.attach(to: self, isPreview: false) {
        case .engine:
            usingCanary = false
            renderer.start()
        case .canary:
            switchToCanary()
        }
    }

    private func stop() {
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
            canary.attach(to: layer)
            canary.updateBounds(bounds)
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
