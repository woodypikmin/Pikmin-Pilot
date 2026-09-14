
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

fn dict_string(value: &plist::Value, key: &str) -> Option<String> {
    value
        .as_dictionary()
        .and_then(|d| d.get(key))
        .and_then(|v| v.as_string())
        .map(|s| s.to_string())
}

pub(crate) unsafe fn pilot_xctest_metadata_impl(
    adapter: *mut AdapterHandle,
    handshake: *mut RsdHandshakeHandle,
    message: *mut c_char,
    message_capacity: usize,
) -> i32 {
    if adapter.is_null() || handshake.is_null() {
        write_message(message, message_capacity, "XCTest metadata received NULL RSD handles");
        return -110;
    }

    let result: Result<String, String> = run_sync_local(async move {
        let adapter_ref = unsafe { &mut (*adapter).0 };
        let handshake_ref = unsafe { &mut (*handshake).0 };

        let mut inst = InstallationProxyClient::connect_rsd(adapter_ref, handshake_ref)
            .await
            .map_err(|e| format!("InstallationProxy connect failed: {e:?}"))?;

        let apps = inst
            .get_apps(Some("User"), None)
            .await
            .map_err(|e| format!("InstallationProxy get_apps failed: {e:?}"))?;

        let mut runner_ids: Vec<String> = apps.keys()
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
            .ok_or_else(|| format!("No installed XCUITest runner found among {} user apps", apps.len()))?
            .clone();

        let runner = apps.get(&runner_id)
            .ok_or_else(|| "Runner disappeared from InstallationProxy result".to_string())?;

        let pikmin_id = "com.nianticlabs.pikmin";
        let pikmin = apps.get(pikmin_id)
            .ok_or_else(|| "Pikmin Bloom not found in User apps".to_string())?;

        let runner_path = dict_string(runner, "Path")
            .ok_or_else(|| "Runner metadata missing Path".to_string())?;
        let runner_container = dict_string(runner, "Container")
            .unwrap_or_else(|| "<none>".into());
        let runner_exec = dict_string(runner, "CFBundleExecutable")
            .unwrap_or_else(|| "<none>".into());

        let pikmin_path = dict_string(pikmin, "Path")
            .ok_or_else(|| "Pikmin metadata missing Path".to_string())?;
        let pikmin_container = dict_string(pikmin, "Container")
            .unwrap_or_else(|| "<none>".into());
        let pikmin_exec = dict_string(pikmin, "CFBundleExecutable")
            .unwrap_or_else(|| "<none>".into());

        let test_bundle_path = format!(
            "{}/PlugIns/PikminPilotRunnerUITests.xctest",
            runner_path.trim_end_matches('/')
        );
        let test_bundle_url = format!("file://{}", test_bundle_path);

        Ok(format!(
            "PHONE-LOCAL XCTEST METADATA READY • runnerID={} • runnerPath={} • runnerContainer={} • runnerExec={} • testBundleURL={} • targetID={} • targetPath={} • targetContainer={} • targetExec={} • total={} user apps",
            runner_id,
            runner_path,
            runner_container,
            runner_exec,
            test_bundle_url,
            pikmin_id,
            pikmin_path,
            pikmin_container,
            pikmin_exec,
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
                &format!("PHONE-LOCAL XCTEST METADATA FAILED • {error}"),
            );
            -111
        }
    }
}
