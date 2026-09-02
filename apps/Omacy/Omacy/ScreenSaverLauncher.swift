import AppKit
import Foundation

@MainActor
final class LoadingActivityCounter {
    private(set) var count = 0
    var isActive: Bool { count > 0 }
    func begin() { count += 1 }
    func end() { count = max(0, count - 1) }
}

@MainActor
struct ScreenSaverPreparation {
    let embeddedPath: String
    let refreshRegistration: () async throws -> OmacyRegistrationState
    let unregisterRegistration: (String) async throws -> Void
    let registerEmbeddedExtension: () async throws -> Void
    let inspectCurrentDisplays: () async throws -> OmacyCurrentDisplayStatus
    let activateOnAllDisplaysAndSpaces: () async throws -> Void

    func prepare() async throws {
        var registration = try await refreshRegistration()
        switch registration {
        case .notRegistered:
            try await registerEmbeddedExtension()
            registration = try await refreshRegistration()
        case .missingRegistrations(let registrations):
            try await replaceStaleRegistrations(registrations)
            registration = try await refreshRegistration()
        case .registered(let registered) where registered.path != embeddedPath:
            try await replaceStaleRegistrations([registered])
            registration = try await refreshRegistration()
        case .registered:
            break
        case .conflictingRegistrations:
            throw PluginError.conflictingRegistrations
        }
        guard case .registered(let registered) = registration,
              registered.path == embeddedPath else {
            throw PluginError.registrationVerificationFailed
        }

        var displays = try await inspectCurrentDisplays()
        if !displays.isActiveOnAllCurrentDisplays {
            try await activateOnAllDisplaysAndSpaces()
            displays = try await inspectCurrentDisplays()
        }
        guard displays.isActiveOnAllCurrentDisplays else {
            throw PluginError.activationVerificationFailed
        }
    }

    private func replaceStaleRegistrations(
        _ registrations: [OmacyPluginRegistration]
    ) async throws {
        for registration in registrations where registration.path != embeddedPath {
            try await unregisterRegistration(registration.path)
        }
        try await registerEmbeddedExtension()
    }
}

@MainActor
struct RegistrationRepair {
    let unregister: (String) async throws -> Void
    let registerEmbeddedExtension: () async throws -> Void
    let refreshRegistration: () async throws -> OmacyRegistrationState

    func repair(
        _ state: OmacyRegistrationState,
        embeddedPath: String
    ) async throws {
        guard let registrations = state.registrationsNeedingRepair else {
            throw PluginError.registrationDoesNotNeedRepair
        }
        let stale = registrations.filter { $0.path != embeddedPath }
        for registration in stale {
            try await unregister(registration.path)
        }
        try await registerEmbeddedExtension()
        let refreshed = try await refreshRegistration()
        guard case .registered = refreshed else {
            throw PluginError.registrationVerificationFailed
        }
    }
}

@MainActor
protocol ScreenSaverLaunching {
    func launch() async throws
}

enum ScreenSaverLaunchError: LocalizedError, Equatable {
    case applicationNotFound

    var errorDescription: String? {
        switch self {
        case .applicationNotFound:
            return "macOS couldn't find ScreenSaverEngine."
        }
    }
}

@MainActor
struct ScreenSaverLauncher: ScreenSaverLaunching {
    static let bundleIdentifier = "com.apple.ScreenSaver.Engine"
    nonisolated static let canonicalApplicationURL = URL(
        fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app",
        isDirectory: true
    )

    private let resolveApplicationURL: (String) -> URL?
    private let canonicalURL: URL
    private let fileExists: (String) -> Bool
    private let openApplication: (URL) async throws -> Void

    init(
        resolveApplicationURL: @escaping (String) -> URL? = {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        },
        canonicalApplicationURL: URL = ScreenSaverLauncher.canonicalApplicationURL,
        fileExists: @escaping (String) -> Bool = FileManager.default.fileExists(atPath:),
        openApplication: @escaping (URL) async throws -> Void = ScreenSaverLauncher.open
    ) {
        self.resolveApplicationURL = resolveApplicationURL
        self.canonicalURL = canonicalApplicationURL
        self.fileExists = fileExists
        self.openApplication = openApplication
    }

    func launch() async throws {
        let applicationURL: URL
        if let resolved = resolveApplicationURL(Self.bundleIdentifier) {
            applicationURL = resolved
        } else if fileExists(canonicalURL.path) {
            applicationURL = canonicalURL
        } else {
            throw ScreenSaverLaunchError.applicationNotFound
        }
        try await openApplication(applicationURL)
    }

    private static func open(_ applicationURL: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(
                at: applicationURL,
                configuration: configuration
            ) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
