import AppKit
import QuartzCore
private let log = AppexLog.logger("Renderer")
enum OmacyAttachMode {
    case engine
    case canary
}
@MainActor
final class OmacyRenderer: NSObject {
    var onEngineUnavailable: (() -> Void)?
    /// Host preview: recreate the session when the view's cell count changes.
    /// Screensaver keeps mid-effect size until the effect ends.
    var appliesGeometryLive = false
    /// Art-window live canvas: loop this content and skip public-config reloads.
    var pinnedContent: OmacyPinnedContent? {
        get { transitions.desiredPinnedContent }
        set { transitions.desiredPinnedContent = newValue }
    }
    var displayCoordinator: OmacyDisplayCoordinator?
    private var participantID: UUID?
    private var currentCycle: UInt64 = 0
    private var coordinatedSeed: UInt64?
    private var coordinatedEpoch: CFTimeInterval?
    private var coordinatedStep: UInt64 = 0
    private let engineAPI: OmacyEngineSession.API
    private let configurationLoader: () -> OmacyConfigSnapshot
    private(set) var lastStepResult: OmacyStepResult?
    var currentCycleNumber: UInt64 { currentCycle }
    var currentSession: OmacyEngineSession? { session }
    var currentEffect: String { lastSettings.effect }

    private var isCoordinated: Bool {
        displayCoordinator != nil && lastSettings.syncDisplays && pinnedContent == nil && !isPreview
    }

    private func unregisterCoordinator() {
        if let pid = participantID {
            displayCoordinator?.unregisterParticipant(id: pid)
            participantID = nil
        }
        currentCycle = 0
        coordinatedSeed = nil
        coordinatedEpoch = nil
        coordinatedStep = 0
    }

    override init() {
        engineAPI = .live
        configurationLoader = OmacyStore.loadConfiguration
        super.init()
    }

    init(engineAPI: OmacyEngineSession.API) {
        self.engineAPI = engineAPI
        configurationLoader = OmacyStore.loadConfiguration
        super.init()
    }

    init(configurationLoader: @escaping () -> OmacyConfigSnapshot) {
        engineAPI = .live
        self.configurationLoader = configurationLoader
        super.init()
    }

    init(
        engineAPI: OmacyEngineSession.API,
        configurationLoader: @escaping () -> OmacyConfigSnapshot
    ) {
        self.engineAPI = engineAPI
        self.configurationLoader = configurationLoader
        super.init()
    }
    private weak var view: NSView?
    private var session: OmacyEngineSession?
    private let previewDebouncer = OmacyDebouncer(delay: 0.05)
    private let transitions = OmacyTransitionCoordinator()
    private let displayLinkDriver = OmacyDisplayLinkDriver()
    private let metalRenderer = OmacyMetalGridRenderer()
    private var lastTimestamp: CFTimeInterval?
    private var fontSize: CGFloat = OmacyLayout.defaultFontSize
    private var cachedFont: NSFont?
    private var cols: UInt32 = 1
    private var rows: UInt32 = 1
    private var pendingCols: UInt32?
    private var pendingRows: UInt32?
    private var pendingFontSize: CGFloat?
    private var pendingFont: NSFont?
    private var debounce: TimeInterval = 0
    private var isPreview = false
    private var stopped = true
    private var lastSettings = OmacySettings()
    private var lastArt = ""
    var usesEngine: Bool { session != nil }
    @discardableResult
    func attach(to view: NSView, isPreview: Bool) -> OmacyAttachMode {
        stopSessionAndLink()
        metalRenderer.resetPresentation()
        self.view = view
        self.isPreview = isPreview
        view.wantsLayer = true
        loadContent()
        if isCoordinated {
            let pid = participantID ?? displayCoordinator!.registerParticipant()
            participantID = pid
            let plan = displayCoordinator!.initialPlan(for: pid, availableEffects: lastSettings.effects)
            currentCycle = plan.cycle
            coordinatedSeed = plan.seed
            lastSettings.effect = plan.effect
            lastSettings.effects = [plan.effect]
        }
        // Attach prepares a new transaction. Its layout follows the candidate
        // source; the active renderer otherwise follows committed state only.
        fontSize = transitions.resolvedFontSize(
            settings: lastSettings,
            art: lastArt,
            view: view,
            fitsToView: pinnedContent != nil || isPreview
        )
        cachedFont = OmacyFont.makeFont(size: fontSize)
        let font = cachedFont!
        let layout = OmacyLayout.grid(view: view, font: font)
        cols = layout.cols
        rows = layout.rows
        if OmacyStore.forceCanary || !createSession(
            cols: cols,
            rows: rows,
            settings: lastSettings,
            art: lastArt,
            seed: coordinatedSeed
        ) {
            unregisterCoordinator()
            metalRenderer.installPlainLayer(on: view)
            return .canary
        }
        if pinnedContent == nil {
            transitions.commitPublic()
        }
        guard metalRenderer.install(on: view, font: font, cell: layout.cell) else {
            session = nil
            unregisterCoordinator()
            metalRenderer.installPlainLayer(on: view)
            return .canary
        }
        return .engine
    }
    func start() {
        guard let view, session != nil else { return }
        stopped = false
        displayLinkDriver.start(
            for: view,
            limitsFrameRate: isPreview || pinnedContent != nil,
            tick: { [weak self] link in self?.tick(link) },
            stop: { [weak self] in self?.stop() }
        )
    }
    /// Recreate the display link for a screen with another refresh rate.
    func retargetDisplayLink() {
        guard let view else { return }
        displayLinkDriver.retarget(for: view, limitsFrameRate: isPreview || pinnedContent != nil)
    }
    func stop() {
        stopped = true
        stopSessionAndLink()
        metalRenderer.stop()
        cachedFont = nil
    }
    deinit {
        if session != nil {
            assertionFailure("OmacyRenderer.deinit with live session")
        }
    }
    func updateGeometry() {
        guard let view, view.bounds.width > 1, view.bounds.height > 1 else { return }
        let fitted = resolvedFontSize()
        let activeFont = cachedFont ?? OmacyFont.makeFont(size: fontSize)
        cachedFont = activeFont
        let changesFont = abs(fitted - fontSize) > 0.5
        let candidateFont = changesFont ? OmacyFont.makeFont(size: fitted) : activeFont
        let layout = OmacyLayout.grid(view: view, font: candidateFont)
        let backing = view.convertToBacking(view.bounds.size)
        let scale = OmacyLayout.backingScale(for: view)
        let viewport = OmacyLayout.viewportSize(viewSize: view.bounds.size, backing: backing, scale: scale)
        switch OmacyGeometryIntent.resolve(
            committedCols: cols, committedRows: rows,
            candidateCols: layout.cols, candidateRows: layout.rows,
            changesFont: changesFont
        ) {
        case .stage:
            pendingCols = layout.cols
            pendingRows = layout.rows
            pendingFontSize = changesFont ? fitted : nil
            pendingFont = changesFont ? candidateFont : nil
            debounce = CACurrentMediaTime()
            metalRenderer.markNeedsRepack()
            applyUnpresentedGeometry()
        case .clear:
            pendingCols = nil
            pendingRows = nil
            pendingFontSize = nil
            pendingFont = nil
            debounce = 0
        }
        let activeCell = OmacyLayout.cellSize(font: activeFont)
        metalRenderer.updateGeometry(view: view, font: activeFont, cell: activeCell, viewport: viewport)
    }
    func pin(_ content: OmacyPinnedContent) {
        if transitions.suppressesPinnedRequest(content) { return }
        pinnedContent = content
        previewDebouncer.schedule { [weak self] in self?.replacePinnedPreview(with: content) }
    }
    private func tick(_ link: CADisplayLink) {
        tick(timestamp: link.timestamp)
    }

    func tick(timestamp: CFTimeInterval) {
        guard !stopped else { return }
        guard let session else { return }
        let now = timestamp
        var synchronizedElapsed: Double?

        if isCoordinated {
            if let coordinator = displayCoordinator, currentCycle < coordinator.currentCycle {
                applyWaitingWork(force: true)
                return
            }
            guard let epoch = displayCoordinator?.startEpoch(for: currentCycle), now >= epoch else {
                if !metalRenderer.hasPresented {
                    if case .frame(let initialResult) = session.step(elapsed: 0.0) {
                        lastStepResult = initialResult
                        if let cells = initialResult.frame.cells, let view {
                            let font = cachedFont ?? OmacyFont.makeFont(size: fontSize)
                            cachedFont = font
                            metalRenderer.present(frame: initialResult.frame, cells: cells, view: view, font: font)
                        }
                    }
                }
                return
            }
            synchronizedElapsed = coordinatedElapsed(timestamp: now, epoch: epoch)
        }

        let elapsed: Double
        if let synchronizedElapsed {
            elapsed = synchronizedElapsed
        } else if let lastTimestamp {
            elapsed = now - lastTimestamp
        } else {
            elapsed = 1.0 / 60.0
        }
        lastTimestamp = now
        let result: OmacyStepResult
        switch session.step(elapsed: elapsed) {
        case .frame(let next):
            transitions.healthyStep()
            if synchronizedElapsed != nil {
                coordinatedStep += UInt64(next.steps_taken)
            }
            result = next
        case .failure(.recoverable):
            if transitions.recoveringUntilHealthyStep {
                failToCanary()
                return
            }
            recoverDeadSession()
            return
        case .failure(.programmingFault(let message)):
            log.fault("engine programming fault; retry disabled: \(message, privacy: .public)")
            failToCanary()
            return
        case .failure(.rejected(let message)):
            log.error("engine step rejected: \(message, privacy: .public)")
            return
        }
        lastStepResult = result
        guard let cells = result.frame.cells else { return }
        let mustPack = metalRenderer.needsRepack || result.steps_taken != 0
        let font = cachedFont ?? OmacyFont.makeFont(size: fontSize)
        cachedFont = font
        if let view {
            metalRenderer.present(frame: result.frame, cells: mustPack ? cells : nil, view: view, font: font)
        }
        applyWaitingWork(result)
        applyLiveGeometryIfNeeded()
    }

    private func coordinatedElapsed(timestamp: CFTimeInterval, epoch: CFTimeInterval) -> Double {
        if coordinatedEpoch != epoch {
            coordinatedEpoch = epoch
            coordinatedStep = 0
        }
        let elapsedSinceEpoch = max(0, timestamp - epoch)
        let targetStepValue = floor(elapsedSinceEpoch * 60.0 + 1e-9)
        let targetStep = UInt64(min(targetStepValue, Double(UInt64.max)))
        guard targetStep > coordinatedStep else { return 0 }
        let steps = targetStep - coordinatedStep
        return Double(steps) * (1.0 / 60.0)
    }
    /// ScreenSaverEngine sizes every saver window to the main display first,
    /// then migrates it. If that resize lands before the first present, apply
    /// it now so the first effect is not locked to `NSScreen.main`.
    private func applyUnpresentedGeometry() {
        guard !metalRenderer.hasPresented else { return }
        guard let pc = pendingCols, let pr = pendingRows else { return }
        pendingCols = nil
        pendingRows = nil
        debounce = 0
        guard pc != cols || pr != rows || pendingFont != nil else { return }
        if createSession(
            cols: pc,
            rows: pr,
            settings: lastSettings,
            art: lastArt,
            identity: transitions.replacementIdentity(settings: lastSettings, art: lastArt, cols: pc, rows: pr, seed: coordinatedSeed),
            seed: coordinatedSeed
        ) {
            cols = pc
            rows = pr
            promotePendingFont()
            metalRenderer.markNeedsRepack()
        }
    }
    private func applyLiveGeometryIfNeeded() {
        guard appliesGeometryLive else { return }
        guard CACurrentMediaTime() - debounce >= 0.05,
              let pc = pendingCols, let pr = pendingRows else { return }
        pendingCols = nil
        pendingRows = nil
        guard pc != cols || pr != rows || pendingFont != nil else { return }
        if createSession(
            cols: pc,
            rows: pr,
            settings: lastSettings,
            art: lastArt,
            identity: transitions.replacementIdentity(settings: lastSettings, art: lastArt, cols: pc, rows: pr, seed: coordinatedSeed),
            seed: coordinatedSeed
        ) {
            cols = pc
            rows = pr
            promotePendingFont()
            metalRenderer.markNeedsRepack()
        }
    }
    private func applyWaitingWork(_ result: OmacyStepResult? = nil, force: Bool = false) {
        guard let session else { return }
        if force || result?.needs_begin_next != 0 {
            let current = OmacyConfigSnapshot(settings: lastSettings, art: lastArt, diagnostic: nil)
            let boundary = transitions.boundaryConfiguration(
                current: current,
                load: configurationLoader
            )
            var candidateSettings = boundary.settings
            let candidateArt = boundary.art

            let sessionWasCoordinated = coordinatedSeed != nil
            let wantsCoordination = displayCoordinator != nil
                && candidateSettings.syncDisplays && pinnedContent == nil && !isPreview
            var nextCycle: UInt64 = wantsCoordination ? currentCycle : 0
            var nextSeed: UInt64?
            if wantsCoordination {
                let pid = participantID ?? displayCoordinator!.registerParticipant()
                participantID = pid
                let decision = displayCoordinator!.evaluateBoundary(
                    for: pid,
                    cycle: currentCycle,
                    availableEffects: candidateSettings.effects
                )
                switch decision {
                case .wait:
                    return
                case .proceed(let plan):
                    nextCycle = plan.cycle
                    nextSeed = plan.seed
                    candidateSettings.effect = plan.effect
                    candidateSettings.effects = [plan.effect]
                }
            }
            let canAdvanceSeedInPlace = session.configuration.seed.map { $0 &+ 1 } == nextSeed
            let requiresSeedRealignment = wantsCoordination && !canAdvanceSeedInPlace
            let requiresSessionReplacement = sessionWasCoordinated != wantsCoordination
                || requiresSeedRealignment

            let candidateFontSize = transitions.resolvedFontSize(
                settings: candidateSettings,
                art: candidateArt,
                view: view,
                fitsToView: transitions.candidateUsesPinnedLayout(isPreview: isPreview)
            )
            let candidateFont = OmacyFont.makeFont(size: candidateFontSize)
            let candidateLayout = view.map { OmacyLayout.grid(view: $0, font: candidateFont) }
            let nextCols = candidateLayout?.cols ?? pendingCols ?? cols
            let nextRows = candidateLayout?.rows ?? pendingRows ?? rows
            let plan = transitions.boundaryPlan(
                settings: candidateSettings, art: candidateArt, cols: nextCols, rows: nextRows, seed: nextSeed
            )
            let commit: (OmacyBoundaryPlan) -> Void = { [weak self] accepted in
                guard let self else { return }
                if wantsCoordination {
                    self.currentCycle = nextCycle
                    self.coordinatedSeed = nextSeed
                    if let pid = self.participantID {
                        self.displayCoordinator?.commitAdvancement(for: pid, cycle: nextCycle)
                    }
                } else {
                    self.unregisterCoordinator()
                }
                self.promoteCommittedConfiguration(
                    settings: accepted.settings, art: accepted.art,
                    cols: accepted.cols, rows: accepted.rows,
                    fontSize: candidateFontSize, font: candidateFont
                )
            }
            if requiresSessionReplacement || plan.configuration.background != session.configuration.background {
                transitions.performBoundary(
                    plan,
                    transition: { [weak self] candidate in
                        self?.createSession(
                            cols: candidate.cols, rows: candidate.rows,
                            settings: candidate.settings, art: candidate.art,
                            identity: candidate.identity,
                            seed: nextSeed
                        ) ?? false
                    },
                    commit: commit
                )
                return
            }
            transitions.performBoundary(
                plan,
                transition: { [weak self] candidate in
                    guard let self, let session = self.session else { return false }
                    switch session.beginNext(
                        configuration: candidate.configuration,
                        cols: candidate.cols, rows: candidate.rows,
                        fileIdentity: candidate.identity
                    ) {
                    case .committed: return true
                    case .ignoredUntilIdentityChanges:
                        self.failRejectedCoordinatedTransition()
                        return false
                    case .failed(.rejected):
                        self.failRejectedCoordinatedTransition()
                        return false
                    case .failed(.recoverable): self.recoverDeadSession(); return false
                    case .failed(.programmingFault(let message)):
                        log.fault("engine programming fault; retry disabled: \(message, privacy: .public)")
                        self.failToCanary()
                        return false
                    }
                },
                commit: commit
            )
        }
    }

    @discardableResult
    private func createSession(
        cols: UInt32,
        rows: UInt32,
        settings: OmacySettings,
        art: String,
        identity: String? = nil,
        seed: UInt64? = nil
    ) -> Bool {
        guard transitions.shouldAttemptReplacement(identity: identity) else { return false }
        let preparation: OmacyEnginePreparation
        if let session {
            preparation = session.replacement(
                configuration: transitions.engineConfiguration(settings: settings, art: art, seed: seed),
                cols: cols,
                rows: rows
            )
        } else {
            preparation = OmacyEngineSession.prepare(
                configuration: transitions.engineConfiguration(settings: settings, art: art, seed: seed),
                cols: cols,
                rows: rows,
                api: engineAPI,
                report: { message in log.error("\(message, privacy: .public)") }
            )
        }
        switch preparation {
        case .ready(let replacement):
            transitions.replacementPrepared()
            session = replacement
            return true
        case .failed(.rejected(let message)):
            if let identity {
                transitions.replacementRejected(identity: identity)
            }
            log.error("session replacement rejected: \(message, privacy: .public)")
            if identity != nil {
                failRejectedCoordinatedTransition()
            }
            return false
        case .failed(.recoverable(let message)):
            log.error("session replacement recoverable failure: \(message, privacy: .public)")
            if transitions.recoveringUntilHealthyStep {
                failToCanary()
            } else if session != nil {
                recoverDeadSession()
            } else {
                failToCanary()
            }
            return false
        case .failed(.programmingFault(let message)):
            log.fault("engine programming fault; retry disabled: \(message, privacy: .public)")
            failToCanary()
            return false
        }
    }

    private func failRejectedCoordinatedTransition() {
        guard participantID != nil else { return }
        failToCanary()
    }

    private func recoverDeadSession() {
        guard let current = session else { return failToCanary() }
        switch current.replacement(
            configuration: current.configuration,
            cols: current.cols,
            rows: current.rows
        ) {
        case .ready(let replacement):
            session = replacement
            coordinatedEpoch = nil
            coordinatedStep = 0
            transitions.beginRecovery()
            metalRenderer.markNeedsRepack()
        case .failed(.recoverable(let message)):
            log.error("engine recovery failed: \(message, privacy: .public)")
            failToCanary()
        case .failed(.programmingFault(let message)):
            log.fault("engine recovery programming fault: \(message, privacy: .public)")
            failToCanary()
        case .failed(.rejected(let message)):
            log.error("engine recovery rejected last-good configuration: \(message, privacy: .public)")
            failToCanary()
        }
    }

    private func failToCanary() {
        stopSessionAndLink()
        stopped = true
        metalRenderer.stop()
        if let view {
            metalRenderer.installPlainLayer(on: view)
        }
        onEngineUnavailable?()
    }

    private func stopSessionAndLink() {
        previewDebouncer.cancel()
        transitions.stopRecovery()
        session = nil
        displayLinkDriver.stop()
        lastTimestamp = nil
        unregisterCoordinator()
    }

    private func resolvedFontSize() -> CGFloat {
        transitions.resolvedFontSize(
            settings: lastSettings,
            art: lastArt,
            view: view,
            fitsToView: transitions.usesPinnedLayout || isPreview
        )
    }

    private func promotePendingFont() {
        if let pendingFontSize, let pendingFont {
            fontSize = pendingFontSize
            cachedFont = pendingFont
        }
        self.pendingFontSize = nil
        self.pendingFont = nil
    }

    private func loadContent() {
        if let pinned = pinnedContent {
            lastArt = pinned.art
            lastSettings.effect = pinned.effect
            lastSettings.effects = [pinned.effect]
            lastSettings.background = pinned.background
            lastSettings.fontSize = pinned.fontSize
            transitions.commitPinned(pinned)
        } else {
            let snapshot = configurationLoader()
            lastSettings = snapshot.settings
            lastArt = snapshot.art
            if let diagnostic = snapshot.diagnostic {
                log.error("configuration fallback: \(diagnostic, privacy: .public)")
            }
        }
    }

    private func replacePinnedPreview(with content: OmacyPinnedContent) {
        guard pinnedContent == content, let view else { return }
        var candidateSettings = lastSettings
        candidateSettings.effect = content.effect
        candidateSettings.effects = [content.effect]
        candidateSettings.background = content.background
        candidateSettings.fontSize = content.fontSize
        let candidateFontSize = OmacyLayout.fittingFontSize(
            art: content.art,
            in: view.bounds.size,
            cap: CGFloat(content.fontSize)
        )
        let candidateFont = OmacyFont.makeFont(size: candidateFontSize)
        let candidateLayout = OmacyLayout.grid(view: view, font: candidateFont)
        let identity = "preview:\(transitions.semanticIdentity(settings: candidateSettings, art: content.art)):\(candidateLayout.cols)x\(candidateLayout.rows)"
        guard createSession(
            cols: candidateLayout.cols,
            rows: candidateLayout.rows,
            settings: candidateSettings,
            art: content.art,
            identity: identity
        ) else {
            if shouldRetryPinnedReplacement(content: content, identity: identity) {
                previewDebouncer.schedule { [weak self] in self?.replacePinnedPreview(with: content) }
            }
            return
        }

        // Commit every Swift mirror only after the replacement Rust session exists.
        lastSettings = candidateSettings
        lastArt = content.art
        transitions.commitPinned(content)
        fontSize = candidateFontSize
        cachedFont = candidateFont
        cols = candidateLayout.cols
        rows = candidateLayout.rows
        pendingCols = nil
        pendingRows = nil
        pendingFontSize = nil
        pendingFont = nil
        metalRenderer.markNeedsRepack()
        updateGeometry()
    }

    private func shouldRetryPinnedReplacement(content: OmacyPinnedContent, identity: String) -> Bool {
        transitions.shouldRetryPinnedReplacement(
            content: content,
            identity: identity,
            canRun: session != nil && !stopped
        )
    }

    private func promoteCommittedConfiguration(
        settings: OmacySettings,
        art: String,
        cols: UInt32,
        rows: UInt32,
        fontSize: CGFloat,
        font: NSFont
    ) {
        lastSettings = settings
        lastArt = art
        if pinnedContent == nil {
            transitions.commitPublic()
        }
        self.cols = cols
        self.rows = rows
        pendingCols = nil
        pendingRows = nil
        pendingFontSize = nil
        pendingFont = nil
        self.fontSize = fontSize
        cachedFont = font
        metalRenderer.markNeedsRepack()
        updateGeometry()
    }
}
