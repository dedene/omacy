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
import PaperSaverKit

private let logger = AppexLog.logger("PluginManager")

struct OmacyUpdateRecovery {
    let currentIdentity: String
    let storedIdentity: () -> String?
    let isActiveScreensaver: () -> Bool
    let registerExtension: () throws -> Void
    let restartWallpaperAgent: () throws -> Void
    let recordIdentity: (String) -> Void

    func reconcile() throws {
        guard storedIdentity() != currentIdentity else { return }
        if isActiveScreensaver() {
            try registerExtension()
            try restartWallpaperAgent()
        }
        recordIdentity(currentIdentity)
    }
}

enum OmacyUpdateRecoveryLauncher {
    private static let recordedIdentityKey = "lastReconciledScreensaverIdentity"
    private static let activeNames: Set<String> = [
        "Omacy", "OmacyScreensaver", "be.zenjoy.omacy.screensaver",
    ]

    static func reconcileAfterLaunch(
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard
    ) {
        guard bundle.bundlePath.hasPrefix("/Applications/"),
              let extensionURL = bundle.builtInPlugInsURL?
                .appendingPathComponent("OmacyScreensaver.appex"),
              let extensionBundle = Bundle(url: extensionURL),
              let shortVersion = extensionBundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
              ) as? String,
              let buildVersion = extensionBundle.object(
                forInfoDictionaryKey: "CFBundleVersion"
              ) as? String else { return }

        let identity = "\(shortVersion):\(buildVersion)"
        let recovery = OmacyUpdateRecovery(
            currentIdentity: identity,
            storedIdentity: { defaults.string(forKey: recordedIdentityKey) },
            isActiveScreensaver: {
                PaperSaver().getActiveScreensavers().contains { activeNames.contains($0) }
            },
            registerExtension: {
                try runProcess(
                    "/usr/bin/pluginkit", arguments: ["-a", extensionURL.path],
                    acceptedStatuses: [0]
                )
            },
            restartWallpaperAgent: {
                // PaperSaver uses the same field-proven refresh after changing
                // screen saver configuration. Status 1 means no agent was running.
                try runProcess(
                    "/usr/bin/killall", arguments: ["WallpaperAgent"],
                    acceptedStatuses: [0, 1]
                )
            },
            recordIdentity: { defaults.set($0, forKey: recordedIdentityKey) }
        )

        do {
            try recovery.reconcile()
        } catch {
            logger.error("Update reconciliation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func runProcess(
        _ path: String,
        arguments: [String],
        acceptedStatuses: Set<Int32>
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard acceptedStatuses.contains(process.terminationStatus) else {
            throw NSError(
                domain: "be.zenjoy.omacy.update-recovery",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "\(path) exited with status \(process.terminationStatus)"]
            )
        }
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

    /// Registered with PlugInKit but the appex file is gone.
    var isPluginMissing: Bool {
        guard isInstalled else { return false }
        guard let path = installedPath, !path.isEmpty else { return true }
        return !FileManager.default.fileExists(atPath: path)
    }

    /// PlugInKit is sticky if DerivedData and /Applications are both registered.
    var hasConflictingRegistrations: Bool {
        registeredPaths.count > 1
    }

    @Published var isActiveScreensaver: Bool = false
    @Published var isCheckingScreensaver: Bool = false
    @Published var screensaverError: String?

    private let bundleIdentifier = "be.zenjoy.omacy.screensaver"
    private let paperSaver = PaperSaver()
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

    init() {
        checkInstallationStatus()
        checkScreensaverStatus()
    }

    /// Check if the extension is registered with pluginkit.
    func checkInstallationStatus() {
        isLoading = true
        lastError = nil

        Task {
            do {
                let matches = try await queryPluginKit()
                await MainActor.run {
                    self.registeredPaths = matches.map(\.path).compactMap { $0 }
                    self.isInstalled = !matches.isEmpty
                    self.installedPath = matches.first?.path
                    self.installedVersion = matches.first?.version
                    self.isLoading = false
                    if matches.count > 1 {
                        self.lastError = "Registered in more than one place. Unregister extras so only /Applications or DerivedData remains."
                    }
                }
            } catch {
                await MainActor.run {
                    self.isInstalled = false
                    self.installedPath = nil
                    self.installedVersion = nil
                    self.registeredPaths = []
                    self.isLoading = false
                    self.lastError = error.localizedDescription
                }
            }
        }
    }

    private struct PluginMatch {
        var path: String?
        var version: String?
    }

    /// Query pluginkit for our extension's registration status.
    /// Line format we look for:
    ///   `+    be.zenjoy.omacy.screensaver(0.1.0) <path>`
    private func queryPluginKit() async throws -> [PluginMatch] {
        let output = try runProcess("/usr/bin/pluginkit", arguments: ["-m", "-v", "-p", "com.apple.screensaver"])

        var matches: [PluginMatch] = []
        let lines = output.components(separatedBy: "\n")
        for line in lines {
            if line.contains(bundleIdentifier) {
                logger.info("Found extension in pluginkit output: \(line, privacy: .public)")

                var version: String?
                if let versionStart = line.firstIndex(of: "("),
                   let versionEnd = line.firstIndex(of: ")") {
                    let start = line.index(after: versionStart)
                    version = String(line[start..<versionEnd])
                }

                var path: String?
                if let pathStart = line.range(of: "/", options: [], range: line.startIndex..<line.endIndex) {
                    path = String(line[pathStart.lowerBound...])
                }

                matches.append(PluginMatch(path: path, version: version))
            }
        }

        return matches
    }

    /// Install the embedded extension by handing it to pluginkit.
    func install() throws {
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

        isLoading = true
        lastError = nil

        do {
            _ = try runProcess("/usr/bin/pluginkit", arguments: ["-a", extensionPath])
            logger.info("Extension installed successfully")

            checkInstallationStatus()
            checkScreensaverStatus()
        } catch {
            isLoading = false
            lastError = error.localizedDescription
            throw error
        }
    }

    /// Uninstall every registered copy, then the embedded path as a fallback.
    func uninstall() throws {
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

        isLoading = true
        lastError = nil

        do {
            for extensionPath in paths {
                logger.info("Uninstalling extension at: \(extensionPath, privacy: .public)")
                _ = try runProcess("/usr/bin/pluginkit", arguments: ["-r", extensionPath])
            }
            logger.info("Extension uninstalled successfully")
            checkInstallationStatus()
        } catch {
            isLoading = false
            lastError = error.localizedDescription
            throw error
        }
    }

    /// Check if our screensaver is the active screensaver on any display.
    func checkScreensaverStatus() {
        isCheckingScreensaver = true
        screensaverError = nil

        let activeScreensavers = paperSaver.getActiveScreensavers()
        let names: Set<String> = [paperSaverModuleName, screensaverDisplayName]
        isActiveScreensaver = activeScreensavers.contains { names.contains($0) }
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

    private func allowedInstallLocation() -> Bool {
        let path = Bundle.main.bundlePath
        if path.hasPrefix("/Applications/") { return true }
        if path.contains("/DerivedData/") { return true }
        return false
    }

    /// Run a subprocess and return its combined stdout/stderr.
    private func runProcess(_ path: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        logger.debug("Process output: \(output, privacy: .public)")

        if process.terminationStatus != 0 {
            // pluginkit returns non-zero when no matches are found, so don't treat it as fatal.
            logger.warning("Process exited with status: \(process.terminationStatus)")
        }

        return output
    }
}

enum PluginError: LocalizedError {
    case embeddedExtensionNotFound
    case extensionPathNotFound
    case installationFailed(String)
    case uninstallationFailed(String)
    case notInApplications

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
        }
    }
}
