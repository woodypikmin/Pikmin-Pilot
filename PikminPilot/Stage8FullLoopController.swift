import SwiftUI
import UIKit

@MainActor
final class Stage8FullLoopController: ObservableObject {
    static let persistedStatusKey = "PikminPilot.Stage8.LastStatus"

    private enum StopCause: Equatable {
        case none
        case userAfterCurrent
        case userImmediate
        case targetReached
        case backgroundExpired
    }

    @Published private(set) var isRunning = false
    @Published private(set) var completedDispatches = 0
    @Published private(set) var currentPhase = "待機"
    @Published private(set) var stopAfterCurrentRequested = false
    @Published private(set) var targetDispatches: Int?
    @Published private(set) var pikminType: PilotPikminType = .pink
    @Published private(set) var pikminCount = 12
    @Published private(set) var cargoMode: PilotCargoMode = .fruit
    @Published private(set) var fastMode = false

    private var cancelled = false
    private var stopCause: StopCause = .none
    private var worker: Task<Void, Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var backgroundGeneration: UInt64 = 0
    private var renewalInProgress = false
    private var criticalTailInProgress = false
    // Stage 11.5.4.19: once a dispatch has left the expedition list, Pilot is
    // forbidden from foregrounding itself until Runner has positively closed
    // the carrying green X and hands control back. This prevents a background
    // renewal/checkpoint from stealing foreground before the close tap.
    private var gameplayForegroundLock = false
    private var backgroundExpiredDuringCriticalTail = false
    // 11.5.4.21 CONTINUOUS RECOVERY: expiration of one finite host task is
    // a recoverable lifecycle event, not a reason to cancel an N-item run.
    // Safe checkpoints consume this flag and acquire a new window.
    private var backgroundRecoveryPending = false
    // 11.5.4.20: remember the slowest successful atomic tail seen in this run.
    // The final GO commit budget is derived from both a conservative default
    // and this field observation so a temporarily slower device does not keep
    // starting the next tail with only a few seconds of handoff margin.
    private var observedCriticalTailSeconds: Double?
    private var logLines: [String] = []

    private var statusSink: ((String) -> Void)?
    private var screenshotSink: ((UIImage) -> Void)?

    func start(
        pairingPath: String,
        host: String = "10.7.0.1",
        targetDispatches: Int?,
        pikminType: PilotPikminType,
        pikminCount: Int,
        cargoMode: PilotCargoMode,
        fastMode: Bool,
        onStatus: @escaping (String) -> Void,
        onScreenshot: @escaping (UIImage) -> Void
    ) {
        guard !isRunning else { return }

        cancelled = false
        stopCause = .none
        stopAfterCurrentRequested = false
        gameplayForegroundLock = false
        backgroundRecoveryPending = false
        observedCriticalTailSeconds = nil
        completedDispatches = 0
        self.targetDispatches = targetDispatches.flatMap { $0 > 0 ? $0 : nil }
        self.pikminType = pikminType
        self.pikminCount = min(12, max(pikminType.minimumCount, pikminCount))
        self.cargoMode = cargoMode
        self.fastMode = fastMode
        logLines.removeAll(keepingCapacity: true)
        statusSink = onStatus
        screenshotSink = onScreenshot
        isRunning = true
        setPhase("準備中")

        beginBackgroundWindow(label: "initial")
        let goal = self.targetDispatches.map(String.init) ?? "∞"
        emit("STAGE 11.5.4.23 PILOT RUN START • baseline=11.5.3 • automation-core=10.3.1 • transportHost=\(host):49152 • target=\(goal) • cargo=\(self.cargoMode.displayName) • pikmin=\(self.pikminType.shortName)×\(self.pikminCount) • speed=\(self.fastMode ? "FAST" : "STABLE") • Stage 8.2.2 stable loop core • WDA=OFF")

        worker = Task { [weak self] in
            guard let self else { return }
            await self.run(pairingPath: pairingPath, host: host)
        }
    }

    // Stage 11.5.4.19: run the same verified 10.3.1 automation core on an
    // already-established persistent RSD session. This is the cellular escape
    // path: no operation below is allowed to reconnect to RemotePairing :49152.
    func startPersistent(
        engine: IDeviceEngine,
        transportLabel: String,
        targetDispatches: Int?,
        pikminType: PilotPikminType,
        pikminCount: Int,
        cargoMode: PilotCargoMode,
        fastMode: Bool,
        onStatus: @escaping (String) -> Void,
        onScreenshot: @escaping (UIImage) -> Void
    ) {
        guard !isRunning else { return }

        cancelled = false
        stopCause = .none
        stopAfterCurrentRequested = false
        gameplayForegroundLock = false
        backgroundRecoveryPending = false
        observedCriticalTailSeconds = nil
        completedDispatches = 0
        self.targetDispatches = targetDispatches.flatMap { $0 > 0 ? $0 : nil }
        self.pikminType = pikminType
        self.pikminCount = min(12, max(pikminType.minimumCount, pikminCount))
        self.cargoMode = cargoMode
        self.fastMode = fastMode
        logLines.removeAll(keepingCapacity: true)
        statusSink = onStatus
        screenshotSink = onScreenshot
        isRunning = true
        setPhase("準備中")

        beginBackgroundWindow(label: "persistent-cellular")
        let goal = self.targetDispatches.map(String.init) ?? "∞"
        emit("STAGE 11.5.4.23 PERSISTENT CELLULAR RUN START • automation-core=10.3.1 • transport=\(transportLabel) • target=\(goal) • cargo=\(self.cargoMode.displayName) • pikmin=\(self.pikminType.shortName)×\(self.pikminCount) • speed=\(self.fastMode ? "FAST" : "STABLE") • RPPairing-reconnect=DISABLED")

        worker = Task { [weak self] in
            guard let self else { return }
            await self.run(engine: engine)
        }
    }

    /// Finish the item that is already in progress, return to the expedition
    /// list, then stop before starting another round.
    func stopAfterCurrent() {
        guard isRunning else { return }
        stopAfterCurrentRequested = true
        stopCause = .userAfterCurrent
        setPhase("完成目前項目後停止")
        emit("STOP AFTER CURRENT requested • current dispatch will finish, then no new round will start")
    }

    /// Best-effort immediate stop. No new screenshot/tap/swipe command will be
    /// started after this flag is observed. A single XCTest command that has
    /// already crossed the FFI boundary is atomic and may finish before control
    /// returns to Pilot.
    func stopNow() {
        guard isRunning else { return }
        stopCause = .userImmediate
        cancelled = true
        stopAfterCurrentRequested = false
        setPhase("立即停止中")
        emit("STOP NOW requested ⚡️ • cancellation latched • only an already in-flight XCTest/DTX command may finish; no next tap/swipe/capture will be started")
        worker?.cancel()
    }

    private func finish() {
        // Invalidate any queued expiration callback before ending the task.
        backgroundGeneration &+= 1
        renewalInProgress = false
        criticalTailInProgress = false
        gameplayForegroundLock = false
        backgroundExpiredDuringCriticalTail = false
        backgroundRecoveryPending = false
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
        isRunning = false
        worker = nil
    }

    private func beginBackgroundWindow(label: String) {
        // Every background window has a generation token. iOS can deliver an
        // expiration callback while we are replacing an old window; callbacks
        // from superseded windows must never cancel the new loop.
        backgroundGeneration &+= 1
        let generation = backgroundGeneration

        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }

        backgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "PikminPilot-Stage10.3-\(label)",
            expirationHandler: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    guard generation == self.backgroundGeneration else {
                        self.emit("BACKGROUND stale expiration ignored • generation=\(generation)")
                        return
                    }

                    // Apple requires every finite background task to be ended
                    // when its expiration handler fires. Not ending it can cause
                    // iOS to terminate the host process, which looked like a
                    // mysterious status reset in earlier Stage 8 builds.
                    let expiredTask = self.backgroundTask
                    self.backgroundTask = .invalid
                    if expiredTask != .invalid {
                        UIApplication.shared.endBackgroundTask(expiredTask)
                    }

                    self.backgroundRecoveryPending = true

                    if self.criticalTailInProgress || self.gameplayForegroundLock {
                        // Never steal foreground from Pikmin while a dispatch is in
                        // its selection/GO/carrying-close critical region. Runner
                        // owns that foreground until the green X is positively closed.
                        self.backgroundExpiredDuringCriticalTail = true
                        self.emit("BACKGROUND WINDOW EXPIRED DURING FOREGROUND-LOCK • recovery latched • GO state preserved • run continues")
                        return
                    }

                    if self.renewalInProgress {
                        self.emit("BACKGROUND expiration arrived during renewal • recovery latched; renewal continues")
                        return
                    }

                    // 11.5.4.21: do not convert one iOS finite-background lease
                    // expiration into FAILED/completed=N. The next safe boundary
                    // must foreground Pilot, acquire a new lease, and continue.
                    self.emit("BACKGROUND WINDOW EXPIRED ⚠️ • recovery pending • target latch preserved • run NOT cancelled")
                }
            }
        )
    }

    private func setPhase(_ phase: String) {
        currentPhase = phase
    }

    private func emit(_ line: String) {
        logLines.append(line)
        if logLines.count > 220 {
            logLines.removeFirst(logLines.count - 220)
        }
        let text = logLines.joined(separator: "\n")
        UserDefaults.standard.set(text, forKey: Self.persistedStatusKey)
        statusSink?(text)
    }

    private func pause(_ seconds: Double) async {
        let ns = UInt64(max(0, seconds) * 1_000_000_000)
        try? await Task.sleep(nanoseconds: ns)
    }

    private func run(pairingPath: String, host: String) async {
        let engine = IDeviceEngine(pairingPath: pairingPath, host: host, port: 49152)
        await run(engine: engine)
    }

    private func run(engine: IDeviceEngine) async {
        do {
            setPhase("啟動 Pikmin")
            let activate = await engine.runXCTestActivateOnly()
            guard activate.ok else {
                throw LoopError("phase=initial-activate • \(activate.message)")
            }
            emit("Pikmin activate ✅")
            await pause(fastMode ? 0.28 : 0.45)

            var consecutiveEmptyFullScans = 0
            while !cancelled {
                if let targetDispatches, completedDispatches >= targetDispatches {
                    stopCause = .targetReached
                    setPhase("已完成")
                    emit("COMPLETED • requested=\(targetDispatches) • completed=\(completedDispatches) • exact-target=YES")
                    finish()
                    return
                }

                let round = completedDispatches + 1
                setPhase("尋找\(cargoMode.scanDescription)")
                let requested = targetDispatches.map(String.init) ?? "∞"
                emit("ROUND \(round) • scanning Expedition list • cargo=\(cargoMode.displayName) • progress=\(completedDispatches)/\(requested)")

                guard let choice = try await findAvailableCargo(
                    engine: engine,
                    round: round
                ) else {
                    consecutiveEmptyFullScans += 1

                    // Stage 11.5.4.19 HARD COUNT LATCH: a finite target is a
                    // contract, not a best-effort loop. A detector/list refresh
                    // miss is recoverable and MUST NOT end a 5/5 (or N/N) run.
                    // Stay on the same round until an item appears, the user
                    // stops the run, or an actual XCTest/transport error occurs.
                    if targetDispatches != nil {
                        setPhase("暫時找不到項目，保持第 \(round) 輪")
                        emit("ROUND \(round) RETRY • requested=\(requested) • completed=\(completedDispatches) • no safe AVAILABLE after full scan • retry=\(consecutiveEmptyFullScans) • TARGET-LATCH=HOLD • COMPLETE=NO")

                        try await foregroundPikminContinuously(
                            engine: engine,
                            stage: "target-latch-retry-reactivate",
                            round: round
                        )

                        let longSettle = consecutiveEmptyFullScans % 3 == 0
                        await pause(longSettle ? (fastMode ? 1.15 : 1.80) : (fastMode ? 0.55 : 0.90))
                        continue
                    }

                    // Infinite mode also waits instead of silently terminating.
                    setPhase("等待新的可搬運項目")
                    emit("WAITING • mode=infinite • completed=\(completedDispatches) • no safe AVAILABLE • retrying")
                    consecutiveEmptyFullScans = 0
                    await pause(fastMode ? 1.0 : 1.8)
                    continue
                }
                consecutiveEmptyFullScans = 0

                try await runOneDispatch(
                    engine: engine,
                    round: round,
                    item: choice.item,
                    listImage: choice.image
                )

                completedDispatches += 1
                emit("ROUND \(round) COMPLETED ✅ • total=\(completedDispatches)")

                if cancelled { break }

                setPhase("回到探險列表")
                // The post-tail GREEN-X DOUBLE-ACK already proved the list on
                // two consecutive live frames. Keep this legacy list check only
                // as a soft sanity probe; a transient detector miss must never
                // terminate a finite target halfway through.
                if !(try await waitForExpeditionList(engine: engine, attempts: 8)) {
                    emit("ROUND \(round) • LIST SOFT-MISS after verified green-X close • keeping target latch alive")
                    try await foregroundPikminContinuously(
                        engine: engine,
                        stage: "list-soft-recovery-reactivate",
                        round: round
                    )
                    await pause(fastMode ? 0.40 : 0.70)
                }

                if stopAfterCurrentRequested {
                    stopCause = .userAfterCurrent
                    setPhase("已安全停止")
                    emit("STOPPED AFTER CURRENT • completed=\(completedDispatches) • list=ready")
                    finish()
                    return
                }

                if let targetDispatches, completedDispatches >= targetDispatches {
                    stopCause = .targetReached
                    setPhase("已完成")
                    emit("COMPLETED • requested=\(targetDispatches) • completed=\(completedDispatches) • list=ready • exact-target=YES")
                    finish()
                    return
                }

                if cancelled { break }
                await pause(fastMode ? 0.10 : 0.20)
            }

            setPhase(stopCause == .userImmediate ? "已立即停止" : "已停止")
            emit(stopLine())
            finish()
        } catch {
            if cancelled && error.localizedDescription == "cancelled" {
                setPhase(stopCause == .userImmediate ? "已立即停止" : "已停止")
                emit(stopLine())
            } else {
                setPhase("執行失敗")
                emit("FAILED • completed=\(completedDispatches) • \(error.localizedDescription)")
            }
            finish()
        }
    }

    // MARK: - Expedition list scan (Stage 5 card-first semantics)

    private func findAvailableCargo(
        engine: IDeviceEngine,
        round: Int
    ) async throws -> (item: FruitCandidate, image: UIImage)? {
        var directionDown = true
        var reversed = false
        var swipes = 0

        while !cancelled {
            try await ensureBackgroundBudget(engine: engine, stage: "fruit-scan")

            let image = try await capture(engine: engine, tag: "fruit-list")
            let result = await FruitDetector.detect(in: image)
            screenshotSink?(FruitDetector.annotated(image: image, result: result))

            let rawAvailable: [FruitCandidate]
            switch cargoMode {
            case .fruit:
                rawAvailable = result.fruits
            case .seedling:
                rawAvailable = result.seedlings
            case .both:
                rawAvailable = result.fruits + result.seedlings
            }

            let available = rawAvailable.sorted {
                if abs($0.center.y - $1.center.y) > 12 {
                    return $0.center.y < $1.center.y
                }
                return $0.center.x < $1.center.x
            }

            let busyCards = result.cards.filter { $0.state == .busy }.count
            let completeCards = result.cards.filter { $0.state == .complete }.count

            emit(
                "ROUND \(round) SCAN • FRUIT=\(result.fruits.count) • SEEDLING=\(result.seedlings.count) • MATCH=\(available.count) • BUSY=\(busyCards) • COMPLETE=\(completeCards) • BLOCKED=\(result.blockedObjects.count)"
            )

            if let first = available.first {
                emit("ROUND \(round) • card-first AVAILABLE selected • kind=\(first.kind.rawValue) • label=\(first.labelText)")
                return (first, image)
            }

            if swipes >= 8 {
                if !reversed {
                    reversed = true
                    directionDown = false
                    swipes = 0
                    emit("ROUND \(round) • no matching AVAILABLE below; reversing list scan")
                } else {
                    return nil
                }
            }

            if directionDown {
                try await swipeInContent(
                    engine: engine,
                    image: image,
                    fromX: 0.52,
                    fromY: 0.77,
                    toX: 0.52,
                    toY: 0.35,
                    duration: 0.42,
                    stage: "fruit-list-down"
                )
            } else {
                try await swipeInContent(
                    engine: engine,
                    image: image,
                    fromX: 0.52,
                    fromY: 0.35,
                    toX: 0.52,
                    toY: 0.77,
                    duration: 0.42,
                    stage: "fruit-list-up"
                )
            }

            swipes += 1
            await pause(fastMode ? 0.35 : 0.55)
        }

        return nil
    }

    // MARK: - One complete Stage 5 dispatch

    private var isIPadDevice: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    private func runOneDispatch(
        engine: IDeviceEngine,
        round: Int,
        item: FruitCandidate,
        listImage: UIImage
    ) async throws {
        try checkCancelled()

        // Renew only while still on the expedition list, before entering any
        // modal/detail/selection UI. After this point gameplayForegroundLock
        // prevents Pilot from stealing foreground until the green X is closed.
        // iPad can occasionally spend ~60s inside an XCTest activate during a
        // renewal. Do not renew early on the expedition list: the later
        // pre-critical-tail checkpoint is the safer place to refresh. iPhone
        // keeps the proven 11.5.4.19 threshold unchanged.
        try await ensureBackgroundBudget(
            engine: engine,
            stage: "pre-dispatch-safe-boundary",
            minimumRemaining: isIPadDevice ? 10.0 : 22.0
        )
        gameplayForegroundLock = true

        setPhase(item.kind == .seedling ? "點擊可用花苗" : "點擊可用水果")
        emit("ROUND \(round) • tap AVAILABLE • kind=\(item.kind.rawValue) • label=\(item.labelText)")
        try await tap(
            engine: engine,
            pixel: item.center,
            image: listImage,
            stage: "available-fruit"
        )
        await pause(fastMode ? 0.55 : 0.85)

        setPhase("前往探險")

        if item.kind == .seedling {
            // Stage 11.5.4.19: seedling artwork can itself be blue, so never use
            // blue-pixel geometry to choose the detail-page CTA. OCR the literal
            // CTA text and tap the text centre. This leaves the proven fruit path
            // completely unchanged.
            emit("ROUND \(round) • detect 前往探險 • SEEDLING OCR CTA")
            guard let expedition = try await waitForSeedlingExpeditionCTA(
                engine: engine,
                round: round
            ) else {
                throw LoopError("Round \(round): seedling 前往探險 text not detected")
            }

            try await tap(
                engine: engine,
                pixel: expedition.point,
                image: expedition.image,
                stage: "expedition-button",
                allowBackgroundRenewal: false
            )
            try checkCancelled()
            await pause(fastMode ? 1.05 : 1.45)
            try checkCancelled()

            // One short, text-based transition check. No 18-frame loop and no
            // horizontal gesture is sent unless the selection screen is seen.
            guard try await confirmPikminSelectionPage(
                engine: engine,
                round: round
            ) else {
                throw LoopError("Round \(round): seedling 前往探險 was tapped but selection page was not confirmed • filter-row swipe suppressed")
            }
        } else {
            // Proven Stage 11.5.3/11.5.4.12 fruit path: unchanged.
            emit("ROUND \(round) • detect 前往探險 • baseline fruit detector")
            guard let expedition = try await waitForPoint(
                engine: engine,
                attempts: 18,
                delay: 0.38,
                stage: "expedition-button",
                detector: ImageAutomationDetector.detectExpeditionButton
            ) else {
                throw LoopError("Round \(round): 前往探險 not detected")
            }

            try await tap(
                engine: engine,
                pixel: expedition.point,
                image: expedition.image,
                stage: "expedition-button"
            )
            try checkCancelled()
            await pause(fastMode ? 1.45 : 2.0)
            try checkCancelled()
        }

        // Stage 11.5.4.19: the detail/OCR transition is now proven, but field logs
        // showed only ~14-17s of finite background time remained by the time the
        // critical Runner tail began. That is not enough margin for select→GO→X
        // plus Runner→Pilot handoff. Renew only at this verified selection-page
        // checkpoint, then re-confirm the page before any filter-row gesture.
        try await ensurePreCriticalTailBudget(engine: engine, round: round)

        setPhase("辨識\(pikminType.displayName)皮克敏")
        emit("ROUND \(round) • selection page stable • detect \(pikminType.shortName) filter on fresh foreground-locked frame")
        await pause(fastMode ? 0.18 : 0.28)
        try checkCancelled()

        guard var selectedFilter = try await detectPikminFilterForTail(
            engine: engine,
            round: round,
            revealFirst: true
        ) else {
            throw LoopError("Round \(round): \(pikminType.shortName) filter not detected on fresh foreground-locked frame")
        }

        // 11.5.4.21 CONTINUOUS COMMIT GATE. A thin lease never means STOP.
        // GO is still replay-safe here, so keep re-arming until there is a usable
        // commit window (or the user explicitly stops the run). Every re-arm
        // re-confirms the selection page and obtains a fresh filter coordinate.
        var filterX = 0.0
        var filterY = 0.0
        let emergencyFloor = fastMode ? 19.0 : 21.0
        while true {
            try checkCancelled()
            selectedFilter = try await ensureFinalCriticalTailCommitBudget(
                engine: engine,
                round: round,
                selectedFilter: selectedFilter
            )

            guard let filterCG = selectedFilter.image.cgImage else {
                throw LoopError("Round \(round): Pikmin filter screenshot has no CGImage")
            }
            filterX = Double(selectedFilter.point.x) / Double(filterCG.width)
            filterY = Double(selectedFilter.point.y) / Double(filterCG.height)

            if let remaining = finiteBackgroundSeconds(), remaining < emergencyFloor {
                emit(String(format: "ROUND %d • FINAL COMMIT HOLD ⚠️ • %.1fs < emergency %.1fs • GO NOT SENT • re-arming same round", round, remaining, emergencyFloor))
                continue
            }
            break
        }

        setPhase("\(pikminType.shortName) → \(pikminCount) 隻 → GO → 關閉 X")
        emit(String(format: "ROUND %d • ONE XCTest critical tail begin • type=%@ • filter=(%.4f,%.4f) • select=%d→GO→greenX • speed=%@", round, pikminType.shortName, filterX, filterY, pikminCount, fastMode ? "FAST" : "STABLE"))

        if let remaining = finiteBackgroundSeconds() {
            let required = requiredCriticalTailStartBudget()
            emit(String(format: "ROUND %d • fresh background budget before critical tail = %.1fs • target>=%.1fs", round, remaining, required))
        }

        let tailStartedAt = Date()
        criticalTailInProgress = true
        backgroundExpiredDuringCriticalTail = false
        let tail = await engine.runXCTestDispatchTail(
            pikminX: filterX,
            pikminY: filterY,
            pikminCount: pikminCount,
            fastMode: fastMode
        )
        criticalTailInProgress = false

        // STOP NOW may have been requested while the already-dispatched atomic
        // Runner tail was in flight. The tail itself cannot be revoked reliably.
        try checkCancelled()

        let tailElapsed = Date().timeIntervalSince(tailStartedAt)
        observedCriticalTailSeconds = max(observedCriticalTailSeconds ?? 0, tailElapsed)
        if tail.ok {
            if let postTailRemaining = finiteBackgroundSeconds() {
                emit(String(format: "ROUND %d • ONE XCTest critical tail completed ✅ • %@→%d→GO→greenX • tail=%.2fs • background=%.1fs", round, pikminType.shortName, pikminCount, tailElapsed, postTailRemaining))
            } else {
                emit(String(format: "ROUND %d • ONE XCTest critical tail completed ✅ • %@→%d→GO→greenX • tail=%.2fs • background=%@", round, pikminType.shortName, pikminCount, tailElapsed, backgroundBudgetLabel()))
            }
        } else {
            // Once dispatchtail crossed the XCTest boundary, a timeout/BrokenPipe
            // cannot prove whether GO happened. Never replay GO from a transport
            // return code. Hold the committed checkpoint and let screenshots/game
            // state prove Green-X/list before completed is incremented.
            emit("ROUND \(round) • CRITICAL TAIL RESULT UNCERTAIN ⚠️ • tail=\(String(format: "%.2f", tailElapsed))s • \(compactTransportMessage(tail.message)) • GO-REPLAY=FORBIDDEN • entering state reconciliation")
        }

        setPhase("回到探險列表")
        try await completeRunnerHandoffContinuously(engine: engine, round: round)
        await pause(fastMode ? 0.14 : 0.25)
    }


    /// Detect the requested Pikmin filter from a fresh frame. On the first pass
    /// we reveal the horizontal filter row exactly as before. After a final
    /// budget re-arm we first inspect the preserved selection page without a
    /// gesture; if the row stayed visible this saves several seconds of the new
    /// background window. Only if necessary do we reveal it again.
    private func detectPikminFilterForTail(
        engine: IDeviceEngine,
        round: Int,
        revealFirst: Bool
    ) async throws -> (point: CGPoint, image: UIImage)? {
        if !revealFirst {
            try checkCancelled()
            let preserved = try await capture(engine: engine, tag: "pikmin-filter-post-renew-fresh")
            screenshotSink?(preserved)
            if let point = ImageAutomationDetector.detectPikminFilter(type: pikminType, in: preserved) {
                emit("ROUND \(round) • \(pikminType.shortName) filter preserved after final renewal ✅")
                return (point, preserved)
            }
            emit("ROUND \(round) • filter row not immediately visible after final renewal • revealing once")
        }

        emit("ROUND \(round) • reveal Pikmin filter row • target=\(pikminType.shortName)")
        let revealFrame = try await capture(engine: engine, tag: "pikmin-filter-reveal-geometry")
        try await swipeInContent(
            engine: engine,
            image: revealFrame,
            fromX: 0.88,
            fromY: 0.432,
            toX: 0.43,
            toY: 0.432,
            duration: 0.38,
            stage: "pikmin-filter-row"
        )
        await pause(fastMode ? 0.30 : 0.48)

        for attempt in 0...4 {
            try checkCancelled()
            try await ensureBackgroundBudget(engine: engine, stage: "pikmin-filter")

            let image = try await capture(engine: engine, tag: "pikmin-filter-fresh")
            screenshotSink?(image)
            if let point = ImageAutomationDetector.detectPikminFilter(type: pikminType, in: image) {
                emit("ROUND \(round) • \(pikminType.shortName) filter detected on fresh frame ✅")
                return (point, image)
            }

            emit("ROUND \(round) • \(pikminType.shortName) filter miss attempt \(attempt + 1)/5")
            if attempt < 4 {
                try await swipeInContent(
                    engine: engine,
                    image: image,
                    fromX: 0.88,
                    fromY: 0.432,
                    toX: 0.43,
                    toY: 0.432,
                    duration: 0.34,
                    stage: "pikmin-filter-retry"
                )
                await pause(fastMode ? 0.28 : 0.42)
            }
        }
        return nil
    }

    /// Required finite budget at the exact GO commit boundary. This is not a
    /// prediction of XCTest runtime; it is a conservative admission control
    /// floor. It adapts upward if this device has already demonstrated a slower
    /// successful tail in the same run.
    private func requiredCriticalTailStartBudget() -> Double {
        let countExtra = Double(max(0, pikminCount - 2))
        let staticFloor = fastMode
            ? min(24.0, 22.0 + countExtra * 0.08)
            : min(26.0, 24.0 + countExtra * 0.10)
        let observedFloor = (observedCriticalTailSeconds ?? 0) + (fastMode ? 5.0 : 6.0)
        return min(27.0, max(staticFloor, observedFloor))
    }

    /// Final pre-GO recovery. Unlike the legacy iPhone renewal path this uses
    /// AppService for Pikmin foreground restoration on *both* phone and tablet,
    /// so adding this safety gate cannot introduce another activate-only
    /// execute-test-plan / ~60s timeout immediately before the atomic tail.
    private func ensureFinalCriticalTailCommitBudget(
        engine: IDeviceEngine,
        round: Int,
        selectedFilter: (point: CGPoint, image: UIImage)
    ) async throws -> (point: CGPoint, image: UIImage) {
        let required = requiredCriticalTailStartBudget()
        let emergencyFloor = fastMode ? 19.0 : 21.0
        var currentFilter = selectedFilter
        var commitAttempt = 0

        while true {
            try checkCancelled()

            guard UIApplication.shared.applicationState != .active,
                  let remaining = finiteBackgroundSeconds() else {
                emit("ROUND \(round) • FINAL TAIL GATE ✅ • Pilot foreground/unbounded")
                return currentFilter
            }

            if remaining >= required {
                emit(String(format: "ROUND %d • FINAL TAIL GATE ✅ • %.1fs available • target>=%.1fs", round, remaining, required))
                return currentFilter
            }

            commitAttempt += 1
            emit(String(format: "ROUND %d • FINAL TAIL GATE HOLD ⚠️ • %.1fs available • target>=%.1fs • GO NOT SENT • recovery=%d", round, remaining, required, commitAttempt))

            let previousLock = gameplayForegroundLock
            gameplayForegroundLock = false
            do {
                try await refreshBackgroundWindowAppServiceOnly(
                    engine: engine,
                    reason: "final-tail-commit-r\(round)-a\(commitAttempt)",
                    round: round
                )
            } catch {
                gameplayForegroundLock = previousLock
                emit("ROUND \(round) • FINAL TAIL recovery retry ⚠️ • recovery=\(commitAttempt) • \(compactTransportMessage(error.localizedDescription)) • run continues")
                await pause(min(1.20, 0.20 + Double(commitAttempt % 5) * 0.18))
                continue
            }
            gameplayForegroundLock = previousLock
            try checkCancelled()

            guard try await confirmPikminSelectionPage(engine: engine, round: round) else {
                emit("ROUND \(round) • FINAL TAIL checkpoint HOLD ⚠️ • selection page not yet re-confirmed • GO NOT SENT • retrying")
                await pause(commitAttempt % 4 == 0 ? 0.90 : 0.30)
                continue
            }

            guard let freshFilter = try await detectPikminFilterForTail(
                engine: engine,
                round: round,
                revealFirst: false
            ) else {
                emit("ROUND \(round) • FINAL TAIL checkpoint HOLD ⚠️ • \(pikminType.shortName) filter not yet re-confirmed • GO NOT SENT • retrying")
                await pause(commitAttempt % 4 == 0 ? 0.90 : 0.30)
                continue
            }
            currentFilter = freshFilter

            if let after = finiteBackgroundSeconds() {
                if after >= required {
                    emit(String(format: "ROUND %d • FINAL TAIL GATE RE-ARMED ✅ • recovery=%d • background=%.1fs • target>=%.1fs", round, commitAttempt, after, required))
                    return currentFilter
                }

                // A freshly-acquired window that remains above the emergency
                // floor is allowed to proceed after two full recovery cycles.
                // This avoids an endless re-arm loop on devices whose OCR/filter
                // work consistently consumes a few seconds of a ~30s lease.
                if after >= emergencyFloor && commitAttempt >= 2 {
                    emit(String(format: "ROUND %d • FINAL TAIL GATE bounded proceed ⚠️ • background=%.1fs < target %.1fs • >= emergency %.1fs • handoff recovery armed", round, after, required, emergencyFloor))
                    return currentFilter
                }

                emit(String(format: "ROUND %d • FINAL TAIL GATE still thin ⚠️ • recovery=%d • background=%.1fs • GO NOT SENT • continuing recovery", round, commitAttempt, after))
            } else {
                emit("ROUND \(round) • FINAL TAIL GATE RE-ARMED ✅ • background=\(backgroundBudgetLabel())")
                return currentFilter
            }

            await pause(commitAttempt % 4 == 0 ? 0.85 : 0.22)
        }
    }

    /// Acquire a fresh host background task from the safe selection checkpoint
    /// and restore Pikmin with CoreDevice AppService only. No Runner/XCTest
    /// activate command is created here. The newly-created finite window is
    /// verified before returning; an immediately-expiring iPadOS window is
    /// re-primed once instead of being mistaken for a successful renewal.
    private func refreshBackgroundWindowAppServiceOnly(
        engine: IDeviceEngine,
        reason: String,
        round: Int
    ) async throws {
        try checkCancelled()
        renewalInProgress = true
        defer { renewalInProgress = false }
        emit("ROUND \(round) • FINAL TAIL renewal begin • reason=\(reason) • AppService-only")

        guard let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty else {
            throw LoopError("Pilot bundle identifier unavailable for final-tail renewal")
        }

        if let freeze = try? await capture(engine: engine, tag: "refresh-\(reason)") {
            screenshotSink?(freeze)
        }

        let freshWindowMinimum = fastMode ? 22.0 : 24.0
        var lastFailure = "unknown final-tail AppService renewal failure"

        for windowAttempt in 1...2 {
            var pilotResultMessage = "unknown Pilot AppService failure"
            var pilotActive = false
            for attempt in 1...3 {
                let foregroundPilot = await engine.launchBundleID(bundleID)
                try checkCancelled()
                pilotResultMessage = foregroundPilot.message
                if foregroundPilot.ok {
                    let deadline = Date().addingTimeInterval(1.40)
                    while Date() < deadline {
                        if UIApplication.shared.applicationState == .active {
                            pilotActive = true
                            break
                        }
                        await pause(0.04)
                    }
                    if pilotActive { break }
                }
                if attempt < 3 {
                    emit("ROUND \(round) • FINAL TAIL Pilot foreground retry ⚠️ • attempt=\(attempt)/3 • \(compactTransportMessage(pilotResultMessage))")
                    await pause(0.10)
                }
            }
            guard pilotActive else {
                throw LoopError("phase=final-tail-refresh-pilot • AppService could not restore Pilot foreground • \(pilotResultMessage)")
            }

            // A real foreground dwell before beginBackgroundTask is important on
            // iPadOS, where a too-short bounce can immediately inherit/expire the
            // preceding lifecycle window. iPhone gets a shorter dwell.
            await pause(isIPadDevice ? (windowAttempt == 1 ? 0.85 : 1.20) : 0.35)
            try checkCancelled()
            beginBackgroundWindow(label: "renew-\(reason)-w\(windowAttempt)")

            var pikminMessage = "unknown Pikmin AppService failure"
            var pikminOK = false
            for attempt in 1...3 {
                let result = await engine.launchBundleID("com.nianticlabs.pikmin")
                try checkCancelled()
                pikminMessage = result.message
                if result.ok {
                    pikminOK = true
                    break
                }
                if attempt < 3 {
                    emit("ROUND \(round) • FINAL TAIL Pikmin foreground retry ⚠️ • attempt=\(attempt)/3 • \(compactTransportMessage(pikminMessage))")
                    await pause(0.12)
                }
            }
            guard pikminOK else {
                throw LoopError("phase=final-tail-refresh-pikmin • AppService foreground failed • \(pikminMessage)")
            }

            var freshBudget: Double?
            let budgetDeadline = Date().addingTimeInterval(0.90)
            while Date() < budgetDeadline {
                if let value = finiteBackgroundSeconds() {
                    freshBudget = value
                    break
                }
                await pause(0.04)
            }

            if let freshBudget, freshBudget >= freshWindowMinimum {
                backgroundRecoveryPending = false
                emit(String(format: "ROUND %d • FINAL TAIL renewal AppService ✅ • window=%d/2 • fresh-background=%.1fs", round, windowAttempt, freshBudget))
                await pause(0.18)
                return
            }

            let label = freshBudget.map { String(format: "%.1fs", $0) } ?? backgroundBudgetLabel()
            lastFailure = "fresh background window=\(label)"
            emit("ROUND \(round) • FINAL TAIL renewal window rejected ⚠️ • window=\(windowAttempt)/2 • background=\(label) • re-prime=\(windowAttempt < 2 ? "YES" : "NO")")
        }

        throw LoopError("phase=final-tail-refresh-window • unable to obtain fresh finite background window • \(lastFailure)")
    }

    /// 11.5.4.21: after the atomic Runner boundary, transport/lifecycle errors
    /// must never turn target=10 completed=3 into FAILED. GO may already have
    /// happened, so recovery is deliberately no-replay: keep rebuilding the
    /// foreground/background/screenshot path until game state proves the list.
    private func completeRunnerHandoffContinuously(
        engine: IDeviceEngine,
        round: Int
    ) async throws {
        var recovery = 0
        while true {
            try checkCancelled()
            do {
                try await completeRunnerHandoff(engine: engine, round: round)
                if recovery > 0 {
                    emit("ROUND \(round) • POST-TAIL CONTINUOUS RECOVERY ✅ • recoveries=\(recovery) • committed state reconciled")
                }
                return
            } catch {
                if cancelled || Task.isCancelled { throw error }
                recovery += 1
                gameplayForegroundLock = true
                backgroundRecoveryPending = true
                emit("ROUND \(round) • POST-TAIL RECOVERY HOLD ⚠️ • recovery=\(recovery) • completed=\(completedDispatches) unchanged • GO-REPLAY=FORBIDDEN • \(compactTransportMessage(error.localizedDescription))")
                setPhase("第 \(round) 輪狀態復原中")
                await pause(min(1.50, 0.22 + Double(recovery % 6) * 0.20))
            }
        }
    }

    private func completeRunnerHandoff(
        engine: IDeviceEngine,
        round: Int
    ) async throws {
        let handoffStartedAt = Date()
        if let handoffStartRemaining = finiteBackgroundSeconds() {
            emit(String(format: "ROUND %d • HANDOFF CHECK begin • appState=%@ • background=%.1fs", round, appStateLabel(), handoffStartRemaining))
        } else {
            emit("ROUND \(round) • HANDOFF CHECK begin • appState=\(appStateLabel()) • background=\(backgroundBudgetLabel())")
        }

        // 11.5.4.19: Runner's `pilot.activate()` is an observation made *inside*
        // the XCTest process. Field logs from both iPhone and iPad proved that
        // Pilot can be foreground there, then be background again by the time
        // execute-test-plan returns to this process. Do not spend several seconds
        // passively waiting in background. If Pilot is not active at return, use
        // the already-proven CoreDevice AppService path immediately and make the
        // host foreground state authoritative before any next operation.
        let recoveryUsed = try await ensurePilotForegroundAfterTail(
            engine: engine,
            round: round,
            context: "runner-handoff"
        )

        let handoffElapsed = Date().timeIntervalSince(handoffStartedAt)
        if let handoffEndRemaining = finiteBackgroundSeconds() {
            emit(String(format: "ROUND %d • HANDOFF ACTIVE ✅ • mode=%@ • wait=%.2fs • background=%.1fs", round, recoveryUsed ? "APP-SERVICE-RECOVERY" : "RUNNER-DIRECT", handoffElapsed, handoffEndRemaining))
        } else {
            emit(String(format: "ROUND %d • HANDOFF ACTIVE ✅ • mode=%@ • wait=%.2fs • background=%@", round, recoveryUsed ? "APP-SERVICE-RECOVERY" : "RUNNER-DIRECT", handoffElapsed, backgroundBudgetLabel()))
        }

        if backgroundExpiredDuringCriticalTail {
            emit("ROUND \(round) • Runner tail finished after old background window expired • state preserved • second green-X ACK pending")
        } else {
            emit("ROUND \(round) • Runner→Pilot handoff reconciled • second green-X ACK pending")
        }

        // Establish a verified finite post-tail window, then foreground Pikmin
        // with AppService only. This avoids launching another full XCTest plan
        // merely to restore foreground, and is shared by iPhone/iPad because the
        // handoff race is now observed on both device families.
        try await preparePostTailExecutionWindow(
            engine: engine,
            round: round,
            reason: "initial"
        )

        try await verifyCarryingCloseAfterRunnerHandoff(engine: engine, round: round)

        // Only a positively verified expedition-list return releases the lock.
        gameplayForegroundLock = false
        emit("ROUND \(round) • GREEN-X DOUBLE-ACK ✅ • expedition list verified • foreground lock released")
    }

    /// Make Pilot's *current* foreground state authoritative after an XCTest tail.
    /// Returns true when AppService recovery was required.
    private func ensurePilotForegroundAfterTail(
        engine: IDeviceEngine,
        round: Int,
        context: String
    ) async throws -> Bool {
        try checkCancelled()
        if UIApplication.shared.applicationState == .active {
            return false
        }

        guard let pilotBundleID = Bundle.main.bundleIdentifier, !pilotBundleID.isEmpty else {
            throw LoopError("phase=\(context)-pilot-foreground • Pilot bundle identifier unavailable")
        }

        emit("ROUND \(round) • HANDOFF DIRECT MISS ⚠️ • appState=\(appStateLabel()) • immediately foregrounding Pilot via AppService")

        let maxAttempts = 3
        var lastMessage = "unknown AppService foreground failure"
        for attempt in 1...maxAttempts {
            try checkCancelled()
            let result = await engine.launchBundleID(pilotBundleID)
            try checkCancelled()
            lastMessage = result.message

            if result.ok {
                // Use a wall-clock deadline rather than assuming Task.sleep is
                // scheduled precisely while the process is backgrounded.
                let deadline = Date().addingTimeInterval(isIPadDevice ? 2.4 : 1.6)
                while Date() < deadline {
                    if UIApplication.shared.applicationState == .active {
                        if attempt > 1 {
                            emit("ROUND \(round) • HANDOFF RECOVERED ✅ • Pilot AppService attempt \(attempt)/\(maxAttempts)")
                        } else {
                            emit("ROUND \(round) • HANDOFF RECOVERED ✅ • Pilot foregrounded by AppService")
                        }
                        return true
                    }
                    await pause(0.04)
                }
            }

            if attempt < maxAttempts {
                emit("ROUND \(round) • HANDOFF RECOVERY retry ⚠️ • attempt=\(attempt)/\(maxAttempts) • appState=\(appStateLabel()) • \(compactTransportMessage(lastMessage))")
                await pause(0.12)
            }
        }

        throw LoopError("phase=\(context)-pilot-foreground • AppService could not restore Pilot foreground after \(maxAttempts) attempts • \(lastMessage)")
    }

    /// Re-arm the only background window used by the host-side post-tail ACK.
    /// If iOS grants an unusably short window, return Pilot to foreground and
    /// try again instead of entering DVT/XCTest work that is likely to suspend.
    private func preparePostTailExecutionWindow(
        engine: IDeviceEngine,
        round: Int,
        reason: String
    ) async throws {
        let maxAttempts = isIPadDevice ? 3 : 2
        let minimumBudget = isIPadDevice ? 10.0 : 8.0

        for attempt in 1...maxAttempts {
            try checkCancelled()

            if UIApplication.shared.applicationState != .active {
                _ = try await ensurePilotForegroundAfterTail(
                    engine: engine,
                    round: round,
                    context: "post-tail-window-\(reason)"
                )
            }

            // iPadOS field behavior shows that a very short foreground bounce can
            // inherit/lose the previous finite task almost immediately. Give the
            // host a real foreground dwell before asking for the next window.
            if isIPadDevice {
                await pause(attempt == 1 ? 1.60 : 2.10)
            } else if attempt > 1 {
                await pause(0.30)
            }
            try checkCancelled()

            guard UIApplication.shared.applicationState == .active else {
                emit("ROUND \(round) • POST-TAIL WINDOW foreground unstable ⚠️ • reason=\(reason) • attempt=\(attempt)/\(maxAttempts)")
                continue
            }

            backgroundExpiredDuringCriticalTail = false
            beginBackgroundWindow(label: "post-tail-r\(round)-\(reason)-a\(attempt)")

            try await foregroundPikminForPostTail(
                engine: engine,
                round: round,
                reason: reason
            )
            try checkCancelled()

            // 11.5.4.23: after AppService foregrounds Pikmin there is a short
            // UIKit accounting transition where Pilot is already backgrounded and
            // the UIBackgroundTask is live, but backgroundTimeRemaining can still
            // report greatestFiniteMagnitude. 11.5.4.21 interpreted that transient
            // value as "no usable window", foregrounded Pilot again, and created
            // the observed Pilot↔Pikmin ping-pong loop.
            //
            // Probe by observations rather than a 0.90s wall-clock deadline: a
            // single Task.sleep can itself be delayed while the app transitions to
            // background. If UIKit has not published a finite budget yet but the
            // app reached .background and our task identifier is still live, accept
            // the window provisionally and let the next screenshot/state check be
            // authoritative. A real expiration will invalidate backgroundTask and
            // set backgroundExpiredDuringCriticalTail.
            var remaining: Double?
            var observedBackgroundState = UIApplication.shared.applicationState == .background
            for probe in 0..<12 {
                if backgroundExpiredDuringCriticalTail { break }
                if UIApplication.shared.applicationState == .background {
                    observedBackgroundState = true
                }
                if let value = finiteBackgroundSeconds() {
                    remaining = value
                    break
                }
                if probe < 11 {
                    await pause(0.06)
                }
            }

            if !backgroundExpiredDuringCriticalTail,
               let remaining,
               remaining >= minimumBudget {
                backgroundRecoveryPending = false
                emit(String(format: "ROUND %d • POST-TAIL WINDOW READY ✅ • reason=%@ • attempt=%d/%d • background=%.1fs", round, reason, attempt, maxAttempts, remaining))
                return
            }

            // Do not bounce Pilot back to foreground merely because UIKit has not
            // converted "unlimited" to a finite number yet. This exact state was
            // observed in the field: the following loop iteration immediately saw
            // ~29.9s remaining. The live task + actual background state is enough
            // to continue into state reconciliation without replaying GO.
            if !backgroundExpiredDuringCriticalTail,
               remaining == nil,
               observedBackgroundState,
               backgroundTask != .invalid {
                backgroundRecoveryPending = false
                emit("ROUND \(round) • POST-TAIL WINDOW READY ✅ • reason=\(reason) • attempt=\(attempt)/\(maxAttempts) • background=pending-accounting • live-task=YES")
                return
            }

            let budget = remaining.map { String(format: "%.1fs", $0) } ?? backgroundBudgetLabel()
            emit("ROUND \(round) • POST-TAIL WINDOW rejected ⚠️ • reason=\(reason) • attempt=\(attempt)/\(maxAttempts) • appState=\(appStateLabel()) • background=\(budget) • live-task=\(backgroundTask != .invalid ? "YES" : "NO") • expired=\(backgroundExpiredDuringCriticalTail ? "YES" : "NO")")
        }

        throw LoopError("phase=post-tail-window • unable to obtain usable background execution window • reason=\(reason)")
    }

    /// Post-tail foreground restoration never needs a new XCTest session. A
    /// fresh AppService handle is cheaper and avoids the ~60s execute-test-plan
    /// timeout path entirely at this lifecycle boundary.
    private func foregroundPikminForPostTail(
        engine: IDeviceEngine,
        round: Int,
        reason: String
    ) async throws {
        let maxAttempts = 3
        var lastMessage = "unknown AppService foreground failure"

        for attempt in 1...maxAttempts {
            try checkCancelled()
            let result = await engine.launchBundleID("com.nianticlabs.pikmin")
            try checkCancelled()
            lastMessage = result.message
            if result.ok {
                if attempt > 1 {
                    emit("ROUND \(round) • POST-TAIL PIKMIN FOREGROUND RECOVERED ✅ • reason=\(reason) • attempt=\(attempt)/\(maxAttempts)")
                } else {
                    emit("ROUND \(round) • POST-TAIL PIKMIN FOREGROUND ✅ • reason=\(reason) • AppService")
                }
                return
            }

            if attempt < maxAttempts {
                emit("ROUND \(round) • POST-TAIL PIKMIN FOREGROUND transient miss ⚠️ • reason=\(reason) • attempt=\(attempt)/\(maxAttempts) • \(compactTransportMessage(lastMessage))")
                await pause(0.14)
            }
        }

        throw LoopError("phase=post-tail-pikmin-foreground • AppService failed after \(maxAttempts) attempts • \(lastMessage)")
    }

    private func ensurePostTailACKBudget(
        engine: IDeviceEngine,
        round: Int,
        reason: String,
        minimumRemaining: Double
    ) async throws {
        let needsRearm: Bool
        if backgroundExpiredDuringCriticalTail {
            needsRearm = true
        } else if UIApplication.shared.applicationState == .active {
            needsRearm = true
        } else if let remaining = finiteBackgroundSeconds() {
            needsRearm = remaining < minimumRemaining
        } else if UIApplication.shared.applicationState == .background,
                  backgroundTask != .invalid {
            // 11.5.4.23: UIKit can briefly leave backgroundTimeRemaining at the
            // unlimited sentinel after AppService switches Pikmin foreground. A
            // live UIBackgroundTask in an actual .background host is provisional
            // execution authority; do not re-foreground Pilot and create a loop.
            needsRearm = false
        } else {
            needsRearm = true
        }

        guard needsRearm else { return }
        emit("ROUND \(round) • POST-TAIL ACK re-arm ⚠️ • reason=\(reason) • appState=\(appStateLabel()) • background=\(backgroundBudgetLabel())")
        try await preparePostTailExecutionWindow(
            engine: engine,
            round: round,
            reason: reason
        )
    }

    private func verifyCarryingCloseAfterRunnerHandoff(
        engine: IDeviceEngine,
        round: Int
    ) async throws {
        setPhase("確認綠色 X 已關閉")
        await pause(fastMode ? 0.12 : 0.20)

        var closeTapAttempts = 0
        var listReadyStreak = 0
        var noCloseFrames = 0
        var recoveryCount = 0
        let maxCloseTapAttempts = 6
        let maxFrames = 30
        let maxRecoveries = 6

        for frameIndex in 0..<maxFrames {
            try checkCancelled()

            try await ensurePostTailACKBudget(
                engine: engine,
                round: round,
                reason: "ack-frame-\(frameIndex + 1)",
                minimumRemaining: isIPadDevice ? 7.0 : 6.0
            )

            let image: UIImage
            do {
                image = try await capture(engine: engine, tag: "post-tail-green-x-ack")
            } catch {
                let message = error.localizedDescription
                if recoveryCount < maxRecoveries &&
                    (backgroundExpiredDuringCriticalTail || isTransientTransportFailure(message)) {
                    recoveryCount += 1
                    emit("ROUND \(round) • POST-TAIL SCREENSHOT state-recovery ⚠️ • recovery=\(recoveryCount)/\(maxRecoveries) • \(compactTransportMessage(message))")
                    try await preparePostTailExecutionWindow(
                        engine: engine,
                        round: round,
                        reason: "screenshot-recovery-\(recoveryCount)"
                    )
                    continue
                }
                throw error
            }
            screenshotSink?(image)
            emit("ROUND \(round) • POST-TAIL ACK frame=\(frameIndex + 1)/\(maxFrames) captured • background=\(backgroundBudgetLabel())")

            // iPhone keeps the proven detector unchanged. iPad uses the
            // resolution-independent white-X-first validator added in 11.5.4.19
            // patch work; the global detector remains untouched.
            var closePoint = isIPadDevice
                ? detectIPadCarryingCloseGlyph(in: image)
                : ImageAutomationDetector.detectCarryingClose(in: image)
            var listEvidence = false

            if closePoint == nil {
                let detection = await FruitDetector.detect(in: image)
                listEvidence = !detection.fruits.isEmpty ||
                    !detection.seedlings.isEmpty ||
                    !detection.cards.isEmpty ||
                    !detection.blockedObjects.isEmpty

                if !isIPadDevice,
                   !listEvidence,
                   frameIndex >= 2,
                   let broad = ImageAutomationDetector.detectCarryingCloseBroad(in: image),
                   let cg = image.cgImage {
                    let nx = Double(broad.x) / Double(cg.width)
                    let ny = Double(broad.y) / Double(cg.height)
                    if nx <= 0.30 && ny >= 0.65 {
                        closePoint = broad
                        emit("ROUND \(round) • POST-TAIL ACK broad lower-left X recovery candidate")
                    }
                }
            }

            if let closePoint {
                listReadyStreak = 0
                noCloseFrames = 0

                guard closeTapAttempts < maxCloseTapAttempts else {
                    throw LoopError("Round \(round): green X still visible after \(maxCloseTapAttempts) host-side verified retry taps")
                }

                // A generic tap still uses XCTest, so make sure we have enough
                // host budget before entering it. If the command times out after
                // the physical tap already happened, do NOT replay blindly: the
                // next screenshot decides whether X is still present.
                try await ensurePostTailACKBudget(
                    engine: engine,
                    round: round,
                    reason: "pre-close-tap-\(closeTapAttempts + 1)",
                    minimumRemaining: isIPadDevice ? 20.0 : 12.0
                )

                guard let cg = image.cgImage else {
                    throw LoopError("phase=post-tail-green-x-retry • screenshot has no CGImage")
                }
                let x = Double(closePoint.x) / Double(cg.width)
                let y = Double(closePoint.y) / Double(cg.height)
                guard (0...1).contains(x), (0...1).contains(y) else {
                    throw LoopError("phase=post-tail-green-x-retry • invalid normalized tap (\(x),\(y))")
                }

                closeTapAttempts += 1
                if isIPadDevice {
                    emit(String(format: "ROUND %d • POST-TAIL ACK green X visible ⚠️ • retry tap %d/%d • point=(%.4f,%.4f) • bounded-xctest=12s", round, closeTapAttempts, maxCloseTapAttempts, x, y))
                } else {
                    emit(String(format: "ROUND %d • POST-TAIL ACK green X visible ⚠️ • retry tap %d/%d • point=(%.4f,%.4f)", round, closeTapAttempts, maxCloseTapAttempts, x, y))
                }
                let tapResult: IDeviceEngine.Result
                if isIPadDevice {
                    tapResult = await engine.runXCTestTapBounded(
                        normalizedX: x,
                        normalizedY: y,
                        timeoutSeconds: 12
                    )
                } else {
                    // Preserve the proven iPhone tap path byte-for-byte.
                    tapResult = await engine.runXCTestTap(normalizedX: x, normalizedY: y)
                }
                try checkCancelled()

                if !tapResult.ok {
                    if isTransientTransportFailure(tapResult.message), recoveryCount < maxRecoveries {
                        recoveryCount += 1
                        emit("ROUND \(round) • POST-TAIL TAP transient failure ⚠️ • state reconcile instead of replay • recovery=\(recoveryCount)/\(maxRecoveries) • \(compactTransportMessage(tapResult.message))")
                        try await preparePostTailExecutionWindow(
                            engine: engine,
                            round: round,
                            reason: "tap-reconcile-\(recoveryCount)"
                        )
                        continue
                    }
                    throw LoopError("phase=post-tail-green-x-retry-tap • \(tapResult.message)")
                }

                await pause(fastMode ? 0.15 : 0.24)
                continue
            }

            noCloseFrames += 1
            if listEvidence {
                listReadyStreak += 1
                if listReadyStreak >= 2 {
                    emit("ROUND \(round) • POST-TAIL ACK list confirmed on 2 consecutive frames • retryTaps=\(closeTapAttempts) • recoveries=\(recoveryCount)")
                    return
                }
            } else {
                listReadyStreak = 0
            }

            if frameIndex == 2 || frameIndex == 7 || frameIndex == 15 || frameIndex == 23 {
                emit("ROUND \(round) • POST-TAIL ACK waiting • no-green-X-frames=\(noCloseFrames) • list-streak=\(listReadyStreak) • recoveries=\(recoveryCount)")
            }
            await pause(fastMode ? 0.12 : 0.22)
        }

        throw LoopError("Round \(round): post-tail verification could not prove expedition-list return; completed count NOT incremented")
    }

    /// iPad-only post-tail Green-X detector. The legacy detector is intentionally
    /// left untouched for iPhone. This detector starts from the white X glyph,
    /// then proves that the glyph is surrounded by a dark-green circular control.
    /// Every threshold is relative to the active game viewport or to the glyph
    /// itself; there are no iPad-model or fixed-resolution pixel coordinates.
    private func detectIPadCarryingCloseGlyph(in image: UIImage) -> CGPoint? {
        guard isIPadDevice,
              let (w, h, data) = FruitDetector.rawPixels(image),
              w > 0, h > 0
        else {
            return nil
        }

        let viewport = ImageAutomationDetector.activeContentRect(in: image)
        guard viewport.width > 1, viewport.height > 1 else { return nil }

        // Carrying close is a lower-left overlay control. Keep the ROI broad
        // enough for different iPad aspect ratios while excluding most flowers,
        // status text and central gameplay art.
        let x0 = max(0, Int(floor(viewport.minX)))
        let x1 = min(w, Int(ceil(viewport.minX + viewport.width * 0.30)))
        let y0 = max(0, Int(floor(viewport.minY + viewport.height * 0.74)))
        let y1 = min(h, Int(ceil(viewport.maxY)))
        guard x1 > x0, y1 > y0 else { return nil }

        let roiW = x1 - x0
        let roiH = y1 - y0
        var whiteMask = [Bool](repeating: false, count: roiW * roiH)

        // The glyph is near-white. A slightly relaxed threshold keeps
        // anti-aliased X edges connected across different screenshot scales.
        for y in y0..<y1 {
            for x in x0..<x1 {
                let value = FruitDetector.hsv(
                    FruitDetector.pixel(data, width: w, x: x, y: y)
                )
                if value.s <= 0.22 && value.v >= 0.80 {
                    whiteMask[(y - y0) * roiW + (x - x0)] = true
                }
            }
        }

        let viewportArea = max(1.0, Double(viewport.width * viewport.height))
        let shortEdge = max(1.0, min(viewport.width, viewport.height))
        var bestPoint: CGPoint?
        var bestScore = -Double.greatestFiniteMagnitude

        for (localRect, count) in ImageAutomationDetector.componentCenters(
            mask: whiteMask,
            width: roiW,
            height: roiH
        ) {
            let rect = localRect.offsetBy(dx: CGFloat(x0), dy: CGFloat(y0))
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let nx = (center.x - viewport.minX) / max(1, viewport.width)
            let ny = (center.y - viewport.minY) / max(1, viewport.height)

            // Position is only a broad UI-zone constraint, not a device-size
            // calibration. The real proof comes from the glyph/ring structure.
            guard nx >= 0.0, nx <= 0.30, ny >= 0.74, ny <= 1.0 else { continue }

            let wf = rect.width / max(1, viewport.width)
            let hf = rect.height / max(1, viewport.height)
            guard wf >= 0.008, wf <= 0.055,
                  hf >= 0.006, hf <= 0.055
            else { continue }

            let aspect = rect.width / max(1, rect.height)
            guard aspect >= 0.48, aspect <= 1.85 else { continue }

            let rectArea = max(1.0, Double(rect.width * rect.height))
            let fill = Double(count) / rectArea
            let areaFraction = Double(count) / viewportArea
            guard fill >= 0.12, fill <= 0.72,
                  areaFraction >= 0.000008, areaFraction <= 0.0010
            else { continue }

            // X topology check: both diagonals must carry a meaningful share of
            // the white pixels. This rejects round flower highlights and text.
            let rx0 = max(0, Int(floor(rect.minX)))
            let rx1 = min(w, Int(ceil(rect.maxX)))
            let ry0 = max(0, Int(floor(rect.minY)))
            let ry1 = min(h, Int(ceil(rect.maxY)))
            guard rx1 > rx0, ry1 > ry0 else { continue }

            var glyphWhite = 0
            var diagA = 0
            var diagB = 0
            for y in ry0..<ry1 {
                for x in rx0..<rx1 {
                    let value = FruitDetector.hsv(
                        FruitDetector.pixel(data, width: w, x: x, y: y)
                    )
                    guard value.s <= 0.22, value.v >= 0.80 else { continue }
                    glyphWhite += 1

                    let u = (Double(x) + 0.5 - Double(rect.minX)) / max(1.0, Double(rect.width))
                    let v = (Double(y) + 0.5 - Double(rect.minY)) / max(1.0, Double(rect.height))
                    if abs(v - u) <= 0.19 { diagA += 1 }
                    if abs(v - (1.0 - u)) <= 0.19 { diagB += 1 }
                }
            }
            guard glyphWhite > 0 else { continue }
            let diagAFraction = Double(diagA) / Double(glyphWhite)
            let diagBFraction = Double(diagB) / Double(glyphWhite)
            guard diagAFraction >= 0.34, diagBFraction >= 0.34 else { continue }

            // Prove that the white glyph sits inside a dark-green control. Ring
            // radius follows glyph size, with only a viewport-relative minimum.
            let glyphScale = max(rect.width, rect.height)
            let innerRadius = max(glyphScale * 0.62, shortEdge * 0.007)
            let outerRadius = max(glyphScale * 2.45, shortEdge * 0.045)
            let inner2 = innerRadius * innerRadius
            let outer2 = outerRadius * outerRadius
            let sx0 = max(0, Int(floor(center.x - outerRadius)))
            let sx1 = min(w - 1, Int(ceil(center.x + outerRadius)))
            let sy0 = max(0, Int(floor(center.y - outerRadius)))
            let sy1 = min(h - 1, Int(ceil(center.y + outerRadius)))
            guard sx1 >= sx0, sy1 >= sy0 else { continue }

            let sampleStep = max(1, Int(Double(shortEdge) / 900.0))
            var ringTotal = 0
            var darkGreen = 0
            for y in stride(from: sy0, through: sy1, by: sampleStep) {
                for x in stride(from: sx0, through: sx1, by: sampleStep) {
                    let dx = CGFloat(x) + 0.5 - center.x
                    let dy = CGFloat(y) + 0.5 - center.y
                    let d2 = dx * dx + dy * dy
                    guard d2 >= inner2, d2 <= outer2 else { continue }

                    let value = FruitDetector.hsv(
                        FruitDetector.pixel(data, width: w, x: x, y: y)
                    )
                    if value.h >= 105.0, value.h <= 205.0,
                       value.s >= 0.22,
                       value.v >= 0.14, value.v <= 0.92 {
                        darkGreen += 1
                    }
                    ringTotal += 1
                }
            }
            guard ringTotal > 0 else { continue }
            let darkGreenFraction = Double(darkGreen) / Double(ringTotal)
            guard darkGreenFraction >= 0.72 else { continue }

            // Structural evidence dominates. Normalized location is only a weak
            // tie-breaker so the algorithm remains portable across iPad sizes.
            let diagonalScore = min(diagAFraction, diagBFraction)
            let locationPenalty = Double(nx) * 0.08 + abs(Double(ny) - 0.91) * 0.05
            let score = darkGreenFraction * 2.0 + diagonalScore + fill * 0.20 - locationPenalty
            if score > bestScore {
                bestScore = score
                bestPoint = center
            }
        }

        return bestPoint
    }

    // MARK: - Detection / input helpers

    private func waitForCarryingClose(
        engine: IDeviceEngine,
        round: Int
    ) async throws -> (point: CGPoint, image: UIImage, mode: String)? {
        // Critical section: DO NOT foreground Pilot here. We just tapped GO and
        // must leave Pikmin untouched until the carrying overlay appears.
        // Stage 11.5 fails closed if the live green-X cannot be detected; it no
        // longer taps a coordinate calibrated from one specific phone.
        for index in 0..<8 {
            try checkCancelled()

            let image = try await capture(engine: engine, tag: "carrying-green-x")
            screenshotSink?(image)

            if let point = ImageAutomationDetector.detectCarryingClose(in: image) {
                return (point, image, "strict")
            }

            if index >= 2,
               let point = ImageAutomationDetector.detectCarryingCloseBroad(in: image) {
                emit("ROUND \(round) • carrying green X found by broad ROI")
                return (point, image, "broad")
            }

            if index == 0 || index == 2 || index == 5 {
                emit("ROUND \(round) • carrying green X adaptive scan attempt \(index + 1)/8")
            }
            await pause(0.34)
        }
        return nil
    }

    // MARK: - Stage 11.5.4.19 seedling detail OCR gate

    private func normalizedAutomationText(_ text: String) -> String {
        text
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\t", with: "")
            .lowercased()
    }

    private func isExpeditionCTAText(_ text: String) -> Bool {
        let t = normalizedAutomationText(text)
        return t.contains("前往探險") ||
            t.contains("前往探险") ||
            t.contains("gotoexpedition") ||
            t.contains("探検へ") ||
            t.contains("探險へ")
    }

    private func isSelectionHeaderText(_ text: String) -> Bool {
        let t = normalizedAutomationText(text)
        return t.contains("可以選擇最多") ||
            t.contains("可以选择最多") ||
            t.contains("選擇最多") ||
            t.contains("选择最多") ||
            t.contains("selectupto")
    }

    private func waitForSeedlingExpeditionCTA(
        engine: IDeviceEngine,
        round: Int
    ) async throws -> (point: CGPoint, image: UIImage)? {
        // Keep this deliberately short. The 11.5.4.14 18-frame gate could burn
        // the host's entire iOS background window before doing any useful action.
        for attempt in 0..<4 {
            try checkCancelled()
            let image = try await capture(engine: engine, tag: "seedling-expedition-ocr")
            screenshotSink?(image)
            let textItems = await FruitDetector.recognizeAllText(image: image)
            try checkCancelled()

            if let item = textItems.first(where: { isExpeditionCTAText($0.text) }) {
                let point = CGPoint(x: item.rect.midX, y: item.rect.midY)
                emit("ROUND \(round) • 前往探險 OCR found ✅ • text=\(item.text) • attempt=\(attempt + 1)/4")
                return (point, image)
            }

            if attempt == 0 || attempt == 2 {
                emit("ROUND \(round) • 前往探險 OCR waiting • attempt=\(attempt + 1)/4")
            }
            await pause(fastMode ? 0.18 : 0.28)
        }
        return nil
    }

    private func confirmPikminSelectionPage(
        engine: IDeviceEngine,
        round: Int
    ) async throws -> Bool {
        for attempt in 0..<4 {
            try checkCancelled()
            let image = try await capture(engine: engine, tag: "seedling-selection-confirm")
            screenshotSink?(image)

            let textItems = await FruitDetector.recognizeAllText(image: image)
            try checkCancelled()
            if let item = textItems.first(where: { isSelectionHeaderText($0.text) }) {
                emit("ROUND \(round) • selection confirmed ✅ • header=\(item.text)")
                return true
            }

            if attempt == 0 || attempt == 2 {
                emit("ROUND \(round) • selection confirmation waiting • attempt=\(attempt + 1)/4")
            }
            await pause(fastMode ? 0.16 : 0.24)
        }
        return false
    }

    private func waitForPoint(
        engine: IDeviceEngine,
        attempts: Int,
        delay: Double,
        stage: String,
        detector: (UIImage) -> CGPoint?
    ) async throws -> (point: CGPoint, image: UIImage)? {
        for index in 0..<attempts {
            try checkCancelled()
            if index % 4 == 0 {
                try await ensureBackgroundBudget(engine: engine, stage: stage)
            }

            let image = try await capture(engine: engine, tag: stage)
            screenshotSink?(image)
            if let point = detector(image) {
                return (point, image)
            }
            await pause(delay)
        }
        return nil
    }

    private func waitForExpeditionList(
        engine: IDeviceEngine,
        attempts: Int
    ) async throws -> Bool {
        for index in 0..<attempts {
            try checkCancelled()
            if index % 4 == 0 {
                try await ensureBackgroundBudget(engine: engine, stage: "return-list")
            }

            let image = try await capture(engine: engine, tag: "return-list")
            let result = await FruitDetector.detect(in: image)
            screenshotSink?(FruitDetector.annotated(image: image, result: result))

            if !result.fruits.isEmpty ||
                !result.seedlings.isEmpty ||
                !result.cards.isEmpty ||
                !result.blockedObjects.isEmpty {
                return true
            }
            await pause(0.40)
        }
        return false
    }

    private func capture(
        engine: IDeviceEngine,
        tag: String
    ) async throws -> UIImage {
        let safeTag = tag.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PikminPilot-Stage10.3-\(safeTag).png")
        let isPostTailACK = tag.hasPrefix("post-tail-green-x-ack")
        let maxAttempts = isPostTailACK ? (isIPadDevice ? 2 : 6) : 3
        var lastFailure = "unknown screenshot failure"

        for attempt in 1...maxAttempts {
            try checkCancelled()
            try? FileManager.default.removeItem(at: url)

            let result: IDeviceEngine.Result
            if isPostTailACK && isIPadDevice {
                emit("POST-TAIL DVT CAPTURE begin • attempt=\(attempt)/\(maxAttempts) • watchdog=4500ms")
                result = await engine.takeScreenshotBounded(
                    outputPath: url.path,
                    timeoutMilliseconds: 4_500
                )
            } else {
                result = await engine.takeScreenshot(outputPath: url.path)
            }
            try checkCancelled()

            if result.ok,
               let data = try? Data(contentsOf: url),
               let image = UIImage(data: data),
               image.cgImage != nil {
                if attempt > 1 {
                    emit("DVT SCREENSHOT RECOVERED ✅ • tag=\(tag) • attempt=\(attempt)/\(maxAttempts)")
                }
                return image
            }

            lastFailure = result.ok ? "UIKit decode failed" : result.message
            let transient = isTransientTransportFailure(lastFailure)
            guard transient, attempt < maxAttempts else {
                throw LoopError("phase=dvt-screenshot/\(tag) • \(lastFailure)")
            }

            emit("DVT SCREENSHOT transient failure ⚠️ • tag=\(tag) • attempt=\(attempt)/\(maxAttempts) • retrying fresh channel • \(compactTransportMessage(lastFailure))")
            await pause(tag.hasPrefix("post-tail-green-x-ack") ? 0.30 : 0.18)
        }

        throw LoopError("phase=dvt-screenshot/\(tag) • \(lastFailure)")
    }

    private func tap(
        engine: IDeviceEngine,
        pixel: CGPoint,
        image: UIImage,
        stage: String,
        allowBackgroundRenewal: Bool = true
    ) async throws {
        try checkCancelled()
        if allowBackgroundRenewal {
            try await ensureBackgroundBudget(engine: engine, stage: stage)
        }

        guard let cg = image.cgImage else {
            throw LoopError("phase=\(stage) • screenshot has no CGImage")
        }
        let x = Double(pixel.x) / Double(cg.width)
        let y = Double(pixel.y) / Double(cg.height)
        guard (0...1).contains(x), (0...1).contains(y) else {
            throw LoopError("phase=\(stage) • invalid normalized tap (\(x),\(y))")
        }

        let result = await engine.runXCTestTap(normalizedX: x, normalizedY: y)
        try checkCancelled()
        guard result.ok else {
            throw LoopError("phase=\(stage)-tap • \(result.message)")
        }
    }

    private func swipeInContent(
        engine: IDeviceEngine,
        image: UIImage,
        fromX: Double,
        fromY: Double,
        toX: Double,
        toY: Double,
        duration: Double,
        stage: String
    ) async throws {
        guard let cg = image.cgImage else {
            throw LoopError("phase=\(stage) • screenshot has no CGImage for adaptive swipe")
        }
        let viewport = ImageAutomationDetector.activeContentRect(in: image)
        func normalized(_ x: Double, _ y: Double) -> (Double, Double) {
            let px = viewport.minX + viewport.width * x
            let py = viewport.minY + viewport.height * y
            return (
                min(1, max(0, px / Double(cg.width))),
                min(1, max(0, py / Double(cg.height)))
            )
        }
        let a = normalized(fromX, fromY)
        let b = normalized(toX, toY)
        try await swipe(
            engine: engine,
            fromX: a.0,
            fromY: a.1,
            toX: b.0,
            toY: b.1,
            duration: duration,
            stage: stage
        )
    }

    private func swipe(
        engine: IDeviceEngine,
        fromX: Double,
        fromY: Double,
        toX: Double,
        toY: Double,
        duration: Double,
        stage: String
    ) async throws {
        try checkCancelled()
        try await ensureBackgroundBudget(engine: engine, stage: stage)

        let result = await engine.runXCTestSwipe(
            fromX: fromX,
            fromY: fromY,
            toX: toX,
            toY: toY,
            duration: duration
        )
        try checkCancelled()
        guard result.ok else {
            throw LoopError("phase=\(stage)-swipe • \(result.message)")
        }
    }

    // MARK: - iOS finite-background renewal

    // Stage 11.5.4.19 controlled late renewal. This is intentionally separate
    // from ensureBackgroundBudget(): the normal foreground lock remains strict
    // everywhere else. Only a visually verified Pikmin selection page may open
    // this one renewal checkpoint.
    private func ensurePreCriticalTailBudget(
        engine: IDeviceEngine,
        round: Int
    ) async throws {
        var recovery = 0
        while true {
            try checkCancelled()
            guard UIApplication.shared.applicationState != .active else {
                emit("ROUND \(round) • PRE-TAIL BUDGET • Pilot already foreground; no background renewal required")
                return
            }

            if let before = finiteBackgroundSeconds() {
                emit(String(format: "ROUND %d • PRE-TAIL BUDGET check • %.1fs remaining • renew-below=26.0s", round, before))
                if before >= 26.0 && !backgroundRecoveryPending { return }
            }

            recovery += 1
            emit("ROUND \(round) • PRE-TAIL HOLD ⚠️ • safe selection checkpoint • GO NOT SENT • recovery=\(recovery)")

            let previousLock = gameplayForegroundLock
            gameplayForegroundLock = false
            do {
                try await refreshBackgroundWindowAppServiceOnly(
                    engine: engine,
                    reason: "pre-critical-tail-r\(round)-a\(recovery)",
                    round: round
                )
            } catch {
                gameplayForegroundLock = previousLock
                emit("ROUND \(round) • PRE-TAIL renewal retry ⚠️ • \(compactTransportMessage(error.localizedDescription)) • run continues")
                await pause(min(1.20, 0.25 + Double(recovery % 5) * 0.18))
                continue
            }
            gameplayForegroundLock = previousLock
            try checkCancelled()

            guard try await confirmPikminSelectionPage(engine: engine, round: round) else {
                emit("ROUND \(round) • PRE-TAIL checkpoint HOLD ⚠️ • selection page not yet confirmed after renewal • retrying same round")
                await pause(recovery % 4 == 0 ? 0.90 : 0.30)
                continue
            }

            if let after = finiteBackgroundSeconds() {
                emit(String(format: "ROUND %d • PRE-TAIL RENEWED ✅ • selection re-confirmed • background=%.1fs", round, after))
                if after >= 22.0 { return }
                emit(String(format: "ROUND %d • PRE-TAIL window still thin ⚠️ • %.1fs • retrying instead of FAILED", round, after))
                await pause(0.22)
                continue
            }

            emit("ROUND \(round) • PRE-TAIL RENEWED ✅ • selection re-confirmed • background=\(backgroundBudgetLabel())")
            return
        }
    }

    // Stage 11.5.4.19: DVT/XCTest channels are short-lived and can
    // occasionally close between commands even while the persistent RSD
    // Adapter itself is healthy. BrokenPipe/ConnectionReset/channel timeout are
    // therefore retried at safe/idempotent boundaries instead of aborting the
    // entire finite target immediately.
    private func isTransientTransportFailure(_ text: String) -> Bool {
        let lower = text.lowercased()
        let needles = [
            "brokenpipe",
            "broken pipe",
            "connectionreset",
            "connection reset",
            "remote server connection closed",
            "channel recv timeout",
            "xctesttimeout",
            "timedout",
            "timed out",
            "socket(custom"
        ]
        return needles.contains { lower.contains($0) }
    }

    private func compactTransportMessage(_ text: String) -> String {
        let oneLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        if oneLine.count <= 180 { return oneLine }
        return String(oneLine.prefix(177)) + "..."
    }

    private func finiteBackgroundSeconds() -> Double? {
        // UIKit returns Double.greatestFiniteMagnitude while the app is active.
        // `isFinite` alone is therefore not a useful test for a real finite
        // background window.
        guard UIApplication.shared.applicationState != .active else { return nil }
        let value = UIApplication.shared.backgroundTimeRemaining
        guard value.isFinite, value >= 0, value < 86_400 else { return nil }
        return value
    }

    private func backgroundBudgetLabel() -> String {
        if UIApplication.shared.applicationState == .active {
            return "foreground/unlimited"
        }
        if let value = finiteBackgroundSeconds() {
            return String(format: "%.1fs", value)
        }
        return "unbounded/unknown"
    }

    private func reactivatePikminWithRecovery(
        engine: IDeviceEngine,
        stage: String,
        round: Int?,
        allowIPadXCTestFallback: Bool = true
    ) async throws {
        try checkCancelled()

        let prefix = round.map { "ROUND \($0) • " } ?? ""

        // Stage 11.5.4.19 iPad foreground recovery:
        // On iPadOS the XCTest activate-only path can occasionally block for
        // nearly its full ~60s timeout. For foreground restoration we do not
        // need a new XCTest command; AppService can foreground the already
        // running Pikmin process. Prefer that on iPad and keep the proven
        // XCTest-first path on iPhone.
        if isIPadDevice {
            emit("\(prefix)IPAD FOREGROUND • AppService-first • stage=\(stage)")

            // Mid-run safe-boundary recovery must not turn a cheap foreground
            // correction into a ~60s execute-test-plan stall. Give AppService a
            // few fresh attempts first. Background-renewal/handoff call sites may
            // still opt into the legacy XCTest fallback via the default argument.
            let appServiceAttempts = allowIPadXCTestFallback ? 2 : 3
            var lastAppServiceMessage = "unknown AppService foreground failure"
            for attempt in 1...appServiceAttempts {
                let appService = await engine.launchBundleID("com.nianticlabs.pikmin")
                try checkCancelled()
                if appService.ok {
                    if attempt > 1 {
                        emit("\(prefix)IPAD FOREGROUND RECOVERED ✅ • AppService attempt \(attempt)/\(appServiceAttempts)")
                    } else {
                        emit("\(prefix)IPAD FOREGROUND ✅ • AppService foregrounded Pikmin")
                    }
                    await pause(0.25)
                    return
                }

                lastAppServiceMessage = appService.message
                if attempt < appServiceAttempts {
                    emit("\(prefix)IPAD FOREGROUND AppService transient miss ⚠️ • attempt \(attempt)/\(appServiceAttempts) • retrying • \(compactTransportMessage(appService.message))")
                    await pause(0.18)
                }
            }

            if !allowIPadXCTestFallback {
                emit("\(prefix)IPAD FOREGROUND AppService miss ⚠️ • XCTest fallback suppressed at safe mid-run recovery boundary • \(compactTransportMessage(lastAppServiceMessage))")
                throw LoopError("phase=\(stage) • iPad AppService foreground failed after \(appServiceAttempts) attempts; XCTest fallback intentionally suppressed • \(lastAppServiceMessage)")
            }

            emit("\(prefix)IPAD FOREGROUND AppService miss ⚠️ • falling back to XCTest activate • \(compactTransportMessage(lastAppServiceMessage))")
            let fallbackXCTest = await engine.runXCTestActivateOnly()
            try checkCancelled()
            guard fallbackXCTest.ok else {
                throw LoopError("phase=\(stage) • AppService failed: \(lastAppServiceMessage) • XCTest fallback failed: \(fallbackXCTest.message)")
            }
            emit("\(prefix)IPAD FOREGROUND RECOVERED ✅ • XCTest fallback")
            await pause(0.25)
            return
        }

        let primary = await engine.runXCTestActivateOnly()
        try checkCancelled()
        if primary.ok { return }

        guard isTransientTransportFailure(primary.message) else {
            throw LoopError("phase=\(stage) • \(primary.message)")
        }

        emit("\(prefix)PIKMIN ACTIVATE transient XCTest failure ⚠️ • using AppService foreground fallback • \(compactTransportMessage(primary.message))")

        let fallback = await engine.launchBundleID("com.nianticlabs.pikmin")
        try checkCancelled()
        guard fallback.ok else {
            throw LoopError("phase=\(stage)-fallback • XCTest activate failed: \(primary.message) • AppService fallback failed: \(fallback.message)")
        }

        emit("\(prefix)PIKMIN ACTIVATE RECOVERED ✅ • AppService foreground fallback")
        await pause(0.35)
    }

    private func appStateLabel() -> String {
        switch UIApplication.shared.applicationState {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }

    private func ensureBackgroundBudget(
        engine: IDeviceEngine,
        stage: String,
        minimumRemaining: Double = 20.0
    ) async throws {
        guard UIApplication.shared.applicationState != .active else {
            backgroundRecoveryPending = false
            return
        }

        let remaining = UIApplication.shared.backgroundTimeRemaining
        if gameplayForegroundLock {
            if backgroundRecoveryPending || (remaining.isFinite && remaining < minimumRemaining) {
                let label = finiteBackgroundSeconds().map { String(format: "%.1fs", $0) } ?? backgroundBudgetLabel()
                emit("FOREGROUND LOCK • \(label) at \(stage) • recovery deferred until green-X/list checkpoint")
            }
            return
        }

        if backgroundRecoveryPending || !remaining.isFinite || remaining < minimumRemaining {
            let label = finiteBackgroundSeconds().map { String(format: "%.1fs", $0) } ?? backgroundBudgetLabel()
            emit("BACKGROUND \(label) • recovery/renewal at \(stage) • CONTINUOUS=ON")
            try await refreshBackgroundWindow(engine: engine, reason: stage)
        }
    }

    /// Safe-boundary background renewal is continuous and AppService-only on
    /// both iPhone and iPad. It deliberately never creates an activate-only
    /// XCTest plan, so a cheap lifecycle correction cannot become a ~60s stall.
    private func refreshBackgroundWindow(
        engine: IDeviceEngine,
        reason: String
    ) async throws {
        try checkCancelled()
        renewalInProgress = true
        defer { renewalInProgress = false }

        guard let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty else {
            throw LoopError("Pilot bundle identifier unavailable for background renewal")
        }

        var cycle = 0
        while true {
            try checkCancelled()
            cycle += 1
            emit("BACKGROUND renewal begin • reason=\(reason) • cycle=\(cycle) • AppService-only")

            if let freeze = try? await capture(engine: engine, tag: "refresh-\(reason)") {
                screenshotSink?(freeze)
            }

            let foregroundPilot = await engine.launchBundleID(bundleID)
            try checkCancelled()
            guard foregroundPilot.ok else {
                emit("BACKGROUND renewal Pilot foreground miss ⚠️ • reason=\(reason) • cycle=\(cycle) • \(compactTransportMessage(foregroundPilot.message)) • retrying")
                await pause(min(1.20, 0.20 + Double(cycle % 5) * 0.18))
                continue
            }

            let deadline = Date().addingTimeInterval(isIPadDevice ? 2.4 : 1.6)
            var active = false
            while Date() < deadline {
                if UIApplication.shared.applicationState == .active {
                    active = true
                    break
                }
                await pause(0.04)
            }
            guard active else {
                emit("BACKGROUND renewal Pilot foreground unstable ⚠️ • reason=\(reason) • cycle=\(cycle) • retrying")
                await pause(0.28)
                continue
            }

            await pause(isIPadDevice ? 0.85 : 0.30)
            try checkCancelled()
            beginBackgroundWindow(label: "renew-\(reason)-c\(cycle)")

            let pikmin = await engine.launchBundleID("com.nianticlabs.pikmin")
            try checkCancelled()
            guard pikmin.ok else {
                backgroundRecoveryPending = true
                emit("BACKGROUND renewal Pikmin foreground miss ⚠️ • reason=\(reason) • cycle=\(cycle) • \(compactTransportMessage(pikmin.message)) • retrying")
                await pause(0.30)
                continue
            }

            var fresh: Double?
            let budgetDeadline = Date().addingTimeInterval(0.80)
            while Date() < budgetDeadline {
                if let value = finiteBackgroundSeconds() {
                    fresh = value
                    break
                }
                await pause(0.04)
            }

            if let fresh, fresh < 6.0 {
                backgroundRecoveryPending = true
                emit(String(format: "BACKGROUND renewal window rejected ⚠️ • reason=%@ • cycle=%d • %.1fs • retrying", reason, cycle, fresh))
                await pause(0.30)
                continue
            }

            backgroundRecoveryPending = false
            if let fresh {
                emit(String(format: "BACKGROUND renewed ✅ • reason=%@ • cycle=%d • fresh=%.1fs • AppService-only", reason, cycle, fresh))
            } else {
                emit("BACKGROUND renewed ✅ • reason=\(reason) • cycle=\(cycle) • background=\(backgroundBudgetLabel()) • AppService-only")
            }
            await pause(0.22)
            return
        }
    }

    /// Safe recovery boundaries never need a full XCTest activate. Keep trying
    /// the lightweight AppService foreground path until it succeeds or the user
    /// explicitly stops the run.
    private func foregroundPikminContinuously(
        engine: IDeviceEngine,
        stage: String,
        round: Int?
    ) async throws {
        let prefix = round.map { "ROUND \($0) • " } ?? ""
        var attempt = 0
        while true {
            try checkCancelled()
            attempt += 1
            let result = await engine.launchBundleID("com.nianticlabs.pikmin")
            try checkCancelled()
            if result.ok {
                if attempt > 1 {
                    emit("\(prefix)PIKMIN FOREGROUND RECOVERED ✅ • stage=\(stage) • AppService attempt=\(attempt)")
                }
                await pause(0.25)
                return
            }

            emit("\(prefix)PIKMIN FOREGROUND HOLD ⚠️ • stage=\(stage) • AppService attempt=\(attempt) • \(compactTransportMessage(result.message)) • run continues")
            await pause(min(1.20, 0.20 + Double(attempt % 5) * 0.18))
        }
    }

    private func stopLine() -> String {
        switch stopCause {
        case .userAfterCurrent:
            return "STOPPED AFTER CURRENT • completed=\(completedDispatches)"
        case .userImmediate:
            return "STOPPED NOW • completed=\(completedDispatches) • phase=\(currentPhase)"
        case .targetReached:
            let requested = targetDispatches.map(String.init) ?? "∞"
            return "COMPLETED • requested=\(requested) • completed=\(completedDispatches)"
        case .backgroundExpired:
            return "STOPPED • reason=iOS-background-expired • completed=\(completedDispatches)"
        case .none:
            return "STOPPED • reason=cancelled • completed=\(completedDispatches)"
        }
    }

    private func checkCancelled() throws {
        if cancelled || Task.isCancelled {
            throw LoopError("cancelled")
        }
    }
}

private struct LoopError: LocalizedError {
    let detail: String

    init(_ detail: String) {
        self.detail = detail
    }

    var errorDescription: String? { detail }
}
