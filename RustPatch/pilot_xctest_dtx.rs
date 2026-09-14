// Pikmin Pilot Stage 7.5
// Phone-local XCTest DTX bootstrap over an already-established RSD tunnel.

use std::ffi::c_char;
use std::ptr;

use crate::core_device_proxy::AdapterHandle;
use crate::rsd::RsdHandshakeHandle;
use crate::run_sync_local;

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

pub(crate) unsafe fn pilot_xctest_dtx_bootstrap_impl(
    adapter: *mut AdapterHandle,
    handshake: *mut RsdHandshakeHandle,
    message: *mut c_char,
    message_capacity: usize,
) -> i32 {
    if adapter.is_null() || handshake.is_null() {
        write_message(
            message,
            message_capacity,
            "XCTest DTX bootstrap received NULL RSD handles",
        );
        return -80;
    }

    let result: Result<String, String> = run_sync_local(async move {
        let adapter_ref = unsafe { &mut (*adapter).0 };
        let handshake_ref = unsafe { &(*handshake).0 };

        idevice::services::dvt::xctest::pilot_probe_existing_rsd_dtx(
            adapter_ref,
            handshake_ref,
        )
        .await
        .map_err(|e| format!("{e:?}"))
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
                &format!("PHONE-LOCAL XCTEST DTX FAILED • {error}"),
            );
            -81
        }
    }
}
