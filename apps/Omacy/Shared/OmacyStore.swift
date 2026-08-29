import Foundation
import AppKit
import Darwin

enum OmacyEffects {
    /// Keep in lockstep with `ttfx::effects::EffectCommand::NAMES`.
    static let names: [String] = [
        "beams", "binarypath", "blackhole", "bouncyballs", "bubbles", "burn",
        "colorshift", "crumble", "decrypt", "errorcorrect", "expand", "fireworks",
        "highlight", "laseretch", "matrix", "middleout", "orbittingvolley",
        "overflow", "pour", "print", "rain", "randomsequence", "rings",
        "scattered", "slice", "slide", "smoke", "spotlights", "spray", "swarm",
        "sweep", "synthgrid", "thunderstorm", "unstable", "vhstape", "waves",
        "wipe"
    ]

    static func sanitize(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { name in
            guard Self.names.contains(name), !seen.contains(name) else { return false }
            seen.insert(name)
            return true
        }
    }
}

struct OmacySettings: Equatable {
    var effect: String = "random"
    var effects: [String] = OmacyEffects.names
    var background: String = "#000000"
    var fontSize: Double = 18
    var asciiMode: String = "block"
    var threshold: Int = 50
    var invert: Bool = false

    var engineEffect: String {
        let selected = OmacyEffects.sanitize(effects)
        if selected.count == 1 { return selected[0] }
        return "random"
    }

    mutating func syncEngineEffect() {
        let selected = Set(OmacyEffects.sanitize(effects))
        effects = OmacyEffects.names.filter { selected.contains($0) }
        if effects.isEmpty { effects = OmacyEffects.names }
        effect = engineEffect
    }

    var backgroundRGBA: (UInt8, UInt8, UInt8, UInt8) {
        let hex = background.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6, let n = UInt32(hex, radix: 16) else {
            return (0, 0, 0, 255)
        }
        return (UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF), 255)
    }

    var asciiModeCode: UInt32 {
        asciiMode == "block" ? 1 : 0
    }
}

extension Notification.Name {
    static let omacyConfigDidChange = Notification.Name("omacy.configDidChange")
}

enum OmacyStore {
    static let appGroup = "group.be.zenjoy.omacy"
    static let forceCanaryKey = "omacy.forceCanary"

    private static var lastGoodSettings = OmacySettings()
    private static var lastGoodArt: String?
    static private(set) var lastLoadError: String?

    static var containerURL: URL? { readableConfigDirectories().first }

    static var settingsURL: URL? { containerURL?.appendingPathComponent("settings.json") }
    static var artURL: URL? { containerURL?.appendingPathComponent("screensaver.txt") }

    /// ScreenSaverEngine often denies the official App Group API even though
    /// the host wrote the files. Walk known locations, using the real home
    /// directory (sandbox `homeDirectoryForCurrentUser` is the container).
    static func readableConfigDirectories() -> [URL] {
        configDirectoryCandidates().filter { dir in
            let art = dir.appendingPathComponent("screensaver.txt")
            return FileManager.default.isReadableFile(atPath: art.path)
                || FileManager.default.isReadableFile(atPath: dir.path)
        }
    }

    static func configDirectoryCandidates() -> [URL] {
        var dirs: [URL] = []
        var seen = Set<String>()
        func add(_ url: URL?) {
            guard let url else { return }
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else { return }
            dirs.append(url)
        }
        add(FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup))
        let home = realHomeURL()
        add(home.appendingPathComponent("Library/Group Containers/\(appGroup)", isDirectory: true))
        add(home.appendingPathComponent("Library/Application Support/Omacy", isDirectory: true))
        return dirs
    }

    private static func realHomeURL() -> URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

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

    static func loadSettings() -> OmacySettings {
        guard let url = configDirectoryCandidates()
            .map({ $0.appendingPathComponent("settings.json") })
            .first(where: { FileManager.default.isReadableFile(atPath: $0.path) })
        else { return lastGoodSettings }
        guard FileManager.default.fileExists(atPath: url.path) else { return lastGoodSettings }
        do {
            let data = try Data(contentsOf: url)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                lastLoadError = "settings.json is invalid; keeping last-known-good"
                return lastGoodSettings
            }
            var s = OmacySettings()
            if let effect = obj["effect"] as? String { s.effect = effect }
            if let background = obj["background"] as? String { s.background = background }
            if let fontSize = obj["fontSize"] as? Double { s.fontSize = fontSize }
            if let asciiMode = obj["asciiMode"] as? String { s.asciiMode = asciiMode }
            if let threshold = obj["threshold"] as? Int { s.threshold = threshold }
            if let invert = obj["invert"] as? Bool { s.invert = invert }
            if let list = obj["effects"] as? [String] {
                s.effects = OmacyEffects.sanitize(list)
            } else if s.effect == "random" || s.effect.isEmpty {
                s.effects = OmacyEffects.names
            } else if OmacyEffects.names.contains(s.effect) {
                s.effects = [s.effect]
            } else {
                s.effects = OmacyEffects.names
            }
            s.syncEngineEffect()
            lastGoodSettings = s
            lastLoadError = nil
            return s
        } catch {
            lastLoadError = "Could not read settings.json; keeping last-known-good"
            return lastGoodSettings
        }
    }

    static func loadArt() -> String {
        for dir in configDirectoryCandidates() {
            let url = dir.appendingPathComponent("screensaver.txt")
            if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
                lastGoodArt = text
                lastLoadError = nil
                return text
            }
        }
        if let lastGoodArt { return lastGoodArt }
        return bundledArt
    }

    static func save(settings: OmacySettings, art: String) throws {
        var settings = settings
        settings.syncEngineEffect()
        let payload: [String: Any] = [
            "effect": settings.effect,
            "effects": settings.effects,
            "background": settings.background,
            "fontSize": settings.fontSize,
            "asciiMode": settings.asciiMode,
            "threshold": settings.threshold,
            "invert": settings.invert
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        let artData = Data(art.utf8)
        var wrote = false
        var lastWriteError: Error?
        for dir in configDirectoryCandidates() {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try atomicWrite(data, to: dir.appendingPathComponent("settings.json"))
                try atomicWrite(artData, to: dir.appendingPathComponent("screensaver.txt"))
                wrote = true
            } catch {
                lastWriteError = error
            }
        }
        guard wrote else {
            throw lastWriteError ?? NSError(
                domain: "Omacy",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "App Group container missing"]
            )
        }
        lastGoodSettings = settings
        lastGoodArt = art
        lastLoadError = nil
        NotificationCenter.default.post(name: .omacyConfigDidChange, object: nil)
    }

    static func restoreDefaultArt() throws {
        try save(settings: loadSettings(), art: bundledArt)
    }

    static func resetToDefaults() throws {
        try save(settings: OmacySettings(), art: bundledArt)
    }

    static var forceCanary: Bool {
        UserDefaults.standard.bool(forKey: forceCanaryKey)
    }

    private static func atomicWrite(_ data: Data, to url: URL) throws {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp")
        if FileManager.default.fileExists(atPath: tmp.path) {
            try FileManager.default.removeItem(at: tmp)
        }
        try data.write(to: tmp)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }
}
