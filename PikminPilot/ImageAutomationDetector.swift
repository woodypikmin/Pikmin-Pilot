
import UIKit
import CoreGraphics

final class ImageAutomationDetector {
    static func componentCenters(
        mask: [Bool],
        width w: Int,
        height h: Int
    ) -> [(CGRect, Int)] {
        FruitDetector.connectedComponents(
            width: w,
            height: h,
            mask: mask
        )
    }


    /// Returns the live game-content rectangle in screenshot pixels. On normal
    /// iPhones this is usually the full frame. On iPad/iPhone-compatibility
    /// layouts it trims persistent near-black letterbox margins before any
    /// geometry is mapped into XCTest's full-screen normalized coordinates.
    static func activeContentRect(in image: UIImage) -> CGRect {
        guard let (w, h, data) = FruitDetector.rawPixels(image), w > 0, h > 0 else {
            return CGRect(origin: .zero, size: image.size)
        }

        let sampleStep = max(2, min(w, h) / 220)

        func isActive(_ x: Int, _ y: Int) -> Bool {
            let value = FruitDetector.hsv(FruitDetector.pixel(data, width: w, x: x, y: y))
            return value.v > 0.085 || value.s > 0.10
        }

        var rowActive = [Bool](repeating: false, count: h)
        for y in stride(from: 0, to: h, by: sampleStep) {
            var active = 0
            var total = 0
            for x in stride(from: 0, to: w, by: sampleStep) {
                if isActive(x, y) { active += 1 }
                total += 1
            }
            let on = total > 0 && Double(active) / Double(total) > 0.16
            for yy in y..<min(h, y + sampleStep) { rowActive[yy] = on }
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

        guard let yr = longestRun(rowActive), yr.count >= Int(Double(h) * 0.55) else {
            return CGRect(x: 0, y: 0, width: w, height: h)
        }

        var colActive = [Bool](repeating: false, count: w)
        let yStep = max(sampleStep, yr.count / 140)
        for x in stride(from: 0, to: w, by: sampleStep) {
            var active = 0
            var total = 0
            for y in stride(from: yr.lowerBound, to: yr.upperBound, by: yStep) {
                if isActive(x, y) { active += 1 }
                total += 1
            }
            let on = total > 0 && Double(active) / Double(total) > 0.16
            for xx in x..<min(w, x + sampleStep) { colActive[xx] = on }
        }

        guard let xr = longestRun(colActive), xr.count >= Int(Double(w) * 0.45) else {
            return CGRect(x: 0, y: yr.lowerBound, width: w, height: yr.count)
        }

        let rect = CGRect(x: xr.lowerBound, y: yr.lowerBound, width: xr.count, height: yr.count)
        if rect.width < Double(w) * 0.45 || rect.height < Double(h) * 0.55 {
            return CGRect(x: 0, y: 0, width: w, height: h)
        }
        return rect
    }

    static func contentPoint(x: Double, y: Double, in image: UIImage) -> CGPoint {
        let rect = activeContentRect(in: image)
        return CGPoint(
            x: rect.minX + rect.width * x,
            y: rect.minY + rect.height * y
        )
    }

    /// Stage 11.5.4.14: detect the real "Go to Expedition" control by
    /// *button geometry*, not merely by the amount of blue pixels.
    ///
    /// The old detector accepted any sufficiently large blue component in the
    /// lower half of the detail page. Ice-blue seedlings have a large blue pot,
    /// so that object could outrank the actual button and be tapped. Pilot then
    /// assumed it was already on the Pikmin-selection page and sent horizontal
    /// filter-row swipes into the still-open detail page.
    ///
    /// This detector is deliberately fail-closed: the candidate must be a wide,
    /// shallow, horizontally centred blue rounded-rectangle-like component.
    static func detectExpeditionButton(
        in image: UIImage
    ) -> CGPoint? {
        guard let (w, h, data) = FruitDetector.rawPixels(image) else {
            return nil
        }

        let viewport = activeContentRect(in: image)
        let minDim = max(1.0, min(viewport.width, viewport.height))
        let x0 = max(0, Int(viewport.minX + viewport.width * 0.08))
        let x1 = min(w, Int(viewport.maxX - viewport.width * 0.08))
        let y0 = max(0, Int(viewport.minY + viewport.height * 0.50))
        let y1 = min(h, Int(viewport.minY + viewport.height * 0.94))

        var mask = [Bool](repeating: false, count: w * h)
        for y in y0..<y1 {
            for x in x0..<x1 {
                let p = FruitDetector.pixel(data, width: w, x: x, y: y)
                let v = FruitDetector.hsv(p)

                // Pikmin Bloom's expedition CTA is cyan/blue. Keep this a little
                // broader than the old range so display tone / screenshot colour
                // management does not cause a false negative.
                let blueCTA = v.h >= 128 && v.h <= 222 &&
                    v.s >= 0.22 && v.v >= 0.30
                if blueCTA { mask[y * w + x] = true }
            }
        }

        let components = componentCenters(mask: mask, width: w, height: h)
        var scored: [(score: CGFloat, point: CGPoint)] = []

        for (rect, count) in components {
            let widthRatio = rect.width / viewport.width
            let heightRatio = rect.height / viewport.height
            let aspect = rect.width / max(1.0, rect.height)
            let fill = CGFloat(count) / max(1.0, rect.width * rect.height)
            let centerX = rect.midX
            let centerY = rect.midY

            // A seedling pot / fruit icon is roughly square. The real CTA is
            // conspicuously wide and shallow, so reject anything icon-shaped.
            guard widthRatio >= 0.24 && widthRatio <= 0.82 else { continue }
            guard heightRatio >= 0.028 && heightRatio <= 0.145 else { continue }
            guard aspect >= 2.35 && aspect <= 14.0 else { continue }
            guard fill >= 0.22 else { continue }
            guard count >= Int(minDim * minDim * 0.00022) else { continue }

            let centerOffset = abs(centerX - viewport.midX) / viewport.width
            guard centerOffset <= 0.20 else { continue }

            let normalizedY = (centerY - viewport.minY) / viewport.height
            guard normalizedY >= 0.52 && normalizedY <= 0.92 else { continue }

            // Prefer a centred, medium-width CTA. Count/fill help when white text
            // punches small holes into the blue background.
            let widthPenalty = abs(widthRatio - 0.56) * 1.20
            let centerPenalty = centerOffset * 2.20
            let yPenalty = abs(normalizedY - 0.76) * 0.35
            let aspectBonus = min(aspect, 8.0) * 0.025
            let fillBonus = fill * 0.55
            let score = fillBonus + aspectBonus - widthPenalty - centerPenalty - yPenalty

            scored.append((score, CGPoint(x: centerX, y: centerY)))
        }

        return scored.max(by: { $0.score < $1.score })?.point
    }

    /// A fail-closed visual gate for the Pikmin-selection page.
    ///
    /// The selection page contains a row of several small coloured circular
    /// filter chips. We require a horizontal cluster of >=4 chip-like components
    /// before the host is allowed to send the reveal/filter-row swipe. This is
    /// independent of device model and prevents a false expedition-button tap
    /// from turning into repeated horizontal swipes on a seedling detail page.
    static func isPikminSelectionPage(
        _ image: UIImage
    ) -> Bool {
        guard let (w, h, data) = FruitDetector.rawPixels(image) else {
            return false
        }

        let viewport = activeContentRect(in: image)
        let minDim = max(1.0, min(viewport.width, viewport.height))
        let x0 = max(0, Int(viewport.minX + viewport.width * 0.28))
        let x1 = min(w, Int(viewport.maxX - viewport.width * 0.01))
        let y0 = max(0, Int(viewport.minY + viewport.height * 0.33))
        let y1 = min(h, Int(viewport.minY + viewport.height * 0.55))

        var mask = [Bool](repeating: false, count: w * h)
        for y in y0..<y1 {
            for x in x0..<x1 {
                let p = FruitDetector.pixel(data, width: w, x: x, y: y)
                let v = FruitDetector.hsv(p)
                // Pastel colour chips remain bright but may have modest saturation.
                if v.s >= 0.13 && v.v >= 0.58 {
                    mask[y * w + x] = true
                }
            }
        }

        let components = componentCenters(mask: mask, width: w, height: h)
        let chips: [CGPoint] = components.compactMap { rect, count in
            let wf = rect.width / minDim
            let hf = rect.height / minDim
            let aspect = rect.width / max(1.0, rect.height)
            guard count >= Int(minDim * minDim * 0.00008) else { return nil }
            guard wf >= 0.018 && wf <= 0.080 else { return nil }
            guard hf >= 0.018 && hf <= 0.080 else { return nil }
            guard aspect >= 0.52 && aspect <= 1.60 else { return nil }
            return CGPoint(x: rect.midX, y: rect.midY)
        }

        guard chips.count >= 4 else { return false }

        // Find a horizontally aligned cluster. Pikmin sprites below the row may
        // also contain colour, but they do not produce 4+ small circles at one Y.
        let yTolerance = max(8.0, viewport.height * 0.030)
        for anchor in chips {
            let aligned = chips.filter { abs($0.y - anchor.y) <= yTolerance }
            guard aligned.count >= 4 else { continue }
            let xs = aligned.map(\.x)
            if let minX = xs.min(), let maxX = xs.max(),
               maxX - minX >= viewport.width * 0.22 {
                return true
            }
        }

        return false
    }

    static func detectPinkFilter(
        in image: UIImage
    ) -> CGPoint? {
        guard let (w, h, data) =
            FruitDetector.rawPixels(image)
        else {
            return nil
        }

        // Filter row on user's real screenshot:
        // y ~= 0.42 of screen.
        let y0 =
            Int(
                Double(h) * 0.395
            )

        let y1 =
            Int(
                Double(h) * 0.455
            )

        var mask =
            [Bool](
                repeating: false,
                count: w * h
            )

        for y in y0..<y1 {
            for x in 0..<w {
                let p =
                    FruitDetector.pixel(
                        data,
                        width: w,
                        x: x,
                        y: y
                    )

                let hsv =
                    FruitDetector.hsv(
                        p
                    )

                let r = Int(p.r)
                let g = Int(p.g)
                let b = Int(p.b)

                // Both purple and pink circles are magenta-ish,
                // but the pink Pikmin filter is the RIGHTMOST
                // magenta circle in this filter row.
                let magenta =
                    hsv.h >= 285 &&
                    hsv.h <= 325 &&
                    hsv.s >= 0.18 &&
                    hsv.s <= 0.62 &&
                    hsv.v >= 0.72 &&
                    r > 215 &&
                    b > 200 &&
                    g > 120

                if magenta {
                    mask[
                        y * w + x
                    ] = true
                }
            }
        }

        let components =
            componentCenters(
                mask: mask,
                width: w,
                height: h
            )

        let candidates =
            components
            .compactMap {
                rect,
                count
                ->
                (
                    CGPoint,
                    Int
                )?
                in

                if count <
                    Int(
                        Double(w * h)
                        * 0.00016
                    ) {
                    return nil
                }

                if rect.width <
                    Double(w) * 0.025 ||
                    rect.width >
                    Double(w) * 0.080 {
                    return nil
                }

                if rect.height <
                    Double(h) * 0.012 ||
                    rect.height >
                    Double(h) * 0.050 {
                    return nil
                }

                let center =
                    CGPoint(
                        x:
                            rect.midX,
                        y:
                            rect.midY
                    )

                return (
                    center,
                    count
                )
            }

        // Key Stage 4.2 change:
        // purple circle is left of pink circle.
        // Select the RIGHTMOST valid magenta circle.
        return candidates
            .sorted {
                if abs(
                    $0.0.x -
                    $1.0.x
                ) > 4 {
                    return (
                        $0.0.x >
                        $1.0.x
                    )
                }

                return (
                    $0.1 >
                    $1.1
                )
            }
            .first?
            .0
    }

    static func detectPikminFilter(
        type: PilotPikminType,
        in image: UIImage
    ) -> CGPoint? {
        guard let (w, h, data) = FruitDetector.rawPixels(image) else {
            return nil
        }

        let viewport = activeContentRect(in: image)
        let minDim = max(1.0, min(viewport.width, viewport.height))
        let x0 = max(0, Int(viewport.minX + viewport.width * 0.12))
        let x1 = min(w, Int(viewport.maxX - viewport.width * 0.03))
        let y0 = max(0, Int(viewport.minY + viewport.height * 0.22))
        let y1 = min(h, Int(viewport.minY + viewport.height * 0.66))

        var mask = [Bool](repeating: false, count: w * h)
        for y in y0..<y1 {
            for x in x0..<x1 {
                let p = FruitDetector.pixel(data, width: w, x: x, y: y)
                let hsv = FruitDetector.hsv(p)
                let magenta = hsv.h >= 278 && hsv.h <= 332 &&
                    hsv.s >= 0.16 && hsv.v >= 0.58 &&
                    Int(p.r) > Int(p.g) + 22 && Int(p.b) > Int(p.g) + 8
                if magenta { mask[y * w + x] = true }
            }
        }

        let candidates = componentCenters(mask: mask, width: w, height: h)
            .compactMap { rect, count -> (CGPoint, CGRect, Int)? in
                let wf = rect.width / minDim
                let hf = rect.height / minDim
                guard count >= Int(minDim * minDim * 0.00012) else { return nil }
                guard wf >= 0.020 && wf <= 0.115 else { return nil }
                guard hf >= 0.012 && hf <= 0.090 else { return nil }
                return (CGPoint(x: rect.midX, y: rect.midY), rect, count)
            }

        // Purple and pink are both magenta-ish. In the live filter row they
        // form the most useful pair of horizontally aligned magenta anchors.
        // Their separation spans two chip slots (purple, white, pink), which
        // gives us the actual row spacing on this exact device/layout.
        var bestPair: (left: CGPoint, right: CGPoint, score: CGFloat)?
        for i in 0..<candidates.count {
            for j in (i + 1)..<candidates.count {
                var a = candidates[i].0
                var b = candidates[j].0
                if a.x > b.x { swap(&a, &b) }
                let dx = b.x - a.x
                let dy = abs(b.y - a.y)
                guard dx >= viewport.width * 0.08 && dx <= viewport.width * 0.30 else { continue }
                guard dy <= max(minDim * 0.045, 8) else { continue }
                let spacingScore = abs(dx / viewport.width - 0.166)
                let verticalScore = dy / max(1, viewport.height)
                let middleBias = abs(((a.y + b.y) * 0.5 - viewport.midY) / max(1, viewport.height)) * 0.12
                let score = spacingScore + verticalScore * 2.5 + middleBias
                if bestPair == nil || score < bestPair!.score {
                    bestPair = (left: a, right: b, score: score)
                }
            }
        }

        guard let anchors = bestPair else {
            return nil
        }

        let purple = anchors.left
        let pink = anchors.right
        let spacing = (pink.x - purple.x) * 0.5
        let rowY = (purple.y + pink.y) * 0.5

        switch type {
        case .purple:
            return CGPoint(x: purple.x, y: rowY)
        case .white:
            return CGPoint(x: purple.x + spacing, y: rowY)
        case .pink:
            return CGPoint(x: pink.x, y: rowY)
        case .rock:
            let x = pink.x + spacing
            guard x < viewport.maxX - max(2, minDim * 0.01) else { return nil }
            return CGPoint(x: x, y: rowY)
        }
    }

    static func detectActiveGO(
        in image: UIImage
    ) -> CGPoint? {
        guard let (w, h, data) =
            FruitDetector.rawPixels(image)
        else {
            return nil
        }

        let x0 = Int(Double(w) * 0.60)
        let y0 = Int(Double(h) * 0.76)

        var mask = [Bool](
            repeating: false,
            count: w * h
        )

        for y in y0..<h {
            for x in x0..<w {
                let p = FruitDetector.pixel(
                    data,
                    width: w,
                    x: x,
                    y: y
                )

                let v = FruitDetector.hsv(p)

                let warmHue =
                    v.h < 60 ||
                    v.h > 336

                if warmHue &&
                    v.s > 0.27 &&
                    v.v > 0.56 {
                    mask[y * w + x] = true
                }
            }
        }

        let components = componentCenters(
            mask: mask,
            width: w,
            height: h
        )

        let candidates = components.compactMap {
            rect,
            count -> (Double, CGPoint)? in

            if count <
                Int(
                    Double(w * h)
                    * 0.0010
                ) {
                return nil
            }

            if rect.width <
                Double(w) * 0.07 ||
                rect.height <
                Double(h) * 0.04 {
                return nil
            }

            return (
                Double(count),
                CGPoint(
                    x: rect.midX,
                    y: rect.midY
                )
            )
        }
        .sorted {
            $0.0 > $1.0
        }

        return candidates.first?.1
    }

    static func detectCarryingClose(
        in image: UIImage
    ) -> CGPoint? {
        guard let (w, h, data) =
            FruitDetector.rawPixels(image)
        else {
            return nil
        }

        // This button is extremely stable on the carrying screen.
        // From the user's real screenshots its center is ~
        // x=0.096w, y=0.917h and radius ~0.055w.
        //
        // The carrying button is GREEN.
        // The normal expedition-list close button at the same place
        // is WHITE, so color makes this a very reliable discriminator.

        let expectedX =
            Double(w) * 0.096

        let expectedY =
            Double(h) * 0.917

        let radius =
            Double(w) * 0.055

        let searchDX =
            Int(Double(w) * 0.035)

        let searchDY =
            Int(Double(h) * 0.025)

        let stepX =
            max(
                2,
                Int(Double(w) * 0.006)
            )

        let stepY =
            max(
                2,
                Int(Double(h) * 0.006)
            )

        var bestPoint:
            CGPoint?

        var bestScore =
            -999.0

        var cy =
            Int(expectedY) -
            searchDY

        while cy <=
            Int(expectedY) +
            searchDY {

            var cx =
                Int(expectedX) -
                searchDX

            while cx <=
                Int(expectedX) +
                searchDX {

                var green =
                    0

                var white =
                    0

                var total =
                    0

                let rr =
                    radius * 0.82

                let minX =
                    max(
                        0,
                        Int(
                            Double(cx) -
                            rr
                        )
                    )

                let maxX =
                    min(
                        w - 1,
                        Int(
                            Double(cx) +
                            rr
                        )
                    )

                let minY =
                    max(
                        0,
                        Int(
                            Double(cy) -
                            rr
                        )
                    )

                let maxY =
                    min(
                        h - 1,
                        Int(
                            Double(cy) +
                            rr
                        )
                    )

                for y in minY...maxY {
                    for x in minX...maxX {
                        let dx =
                            Double(x - cx)

                        let dy =
                            Double(y - cy)

                        if dx * dx +
                            dy * dy >
                            rr * rr {
                            continue
                        }

                        let p =
                            FruitDetector.pixel(
                                data,
                                width: w,
                                x: x,
                                y: y
                            )

                        let value =
                            FruitDetector.hsv(
                                p
                            )

                        // Equivalent to the already-proven Python V3:
                        // OpenCV H 35...100 -> normal HSV ~70...200 deg.
                        if value.h > 70 &&
                            value.h < 200 &&
                            value.s > 0.14 &&
                            value.v > 0.14 {
                            green += 1
                        }

                        if value.s < 0.18 &&
                            value.v > 0.84 {
                            white += 1
                        }

                        total += 1
                    }
                }

                if total > 0 {
                    let greenFraction =
                        Double(green) /
                        Double(total)

                    let whiteFraction =
                        Double(white) /
                        Double(total)

                    let score =
                        greenFraction -
                        whiteFraction * 0.50

                    // Carrying screenshot tested around:
                    // green ~= 0.95, white ~= 0.04
                    //
                    // Expedition list X tested around:
                    // green ~= 0.00, white ~= 0.94
                    if greenFraction >
                        0.30 &&
                        whiteFraction <
                        0.45 &&
                        score >
                        bestScore {

                        bestScore =
                            score

                        bestPoint =
                            CGPoint(
                                x:
                                    Double(cx),
                                y:
                                    Double(cy)
                            )
                    }
                }

                cx +=
                    stepX
            }

            cy +=
                stepY
        }

        return bestPoint
    }
    static func detectCarryingCloseBroad(
        in image: UIImage
    ) -> CGPoint? {
        guard let (w, h, data) = FruitDetector.rawPixels(image) else {
            return nil
        }

        let viewport = activeContentRect(in: image)
        let x0 = max(0, Int(viewport.minX))
        let x1 = min(w, Int(viewport.maxX))
        let y0 = max(0, Int(viewport.minY + viewport.height * 0.48))
        let y1 = min(h, Int(viewport.maxY))

        var mask = [Bool](repeating: false, count: w * h)
        for y in y0..<y1 {
            for x in x0..<x1 {
                let hsv = FruitDetector.hsv(FruitDetector.pixel(data, width: w, x: x, y: y))
                if hsv.h >= 62 && hsv.h <= 215 && hsv.s >= 0.09 && hsv.v >= 0.12 {
                    mask[y * w + x] = true
                }
            }
        }

        let contentArea = max(1.0, viewport.width * viewport.height)
        let candidates = componentCenters(mask: mask, width: w, height: h)
            .compactMap { rect, count -> (CGPoint, Double)? in
                guard count >= Int(contentArea * 0.00020) else { return nil }
                let wf = rect.width / max(1, viewport.width)
                let hf = rect.height / max(1, viewport.height)
                guard wf >= 0.025 && wf <= 0.20 else { return nil }
                guard hf >= 0.015 && hf <= 0.16 else { return nil }
                let aspect = rect.width / max(1, rect.height)
                guard aspect >= 0.50 && aspect <= 1.85 else { return nil }

                let center = CGPoint(x: rect.midX, y: rect.midY)
                let nx = (center.x - viewport.minX) / max(1, viewport.width)
                let ny = (center.y - viewport.minY) / max(1, viewport.height)
                guard ny >= 0.52 else { return nil }

                // Prefer compact/circular green controls and, only as a weak
                // tie-breaker, the lower-left portion where the carrying close
                // control normally lives. There is no calibrated absolute tap.
                let shapePenalty = abs(log(max(0.001, aspect)))
                let locationPenalty = nx * 0.20 + abs(ny - 0.88) * 0.08
                let areaBonus = min(0.10, Double(count) / contentArea * 8.0)
                return (center, shapePenalty + locationPenalty - areaBonus)
            }
            .sorted { $0.1 < $1.1 }

        return candidates.first?.0
    }


}
