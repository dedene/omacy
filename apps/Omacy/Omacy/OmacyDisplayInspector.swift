import AppKit
import Foundation
import PaperSaverKit

enum OmacyDisplayInspector {
    static func displayUUID(for screen: NSScreen) -> String? {
        guard let screenDisplayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let cfUuid = CGDisplayCreateUUIDFromDisplayID(screenDisplayID) else {
            return nil
        }
        return (CFUUIDCreateString(nil, cfUuid.takeRetainedValue()) as String)
    }

    static func decodeScreensaverName(from choiceDict: [String: Any]) -> String? {
        guard let content = choiceDict["Content"] as? [String: Any],
              let choices = content["Choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let data = firstChoice["Configuration"] as? Data,
              !data.isEmpty,
              let (name, _) = try? PlistManager.shared.decodeScreensaverConfigurationWithType(from: data) else {
            return nil
        }
        return name
    }

    static func extractScreensaverName(from config: [String: Any]) -> String? {
        if let idle = config["Idle"] as? [String: Any],
           let name = decodeScreensaverName(from: idle) {
            return name
        }
        if let def = config["Default"] as? [String: Any],
           let idle = def["Idle"] as? [String: Any],
           let name = decodeScreensaverName(from: idle) {
            return name
        }
        return nil
    }

    static func screensaverName(
        forDisplayUUID displayUUID: String?,
        wallpaperPlist: [String: Any]?,
        spaceTree: [String: Any]?
    ) -> String? {
        guard let plist = wallpaperPlist else { return nil }

        // Priority 1: AllSpacesAndDisplays applies to all screens and spaces
        if let allSpaces = plist["AllSpacesAndDisplays"] as? [String: Any],
           let name = extractScreensaverName(from: allSpaces) {
            return name
        }

        // Priority 2: Look up current space for this monitor in the space tree
        if let displayUUID = displayUUID {
            if let tree = spaceTree,
               let monitors = tree["monitors"] as? [[String: Any]],
               let monitor = monitors.first(where: { ($0["uuid"] as? String) == displayUUID }),
               let spaces = monitor["spaces"] as? [[String: Any]],
               let currentSpace = spaces.first(where: { ($0["is_current"] as? Bool) == true }),
               let spaceUUID = currentSpace["uuid"] as? String,
               let spacesDict = plist["Spaces"] as? [String: Any],
               let spaceConfig = (spacesDict[spaceUUID] as? [String: Any]) ?? (spacesDict[""] as? [String: Any]),
               let name = extractScreensaverName(from: spaceConfig) {
                return name
            }

            // Priority 3: Displays[displayUUID]
            if let displaysDict = plist["Displays"] as? [String: Any],
               let displayConfig = displaysDict[displayUUID] as? [String: Any],
               let name = extractScreensaverName(from: displayConfig) {
                return name
            }
        }

        // Priority 4: SystemDefault
        if let sysDef = plist["SystemDefault"] as? [String: Any],
           let name = extractScreensaverName(from: sysDef) {
            return name
        }

        return nil
    }

    static func activeScreensaverName(
        for screen: NSScreen,
        paperSaver: PaperSaver,
        wallpaperPlist: [String: Any]?,
        spaceTree: [String: Any]?,
        displayUUIDResolver: (NSScreen) -> String? = { displayUUID(for: $0) }
    ) -> String? {
        // 1. If PaperSaver returns a non-empty name directly, use it.
        if let info = paperSaver.getActiveScreensaver(for: screen), !info.name.isEmpty {
            return OmacyScreensaverIdentity.isOmacy(info.identifier) ? info.identifier : info.name
        }

        // 2. PaperSaver 0.2.0 bug workaround: resolve screen UUID and inspect Index.plist
        let resolvedUUID = displayUUIDResolver(screen)
        let tree = spaceTree ?? paperSaver.getNativeSpaceTree()
        if let name = screensaverName(
            forDisplayUUID: resolvedUUID,
            wallpaperPlist: wallpaperPlist,
            spaceTree: tree
        ) {
            return name
        }

        // 3. Fallback: If global active screensavers contains only Omacy, return it
        let active = paperSaver.getActiveScreensavers()
        if !active.isEmpty, active.allSatisfy(OmacyScreensaverIdentity.isOmacy) {
            return active.first
        }

        // 4. Fallback: If getActiveScreensaver(nil) returns a value
        if let fallback = paperSaver.getActiveScreensaver(for: nil), !fallback.name.isEmpty {
            return OmacyScreensaverIdentity.isOmacy(fallback.identifier) ? fallback.identifier : fallback.name
        }

        return nil
    }

    static func inspectCurrentDisplayStatus(
        screens: [NSScreen],
        paperSaver: PaperSaver,
        wallpaperPlist: [String: Any]? = try? PlistManager.shared.read(at: SystemPaths.wallpaperIndexPath),
        spaceTree: [String: Any]? = nil,
        displayUUIDResolver: (NSScreen) -> String? = { displayUUID(for: $0) }
    ) -> OmacyCurrentDisplayStatus {
        guard !screens.isEmpty else { return .inactive(displayCount: 0) }

        let tree = spaceTree ?? paperSaver.getNativeSpaceTree()

        let names = screens.map { screen in
            activeScreensaverName(
                for: screen,
                paperSaver: paperSaver,
                wallpaperPlist: wallpaperPlist,
                spaceTree: tree,
                displayUUIDResolver: displayUUIDResolver
            ) ?? ""
        }
        return .classify(names)
    }

    static func inspectDisplayStatus(
        displayUUIDs: [String],
        wallpaperPlist: [String: Any]?,
        spaceTree: [String: Any]?
    ) -> OmacyCurrentDisplayStatus {
        guard !displayUUIDs.isEmpty else { return .inactive(displayCount: 0) }
        let names = displayUUIDs.map { uuid in
            screensaverName(
                forDisplayUUID: uuid,
                wallpaperPlist: wallpaperPlist,
                spaceTree: spaceTree
            ) ?? ""
        }
        return .classify(names)
    }
}
