import AppKit
import QuartzCore

/// Owns the display-link lifecycle so the renderer only coordinates frames.
@MainActor
final class OmacyDisplayLinkDriver: NSObject {
    private var link: CADisplayLink?
    private var tick: ((CADisplayLink) -> Void)?
    private var stopHandler: (() -> Void)?

    var isRunning: Bool { link != nil }
    private(set) var generation: UInt64 = 0
    private(set) var limitsFrameRate = false

    func start(
        for view: NSView,
        limitsFrameRate: Bool,
        tick: @escaping (CADisplayLink) -> Void,
        stop: @escaping () -> Void
    ) {
        self.tick = tick
        stopHandler = stop
        link?.invalidate()
        self.limitsFrameRate = limitsFrameRate
        generation &+= 1
        let next = view.displayLink(target: self, selector: #selector(didTick(_:)))
        if limitsFrameRate {
            next.add(to: .main, forMode: .default)
            next.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 30, preferred: 30)
        } else {
            next.add(to: .main, forMode: .common)
        }
        link = next
        NotificationCenter.default.removeObserver(self, name: Self.willStopName, object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(willStop),
            name: Self.willStopName,
            object: nil
        )
    }

    /// Recreate the link for a view which moved to a screen with another refresh rate.
    func retarget(for view: NSView, limitsFrameRate: Bool) {
        guard link != nil, let tick, let stopHandler else { return }
        start(for: view, limitsFrameRate: limitsFrameRate, tick: tick, stop: stopHandler)
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        link?.invalidate()
        link = nil
        tick = nil
        stopHandler = nil
        limitsFrameRate = false
    }

    @objc private func didTick(_ link: CADisplayLink) {
        tick?(link)
    }

    @objc private func willStop() {
        stopHandler?()
    }

    private static let willStopName = Notification.Name("com.apple.screensaver.willstop")
}
