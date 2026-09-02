/// Pure editing state for reconciling an in-memory draft with public config files.
/// Persistence and external-change observation belong to the workspace coordinator.
struct OmacyEditorState {
    private(set) var baseline: OmacyConfigSnapshot
    var draftSettings: OmacySettings
    var draftArt: String
    private(set) var pendingExternal: OmacyConfigSnapshot?
    private(set) var diagnostic: String?

    var isDirty: Bool {
        draftSettings != baseline.settings || draftArt != baseline.art
    }

    init(snapshot: OmacyConfigSnapshot) {
        baseline = OmacyConfigSnapshot(
            settings: snapshot.settings,
            art: snapshot.art,
            diagnostic: nil,
            origin: snapshot.origin
        )
        draftSettings = snapshot.settings
        draftArt = snapshot.art
        pendingExternal = nil
        diagnostic = snapshot.diagnostic
    }

    mutating func observeExternal(_ snapshot: OmacyConfigSnapshot) {
        guard snapshot.diagnostic == nil else {
            diagnostic = snapshot.diagnostic
            return
        }

        diagnostic = nil
        if snapshot == baseline {
            pendingExternal = nil
            return
        }
        if isDirty {
            pendingExternal = snapshot
        } else {
            adopt(snapshot)
        }
    }

    mutating func reload(_ snapshot: OmacyConfigSnapshot) {
        guard snapshot.diagnostic == nil else {
            diagnostic = snapshot.diagnostic
            return
        }
        adopt(snapshot)
    }

    /// Stages a verified readback mismatch, even when it matches the old baseline.
    mutating func stageExternalConflict(_ snapshot: OmacyConfigSnapshot) {
        guard snapshot.diagnostic == nil else {
            diagnostic = snapshot.diagnostic
            return
        }
        pendingExternal = OmacyConfigSnapshot(
            settings: snapshot.settings,
            art: snapshot.art,
            diagnostic: nil,
            origin: snapshot.origin
        )
        diagnostic = nil
    }

    mutating func markSaved(_ normalizedSnapshot: OmacyConfigSnapshot) {
        adopt(normalizedSnapshot)
    }

    mutating func resetDraft(bundledArt: String) {
        draftSettings = OmacySettings()
        draftArt = bundledArt
    }

    /// Discards the draft and adopts the exact external revision staged by observation.
    @discardableResult
    mutating func acceptPendingExternal() -> Bool {
        guard let pendingExternal else { return false }
        adopt(pendingExternal)
        return true
    }

    /// Acknowledges that the caller intends to overwrite the currently staged revision.
    /// Clearing only that revision ensures a later disk change stages a new conflict.
    @discardableResult
    mutating func acknowledgeOverwriteOfPendingRevision() -> OmacyConfigSnapshot? {
        defer { pendingExternal = nil }
        return pendingExternal
    }

    private mutating func adopt(_ snapshot: OmacyConfigSnapshot) {
        let validSnapshot = OmacyConfigSnapshot(
            settings: snapshot.settings,
            art: snapshot.art,
            diagnostic: nil,
            origin: snapshot.origin
        )
        baseline = validSnapshot
        draftSettings = validSnapshot.settings
        draftArt = validSnapshot.art
        pendingExternal = nil
        diagnostic = nil
    }
}
