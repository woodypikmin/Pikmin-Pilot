import Foundation

actor IDeviceEngine {
    struct Result: Sendable {
        let ok: Bool
        let message: String
    }

    private let pairingPath: String
    private let host: String
    private let port: UInt16
    private var persistentSession: UInt = 0

    init(
        pairingPath: String,
        host: String = "10.7.0.1",
        port: UInt16 = 49152
    ) {
        self.pairingPath = pairingPath
        self.host = host
        self.port = port
    }

    func validatePairing() -> Result {
        callBridge { path, message, capacity in
            PPValidateRPPairingFile(path, message, capacity)
        }
    }

    // Stage 11.5.4.9: keep one already-established RPPairing/RSD tunnel alive
    // while the physical network changes from temporary Airplane Mode back to
    // cellular. Session-backed calls below do not reconnect to :49152.
    func openPersistentSession() -> Result {
        if persistentSession != 0 {
            return Result(ok: true, message: "PERSISTENT RSD SESSION ALREADY READY ✅")
        }
        let capacity = 8192
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: capacity)
        buffer.initialize(repeating: 0, count: capacity)
        defer { buffer.deallocate() }

        let handle: UInt = pairingPath.withCString { path in
            host.withCString { hostCString in
                PPPhoneLocalSessionCreate(path, hostCString, port, buffer, capacity)
            }
        }
        let text = String(cString: buffer)
        guard handle != 0 else {
            return Result(ok: false, message: text.isEmpty ? "persistent session create failed" : text)
        }
        persistentSession = handle
        return Result(ok: true, message: text.isEmpty ? "PERSISTENT RSD SESSION READY ✅" : text)
    }

    func closePersistentSession() {
        guard persistentSession != 0 else { return }
        PPPhoneLocalSessionFree(persistentSession)
        persistentSession = 0
    }

    /// Stage 11.5.4.24: create a brand-new RPPairing/RSD session first and only
    /// swap it in after creation succeeds. This lets the iPad post-tail recovery
    /// discard a poisoned DVT/RSD transport without risking the still-live old
    /// session when a fresh :49152 connection is temporarily unavailable.
    /// Existing iPhone paths never call this method.
    func refreshPersistentSessionTransactionally() -> Result {
        let capacity = 8192
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: capacity)
        buffer.initialize(repeating: 0, count: capacity)
        defer { buffer.deallocate() }

        let newHandle: UInt = pairingPath.withCString { path in
            host.withCString { hostCString in
                PPPhoneLocalSessionCreate(path, hostCString, port, buffer, capacity)
            }
        }
        let text = String(cString: buffer)
        guard newHandle != 0 else {
            return Result(
                ok: false,
                message: text.isEmpty
                    ? "transactional persistent-session refresh failed; old session preserved"
                    : "\(text) • old session preserved"
            )
        }

        let oldHandle = persistentSession
        persistentSession = newHandle
        if oldHandle != 0 {
            PPPhoneLocalSessionFree(oldHandle)
        }
        return Result(
            ok: true,
            message: text.isEmpty
                ? "PERSISTENT RSD SESSION REBUILT ✅"
                : "\(text) • previous session retired"
        )
    }

    func hasPersistentSession() -> Bool {
        persistentSession != 0
    }

    func probePersistentSessionHealth() -> Result {
        // This is a real DTX connect over the already-open Adapter, not merely
        // a cached RSD service-list inspection. It proves the persistent tunnel
        // still carries traffic after cellular is restored.
        callPersistent { session, message, capacity in
            PPPhoneLocalSessionBootstrapXCTestDTX(session, message, capacity)
        }
    }

    /// Stage 11.5.4.2: fixed-port transport discriminator for cellular-only.
    /// It intentionally bypasses RPPairing createListener and asks lockdownd
    /// QueryType through the integrated reflector at 10.7.0.1:62078.
    func probeCellularLockdownRoute() -> Result {
        callBridgeWithoutPairing { message, capacity in
            PPProbeCellularLockdownRoute(message, capacity)
        }
    }


    /// Stage 11.5.4.3: prove whether the fixed RPPairing ingress socket itself
    /// is reachable over cellular and record the kernel-selected source/interface.
    func probeCellularRPPairingIngress() -> Result {
        callBridgeWithoutPairing { message, capacity in
            PPProbeCellularRPPairingIngress(message, capacity)
        }
    }

    /// Stage 11.5.4.5: enumerate en0/pdp_ip*/utun* IPv4 addresses, TCP-probe
    /// 49152, then run full RPPairing -> RSD on every accepting candidate.
    /// Returns the first host that completes RSD so the caller can propagate it
    /// through DDI/Runner/XCTest instead of falling back to a different path.
    func probeCellularRPPairingInterfaces() -> (result: Result, selectedHost: String?) {
        let messageCapacity = 8192
        let hostCapacity = 128
        let message = UnsafeMutablePointer<CChar>.allocate(capacity: messageCapacity)
        let hostBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: hostCapacity)
        message.initialize(repeating: 0, count: messageCapacity)
        hostBuffer.initialize(repeating: 0, count: hostCapacity)
        defer {
            message.deallocate()
            hostBuffer.deallocate()
        }

        let code: Int32 = pairingPath.withCString { path in
            PPProbeCellularRPPairingInterfaces(
                path,
                hostBuffer,
                hostCapacity,
                message,
                messageCapacity
            )
        }
        let text = String(cString: message)
        let selected = hostBuffer[0] == 0 ? nil : String(cString: hostBuffer)
        return (
            Result(ok: code == 0, message: text.isEmpty ? "code=\(code)" : text),
            selected
        )
    }

    /// Stage 11.5.4.8: enumerate scoped IPv6 endpoints on cellular/utun/loopback
    /// and run the full RPPairing -> RSD path against any accepting :49152 socket.
    func probeCellularRPPairingIPv6Interfaces() -> (result: Result, selectedHost: String?) {
        let messageCapacity = 16384
        let hostCapacity = 256
        let message = UnsafeMutablePointer<CChar>.allocate(capacity: messageCapacity)
        let hostBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: hostCapacity)
        message.initialize(repeating: 0, count: messageCapacity)
        hostBuffer.initialize(repeating: 0, count: hostCapacity)
        defer {
            message.deallocate()
            hostBuffer.deallocate()
        }

        let code: Int32 = pairingPath.withCString { path in
            PPProbeCellularRPPairingIPv6Interfaces(
                path,
                hostBuffer,
                hostCapacity,
                message,
                messageCapacity
            )
        }
        let text = String(cString: message)
        let selected = hostBuffer[0] == 0 ? nil : String(cString: hostBuffer)
        return (
            Result(ok: code == 0, message: text.isEmpty ? "code=\(code)" : text),
            selected
        )
    }

    func probeRSD() -> Result {
        callBridge { path, message, capacity in
            host.withCString { hostCString in
                PPProbeRSD(path, hostCString, port, message, capacity)
            }
        }
    }

    func prepareXCTestMetadata() -> Result {
        callBridge { path, message, capacity in
            host.withCString { hostCString in
                PPPreparePhoneLocalXCTestMetadata(
                    path,
                    hostCString,
                    port,
                    message,
                    capacity
                )
            }
        }
    }


    // Stage 11.3.2: after reboot, missing developer services are a DDI state
    // problem. START PILOT performs DDI preflight before XCTest; do not spin RSD.
    func runXCTestCenterTap() -> Result {
        callBridge { path, message, capacity in
            host.withCString { hostCString in
                PPRunPhoneLocalXCTestCenterTap(path, hostCString, port, message, capacity)
            }
        }
    }

    func runXCTestActivateOnly() -> Result {
        if persistentSession != 0 {
            return callPersistent { session, message, capacity in
                PPPhoneLocalSessionXCTestActivate(session, message, capacity)
            }
        }
        return callBridge { path, message, capacity in
            host.withCString { hostCString in
                PPRunPhoneLocalXCTestActivate(path, hostCString, port, message, capacity)
            }
        }
    }

    func runXCTestTap(normalizedX: Double, normalizedY: Double) -> Result {
        if persistentSession != 0 {
            return callPersistent { session, message, capacity in
                PPPhoneLocalSessionXCTestTap(session, normalizedX, normalizedY, message, capacity)
            }
        }
        return callBridge { path, message, capacity in
            host.withCString { hostCString in
                PPRunPhoneLocalXCTestTap(
                    path, hostCString, port, normalizedX, normalizedY, message, capacity
                )
            }
        }
    }

    func runXCTestTapBounded(
        normalizedX: Double,
        normalizedY: Double,
        timeoutSeconds: UInt64
    ) -> Result {
        if persistentSession != 0 {
            return callPersistent { session, message, capacity in
                PPPhoneLocalSessionXCTestTapBounded(
                    session,
                    normalizedX,
                    normalizedY,
                    timeoutSeconds,
                    message,
                    capacity
                )
            }
        }
        return callBridge { path, message, capacity in
            host.withCString { hostCString in
                PPRunPhoneLocalXCTestTapBounded(
                    path,
                    hostCString,
                    port,
                    normalizedX,
                    normalizedY,
                    timeoutSeconds,
                    message,
                    capacity
                )
            }
        }
    }

    func runXCTestSwipe(
        fromX: Double,
        fromY: Double,
        toX: Double,
        toY: Double,
        duration: Double
    ) -> Result {
        if persistentSession != 0 {
            return callPersistent { session, message, capacity in
                PPPhoneLocalSessionXCTestSwipe(
                    session, fromX, fromY, toX, toY, duration, message, capacity
                )
            }
        }
        return callBridge { path, message, capacity in
            host.withCString { hostCString in
                PPRunPhoneLocalXCTestSwipe(
                    path, hostCString, port, fromX, fromY, toX, toY, duration,
                    message, capacity
                )
            }
        }
    }

    func runXCTestSelectPink12() -> Result {
        callBridge { path, message, capacity in
            host.withCString { hostCString in
                PPRunPhoneLocalXCTestSelectPink12(path, hostCString, port, message, capacity)
            }
        }
    }

    func runXCTestDispatchTail(
        pikminX: Double,
        pikminY: Double,
        pikminCount: Int,
        fastMode: Bool
    ) -> Result {
        if persistentSession != 0 {
            return callPersistent { session, message, capacity in
                PPPhoneLocalSessionXCTestDispatchTail(
                    session, pikminX, pikminY,
                    Int32(min(12, max(2, pikminCount))),
                    Int32(fastMode ? 1 : 0),
                    message, capacity
                )
            }
        }
        return callBridge { path, message, capacity in
            host.withCString { hostCString in
                PPRunPhoneLocalXCTestDispatchTail(
                    path, hostCString, port, pikminX, pikminY,
                    Int32(min(12, max(2, pikminCount))),
                    Int32(fastMode ? 1 : 0),
                    message, capacity
                )
            }
        }
    }

    func mountPersonalizedDDI(
        imagePath: String,
        buildManifestPath: String,
        trustCachePath: String
    ) -> Result {
        if persistentSession != 0 {
            return callPersistent { session, message, capacity in
                imagePath.withCString { imageCString in
                    buildManifestPath.withCString { manifestCString in
                        trustCachePath.withCString { trustCString in
                            PPPhoneLocalSessionMountPersonalizedDDI(
                                session, imageCString, manifestCString, trustCString, message, capacity
                            )
                        }
                    }
                }
            }
        }
        return callBridge { path, message, capacity in
            host.withCString { hostCString in
                imagePath.withCString { imageCString in
                    buildManifestPath.withCString { manifestCString in
                        trustCachePath.withCString { trustCString in
                            PPMountPhoneLocalPersonalizedDDI(
                                path, hostCString, port, imageCString, manifestCString,
                                trustCString, message, capacity
                            )
                        }
                    }
                }
            }
        }
    }

    func installXCTestRunnerIPA(localPath: String) -> Result {
        if persistentSession != 0 {
            return callPersistent { session, message, capacity in
                localPath.withCString { ipaCString in
                    PPPhoneLocalSessionInstallRunnerIPA(session, ipaCString, message, capacity)
                }
            }
        }
        return callBridge { path, message, capacity in
            host.withCString { hostCString in
                localPath.withCString { ipaCString in
                    PPInstallPhoneLocalXCTestRunnerIPA(
                        path,
                        hostCString,
                        port,
                        ipaCString,
                        message,
                        capacity
                    )
                }
            }
        }
    }

    func discoverXCTestRunner() -> Result {
        if persistentSession != 0 {
            return callPersistent { session, message, capacity in
                PPPhoneLocalSessionDiscoverRunner(session, message, capacity)
            }
        }
        return callBridge { path, message, capacity in
            host.withCString { hostCString in
                PPDiscoverPhoneLocalXCTestRunner(
                    path,
                    hostCString,
                    port,
                    message,
                    capacity
                )
            }
        }
    }

    func bootstrapXCTestDTX() -> Result {
        callBridge { path, message, capacity in
            host.withCString { hostCString in
                PPBootstrapPhoneLocalXCTestDTX(
                    path,
                    hostCString,
                    port,
                    message,
                    capacity
                )
            }
        }
    }

    func probeXCTestServices() -> Result {
        if persistentSession != 0 {
            return callPersistent { session, message, capacity in
                PPPhoneLocalSessionProbeXCTestServices(session, message, capacity)
            }
        }
        return callBridge { path, message, capacity in
            host.withCString { hostCString in
                PPProbePhoneLocalXCTestServices(
                    path,
                    hostCString,
                    port,
                    message,
                    capacity
                )
            }
        }
    }

    func launchBundleID(_ bundleID: String) -> Result {
        if persistentSession != 0 {
            return callPersistent { session, message, capacity in
                bundleID.withCString { bundleCString in
                    PPPhoneLocalSessionLaunchBundleID(session, bundleCString, message, capacity)
                }
            }
        }
        return callBridge { path, message, capacity in
            host.withCString { hostCString in
                bundleID.withCString { bundleCString in
                    PPLaunchBundleID(
                        path,
                        hostCString,
                        port,
                        bundleCString,
                        message,
                        capacity
                    )
                }
            }
        }
    }

    func launchPikmin() -> Result {
        callBridge { path, message, capacity in
            host.withCString { hostCString in
                PPLaunchPikmin(path, hostCString, port, message, capacity)
            }
        }
    }

    /// CoreDevice Screen Capture through a live phone-local RSD session.
    /// Stage 11.5.4.27 guarantees that normal iPhone/iPad post-tail paths open
    /// a dedicated session before calling this; cellular escape reuses its pin.
    func takeCoreDeviceScreenshotBounded(
        outputPath: String,
        timeoutMilliseconds: UInt64
    ) -> Result {
        guard persistentSession != 0 else {
            return Result(ok: false, message: "PERSISTENT RSD SESSION MISSING")
        }
        return callPersistent { session, message, capacity in
            outputPath.withCString { outputCString in
                PPPhoneLocalSessionTakeCoreDeviceScreenshotBounded(
                    session,
                    outputCString,
                    timeoutMilliseconds,
                    message,
                    capacity
                )
            }
        }
    }

    func takeScreenshot(outputPath: String) -> Result {
        if persistentSession != 0 {
            return callPersistent { session, message, capacity in
                outputPath.withCString { outputCString in
                    PPPhoneLocalSessionTakeScreenshot(session, outputCString, message, capacity)
                }
            }
        }
        return callBridge { path, message, capacity in
            host.withCString { hostCString in
                outputPath.withCString { outputCString in
                    PPTakePhoneScreenshot(
                        path,
                        hostCString,
                        port,
                        outputCString,
                        message,
                        capacity
                    )
                }
            }
        }
    }

    func takeScreenshotBounded(
        outputPath: String,
        timeoutMilliseconds: UInt64
    ) -> Result {
        if persistentSession != 0 {
            return callPersistent { session, message, capacity in
                outputPath.withCString { outputCString in
                    PPPhoneLocalSessionTakeScreenshotBounded(
                        session,
                        outputCString,
                        timeoutMilliseconds,
                        message,
                        capacity
                    )
                }
            }
        }
        return callBridge { path, message, capacity in
            host.withCString { hostCString in
                outputPath.withCString { outputCString in
                    PPTakePhoneScreenshotBounded(
                        path,
                        hostCString,
                        port,
                        outputCString,
                        timeoutMilliseconds,
                        message,
                        capacity
                    )
                }
            }
        }
    }

    private func callPersistent(
        _ body: (UInt, UnsafeMutablePointer<CChar>, Int) -> Int32
    ) -> Result {
        guard persistentSession != 0 else {
            return Result(ok: false, message: "PERSISTENT RSD SESSION MISSING")
        }
        let capacity = 8192
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: capacity)
        buffer.initialize(repeating: 0, count: capacity)
        defer { buffer.deallocate() }
        let code = body(persistentSession, buffer, capacity)
        let text = String(cString: buffer)
        return Result(ok: code == 0, message: text.isEmpty ? "persistent idevice result code \(code)" : text)
    }

    private func callBridgeWithoutPairing(
        _ body: (_ message: UnsafeMutablePointer<CChar>, _ capacity: Int) -> Int32
    ) -> Result {
        var message = [CChar](repeating: 0, count: 4096)
        let code = message.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress!, buffer.count)
        }
        let text = String(cString: message)
        return Result(ok: code == 0, message: text.isEmpty ? "code=\(code)" : text)
    }

    private func callBridge(
        _ body: (
            UnsafePointer<CChar>,
            UnsafeMutablePointer<CChar>,
            Int
        ) -> Int32
    ) -> Result {
        let capacity = 8192
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: capacity)
        buffer.initialize(repeating: 0, count: capacity)
        defer { buffer.deallocate() }

        let code: Int32 = pairingPath.withCString { path in
            body(path, buffer, capacity)
        }

        let text = String(cString: buffer)
        return Result(
            ok: code == 0,
            message: text.isEmpty ? "idevice result code \(code)" : text
        )
    }
}
