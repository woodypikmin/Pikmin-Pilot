// Pikmin Pilot Stage 7.5.1
// Retained Stage 7.4 phone-local XCTest service manifest probe.

use std::ffi::c_char;
use std::ptr;

use crate::rsd::RsdHandshakeHandle;

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

fn service_port(
    handshake: &idevice::rsd::RsdHandshake,
    name: &str,
) -> Option<u16> {
    handshake.services.get(name).map(|service| service.port)
}

pub(crate) unsafe fn pilot_xctest_service_probe_impl(
    handshake: *mut RsdHandshakeHandle,
    message: *mut c_char,
    message_capacity: usize,
) -> i32 {
    if handshake.is_null() {
        write_message(
            message,
            message_capacity,
            "XCTest probe received NULL RSD handshake",
        );
        return -70;
    }

    let handshake_ref = unsafe { &(*handshake).0 };

    let tm = service_port(handshake_ref, "com.apple.dt.testmanagerd.remote");
    let dvt = service_port(handshake_ref, "com.apple.instruments.dtservicehub");
    let fetch = service_port(handshake_ref, "com.apple.dt.remoteFetchSymbols");
    let view = service_port(handshake_ref, "com.apple.dt.ViewHierarchyAgent.remote");

    let fmt = |value: Option<u16>| -> String {
        value
            .map(|port| format!("YES:{port}"))
            .unwrap_or_else(|| "NO".to_string())
    };

    let ready = tm.is_some() && dvt.is_some();

    let text = if ready {
        format!(
            "PHONE-LOCAL XCTEST SERVICES READY • testmanagerd.remote={} • dtservicehub={} • remoteFetchSymbols={} • ViewHierarchyAgent={} • total={} services",
            fmt(tm),
            fmt(dvt),
            fmt(fetch),
            fmt(view),
            handshake_ref.services.len(),
        )
    } else {
        format!(
            "PHONE-LOCAL XCTEST SERVICES BLOCKED • testmanagerd.remote={} • dtservicehub={} • remoteFetchSymbols={} • ViewHierarchyAgent={} • total={} services",
            fmt(tm),
            fmt(dvt),
            fmt(fetch),
            fmt(view),
            handshake_ref.services.len(),
        )
    };

    write_message(message, message_capacity, &text);
    if ready { 0 } else { -71 }
}
