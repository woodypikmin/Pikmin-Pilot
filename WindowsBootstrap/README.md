# Pikmin Pilot Full Windows Bootstrap v2.3

This is the Windows fallback for iOS/iPadOS versions that cannot bootstrap RPPairing entirely on-device.

## User flow

1. Install Apple iTunes / Apple Mobile Device support on Windows.
2. Connect exactly one iPhone/iPad by USB.
3. Unlock it and tap **Trust** if asked.
4. Double-click `PikminPilotSetup.exe` (or `START_HERE.cmd`).
5. The visible setup window detects the UDID and installs the bundled `PikminPilot.ipa`.
6. Setup opens the Remote Pairing GUI. Choose **Remote pairing → Create → Pikmin Pilot**.
7. Close the pairing window when complete.
8. Unplug USB, open Pikmin Pilot, press **START PILOT**.

## Important v2.3 changes

- The Setup app is a real WinForms `WinExe`; it no longer relies on a console window that can flash and disappear.
- Every run writes `PikminPilotSetup.log` next to the EXE.
- The Rust helper binaries are built with static CRT linking to reduce missing-runtime launch failures.
- The GitHub workflow checks out upstream repos with `actions/checkout`; it no longer downloads GitHub source ZIPs with `Invoke-WebRequest`.
- By default the workflow downloads the latest successful `build-ios.yml` artifact and bundles its signed IPA as `PikminPilot.ipa`.

## New / unregistered devices

If the bundled IPA does not include the connected UDID in its provisioning profiles, iOS will reject installation. `PikminPilotSetup.exe` will show that error instead of silently exiting. The Toolkit still contains the registration/backend prototype for automating the Apple Developer device-registration/rebuild path; that server-side path remains a separate deployment step.


## v2.3 USB detection hardening

- `idevice_id -l` is given an 8-second hard timeout instead of three 2-minute attempts.
- The Setup window stays responsive and the log button remains available while probing USB.
- If the bundled Rust detector cannot reach Apple usbmuxd, Setup can use an already-installed `pymobiledevice3 usbmux list` as a fallback.
- `CHECK_USB.cmd` is included for standalone diagnostics.


### v2.3 host IPA guard
The setup refuses any IPA whose Payload root is `PikminPilotRunnerUITests-Runner.app`. Only the fully signed host IPA containing `Payload/PikminPilot.app` is accepted.
