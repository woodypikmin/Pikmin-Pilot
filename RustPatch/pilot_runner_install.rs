// Pikmin Pilot Stage 9.1
// Phone-local signed Runner IPA upload + install through RSD AFC/InstallationProxy.
// No WDA and no desktop-resident process.

use std::ffi::{c_char, CStr};
use std::ptr;

use crate::core_device_proxy::AdapterHandle;
use crate::rsd::RsdHandshakeHandle;
use crate::run_sync_local;

use idevice::RsdService;
use idevice::afc::{AfcClient, opcode::AfcFopenMode};
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

pub(crate) unsafe fn pilot_runner_install_ipa_impl(
    adapter: *mut AdapterHandle,
    handshake: *mut RsdHandshakeHandle,
    local_ipa_path: *const c_char,
    message: *mut c_char,
    message_capacity: usize,
) -> i32 {
    if adapter.is_null() || handshake.is_null() || local_ipa_path.is_null() {
        write_message(message, message_capacity, "Runner self-install received NULL input");
        return -120;
    }

    let local_path = match unsafe { CStr::from_ptr(local_ipa_path) }.to_str() {
        Ok(value) if !value.is_empty() => value.to_owned(),
        _ => {
            write_message(message, message_capacity, "Runner IPA path is invalid UTF-8 or empty");
            return -121;
        }
    };

    let result: Result<String, String> = run_sync_local(async move {
        let ipa = std::fs::read(&local_path)
            .map_err(|e| format!("step=read-local-runner-ipa • {e}"))?;
        if ipa.len() < 4 || &ipa[..2] != b"PK" {
            return Err("step=validate-local-runner-ipa • file is not a ZIP/IPA".into());
        }

        let adapter_ref = unsafe { &mut (*adapter).0 };
        let handshake_ref = unsafe { &mut (*handshake).0 };

        let mut afc = AfcClient::connect_rsd(adapter_ref, handshake_ref)
            .await
            .map_err(|e| format!("step=afc-connect-rsd • {e:?}"))?;

        if afc.get_file_info("PublicStaging").await.is_err() {
            afc.mk_dir("PublicStaging")
                .await
                .map_err(|e| format!("step=afc-mkdir-publicstaging • {e:?}"))?;
        }

        let staging_path = "PublicStaging/PikminPilotRunner.ipa";
        let mut file = afc
            .open(staging_path, AfcFopenMode::Wr)
            .await
            .map_err(|e| format!("step=afc-open-staging • {e:?}"))?;
        file.write_entire(&ipa)
            .await
            .map_err(|e| format!("step=afc-upload-runner • {e:?}"))?;
        file.close()
            .await
            .map_err(|e| format!("step=afc-close-staging • {e:?}"))?;
        drop(afc);

        let mut inst = InstallationProxyClient::connect_rsd(adapter_ref, handshake_ref)
            .await
            .map_err(|e| format!("step=installation-proxy-connect • {e:?}"))?;

        let before = inst
            .get_apps(Some("User"), None)
            .await
            .map_err(|e| format!("step=pre-install-list • {e:?}"))?;
        let runner_already_installed = before.keys().any(|bundle_id| {
            let lower = bundle_id.to_ascii_lowercase();
            lower.ends_with(".xctrunner")
                || lower.contains("pikminpilotrunner")
                || lower.contains("pikminpilotrunneruitests")
        });

        let action = if runner_already_installed { "upgrade" } else { "install" };
        if runner_already_installed {
            inst.upgrade(staging_path, None)
                .await
                .map_err(|e| format!("step=installation-proxy-upgrade • {e:?}"))?;
        } else {
            inst.install(staging_path, None)
                .await
                .map_err(|e| format!("step=installation-proxy-install • {e:?}"))?;
        }

        let apps = inst
            .get_apps(Some("User"), None)
            .await
            .map_err(|e| format!("step=post-install-list • {e:?}"))?;
        let mut runners: Vec<String> = apps
            .keys()
            .filter(|bundle_id| {
                let lower = bundle_id.to_ascii_lowercase();
                lower.ends_with(".xctrunner")
                    || lower.contains("pikminpilotrunner")
                    || lower.contains("pikminpilotrunneruitests")
            })
            .cloned()
            .collect();
        runners.sort();
        if runners.is_empty() {
            return Err("step=post-install-verify • install completed but no Runner is visible".into());
        }

        Ok(format!(
            "PHONE-LOCAL XCTEST RUNNER INSTALL COMPLETED • action={} • uploaded={} bytes • runner={}",
            action,
            ipa.len(),
            runners.join(" | ")
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
                &format!("PHONE-LOCAL XCTEST RUNNER INSTALL FAILED • {error}"),
            );
            -122
        }
    }
}
