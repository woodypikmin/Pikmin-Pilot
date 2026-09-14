
import UIKit
import CoreGraphics
import Vision

enum CardState: String {
    case available = "AVAILABLE"
    case busy = "BUSY"
    case complete = "COMPLETE"
    case blocked = "BLOCKED"
}

struct OCRItem {
    let text: String
    let rect: CGRect
}

struct StatusCard: Identifiable {
    let id = UUID()
    let state: CardState
    let rect: CGRect
    let partial: Bool
}

enum ExpeditionItemKind: String {
    case fruit = "FRUIT"
    case seedling = "SEEDLING"
    case unknown = "UNKNOWN"
}

struct FruitCandidate: Identifiable {
    let id = UUID()
    var rect: CGRect
    var center: CGPoint
    var fill: Double
    var state: CardState
    var kind: ExpeditionItemKind = .unknown
    var labelText: String = ""
}

struct DetectionResult {
    var fruits: [FruitCandidate]          // tappable AVAILABLE fruit
    var seedlings: [FruitCandidate]       // OCR-confirmed AVAILABLE seedlings
    var blockedObjects: [FruitCandidate] // object-like item but not safe
    var cards: [StatusCard]              // BUSY / COMPLETE / partial BLOCKED
    var ocr: [OCRItem]
}

final class FruitDetector {
    struct Pixel {
        let r: UInt8
        let g: UInt8
        let b: UInt8
    }

    struct HSV {
        let h: Double
        let s: Double
        let v: Double
    }

    struct LineBand {
        let state: CardState
        let column: Int
        let y0: Int
        let y1: Int

        var centerY: Double {
            Double(y0 + y1) / 2.0
        }
    }

    // MARK: - Pixel helpers

    static func rawPixels(_ image: UIImage) -> (Int, Int, [UInt8])? {
        guard let cg = image.cgImage else {
            return nil
        }

        let w = cg.width
        let h = cg.height
        let bytesPerRow = w * 4

        var data = [UInt8](
            repeating: 0,
            count: h * bytesPerRow
        )

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

        ctx.draw(
            cg,
            in: CGRect(
                x: 0,
                y: 0,
                width: w,
                height: h
            )
        )

        return (w, h, data)
    }

    static func pixel(
        _ data: [UInt8],
        width: Int,
        x: Int,
        y: Int
    ) -> Pixel {
        let i = (y * width + x) * 4

        return Pixel(
            r: data[i],
            g: data[i + 1],
            b: data[i + 2]
        )
    }

    static func hsv(_ p: Pixel) -> HSV {
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

        if h < 0 {
            h += 360.0
        }

        let s = mx == 0 ? 0 : d / mx

        return HSV(
            h: h,
            s: s,
            v: mx
        )
    }

    // MARK: - OCR once per screenshot

    static func recognizeAllText(
        image: UIImage
    ) async -> [OCRItem] {
        guard let cg = image.cgImage else {
            return []
        }

        let w = CGFloat(cg.width)
        let h = CGFloat(cg.height)

        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                guard error == nil else {
                    continuation.resume(returning: [])
                    return
                }

                let observations =
                    request.results as? [VNRecognizedTextObservation] ?? []

                var items: [OCRItem] = []

                for observation in observations {
                    guard let text =
                        observation.topCandidates(1).first?.string
                    else {
                        continue
                    }

                    let box = observation.boundingBox

                    let rect = CGRect(
                        x: box.minX * w,
                        y: (1.0 - box.maxY) * h,
                        width: box.width * w,
                        height: box.height * h
                    )

                    items.append(
                        OCRItem(
                            text: text,
                            rect: rect
                        )
                    )
                }

                continuation.resume(returning: items)
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.minimumTextHeight = 0.010

            if let supported =
                try? request.supportedRecognitionLanguages() {
                var langs: [String] = []

                if supported.contains("zh-Hant") {
                    langs.append("zh-Hant")
                }

                if supported.contains("zh-Hans") {
                    langs.append("zh-Hans")
                }

                if supported.contains("en-US") {
                    langs.append("en-US")
                }

                if !langs.isEmpty {
                    request.recognitionLanguages = langs
                }
            }

            let handler = VNImageRequestHandler(
                cgImage: cg,
                orientation: .up,
                options: [:]
            )

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(returning: [])
                }
            }
        }
    }

    // MARK: - Card border colors

    static func isBusyBorderPixel(_ p: Pixel) -> Bool {
        let r = Int(p.r)
        let g = Int(p.g)
        let b = Int(p.b)

        let mx = max(r, g, b)
        let mn = min(r, g, b)

        return (
            r > 230 &&
            g > 220 &&
            b > 220 &&
            r - g >= 3 &&
            r - b >= 2 &&
            mx - mn < 35
        )
    }

    static func isCompleteBorderPixel(_ p: Pixel) -> Bool {
        let r = Int(p.r)
        let g = Int(p.g)
        let b = Int(p.b)

        let mx = max(r, g, b)
        let mn = min(r, g, b)

        return (
            g > 220 &&
            r > 200 &&
            b > 200 &&
            g - r >= 4 &&
            g - b >= 2 &&
            mx - mn < 40
        )
    }

    static func borderMatches(
        state: CardState,
        pixel p: Pixel
    ) -> Bool {
        switch state {
        case .busy:
            return isBusyBorderPixel(p)

        case .complete:
            return isCompleteBorderPixel(p)

        default:
            return false
        }
    }

    // MARK: - Horizontal card borders

    static func horizontalBorderBands(
        data: [UInt8],
        width w: Int,
        height h: Int
    ) -> [LineBand] {
        let columnWidth = Double(w) / 3.0
        let startY = Int(Double(h) * 0.16)
        let endY = Int(Double(h) * 0.98)

        var rawHits: [(CardState, Int, Int)] = []

        for y in startY..<endY {
            for col in 0..<3 {
                let x0 = max(
                    0,
                    Int(Double(col) * columnWidth + Double(w) * 0.030)
                )

                let x1 = min(
                    w - 1,
                    Int(Double(col + 1) * columnWidth - Double(w) * 0.030)
                )

                if x1 <= x0 {
                    continue
                }

                let total = x1 - x0 + 1

                var busyCount = 0
                var completeCount = 0

                for x in x0...x1 {
                    let p = pixel(
                        data,
                        width: w,
                        x: x,
                        y: y
                    )

                    if isBusyBorderPixel(p) {
                        busyCount += 1
                    }

                    if isCompleteBorderPixel(p) {
                        completeCount += 1
                    }
                }

                if Double(busyCount) / Double(total) >= 0.55 {
                    rawHits.append((.busy, col, y))
                }

                if Double(completeCount) / Double(total) >= 0.55 {
                    rawHits.append((.complete, col, y))
                }
            }
        }

        var bands: [LineBand] = []

        for state in [CardState.busy, CardState.complete] {
            for col in 0..<3 {
                let ys = rawHits
                    .filter {
                        $0.0 == state &&
                        $0.1 == col
                    }
                    .map { $0.2 }
                    .sorted()

                if ys.isEmpty {
                    continue
                }

                var start = ys[0]
                var previous = ys[0]

                for y in ys.dropFirst() {
                    if y <= previous + 1 {
                        previous = y
                    } else {
                        bands.append(
                            LineBand(
                                state: state,
                                column: col,
                                y0: start,
                                y1: previous
                            )
                        )

                        start = y
                        previous = y
                    }
                }

                bands.append(
                    LineBand(
                        state: state,
                        column: col,
                        y0: start,
                        y1: previous
                    )
                )
            }
        }

        return bands
    }

    // MARK: - Partial card protection

    static func verticalBorderRows(
        data: [UInt8],
        width w: Int,
        height h: Int,
        state: CardState,
        column col: Int,
        y0: Int,
        y1: Int
    ) -> Int {
        if y1 <= y0 {
            return 0
        }

        let columnWidth = Double(w) / 3.0

        let expectedLeft =
            Double(col) * columnWidth +
            Double(w) * 0.030

        let expectedRight =
            Double(col + 1) * columnWidth -
            Double(w) * 0.030

        let strip = max(
            3,
            Int(Double(w) * 0.010)
        )

        let lx0 = max(0, Int(expectedLeft) - strip)
        let lx1 = min(w - 1, Int(expectedLeft) + strip)

        let rx0 = max(0, Int(expectedRight) - strip)
        let rx1 = min(w - 1, Int(expectedRight) + strip)

        let yy0 = max(0, y0)
        let yy1 = min(h - 1, y1)

        if yy1 <= yy0 {
            return 0
        }

        var rows = 0

        for y in yy0...yy1 {
            var hits = 0

            for x in lx0...lx1 {
                if borderMatches(
                    state: state,
                    pixel: pixel(
                        data,
                        width: w,
                        x: x,
                        y: y
                    )
                ) {
                    hits += 1
                }
            }

            for x in rx0...rx1 {
                if borderMatches(
                    state: state,
                    pixel: pixel(
                        data,
                        width: w,
                        x: x,
                        y: y
                    )
                ) {
                    hits += 1
                }
            }

            if hits >= 2 {
                rows += 1
            }
        }

        return rows
    }

    static func cardRect(
        column col: Int,
        y0: Double,
        y1: Double,
        width w: Int
    ) -> CGRect {
        let columnWidth = Double(w) / 3.0

        let x0 =
            Double(col) * columnWidth +
            Double(w) * 0.024

        let x1 =
            Double(col + 1) * columnWidth -
            Double(w) * 0.024

        return CGRect(
            x: x0,
            y: y0,
            width: x1 - x0,
            height: max(1, y1 - y0)
        )
    }

    static func detectStatusCards(
        data: [UInt8],
        width w: Int,
        height h: Int
    ) -> [StatusCard] {
        let bands = horizontalBorderBands(
            data: data,
            width: w,
            height: h
        )

        var cards: [StatusCard] = []

        for state in [CardState.busy, CardState.complete] {
            for col in 0..<3 {
                let local = bands
                    .filter {
                        $0.state == state &&
                        $0.column == col
                    }
                    .sorted {
                        $0.centerY < $1.centerY
                    }

                if local.isEmpty {
                    continue
                }

                var used = Set<Int>()

                // A) Pair complete top+bottom borders.
                for i in 0..<local.count {
                    if used.contains(i) {
                        continue
                    }

                    let top = local[i]
                    var best: Int?

                    if i + 1 < local.count {
                        for j in (i + 1)..<local.count {
                            if used.contains(j) {
                                continue
                            }

                            let bottom = local[j]
                            let distance =
                                bottom.centerY -
                                top.centerY

                            if distance >= Double(h) * 0.105 &&
                                distance <= Double(h) * 0.175 {
                                best = j
                                break
                            }

                            if distance > Double(h) * 0.175 {
                                break
                            }
                        }
                    }

                    if let j = best {
                        used.insert(i)
                        used.insert(j)

                        cards.append(
                            StatusCard(
                                state: state,
                                rect: cardRect(
                                    column: col,
                                    y0: Double(local[i].y0),
                                    y1: Double(local[j].y1),
                                    width: w
                                ),
                                partial: false
                            )
                        )
                    }
                }

                // B) Any unpaired horizontal border may be a card clipped by
                //    top/bottom of the viewport. Use vertical side-border
                //    evidence to decide which side of the line contains card.
                for i in 0..<local.count {
                    if used.contains(i) {
                        continue
                    }

                    let band = local[i]
                    let y = Int(band.centerY)

                    let span = Int(Double(h) * 0.17)
                    let gap = max(3, Int(Double(h) * 0.004))

                    let aboveRows = verticalBorderRows(
                        data: data,
                        width: w,
                        height: h,
                        state: state,
                        column: col,
                        y0: y - span,
                        y1: y - gap
                    )

                    let belowRows = verticalBorderRows(
                        data: data,
                        width: w,
                        height: h,
                        state: state,
                        column: col,
                        y0: y + gap,
                        y1: y + span
                    )

                    let minimumSideRows =
                        max(10, Int(Double(h) * 0.018))

                    if aboveRows >= minimumSideRows &&
                        aboveRows > belowRows {
                        // This is the BOTTOM of a card clipped at the top.
                        cards.append(
                            StatusCard(
                                state: .blocked,
                                rect: cardRect(
                                    column: col,
                                    y0: max(
                                        0,
                                        Double(y - span)
                                    ),
                                    y1: Double(band.y1),
                                    width: w
                                ),
                                partial: true
                            )
                        )
                    } else if belowRows >= minimumSideRows {
                        // This is the TOP of a card clipped at the bottom.
                        cards.append(
                            StatusCard(
                                state: .blocked,
                                rect: cardRect(
                                    column: col,
                                    y0: Double(band.y0),
                                    y1: min(
                                        Double(h),
                                        Double(y + span)
                                    ),
                                    width: w
                                ),
                                partial: true
                            )
                        )
                    }
                }
            }
        }

        // Deduplicate highly-overlapping cards.
        var dedup: [StatusCard] = []

        for card in cards.sorted(by: {
            $0.rect.minY < $1.rect.minY
        }) {
            let duplicate = dedup.contains { old in
                let intersection =
                    old.rect.intersection(card.rect)

                guard !intersection.isNull else {
                    return false
                }

                let smallerArea = min(
                    old.rect.width * old.rect.height,
                    card.rect.width * card.rect.height
                )

                if smallerArea <= 0 {
                    return false
                }

                return (
                    intersection.width *
                    intersection.height
                ) / smallerArea > 0.78
            }

            if !duplicate {
                dedup.append(card)
            }
        }

        return dedup
    }

    // MARK: - Fruit/object candidates

    static func isFruitColor(
        _ value: HSV
    ) -> Bool {
        let colorful =
            value.s > 0.30 &&
            value.v > 0.24

        let purple =
            value.h >= 235 &&
            value.h <= 335 &&
            value.s > 0.09 &&
            value.v > 0.11

        let red =
            (
                value.h <= 28 ||
                value.h >= 332
            ) &&
            value.s > 0.20 &&
            value.v > 0.18

        return colorful || purple || red
    }

    static func connectedComponents(
        width: Int,
        height: Int,
        mask: [Bool]
    ) -> [(CGRect, Int)] {
        var visited = [Bool](
            repeating: false,
            count: mask.count
        )

        var result: [(CGRect, Int)] = []

        let dirs = [
            (1, 0),
            (-1, 0),
            (0, 1),
            (0, -1)
        ]

        for y in 0..<height {
            for x in 0..<width {
                let idx = y * width + x

                if visited[idx] || !mask[idx] {
                    continue
                }

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

                        if nx < 0 ||
                            ny < 0 ||
                            nx >= width ||
                            ny >= height {
                            continue
                        }

                        let ni = ny * width + nx

                        if visited[ni] || !mask[ni] {
                            continue
                        }

                        visited[ni] = true
                        queue.append((nx, ny))
                    }
                }

                result.append(
                    (
                        CGRect(
                            x: minX,
                            y: minY,
                            width: maxX - minX + 1,
                            height: maxY - minY + 1
                        ),
                        count
                    )
                )
            }
        }

        return result
    }

    static let knownFruitNames: [String] = [
        "青蘋果",
        "蘋果",
        "苹果",
        "檸檬",
        "柠檬",
        "桃子",
        "梅子",
        "柳橙",
        "橘子",
        "橙子",
        "葡萄",
        "青葡萄",
        "草莓",
        "櫻桃",
        "樱桃",
        "藍莓",
        "蓝莓",
        "萊姆",
        "莱姆",
        "酸橙",
        "柚子"
    ]

    static func nearbyLabel(
        for object: CGRect,
        imageWidth w: Int,
        imageHeight h: Int,
        ocr: [OCRItem]
    ) -> String {
        let colWidth = Double(w) / 3.0

        let col = min(
            2,
            max(
                0,
                Int(object.midX / colWidth)
            )
        )

        let x0 =
            Double(col) * colWidth

        let x1 =
            Double(col + 1) * colWidth

        // Only the first label line(s) directly under the object.
        // We intentionally stop before the lower location/expiry lines.
        let y0 =
            object.maxY -
            Double(h) * 0.004

        let y1 =
            min(
                Double(h),
                object.maxY +
                Double(h) * 0.070
            )

        return ocr
            .filter {
                $0.rect.midX >= x0 &&
                $0.rect.midX <= x1 &&
                $0.rect.midY >= y0 &&
                $0.rect.midY <= y1
            }
            .sorted {
                $0.rect.minY < $1.rect.minY
            }
            .map { $0.text }
            .joined(separator: " ")
    }

    /// Expedition-list seedling labels are color-qualified (for example
    /// `灰色花苗`, `藍色花苗`, `粉紅色花苗`). The screen also has a top-level
    /// navigation/tab label that is only `花苗`; that label opens the seedling
    /// inventory/view page and must never be treated as a transport target.
    ///
    /// Require `色花苗` after whitespace/newline normalization so plain
    /// `花苗` is ignored completely.
    static func isSeedlingLabel(_ text: String) -> Bool {
        let normalized = text
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\t", with: "")
        return normalized.contains("色花苗")
    }

    static func isKnownFruitLabel(_ text: String) -> Bool {
        if isSeedlingLabel(text) {
            return false
        }

        return knownFruitNames.contains { name in
            text.contains(name)
        }
    }

    static func objectCandidates(
        data: [UInt8],
        width w: Int,
        height h: Int
    ) -> [(CGRect, Int)] {
        let startY =
            Int(Double(h) * 0.16)

        let endY =
            Int(Double(h) * 0.96)

        var mask = [Bool](
            repeating: false,
            count: w * h
        )

        for y in startY..<endY {
            for x in 0..<w {
                let value = hsv(
                    pixel(
                        data,
                        width: w,
                        x: x,
                        y: y
                    )
                )

                if isFruitColor(value) {
                    mask[y * w + x] = true
                }
            }
        }

        return connectedComponents(
            width: w,
            height: h,
            mask: mask
        )
    }

    static func classifyPlainObjects(
        data: [UInt8],
        width w: Int,
        height h: Int,
        cards: [StatusCard],
        ocr: [OCRItem]
    ) -> (
        available: [FruitCandidate],
        seedlings: [FruitCandidate],
        blocked: [FruitCandidate]
    ) {
        let components = objectCandidates(
            data: data,
            width: w,
            height: h
        )

        let columnWidth =
            Double(w) / 3.0

        var available: [FruitCandidate] = []
        var seedlings: [FruitCandidate] = []
        var blocked: [FruitCandidate] = []

        for (rect, count) in components {
            let bw = rect.width
            let bh = rect.height

            if bw < Double(w) * 0.040 ||
                bw > Double(w) * 0.185 {
                continue
            }

            if bh < Double(h) * 0.018 ||
                bh > Double(h) * 0.110 {
                continue
            }

            let aspect =
                bw / max(1, bh)

            if aspect < 0.48 ||
                aspect > 2.00 {
                continue
            }

            let fill =
                Double(count) /
                max(1, bw * bh)

            if fill < 0.42 {
                continue
            }

            let center = CGPoint(
                x: rect.midX,
                y: rect.midY
            )

            // Anything inside a full OR partial status card is never available.
            if cards.contains(where: {
                $0.rect
                    .insetBy(dx: -8, dy: -8)
                    .contains(center)
            }) {
                continue
            }

            let col = min(
                2,
                max(
                    0,
                    Int(center.x / columnWidth)
                )
            )

            let expectedCenter =
                (Double(col) + 0.5) *
                columnWidth

            // Available fruit is centered in the 3-column grid.
            if abs(center.x - expectedCenter) >
                columnWidth * 0.30 {
                continue
            }

            let label = nearbyLabel(
                for: rect,
                imageWidth: w,
                imageHeight: h,
                ocr: ocr
            )

            let kind: ExpeditionItemKind
            let state: CardState
            if isKnownFruitLabel(label) {
                kind = .fruit
                state = .available
            } else if isSeedlingLabel(label) {
                kind = .seedling
                state = .available
            } else {
                kind = .unknown
                state = .blocked
            }

            let candidate = FruitCandidate(
                rect: rect,
                center: center,
                fill: fill,
                state: state,
                kind: kind,
                labelText: label
            )

            if kind == .fruit {
                available.append(candidate)
            } else if kind == .seedling {
                seedlings.append(candidate)
            } else {
                blocked.append(candidate)
            }
        }

        func dedup(_ input: [FruitCandidate]) -> [FruitCandidate] {
            var output: [FruitCandidate] = []

            for item in input.sorted(by: {
                if abs($0.center.y - $1.center.y) > 15 {
                    return $0.center.y < $1.center.y
                }

                return $0.center.x < $1.center.x
            }) {
                let duplicate = output.contains {
                    abs($0.center.x - item.center.x) <
                        Double(w) * 0.045 &&
                    abs($0.center.y - item.center.y) <
                        Double(h) * 0.035
                }

                if !duplicate {
                    output.append(item)
                }
            }

            return output
        }

        return (
            dedup(available),
            dedup(seedlings),
            dedup(blocked)
        )
    }

    /// Seedlings are much easier and safer to recognize from their visible
    /// `某色花苗` label than from pot color (gray pots in particular are low
    /// saturation and can disappear from the fruit-color mask). Infer a tap
    /// point in the same three-column cell, slightly above the OCR label.
    static func ocrSeedlingCandidates(
        imageWidth w: Int,
        imageHeight h: Int,
        cards: [StatusCard],
        ocr: [OCRItem]
    ) -> [FruitCandidate] {
        let columnWidth = Double(w) / 3.0
        var output: [FruitCandidate] = []

        for item in ocr where isSeedlingLabel(item.text) {
            let col = min(2, max(0, Int(item.rect.midX / columnWidth)))
            let centerX = (Double(col) + 0.5) * columnWidth
            let centerY = max(
                Double(h) * 0.17,
                item.rect.minY - Double(h) * 0.070
            )
            let center = CGPoint(x: centerX, y: centerY)

            // Preserve the Stage 5 card-first rule for seedlings too. A label
            // or inferred pot center that belongs to BUSY/COMPLETE/partial card
            // is never exposed as AVAILABLE.
            let blockedByCard = cards.contains { card in
                card.rect.insetBy(dx: -8, dy: -8).contains(center) ||
                card.rect.insetBy(dx: -8, dy: -8).intersects(item.rect)
            }
            if blockedByCard { continue }

            let rect = CGRect(
                x: centerX - Double(w) * 0.060,
                y: centerY - Double(h) * 0.045,
                width: Double(w) * 0.120,
                height: Double(h) * 0.090
            )

            output.append(
                FruitCandidate(
                    rect: rect,
                    center: center,
                    fill: 1.0,
                    state: .available,
                    kind: .seedling,
                    labelText: item.text
                )
            )
        }

        var dedup: [FruitCandidate] = []
        for item in output.sorted(by: {
            if abs($0.center.y - $1.center.y) > 15 {
                return $0.center.y < $1.center.y
            }
            return $0.center.x < $1.center.x
        }) {
            let duplicate = dedup.contains { old in
                abs(old.center.x - item.center.x) < Double(w) * 0.08 &&
                abs(old.center.y - item.center.y) < Double(h) * 0.06
            }
            if !duplicate { dedup.append(item) }
        }
        return dedup
    }

    // MARK: - Main detection

    static func detect(
        in image: UIImage
    ) async -> DetectionResult {
        guard let (w, h, data) =
            rawPixels(image)
        else {
            return DetectionResult(
                fruits: [],
                seedlings: [],
                blockedObjects: [],
                cards: [],
                ocr: []
            )
        }

        let ocr =
            await recognizeAllText(
                image: image
            )

        let cards =
            detectStatusCards(
                data: data,
                width: w,
                height: h
            )

        let objects =
            classifyPlainObjects(
                data: data,
                width: w,
                height: h,
                cards: cards,
                ocr: ocr
            )

        let inferredSeedlings = ocrSeedlingCandidates(
            imageWidth: w,
            imageHeight: h,
            cards: cards,
            ocr: ocr
        )

        // Merge component-backed and OCR-inferred seedlings without exposing
        // duplicates. OCR is the authoritative safety signal (`色花苗`).
        var seedlings = objects.seedlings
        for item in inferredSeedlings {
            let duplicate = seedlings.contains { old in
                abs(old.center.x - item.center.x) < Double(w) * 0.10 &&
                abs(old.center.y - item.center.y) < Double(h) * 0.08
            }
            if !duplicate { seedlings.append(item) }
        }

        return DetectionResult(
            fruits: objects.available,
            seedlings: seedlings,
            blockedObjects: objects.blocked,
            cards: cards,
            ocr: ocr
        )
    }

    // MARK: - Debug annotation

    static func annotated(
        image: UIImage,
        result: DetectionResult
    ) -> UIImage {
        guard let cg = image.cgImage else {
            return image
        }

        let cgW = CGFloat(cg.width)
        let cgH = CGFloat(cg.height)

        let sx =
            image.size.width / cgW

        let sy =
            image.size.height / cgH

        let renderer =
            UIGraphicsImageRenderer(
                size: image.size
            )

        return renderer.image { _ in
            image.draw(
                in: CGRect(
                    origin: .zero,
                    size: image.size
                )
            )

            // Cards
            for card in result.cards {
                let color: UIColor

                switch card.state {
                case .busy:
                    color = .red

                case .complete:
                    color = .blue

                case .blocked:
                    color = .purple

                default:
                    color = .purple
                }

                color.setStroke()

                let rect = CGRect(
                    x: card.rect.minX * sx,
                    y: card.rect.minY * sy,
                    width: card.rect.width * sx,
                    height: card.rect.height * sy
                )

                let path =
                    UIBezierPath(rect: rect)

                path.lineWidth =
                    card.partial ? 5 : 4

                path.stroke()
            }

            // Tappable fruit
            for fruit in result.fruits {
                UIColor.green.setStroke()

                let rect = CGRect(
                    x: fruit.rect.minX * sx,
                    y: fruit.rect.minY * sy,
                    width: fruit.rect.width * sx,
                    height: fruit.rect.height * sy
                )
                .insetBy(
                    dx: -4,
                    dy: -4
                )

                let path =
                    UIBezierPath(rect: rect)

                path.lineWidth = 4
                path.stroke()
            }

            // OCR-confirmed tappable seedlings / pots.
            for seedling in result.seedlings {
                UIColor.systemTeal.setStroke()

                let rect = CGRect(
                    x: seedling.rect.minX * sx,
                    y: seedling.rect.minY * sy,
                    width: seedling.rect.width * sx,
                    height: seedling.rect.height * sy
                )
                .insetBy(dx: -4, dy: -4)

                let path = UIBezierPath(rect: rect)
                path.lineWidth = 4
                path.stroke()
            }

            // Fruit-like / Pikmin-like / decoration candidates that FAILED
            // the fruit-name safety check.
            for object in result.blockedObjects {
                UIColor.purple.setStroke()

                let rect = CGRect(
                    x: object.rect.minX * sx,
                    y: object.rect.minY * sy,
                    width: object.rect.width * sx,
                    height: object.rect.height * sy
                )
                .insetBy(
                    dx: -3,
                    dy: -3
                )

                let path =
                    UIBezierPath(rect: rect)

                path.lineWidth = 3
                path.stroke()
            }
        }
    }
}
