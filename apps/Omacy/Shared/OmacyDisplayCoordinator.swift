import AppKit
import Foundation
import QuartzCore

private let logger = AppexLog.logger("DisplayCoordinator")

@MainActor
final class OmacyDisplayCoordinator {
    static let shared = OmacyDisplayCoordinator()

    struct CyclePlan: Equatable {
        let cycle: UInt64
        let effect: String
        let seed: UInt64
        let startEpoch: TimeInterval?
    }

    enum BarrierDecision: Equatable {
        case wait
        case proceed(CyclePlan)
    }

    struct Configuration {
        var dwellDuration: TimeInterval
        var maxBarrierWait: TimeInterval
        var startBarrierTimeout: TimeInterval
        var expectedParticipants: (() -> Int)?
        var clock: () -> TimeInterval
        var shuffler: ([String]) -> [String]
        var seedGenerator: () -> UInt64

        init(
            dwellDuration: TimeInterval = 1.5,
            maxBarrierWait: TimeInterval = 10.0,
            startBarrierTimeout: TimeInterval = 0.5,
            expectedParticipants: (() -> Int)? = nil,
            clock: @escaping () -> TimeInterval = { CACurrentMediaTime() },
            shuffler: @escaping ([String]) -> [String] = { $0.shuffled() },
            seedGenerator: @escaping () -> UInt64 = { UInt64.random(in: 0...UInt64.max) }
        ) {
            self.dwellDuration = dwellDuration
            self.maxBarrierWait = maxBarrierWait
            self.startBarrierTimeout = startBarrierTimeout
            self.expectedParticipants = expectedParticipants
            self.clock = clock
            self.shuffler = shuffler
            self.seedGenerator = seedGenerator
        }
    }

    struct ParticipantState: Equatable {
        var cycle: UInt64
        var isFinished: Bool
        var hasCommittedCurrentCycle: Bool
    }

    var configuration: Configuration
    private(set) var participants: [UUID: ParticipantState] = [:]
    private(set) var currentCycle: UInt64 = 0
    private(set) var currentEffect: String?
    private(set) var baseSeed: UInt64 = 0
    private(set) var currentStartEpoch: TimeInterval?
    private(set) var firstRegistrationTime: TimeInterval?
    private(set) var firstFinishedTime: TimeInterval?
    private(set) var barrierSatisfiedTime: TimeInterval?
    private(set) var activeProposal: CyclePlan?
    private(set) var lastEffect: String?
    private var remainingBag: [String] = []
    private var lastPool: [String] = []

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    var activeParticipantCount: Int {
        participants.count
    }

    private func targetParticipantCount() -> Int {
        if let expected = configuration.expectedParticipants {
            return max(1, expected())
        }
        return max(1, NSScreen.screens.count)
    }

    @discardableResult
    func registerParticipant(id: UUID = UUID()) -> UUID {
        let now = configuration.clock()
        if participants.isEmpty {
            currentCycle = 0
            currentEffect = nil
            baseSeed = configuration.seedGenerator()
            currentStartEpoch = nil
            firstRegistrationTime = now
            firstFinishedTime = nil
            barrierSatisfiedTime = nil
            activeProposal = nil
        }
        if let _ = participants[id] {
            return id
        }
        let isFinished = barrierSatisfiedTime != nil
        participants[id] = ParticipantState(cycle: currentCycle, isFinished: isFinished, hasCommittedCurrentCycle: true)
        logger.info("registerParticipant(\(id.uuidString, privacy: .public)) total=\(self.participants.count) cycle=\(self.currentCycle)")
        checkCycle0StartBarrier(now: now)
        return id
    }

    func unregisterParticipant(id: UUID) {
        participants.removeValue(forKey: id)
        logger.info("unregisterParticipant(\(id.uuidString, privacy: .public)) remaining=\(self.participants.count)")
        if participants.isEmpty {
            reset()
        } else {
            if let proposal = activeProposal {
                let allRemainingCommitted = participants.values.allSatisfy { $0.cycle == proposal.cycle && $0.hasCommittedCurrentCycle }
                if allRemainingCommitted {
                    finalizeAdvancement(proposal: proposal)
                    return
                }
            }
            if areAllParticipantsFinished(for: currentCycle) {
                if barrierSatisfiedTime == nil {
                    barrierSatisfiedTime = configuration.clock()
                }
            }
        }
    }

    func startEpoch(for cycle: UInt64) -> TimeInterval? {
        if cycle == currentCycle {
            if currentStartEpoch == nil {
                checkCycle0StartBarrier(now: configuration.clock())
            }
            return currentStartEpoch
        }
        if let proposal = activeProposal, proposal.cycle == cycle {
            return proposal.startEpoch
        }
        return nil
    }

    func initialPlan(for id: UUID, availableEffects: [String]) -> CyclePlan {
        let pool = resolvePool(availableEffects)
        let now = configuration.clock()
        if currentEffect == nil {
            currentEffect = pickNextEffect(from: pool)
        }
        checkCycle0StartBarrier(now: now)
        let isFinished = barrierSatisfiedTime != nil
        participants[id] = ParticipantState(cycle: currentCycle, isFinished: isFinished, hasCommittedCurrentCycle: true)
        let effectName = self.currentEffect ?? "none"
        let cycleSeed = seed(for: currentCycle)
        logger.info("initialPlan chosen=\(effectName, privacy: .public) cycle=\(self.currentCycle) seed=\(cycleSeed)")
        return CyclePlan(
            cycle: currentCycle,
            effect: currentEffect!,
            seed: cycleSeed,
            startEpoch: currentStartEpoch
        )
    }

    func initialEffect(for id: UUID, availableEffects: [String]) -> String {
        initialPlan(for: id, availableEffects: availableEffects).effect
    }

    func seed(for cycle: UInt64) -> UInt64 {
        baseSeed &+ cycle
    }

    func evaluateBoundary(
        for id: UUID,
        cycle: UInt64,
        availableEffects: [String]
    ) -> BarrierDecision {
        let pool = resolvePool(availableEffects)

        if participants[id] == nil {
            registerParticipant(id: id)
        }

        var participantCycle = cycle
        if participantCycle < currentCycle {
            participants[id] = ParticipantState(cycle: currentCycle, isFinished: false, hasCommittedCurrentCycle: true)
            let effect = currentEffect ?? pickNextEffect(from: pool)
            currentEffect = effect
            logger.info("evaluateBoundary: participant \(id.uuidString, privacy: .public) catchup to cycle=\(self.currentCycle) effect=\(effect, privacy: .public)")
            return .proceed(CyclePlan(
                cycle: currentCycle,
                effect: effect,
                seed: seed(for: currentCycle),
                startEpoch: currentStartEpoch
            ))
        }

        if participantCycle > currentCycle {
            logger.warning("evaluateBoundary: participant \(id.uuidString, privacy: .public) cycle \(cycle) > coordinator cycle \(self.currentCycle); synchronizing to current cycle")
            participantCycle = currentCycle
        }

        participants[id] = ParticipantState(cycle: currentCycle, isFinished: true, hasCommittedCurrentCycle: participants[id]?.hasCommittedCurrentCycle ?? true)

        let now = configuration.clock()

        if let proposal = activeProposal {
            return .proceed(proposal)
        }

        if firstFinishedTime == nil {
            firstFinishedTime = now
        }

        let allFinished = areAllParticipantsFinished(for: currentCycle)

        if !allFinished {
            if let first = firstFinishedTime, (now - first) >= configuration.maxBarrierWait {
                let stalledParticipants = participants.compactMap { participantID, state in
                    state.cycle == currentCycle && !state.isFinished ? participantID : nil
                }
                for participantID in stalledParticipants {
                    participants.removeValue(forKey: participantID)
                }
                logger.warning("evaluateBoundary: safety barrier timeout after \(self.configuration.maxBarrierWait)s, removed \(stalledParticipants.count) stalled participants and proposing cycle \(self.currentCycle + 1)")
                return proposeAdvancement(pool: pool)
            }
            return .wait
        }

        if barrierSatisfiedTime == nil {
            barrierSatisfiedTime = now
            logger.info("evaluateBoundary: all \(self.participants.count) participants finished cycle \(self.currentCycle); starting dwell")
        }

        let dwellElapsed = now - barrierSatisfiedTime!
        if dwellElapsed >= configuration.dwellDuration {
            logger.info("evaluateBoundary: dwell \(dwellElapsed)s elapsed; proposing cycle \(self.currentCycle + 1)")
            return proposeAdvancement(pool: pool)
        }

        return .wait
    }

    func commitAdvancement(for id: UUID, cycle: UInt64) {
        guard let proposal = activeProposal, proposal.cycle == cycle else {
            if cycle == currentCycle {
                participants[id] = ParticipantState(cycle: cycle, isFinished: false, hasCommittedCurrentCycle: true)
            }
            return
        }
        participants[id] = ParticipantState(cycle: cycle, isFinished: false, hasCommittedCurrentCycle: true)
        logger.info("commitAdvancement(id=\(id.uuidString, privacy: .public), cycle=\(cycle))")

        let allCommitted = participants.values.allSatisfy { $0.cycle == cycle && $0.hasCommittedCurrentCycle }
        if allCommitted {
            finalizeAdvancement(proposal: proposal)
        }
    }

    func reset() {
        participants.removeAll()
        currentCycle = 0
        currentEffect = nil
        baseSeed = 0
        currentStartEpoch = nil
        firstRegistrationTime = nil
        firstFinishedTime = nil
        barrierSatisfiedTime = nil
        activeProposal = nil
        lastEffect = nil
        remainingBag.removeAll()
        lastPool.removeAll()
    }

    private func checkCycle0StartBarrier(now: TimeInterval) {
        guard currentCycle == 0, currentStartEpoch == nil else { return }
        let target = targetParticipantCount()
        let timeSinceFirst = now - (firstRegistrationTime ?? now)
        if participants.count >= target || timeSinceFirst >= configuration.startBarrierTimeout {
            currentStartEpoch = now
            logger.info("Cycle 0 start barrier satisfied: participants=\(self.participants.count)/\(target), startEpoch=\(now)")
        }
    }

    private func areAllParticipantsFinished(for cycle: UInt64) -> Bool {
        guard !participants.isEmpty else { return false }
        return participants.values.allSatisfy { $0.cycle == cycle && $0.isFinished }
    }

    private func proposeAdvancement(pool: [String]) -> BarrierDecision {
        let nextCycle = currentCycle + 1
        let nextEffect = pickNextEffect(from: pool)
        let nextSeed = seed(for: nextCycle)
        let proposal = CyclePlan(
            cycle: nextCycle,
            effect: nextEffect,
            seed: nextSeed,
            startEpoch: nil
        )
        activeProposal = proposal
        return .proceed(proposal)
    }

    private func finalizeAdvancement(proposal: CyclePlan) {
        currentCycle = proposal.cycle
        currentEffect = proposal.effect
        currentStartEpoch = configuration.clock()
        activeProposal = nil
        firstFinishedTime = nil
        barrierSatisfiedTime = nil
        let effectName = self.currentEffect ?? "none"
        logger.info("Finalized cycle advancement to cycle \(self.currentCycle), effect=\(effectName, privacy: .public)")
    }

    private func resolvePool(_ availableEffects: [String]) -> [String] {
        let sanitized = OmacyEffects.sanitize(availableEffects)
        return sanitized.isEmpty ? OmacyEffects.names : sanitized
    }

    private func pickNextEffect(from pool: [String]) -> String {
        if pool.isEmpty {
            return OmacyEffects.names.first ?? "wipe"
        }
        if pool.count == 1 {
            lastEffect = pool[0]
            remainingBag.removeAll()
            return pool[0]
        }

        if pool != lastPool {
            lastPool = pool
            remainingBag.removeAll()
        }

        if remainingBag.isEmpty {
            var newBag = configuration.shuffler(pool)
            if newBag.count > 1, newBag.first == lastEffect {
                let lastIndex = newBag.count - 1
                newBag.swapAt(0, lastIndex)
            }
            remainingBag = newBag
        }

        let chosen = remainingBag.removeFirst()
        lastEffect = chosen
        return chosen
    }
}
