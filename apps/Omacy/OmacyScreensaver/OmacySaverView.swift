import ScreenSaver
import QuartzCore

private let logger = AppexLog.logger("View")

final class OmacySaverView: ScreenSaverView {
    private let renderer = OmacyRenderer()
    private let canary = OmacyCanaryAnimator()
    private var usingCanary = true

    override init?(frame: NSRect, isPreview: Bool) {
        logger.info("init(frame: \(frame.size.width, privacy: .public)x\(frame.size.height, privacy: .public), isPreview: \(isPreview))")
        super.init(frame: frame, isPreview: isPreview)
        wantsLayer = true
        animationTimeInterval = 1.0 / 60.0
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

    deinit {
        teardown()
        logger.info("deinit")
    }

    override func startAnimation() {
        logger.info("startAnimation()")
        super.startAnimation()
        start()
    }

    override func stopAnimation() {
        logger.info("stopAnimation()")
        teardown()
        super.stopAnimation()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        logger.info("viewDidMoveToWindow() hasWindow=\(self.window != nil)")
        if window != nil {
            start()
        } else {
            teardown()
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

    private func start() {
        teardown()
        let preview = isPreview || (bounds.width > 0 && bounds.width < 400)
        switch renderer.attach(to: self, isPreview: preview) {
        case .engine:
            usingCanary = false
            renderer.start()
        case .canary:
            switchToCanary()
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

    private func teardown() {
        renderer.stop()
        canary.stop()
    }
}
