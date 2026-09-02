//
//  PluginManager.swift
//  Omacy
//
//  Copyright © 2026 Guillaume Louel. Licensed under the MIT License.
//
//  Drives extension registration (via pluginkit) and screensaver activation
//  (via PaperSaverKit) from the host app's UI.
//

import Foundation
import AppKit
import PaperSaverKit

private let logger = AppexLog.logger("PluginManager")

struct OmacyPluginRegistration: Equatable {
    let path: String
    let version: String?
}

enum OmacyRegistrationState: Equatable {
    case notRegistered
    case missingRegistrations([OmacyPluginRegistration])
    case registered(OmacyPluginRegistration)
    case conflictingRegistrations([OmacyPluginRegistration])

    static func classify(
        _ registrations: [OmacyPluginRegistration],
        fileExists: (String) -> Bool
    ) -> Self {
        let sorted = registrations.sorted {
            ($0.path, $0.version ?? "") < ($1.path, $1.version ?? "")
        }.reduce(into: [OmacyPluginRegistration]()) { unique, registration in
            if unique.last != registration { unique.append(registration) }
        }
        guard !sorted.isEmpty else { return .notRegistered }
        let live = sorted.filter { fileExists($0.path) }
        if live.isEmpty { return .missingRegistrations(sorted) }
        guard sorted.count == 1 else { return .conflictingRegistrations(sorted) }
        return .registered(sorted[0])
    }

    var isMissing: Bool {
        if case .missingRegistrations = self { return true }
        return false
    }

    var hasConflicts: Bool {
        if case .conflictingRegistrations = self { return true }
        return false
    }

    func isRegistered(at embeddedPath: String?) -> Bool {
        guard let embeddedPath, case .registered(let registration) = self else { return false }
        return registration.path == embeddedPath
    }

    func pathsToRemoveBeforeInstalling(at embeddedPath: String) throws -> [String] {
        switch self {
        case .notRegistered:
            return []
        case .missingRegistrations(let registrations):
            return registrations.map(\.path).filter { $0 != embeddedPath }
        case .registered(let registration):
            return registration.path == embeddedPath ? [] : [registration.path]
        case .conflictingRegistrations:
            throw PluginError.conflictingRegistrations
        }
    }

    var registrationsNeedingRepair: [OmacyPluginRegistration]? {
        switch self {
        case .missingRegistrations(let registrations),
             .conflictingRegistrations(let registrations):
            return registrations.sorted { $0.path < $1.path }
        case .notRegistered, .registered:
            return nil
        }
    }
}

enum OmacyScreensaverIdentity {
    static let aliases: Set<String> = [
        "Omacy", "OmacyScreensaver", "be.zenjoy.omacy.screensaver",
    ]

    static func isOmacy(_ value: String) -> Bool { aliases.contains(value) }
}

enum OmacyCurrentDisplayStatus: Equatable {
    case inactive(displayCount: Int)
    case activeOnSome(activeCount: Int, displayCount: Int)
    case activeOnAll(displayCount: Int)

    static func classify(_ screensaverNames: [String]) -> Self {
        let activeCount = screensaverNames.count(where: OmacyScreensaverIdentity.isOmacy)
        guard activeCount > 0 else { return .inactive(displayCount: screensaverNames.count) }
        guard activeCount == screensaverNames.count else {
            return .activeOnSome(activeCount: activeCount, displayCount: screensaverNames.count)
        }
        return .activeOnAll(displayCount: screensaverNames.count)
    }

    var isActiveOnAllCurrentDisplays: Bool {
        if case .activeOnAll(let count) = self { return count > 0 }
        return false
    }
}

@MainActor
class PluginManager: ObservableObject {
    @Published var isInstalled: Bool = false
    @Published var installedVersion: String?
    @Published var installedPath: String?
    @Published var isLoading: Bool = false
    @Published var lastError: String?
    @Published var registeredPaths: [String] = []
    @Published private(set) var registrationState: OmacyRegistrationState = .notRegistered

    /// Registered with PlugInKit but the appex file is gone.
    var isPluginMissing: Bool {
        registrationState.isMissing
    }

    /// PlugInKit is sticky if DerivedData and /Applications are both registered.
    var hasConflictingRegistrations: Bool {
        registrationState.hasConflicts
    }

    var isCurrentExtensionInstalled: Bool {
        registrationState.isRegistered(at: embeddedExtensionPath)
    }

    @Published var isActiveScreensaver: Bool = false
    @Published var isCheckingScreensaver: Bool = false
    @Published var screensaverError: String?
    @Published private(set) var currentDisplayStatus: OmacyCurrentDisplayStatus = .inactive(displayCount: 0)

    private let bundleIdentifier = "be.zenjoy.omacy.screensaver"
    private let paperSaver = PaperSaver()
    private let processRunner: OmacyProcessRunner
    private let loadingActivity = LoadingActivityCounter()
    private let screensaverDisplayName = "Omacy"

    /// PaperSaver looks up modules by the `.appex` filename, not CFBundleDisplayName.
    /// Ours ships as `OmacyScreensaver.appex`, so `module: "Omacy"` 404s.
    private var paperSaverModuleName: String {
        let available = paperSaver.listAvailableScreensavers()
        if let hit = available.first(where: { $0.path.path.contains(bundleIdentifier) }) {
            return hit.name
        }
        if let path = embeddedExtensionPath ?? installedPath {
            let fileName = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            if available.contains(where: { $0.name == fileName }) {
                return fileName
            }
            return fileName
        }
        return screensaverDisplayName
    }

    /// Path to the embedded extension in the app bundle.
    var embeddedExtensionPath: String? {
        Bundle.main.builtInPlugInsURL?.appendingPathComponent("OmacyScreensaver.appex").path
    }

    /// Version of the embedded extension.
    var embeddedVersion: String? {
        guard let path = embeddedExtensionPath,
              let bundle = Bundle(path: path),
              let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String else {
            return nil
        }
        return version
    }

    init(processRunner: OmacyProcessRunner = OmacyProcessRunner()) {
        self.processRunner = processRunner
        checkInstallationStatus()
        checkScreensaverStatus()
    }

    /// Check if the extension is registered with pluginkit.
    func checkInstallationStatus() {
        beginLoading()
        Task {
            defer { self.endLoading() }
            do {
                _ = try await refreshRegistrationState()
            } catch {
                self.registrationState = .notRegistered
                self.isInstalled = false
                self.installedPath = nil
                self.installedVersion = nil
                self.registeredPaths = []
                self.lastError = error.localizedDescription
            }
        }
    }

    /// Query pluginkit for our extension's registration status.
    /// Line format we look for:
    ///   `+    be.zenjoy.omacy.screensaver(0.1.0) <path>`
    private func queryPluginKit() async throws -> [OmacyPluginRegistration] {
        let result = try await runProcessResult(
            "/usr/bin/pluginkit",
            arguments: ["-m", "-v", "-p", "com.apple.screensaver"]
        )
        return try OmacyPluginQuery.parse(result, bundleIdentifier: bundleIdentifier)
    }

    @discardableResult
    func refreshRegistrationState() async throws -> OmacyRegistrationState {
        beginLoading()
        defer { endLoading() }
        return try await {
            lastError = nil
            let matches = try await queryPluginKit()
            let registrations = matches.sorted {
                ($0.path, $0.version ?? "") < ($1.path, $1.version ?? "")
            }
            let state = OmacyRegistrationState.classify(
                registrations,
                fileExists: FileManager.default.fileExists(atPath:)
            )
            registrationState = state
            registeredPaths = registrations.map(\.path)
            isInstalled = !registrations.isEmpty
            switch state {
            case .registered(let registration):
                installedPath = registration.path
                installedVersion = registration.version
            case .missingRegistrations(let registrations):
                installedPath = registrations.first?.path
                installedVersion = registrations.first?.version
            case .notRegistered, .conflictingRegistrations:
                installedPath = nil
                installedVersion = nil
            }
            if case .conflictingRegistrations = state {
                lastError = "Registered in more than one place. Repair registration before continuing."
            }
            return state
        }()
    }

    /// Install the embedded extension by handing it to pluginkit.
    func install() async throws {
        guard allowedInstallLocation() else {
            throw PluginError.notInApplications
        }
        guard let extensionPath = embeddedExtensionPath else {
            throw PluginError.embeddedExtensionNotFound
        }

        guard FileManager.default.fileExists(atPath: extensionPath) else {
            throw PluginError.embeddedExtensionNotFound
        }

        logger.info("Installing extension from: \(extensionPath, privacy: .public)")

        beginLoading()
        defer { endLoading() }
        lastError = nil

        do {
            for stalePath in try registrationState.pathsToRemoveBeforeInstalling(at: extensionPath) {
                try await unregisterRegistration(at: stalePath)
            }
            try await runProcessRequiringSuccess(
                "/usr/bin/pluginkit", arguments: ["-a", extensionPath]
            )
            logger.info("Extension installed successfully")

            let refreshed = try await refreshRegistrationState()
            guard refreshed.isRegistered(at: extensionPath) else {
                throw PluginError.registrationVerificationFailed
            }
            checkScreensaverStatus()
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    /// Uninstall every registered copy, then the embedded path as a fallback.
    func uninstall() async throws {
        var paths = registeredPaths
        if paths.isEmpty {
            if let installed = installedPath, !installed.isEmpty {
                paths = [installed]
            } else if let embedded = embeddedExtensionPath {
                paths = [embedded]
            } else {
                throw PluginError.extensionPathNotFound
            }
        }

        beginLoading()
        defer { endLoading() }
        lastError = nil

        do {
            for extensionPath in paths {
                logger.info("Uninstalling extension at: \(extensionPath, privacy: .public)")
                try await runProcessRequiringSuccess(
                    "/usr/bin/pluginkit", arguments: ["-r", extensionPath]
                )
            }
            logger.info("Extension uninstalled successfully")
            _ = try await refreshRegistrationState()
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    /// Check Omacy on the current space of every currently connected display.
    func checkScreensaverStatus() {
        isCheckingScreensaver = true
        screensaverError = nil
        currentDisplayStatus = inspectCurrentDisplayStatus()
        isActiveScreensaver = currentDisplayStatus.isActiveOnAllCurrentDisplays
        isCheckingScreensaver = false
    }

    /// Enable our screensaver as the active screensaver on every display.
    func enableAsScreensaver() async {
        isCheckingScreensaver = true
        screensaverError = nil

        do {
            let module = paperSaverModuleName
            logger.info("setScreensaverEverywhere module=\(module, privacy: .public)")
            try await paperSaver.setScreensaverEverywhere(module: module)
            checkScreensaverStatus()
        } catch {
            screensaverError = error.localizedDescription
            isCheckingScreensaver = false
        }
    }

    /// Prepare the registered extension and current display configuration for a real test.
    func prepareForScreenSaverTest() async throws {
        beginLoading()
        isCheckingScreensaver = true
        lastError = nil
        screensaverError = nil
        defer {
            endLoading()
            isCheckingScreensaver = false
        }
        guard let embeddedExtensionPath else {
            throw PluginError.embeddedExtensionNotFound
        }
        let preparation = ScreenSaverPreparation(
            embeddedPath: embeddedExtensionPath,
            refreshRegistration: { [weak self] in
                guard let self else { throw PluginError.managerUnavailable }
                return try await self.refreshRegistrationState()
            },
            unregisterRegistration: { [weak self] path in
                guard let self else { throw PluginError.managerUnavailable }
                try await self.unregisterRegistration(at: path)
            },
            registerEmbeddedExtension: { [weak self] in
                guard let self else { throw PluginError.managerUnavailable }
                try await self.registerEmbeddedExtension()
            },
            inspectCurrentDisplays: { [weak self] in
                guard let self else { throw PluginError.managerUnavailable }
                let status = self.inspectCurrentDisplayStatus()
                self.currentDisplayStatus = status
                self.isActiveScreensaver = status.isActiveOnAllCurrentDisplays
                return status
            },
            activateOnAllDisplaysAndSpaces: { [weak self] in
                guard let self else { throw PluginError.managerUnavailable }
                try await self.activateOnAllDisplaysAndSpaces()
            }
        )
        do {
            try await preparation.prepare()
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    /// Explicitly remove stale or duplicate registrations and register this app's extension.
    func repairRegistration() async throws {
        beginLoading()
        lastError = nil
        defer { endLoading() }
        let repair = RegistrationRepair(
            unregister: { [weak self] path in
                guard let self else { throw PluginError.managerUnavailable }
                try await self.runProcessRequiringSuccess(
                    "/usr/bin/pluginkit", arguments: ["-r", path]
                )
            },
            registerEmbeddedExtension: { [weak self] in
                guard let self else { throw PluginError.managerUnavailable }
                try await self.registerEmbeddedExtension()
            },
            refreshRegistration: { [weak self] in
                guard let self else { throw PluginError.managerUnavailable }
                return try await self.refreshRegistrationState()
            }
        )
        do {
            guard let embeddedExtensionPath else { throw PluginError.embeddedExtensionNotFound }
            try await repair.repair(
                registrationState,
                embeddedPath: embeddedExtensionPath
            )
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    private func registerEmbeddedExtension() async throws {
        guard allowedInstallLocation() else { throw PluginError.notInApplications }
        guard let path = embeddedExtensionPath,
              FileManager.default.fileExists(atPath: path) else {
            throw PluginError.embeddedExtensionNotFound
        }
        try await runProcessRequiringSuccess("/usr/bin/pluginkit", arguments: ["-a", path])
    }

    private func unregisterRegistration(at path: String) async throws {
        guard path != embeddedExtensionPath else { return }
        try await runProcessRequiringSuccess("/usr/bin/pluginkit", arguments: ["-r", path])
    }

    private func activateOnAllDisplaysAndSpaces() async throws {
        try await paperSaver.setScreensaverEverywhere(module: paperSaverModuleName)
    }

    private func inspectCurrentDisplayStatus() -> OmacyCurrentDisplayStatus {
        let names = NSScreen.screens.map { screen -> String in
            guard let info = paperSaver.getActiveScreensaver(for: screen) else { return "" }
            if OmacyScreensaverIdentity.isOmacy(info.identifier) { return info.identifier }
            return info.name
        }
        return .classify(names)
    }

    private func allowedInstallLocation() -> Bool {
        let path = Bundle.main.bundlePath
        if path.hasPrefix("/Applications/") { return true }
        if path.contains("/DerivedData/") { return true }
        return false
    }

    private func beginLoading() {
        loadingActivity.begin()
        isLoading = loadingActivity.isActive
    }

    private func endLoading() {
        loadingActivity.end()
        isLoading = loadingActivity.isActive
    }

    /// Run a subprocess and return its combined stdout/stderr.
    private func runProcessRequiringSuccess(
        _ path: String,
        arguments: [String]
    ) async throws {
        let result = try await runProcessResult(path, arguments: arguments)
        if result.status != 0 {
            logger.warning("Process exited with status: \(result.status)")
            throw PluginError.processFailed(path, result.status, result.output)
        }
    }

    private func runProcessResult(
        _ path: String,
        arguments: [String]
    ) async throws -> OmacyPluginProcessResult {
        let result = try await processRunner.run(
            executableURL: URL(fileURLWithPath: path),
            arguments: arguments
        )
        logger.debug("Process output: \(result.output, privacy: .public)")
        return result
    }
}

enum PluginError: LocalizedError {
    case embeddedExtensionNotFound
    case extensionPathNotFound
    case installationFailed(String)
    case uninstallationFailed(String)
    case notInApplications
    case conflictingRegistrations
    case registrationVerificationFailed
    case activationVerificationFailed
    case managerUnavailable
    case processFailed(String, Int32, String)
    case registrationDoesNotNeedRepair

    var errorDescription: String? {
        switch self {
        case .embeddedExtensionNotFound:
            return "Embedded extension not found in app bundle"
        case .extensionPathNotFound:
            return "Extension path not found"
        case .installationFailed(let message):
            return "Installation failed: \(message)"
        case .uninstallationFailed(let message):
            return "Uninstallation failed: \(message)"
        case .notInApplications:
            return "Move Omacy.app to /Applications, then register. The host will not register from a random path."
        case .conflictingRegistrations:
            return "Omacy is registered in more than one place. Repair registration before testing."
        case .registrationVerificationFailed:
            return "Omacy's screen saver extension could not be verified after registration."
        case .activationVerificationFailed:
            return "Omacy couldn't be made active on every current display."
        case .managerUnavailable:
            return "Screen saver setup is no longer available."
        case .processFailed(let path, let status, let output):
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(path) exited with status \(status)\(detail.isEmpty ? "" : ": \(detail)")"
        case .registrationDoesNotNeedRepair:
            return "Omacy's registration does not need repair."
        }
    }
}
