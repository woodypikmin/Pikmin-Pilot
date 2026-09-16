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
    // Stage 11.5.4.14: once a dispatch has left the expedition list, Pilot is
    // forbidden from foregrounding itself until Runner has positively closed
    // the carrying green X and hands control back. This prevents a background
    // renewal/checkpoint from stealing foreground before the close tap.
    private var gameplayForegroundLock = false
    private var backgroundExpiredDuringCriticalTail = false
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
        emit("STAGE 11.5.4.14 PILOT RUN START • baseline=11.5.3 • automation-core=10.3.1 • transportHost=\(host):49152 • target=\(goal) • cargo=\(self.cargoMode.displayName) • pikmin=\(self.pikminType.shortName)×\(self.pikminCount) • speed=\(self.fastMode ? "FAST" : "STABLE") • Stage 8.2.2 stable loop core • WDA=OFF")

        worker = Task { [weak self] in
            guard let self else { return }
            await self.run(pairingPath: pairingPath, host: host)
        }
    }

    // Stage 11.5.4.14: run the same verified 10.3.1 automation core on an
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
        emit("STAGE 11.5.4.14 PERSISTENT CELLULAR RUN START • automation-core=10.3.1 • transport=\(transportLabel) • target=\(goal) • cargo=\(self.cargoMode.displayName) • pikmin=\(self.pikminType.shortName)×\(self.pikminCount) • speed=\(self.fastMode ? "FAST" : "STABLE") • RPPairing-reconnect=DISABLED")

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

                    if self.criticalTailInProgress || self.gameplayForegroundLock {
                        // Never steal foreground from Pikmin while a dispatch is in
                        // its selection/GO/carrying-close critical region. Runner
                        // owns that foreground until the green X is positively closed.
                        self.backgroundExpiredDuringCriticalTail = true
                        self.emit("BACKGROUND WINDOW EXPIRED DURING FOREGROUND-LOCK • deferring recovery until verified Runner→Pilot handoff")
                        return
                    }

                    if self.renewalInProgress {
                        self.emit("BACKGROUND expiration arrived during renewal • task ended; renewal continues")
                        return
                    }
                    self.stopCause = .backgroundExpired
                    self.cancelled = true
                    self.setPhase("背景時間已到")
                    self.emit("BACKGROUND WINDOW EXPIRED • iOS background limit ended this run")
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

                    // Stage 11.5.4.14 HARD COUNT LATCH: a finite target is a
                    // contract, not a best-effort loop. A detector/list refresh
                    // miss is recoverable and MUST NOT end a 5/5 (or N/N) run.
                    // Stay on the same round until an item appears, the user
                    // stops the run, or an actual XCTest/transport error occurs.
                    if targetDispatches != nil {
                        setPhase("暫時找不到項目，保持第 \(round) 輪")
                        emit("ROUND \(round) RETRY • requested=\(requested) • completed=\(completedDispatches) • no safe AVAILABLE after full scan • retry=\(consecutiveEmptyFullScans) • TARGET-LATCH=HOLD • COMPLETE=NO")

                        let reactivate = await engine.runXCTestActivateOnly()
                        if !reactivate.ok {
                            throw LoopError("Round \(round): retry reactivate failed • \(reactivate.message)")
                        }

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
                    let reactivate = await engine.runXCTestActivateOnly()
                    if !reactivate.ok {
                        throw LoopError("Round \(round): list soft-recovery reactivate failed • \(reactivate.message)")
                    }
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
        try await ensureBackgroundBudget(
            engine: engine,
            stage: "pre-dispatch-safe-boundary",
            minimumRemaining: 22.0
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
        emit("ROUND \(round) • detect 前往探險 • strict CTA geometry + selection-page gate")
        guard try await enterPikminSelectionPage(engine: engine, round: round) else {
            throw LoopError("Round \(round): 前往探險/selection transition not verified • no filter-row swipe sent")
        }
        try checkCancelled()

        // Stage 11.5.4.14 FOREGROUND LOCK: do NOT foreground Pikmin Pilot here.
        // 11.5.4.9 could renew/checkpoint Pilot between the expedition detail and
        // the carrying-close tail, which occasionally stole foreground before X.
        // The background budget was renewed at the safe list boundary above.
        setPhase("辨識\(pikminType.displayName)皮克敏")
        emit("ROUND \(round) • selection page stable • detect \(pikminType.shortName) filter on fresh foreground-locked frame")
        await pause(fastMode ? 0.18 : 0.28)
        try checkCancelled()

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

        var filterFound: (point: CGPoint, image: UIImage)?
        for attempt in 0...4 {
            try checkCancelled()
            try await ensureBackgroundBudget(engine: engine, stage: "pikmin-filter")

            let image = try await capture(engine: engine, tag: "pikmin-filter-fresh")
            screenshotSink?(image)
            if let point = ImageAutomationDetector.detectPikminFilter(type: pikminType, in: image) {
                filterFound = (point, image)
                emit("ROUND \(round) • \(pikminType.shortName) filter detected on fresh frame ✅")
                break
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

        guard let selectedFilter = filterFound else {
            throw LoopError("Round \(round): \(pikminType.shortName) filter not detected on fresh foreground-locked frame")
        }

        // Pass the coordinate from the *fresh* post-checkpoint screenshot into
        // the single Runner session. There is deliberately no Pilot foreground
        // bounce between this detection and dispatchtail.
        guard let filterCG = selectedFilter.image.cgImage else {
            throw LoopError("Round \(round): Pikmin filter screenshot has no CGImage")
        }
        let filterX = Double(selectedFilter.point.x) / Double(filterCG.width)
        let filterY = Double(selectedFilter.point.y) / Double(filterCG.height)

        setPhase("\(pikminType.shortName) → \(pikminCount) 隻 → GO → 關閉 X")
        emit(String(format: "ROUND %d • ONE XCTest critical tail begin • type=%@ • filter=(%.4f,%.4f) • select=%d→GO→greenX • speed=%@", round, pikminType.shortName, filterX, filterY, pikminCount, fastMode ? "FAST" : "STABLE"))

        let remaining = UIApplication.shared.backgroundTimeRemaining
        if remaining.isFinite {
            emit(String(format: "ROUND %d • fresh background budget before critical tail = %.1fs", round, remaining))
        }

        criticalTailInProgress = true
        backgroundExpiredDuringCriticalTail = false
        let tail = await engine.runXCTestDispatchTail(
            pikminX: filterX,
            pikminY: filterY,
            pikminCount: pikminCount,
            fastMode: fastMode
        )
        criticalTailInProgress = false

        guard tail.ok else {
            throw LoopError("phase=critical-tail • \(tail.message)")
        }

        // STOP NOW may have been requested while the already-dispatched atomic
        // Runner tail was in flight. The tail itself cannot be revoked reliably,
        // but after it returns we must not start the next handoff/reactivation.
        try checkCancelled()

        emit("ROUND \(round) • ONE XCTest critical tail completed ✅ • \(pikminType.shortName)→\(pikminCount)→GO→greenX")

        // Stage 8.2.2 Runner activates Pikmin Pilot after tapping the green X.
        // Accept that foreground handoff, start a fresh task, then reactivate
        // Pikmin for the next DVT fruit-list scan. This removes the dead zone
        // where Round 1 finished but Pilot was already suspended before Round 2.
        setPhase("回到探險列表")
        try await completeRunnerHandoff(engine: engine, round: round)
        await pause(fastMode ? 0.14 : 0.25)
    }


    private func completeRunnerHandoff(
        engine: IDeviceEngine,
        round: Int
    ) async throws {
        var active = UIApplication.shared.applicationState == .active
        if !active {
            for _ in 0..<60 {
                if UIApplication.shared.applicationState == .active {
                    active = true
                    break
                }
                await pause(0.05)
            }
        }

        guard active else {
            throw LoopError("phase=runner-handoff • verified Runner did not return Pilot foreground; leaving Pikmin Bloom visible for diagnosis")
        }

        // Stage 11.5.4.14 SECOND ACK: Runner 1153-xfix remains untouched.
        // Do not trust a single "X disappeared" observation as the final truth:
        // a transient detector miss inside Runner can otherwise foreground Pilot
        // even though the carrying X is still visible. Keep the foreground lock
        // until Pilot independently re-enters Pikmin and verifies the list.
        if backgroundExpiredDuringCriticalTail {
            emit("ROUND \(round) • Runner handoff recovered an expired background window; second green-X ACK pending")
        } else {
            emit("ROUND \(round) • Runner→Pilot handoff received • second green-X ACK pending")
        }

        // Pilot is foreground now, so refresh its finite background budget before
        // sending Pikmin back to foreground for the independent close check.
        beginBackgroundWindow(label: "post-tail-verify-r\(round)")
        backgroundExpiredDuringCriticalTail = false

        let reactivate = await engine.runXCTestActivateOnly()
        guard reactivate.ok else {
            throw LoopError("phase=runner-handoff-reactivate-pikmin • \(reactivate.message)")
        }

        try await verifyCarryingCloseAfterRunnerHandoff(engine: engine, round: round)

        // Only a positively verified expedition-list return releases the lock.
        gameplayForegroundLock = false
        emit("ROUND \(round) • GREEN-X DOUBLE-ACK ✅ • expedition list verified • foreground lock released")
    }

    private func verifyCarryingCloseAfterRunnerHandoff(
        engine: IDeviceEngine,
        round: Int
    ) async throws {
        setPhase("確認綠色 X 已關閉")
        await pause(fastMode ? 0.16 : 0.26)

        var closeTapAttempts = 0
        var listReadyStreak = 0
        var noCloseFrames = 0
        let maxCloseTapAttempts = 6
        let maxFrames = 30

        for frameIndex in 0..<maxFrames {
            try checkCancelled()

            let image = try await capture(engine: engine, tag: "post-tail-green-x-ack")
            screenshotSink?(image)

            // Prefer the calibrated strict detector. Never let the broad green
            // detector tap first on a real expedition-list frame, where unrelated
            // green objects may exist. The broad fallback is only allowed after
            // list detection also says this is NOT the list, and only inside the
            // lower-left carrying-control zone.
            var closePoint = ImageAutomationDetector.detectCarryingClose(in: image)
            var listEvidence = false

            if closePoint == nil {
                let detection = await FruitDetector.detect(in: image)
                listEvidence = !detection.fruits.isEmpty ||
                    !detection.seedlings.isEmpty ||
                    !detection.cards.isEmpty ||
                    !detection.blockedObjects.isEmpty

                if !listEvidence,
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

                closeTapAttempts += 1
                emit("ROUND \(round) • POST-TAIL ACK found green X still visible ⚠️ • retry tap \(closeTapAttempts)/\(maxCloseTapAttempts)")
                try await tap(
                    engine: engine,
                    pixel: closePoint,
                    image: image,
                    stage: "post-tail-green-x-retry",
                    allowBackgroundRenewal: false
                )
                await pause(fastMode ? 0.18 : 0.30)
                continue
            }

            noCloseFrames += 1
            if listEvidence {
                listReadyStreak += 1
                if listReadyStreak >= 2 {
                    emit("ROUND \(round) • POST-TAIL ACK list confirmed on 2 consecutive frames • retryTaps=\(closeTapAttempts)")
                    return
                }
            } else {
                listReadyStreak = 0
            }

            if frameIndex == 3 || frameIndex == 9 || frameIndex == 17 {
                emit("ROUND \(round) • POST-TAIL ACK waiting • no-green-X-frames=\(noCloseFrames) • list-streak=\(listReadyStreak)")
            }
            await pause(fastMode ? 0.16 : 0.28)
        }

        throw LoopError("Round \(round): post-tail verification could not prove expedition-list return; completed count NOT incremented")
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

    /// Stage 11.5.4.14 seedling-detail safety gate.
    ///
    /// We are not allowed to send the horizontal Pikmin-filter reveal swipe until
    /// two independent facts are true:
    /// 1) a button-shaped cyan/blue CTA was tapped, and
    /// 2) the next live frame visually looks like the Pikmin-selection page.
    ///
    /// This prevents ice-blue / huge seedling artwork from being mistaken for the
    /// CTA and eliminates the old "detail page keeps sliding sideways" failure.
    private func enterPikminSelectionPage(
        engine: IDeviceEngine,
        round: Int
    ) async throws -> Bool {
        var ctaTapAttempts = 0
        var visualMisses = 0

        for frameIndex in 0..<18 {
            try checkCancelled()
            if frameIndex % 4 == 0 {
                try await ensureBackgroundBudget(engine: engine, stage: "expedition-button")
            }

            let image = try await capture(engine: engine, tag: "expedition-detail-gate")
            screenshotSink?(image)
            try checkCancelled()

            // A previous tap may already have succeeded. Never tap the old detail
            // page again when the selection page is positively visible.
            if ImageAutomationDetector.isPikminSelectionPage(image) {
                emit("ROUND \(round) • SELECTION GATE ✅ • Pikmin selection page visually confirmed • CTA taps=\(ctaTapAttempts)")
                return true
            }

            if let point = ImageAutomationDetector.detectExpeditionButton(in: image),
               ctaTapAttempts < 3 {
                ctaTapAttempts += 1
                emit("ROUND \(round) • 前往探險 strict CTA found • tap \(ctaTapAttempts)/3")
                try await tap(
                    engine: engine,
                    pixel: point,
                    image: image,
                    stage: "expedition-button",
                    allowBackgroundRenewal: false
                )
                try checkCancelled()
                await pause(fastMode ? 0.62 : 0.90)
                try checkCancelled()
                continue
            }

            visualMisses += 1
            if frameIndex == 0 || frameIndex == 4 || frameIndex == 9 || frameIndex == 14 {
                emit("ROUND \(round) • 前往探險 strict CTA/selection gate waiting • frame=\(frameIndex + 1)/18 • ctaTaps=\(ctaTapAttempts) • misses=\(visualMisses)")
            }

            // Fail closed. This is intentionally a quiet wait only: no horizontal
            // gesture is permitted while the detail/selection state is uncertain.
            await pause(fastMode ? 0.22 : 0.32)
            try checkCancelled()
        }

        emit("ROUND \(round) • SELECTION GATE ❌ • no verified transition after strict CTA scan • horizontal filter-row swipe suppressed")
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
        try checkCancelled()
        let safeTag = tag.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PikminPilot-Stage10.3-\(safeTag).png")
        try? FileManager.default.removeItem(at: url)

        let result = await engine.takeScreenshot(outputPath: url.path)
        try checkCancelled()
        guard result.ok else {
            throw LoopError("phase=dvt-screenshot/\(tag) • \(result.message)")
        }
        guard
            let data = try? Data(contentsOf: url),
            let image = UIImage(data: data),
            image.cgImage != nil
        else {
            throw LoopError("phase=dvt-screenshot/\(tag) • UIKit decode failed")
        }
        return image
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

    private func ensureBackgroundBudget(
        engine: IDeviceEngine,
        stage: String,
        minimumRemaining: Double = 20.0
    ) async throws {
        guard UIApplication.shared.applicationState != .active else { return }

        let remaining = UIApplication.shared.backgroundTimeRemaining
        if gameplayForegroundLock {
            if remaining.isFinite && remaining < minimumRemaining {
                emit(String(format: "FOREGROUND LOCK • %.1fs left at %@ • Pilot renewal suppressed until green-X close", remaining, stage))
            }
            return
        }

        if remaining.isFinite && remaining < minimumRemaining {
            emit(String(format: "BACKGROUND %.1fs left • renewing at %@", remaining, stage))
            try await refreshBackgroundWindow(engine: engine, reason: stage)
        }
    }

    private func refreshBackgroundWindow(
        engine: IDeviceEngine,
        reason: String
    ) async throws {
        try checkCancelled()
        renewalInProgress = true
        defer { renewalInProgress = false }
        emit("BACKGROUND renewal begin • reason=\(reason)")

        guard let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty else {
            throw LoopError("Pilot bundle identifier unavailable for background renewal")
        }

        // Capture the current game frame for diagnostics immediately before the
        // renewal. The target itself is never terminated or relaunched.
        if let freeze = try? await capture(engine: engine, tag: "refresh-\(reason)") {
            screenshotSink?(freeze)
        }

        let foregroundPilot = await engine.launchBundleID(bundleID)
        guard foregroundPilot.ok else {
            throw LoopError("phase=background-refresh-pilot • \(foregroundPilot.message)")
        }

        var active = false
        for _ in 0..<60 {
            if UIApplication.shared.applicationState == .active {
                active = true
                break
            }
            await pause(0.05)
        }
        guard active else {
            throw LoopError("phase=background-refresh • Pikmin Pilot did not return foreground")
        }

        beginBackgroundWindow(label: "renew-\(reason)")

        let reactivate = await engine.runXCTestActivateOnly()
        guard reactivate.ok else {
            throw LoopError("phase=background-refresh-pikmin • \(reactivate.message)")
        }

        emit("BACKGROUND renewed ✅ • Pikmin re-activated without relaunch")
        await pause(0.30)
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
