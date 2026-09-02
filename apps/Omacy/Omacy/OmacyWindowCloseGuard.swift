import AppKit
import SwiftUI

enum OmacyWindowSizing {
    static let minimum = NSSize(width: ArtMetrics.minWindowWidth, height: ArtMetrics.minWindowHeight)

    static func grownFrame(_ frame: NSRect) -> NSRect {
        let width = max(frame.width, minimum.width)
        let height = max(frame.height, minimum.height)
        return NSRect(x: frame.minX, y: frame.maxY - height, width: width, height: height)
    }

    @MainActor
    static func enforce(on window: NSWindow) {
        window.minSize = minimum
        let grown = grownFrame(window.frame)
        if grown != window.frame { window.setFrame(grown, display: true) }
    }

    @MainActor
    static func workspaceWindow(in application: NSApplication) -> NSWindow? {
        if let key = application.keyWindow, isWorkspaceWindow(key) { return key }
        if let identified = application.windows.first(where: {
            isWorkspaceCandidate($0) && isWorkspaceIdentity(title: $0.title, identifier: $0.identifier?.rawValue)
                && $0.identifier?.rawValue.contains("main") == true
        }) { return identified }
        return application.windows.first(where: {
            isWorkspaceCandidate($0) && $0.title == "Omacy"
        })
    }

    static func isWorkspaceIdentity(title: String, identifier: String?) -> Bool {
        identifier?.contains("main") == true || title == "Omacy"
    }

    @MainActor
    private static func isWorkspaceWindow(_ window: NSWindow) -> Bool {
        isWorkspaceCandidate(window)
            && isWorkspaceIdentity(title: window.title, identifier: window.identifier?.rawValue)
    }

    @MainActor
    private static func isWorkspaceCandidate(_ window: NSWindow) -> Bool {
        window.isVisible
            && window.screen != nil
            && !window.title.isEmpty
            && window.styleMask.contains(.titled)
            && window.level == .normal
    }
}

struct OmacyWindowCloseGuard: NSViewRepresentable {
    let isDirty: Bool
    let save: @MainActor () async -> Bool
    let discard: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WindowObserverView {
        let view = WindowObserverView(frame: .zero)
        view.windowChanged = { [weak coordinator = context.coordinator] window in
            guard let window else { coordinator?.uninstall(); return }
            coordinator?.installIfNeeded(on: window)
        }
        return view
    }

    func updateNSView(_ view: WindowObserverView, context: Context) {
        context.coordinator.isDirty = isDirty
        context.coordinator.save = save
        context.coordinator.discard = discard
        if let window = view.window {
            context.coordinator.installIfNeeded(on: window)
            window.isDocumentEdited = isDirty
        }
    }

    static func dismantleNSView(_ view: WindowObserverView, coordinator: Coordinator) {
        view.windowChanged = nil
        coordinator.uninstall()
        coordinator.unregisterTerminationGuard()
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        weak var window: NSWindow?
        weak var originalDelegate: NSWindowDelegate?
        var isDirty = false
        var save: (@MainActor () async -> Bool)?
        var discard: (@MainActor () -> Void)?
        var presentAlert: @MainActor () -> OmacyUnsavedChangesChoice = {
            OmacyUnsavedChangesAlert.present(.closing)
        }
        let terminationGuard: OmacyTerminationGuard
        private var approvedClose = false

        init(terminationGuard: OmacyTerminationGuard = .shared) {
            self.terminationGuard = terminationGuard
            super.init()
            registerTerminationGuard()
        }

        func installIfNeeded(on window: NSWindow) {
            OmacyWindowSizing.enforce(on: window)
            guard self.window !== window || window.delegate !== self else { return }
            uninstall()
            self.window = window
            // A displaced coordinator must never adopt itself as the delegate to forward to.
            originalDelegate = window.delegate === self ? nil : window.delegate
            window.delegate = self
        }

        /// Registration is tied to the coordinator's lifetime, not the window's: a transient
        /// detach must not open a window where Cmd-Q quits without asking.
        func registerTerminationGuard() {
            terminationGuard.register(
                owner: self,
                isDirty: { [weak self] in self?.isDirty ?? false },
                save: { [weak self] in await self?.save?() ?? false },
                discard: { [weak self] in self?.discard?() }
            )
        }

        func unregisterTerminationGuard() {
            terminationGuard.unregister(owner: self)
        }

        func uninstall() {
            if window?.delegate === self { window?.delegate = originalDelegate }
            window = nil
            originalDelegate = nil
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if approvedClose || !isDirty { return originalDelegate?.windowShouldClose?(sender) ?? true }
            switch presentAlert() {
            case .save:
                Task { @MainActor [weak self, weak sender] in
                    guard let self, let sender, await save?() == true else { return }
                    approvedClose = true
                    sender.performClose(nil)
                    approvedClose = false
                }
            case .discard:
                discard?()
                approvedClose = true
                DispatchQueue.main.async { [weak self, weak sender] in
                    sender?.performClose(nil)
                    self?.approvedClose = false
                }
            case .cancel:
                break
            }
            return false
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || originalDelegate?.responds(to: selector) == true
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            originalDelegate?.responds(to: selector) == true ? originalDelegate : super.forwardingTarget(for: selector)
        }
    }
}

final class WindowObserverView: NSView {
    var windowChanged: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowChanged?(window)
    }
}
