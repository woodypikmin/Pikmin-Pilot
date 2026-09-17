
import UIKit

@MainActor
final class SingleDispatchProbe: ObservableObject {
    static let shared = SingleDispatchProbe()

    @Published var status = "Not started"

    private var bgTask:
        UIBackgroundTaskIdentifier =
        .invalid

    private let pinkGrid: [
        (Double, Double)
    ] = [
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

    static var finalScreenshotURL: URL {
        FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent(
            "stage3_final.png"
        )
    }

    func runOneDispatch() {
        UserDefaults.standard.set(
            "",
            forKey:
                "stage3Status"
        )

        persist(
            "START: launching Pikmin"
        )

        bgTask =
            UIApplication.shared
            .beginBackgroundTask(
                withName:
                    "PikminSingleDispatch"
            ) {
                [weak self] in

                self?.persist(
                    "FAILED: iOS background time expired"
                )

                self?
                    .finishBackgroundTask()
            }

        Task {
            do {
                try await runFlow()
            }
            catch {
                persist(
                    "FAILED: \(error.localizedDescription)"
                )

                finishBackgroundTask()
            }
        }
    }

    private func persist(
        _ text: String
    ) {
        status = text

        UserDefaults.standard.set(
            text,
            forKey:
                "stage3Status"
        )
    }

    private func normalizedTap(
        pixel: CGPoint,
        image: UIImage
    ) async throws {
        guard let cg =
            image.cgImage
        else {
            throw
                WDAError
                .invalidScreenshot
        }

        let screen =
            try await
            WDAClient.shared
            .windowSize()

        let x =
            Double(pixel.x)
            /
            Double(cg.width)
            *
            Double(screen.width)

        let y =
            Double(pixel.y)
            /
            Double(cg.height)
            *
            Double(screen.height)

        try await
            WDAClient.shared
            .tap(
                x: x,
                y: y
            )
    }

    private func runFlow() async throws {
        do {
            try await
                WDAClient.shared
                .launchPikmin()
        }
        catch {
            // The foreground switch can interrupt the final response.
        }

        try await sleep(3.5)

        // ----------------------------------------------------
        // 1. AVAILABLE fruit
        // ----------------------------------------------------
        persist(
            "1/7 Detecting AVAILABLE fruit..."
        )

        let listImage =
            try await
            WDAClient.shared
            .screenshot()

        let result =
            await
            FruitDetector
            .detect(
                in: listImage
            )

        guard let fruit =
            result.fruits.first
        else {
            throw
                WDAError.server(
                    "No safe AVAILABLE fruit detected."
                )
        }

        try await normalizedTap(
            pixel:
                fruit.center,
            image:
                listImage
        )

        persist(
            "1/7 AVAILABLE tapped"
        )

        try await sleep(1.0)

        // ----------------------------------------------------
        // 2. 前往探險
        // ----------------------------------------------------
        persist(
            "2/7 Looking for 前往探險..."
        )

        guard let expedition =
            try await waitForPoint(
                attempts: 16,
                delay: 0.40,
                detector:
                    ImageAutomationDetector
                    .detectExpeditionButton
            )
        else {
            throw
                WDAError.server(
                    "Could not detect 前往探險."
                )
        }

        try await normalizedTap(
            pixel:
                expedition.point,
            image:
                expedition.image
        )

        persist(
            "2/7 前往探險 tapped"
        )

        try await sleep(1.0)

        // ----------------------------------------------------
        // 3. Pink filter
        // ----------------------------------------------------
        persist(
            "3/7 Looking for pink filter..."
        )

        let screen =
            try await
            WDAClient.shared
            .windowSize()

        var pinkFound:
            (
                point: CGPoint,
                image: UIImage
            )?

        for attempt in 0...4 {
            let image =
                try await
                WDAClient.shared
                .screenshot()

            if let pink =
                ImageAutomationDetector
                .detectPinkFilter(
                    in: image
                ) {
                pinkFound =
                    (
                        pink,
                        image
                    )

                break
            }

            if attempt == 4 {
                break
            }

            try await
                WDAClient.shared
                .swipe(
                    fromX:
                        Double(
                            screen.width
                        )
                        * 0.86,
                    fromY:
                        Double(
                            screen.height
                        )
                        * 0.432,
                    toX:
                        Double(
                            screen.width
                        )
                        * 0.48,
                    toY:
                        Double(
                            screen.height
                        )
                        * 0.432,
                    duration:
                        0.35
                )

            try await sleep(0.55)
        }

        guard let pink =
            pinkFound
        else {
            throw
                WDAError.server(
                    "Could not reveal/detect pink filter."
                )
        }

        try await normalizedTap(
            pixel:
                pink.point,
            image:
                pink.image
        )

        persist(
            "3/7 Pink filter tapped"
        )

        try await sleep(0.7)

        // ----------------------------------------------------
        // 4. Select 12 pink Pikmin
        // ----------------------------------------------------
        persist(
            "4/7 Selecting 12 pink Pikmin..."
        )

        for (
            nx,
            ny
        ) in pinkGrid {
            try await
                WDAClient.shared
                .tap(
                    x:
                        Double(
                            screen.width
                        )
                        * nx,
                    y:
                        Double(
                            screen.height
                        )
                        * ny
                )

            try await sleep(0.12)
        }

        try await sleep(0.5)

        // ----------------------------------------------------
        // 5. Active GO
        // ----------------------------------------------------
        persist(
            "5/7 Waiting for active GO..."
        )

        guard let go =
            try await waitForPoint(
                attempts: 12,
                delay: 0.35,
                detector:
                    ImageAutomationDetector
                    .detectActiveGO
            )
        else {
            throw
                WDAError.server(
                    "12 taps sent but active GO was not detected."
                )
        }

        try await normalizedTap(
            pixel:
                go.point,
            image:
                go.image
        )

        persist(
            "5/7 GO tapped"
        )

        try await sleep(0.8)

        // ----------------------------------------------------
        // 6. Carrying X
        // ----------------------------------------------------
        persist(
            "6/7 Waiting for carrying-screen X..."
        )

        guard let close =
            try await waitForPoint(
                attempts: 50,
                delay: 0.40,
                detector:
                    ImageAutomationDetector
                    .detectCarryingClose
            )
        else {
            throw
                WDAError.server(
                    "Carrying-screen green X was not detected. Stage 3.1 uses the fixed lower-left green-circle detector."
                )
        }

        try await normalizedTap(
            pixel:
                close.point,
            image:
                close.image
        )

        persist(
            "6/7 Carrying X tapped"
        )

        try await sleep(1.0)

        // ----------------------------------------------------
        // 7. Save final screen, stop
        // ----------------------------------------------------
        let finalImage =
            try await
            WDAClient.shared
            .screenshot()

        if let png =
            finalImage.pngData() {
            try png.write(
                to:
                    Self.finalScreenshotURL,
                options:
                    .atomic
            )
        }

        persist(
            """
            SUCCESS: ONE FULL DISPATCH COMPLETED
            AVAILABLE -> 前往探險 -> pink -> 12 -> GO -> X

            This test intentionally stops after one dispatch.
            """
        )

        finishBackgroundTask()
    }

    private func waitForPoint(
        attempts: Int,
        delay: Double,
        detector:
            @escaping
            (UIImage) -> CGPoint?
    ) async throws
    ->
    (
        point: CGPoint,
        image: UIImage
    )? {
        for _ in 0..<attempts {
            let image =
                try await
                WDAClient.shared
                .screenshot()

            if let point =
                detector(
                    image
                ) {
                return (
                    point,
                    image
                )
            }

            try await sleep(
                delay
            )
        }

        return nil
    }

    private func sleep(
        _ seconds: Double
    ) async throws {
        try await Task.sleep(
            nanoseconds:
                UInt64(
                    seconds
                    * 1_000_000_000
                )
        )
    }

    private func finishBackgroundTask() {
        if bgTask !=
            .invalid {
            UIApplication.shared
                .endBackgroundTask(
                    bgTask
                )

            bgTask =
                .invalid
        }
    }
}
