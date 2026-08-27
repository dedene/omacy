import Foundation
import AppKit

struct OmacySettings: Equatable {
    var effect: String = "random"
    var background: String = "#000000"
    var fontSize: Double = 18
    var asciiMode: String = "braille"
    var threshold: Int = 50
    var invert: Bool = false

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

enum OmacyStore {
    static let appGroup = "group.be.zenjoy.omacy"
    static let forceCanaryKey = "omacy.forceCanary"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    static var settingsURL: URL? { containerURL?.appendingPathComponent("settings.json") }
    static var artURL: URL? { containerURL?.appendingPathComponent("screensaver.txt") }

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
        guard let url = settingsURL, let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return OmacySettings()
        }
        var s = OmacySettings()
        if let effect = obj["effect"] as? String { s.effect = effect }
        if let background = obj["background"] as? String { s.background = background }
        if let fontSize = obj["fontSize"] as? Double { s.fontSize = fontSize }
        if let asciiMode = obj["asciiMode"] as? String { s.asciiMode = asciiMode }
        if let threshold = obj["threshold"] as? Int { s.threshold = threshold }
        if let invert = obj["invert"] as? Bool { s.invert = invert }
        return s
    }

    static func loadArt() -> String {
        if let url = artURL, let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
            return text
        }
        return bundledArt
    }

    static func save(settings: OmacySettings, art: String) throws {
        guard let dir = containerURL else {
            throw NSError(domain: "Omacy", code: 1, userInfo: [NSLocalizedDescriptionKey: "App Group container missing"])
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let payload: [String: Any] = [
            "effect": settings.effect,
            "background": settings.background,
            "fontSize": settings.fontSize,
            "asciiMode": settings.asciiMode,
            "threshold": settings.threshold,
            "invert": settings.invert
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try atomicWrite(data, to: settingsURL!)
        try atomicWrite(Data(art.utf8), to: artURL!)
    }

    static func restoreDefaultArt() throws {
        try save(settings: loadSettings(), art: bundledArt)
    }

    static var forceCanary: Bool {
        UserDefaults.standard.bool(forKey: forceCanaryKey)
    }

    private static func atomicWrite(_ data: Data, to url: URL) throws {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}
