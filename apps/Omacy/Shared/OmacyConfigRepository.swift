import Foundation
import Darwin

enum OmacyBoundedFileReader {
    static func readRegularFile(at url: URL, maximumBytes: Int) -> Data? {
        let descriptor = url.path.withCString {
            open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0,
              UInt64(info.st_size) <= UInt64(maximumBytes) else { return nil }
        do {
            guard let data = try handle.read(upToCount: maximumBytes + 1),
                  data.count <= maximumBytes else { return nil }
            return data
        } catch {
            return nil
        }
    }
}

enum OmacyLoginHomeDirectory {
    static func current() -> URL {
        guard let passwordRecord = getpwuid(getuid()),
              let homePath = passwordRecord.pointee.pw_dir else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return URL(fileURLWithPath: String(cString: homePath), isDirectory: true)
    }
}

struct OmacyConfigPaths {
    let configDirectory: URL
    let cacheDirectory: URL
    let migrationMarkerURL: URL

    var settingsURL: URL { configDirectory.appendingPathComponent("settings.json") }
    var artURL: URL { configDirectory.appendingPathComponent("screensaver.txt") }
    var cachedSettingsURL: URL { cacheDirectory.appendingPathComponent("settings.json") }
    var cachedArtURL: URL { cacheDirectory.appendingPathComponent("screensaver.txt") }

    static func live(
        fileManager: FileManager = .default,
        loginHomeDirectory: () -> URL = OmacyLoginHomeDirectory.current
    ) -> Self {
        let home = loginHomeDirectory()
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return Self(
            configDirectory: home.appendingPathComponent(".config/omacy", isDirectory: true),
            cacheDirectory: support.appendingPathComponent("Omacy/LastGoodConfig", isDirectory: true),
            migrationMarkerURL: support.appendingPathComponent("Omacy/migration-v1-attempted")
        )
    }
}

struct OmacyConfigSnapshot: Equatable {
    let settings: OmacySettings
    let art: String
    let diagnostic: String?
}

enum OmacyBoundaryConfiguration {
    /// Unpinned sessions reread public files exactly at an effect boundary.
    /// Host notifications are not required; external writers are observed here.
    static func resolve(
        isPinned: Bool,
        current: OmacyConfigSnapshot,
        load: () -> OmacyConfigSnapshot
    ) -> OmacyConfigSnapshot {
        guard !isPinned else { return current }
        return load()
    }
}

struct OmacyLegacyConfiguration {
    let settingsData: Data?
    let art: String?
}

enum OmacyMigrationResult: Equatable {
    case canonicalAlreadyValid, alreadyAttempted, migrated, noLegacyConfiguration
}

enum OmacyConfigWriteError: LocalizedError {
    case settings(Error)
    case art(Error)

    var errorDescription: String? {
        switch self {
        case .settings(let error):
            return "Could not write settings.json: \(error.localizedDescription)"
        case .art(let error):
            return "Settings were saved, but screensaver.txt could not be written: \(error.localizedDescription)"
        }
    }
}

final class OmacyConfigRepository {
    let paths: OmacyConfigPaths
    private let fileManager: FileManager
    private let bundledArtProvider: () -> String
    private let atomicWriteOverride: ((Data, URL) throws -> Void)?
    private var lastGoodSettings: OmacySettings?
    private var lastGoodArt: String?

    init(
        paths: OmacyConfigPaths,
        fileManager: FileManager = .default,
        bundledArt: @escaping () -> String,
        atomicWrite: ((Data, URL) throws -> Void)? = nil
    ) {
        self.paths = paths
        self.fileManager = fileManager
        bundledArtProvider = bundledArt
        atomicWriteOverride = atomicWrite
    }

    func load() -> OmacyConfigSnapshot {
        let publicSettings = readSettings(at: paths.settingsURL)
        let publicArt = readArt(at: paths.artURL)
        if let publicSettings { lastGoodSettings = publicSettings }
        if let publicArt { lastGoodArt = publicArt }
        if publicSettings != nil || publicArt != nil {
            cacheValidPublic(settings: publicSettings, art: publicArt)
        }

        let memorySettings = publicSettings ?? lastGoodSettings
        let memoryArt = publicArt ?? lastGoodArt
        if let memorySettings, let memoryArt {
            let diagnostic: String?
            if publicSettings == nil {
                diagnostic = "settings.json is invalid; using last-known-good settings"
            } else if publicArt == nil {
                diagnostic = "screensaver.txt is empty or unreadable; using last-known-good art"
            } else {
                diagnostic = nil
            }
            return .init(settings: memorySettings, art: memoryArt, diagnostic: diagnostic)
        }

        let cachedSettings = readSettings(at: paths.cachedSettingsURL)
        let cachedArt = readArt(at: paths.cachedArtURL)
        let cacheFillsMissingValue = (memorySettings == nil && cachedSettings != nil)
            || (memoryArt == nil && cachedArt != nil)
        if cacheFillsMissingValue {
            let settings = memorySettings ?? cachedSettings ?? OmacySettings()
            let art = memoryArt ?? cachedArt ?? bundledArtProvider()
            lastGoodSettings = settings
            lastGoodArt = art
            return .init(
                settings: settings, art: art,
                diagnostic: "Public configuration is invalid; using private last-known-good cache"
            )
        }

        let diagnostic: String
        if memorySettings != nil {
            diagnostic = "screensaver.txt is empty or unreadable; using bundled art"
        } else if memoryArt != nil {
            diagnostic = "settings.json is invalid; using bundled settings"
        } else {
            diagnostic = "No valid public or cached configuration; using bundled defaults"
        }
        return .init(
            settings: memorySettings ?? OmacySettings(),
            art: memoryArt ?? bundledArtProvider(), diagnostic: diagnostic
        )
    }

    func save(settings: OmacySettings, art: String) throws {
        var normalized = settings
        normalized.syncEngineEffect()
        if let validationError = OmacyArtSchema.validationError(for: art) {
            throw OmacyConfigWriteError.art(NSError(
                domain: "Omacy", code: 2,
                userInfo: [NSLocalizedDescriptionKey: validationError]
            ))
        }
        let settingsData = try OmacySettingsCodec.encode(normalized)
        try fileManager.createDirectory(at: paths.configDirectory, withIntermediateDirectories: true)
        do {
            try atomicWrite(settingsData, to: paths.settingsURL)
        } catch {
            throw OmacyConfigWriteError.settings(error)
        }
        do {
            try atomicWrite(Data(art.utf8), to: paths.artURL)
        } catch {
            // Canonical files are independently replaceable. The settings write
            // intentionally remains published and the error identifies the failed file.
            throw OmacyConfigWriteError.art(error)
        }
        lastGoodSettings = normalized
        lastGoodArt = art
        cacheValidPublic(settings: normalized, art: art)
    }

    func migrateIfNeeded(
        defaults: () throws -> OmacyLegacyConfiguration?,
        files: () throws -> OmacyLegacyConfiguration?
    ) throws -> OmacyMigrationResult {
        let existingSettings = readSettings(at: paths.settingsURL)
        let existingArt = readArt(at: paths.artURL)
        if existingSettings != nil, existingArt != nil { return .canonicalAlreadyValid }
        if fileManager.fileExists(atPath: paths.migrationMarkerURL.path) { return .alreadyAttempted }
        try fileManager.createDirectory(
            at: paths.migrationMarkerURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try atomicWrite(Data("attempted\n".utf8), to: paths.migrationMarkerURL)

        let defaultValues = try defaults()
        let defaultSettings = defaultValues?.settingsData.flatMap {
            OmacySettingsCodec.decodeValidated($0)
        }
        let defaultArt = defaultValues?.art.flatMap { OmacyArtSchema.isValid($0) ? $0 : nil }
        var fileSettings: OmacySettings?
        var fileArt: String?
        if (existingSettings == nil && defaultSettings == nil)
            || (existingArt == nil && defaultArt == nil) {
            let fileValues = try files()
            fileSettings = fileValues?.settingsData.flatMap {
                OmacySettingsCodec.decodeValidated($0)
            }
            fileArt = fileValues?.art.flatMap { OmacyArtSchema.isValid($0) ? $0 : nil }
        }
        let legacySettings = defaultSettings ?? fileSettings
        let legacyArt = defaultArt ?? fileArt
        guard legacySettings != nil || legacyArt != nil else { return .noLegacyConfiguration }
        try save(
            settings: existingSettings ?? legacySettings ?? OmacySettings(),
            art: existingArt ?? legacyArt ?? bundledArtProvider()
        )
        return .migrated
    }

    func retryMigration() { try? fileManager.removeItem(at: paths.migrationMarkerURL) }

    private func readSettings(at url: URL) -> OmacySettings? {
        guard let data = OmacyBoundedFileReader.readRegularFile(
            at: url, maximumBytes: OmacySettingsCodec.maximumJSONBytes
        ) else { return nil }
        return OmacySettingsCodec.decodeValidated(data)
    }

    private func readArt(at url: URL) -> String? {
        guard let data = OmacyBoundedFileReader.readRegularFile(
            at: url, maximumBytes: OmacyArtSchema.maximumUTF8Bytes
        ),
              let text = String(data: data, encoding: .utf8),
              OmacyArtSchema.isValid(text) else { return nil }
        return text
    }

    private func cacheValidPublic(settings: OmacySettings?, art: String?) {
        guard settings != nil || art != nil else { return }
        try? fileManager.createDirectory(at: paths.cacheDirectory, withIntermediateDirectories: true)
        if let settings, let data = try? OmacySettingsCodec.encode(settings) {
            try? atomicWrite(data, to: paths.cachedSettingsURL)
        }
        if let art { try? atomicWrite(Data(art.utf8), to: paths.cachedArtURL) }
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        if let atomicWriteOverride { try atomicWriteOverride(data, url); return }
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporaryURL, options: .withoutOverwriting)
        do {
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: url)
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }
}
