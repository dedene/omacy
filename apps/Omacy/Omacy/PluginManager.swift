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

@MainActor
class PluginManager: ObservableObject {
    @Published var isInstalled: Bool = false
    @Published var installedVersion: String?
    @Published var installedPath: String?
    @Published var isLoading: Bool = false
    @Published var lastError: String?

    @Published var isActiveScreensaver: Bool = false
    @Published var isCheckingScreensaver: Bool = false
    @Published var screensaverError: String?

    private let bundleIdentifier = "be.zenjoy.omacy.screensaver"
    private let paperSaver = PaperSaver()
    private let screensaverDisplayName = "Omacy"

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
                let (isRegistered, path, version) = try await queryPluginKit()
                await MainActor.run {
                    self.isInstalled = isRegistered
                    self.installedPath = path
                    self.installedVersion = version
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.isInstalled = false
                    self.installedPath = nil
                    self.installedVersion = nil
                    self.isLoading = false
                    self.lastError = error.localizedDescription
                }
            }
        }
    }

    /// Query pluginkit for our extension's registration status.
    /// Line format we look for:
    ///   `+    be.zenjoy.omacy.screensaver(1.0) <path>`
    private func queryPluginKit() async throws -> (Bool, String?, String?) {
        let output = try runProcess("/usr/bin/pluginkit", arguments: ["-m", "-v", "-p", "com.apple.screensaver"])

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

                return (true, path, version)
            }
        }

        return (false, nil, nil)
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

    /// Uninstall the extension.
    func uninstall() throws {
        let extensionPath: String
        if let installed = installedPath, !installed.isEmpty {
            extensionPath = installed
        } else if let embedded = embeddedExtensionPath {
            extensionPath = embedded
        } else {
            throw PluginError.extensionPathNotFound
        }

        logger.info("Uninstalling extension at: \(extensionPath, privacy: .public)")

        isLoading = true
        lastError = nil

        do {
            _ = try runProcess("/usr/bin/pluginkit", arguments: ["-r", extensionPath])
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
        isActiveScreensaver = activeScreensavers.contains(screensaverDisplayName)
        isCheckingScreensaver = false
    }

    /// Enable our screensaver as the active screensaver on every display.
    func enableAsScreensaver() async {
        isCheckingScreensaver = true
        screensaverError = nil

        do {
            try await paperSaver.setScreensaverEverywhere(module: screensaverDisplayName)
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
