struct OmacyPinnedContent: Equatable {
    var art: String
    var effect: String
    var background: String
    var fontSize: Double
}

struct OmacyReplacementRejectionLatch {
    private(set) var rejectedIdentity: String?

    func shouldAttempt(_ identity: String?) -> Bool {
        guard let identity else { return true }
        return rejectedIdentity != identity
    }

    mutating func reject(_ identity: String?) { rejectedIdentity = identity }
    mutating func clear() { rejectedIdentity = nil }
    func rejects(_ identity: String) -> Bool { rejectedIdentity == identity }

    static func identity(semanticConfiguration: String, cols: UInt32, rows: UInt32) -> String {
        "\(semanticConfiguration):\(cols)x\(rows)"
    }
}

enum OmacyGeometryIntent: Equatable {
    case stage
    case clear

    static func resolve(
        committedCols: UInt32, committedRows: UInt32,
        candidateCols: UInt32, candidateRows: UInt32,
        changesFont: Bool
    ) -> Self {
        candidateCols != committedCols || candidateRows != committedRows || changesFont ? .stage : .clear
    }
}

struct OmacyBoundaryPlan {
    let settings: OmacySettings
    let art: String
    let configuration: OmacyEngineConfiguration
    let cols: UInt32
    let rows: UInt32
    let identity: String
}

/// Owns transition identity, recovery, and desired-versus-committed policy.
final class OmacyTransitionCoordinator {
    private var pinned = OmacyPinnedPreviewState()
    private var rejection = OmacyReplacementRejectionLatch()
    private(set) var recoveringUntilHealthyStep = false

    var desiredPinnedContent: OmacyPinnedContent? {
        get { pinned.desired }
        set { pinned.desired = newValue }
    }
    var usesPinnedLayout: Bool { pinned.usesPinnedLayout }
    func candidateUsesPinnedLayout(isPreview: Bool) -> Bool { pinned.candidateUsesPinnedLayout(isPreview: isPreview) }
    func suppressesPinnedRequest(_ content: OmacyPinnedContent) -> Bool { pinned.suppressesRequest(content) }
    func shouldAttemptReplacement(identity: String?) -> Bool { rejection.shouldAttempt(identity) }
    func replacementRejected(identity: String?) { rejection.reject(identity) }
    func replacementPrepared() { rejection.clear(); recoveringUntilHealthyStep = false }
    func healthyStep() { recoveringUntilHealthyStep = false }
    func beginRecovery() { recoveringUntilHealthyStep = true }
    func stopRecovery() { recoveringUntilHealthyStep = false }
    func commitPinned(_ content: OmacyPinnedContent) { pinned.commitPinned(content) }
    func commitPublic() { pinned.commitPublic() }

    func shouldRetryPinnedReplacement(content: OmacyPinnedContent, identity: String, canRun: Bool) -> Bool {
        pinned.shouldRetry(content: content, rejectedIdentityMatches: rejection.rejects(identity), canRun: canRun)
    }

    func engineConfiguration(settings: OmacySettings, art: String, seed: UInt64? = nil) -> OmacyEngineConfiguration {
        OmacyEngineConfiguration(
            art: art, initialEffect: settings.engineEffect,
            effects: OmacyEffects.sanitize(settings.effects), background: settings.backgroundRGBA,
            seed: seed
        )
    }

    func semanticIdentity(settings: OmacySettings, art: String, seed: UInt64? = nil) -> String {
        var components = [
            settings.effects.joined(separator: "\u{1f}"), settings.background, String(settings.fontSize),
            settings.asciiMode, String(settings.threshold), String(settings.invert), String(settings.syncDisplays), art
        ]
        if let seed {
            components.append(String(seed))
        }
        return components.joined(separator: "\u{1e}")
    }

    func replacementIdentity(settings: OmacySettings, art: String, cols: UInt32, rows: UInt32, seed: UInt64? = nil) -> String {
        OmacyReplacementRejectionLatch.identity(
            semanticConfiguration: semanticIdentity(settings: settings, art: art, seed: seed), cols: cols, rows: rows
        )
    }

    func boundaryConfiguration(current: OmacyConfigSnapshot, load: () -> OmacyConfigSnapshot) -> OmacyConfigSnapshot {
        OmacyBoundaryConfiguration.resolve(isPinned: desiredPinnedContent != nil, current: current, load: load)
    }

    func resolvedFontSize(settings: OmacySettings, art: String, view: NSView?, fitsToView: Bool) -> CGFloat {
        let cap = CGFloat(settings.fontSize)
        guard fitsToView, let view else { return cap }
        return OmacyLayout.fittingFontSize(art: art, in: view.bounds.size, cap: cap)
    }

    func boundaryPlan(settings: OmacySettings, art: String, cols: UInt32, rows: UInt32, seed: UInt64? = nil) -> OmacyBoundaryPlan {
        OmacyBoundaryPlan(
            settings: settings,
            art: art,
            configuration: engineConfiguration(settings: settings, art: art, seed: seed),
            cols: cols,
            rows: rows,
            identity: replacementIdentity(settings: settings, art: art, cols: cols, rows: rows, seed: seed)
        )
    }

    @discardableResult
    func performBoundary(
        _ plan: OmacyBoundaryPlan,
        transition: (OmacyBoundaryPlan) -> Bool,
        commit: (OmacyBoundaryPlan) -> Void
    ) -> Bool {
        guard transition(plan) else { return false }
        commit(plan)
        return true
    }
}
import AppKit
