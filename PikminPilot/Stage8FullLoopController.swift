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
    private var backgroundExpiredDuringCriticalTail = false
    private var logLines: [String] = []

    private var statusSink: ((String) -> Void)?
    private var screenshotSink: ((UIImage) -> Void)?

    func start(
        pairingPath: String,
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
        emit("STAGE 10.3 PILOT RUN START • target=\(goal) • cargo=\(self.cargoMode.displayName) • pikmin=\(self.pikminType.shortName)×\(self.pikminCount) • speed=\(self.fastMode ? "FAST" : "STABLE") • Stage 8.2.2 stable loop core • WDA=OFF")

        worker = Task { [weak self] in
            guard let self else { return }
            await self.run(pairingPath: pairingPath)
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
        emit("STOP NOW requested • cancelling worker • no new automation command will be started")
        worker?.cancel()
    }

    private func finish() {
        // Invalidate any queued expiration callback before ending the task.
        backgroundGeneration &+= 1
        renewalInProgress = false
        criticalTailInProgress = false
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

                    if self.criticalTailInProgress {
                        // The XCTest Runner is a separate process and can finish
                        // the GO -> green-X tail even if Pilot's finite window
                        // expires. The Runner will explicitly activate Pilot at
                        // the end of the tail, so do not mislabel this as a user
                        // stop or permanently cancel the loop.
                        self.backgroundExpiredDuringCriticalTail = true
                        self.emit("BACKGROUND WINDOW EXPIRED DURING CRITICAL TAIL • waiting for Runner→Pilot handoff")
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

    private func run(pairingPath: String) async {
        let engine = IDeviceEngine(pairingPath: pairingPath)

        do {
            setPhase("啟動 Pikmin")
            let activate = await engine.runXCTestActivateOnly()
            guard activate.ok else {
                throw LoopError("phase=initial-activate • \(activate.message)")
            }
            emit("Pikmin activate ✅")
            await pause(fastMode ? 0.28 : 0.45)

            while !cancelled {
                if let targetDispatches, completedDispatches >= targetDispatches {
                    stopCause = .targetReached
                    setPhase("已完成")
                    emit("COMPLETED • requested=\(targetDispatches) • completed=\(completedDispatches)")
                    finish()
                    return
                }

                let round = completedDispatches + 1
                setPhase("尋找\(cargoMode.scanDescription)")
                emit("ROUND \(round) • scanning Expedition list • cargo=\(cargoMode.displayName)")

                guard let choice = try await findAvailableCargo(
                    engine: engine,
                    round: round
                ) else {
                    setPhase("沒有可搬運項目")
                    let requested = targetDispatches.map(String.init) ?? "∞"
                    emit("FINISHED EARLY • requested=\(requested) • completed=\(completedDispatches) • no safe AVAILABLE \(cargoMode.displayName) found")
                    finish()
                    return
                }

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
                guard try await waitForExpeditionList(engine: engine, attempts: 20) else {
                    throw LoopError("Round \(round): Expedition list did not return after green X")
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
                    emit("COMPLETED • requested=\(targetDispatches) • completed=\(completedDispatches) • list=ready")
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
                try await swipe(
                    engine: engine,
                    fromX: 0.52,
                    fromY: 0.77,
                    toX: 0.52,
                    toY: 0.35,
                    duration: 0.42,
                    stage: "fruit-list-down"
                )
            } else {
                try await swipe(
                    engine: engine,
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
        emit("ROUND \(round) • detect 前往探險")
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
        await pause(fastMode ? 1.45 : 2.0)

        // Stage 8.2.2: refresh the finite background window BEFORE detecting
        // the selected Pikmin filter. In 8.2.1 we detected pink first, then foregrounded Pilot. When
        // Pikmin was activated again the selection screen could re-render, so
        // the saved filter coordinate became stale and Runner tapped whatever was
        // now under that old point. Do the foreground checkpoint first, return
        // to Pikmin, and only then obtain a fresh DVT frame + fresh filter point.
        setPhase("準備選擇\(pikminType.displayName)皮克敏")
        try await prepareCriticalTailWindow(engine: engine, round: round)

        setPhase("辨識\(pikminType.displayName)皮克敏")
        emit("ROUND \(round) • returned to selection page • detect \(pikminType.shortName) filter on fresh post-checkpoint frame")
        await pause(fastMode ? 0.18 : 0.28)

        emit("ROUND \(round) • reveal Pikmin filter row • target=\(pikminType.shortName)")
        try await swipe(
            engine: engine,
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
                try await swipe(
                    engine: engine,
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
            throw LoopError("Round \(round): \(pikminType.shortName) filter not detected on fresh post-checkpoint frame")
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


    private func prepareCriticalTailWindow(
        engine: IDeviceEngine,
        round: Int
    ) async throws {
        guard let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty else {
            throw LoopError("Pilot bundle identifier unavailable for critical-tail checkpoint")
        }

        emit("ROUND \(round) • foreground checkpoint before critical tail")
        let foregroundPilot = await engine.launchBundleID(bundleID)
        guard foregroundPilot.ok else {
            throw LoopError("phase=critical-tail-foreground-pilot • \(foregroundPilot.message)")
        }

        var active = false
        for _ in 0..<50 {
            if UIApplication.shared.applicationState == .active {
                active = true
                break
            }
            await pause(0.04)
        }
        guard active else {
            throw LoopError("phase=critical-tail-foreground-pilot • Pilot did not become active")
        }

        beginBackgroundWindow(label: "critical-tail-r\(round)")

        // Return to the already-running game now, before any Pikmin-filter detection.
        // This guarantees the DVT screenshot used for the filter coordinate is
        // from the exact screen state Runner will act on.
        let reactivate = await engine.runXCTestActivateOnly()
        guard reactivate.ok else {
            throw LoopError("phase=critical-tail-reactivate-pikmin • \(reactivate.message)")
        }
        emit("ROUND \(round) • fresh background task armed • Pikmin re-activated before Pikmin-filter detection ✅")
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

        // Fallback for an older Runner or a missed XCTest handoff. If this code
        // is executing, Pilot still has enough CPU to foreground itself via the
        // existing CoreDevice AppService path.
        if !active, let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty {
            let foregroundPilot = await engine.launchBundleID(bundleID)
            if foregroundPilot.ok {
                for _ in 0..<40 {
                    if UIApplication.shared.applicationState == .active {
                        active = true
                        break
                    }
                    await pause(0.05)
                }
            }
        }

        guard active else {
            throw LoopError("phase=runner-handoff • Pilot did not return foreground after green X")
        }

        if backgroundExpiredDuringCriticalTail {
            emit("ROUND \(round) • Runner handoff recovered an expired background window ✅")
        } else {
            emit("ROUND \(round) • Runner→Pilot foreground handoff ✅")
        }

        beginBackgroundWindow(label: "post-tail-r\(round)")
        backgroundExpiredDuringCriticalTail = false

        let reactivate = await engine.runXCTestActivateOnly()
        guard reactivate.ok else {
            throw LoopError("phase=runner-handoff-reactivate-pikmin • \(reactivate.message)")
        }
        emit("ROUND \(round) • Pikmin re-activated for next list scan ✅")
    }

    // MARK: - Detection / input helpers

    private func waitForCarryingClose(
        engine: IDeviceEngine,
        round: Int
    ) async throws -> (point: CGPoint, image: UIImage, mode: String)? {
        // Critical section: DO NOT foreground Pilot here. We just tapped GO and
        // must leave Pikmin untouched until the carrying overlay appears.
        // Try the visual detectors briefly, then use the coordinate measured
        // from the user's real 942x2048 carrying screenshot.
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

            if index >= 4 {
                let fixedPoint = CGPoint(
                    x: Double(image.cgImage?.width ?? 1) * 0.0971,
                    y: Double(image.cgImage?.height ?? 1) * 0.9144
                )
                emit("ROUND \(round) • green X visual miss → calibrated fallback x=0.0971 y=0.9144")
                return (fixedPoint, image, "fixed@0.0971,0.9144")
            }

            if index == 0 || index == 2 {
                emit("ROUND \(round) • carrying green X scan attempt \(index + 1)/8")
            }
            await pause(0.34)
        }
        return nil
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
        try? FileManager.default.removeItem(at: url)

        let result = await engine.takeScreenshot(outputPath: url.path)
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
        guard result.ok else {
            throw LoopError("phase=\(stage)-tap • \(result.message)")
        }
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
        guard result.ok else {
            throw LoopError("phase=\(stage)-swipe • \(result.message)")
        }
    }

    // MARK: - iOS finite-background renewal

    private func ensureBackgroundBudget(
        engine: IDeviceEngine,
        stage: String,
        minimumRemaining: Double = 12.0
    ) async throws {
        guard UIApplication.shared.applicationState != .active else { return }

        let remaining = UIApplication.shared.backgroundTimeRemaining
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
        if cancelled {
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
