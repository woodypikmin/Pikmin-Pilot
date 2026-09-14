import Foundation

actor IDeviceEngine {
    struct Result: Sendable {
        let ok: Bool
        let message: String
    }

    private let pairingPath: String
    private let host: String
    private let port: UInt16

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

    /// Stage 11.5.4.2: fixed-port transport discriminator for cellular-only.
    /// It intentionally bypasses RPPairing createListener and asks lockdownd
    /// QueryType through the integrated reflector at 10.7.0.1:62078.
    func probeCellularLockdownRoute() -> Result {
        callBridgeWithoutPairing { message, capacity in
            PPProbeCellularLockdownRoute(message, capacity)
        }
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
        callBridge { path, message, capacity in
            host.withCString { hostCString in
                PPRunPhoneLocalXCTestActivate(path, hostCString, port, message, capacity)
            }
        }
    }

    func runXCTestTap(normalizedX: Double, normalizedY: Double) -> Result {
        callBridge { path, message, capacity in
            host.withCString { hostCString in
                PPRunPhoneLocalXCTestTap(
                    path, hostCString, port, normalizedX, normalizedY, message, capacity
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
        callBridge { path, message, capacity in
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
        callBridge { path, message, capacity in
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
        callBridge { path, message, capacity in
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
        callBridge { path, message, capacity in
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
        callBridge { path, message, capacity in
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
        callBridge { path, message, capacity in
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
        callBridge { path, message, capacity in
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

    func takeScreenshot(outputPath: String) -> Result {
        callBridge { path, message, capacity in
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
