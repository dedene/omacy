import AppKit
import Sparkle

@MainActor
final class SparkleUpdater: NSObject {
    static let shared = SparkleUpdater()

    private var controller: SPUStandardUpdaterController?

    var isEnabled: Bool {
        Bundle.main.sparkleFeedURLString != nil && Bundle.main.sparklePublicEDKey != nil
    }

    var canCheckForUpdates: Bool {
        controller?.updater.canCheckForUpdates ?? false
    }

    func start() {
        guard isEnabled, controller == nil else { return }
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}

private extension Bundle {
    var sparkleFeedURLString: String? { nonEmptyInfoValue("SUFeedURL") }
    var sparklePublicEDKey: String? { nonEmptyInfoValue("SUPublicEDKey") }

    func nonEmptyInfoValue(_ key: String) -> String? {
        guard let value = object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
