// Pikmin Pilot Stage 7.6
// Finds the installed XCUITest runner over the existing phone-local RSD tunnel.

use std::ffi::c_char;
use std::ptr;

use crate::core_device_proxy::AdapterHandle;
use crate::rsd::RsdHandshakeHandle;
use crate::run_sync_local;

use idevice::RsdService;
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

pub(crate) unsafe fn pilot_xctest_runner_discovery_impl(
    adapter: *mut AdapterHandle,
    handshake: *mut RsdHandshakeHandle,
    message: *mut c_char,
    message_capacity: usize,
) -> i32 {
    if adapter.is_null() || handshake.is_null() {
        write_message(
            message,
            message_capacity,
            "XCTest runner discovery received NULL RSD handles",
        );
        return -90;
    }

    let result: Result<String, String> = run_sync_local(async move {
        let adapter_ref = unsafe { &mut (*adapter).0 };
        let handshake_ref = unsafe { &mut (*handshake).0 };

        let mut inst = InstallationProxyClient::connect_rsd(
            adapter_ref,
            handshake_ref,
        )
        .await
        .map_err(|e| format!("InstallationProxy RSD connect failed: {e:?}"))?;

        let apps = inst
            .get_apps(Some("User"), None)
            .await
            .map_err(|e| format!("InstallationProxy get_apps failed: {e:?}"))?;

        let mut candidates: Vec<String> = apps
            .keys()
            .filter(|bundle_id| {
                let lower = bundle_id.to_ascii_lowercase();
                lower.ends_with(".xctrunner")
                    || lower.contains("pikminpilotrunner")
                    || lower.contains("pikminpilotrunneruitests")
            })
            .cloned()
            .collect();

        candidates.sort();

        if candidates.is_empty() {
            return Err(format!(
                "XCTest Runner not installed • {} user apps scanned",
                apps.len()
            ));
        }

        Ok(format!(
            "PHONE-LOCAL XCTEST RUNNER FOUND • {} • {} user apps scanned",
            candidates.join(" | "),
            apps.len()
        ))
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
                &format!("PHONE-LOCAL XCTEST RUNNER MISSING • {error}"),
            );
            -91
        }
    }
}
