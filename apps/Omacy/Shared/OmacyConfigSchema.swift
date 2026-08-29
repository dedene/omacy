import Foundation

enum OmacyEffects {
    static var names: [String] { OmacyEffectCatalog.live.names }

    static func sanitize(
        _ names: [String],
        catalog: OmacyEffectCatalog = .live
    ) -> [String] {
        var seen = Set<String>()
        return names.filter { name in
            guard catalog.names.contains(name), !seen.contains(name) else { return false }
            seen.insert(name)
            return true
        }
    }
}

enum OmacyArtSchema {
    // Cross-language invariant: keep these in lockstep with
    // crates/omacy-engine/src/limits.rs and content::validate_art.
    static let maximumUTF8Bytes = 64 * 1024
    static let maximumLines = 128
    static let maximumColumns = 256

    static func validationError(for art: String) -> String? {
        guard !art.isEmpty else { return "ASCII art is empty" }
        guard art.lengthOfBytes(using: .utf8) <= maximumUTF8Bytes else {
            return "ASCII input exceeds 64 KiB"
        }
        guard !art.unicodeScalars.contains(where: { $0.value == 0x1B }) else {
            return "ASCII art must not contain ESC"
        }
        let lines = art.components(separatedBy: "\n")
        guard lines.count <= maximumLines else { return "ASCII line count exceeds 128" }
        guard lines.allSatisfy({ $0.unicodeScalars.count <= maximumColumns }) else {
            return "ASCII column count exceeds 256"
        }
        return nil
    }

    static func isValid(_ art: String) -> Bool { validationError(for: art) == nil }
}

struct OmacySettings: Equatable {
    var effect: String = "random"
    var effects: [String] = OmacyEffects.names
    var background: String = "#000000"
    var fontSize: Double = 18
    var asciiMode: String = "block"
    var threshold: Int = 50
    var invert: Bool = false

    func engineEffect(catalog: OmacyEffectCatalog = .live) -> String {
        let selected = OmacyEffects.sanitize(effects, catalog: catalog)
        return selected.count == 1 ? selected[0] : "random"
    }

    var engineEffect: String { engineEffect() }

    mutating func syncEngineEffect(catalog: OmacyEffectCatalog = .live) {
        let selected = Set(OmacyEffects.sanitize(effects, catalog: catalog))
        effects = catalog.names.filter { selected.contains($0) }
        if effects.isEmpty { effects = catalog.names }
        effect = engineEffect(catalog: catalog)
    }

    var backgroundRGBA: (UInt8, UInt8, UInt8, UInt8) {
        let hex = background.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6, let number = UInt32(hex, radix: 16) else { return (0, 0, 0, 255) }
        return (
            UInt8((number >> 16) & 0xFF), UInt8((number >> 8) & 0xFF),
            UInt8(number & 0xFF), 255
        )
    }

    var asciiModeCode: UInt32 { asciiMode == "block" ? 1 : 0 }
}

enum OmacySettingsCodec {
    static let maximumJSONBytes = 64 * 1024
    static let maximumJSONNestingDepth = 32
    static let maximumFontSize = 256.0

    static func decode(
        _ data: Data,
        lastGood: OmacySettings,
        catalog: OmacyEffectCatalog = .live
    ) -> (settings: OmacySettings, error: String?) {
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return (lastGood, "settings.json is invalid; keeping last-known-good")
            }
            var settings = OmacySettings()
            if let value = object["effect"] as? String { settings.effect = value }
            if let value = object["background"] as? String { settings.background = value }
            if let value = object["fontSize"] as? Double { settings.fontSize = value }
            if let value = object["asciiMode"] as? String { settings.asciiMode = value }
            if let value = object["threshold"] as? Int { settings.threshold = value }
            if let value = object["invert"] as? Bool { settings.invert = value }
            if let effects = object["effects"] as? [String] {
                settings.effects = OmacyEffects.sanitize(effects, catalog: catalog)
            } else if settings.effect == "random" || settings.effect.isEmpty {
                settings.effects = catalog.names
            } else if catalog.names.contains(settings.effect) {
                settings.effects = [settings.effect]
            } else {
                settings.effects = catalog.names
            }
            settings.syncEngineEffect(catalog: catalog)
            return (settings, nil)
        } catch {
            return (lastGood, "Could not read settings.json; keeping last-known-good")
        }
    }

    static func decodeValidated(
        _ data: Data,
        catalog: OmacyEffectCatalog = .live
    ) -> OmacySettings? {
        guard data.count <= maximumJSONBytes,
              hasAcceptableNesting(data),
              let value = try? JSONSerialization.jsonObject(with: data),
              let object = value as? [String: Any], validate(object, catalog: catalog) else { return nil }
        let decoded = decode(data, lastGood: OmacySettings(), catalog: catalog)
        return decoded.error == nil ? decoded.settings : nil
    }

    static func encode(_ settings: OmacySettings) throws -> Data {
        let payload: [String: Any] = [
            "effect": settings.effect, "effects": settings.effects,
            "background": settings.background, "fontSize": settings.fontSize,
            "asciiMode": settings.asciiMode, "threshold": settings.threshold,
            "invert": settings.invert
        ]
        return try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    }

    private static func validate(
        _ object: [String: Any],
        catalog: OmacyEffectCatalog
    ) -> Bool {
        if let value = object["effect"] {
            guard let effect = value as? String,
                  effect == "random" || catalog.names.contains(effect) else { return false }
        }
        if let value = object["effects"] {
            guard let effects = value as? [String], effects.allSatisfy(catalog.names.contains),
                  Set(effects).count == effects.count else { return false }
        }
        if let value = object["background"] {
            guard let color = value as? String,
                  color.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil else { return false }
        }
        if let value = object["fontSize"] {
            guard !(value is Bool), let number = value as? NSNumber,
                  number.doubleValue.isFinite, number.doubleValue > 0,
                  number.doubleValue <= maximumFontSize else { return false }
        }
        if let value = object["asciiMode"] {
            guard let mode = value as? String, mode == "block" || mode == "braille" else { return false }
        }
        if let value = object["threshold"] {
            guard !(value is Bool), let threshold = value as? Int,
                  (0...100).contains(threshold) else { return false }
        }
        if let value = object["invert"], !(value is Bool) { return false }
        return true
    }

    private static func hasAcceptableNesting(_ data: Data) -> Bool {
        var depth = 0
        var isInsideString = false
        var isEscaped = false
        for byte in data {
            if isInsideString {
                if isEscaped {
                    isEscaped = false
                } else if byte == 0x5C {
                    isEscaped = true
                } else if byte == 0x22 {
                    isInsideString = false
                }
                continue
            }
            if byte == 0x22 {
                isInsideString = true
            } else if byte == 0x7B || byte == 0x5B {
                depth += 1
                if depth > maximumJSONNestingDepth { return false }
            } else if byte == 0x7D || byte == 0x5D {
                depth -= 1
                if depth < 0 { return false }
            }
        }
        return !isInsideString && depth == 0
    }
}
