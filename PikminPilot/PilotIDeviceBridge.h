#pragma once

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Stage 11.6.1: starts an iOS 27+ device-initiated RPPairing host entirely
/// inside Pikmin Pilot. The Rust responder owns TCP + RPPairing; Foundation
/// NetService publishes the Bonjour record to avoid raw multicast sockets.
/// This call blocks until pairing succeeds, fails, or timeoutSeconds elapses,
/// so Swift must call it off the main thread. On success outputPath contains
/// rp_pairing_file.plist.
int32_t PPStartPhoneLocalPairingHost(
    const char *outputPath,
    uint64_t timeoutSeconds,
    char *message,
    size_t messageCapacity
);

/// Returns the latest asynchronous pairing-host status (Bonjour ready / PIN /
/// completion) for display while PPStartPhoneLocalPairingHost is blocking.
int32_t PPGetPhoneLocalPairingHostStatus(
    char *message,
    size_t messageCapacity
);

/// Returns 0 on success. Writes a human-readable result into message.
int32_t PPValidateRPPairingFile(
    const char *path,
    char *message,
    size_t messageCapacity
);

/// Performs a VPN-free self-transport diagnostic against 127.0.0.1:62078
/// and the device's own non-loopback IPv4 addresses. This function never
/// starts NetworkExtension and never uses the 10.7.0.1 reflector.
/// Returns 0 when a lockdownd QueryType reply is confirmed on any address.
int32_t PPNoVPNSelfTransportProbe(
    char *message,
    size_t messageCapacity
);

/// Creates an on-device RPPairing tunnel to host:port and performs an RSD
/// handshake. Returns 0 on success.
int32_t PPProbeRSD(
    const char *pairingPath,
    const char *host,
    uint16_t port,
    char *message,
    size_t messageCapacity
);

/// Mounts the iOS 17+ Personalized Developer Disk Image through
/// com.apple.mobile.mobile_image_mounter.shim.remote over the same phone-local
/// RSD transport. Payloads are cached in the app sandbox.
int32_t PPMountPhoneLocalPersonalizedDDI(
    const char *pairingPath,
    const char *host,
    uint16_t port,
    const char *imagePath,
    const char *buildManifestPath,
    const char *trustCachePath,
    char *message,
    size_t messageCapacity
);

/// Creates the same phone-local tunnel and uses CoreDevice AppService to
/// launch Pikmin Bloom. Returns 0 on success.
int32_t PPLaunchPikmin(
    const char *pairingPath,
    const char *host,
    uint16_t port,
    char *message,
    size_t messageCapacity
);

/// Creates the phone-local tunnel, connects DVT RemoteServer over RSD, captures
/// one screenshot, and writes it to outputPath. Returns 0 on success.
int32_t PPTakePhoneScreenshot(
    const char *pairingPath,
    const char *host,
    uint16_t port,
    const char *outputPath,
    char *message,
    size_t messageCapacity
);


/// Creates the phone-local RSD tunnel and checks whether the modern
/// testmanagerd + DVT services required for iOS 17+ XCTest are advertised.
int32_t PPProbePhoneLocalXCTestServices(
    const char *pairingPath,
    const char *host,
    uint16_t port,
    char *message,
    size_t messageCapacity
);


/// Opens dtservicehub + two testmanagerd.remote DTX sessions using the
/// existing phone-local RSD tunnel and performs their capability handshakes.
int32_t PPBootstrapPhoneLocalXCTestDTX(
    const char *pairingPath,
    const char *host,
    uint16_t port,
    char *message,
    size_t messageCapacity
);


/// Uploads an already-signed Runner IPA through AFC/PublicStaging and asks
/// InstallationProxy to install/update it over the same phone-local RSD tunnel.
/// This is the bootstrap path toward a one-user-facing-install package.
int32_t PPInstallPhoneLocalXCTestRunnerIPA(
    const char *pairingPath,
    const char *host,
    uint16_t port,
    const char *localIPAPath,
    char *message,
    size_t messageCapacity
);


/// Uses InstallationProxy over the existing phone-local RSD tunnel to locate
/// the signed Pikmin Pilot XCUITest Runner installed on the iPhone.
int32_t PPDiscoverPhoneLocalXCTestRunner(
    const char *pairingPath,
    const char *host,
    uint16_t port,
    char *message,
    size_t messageCapacity
);


/// Launches any installed bundle ID using CoreDevice AppService over the
/// phone-local RSD tunnel. Stage 7.7 uses this for the discovered .xctrunner.
int32_t PPLaunchBundleID(
    const char *pairingPath,
    const char *host,
    uint16_t port,
    const char *bundleID,
    char *message,
    size_t messageCapacity
);


/// Reads the real installed Runner + Pikmin metadata needed to build
/// XCTestConfiguration over the phone-local RSD tunnel.
int32_t PPPreparePhoneLocalXCTestMetadata(
    const char *pairingPath,
    const char *host,
    uint16_t port,
    char *message,
    size_t messageCapacity
);

/// Executes the installed XCUITest runner over the existing phone-local RSD
/// transport. The runner contains testTapPikminCenter(). No WDA HTTP transport.
int32_t PPRunPhoneLocalXCTestCenterTap(
    const char *pairingPath,
    const char *host,
    uint16_t port,
    char *message,
    size_t messageCapacity
);

/// Activates an already-running Pikmin Bloom via the signed XCUITest Runner.
int32_t PPRunPhoneLocalXCTestActivate(
    const char *pairingPath,
    const char *host,
    uint16_t port,
    char *message,
    size_t messageCapacity
);

/// Dispatches one normalized coordinate tap through XCUITest without WDA.
int32_t PPRunPhoneLocalXCTestTap(
    const char *pairingPath,
    const char *host,
    uint16_t port,
    double normalizedX,
    double normalizedY,
    char *message,
    size_t messageCapacity
);

/// Dispatches one normalized swipe through XCUITest without WDA.
int32_t PPRunPhoneLocalXCTestSwipe(
    const char *pairingPath,
    const char *host,
    uint16_t port,
    double fromX,
    double fromY,
    double toX,
    double toY,
    double duration,
    char *message,
    size_t messageCapacity
);

/// Selects the fixed Stage 5 set of 12 pink Pikmin in one XCTest session.
int32_t PPRunPhoneLocalXCTestSelectPink12(
    const char *pairingPath,
    const char *host,
    uint16_t port,
    char *message,
    size_t messageCapacity
);

/// Executes the time-critical tail in one XCTest session:
/// tap selected color filter -> select configurable 2...12 -> detect/tap GO -> detect/tap green X.
int32_t PPRunPhoneLocalXCTestDispatchTail(
    const char *pairingPath,
    const char *host,
    uint16_t port,
    double pikminFilterX,
    double pikminFilterY,
    int32_t pikminCount,
    int32_t fastMode,
    char *message,
    size_t messageCapacity
);

#ifdef __cplusplus
}
#endif
