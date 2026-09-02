import Foundation
import PaperSaverKit

private let updateRecoveryLogger = AppexLog.logger("OmacyUpdateRecovery")

struct OmacyUpdateRecovery {
    static func reconcile(
        currentIdentity: String,
        storedIdentity: () -> String?,
        isActiveScreensaver: () -> Bool,
        registerExtension: () async throws -> Void,
        restartWallpaperAgent: () async throws -> Void,
        recordIdentity: (String) -> Void
    ) async throws {
        guard storedIdentity() != currentIdentity else { return }
        if isActiveScreensaver() {
            try await registerExtension()
            try await restartWallpaperAgent()
        }
        recordIdentity(currentIdentity)
    }
}

enum OmacyUpdateRecoveryLauncher {
    private static let recordedIdentityKey = "lastReconciledScreensaverIdentity"

    static func reconcileAfterLaunch(
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard,
        processRunner: OmacyProcessRunner = OmacyProcessRunner()
    ) {
        Task {
            await reconcileAfterLaunchNow(
                bundle: bundle,
                defaults: defaults,
                processRunner: processRunner
            )
        }
    }

    private static func reconcileAfterLaunchNow(
        bundle: Bundle,
        defaults: UserDefaults,
        processRunner: OmacyProcessRunner
    ) async {
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
        do {
            try await OmacyUpdateRecovery.reconcile(
                currentIdentity: identity,
                storedIdentity: { defaults.string(forKey: recordedIdentityKey) },
                isActiveScreensaver: {
                    PaperSaver().getActiveScreensavers().contains(
                        where: OmacyScreensaverIdentity.isOmacy
                    )
                },
                registerExtension: {
                    try await runProcess(
                        processRunner,
                        path: "/usr/bin/pluginkit",
                        arguments: ["-a", extensionURL.path],
                        acceptedStatuses: [0]
                    )
                },
                restartWallpaperAgent: {
                    try await runProcess(
                        processRunner,
                        path: "/usr/bin/killall",
                        arguments: ["WallpaperAgent"],
                        acceptedStatuses: [0, 1]
                    )
                },
                recordIdentity: { defaults.set($0, forKey: recordedIdentityKey) }
            )
        } catch {
            updateRecoveryLogger.error(
                "Update reconciliation failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private static func runProcess(
        _ runner: OmacyProcessRunner,
        path: String,
        arguments: [String],
        acceptedStatuses: Set<Int32>
    ) async throws {
        let result = try await runner.run(
            executableURL: URL(fileURLWithPath: path),
            arguments: arguments
        )
        guard acceptedStatuses.contains(result.status) else {
            throw NSError(
                domain: "be.zenjoy.omacy.update-recovery",
                code: Int(result.status),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "\(path) exited with status \(result.status)"
                ]
            )
        }
    }
}
