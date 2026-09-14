use std::ffi::{CStr, CString, c_char};
use std::net::Ipv4Addr;
use std::path::PathBuf;
use std::time::Duration;

use idevice::remote_pairing::{PairableHost, PairableHostInfo, RpPairingFile, RpPairingSocket};

use crate::run_sync_local;

pub type PilotPairingReadyCallback = extern "C" fn(
    service_identifier: *const c_char,
    port: u16,
    txt_records: *const c_char,
);
pub type PilotPairingPinCallback = extern "C" fn(pin: *const c_char);

unsafe fn write_message(message: *mut c_char, capacity: usize, text: &str) {
    if message.is_null() || capacity == 0 {
        return;
    }
    let bytes = text.as_bytes();
    let count = bytes.len().min(capacity.saturating_sub(1));
    unsafe {
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), message.cast::<u8>(), count);
        *message.add(count) = 0;
    }
}

fn clean_c_string(value: &str) -> CString {
    let cleaned = value.replace('\0', "");
    CString::new(cleaned).unwrap_or_else(|_| CString::new("Pikmin Pilot").unwrap())
}

/// Pikmin Pilot Stage 11.6.2 on-device RPPairing responder.
///
/// This deliberately does NOT use idevice-ffi's `pairable_host_accept`, because
/// that helper owns its mDNS publication through the `mdns-sd` crate. On iOS the
/// app publishes Bonjour through Foundation/NetService instead, so this Rust
/// helper only binds TCP, emits the exact service metadata through `ready_callback`,
/// accepts one iOS 27+ device-initiated pairing, and persists the resulting
/// rp_pairing_file.plist into the app's Documents directory.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pilot_pairing_host_accept(
    output_path: *const c_char,
    host_name: *const c_char,
    timeout_seconds: u64,
    ready_callback: PilotPairingReadyCallback,
    pin_callback: PilotPairingPinCallback,
    message: *mut c_char,
    message_capacity: usize,
) -> i32 {
    if output_path.is_null() || host_name.is_null() {
        unsafe { write_message(message, message_capacity, "step=pairing-args • null output path or host name") };
        return -1;
    }

    let output_path = match unsafe { CStr::from_ptr(output_path) }.to_str() {
        Ok(value) if !value.is_empty() => PathBuf::from(value),
        _ => {
            unsafe { write_message(message, message_capacity, "step=pairing-args • invalid output path") };
            return -2;
        }
    };
    let host_name = match unsafe { CStr::from_ptr(host_name) }.to_str() {
        Ok(value) if !value.is_empty() => value.to_owned(),
        _ => {
            unsafe { write_message(message, message_capacity, "step=pairing-args • invalid host name") };
            return -3;
        }
    };
    let timeout_seconds = timeout_seconds.clamp(15, 600);

    let result: Result<String, String> = run_sync_local(async move {
        let listener = tokio::net::TcpListener::bind((Ipv4Addr::UNSPECIFIED, 0))
            .await
            .map_err(|e| format!("step=pairing-listen • bind failed • {e}"))?;
        let port = listener
            .local_addr()
            .map_err(|e| format!("step=pairing-listen • local_addr failed • {e}"))?
            .port();

        let mut pairing_file = RpPairingFile::generate(&host_name);
        let host_info = PairableHostInfo::generate(host_name.clone(), "Mac17,7");
        let service_identifier = pairing_file.identifier.clone();
        let txt_records = host_info.mdns_txt_records(&service_identifier);
        let txt_blob = txt_records
            .iter()
            .map(|(key, value)| format!("{key}={value}"))
            .collect::<Vec<_>>()
            .join("\n");

        {
            let service_c = clean_c_string(&service_identifier);
            let txt_c = clean_c_string(&txt_blob);
            ready_callback(service_c.as_ptr(), port, txt_c.as_ptr());
        }

        let pairing_future = async {
            let (stream, _peer_addr) = listener
                .accept()
                .await
                .map_err(|e| format!("step=pairing-accept • {e}"))?;

            let socket = RpPairingSocket::new_device(stream);
            let mut host = PairableHost::new(socket, host_info);
            host.accept(&mut pairing_file, |pin| async move {
                let pin_c = clean_c_string(&pin);
                pin_callback(pin_c.as_ptr());
            })
            .await
            .map_err(|e| format!("step=pairing-protocol • {e:?}"))?;

            pairing_file
                .write_to_file(&output_path)
                .await
                .map_err(|e| format!("step=pairing-save • {e:?}"))?;

            Ok::<String, String>(format!(
                "PHONE-LOCAL RPPairing CREATED ✅ • identifier={} • saved={}",
                service_identifier,
                output_path.display()
            ))
        };

        tokio::time::timeout(Duration::from_secs(timeout_seconds), pairing_future)
            .await
            .map_err(|_| {
                format!(
                    "step=pairing-wait • timed out after {}s waiting for iOS device-initiated pairing",
                    timeout_seconds
                )
            })?
    });

    match result {
        Ok(text) => {
            unsafe { write_message(message, message_capacity, &text) };
            0
        }
        Err(text) => {
            unsafe { write_message(message, message_capacity, &text) };
            1
        }
    }
}
