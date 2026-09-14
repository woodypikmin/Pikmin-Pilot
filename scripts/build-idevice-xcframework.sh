#!/bin/bash
set -euxo pipefail

# Stage 7.8.5: keep the proven 7.8.3 driver-ready runtime path; Runner signing is fixed at install time.
PIN="${IDEVICE_PIN:-7a1cca3}"
ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
CACHE="$ROOT/.build/idevice"
OUT="$ROOT/Vendor/IDevice/IDevice.xcframework"
HEADERS="$ROOT/Vendor/IDevice/include"

rm -rf "$CACHE" "$OUT" "$HEADERS"
mkdir -p "$ROOT/.build" "$HEADERS"

git clone https://github.com/jkcoxson/idevice.git "$CACHE"
cd "$CACHE"
git checkout "$PIN"

# Stage 11.3.2: add a diagnostic Personalized-DDI helper as a new impl block.
# Do not rewrite/replace upstream function bodies: Stage 11.3.0 used an exact
# multiline text replacement here, which was unnecessarily brittle in CI.
cat >> idevice/src/services/mobile_image_mounter.rs <<'RUST_DDI_DIAG'

// Pikmin Pilot Stage 11.3.2 diagnostic Personalized-DDI mount helper.
// This intentionally lives in the same module as ImageMounter so it can
// reconnect the private `idevice` field after QueryPersonalizationManifest
// closes the socket, while preserving precise failure-stage labels.
#[cfg(all(feature = "tss", feature = "rsd"))]
impl ImageMounter {
    #[allow(clippy::too_many_arguments)]
    pub async fn pilot_mount_personalized_diagnostic_rsd(
        &mut self,
        provider: &mut impl crate::provider::RsdProvider,
        handshake: &mut crate::rsd::RsdHandshake,
        image: Vec<u8>,
        trust_cache: Vec<u8>,
        build_manifest: &[u8],
        info_plist: Option<plist::Value>,
        unique_chip_id: u64,
    ) -> Result<(), IdeviceError> {
        let mut hasher = Sha384::new();
        hasher.update(&image);
        let image_hash = hasher.finalize();

        let manifest = match self
            .query_personalization_manifest("DeveloperDiskImage", image_hash.to_vec())
            .await
        {
            Ok(manifest) => manifest,
            Err(e) => {
                debug!("Device didn't contain a manifest: {e:?}, fetching from TSS");

                // QueryPersonalizationManifest failure closes this socket.
                self.idevice = Self::connect_rsd(provider, handshake)
                    .await
                    .map_err(|e| {
                        IdeviceError::UnexpectedResponse(format!(
                            "step=ddi-rsd-reconnect • {e:?}"
                        ))
                    })?
                    .idevice;

                let manifest_dict: plist::Dictionary = plist::from_bytes(build_manifest)
                    .map_err(|e| {
                        IdeviceError::UnexpectedResponse(format!(
                            "step=ddi-build-manifest-parse • {e:?}"
                        ))
                    })?;

                self.get_manifest_from_tss(&manifest_dict, unique_chip_id)
                    .await
                    .map_err(|e| {
                        IdeviceError::UnexpectedResponse(format!(
                            "step=ddi-tss-personalization • {e:?}"
                        ))
                    })?
            }
        };

        self.upload_image("Personalized", &image, manifest.clone())
            .await
            .map_err(|e| {
                IdeviceError::UnexpectedResponse(format!("step=ddi-upload • {e:?}"))
            })?;

        self.mount_image("Personalized", manifest, Some(trust_cache), info_plist)
            .await
            .map_err(|e| {
                IdeviceError::UnexpectedResponse(format!("step=ddi-mount-image • {e:?}"))
            })?;

        Ok(())
    }
}
RUST_DDI_DIAG

# Stage 7.8.5: upstream idevice guesses that every XCTest bootstrap NSError
# with numeric code 103 means an untrusted developer certificate. That guess
# is not safe without the NSError domain. Replace it with raw archive string
# extraction so the phone can display Apple's actual domain/description text.
python3 - <<'PY_BOOTERR'
from pathlib import Path
p = Path("idevice/src/services/dvt/xctest/mod.rs")
s = p.read_text()
old = """                        // Fall back to the numeric code with a hint for
                        // the most common values seen from testmanagerd
                        if let Some(code) = d.get("NSCode").and_then(|v| v.as_signed_integer()) {
                            let hint = match code {
                                103 => " (untrusted developer certificate — go to Settings → General → VPN & Device Management and trust your developer app)",
                                _ => "",
                            };
                            return Some(format!("NSError code {code}{hint}"));
                        }
"""
new = """                        // Preserve the numeric code but do not guess its meaning
                        // without the NSError domain. The raw NSKeyedArchive still
                        // contains the useful domain/description/underlying-error strings.
                        if let Some(code) = d.get("NSCode").and_then(|v| v.as_signed_integer()) {
                            let archive = pilot_bootstrap_archive_strings(v);
                            if archive.is_empty() {
                                return Some(format!("NSError code {code}"));
                            }
                            return Some(format!("NSError code {code} • archiveStrings={archive}"));
                        }
"""
if old not in s:
    raise SystemExit("Stage 7.8.5 bootstrap NSError patch target not found")
s = s.replace(old, new, 1)
p.write_text(s)
PY_BOOTERR

# The public idevice xctest orchestrator internally already contains the correct
# iOS 17+ RSD DTX handshake logic, but its low-level rsd_connect helper is private.
# Expose one tiny diagnostic helper *inside the idevice crate* so it can reuse
# those exact private primitives against Pikmin Pilot's existing Adapter/RSD handles.
cat >> idevice/src/services/dvt/xctest/mod.rs <<'RUST'

// Pikmin Pilot Stage 7.6 diagnostic hook.
// Uses the same private rsd_connect() implementation as the upstream XCTest
// orchestrator, but reuses an RSD adapter/handshake supplied by the embedding app.
pub async fn pilot_probe_existing_rsd_dtx(
    handle: &mut crate::tcp::handle::AdapterHandle,
    handshake: &crate::services::rsd::RsdHandshake,
) -> Result<String, crate::IdeviceError> {
    let dvt_port = handshake
        .services
        .get("com.apple.instruments.dtservicehub")
        .map(|service| service.port)
        .ok_or(crate::IdeviceError::ServiceNotFound)?;

    let tm_port = handshake
        .services
        .get(TESTMANAGERD_RSD_SERVICE)
        .map(|service| service.port)
        .ok_or(crate::IdeviceError::ServiceNotFound)?;

    // DVT includes the process-control termination callback capability exactly
    // like connect_rsd_stack_once() in upstream XCTest.
    let dvt = rsd_connect(
        handle,
        handshake,
        "com.apple.instruments.dtservicehub",
        "pikmin-pilot-dtservicehub",
        true,
    )
    .await?;

    // XCTest needs two independent testmanagerd DTX connections.
    let ctrl = rsd_connect(
        handle,
        handshake,
        TESTMANAGERD_RSD_SERVICE,
        "pikmin-pilot-testmanagerd-ctrl",
        false,
    )
    .await?;

    let main = rsd_connect(
        handle,
        handshake,
        TESTMANAGERD_RSD_SERVICE,
        "pikmin-pilot-testmanagerd-main",
        false,
    )
    .await?;

    // Keep all three clients alive until every handshake has completed.
    let _keep_alive = (dvt, ctrl, main);

    Ok(format!(
        "PHONE-LOCAL XCTEST DTX READY • dtservicehub={} • testmanagerd.ctrl={} • testmanagerd.main={} • {} RSD services",
        dvt_port,
        tm_port,
        tm_port,
        handshake.services.len()
    ))
}
RUST

# Stage 7.8 execution hook. This deliberately lives inside the upstream xctest
# module so it can reuse the exact private orchestration primitives while using
# Pikmin Pilot's already-established phone-local Adapter/RSD handles.
cat >> idevice/src/services/dvt/xctest/mod.rs <<'RUST'

// Stage 7.8.4 bootstrap diagnostics. The decoded NSError sometimes exposes
// only NSCode; its raw NSKeyedArchive still carries human-readable strings.
fn pilot_collect_plist_strings(value: &Value, out: &mut Vec<String>) {
    match value {
        Value::String(text) => {
            let text = text.trim();
            if !text.is_empty() && text != "$null" && text.len() <= 512 {
                out.push(text.to_owned());
            }
        }
        Value::Array(values) => {
            for value in values {
                pilot_collect_plist_strings(value, out);
            }
        }
        Value::Dictionary(dict) => {
            for value in dict.values() {
                pilot_collect_plist_strings(value, out);
            }
        }
        _ => {}
    }
}

fn pilot_bootstrap_archive_strings(aux: &AuxValue) -> String {
    let AuxValue::Array(bytes) = aux else {
        return String::new();
    };
    let Ok(raw) = Value::from_reader(std::io::Cursor::new(bytes.as_slice())) else {
        return String::new();
    };

    let mut values = Vec::new();
    pilot_collect_plist_strings(&raw, &mut values);

    let mut unique: Vec<String> = Vec::new();
    for value in values {
        if matches!(
            value.as_str(),
            "$archiver" | "$version" | "$objects" | "$top" | "$class" | "$classes" | "$classname"
        ) {
            continue;
        }
        if value.starts_with("NSKeyedArchiver") || value == "NSError" || value == "NSObject" {
            continue;
        }
        if !unique.iter().any(|existing| existing == &value) {
            unique.push(value);
        }
        if unique.len() >= 24 {
            break;
        }
    }
    unique.join(" | ")
}

struct PilotNoopXCTestListener;
impl XCUITestListener for PilotNoopXCTestListener {}

/// Runs a normal XCTest plan using an existing phone-local RSD tunnel.
/// This is the same lifecycle as XCUITestService::run(), except transport setup
/// is not recreated through an IdeviceProvider/CoreDeviceProxy. No WDA fallback.
pub async fn pilot_run_existing_rsd_xctest(
    handle: &mut crate::tcp::handle::AdapterHandle,
    handshake: &crate::services::rsd::RsdHandshake,
    cfg: TestConfig,
    ios_major_version: u8,
    timeout: Option<std::time::Duration>,
) -> Result<u64, String> {
    let session_id = uuid::Uuid::new_v4();
    let xctest_path = format!(
        "/tmp/{}.xctestconfiguration",
        session_id.to_string().to_uppercase()
    );

    let xctest_config = cfg
        .build_xctest_configuration(session_id, ios_major_version)
        .map_err(|e| format!("step=xctest-configuration • {e:?}"))?;

    // Exactly three DTX connections, all through the existing RSD adapter.
    let dvt = rsd_connect(
        handle,
        handshake,
        "com.apple.instruments.dtservicehub",
        "pikmin-pilot-exec-dtservicehub",
        true,
    )
    .await
    .map_err(|e| format!("step=dtx-dtservicehub • {e:?}"))?;

    let ctrl = rsd_connect(
        handle,
        handshake,
        TESTMANAGERD_RSD_SERVICE,
        "pikmin-pilot-exec-testmanagerd-ctrl",
        false,
    )
    .await
    .map_err(|e| format!("step=dtx-testmanagerd-ctrl • {e:?}"))?;

    let main = rsd_connect(
        handle,
        handshake,
        TESTMANAGERD_RSD_SERVICE,
        "pikmin-pilot-exec-testmanagerd-main",
        false,
    )
    .await
    .map_err(|e| format!("step=dtx-testmanagerd-main • {e:?}"))?;

    let mut conns = TestManagerConnections {
        ctrl,
        main,
        dvt,
        rsd_handles: Vec::new(),
    };

    let mut ctrl_proxy = TestManagerProxy::open(&mut conns.ctrl, ios_major_version)
        .await
        .map_err(|e| format!("step=open-testmanager-ctrl • {e:?}"))?;
    let mut main_proxy = TestManagerProxy::open(&mut conns.main, ios_major_version)
        .await
        .map_err(|e| format!("step=open-testmanager-main • {e:?}"))?;
    let mut process_control = XCTestProcessControlChannel::open(&mut conns.dvt)
        .await
        .map_err(|e| format!("step=open-process-control • {e:?}"))?;

    initialize_testmanager_sessions(&mut ctrl_proxy, &mut main_proxy, &xctest_config)
        .await
        .map_err(|e| format!("step=install-bootstrap-handlers • {e:?}"))?;

    register_early_driver_channel_handler(&mut conns.main, &xctest_config).await;

    initialize_testmanager_daemon_sessions(
        &mut ctrl_proxy,
        &mut main_proxy,
        ios_major_version,
        &session_id,
        &xctest_config,
    )
    .await
    .map_err(|e| format!("step=initialize-xctest-session • {e:?}"))?;

    let config_name = cfg.config_name().to_owned();
    let (launch_args, mut launch_env, launch_options) = build_launch_env(
        ios_major_version,
        &session_id,
        &cfg.runner_app_path,
        &cfg.runner_app_container,
        &config_name,
        &xctest_path,
        cfg.runner_env.as_ref(),
        cfg.runner_args.as_deref(),
    );

    // Stage 7.8.5: intentionally keep upstream build_launch_env byte-for-byte.
    // Stage 7.8.2 overrode DYLD_* after build_launch_env; on this iOS 26.6.1
    // device that changed the failure from a late bootstrap NSError to an
    // earlier BrokenPipe while waiting for XCTestDriverInterface.  Reverting
    // that override restores the already-observed driver-ready path so the
    // raw bootstrap NSError diagnostic below can expose the real failure.

    let pid = launch_and_authorize_test_runner(
        &mut ctrl_proxy,
        &mut process_control,
        ios_major_version,
        &cfg.runner_bundle_id,
        launch_args,
        launch_env,
        launch_options,
    )
    .await
    .map_err(|e| format!("step=launch-authorize-runner • {e:?}"))?;

    let driver_channel = start_test_plan_session(&mut conns.main, &mut main_proxy)
        .await
        .map_err(|e| format!("step=wait-driver-start-plan • {e:?}"))?;

    let mut listener = PilotNoopXCTestListener;
    run_dispatch_loop_until_done_or_disconnect(
        &mut conns.main,
        driver_channel,
        &xctest_config,
        &mut listener,
        timeout,
    )
    .await
    .map_err(|e| format!("step=execute-test-plan • runner-pid={pid} • driver=ready • {e:?}"))?;

    Ok(pid)
}
RUST

cp "$ROOT/RustPatch/pilot_xctest_probe.rs" ffi/src/pilot_xctest_probe.rs
cp "$ROOT/RustPatch/pilot_xctest_dtx.rs" ffi/src/pilot_xctest_dtx.rs
cp "$ROOT/RustPatch/pilot_xctest_runner.rs" ffi/src/pilot_xctest_runner.rs
cp "$ROOT/RustPatch/pilot_xctest_metadata.rs" ffi/src/pilot_xctest_metadata.rs
cp "$ROOT/RustPatch/pilot_xctest_execute.rs" ffi/src/pilot_xctest_execute.rs
cp "$ROOT/RustPatch/pilot_runner_install.rs" ffi/src/pilot_runner_install.rs
cp "$ROOT/RustPatch/pilot_ddi_mount.rs" ffi/src/pilot_ddi_mount.rs
cp "$ROOT/RustPatch/pilot_pairing_host.rs" ffi/src/pilot_pairing_host.rs

# Add a focused FFI-only feature under the existing [features] table.
python3 - <<'PY'
from pathlib import Path
p = Path("ffi/Cargo.toml")
s = p.read_text()
needle = "[features]\n"
if needle not in s:
    raise SystemExit("ffi/Cargo.toml has no [features] table")
s = s.replace(
    needle,
    needle + 'pilot_xctest = ["idevice/xctest", "idevice/afc", "idevice/mobile_image_mounter", "idevice/tss"]\n',
    1,
)
p.write_text(s)
PY

cat >> ffi/src/lib.rs <<'RUST'

// Pikmin Pilot Stage 7.8 retained probes + real XCTest execution.
mod pilot_xctest_probe;
mod pilot_xctest_dtx;
mod pilot_xctest_runner;
mod pilot_xctest_metadata;
mod pilot_xctest_execute;
mod pilot_runner_install;
mod pilot_ddi_mount;
mod pilot_pairing_host;

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pilot_ddi_mount_personalized(
    adapter: *mut core_device_proxy::AdapterHandle,
    handshake: *mut rsd::RsdHandshakeHandle,
    image_path: *const std::ffi::c_char,
    build_manifest_path: *const std::ffi::c_char,
    trustcache_path: *const std::ffi::c_char,
    message: *mut std::ffi::c_char,
    message_capacity: usize,
) -> i32 {
    unsafe {
        pilot_ddi_mount::pilot_ddi_mount_personalized_impl(
            adapter, handshake, image_path, build_manifest_path, trustcache_path,
            message, message_capacity,
        )
    }
}


#[unsafe(no_mangle)]
pub unsafe extern "C" fn pilot_runner_install_ipa(
    adapter: *mut core_device_proxy::AdapterHandle,
    handshake: *mut rsd::RsdHandshakeHandle,
    local_ipa_path: *const std::ffi::c_char,
    message: *mut std::ffi::c_char,
    message_capacity: usize,
) -> i32 {
    unsafe {
        pilot_runner_install::pilot_runner_install_ipa_impl(
            adapter, handshake, local_ipa_path, message, message_capacity,
        )
    }
}


#[unsafe(no_mangle)]
pub unsafe extern "C" fn pilot_xctest_service_probe(
    handshake: *mut rsd::RsdHandshakeHandle,
    message: *mut std::ffi::c_char,
    message_capacity: usize,
) -> i32 {
    unsafe {
        pilot_xctest_probe::pilot_xctest_service_probe_impl(
            handshake,
            message,
            message_capacity,
        )
    }
}


#[unsafe(no_mangle)]
pub unsafe extern "C" fn pilot_xctest_runner_discovery(
    adapter: *mut core_device_proxy::AdapterHandle,
    handshake: *mut rsd::RsdHandshakeHandle,
    message: *mut std::ffi::c_char,
    message_capacity: usize,
) -> i32 {
    unsafe {
        pilot_xctest_runner::pilot_xctest_runner_discovery_impl(
            adapter,
            handshake,
            message,
            message_capacity,
        )
    }
}


#[unsafe(no_mangle)]
pub unsafe extern "C" fn pilot_xctest_metadata(
    adapter: *mut core_device_proxy::AdapterHandle,
    handshake: *mut rsd::RsdHandshakeHandle,
    message: *mut std::ffi::c_char,
    message_capacity: usize,
) -> i32 {
    unsafe {
        pilot_xctest_metadata::pilot_xctest_metadata_impl(
            adapter,
            handshake,
            message,
            message_capacity,
        )
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pilot_xctest_execute_center_tap(
    adapter: *mut core_device_proxy::AdapterHandle,
    handshake: *mut rsd::RsdHandshakeHandle,
    message: *mut std::ffi::c_char,
    message_capacity: usize,
) -> i32 {
    unsafe {
        pilot_xctest_execute::pilot_xctest_execute_center_tap_impl(
            adapter,
            handshake,
            message,
            message_capacity,
        )
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pilot_xctest_execute_activate(
    adapter: *mut core_device_proxy::AdapterHandle,
    handshake: *mut rsd::RsdHandshakeHandle,
    message: *mut std::ffi::c_char,
    message_capacity: usize,
) -> i32 {
    unsafe {
        pilot_xctest_execute::pilot_xctest_execute_activate_impl(
            adapter,
            handshake,
            message,
            message_capacity,
        )
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pilot_xctest_execute_tap(
    adapter: *mut core_device_proxy::AdapterHandle,
    handshake: *mut rsd::RsdHandshakeHandle,
    normalized_x: f64,
    normalized_y: f64,
    message: *mut std::ffi::c_char,
    message_capacity: usize,
) -> i32 {
    unsafe {
        pilot_xctest_execute::pilot_xctest_execute_tap_impl(
            adapter,
            handshake,
            normalized_x,
            normalized_y,
            message,
            message_capacity,
        )
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pilot_xctest_execute_swipe(
    adapter: *mut core_device_proxy::AdapterHandle,
    handshake: *mut rsd::RsdHandshakeHandle,
    from_x: f64,
    from_y: f64,
    to_x: f64,
    to_y: f64,
    duration: f64,
    message: *mut std::ffi::c_char,
    message_capacity: usize,
) -> i32 {
    unsafe {
        pilot_xctest_execute::pilot_xctest_execute_swipe_impl(
            adapter, handshake, from_x, from_y, to_x, to_y, duration,
            message, message_capacity,
        )
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pilot_xctest_execute_select12(
    adapter: *mut core_device_proxy::AdapterHandle,
    handshake: *mut rsd::RsdHandshakeHandle,
    message: *mut std::ffi::c_char,
    message_capacity: usize,
) -> i32 {
    unsafe {
        pilot_xctest_execute::pilot_xctest_execute_select12_impl(
            adapter, handshake, message, message_capacity,
        )
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pilot_xctest_execute_dispatch_tail(
    adapter: *mut core_device_proxy::AdapterHandle,
    handshake: *mut rsd::RsdHandshakeHandle,
    pink_x: f64,
    pink_y: f64,
    pink_count: i32,
    fast_mode: i32,
    message: *mut std::ffi::c_char,
    message_capacity: usize,
) -> i32 {
    unsafe {
        pilot_xctest_execute::pilot_xctest_execute_dispatch_tail_impl(
            adapter, handshake, pink_x, pink_y, pink_count, fast_mode, message, message_capacity,
        )
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pilot_xctest_dtx_bootstrap(
    adapter: *mut core_device_proxy::AdapterHandle,
    handshake: *mut rsd::RsdHandshakeHandle,
    message: *mut std::ffi::c_char,
    message_capacity: usize,
) -> i32 {
    unsafe {
        pilot_xctest_dtx::pilot_xctest_dtx_bootstrap_impl(
            adapter,
            handshake,
            message,
            message_capacity,
        )
    }
}
RUST

rustup target add aarch64-apple-ios

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
BINDGEN_EXTRA_CLANG_ARGS="--sysroot=$SDK" \
IPHONEOS_DEPLOYMENT_TARGET=17.4 \
cargo build \
  -p idevice-ffi \
  --release \
  --locked \
  --target aarch64-apple-ios \
  --no-default-features \
  --features "obfuscate,ring,core_device,tunnel_tcp_stack,dvt,pilot_xctest"

LIB="target/aarch64-apple-ios/release/libidevice_ffi.a"
test -f "$LIB"
ls -lh "$LIB"

# Apple nm may not understand every LLVM object emitted by current Rust;
# use a format-agnostic archive string check instead.
python3 - "$LIB" <<'PY'
from pathlib import Path
import sys
data = Path(sys.argv[1]).read_bytes()
required = [
    b"pilot_pairing_host_accept",
    b"pilot_xctest_service_probe",
    b"pilot_ddi_mount_personalized",
    b"pilot_xctest_dtx_bootstrap",
    b"pilot_xctest_runner_discovery",
    b"pilot_xctest_metadata",
    b"pilot_xctest_execute_center_tap",
    b"pilot_xctest_execute_activate",
    b"pilot_xctest_execute_tap",
    b"pilot_xctest_execute_swipe",
    b"pilot_xctest_execute_select12",
    b"pilot_xctest_execute_dispatch_tail",
]
missing = [name.decode() for name in required if name not in data]
if missing:
    raise SystemExit("Missing Stage 7.8 export(s): " + ", ".join(missing))
print("Stage 11.6.1 pairing-host + XCTest/DDI export set present.")
PY

cp ffi/idevice.h "$HEADERS/idevice.h"

xcodebuild -create-xcframework \
  -library "$LIB" \
  -headers "$HEADERS" \
  -output "$OUT"

test -f "$OUT/Info.plist"
test -f "$OUT/ios-arm64/libidevice_ffi.a"
test -f "$OUT/ios-arm64/Headers/idevice.h"
ls -lh "$OUT/ios-arm64/libidevice_ffi.a"
echo "Built Stage 11.6.1 RPPairing + DDI + XCTest runtime $OUT"
