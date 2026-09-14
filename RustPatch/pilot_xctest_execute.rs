// Pikmin Pilot Stage 8.2.2
// Command-driven XCTest execution over the existing phone-local RSD transport.
// No WDA HTTP transport. Commands are passed to the signed XCTest Runner via
// runner launch environment, allowing DVT screenshot decisions to dispatch
// taps, swipes, and the configurable 2...12 selected-Pikmin batch.

use std::ffi::c_char;
use std::ptr;
use std::time::Duration;

use crate::core_device_proxy::AdapterHandle;
use crate::rsd::RsdHandshakeHandle;
use crate::run_sync_local;

use idevice::RsdService;
use idevice::services::dvt::xctest::TestConfig;
use idevice::services::installation_proxy::InstallationProxyClient;

fn write_message(message: *mut c_char, capacity: usize, text: &str) {
    if message.is_null() || capacity == 0 {
        return;
    }
    let bytes = text.as_bytes();
    let copy_len = bytes.len().min(capacity.saturating_sub(1));
    unsafe {
        ptr::copy_nonoverlapping(bytes.as_ptr(), message.cast::<u8>(), copy_len);
        *message.add(copy_len) = 0;
    }
}

async fn run_command(
    adapter_ref: &mut idevice::tcp::handle::AdapterHandle,
    handshake_ref: &mut idevice::services::rsd::RsdHandshake,
    command: &str,
    x1: f64,
    y1: f64,
    x2: f64,
    y2: f64,
    duration: f64,
    pink_count: i32,
    fast_mode: i32,
) -> Result<String, String> {
    let mut inst = InstallationProxyClient::connect_rsd(adapter_ref, handshake_ref)
        .await
        .map_err(|e| format!("step=installation-proxy-connect • {e:?}"))?;

    let apps = inst
        .get_apps(Some("User"), None)
        .await
        .map_err(|e| format!("step=installation-proxy-list • {e:?}"))?;

    let mut runner_ids: Vec<String> = apps
        .keys()
        .filter(|id| {
            let l = id.to_ascii_lowercase();
            l.ends_with(".xctrunner")
                || l.contains("pikminpilotrunner")
                || l.contains("pikminpilotrunneruitests")
        })
        .cloned()
        .collect();
    runner_ids.sort();

    let runner_id = runner_ids
        .first()
        .ok_or_else(|| {
            format!(
                "step=runner-discovery • no installed XCUITest runner among {} user apps",
                apps.len()
            )
        })?
        .clone();

    let target_id = "com.nianticlabs.pikmin";
    if !apps.contains_key(target_id) {
        return Err("step=target-discovery • Pikmin Bloom is not installed".into());
    }

    // Sideloadly may rewrite the main app bundle identifier, so discover the
    // installed Pikmin Pilot host dynamically. Stage 8.2.2 passes this to the
    // Runner so the test can explicitly hand foreground control back to Pilot
    // after tapping the carrying green X.
    let host_id = apps.keys()
        .filter(|id| {
            let l = id.to_ascii_lowercase();
            l.contains("pikminpilot")
                && !l.contains("runner")
                && !l.ends_with(".xctrunner")
                && l != target_id
        })
        .cloned()
        .next();

    let mut cfg = TestConfig::from_installation_proxy(
        &mut inst,
        &runner_id,
        Some(target_id),
    )
    .await
    .map_err(|e| format!("step=test-config • {e:?}"))?;

    let mut env = cfg.runner_env.take().unwrap_or_default();
    env.insert("PIKMIN_PILOT_COMMAND".to_owned(), command.to_owned().into());
    env.insert("PIKMIN_PILOT_X".to_owned(), format!("{x1:.8}").into());
    env.insert("PIKMIN_PILOT_Y".to_owned(), format!("{y1:.8}").into());
    env.insert("PIKMIN_PILOT_X2".to_owned(), format!("{x2:.8}").into());
    env.insert("PIKMIN_PILOT_Y2".to_owned(), format!("{y2:.8}").into());
    env.insert(
        "PIKMIN_PILOT_DURATION".to_owned(),
        format!("{duration:.4}").into(),
    );
    env.insert(
        "PIKMIN_PILOT_SELECT_COUNT".to_owned(),
        pink_count.to_string().into(),
    );
    // Backward-compatible key for older Runner payloads.
    env.insert(
        "PIKMIN_PILOT_PINK_COUNT".to_owned(),
        pink_count.to_string().into(),
    );
    env.insert(
        "PIKMIN_PILOT_FAST_MODE".to_owned(),
        fast_mode.to_string().into(),
    );
    if let Some(host_id) = host_id.as_ref() {
        env.insert(
            "PIKMIN_PILOT_HOST_BUNDLE_ID".to_owned(),
            host_id.clone().into(),
        );
    }
    cfg.runner_env = Some(env);

    drop(inst);

    let pid = idevice::services::dvt::xctest::pilot_run_existing_rsd_xctest(
        adapter_ref,
        handshake_ref,
        cfg,
        26,
        Some(Duration::from_secs(60)),
    )
    .await?;

    Ok(format!(
        "PHONE-LOCAL XCTEST COMMAND COMPLETED • command={} • p1=({:.5},{:.5}) • p2=({:.5},{:.5}) • duration={:.3} • pikminCount={} • fastMode={} • runner={} • pid={} • target={} • host={}",
        command, x1, y1, x2, y2, duration, pink_count, fast_mode, runner_id, pid, target_id,
        host_id.as_deref().unwrap_or("not-found")
    ))
}

unsafe fn execute_command_impl(
    adapter: *mut AdapterHandle,
    handshake: *mut RsdHandshakeHandle,
    command: &str,
    x1: f64,
    y1: f64,
    x2: f64,
    y2: f64,
    duration: f64,
    pink_count: i32,
    fast_mode: i32,
    message: *mut c_char,
    message_capacity: usize,
) -> i32 {
    if adapter.is_null() || handshake.is_null() {
        write_message(message, message_capacity, "XCTest execute received NULL RSD handles");
        return -120;
    }
    for value in [x1, y1, x2, y2] {
        if !(0.0..=1.0).contains(&value) {
            write_message(message, message_capacity, "XCTest normalized coordinate must be within 0...1");
            return -122;
        }
    }
    if !(0.0..=5.0).contains(&duration) {
        write_message(message, message_capacity, "XCTest duration must be within 0...5 seconds");
        return -123;
    }
    if !(2..=12).contains(&pink_count) {
        write_message(message, message_capacity, "XCTest Pikmin count must be within 2...12");
        return -124;
    }
    if !(0..=1).contains(&fast_mode) {
        write_message(message, message_capacity, "XCTest fast mode must be 0 or 1");
        return -125;
    }

    let result: Result<String, String> = run_sync_local(async move {
        let adapter_ref = unsafe { &mut (*adapter).0 };
        let handshake_ref = unsafe { &mut (*handshake).0 };
        run_command(
            adapter_ref,
            handshake_ref,
            command,
            x1,
            y1,
            x2,
            y2,
            duration,
            pink_count,
            fast_mode,
        )
        .await
    });

    match result {
        Ok(detail) => {
            write_message(message, message_capacity, &detail);
            0
        }
        Err(error) => {
            write_message(
                message,
                message_capacity,
                &format!("PHONE-LOCAL XCTEST COMMAND FAILED • command={command} • {error}"),
            );
            -121
        }
    }
}

pub(crate) unsafe fn pilot_xctest_execute_center_tap_impl(
    adapter: *mut AdapterHandle,
    handshake: *mut RsdHandshakeHandle,
    message: *mut c_char,
    message_capacity: usize,
) -> i32 {
    unsafe {
        execute_command_impl(
            adapter, handshake, "center",
            0.5, 0.5, 0.5, 0.5, 0.0,
            12, 0,
            message, message_capacity,
        )
    }
}

pub(crate) unsafe fn pilot_xctest_execute_activate_impl(
    adapter: *mut AdapterHandle,
    handshake: *mut RsdHandshakeHandle,
    message: *mut c_char,
    message_capacity: usize,
) -> i32 {
    unsafe {
        execute_command_impl(
            adapter, handshake, "activate",
            0.5, 0.5, 0.5, 0.5, 0.0,
            12, 0,
            message, message_capacity,
        )
    }
}

pub(crate) unsafe fn pilot_xctest_execute_tap_impl(
    adapter: *mut AdapterHandle,
    handshake: *mut RsdHandshakeHandle,
    x: f64,
    y: f64,
    message: *mut c_char,
    message_capacity: usize,
) -> i32 {
    unsafe {
        execute_command_impl(
            adapter, handshake, "tap",
            x, y, x, y, 0.0,
            12, 0,
            message, message_capacity,
        )
    }
}

pub(crate) unsafe fn pilot_xctest_execute_swipe_impl(
    adapter: *mut AdapterHandle,
    handshake: *mut RsdHandshakeHandle,
    from_x: f64,
    from_y: f64,
    to_x: f64,
    to_y: f64,
    duration: f64,
    message: *mut c_char,
    message_capacity: usize,
) -> i32 {
    unsafe {
        execute_command_impl(
            adapter, handshake, "swipe",
            from_x, from_y, to_x, to_y, duration,
            12, 0,
            message, message_capacity,
        )
    }
}

pub(crate) unsafe fn pilot_xctest_execute_select12_impl(
    adapter: *mut AdapterHandle,
    handshake: *mut RsdHandshakeHandle,
    message: *mut c_char,
    message_capacity: usize,
) -> i32 {
    unsafe {
        execute_command_impl(
            adapter, handshake, "select12",
            0.5, 0.5, 0.5, 0.5, 0.0,
            12, 0,
            message, message_capacity,
        )
    }
}

pub(crate) unsafe fn pilot_xctest_execute_dispatch_tail_impl(
    adapter: *mut AdapterHandle,
    handshake: *mut RsdHandshakeHandle,
    pink_x: f64,
    pink_y: f64,
    pink_count: i32,
    fast_mode: i32,
    message: *mut c_char,
    message_capacity: usize,
) -> i32 {
    unsafe {
        execute_command_impl(
            adapter, handshake, "dispatchtail",
            pink_x, pink_y, pink_x, pink_y, 0.0,
            pink_count, fast_mode,
            message, message_capacity,
        )
    }
}
