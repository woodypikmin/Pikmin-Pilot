// Pikmin Pilot Stage 11.5.4.6
// Cellular escape hatch that intentionally avoids raw RemotePairing :49152.
//
// Phase A (run while the proven 11.5.3 RPPairing/RSD path is alive on Wi-Fi):
//   existing Adapter/RSD -> lockdownd RSD shim -> classic Pair -> sidecar plist
//
// Phase B (cellular fallback after raw RPPairing first-hop fails):
//   classic sidecar -> TCP lockdownd provider -> CoreDeviceProxy -> software tunnel -> RSD
//
// The original rp_pairing_file.plist is never overwritten by this module.

use std::ffi::{c_char, CStr};
use std::net::IpAddr;
use std::ptr;
use std::time::Duration;

use crate::core_device_proxy::AdapterHandle;
use crate::rsd::RsdHandshakeHandle;
use crate::run_sync_local;

use idevice::core_device_proxy::CoreDeviceProxy;
use idevice::lockdown::LockdownClient;
use idevice::pairing_file::PairingFile;
use idevice::provider::TcpProvider;
use idevice::rsd::RsdHandshake;
use idevice::{IdeviceService, RsdService};

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

fn read_c_string(ptr: *const c_char, label: &str) -> Result<String, String> {
    if ptr.is_null() {
        return Err(format!("{label}=NULL"));
    }
    let value = unsafe { CStr::from_ptr(ptr) }
        .to_str()
        .map_err(|_| format!("{label}=invalid-utf8"))?;
    if value.is_empty() {
        return Err(format!("{label}=empty"));
    }
    Ok(value.to_owned())
}

pub(crate) unsafe fn pilot_classic_bootstrap_rsd_impl(
    adapter: *mut AdapterHandle,
    handshake: *mut RsdHandshakeHandle,
    output_path: *const c_char,
    host_id: *const c_char,
    system_buid: *const c_char,
    message: *mut c_char,
    message_capacity: usize,
) -> i32 {
    if adapter.is_null() || handshake.is_null() {
        write_message(message, message_capacity, "CLASSIC BOOTSTRAP FAILED • NULL RSD handles");
        return -210;
    }

    let output_path = match read_c_string(output_path, "output_path") {
        Ok(v) => v,
        Err(e) => { write_message(message, message_capacity, &e); return -211; }
    };
    let host_id = match read_c_string(host_id, "host_id") {
        Ok(v) => v,
        Err(e) => { write_message(message, message_capacity, &e); return -212; }
    };
    let system_buid = match read_c_string(system_buid, "system_buid") {
        Ok(v) => v,
        Err(e) => { write_message(message, message_capacity, &e); return -213; }
    };

    let result: Result<String, String> = run_sync_local(async move {
        let adapter_ref = unsafe { &mut (*adapter).0 };
        let handshake_ref = unsafe { &mut (*handshake).0 };

        let mut lockdown = LockdownClient::connect_rsd(adapter_ref, handshake_ref)
            .await
            .map_err(|e| format!("step=lockdownd-connect-rsd • {e:?}"))?;

        // pair_once is deliberate: never trap START PILOT in an endless wait if iOS
        // is showing/awaiting a Trust prompt. The next START can retry after approval.
        let pairing = lockdown
            .pair_once(host_id, system_buid, Some("Pikmin Pilot"))
            .await
            .map_err(|e| format!("step=classic-pair-once • {e:?}"))?;

        let bytes = pairing
            .clone()
            .serialize()
            .map_err(|e| format!("step=classic-serialize • {e:?}"))?;
        std::fs::write(&output_path, &bytes)
            .map_err(|e| format!("step=classic-write-sidecar • {e:?}"))?;

        // These flags are best-effort. First try the already-trusted RSD lockdown
        // channel directly. Some iOS builds allow wireless_lockdown SetValue here
        // without nesting a second TLS session. If that is rejected, retry after a
        // classic StartSession using the newly minted record.
        let domain = Some("com.apple.mobile.wireless_lockdown");
        let direct_a = lockdown
            .set_value("EnableWifiConnections", plist::Value::Boolean(true), domain)
            .await;
        let direct_b = lockdown
            .set_value("EnableWifiDebugging", plist::Value::Boolean(true), domain)
            .await;
        let flag_diag = if direct_a.is_ok() && direct_b.is_ok() {
            format!("wifiFlags=direct:connections:{:?},debugging:{:?}", direct_a, direct_b)
        } else {
            match lockdown.start_session(&pairing).await {
                Ok(_) => {
                    let a = lockdown
                        .set_value("EnableWifiConnections", plist::Value::Boolean(true), domain)
                        .await;
                    let b = lockdown
                        .set_value("EnableWifiDebugging", plist::Value::Boolean(true), domain)
                        .await;
                    format!(
                        "wifiFlags=direct({:?},{:?});session:connections:{:?},debugging:{:?}",
                        direct_a, direct_b, a, b
                    )
                }
                Err(e) => format!(
                    "wifiFlags=direct({:?},{:?});session-unavailable:{e:?}",
                    direct_a, direct_b
                ),
            }
        };

        Ok(format!(
            "CLASSIC SIDECAR READY ✅ • bytes={} • path={} • {}",
            bytes.len(), output_path, flag_diag
        ))
    });

    match result {
        Ok(text) => {
            write_message(message, message_capacity, &text);
            0
        }
        Err(text) => {
            write_message(message, message_capacity, &format!("CLASSIC BOOTSTRAP FAILED ❌ • {text}"));
            -214
        }
    }
}

pub(crate) unsafe fn pilot_classic_coredevice_tunnel_impl(
    classic_pairing_path: *const c_char,
    host: *const c_char,
    out_adapter: *mut *mut AdapterHandle,
    out_handshake: *mut *mut RsdHandshakeHandle,
    message: *mut c_char,
    message_capacity: usize,
) -> i32 {
    if out_adapter.is_null() || out_handshake.is_null() {
        write_message(message, message_capacity, "CLASSIC COREDEVICE FAILED • NULL outputs");
        return -220;
    }
    unsafe {
        *out_adapter = ptr::null_mut();
        *out_handshake = ptr::null_mut();
    }

    let pairing_path = match read_c_string(classic_pairing_path, "classic_pairing_path") {
        Ok(v) => v,
        Err(e) => { write_message(message, message_capacity, &e); return -221; }
    };
    let host = match read_c_string(host, "host") {
        Ok(v) => v,
        Err(e) => { write_message(message, message_capacity, &e); return -222; }
    };

    let result = run_sync_local(async move {
        tokio::time::timeout(Duration::from_secs(6), async move {
            let pairing_file = PairingFile::read_from_file(&pairing_path)
                .map_err(|e| format!("step=read-classic-sidecar • {e:?}"))?;
            let addr: IpAddr = host
                .parse()
                .map_err(|e| format!("step=parse-host • {host} • {e:?}"))?;

            let provider = TcpProvider {
                addr,
                scope_id: None,
                pairing_file,
                label: "Pikmin Pilot Classic CoreDevice".to_owned(),
            };

            // IdeviceService::connect performs the classic lockdownd session and
            // starts com.apple.internal.devicecompute.CoreDeviceProxy.
            let proxy = CoreDeviceProxy::connect(&provider)
                .await
                .map_err(|e| format!("step=coredeviceproxy-connect host={host}:62078 • {e:?}"))?;
            let rsd_port = proxy.tunnel_info().server_rsd_port;
            let adapter = proxy
                .create_software_tunnel()
                .map_err(|e| format!("step=coredevice-software-tunnel • {e:?}"))?;
            let mut adapter = adapter.to_async_handle();
            let rsd_stream = adapter
                .connect(rsd_port)
                .await
                .map_err(|e| format!("step=coredevice-rsd-connect port={rsd_port} • {e:?}"))?;
            let handshake = RsdHandshake::new(rsd_stream)
                .await
                .map_err(|e| format!("step=coredevice-rsd-handshake • {e:?}"))?;

            Ok::<_, String>((adapter, handshake, rsd_port, host))
        })
        .await
        .map_err(|_| "step=classic-coredevice • timeout=6s".to_owned())?
    });

    match result {
        Ok((adapter, handshake, rsd_port, host)) => {
            unsafe {
                *out_adapter = Box::into_raw(Box::new(AdapterHandle(adapter)));
                *out_handshake = Box::into_raw(Box::new(RsdHandshakeHandle(handshake)));
            }
            write_message(
                message,
                message_capacity,
                &format!("CLASSIC COREDEVICE RSD READY ✅ • host={host}:62078 • rsdPort={rsd_port}"),
            );
            0
        }
        Err(text) => {
            write_message(message, message_capacity, &format!("CLASSIC COREDEVICE FAILED ❌ • {text}"));
            -223
        }
    }
}
