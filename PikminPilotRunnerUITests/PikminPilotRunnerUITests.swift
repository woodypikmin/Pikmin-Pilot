import XCTest
import UIKit
import CoreGraphics
import Darwin

final class PikminPilotRunnerUITests: XCTestCase {
    private struct Pixel {
        let r: UInt8
        let g: UInt8
        let b: UInt8
    }

    private struct HSV {
        let h: Double
        let s: Double
        let v: Double
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testPilotCommand() throws {
        let env = ProcessInfo.processInfo.environment
        let command = env["PIKMIN_PILOT_COMMAND"] ?? "center"
        let app = XCUIApplication(bundleIdentifier: "com.nianticlabs.pikmin")

        // Stage 8.x never cold-launches Pikmin Bloom. The game must already be
        // alive; commands only re-activate the existing process and inject UI
        // actions. This preserves the user's current game state.
        switch app.state {
        case .runningForeground, .runningBackground, .runningBackgroundSuspended:
            break
        default:
            XCTFail("Pikmin Bloom is not already running (state=\(app.state.rawValue)); refusing to relaunch")
            return
        }

        app.activate()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 15),
            "Pikmin Bloom did not reach foreground after activate()"
        )

        if command == "activate" {
            usleep(120_000)
            return
        }

        if command == "select12" {
            guard selectPikminGrid(in: app, count: 12, interTapDelayUS: 35_000) else {
                XCTFail("select12: adaptive Pikmin grid detection failed")
                return
            }
            XCTAssertEqual(app.state, .runningForeground)
            usleep(120_000)
            return
        }

        guard
            let sx = env["PIKMIN_PILOT_X"],
            let sy = env["PIKMIN_PILOT_Y"],
            let x = Double(sx),
            let y = Double(sy),
            x >= 0, x <= 1,
            y >= 0, y <= 1
        else {
            XCTFail("Invalid PIKMIN_PILOT_X/Y environment")
            return
        }

        // Stage 10.3 critical-tail macro. The host has already used DVT to
        // tap the already-detected Pikmin-type filter. The whole filter -> count -> GO -> X
        // tail stays in one Runner session, but count (2...12) and pace are now
        // user-selectable from Pikmin Pilot.
        if command == "dispatchtail" {
            let requestedCount = Int(
                env["PIKMIN_PILOT_SELECT_COUNT"] ??
                env["PIKMIN_PILOT_PINK_COUNT"] ??
                "12"
            ) ?? 12
            let pikminCount = min(12, max(2, requestedCount))
            let fastMode = env["PIKMIN_PILOT_FAST_MODE"] == "1"

            let filterSettle: useconds_t = fastMode ? 220_000 : 320_000
            let interTap: useconds_t = fastMode ? 20_000 : 35_000
            let afterSelection: useconds_t = fastMode ? 85_000 : 140_000
            let goPollDelay: useconds_t = fastMode ? 55_000 : 80_000
            let afterGO: useconds_t = fastMode ? 380_000 : 520_000
            let closePollDelay: useconds_t = fastMode ? 75_000 : 120_000
            let afterClose: useconds_t = fastMode ? 110_000 : 180_000
            let handoffSettle: useconds_t = fastMode ? 100_000 : 160_000

            app.coordinate(
                withNormalizedOffset: CGVector(dx: x, dy: y)
            ).tap()
            usleep(filterSettle)

            guard selectPikminGrid(in: app, count: pikminCount, interTapDelayUS: interTap) else {
                XCTFail("dispatchtail: adaptive Pikmin grid detection failed")
                return
            }
            usleep(afterSelection)

            var goPoint: CGPoint?
            for _ in 0..<8 {
                let shot = XCUIScreen.main.screenshot().image
                if let point = detectActiveGO(in: shot) {
                    goPoint = point
                    break
                }
                usleep(goPollDelay)
            }

            guard let goPoint else {
                XCTFail("dispatchtail: active GO not detected after selecting \(pikminCount) Pikmin")
                return
            }

            app.coordinate(
                withNormalizedOffset: CGVector(dx: goPoint.x, dy: goPoint.y)
            ).tap()

            // Stage 11.5.2: the carrying-close point must come from the live
            // screenshot, and the close action must be VERIFIED before Pilot is
            // ever allowed back into the foreground. 11.5.1 could send one tap
            // and then unconditionally activate Pilot; if that tap missed, it
            // looked as if Pilot jumped out before the green X was pressed.
            usleep(afterGO)
            var closePoint: CGPoint?
            for _ in 0..<6 {
                let shot = XCUIScreen.main.screenshot().image
                if let point = detectCarryingClose(in: shot) {
                    closePoint = point
                    break
                }
                usleep(closePollDelay)
            }

            guard var closePoint else {
                XCTFail("dispatchtail: carrying green X not detected on live layout")
                return
            }

            var carryingClosed = false
            let maxCloseAttempts = 3
            for attempt in 1...maxCloseAttempts {
                guard app.state == .runningForeground else {
                    XCTFail("dispatchtail: Pikmin Bloom left foreground before carrying-close attempt \(attempt); Pilot handoff suppressed")
                    return
                }

                app.coordinate(
                    withNormalizedOffset: CGVector(dx: closePoint.x, dy: closePoint.y)
                ).tap()
                usleep(afterClose)

                // Verify that the same lower-left green close control actually
                // disappeared. A different green object elsewhere on the next
                // screen must not block the success decision.
                var sameCloseStillVisible: CGPoint?
                var consecutiveAbsentFrames = 0
                for _ in 0..<5 {
                    let verifyShot = XCUIScreen.main.screenshot().image
                    if let candidate = detectCarryingClose(in: verifyShot),
                       normalizedDistance(candidate, closePoint) <= 0.085 {
                        sameCloseStillVisible = candidate
                        consecutiveAbsentFrames = 0
                    } else {
                        consecutiveAbsentFrames += 1
                        if consecutiveAbsentFrames >= 2 {
                            sameCloseStillVisible = nil
                            break
                        }
                    }
                    usleep(closePollDelay)
                }

                if consecutiveAbsentFrames >= 2 {
                    carryingClosed = true
                    break
                }

                if let retryPoint = sameCloseStillVisible {
                    closePoint = retryPoint
                }
            }

            guard carryingClosed else {
                XCTFail("dispatchtail: carrying green X remained visible after \(maxCloseAttempts) verified taps; Pilot foreground handoff suppressed")
                return
            }

            // Explicit foreground handoff only after the carrying screen has
            // been positively closed. Pilot may have exhausted its finite
            // background task while this separate Runner process was working.
            // Bring the already-running host back so its suspended async loop
            // can resume and start Round 2. The host bundle id is discovered
            // dynamically by InstallationProxy because Sideloadly can rewrite it.
            if let hostID = env["PIKMIN_PILOT_HOST_BUNDLE_ID"], !hostID.isEmpty {
                let pilot = XCUIApplication(bundleIdentifier: hostID)
                pilot.activate()
                XCTAssertTrue(
                    pilot.wait(for: .runningForeground, timeout: 6),
                    "dispatchtail: Pikmin Pilot foreground handoff failed for \(hostID)"
                )
                usleep(handoffSettle)
            }
            return
        }

        if command == "swipe" {
            guard
                let sx2 = env["PIKMIN_PILOT_X2"],
                let sy2 = env["PIKMIN_PILOT_Y2"],
                let sd = env["PIKMIN_PILOT_DURATION"],
                let x2 = Double(sx2),
                let y2 = Double(sy2),
                let duration = Double(sd),
                x2 >= 0, x2 <= 1,
                y2 >= 0, y2 <= 1,
                duration >= 0, duration <= 5
            else {
                XCTFail("Invalid swipe environment")
                return
            }

            let start = app.coordinate(
                withNormalizedOffset: CGVector(dx: x, dy: y)
            )
            let end = app.coordinate(
                withNormalizedOffset: CGVector(dx: x2, dy: y2)
            )

            start.press(forDuration: 0.05, thenDragTo: end)
            XCTAssertEqual(app.state, .runningForeground)
            usleep(120_000)
            return
        }

        let tapX: Double
        let tapY: Double
        if command == "tap" {
            tapX = x
            tapY = y
        } else {
            // Retains the Stage 7.8.5 proof command.
            tapX = 0.5
            tapY = 0.5
        }

        app.coordinate(
            withNormalizedOffset: CGVector(dx: tapX, dy: tapY)
        ).tap()

        XCTAssertEqual(
            app.state,
            .runningForeground,
            "Pikmin Bloom left foreground immediately after tap"
        )

        usleep(120_000)
    }

    @discardableResult
    private func selectPikminGrid(
        in app: XCUIApplication,
        count: Int,
        interTapDelayUS: useconds_t
    ) -> Bool {
        let shot = XCUIScreen.main.screenshot().image
        guard let points = detectPikminSelectionGrid(in: shot), points.count >= min(12, max(2, count)) else {
            return false
        }

        for point in points.prefix(min(12, max(2, count))) {
            app.coordinate(
                withNormalizedOffset: CGVector(dx: point.x, dy: point.y)
            ).tap()
            usleep(interTapDelayUS)
        }
        return true
    }

    /// Builds a scalable 5-column selection lattice inside the *live* game
    /// viewport, then locally refines every slot to the strongest visual center
    /// in that neighborhood. The old 868x1836 pixel taps are no longer used.
    private func detectPikminSelectionGrid(in image: UIImage) -> [CGPoint]? {
        guard let (w, h, data) = rawPixels(image) else { return nil }
        let viewport = activeContentRect(width: w, height: h, data: data)
        guard viewport.width > 0, viewport.height > 0 else { return nil }

        let columns = [0.129, 0.313, 0.492, 0.672, 0.849]
        let rows = [0.517, 0.662, 0.801]
        let searchX = viewport.width * 0.055
        let searchY = viewport.height * 0.040
        let step = max(3, Int(min(viewport.width, viewport.height) / 180.0))
        let patchRadius = max(5, Int(min(viewport.width, viewport.height) * 0.018))

        func visualScore(_ cx: Int, _ cy: Int) -> Double {
            let minX = max(1, cx - patchRadius)
            let maxX = min(w - 2, cx + patchRadius)
            let minY = max(1, cy - patchRadius)
            let maxY = min(h - 2, cy + patchRadius)
            guard minX < maxX, minY < maxY else { return -1 }

            var score = 0.0
            var samples = 0
            let localStep = max(2, patchRadius / 5)
            for y in stride(from: minY, through: maxY, by: localStep) {
                for x in stride(from: minX, through: maxX, by: localStep) {
                    let p = pixel(data, width: w, x: x, y: y)
                    let v = hsv(p)
                    let pr = pixel(data, width: w, x: min(w - 1, x + 1), y: y)
                    let pd = pixel(data, width: w, x: x, y: min(h - 1, y + 1))
                    let lum = (Double(p.r) + Double(p.g) + Double(p.b)) / 765.0
                    let lumR = (Double(pr.r) + Double(pr.g) + Double(pr.b)) / 765.0
                    let lumD = (Double(pd.r) + Double(pd.g) + Double(pd.b)) / 765.0
                    let edge = abs(lum - lumR) + abs(lum - lumD)
                    score += v.s * 0.70 + edge * 1.80 + min(v.v, 1.0) * 0.10
                    samples += 1
                }
            }
            return samples > 0 ? score / Double(samples) : -1
        }

        var result: [CGPoint] = []
        for row in rows {
            for column in columns {
                let seedX = viewport.minX + viewport.width * column
                let seedY = viewport.minY + viewport.height * row
                var best = CGPoint(x: seedX, y: seedY)
                var bestScore = -Double.infinity

                var cy = Int(seedY - searchY)
                while cy <= Int(seedY + searchY) {
                    var cx = Int(seedX - searchX)
                    while cx <= Int(seedX + searchX) {
                        if cx >= Int(viewport.minX), cx < Int(viewport.maxX),
                           cy >= Int(viewport.minY), cy < Int(viewport.maxY) {
                            let score = visualScore(cx, cy)
                            if score > bestScore {
                                bestScore = score
                                best = CGPoint(x: cx, y: cy)
                            }
                        }
                        cx += step
                    }
                    cy += step
                }

                result.append(CGPoint(
                    x: best.x / Double(w),
                    y: best.y / Double(h)
                ))
            }
        }

        return result
    }

    // Returns normalized coordinates for the warm active GO component.
    private func detectActiveGO(in image: UIImage) -> CGPoint? {
        guard let (w, h, data) = rawPixels(image) else { return nil }
        let viewport = activeContentRect(width: w, height: h, data: data)
        let x0 = max(0, Int(viewport.minX + viewport.width * 0.42))
        let x1 = min(w, Int(viewport.maxX))
        let y0 = max(0, Int(viewport.minY + viewport.height * 0.58))
        let y1 = min(h, Int(viewport.maxY))
        var mask = [Bool](repeating: false, count: w * h)

        for py in y0..<y1 {
            for px in x0..<x1 {
                let value = hsv(pixel(data, width: w, x: px, y: py))
                let warmHue = value.h < 60 || value.h > 336
                if warmHue && value.s > 0.27 && value.v > 0.56 {
                    mask[py * w + px] = true
                }
            }
        }

        let contentArea = max(1.0, viewport.width * viewport.height)
        let candidates = connectedComponents(width: w, height: h, mask: mask)
            .compactMap { rect, count -> (Double, CGPoint)? in
                guard count >= Int(contentArea * 0.00075) else { return nil }
                guard rect.width >= viewport.width * 0.06 else { return nil }
                guard rect.height >= viewport.height * 0.025 else { return nil }
                let center = CGPoint(x: rect.midX / Double(w), y: rect.midY / Double(h))
                return (Double(count), center)
            }
            .sorted { $0.0 > $1.0 }

        return candidates.first?.1
    }

    private func normalizedDistance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return sqrt(dx * dx + dy * dy)
    }

    // Confirms the green carrying-close control around the user's real-device
    // calibration, then returns its normalized center. This is deliberately a
    // color check, so the normal WHITE list close button is not accepted.
    private func detectCarryingClose(in image: UIImage) -> CGPoint? {
        guard let (w, h, data) = rawPixels(image) else { return nil }
        let viewport = activeContentRect(width: w, height: h, data: data)

        // Search only the lower-left portion of the live game viewport. The
        // carrying close control is a dark green circular button with a white X.
        // Restricting hue/value here avoids merging it into Pikmin Bloom's bright
        // cyan ocean background (the 11.5.2 broad green mask could do that).
        let x0 = max(0, Int(viewport.minX))
        let x1 = min(w, Int(viewport.minX + viewport.width * 0.32))
        let y0 = max(0, Int(viewport.minY + viewport.height * 0.68))
        let y1 = min(h, Int(viewport.maxY))
        var mask = [Bool](repeating: false, count: w * h)

        for y in y0..<y1 {
            for x in x0..<x1 {
                let value = hsv(pixel(data, width: w, x: x, y: y))
                if value.h >= 125 && value.h <= 195 &&
                    value.s >= 0.24 && value.v >= 0.14 && value.v <= 0.84 {
                    mask[y * w + x] = true
                }
            }
        }

        let contentArea = max(1.0, viewport.width * viewport.height)
        var best: (point: CGPoint, score: Double)?
        for (rect, count) in connectedComponents(width: w, height: h, mask: mask) {
            guard count >= Int(contentArea * 0.00055) else { continue }
            let wf = rect.width / max(1, viewport.width)
            let hf = rect.height / max(1, viewport.height)
            guard wf >= 0.045 && wf <= 0.18 else { continue }
            guard hf >= 0.020 && hf <= 0.12 else { continue }
            let aspect = rect.width / max(1, rect.height)
            guard aspect >= 0.68 && aspect <= 1.45 else { continue }

            let center = CGPoint(x: rect.midX, y: rect.midY)
            let nx = (center.x - viewport.minX) / max(1, viewport.width)
            let ny = (center.y - viewport.minY) / max(1, viewport.height)
            guard nx <= 0.30 && ny >= 0.70 else { continue }

            // Confirm that the candidate contains a small amount of bright,
            // low-saturation white pixels from the X glyph.
            var white = 0
            var sampled = 0
            let rx0 = max(0, Int(rect.minX))
            let rx1 = min(w - 1, Int(rect.maxX))
            let ry0 = max(0, Int(rect.minY))
            let ry1 = min(h - 1, Int(rect.maxY))
            if rx0 <= rx1 && ry0 <= ry1 {
                for yy in stride(from: ry0, through: ry1, by: 2) {
                    for xx in stride(from: rx0, through: rx1, by: 2) {
                        let value = hsv(pixel(data, width: w, x: xx, y: yy))
                        if value.s <= 0.20 && value.v >= 0.82 { white += 1 }
                        sampled += 1
                    }
                }
            }
            let whiteFraction = sampled > 0 ? Double(white) / Double(sampled) : 0
            guard whiteFraction >= 0.006 else { continue }

            let shapePenalty = abs(log(max(0.001, aspect)))
            let locationPenalty = nx * 0.08 + abs(ny - 0.91) * 0.03
            let areaBonus = min(0.20, Double(count) / contentArea * 14.0)
            let whiteBonus = min(0.10, whiteFraction * 2.5)
            let score = shapePenalty + locationPenalty - areaBonus - whiteBonus
            let normalized = CGPoint(x: center.x / Double(w), y: center.y / Double(h))
            if best == nil || score < best!.score {
                best = (normalized, score)
            }
        }

        return best?.point
    }

    private func activeContentRect(width w: Int, height h: Int, data: [UInt8]) -> CGRect {
        let sampleStep = max(2, min(w, h) / 220)
        func isActive(_ x: Int, _ y: Int) -> Bool {
            let value = hsv(pixel(data, width: w, x: x, y: y))
            return value.v > 0.085 || value.s > 0.10
        }
        func longestRun(_ values: [Bool]) -> Range<Int>? {
            var best: Range<Int>?
            var start: Int?
            for i in 0...values.count {
                let on = i < values.count ? values[i] : false
                if on, start == nil { start = i }
                if !on, let s = start {
                    let r = s..<i
                    if best == nil || r.count > best!.count { best = r }
                    start = nil
                }
            }
            return best
        }

        var rows = [Bool](repeating: false, count: h)
        for y in stride(from: 0, to: h, by: sampleStep) {
            var active = 0, total = 0
            for x in stride(from: 0, to: w, by: sampleStep) {
                if isActive(x, y) { active += 1 }
                total += 1
            }
            let on = total > 0 && Double(active) / Double(total) > 0.16
            for yy in y..<min(h, y + sampleStep) { rows[yy] = on }
        }
        guard let yr = longestRun(rows), yr.count >= Int(Double(h) * 0.55) else {
            return CGRect(x: 0, y: 0, width: w, height: h)
        }

        var cols = [Bool](repeating: false, count: w)
        let yStep = max(sampleStep, yr.count / 140)
        for x in stride(from: 0, to: w, by: sampleStep) {
            var active = 0, total = 0
            for y in stride(from: yr.lowerBound, to: yr.upperBound, by: yStep) {
                if isActive(x, y) { active += 1 }
                total += 1
            }
            let on = total > 0 && Double(active) / Double(total) > 0.16
            for xx in x..<min(w, x + sampleStep) { cols[xx] = on }
        }
        guard let xr = longestRun(cols), xr.count >= Int(Double(w) * 0.45) else {
            return CGRect(x: 0, y: yr.lowerBound, width: w, height: yr.count)
        }
        return CGRect(x: xr.lowerBound, y: yr.lowerBound, width: xr.count, height: yr.count)
    }

    private func rawPixels(_ image: UIImage) -> (Int, Int, [UInt8])? {
        guard let cg = image.cgImage else { return nil }
        let w = cg.width
        let h = cg.height
        let bytesPerRow = w * 4
        var data = [UInt8](repeating: 0, count: h * bytesPerRow)

        guard let ctx = CGContext(
            data: &data,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (w, h, data)
    }

    private func pixel(
        _ data: [UInt8],
        width: Int,
        x: Int,
        y: Int
    ) -> Pixel {
        let i = (y * width + x) * 4
        return Pixel(r: data[i], g: data[i + 1], b: data[i + 2])
    }

    private func hsv(_ p: Pixel) -> HSV {
        let r = Double(p.r) / 255.0
        let g = Double(p.g) / 255.0
        let b = Double(p.b) / 255.0
        let mx = max(r, g, b)
        let mn = min(r, g, b)
        let d = mx - mn
        var h = 0.0

        if d != 0 {
            if mx == r {
                h = 60.0 * (((g - b) / d).truncatingRemainder(dividingBy: 6.0))
            } else if mx == g {
                h = 60.0 * (((b - r) / d) + 2.0)
            } else {
                h = 60.0 * (((r - g) / d) + 4.0)
            }
        }

        if h < 0 { h += 360.0 }
        let s = mx == 0 ? 0 : d / mx
        return HSV(h: h, s: s, v: mx)
    }

    private func connectedComponents(
        width: Int,
        height: Int,
        mask: [Bool]
    ) -> [(CGRect, Int)] {
        var visited = [Bool](repeating: false, count: mask.count)
        var result: [(CGRect, Int)] = []
        let dirs = [(1, 0), (-1, 0), (0, 1), (0, -1)]

        for y in 0..<height {
            for x in 0..<width {
                let idx = y * width + x
                if visited[idx] || !mask[idx] { continue }

                var queue = [(x, y)]
                visited[idx] = true
                var qi = 0
                var minX = x
                var maxX = x
                var minY = y
                var maxY = y
                var count = 0

                while qi < queue.count {
                    let (cx, cy) = queue[qi]
                    qi += 1
                    count += 1
                    minX = min(minX, cx)
                    maxX = max(maxX, cx)
                    minY = min(minY, cy)
                    maxY = max(maxY, cy)

                    for (dx, dy) in dirs {
                        let nx = cx + dx
                        let ny = cy + dy
                        if nx < 0 || ny < 0 || nx >= width || ny >= height { continue }
                        let ni = ny * width + nx
                        if visited[ni] || !mask[ni] { continue }
                        visited[ni] = true
                        queue.append((nx, ny))
                    }
                }

                result.append((
                    CGRect(
                        x: minX,
                        y: minY,
                        width: maxX - minX + 1,
                        height: maxY - minY + 1
                    ),
                    count
                ))
            }
        }

        return result
    }
}
