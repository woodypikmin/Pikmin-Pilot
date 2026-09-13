
import Foundation
import UIKit

enum WDAError: LocalizedError {
    case invalidResponse
    case server(String)
    case noSession
    case invalidScreenshot

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from WDA."

        case .server(let s):
            return s

        case .noSession:
            return "Create GENERIC session first."

        case .invalidScreenshot:
            return "Could not decode screenshot."
        }
    }
}

actor WDAClient {
    static let shared = WDAClient()

    private let base =
        URL(
            string:
                "http://127.0.0.1:8100"
        )!

    private var sessionId:
        String?

    // Stage 4.3:
    // screen size never changes during this run, so do not ask WDA again
    // on every round. This removes one of the requests that was timing out
    // before round #2 could tap its fruit.
    private var cachedWindowSize:
        CGSize?

    // ---------------------------------------------------------
    // LOW-LEVEL REQUEST
    // ---------------------------------------------------------

    private func request(
        path: String,
        method: String = "GET",
        json: [String: Any]? = nil,
        timeout: TimeInterval = 8
    ) async throws -> [String: Any] {
        let url =
            base.appendingPathComponent(
                path
            )

        var req =
            URLRequest(
                url: url
            )

        req.httpMethod =
            method

        req.timeoutInterval =
            timeout

        req.cachePolicy =
            .reloadIgnoringLocalCacheData

        if let json {
            req.setValue(
                "application/json",
                forHTTPHeaderField:
                    "Content-Type"
            )

            req.httpBody =
                try JSONSerialization
                    .data(
                        withJSONObject:
                            json
                    )
        }

        do {
            let (
                data,
                response
            ) =
                try await
                URLSession.shared
                .data(
                    for: req
                )

            guard let http =
                response
                as?
                HTTPURLResponse
            else {
                throw
                    WDAError
                    .invalidResponse
            }

            guard (
                200...299
            )
            .contains(
                http.statusCode
            )
            else {
                let body =
                    String(
                        data: data,
                        encoding:
                            .utf8
                    )
                    ??
                    "HTTP \(http.statusCode)"

                throw
                    WDAError
                    .server(
                        "\(method) /\(path) -> \(body)"
                    )
            }

            let object =
                try JSONSerialization
                    .jsonObject(
                        with: data
                    )

            guard let dict =
                object
                as?
                [String: Any]
            else {
                throw
                    WDAError
                    .invalidResponse
            }

            return dict
        }
        catch {
            if isTimeout(
                error
            ) {
                throw
                    WDAError
                    .server(
                        "TIMEOUT: \(method) /\(path)"
                    )
            }

            throw error
        }
    }

    private func isTimeout(
        _ error: Error
    ) -> Bool {
        if let e =
            error
            as?
            URLError {
            return (
                e.code ==
                    .timedOut
            )
        }

        let ns =
            error
            as NSError

        return (
            ns.domain ==
                NSURLErrorDomain
            &&
            ns.code ==
                NSURLErrorTimedOut
        )
    }

    private func isRetryable(
        _ error: Error
    ) -> Bool {
        if let e =
            error
            as?
            URLError {
            return [
                URLError.Code.timedOut,
                .networkConnectionLost,
                .cannotConnectToHost,
                .cannotFindHost,
                .notConnectedToInternet
            ]
            .contains(
                e.code
            )
        }

        let text =
            error
            .localizedDescription
            .lowercased()

        return (
            text.contains(
                "timeout"
            )
            ||
            text.contains(
                "timed out"
            )
            ||
            text.contains(
                "connection"
            )
            ||
            text.contains(
                "invalid response"
            )
        )
    }

    private func retryingRequest(
        path: String,
        method: String = "GET",
        json: [String: Any]? = nil,
        timeout: TimeInterval,
        attempts: Int
    ) async throws -> [String: Any] {
        var lastError:
            Error =
            WDAError.invalidResponse

        for attempt in 1...attempts {
            do {
                return try await
                    request(
                        path: path,
                        method: method,
                        json: json,
                        timeout:
                            timeout
                    )
            }
            catch {
                lastError =
                    error

                guard attempt <
                    attempts,
                    isRetryable(
                        error
                    )
                else {
                    break
                }

                let delay =
                    0.30 *
                    Double(
                        attempt
                    )

                try? await
                    Task.sleep(
                        nanoseconds:
                            UInt64(
                                delay
                                *
                                1_000_000_000
                            )
                    )
            }
        }

        throw
            WDAError
            .server(
                "\(method) /\(path) failed after \(attempts) attempt(s). Last error: \(lastError.localizedDescription)"
            )
    }

    // ---------------------------------------------------------
    // SESSION
    // ---------------------------------------------------------

    private func ensureSession()
        throws -> String {
        if let id =
            sessionId {
            return id
        }

        if let saved =
            UserDefaults
                .standard
                .string(
                    forKey:
                        "lastWDASessionId"
                ),
           !saved.isEmpty {
            sessionId =
                saved

            return saved
        }

        throw
            WDAError
            .noSession
    }

    func status()
        async throws {
        _ =
            try await
            retryingRequest(
                path:
                    "status",
                timeout:
                    5,
                attempts:
                    3
            )
    }

    func createGenericSession()
        async throws -> String {
        let d =
            try await
            request(
                path:
                    "session",
                method:
                    "POST",
                json: [
                    "capabilities": [
                        "alwaysMatch": [:]
                    ]
                ],
                timeout:
                    30
            )

        var found:
            String?

        if let id =
            d[
                "sessionId"
            ]
            as?
            String {
            found =
                id
        }

        if found == nil,
           let value =
            d[
                "value"
            ]
            as?
            [String: Any],
           let id =
            value[
                "sessionId"
            ]
            as?
            String {
            found =
                id
        }

        guard let id =
            found,
              !id.isEmpty
        else {
            throw
                WDAError
                .server(
                    "No sessionId returned: \(d)"
                )
        }

        sessionId =
            id

        cachedWindowSize =
            nil

        UserDefaults.standard
            .set(
                id,
                forKey:
                    "lastWDASessionId"
            )

        return id
    }

    // ---------------------------------------------------------
    // APP / SCREENSHOT
    // ---------------------------------------------------------

    func launchPikmin()
        async throws {
        let id =
            try ensureSession()

        _ =
            try await
            retryingRequest(
                path:
                    "session/\(id)/wda/apps/launch",
                method:
                    "POST",
                json: [
                    "bundleId":
                        "com.nianticlabs.pikmin"
                ],
                timeout:
                    8,
                attempts:
                    2
            )
    }


    // Bring an already-running app to foreground without intentionally
    // terminating/restarting it. Used between dispatches to wake Controller
    // and obtain a fresh iOS background-execution window.
    func activateApp(
        bundleId: String
    ) async throws {
        let id =
            try ensureSession()

        _ =
            try await
            request(
                path:
                    "session/\(id)/wda/apps/activate",
                method:
                    "POST",
                json: [
                    "bundleId":
                        bundleId
                ],
                timeout:
                    8
            )
    }

    func screenshot()
        async throws
        -> UIImage {
        // GET /screenshot is safe to retry.
        let d =
            try await
            retryingRequest(
                path:
                    "screenshot",
                timeout:
                    7,
                attempts:
                    4
            )

        guard let b64 =
            d[
                "value"
            ]
            as?
            String,
              let data =
            Data(
                base64Encoded:
                    b64
            ),
              let image =
            UIImage(
                data:
                    data
            )
        else {
            throw
                WDAError
                .invalidScreenshot
        }

        return image
    }

    // ---------------------------------------------------------
    // SIZE
    // ---------------------------------------------------------

    func windowSize()
        async throws
        -> CGSize {
        if let cached =
            cachedWindowSize {
            return cached
        }

        let id =
            try ensureSession()

        let d =
            try await
            retryingRequest(
                path:
                    "session/\(id)/window/size",
                timeout:
                    6,
                attempts:
                    3
            )

        if let value =
            d[
                "value"
            ]
            as?
            [String: Any] {
            let w =
                (
                    value[
                        "width"
                    ]
                    as?
                    NSNumber
                )?
                .doubleValue
                ??
                402

            let h =
                (
                    value[
                        "height"
                    ]
                    as?
                    NSNumber
                )?
                .doubleValue
                ??
                874

            let size =
                CGSize(
                    width: w,
                    height: h
                )

            cachedWindowSize =
                size

            return size
        }

        let fallback =
            CGSize(
                width: 402,
                height: 874
            )

        cachedWindowSize =
            fallback

        return fallback
    }

    // ---------------------------------------------------------
    // TAP / SWIPE
    //
    // Important:
    // We DO NOT blindly retry a tap after a timeout because the tap might
    // already have reached the phone. Blind double-tapping is especially
    // dangerous for the carrying-screen X.
    // ---------------------------------------------------------

    func tap(
        x: Double,
        y: Double
    ) async throws {
        let id =
            try ensureSession()

        let body:
            [String: Any] = [
                "x": x,
                "y": y
            ]

        do {
            _ =
                try await
                request(
                    path:
                        "session/\(id)/wda/tap",
                    method:
                        "POST",
                    json:
                        body,
                    timeout:
                        8
                )
        }
        catch {
            // Only fall back to the alternate endpoint for a non-timeout
            // endpoint/protocol failure. A timed-out tap may already have
            // been delivered, so don't blindly send it twice.
            let lower =
                error
                .localizedDescription
                .lowercased()

            if lower.contains(
                "timeout"
            )
            ||
            lower.contains(
                "timed out"
            ) {
                throw
                    WDAError
                    .server(
                        "TIMEOUT during tap at x=\(String(format: "%.1f", x)) y=\(String(format: "%.1f", y)). Tap was not automatically repeated."
                    )
            }

            _ =
                try await
                request(
                    path:
                        "session/\(id)/wda/tap/0",
                    method:
                        "POST",
                    json:
                        body,
                    timeout:
                        8
                )
        }
    }

    func swipe(
        fromX: Double,
        fromY: Double,
        toX: Double,
        toY: Double,
        duration: Double = 0.35
    ) async throws {
        let id =
            try ensureSession()

        _ =
            try await
            request(
                path:
                    "session/\(id)/wda/dragfromtoforduration",
                method:
                    "POST",
                json: [
                    "fromX":
                        fromX,
                    "fromY":
                        fromY,
                    "toX":
                        toX,
                    "toY":
                        toY,
                    "duration":
                        duration
                ],
                timeout:
                    8
            )
    }

    // Called between dispatches.
    // This is a harmless GET-only health check.
    func prepareForNextDispatch()
        async throws {
        try await status()

        // Warm one screenshot while we're still on the list.
        // screenshot() already has retries.
        _ =
            try await screenshot()
    }
}
