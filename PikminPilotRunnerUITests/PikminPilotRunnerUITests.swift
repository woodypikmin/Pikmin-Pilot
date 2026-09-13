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
            selectPikminGrid(in: app, count: 12, interTapDelayUS: 35_000)
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
            let closeFallbackDelay: useconds_t = fastMode ? 250_000 : 420_000
            let afterClose: useconds_t = fastMode ? 110_000 : 180_000
            let handoffSettle: useconds_t = fastMode ? 100_000 : 160_000

            app.coordinate(
                withNormalizedOffset: CGVector(dx: x, dy: y)
            ).tap()
            usleep(filterSettle)

            selectPikminGrid(in: app, count: pikminCount, interTapDelayUS: interTap)
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

            // XCUIScreen screenshots are relatively expensive. The user's real
            // device already established the carrying-close center at
            // (0.0971, 0.9144), so only do two quick visual confirmations and
            // then use the stage-gated calibrated fallback. This keeps the tail
            // comfortably inside one iOS finite background window.
            usleep(afterGO)
            var closePoint: CGPoint?
            for _ in 0..<2 {
                let shot = XCUIScreen.main.screenshot().image
                if let point = detectCarryingClose(in: shot) {
                    closePoint = point
                    break
                }
                usleep(closePollDelay)
            }

            if closePoint == nil {
                usleep(closeFallbackDelay)
                closePoint = CGPoint(x: 0.0971, y: 0.9144)
            }

            app.coordinate(
                withNormalizedOffset: CGVector(dx: closePoint!.x, dy: closePoint!.y)
            ).tap()
            usleep(afterClose)

            // Explicit foreground handoff: Pilot may have exhausted its finite
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

    private func selectPikminGrid(
        in app: XCUIApplication,
        count: Int,
        interTapDelayUS: useconds_t
    ) {
        let points: [(Double, Double)] = [
            (112.0 / 868.0,  950.0 / 1836.0),
            (272.0 / 868.0,  950.0 / 1836.0),
            (427.0 / 868.0,  950.0 / 1836.0),
            (583.0 / 868.0,  950.0 / 1836.0),
            (737.0 / 868.0,  950.0 / 1836.0),
            (112.0 / 868.0, 1215.0 / 1836.0),
            (272.0 / 868.0, 1215.0 / 1836.0),
            (427.0 / 868.0, 1215.0 / 1836.0),
            (583.0 / 868.0, 1215.0 / 1836.0),
            (737.0 / 868.0, 1215.0 / 1836.0),
            (112.0 / 868.0, 1470.0 / 1836.0),
            (272.0 / 868.0, 1470.0 / 1836.0),
        ]

        for (px, py) in points.prefix(min(12, max(2, count))) {
            app.coordinate(
                withNormalizedOffset: CGVector(dx: px, dy: py)
            ).tap()
            usleep(interTapDelayUS)
        }
    }

    // Returns normalized coordinates for the warm active GO component.
    private func detectActiveGO(in image: UIImage) -> CGPoint? {
        guard let (w, h, data) = rawPixels(image) else { return nil }

        let x0 = Int(Double(w) * 0.60)
        let y0 = Int(Double(h) * 0.76)
        var mask = [Bool](repeating: false, count: w * h)

        for py in y0..<h {
            for px in x0..<w {
                let value = hsv(pixel(data, width: w, x: px, y: py))
                let warmHue = value.h < 60 || value.h > 336
                if warmHue && value.s > 0.27 && value.v > 0.56 {
                    mask[py * w + px] = true
                }
            }
        }

        let minCount = Int(Double(w * h) * 0.0010)
        let candidates = connectedComponents(width: w, height: h, mask: mask)
            .compactMap { rect, count -> (Int, CGPoint)? in
                guard count >= minCount else { return nil }
                guard rect.width >= Double(w) * 0.07 else { return nil }
                guard rect.height >= Double(h) * 0.04 else { return nil }
                return (
                    count,
                    CGPoint(
                        x: rect.midX / Double(w),
                        y: rect.midY / Double(h)
                    )
                )
            }
            .sorted { $0.0 > $1.0 }

        return candidates.first?.1
    }

    // Confirms the green carrying-close control around the user's real-device
    // calibration, then returns its normalized center. This is deliberately a
    // color check, so the normal WHITE list close button is not accepted.
    private func detectCarryingClose(in image: UIImage) -> CGPoint? {
        guard let (w, h, data) = rawPixels(image) else { return nil }

        let expectedX = Double(w) * 0.0971
        let expectedY = Double(h) * 0.9144
        let radius = Double(w) * 0.055
        let searchDX = Int(Double(w) * 0.035)
        let searchDY = Int(Double(h) * 0.025)
        let stepX = max(2, Int(Double(w) * 0.006))
        let stepY = max(2, Int(Double(h) * 0.006))

        var bestPoint: CGPoint?
        var bestScore = -999.0
        var cy = Int(expectedY) - searchDY

        while cy <= Int(expectedY) + searchDY {
            var cx = Int(expectedX) - searchDX

            while cx <= Int(expectedX) + searchDX {
                var green = 0
                var white = 0
                var total = 0
                let rr = radius * 0.82

                let minX = max(0, Int(Double(cx) - rr))
                let maxX = min(w - 1, Int(Double(cx) + rr))
                let minY = max(0, Int(Double(cy) - rr))
                let maxY = min(h - 1, Int(Double(cy) + rr))

                for py in minY...maxY {
                    for px in minX...maxX {
                        let dx = Double(px - cx)
                        let dy = Double(py - cy)
                        if dx * dx + dy * dy > rr * rr { continue }

                        let value = hsv(pixel(data, width: w, x: px, y: py))
                        if value.h > 70 && value.h < 200 && value.s > 0.14 && value.v > 0.14 {
                            green += 1
                        }
                        if value.s < 0.18 && value.v > 0.84 {
                            white += 1
                        }
                        total += 1
                    }
                }

                if total > 0 {
                    let greenFraction = Double(green) / Double(total)
                    let whiteFraction = Double(white) / Double(total)
                    let score = greenFraction - whiteFraction * 0.50
                    if greenFraction > 0.30 && whiteFraction < 0.45 && score > bestScore {
                        bestScore = score
                        bestPoint = CGPoint(
                            x: Double(cx) / Double(w),
                            y: Double(cy) / Double(h)
                        )
                    }
                }

                cx += stepX
            }
            cy += stepY
        }

        return bestPoint
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
