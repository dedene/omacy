import AppKit
import Foundation

extension Notification.Name {
    static let omacyConfigDidChange = Notification.Name("omacy.configDidChange")
}

enum OmacyStore {
    static let forceCanaryKey = "omacy.forceCanary"
    private static let repository = OmacyConfigRepository(paths: .live(), bundledArt: { bundledArt })
    static private(set) var lastLoadError: String?

    static var settingsURL: URL? { repository.paths.settingsURL }
    static var artURL: URL? { repository.paths.artURL }

    static var bundledArt: String {
        if let url = Bundle.main.url(forResource: "screensaver", withExtension: "txt", subdirectory: nil)
            ?? Bundle.main.url(forResource: "screensaver", withExtension: "txt"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        return "OMACY"
    }

    static var bundledFontURL: URL? {
        Bundle.main.url(forResource: "FairfaxHD", withExtension: "ttf")
            ?? Bundle.main.url(forResource: "Fairfax", withExtension: "ttf")
    }

    static func loadConfiguration() -> OmacyConfigSnapshot {
        let snapshot = repository.load()
        lastLoadError = snapshot.diagnostic
        return snapshot
    }

    static func decodeSettings(
        _ data: Data,
        lastGood: OmacySettings
    ) -> (settings: OmacySettings, error: String?) {
        OmacySettingsCodec.decode(data, lastGood: lastGood)
    }

    static func save(settings: OmacySettings, art: String) throws {
        do {
            try repository.save(settings: settings, art: art)
            lastLoadError = nil
            NotificationCenter.default.post(name: .omacyConfigDidChange, object: nil)
        } catch {
            lastLoadError = error.localizedDescription
            throw error
        }
    }

    @discardableResult
    static func performHostMigrationIfNeeded(
        defaults: () throws -> OmacyLegacyConfiguration?,
        files: () throws -> OmacyLegacyConfiguration?
    ) throws -> OmacyMigrationResult {
        try repository.migrateIfNeeded(defaults: defaults, files: files)
    }

    static func retryHostMigration() { repository.retryMigration() }

    static func restoreDefaultArt() throws {
        let current = loadConfiguration()
        try save(settings: current.settings, art: bundledArt)
    }

    static func resetToDefaults() throws {
        try save(settings: OmacySettings(), art: bundledArt)
    }

    static var forceCanary: Bool { UserDefaults.standard.bool(forKey: forceCanaryKey) }
}
