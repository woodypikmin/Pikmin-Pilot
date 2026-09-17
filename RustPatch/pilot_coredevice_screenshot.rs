// Pikmin Pilot Stage 11.5.4.25
// iPad post-tail screenshot path using CoreDevice Screen Capture rather than
// the DVT Instruments screenshot channel. This deliberately stays on the
// existing phone-local RSD adapter/handshake and does not touch DDI, Runner,
// PacketTunnel, UniversalHID, or the iPhone screenshot path.

use std::ffi::{c_char, CStr};
use std::ptr;
use std::time::Duration;

use crate::core_device_proxy::AdapterHandle;
use crate::rsd::RsdHandshakeHandle;
use crate::run_sync_local;

use idevice::RsdService;
use idevice::core_device::{ImageFormat, ScreenCaptureServiceClient};

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

pub(crate) unsafe fn pilot_coredevice_screenshot_impl(
    adapter: *mut AdapterHandle,
    handshake: *mut RsdHandshakeHandle,
    output_path: *const c_char,
    timeout_ms: u64,
    message: *mut c_char,
    message_capacity: usize,
) -> i32 {
    if adapter.is_null() || handshake.is_null() || output_path.is_null() {
        write_message(message, message_capacity, "CoreDevice screenshot received NULL argument");
        return -310;
    }

    let output = match unsafe { CStr::from_ptr(output_path) }.to_str() {
        Ok(v) if !v.is_empty() => v.to_owned(),
        _ => {
            write_message(message, message_capacity, "CoreDevice screenshot output path is invalid");
            return -311;
        }
    };
    let bounded_ms = timeout_ms.clamp(1_000, 15_000);

    let result: Result<usize, String> = run_sync_local(async move {
        let adapter_ref = unsafe { &mut (*adapter).0 };
        let handshake_ref = unsafe { &mut (*handshake).0 };

        let mut client = ScreenCaptureServiceClient::connect_rsd(adapter_ref, handshake_ref)
            .await
            .map_err(|e| format!("CoreDevice ScreenCapture RSD connect failed: {e:?}"))?;

        let image = match tokio::time::timeout(
            Duration::from_millis(bounded_ms),
            client.take_screenshot(None, ImageFormat::Png),
        )
        .await
        {
            Ok(Ok(bytes)) => bytes,
            Ok(Err(e)) => return Err(format!("CoreDevice screenshot failed: {e:?}")),
            Err(_) => return Err(format!("CoreDevice screenshot timed out after {bounded_ms} ms")),
        };

        std::fs::write(&output, &image)
            .map_err(|e| format!("CoreDevice screenshot save failed: {e}"))?;
        Ok(image.len())
    });

    match result {
        Ok(size) => {
            write_message(
                message,
                message_capacity,
                &format!("COREDEVICE SCREENSHOT OK • {size} bytes • timeout={bounded_ms}ms"),
            );
            0
        }
        Err(error) => {
            write_message(message, message_capacity, &error);
            -312
        }
    }
}
