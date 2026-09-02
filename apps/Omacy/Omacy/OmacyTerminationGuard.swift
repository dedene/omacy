import AppKit

enum OmacyUnsavedChangesChoice: Equatable {
    case save
    case cancel
    case discard
}

enum OmacyUnsavedChangesPrompt {
    case closing
    case quitting

    var messageText: String {
        switch self {
        case .closing: return "Save changes before closing?"
        case .quitting: return "Save changes before quitting?"
        }
    }

    var informativeText: String {
        "Your art and screen saver settings have unsaved changes."
    }
}

enum OmacyUnsavedChangesAlert {
    @MainActor
    static func present(_ prompt: OmacyUnsavedChangesPrompt) -> OmacyUnsavedChangesChoice {
        let alert = NSAlert()
        alert.messageText = prompt.messageText
        alert.informativeText = prompt.informativeText
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let dontSave = alert.addButton(withTitle: "Don't Save")
        dontSave.hasDestructiveAction = true
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertThirdButtonReturn: return .discard
        default: return .cancel
        }
    }

    @MainActor
    static func presentSaveFailure() {
        let alert = NSAlert()
        alert.messageText = "Omacy couldn't save your changes."
        alert.informativeText = "It will stay open so you can fix the problem."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

/// Bridges the workspace's unsaved-draft state to `NSApplicationDelegate` termination,
/// which has no access to the SwiftUI scene's services.
@MainActor
final class OmacyTerminationGuard {
    enum Outcome: Equatable {
        case terminateNow
        case cancel
        case terminateLater

        var terminateReply: NSApplication.TerminateReply {
            switch self {
            case .terminateNow: return .terminateNow
            case .cancel: return .terminateCancel
            case .terminateLater: return .terminateLater
            }
        }
    }

    private struct Registration {
        weak var owner: AnyObject?
        var isDirty: @MainActor () -> Bool
        var save: @MainActor () async -> Bool
        var discard: @MainActor () -> Void
    }

    static let shared = OmacyTerminationGuard()

    /// Injectable so tests never present a real modal alert.
    var presentAlert: @MainActor () -> OmacyUnsavedChangesChoice = {
        OmacyUnsavedChangesAlert.present(.quitting)
    }
    var presentSaveFailureAlert: @MainActor () -> Void = OmacyUnsavedChangesAlert.presentSaveFailure

    private var registration: Registration?
    private var isDeciding = false
    private var isSavingForTermination = false

    func register(
        owner: AnyObject,
        isDirty: @escaping @MainActor () -> Bool,
        save: @escaping @MainActor () async -> Bool,
        discard: @escaping @MainActor () -> Void
    ) {
        registration = Registration(owner: owner, isDirty: isDirty, save: save, discard: discard)
    }

    func unregister(owner: AnyObject) {
        guard registration?.owner === owner else { return }
        registration = nil
    }

    /// Decides what should happen for a termination request. When the answer is
    /// `.terminateLater`, `reply` is invoked once the asynchronous save settles.
    ///
    /// Re-entrant requests are absorbed: while a save is in flight the original task owns
    /// the reply, and while the modal question is on screen a repeat request is refused
    /// instead of stacking a second alert.
    func requestTermination(reply: @escaping @MainActor (Bool) -> Void) -> Outcome {
        if isSavingForTermination { return .terminateLater }
        if isDeciding { return .cancel }
        if registration?.owner == nil { registration = nil }
        guard let registration, registration.isDirty() else { return .terminateNow }

        isDeciding = true
        let choice = presentAlert()
        isDeciding = false

        switch choice {
        case .cancel:
            return .cancel
        case .discard:
            registration.discard()
            return .terminateNow
        case .save:
            isSavingForTermination = true
            Task { @MainActor [weak self] in
                let saved = await registration.save()
                self?.isSavingForTermination = false
                if !saved { self?.presentSaveFailureAlert() }
                reply(saved)
            }
            return .terminateLater
        }
    }
}
