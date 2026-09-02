import Combine
import Foundation

enum OmacyWorkspaceOperationState: Equatable {
    case idle
    case working(String)
    case error(String)
    /// The public config files on disk are unreadable or invalid, so saving is
    /// blocked until the user explicitly replaces them.
    case invalidFiles(String)
    case externalConflict
}

@MainActor
final class OmacyWorkspaceModel: ObservableObject {
    typealias Load = () -> OmacyConfigSnapshot
    typealias Save = (OmacySettings, String) throws -> Void
    typealias Convert = (Data, OmacySettings) throws -> String
    typealias AsyncOperation = () async throws -> Void

    @Published var editor: OmacyEditorState
    @Published var highlightedEffect: String
    @Published private(set) var operationState: OmacyWorkspaceOperationState
    /// Image conversion is draft-only work, so its failures never enter
    /// `operationState` and never mask the state of the files on disk.
    @Published private(set) var conversionError: String?
    @Published private(set) var isBusy = false

    private let load: Load
    private let persist: Save
    private let bundledArt: String
    private let convert: Convert
    private let prepareForTest: AsyncOperation
    private let launch: AsyncOperation
    private var stagedImage: Data?
    private var needsBootstrapSave: Bool

    var isDirty: Bool { editor.isDirty }
    var canReconvert: Bool { stagedImage != nil }
    var isAtDefaults: Bool {
        editor.draftSettings == OmacySettings() && editor.draftArt == bundledArt
    }
    var canReset: Bool { !isAtDefaults }
    /// True while the files on disk are unreadable, whatever the operation state
    /// says. Keeps the recovery action reachable after a failed replacement.
    var hasInvalidFiles: Bool { editor.diagnostic != nil }

    var userStatus: String? {
        switch operationState {
        case .idle: nil
        case .working(let message), .error(let message), .invalidFiles(let message): message
        case .externalConflict: "These files changed outside Omacy."
        }
    }

    init(
        load: @escaping Load,
        save: @escaping Save,
        bundledArt: String,
        convert: @escaping Convert,
        prepareForTest: @escaping AsyncOperation,
        launch: @escaping AsyncOperation
    ) {
        self.load = load
        persist = save
        self.bundledArt = bundledArt
        self.convert = convert
        self.prepareForTest = prepareForTest
        self.launch = launch

        let snapshot = load()
        needsBootstrapSave = snapshot.origin == .bootstrapDefaults
        editor = OmacyEditorState(snapshot: snapshot)
        highlightedEffect = snapshot.settings.effects.first ?? OmacyEffects.names[0]
        operationState = snapshot.diagnostic.map { .invalidFiles($0) } ?? .idle
    }

    @discardableResult
    func save() async -> Bool {
        guard !isBusy else { return false }
        clearRetriableError()
        return await performSave(overwriting: nil)
    }

    @discardableResult
    func overwriteMine() async -> Bool {
        guard !isBusy else { return false }
        clearRetriableError()
        guard let acknowledged = editor.acknowledgeOverwriteOfPendingRevision() else { return false }
        return await performSave(overwriting: acknowledged)
    }

    /// Writes the current draft over invalid public files, at the user's request.
    /// Only valid while the files are diagnosed as invalid; the normal save path
    /// refuses to overwrite them so nothing is clobbered behind the user's back.
    /// Both settings.json and screensaver.txt are replaced, even if only one is bad.
    @discardableResult
    func replaceInvalidFiles() async -> Bool {
        guard !isBusy else { return false }
        guard hasInvalidFiles else { return false }
        isBusy = true
        defer { isBusy = false }

        let disk = load()
        guard disk.diagnostic != nil else {
            // The files healed before the user acted, so nothing is overwritten.
            editor.observeExternal(disk)
            updateStateAfterObservation()
            return false
        }
        editor.observeExternal(disk)
        return writeDraftAndVerify()
    }

    func refreshFromDisk() {
        guard !isBusy else { return }
        reconcileDisk()
    }

    private func reconcileDisk() {
        let snapshot = load()
        needsBootstrapSave = snapshot.origin == .bootstrapDefaults
        editor.observeExternal(snapshot)
        updateStateAfterObservation()
    }

    func reloadExternal() {
        guard editor.acceptPendingExternal() else { return }
        syncHighlight()
        operationState = .idle
    }

    func resetDraft() {
        stagedImage = nil
        conversionError = nil
        editor.resetDraft(bundledArt: bundledArt)
        syncHighlight()
        updateStateAfterObservation()
    }

    func discardDraft() {
        stagedImage = nil
        conversionError = nil
        editor.draftSettings = editor.baseline.settings
        editor.draftArt = editor.baseline.art
        syncHighlight()
        updateStateAfterObservation()
    }

    func importImage(_ data: Data) {
        conversionError = nil
        stagedImage = data
        editor.draftSettings.asciiMode = "block"
        reconvertStagedImage()
    }

    func reconvertStagedImage() {
        guard let stagedImage else { return }
        do {
            editor.draftArt = try convert(stagedImage, editor.draftSettings)
            conversionError = nil
        } catch {
            conversionError = "The image couldn't be converted."
        }
    }

    func dismissConversionError() { conversionError = nil }

    func testScreenSaver() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        clearRetriableError()
        reconcileDisk()
        switch operationState {
        case .invalidFiles, .externalConflict: return
        default: break
        }
        if (isDirty || needsBootstrapSave),
           !(await performSave(overwriting: nil)) { return }
        operationState = .working("Preparing screen saver…")
        do {
            try await prepareForTest()
        } catch {
            operationState = .error("Omacy couldn't be made ready for testing.")
            return
        }

        operationState = .working("Starting screen saver…")
        do {
            try await launch()
            operationState = .idle
        } catch {
            operationState = .error("macOS couldn't start the screen saver.")
        }
    }

    private func performSave(overwriting acknowledged: OmacyConfigSnapshot?) async -> Bool {
        let disk = load()
        guard disk.diagnostic == nil else {
            editor.observeExternal(disk)
            operationState = .invalidFiles(disk.diagnostic!)
            return false
        }

        if let acknowledged {
            guard disk == acknowledged else {
                editor.observeExternal(disk)
                updateStateAfterObservation()
                return false
            }
        } else {
            editor.observeExternal(disk)
            updateStateAfterObservation()
            guard editor.diagnostic == nil, editor.pendingExternal == nil else { return false }
        }

        return writeDraftAndVerify()
    }

    /// Normalizes and writes the draft, then verifies the readback.
    /// Shared by the diagnostic-guarded save path and the explicit file replacement.
    private func writeDraftAndVerify() -> Bool {
        var normalizedSettings = editor.draftSettings
        normalizedSettings.syncEngineEffect()
        let intended = OmacyConfigSnapshot(
            settings: normalizedSettings, art: editor.draftArt, diagnostic: nil
        )
        do {
            try persist(normalizedSettings, editor.draftArt)
        } catch {
            operationState = .error("Your changes weren't saved.")
            return false
        }

        let reloaded = load()
        guard reloaded.diagnostic == nil else {
            editor.observeExternal(reloaded)
            operationState = .invalidFiles(reloaded.diagnostic!)
            return false
        }
        guard reloaded == intended else {
            editor.stageExternalConflict(reloaded)
            operationState = .externalConflict
            return false
        }
        editor.markSaved(reloaded)
        needsBootstrapSave = false
        syncHighlight()
        operationState = .idle
        return true
    }

    private func updateStateAfterObservation() {
        if let diagnostic = editor.diagnostic {
            operationState = .invalidFiles(diagnostic)
        } else if editor.pendingExternal != nil {
            operationState = .externalConflict
        } else {
            syncHighlight()
            // A failed save or launch stays visible until the user retries it.
            if case .error = operationState { return }
            operationState = .idle
        }
    }

    /// Explicit retries start from a clean slate; ambient reloads do not.
    private func clearRetriableError() {
        if case .error = operationState { operationState = .idle }
    }

    private func syncHighlight() {
        if !OmacyEffects.names.contains(highlightedEffect) {
            highlightedEffect = editor.draftSettings.effects.first ?? OmacyEffects.names[0]
        }
    }
}
