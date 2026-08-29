import AppKit
import Combine
import Sparkle
import SwiftUI

@MainActor
final class SparkleUpdater: NSObject, ObservableObject {
    static let shared = SparkleUpdater()

    @Published private(set) var canCheckForUpdates = false

    private var controller: SPUStandardUpdaterController?

    var isEnabled: Bool {
        Bundle.main.sparkleFeedURLString != nil && Bundle.main.sparklePublicEDKey != nil
    }

    override init() {
        super.init()
        start()
    }

    func start() {
        guard isEnabled, controller == nil else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller?.updater.checkForUpdates()
    }
}

/// Intermediate view so the menu item's disabled state updates (Sparkle SwiftUI setup).
struct CheckForUpdatesCommand: View {
    @ObservedObject private var updater = SparkleUpdater.shared

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!updater.canCheckForUpdates)
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
