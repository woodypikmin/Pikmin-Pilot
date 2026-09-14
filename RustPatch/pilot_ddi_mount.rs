// Pikmin Pilot Stage 11.3.2
// Phone-local Personalized Developer Disk Image mount over the already-proven
// RPPairing software TCP adapter + trusted RSD session.
// Equivalent core sequence to pymobiledevice3 mounter auto-mount for iOS 17+:
//   ImageMounter RSD shim -> existing/on-device personalization manifest or TSS ->
//   ReceiveBytes(Personalized) -> MountImage(Personalized, trustcache).

use std::ffi::{c_char, CStr};
use std::ptr;

use crate::core_device_proxy::AdapterHandle;
use crate::rsd::RsdHandshakeHandle;
use crate::run_sync_local;

use idevice::RsdService;
use idevice::services::mobile_image_mounter::ImageMounter;

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

fn read_path(ptr: *const c_char, label: &str) -> Result<String, String> {
    if ptr.is_null() {
        return Err(format!("{label} path is NULL"));
    }
    let value = unsafe { CStr::from_ptr(ptr) }
        .to_str()
        .map_err(|_| format!("{label} path is not UTF-8"))?;
    if value.is_empty() {
        return Err(format!("{label} path is empty"));
    }
    Ok(value.to_owned())
}

fn plist_u64(value: &plist::Value) -> Option<u64> {
    match value {
        plist::Value::Integer(v) => v.as_unsigned(),
        plist::Value::String(v) => v.parse::<u64>().ok(),
        _ => None,
    }
}

pub(crate) unsafe fn pilot_ddi_mount_personalized_impl(
    adapter: *mut AdapterHandle,
    handshake: *mut RsdHandshakeHandle,
    image_path: *const c_char,
    build_manifest_path: *const c_char,
    trustcache_path: *const c_char,
    message: *mut c_char,
    message_capacity: usize,
) -> i32 {
    if adapter.is_null() || handshake.is_null() {
        write_message(message, message_capacity, "DDI mount received NULL RSD handles");
        return -160;
    }

    let image_path = match read_path(image_path, "Image.dmg") {
        Ok(v) => v,
        Err(e) => { write_message(message, message_capacity, &e); return -161; }
    };
    let build_manifest_path = match read_path(build_manifest_path, "BuildManifest.plist") {
        Ok(v) => v,
        Err(e) => { write_message(message, message_capacity, &e); return -162; }
    };
    let trustcache_path = match read_path(trustcache_path, "Image.dmg.trustcache") {
        Ok(v) => v,
        Err(e) => { write_message(message, message_capacity, &e); return -163; }
    };

    let result: Result<String, String> = run_sync_local(async move {
        let adapter_ref = unsafe { &mut (*adapter).0 };
        let handshake_ref = unsafe { &mut (*handshake).0 };

        let mounter_service = "com.apple.mobile.mobile_image_mounter.shim.remote";
        if !handshake_ref.services.contains_key(mounter_service) {
            return Err(format!(
                "step=preflight-mobile-image-mounter • ServiceNotFound • {} absent from pre-DDI RSD manifest • total={} services",
                mounter_service,
                handshake_ref.services.len()
            ));
        }

        let unique_chip_id = handshake_ref
            .properties
            .get("UniqueChipID")
            .and_then(plist_u64)
            .ok_or_else(|| "step=read-rsd-ecid • RSD Properties.UniqueChipID missing/not-u64".to_string())?;

        let image = std::fs::read(&image_path)
            .map_err(|e| format!("step=read-ddi-image • {e}"))?;
        let build_manifest = std::fs::read(&build_manifest_path)
            .map_err(|e| format!("step=read-ddi-build-manifest • {e}"))?;
        let trustcache = std::fs::read(&trustcache_path)
            .map_err(|e| format!("step=read-ddi-trustcache • {e}"))?;

        if image.is_empty() || build_manifest.is_empty() || trustcache.is_empty() {
            return Err("step=validate-ddi-assets • one or more DDI payloads are empty".into());
        }

        // If already mounted, treat this as success. lookup_image can be empty on some
        // releases, so also inspect CopyDevices exactly like modern pymobiledevice3 does.
        let mut mounter = ImageMounter::connect_rsd(adapter_ref, handshake_ref)
            .await
            .map_err(|e| format!("step=image-mounter-connect-rsd • {e:?}"))?;

        let already_lookup = mounter.lookup_image("Personalized").await.is_ok();
        let already_copy = if already_lookup {
            false
        } else {
            mounter.copy_devices().await
                .map(|entries| entries.iter().any(|entry| {
                    entry.as_dictionary()
                        .and_then(|d| d.get("DiskImageType"))
                        .and_then(|v| v.as_string())
                        .map(|s| s == "Personalized")
                        .unwrap_or(false)
                }))
                .unwrap_or(false)
        };
        if already_lookup || already_copy {
            return Ok(format!(
                "PHONE-LOCAL DDI ALREADY MOUNTED • type=Personalized • ecid={} • image={} bytes",
                unique_chip_id,
                image.len()
            ));
        }

        let developer_mode = mounter.query_developer_mode_status().await
            .map_err(|e| format!("step=query-developer-mode • {e:?}"))?;
        if !developer_mode {
            return Err("step=query-developer-mode • Developer Mode is OFF; iOS refuses Personalized DDI mounting".into());
        }

        mounter
            .pilot_mount_personalized_diagnostic_rsd(
                adapter_ref,
                handshake_ref,
                image,
                trustcache,
                &build_manifest,
                None,
                unique_chip_id,
            )
            .await
            .map_err(|e| format!("step=mount-personalized-rsd • {e:?}"))?;

        Ok(format!(
            "PHONE-LOCAL DDI MOUNTED ✅ • type=Personalized • ecid={} • next=rebuild-RSD",
            unique_chip_id
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
                &format!("PHONE-LOCAL DDI MOUNT FAILED • {error}"),
            );
            -164
        }
    }
}
