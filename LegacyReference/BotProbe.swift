
import UIKit

@MainActor
final class BotProbe: ObservableObject {
    static let shared = BotProbe()

    @Published var status = "Ready"

    private var bgTask:
        UIBackgroundTaskIdentifier =
        .invalid

    static var resultURL: URL {
        FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent(
            "stage2_4_detection.png"
        )
    }

    func detectOnly() {
        run(
            tapFirstAvailable:
                false
        )
    }

    func detectAndTap() {
        run(
            tapFirstAvailable:
                true
        )
    }

    private func run(
        tapFirstAvailable:
            Bool
    ) {
        status =
            tapFirstAvailable
            ? "Launching Pikmin; card-first detect + tap"
            : "Launching Pikmin; card-first detect only"

        UserDefaults.standard.set(
            "",
            forKey:
                "stage2Status"
        )

        bgTask =
            UIApplication.shared
            .beginBackgroundTask(
                withName:
                    "PikminStage2_4"
            ) {
                [weak self] in

                UserDefaults
                    .standard
                    .set(
                        "FAILED: iOS expired background task",
                        forKey:
                            "stage2Status"
                    )

                self?
                    .finishBackgroundTask()
            }

        Task {
            do {
                try await
                    WDAClient.shared
                    .launchPikmin()
            }
            catch {
                // Launch can still succeed
                // while Controller backgrounds.
            }

            try? await Task.sleep(
                nanoseconds:
                    4_000_000_000
            )

            do {
                let image =
                    try await
                    WDAClient.shared
                    .screenshot()

                let result =
                    await
                    FruitDetector
                    .detect(
                        in: image
                    )

                let annotated =
                    FruitDetector
                    .annotated(
                        image: image,
                        result: result
                    )

                if let png =
                    annotated
                    .pngData() {
                    try png.write(
                        to:
                            Self.resultURL,
                        options:
                            .atomic
                    )
                }

                let busyCards =
                    result.cards
                    .filter {
                        $0.state ==
                            .busy
                    }

                let completeCards =
                    result.cards
                    .filter {
                        $0.state ==
                            .complete
                    }

                let partialCards =
                    result.cards
                    .filter {
                        $0.partial
                    }

                let available =
                    result.fruits

                let blockedObjects =
                    result.blockedObjects

                var text = """
                PARTIAL-CARD + FRUIT-NAME DETECTION OK
                available=\(available.count)
                busy_cards=\(busyCards.count)
                complete_cards=\(completeCards.count)
                partial_blocked_cards=\(partialCards.count)
                blocked_objects=\(blockedObjects.count)

                """

                for (
                    index,
                    fruit
                ) in
                    available
                    .enumerated() {
                    text += """
                    AVAILABLE #\(index + 1)
                    label: \(fruit.labelText)
                    fill: \(String(format: "%.2f", fruit.fill))

                    """
                }

                for (
                    index,
                    object
                ) in
                    blockedObjects
                    .enumerated() {
                    text += """
                    BLOCKED OBJECT #\(index + 1)
                    OCR label: \(object.labelText)

                    """
                }

                if tapFirstAvailable,
                   let first =
                    available.first {
                    let screen =
                        try await
                        WDAClient.shared
                        .windowSize()

                    guard let cg =
                        image.cgImage
                    else {
                        throw
                            WDAError
                            .invalidScreenshot
                    }

                    let x =
                        Double(
                            first.center.x
                        )
                        /
                        Double(
                            cg.width
                        )
                        *
                        Double(
                            screen.width
                        )

                    let y =
                        Double(
                            first.center.y
                        )
                        /
                        Double(
                            cg.height
                        )
                        *
                        Double(
                            screen.height
                        )

                    try await
                        WDAClient.shared
                        .tap(
                            x: x,
                            y: y
                        )

                    text += """
                    TAP SENT
                    x=\(String(format: "%.1f", x))
                    y=\(String(format: "%.1f", y))
                    """
                }

                UserDefaults
                    .standard
                    .set(
                        text,
                        forKey:
                            "stage2Status"
                    )

                await MainActor.run {
                    self.status =
                        text

                    self
                        .finishBackgroundTask()
                }
            }
            catch {
                let text =
                    "FAILED: \(error.localizedDescription)"

                UserDefaults
                    .standard
                    .set(
                        text,
                        forKey:
                            "stage2Status"
                    )

                await MainActor.run {
                    self.status =
                        text

                    self
                        .finishBackgroundTask()
                }
            }
        }
    }

    private func finishBackgroundTask() {
        if bgTask !=
            .invalid {
            UIApplication
                .shared
                .endBackgroundTask(
                    bgTask
                )

            bgTask =
                .invalid
        }
    }
}
