# PikminPilotSetup.exe

Goal: a Windows user should not need to understand IPA, UDID, provisioning, or RPPairing.

## Local test mode (recommended first)

Put a Pikmin Pilot IPA that is already provisioned for the connected device next to `PikminPilotSetup.exe` and name it `PikminPilot.ipa`.

Then:

1. Install iTunes / Apple Mobile Device USB drivers.
2. Connect unlocked iPhone/iPad by USB and tap Trust.
3. Double-click `PikminPilotSetup.exe`.
4. Setup detects UDID and installs the IPA automatically.
5. It launches the bundled pairing helper. Choose **Remote pairing → Create → Pikmin Pilot**.
6. Close the pairing helper. Disconnect USB and start Pikmin Pilot.

## Backend mode

Copy `setup-config.example.json` to `setup-config.json` and configure the Cloudflare Worker supplied under `BootstrapBackend/`.
If no local IPA exists, Setup submits the UDID and waits until the registration workflow publishes a freshly provisioned IPA.

The Apple API key is NEVER stored in this Windows package.
