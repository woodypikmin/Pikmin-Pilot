# Windows Pairing Setup

把 `.github/workflows/build-pikmin-pilot-pairing-helper.yml` 和 `WindowsPairingSetup/` 放進你的 GitHub repo，然後：

`Actions → Build Pikmin Pilot Pairing Helper for Windows → Run workflow`

完成後下載 artifact：

`PikminPilot-Pairing-Setup-Windows`

裡面會有：

`PikminPilotPairingSetup.exe`

這不是重新發明 RPPairing；它直接基於 `idevice_pair v1.1.0`，只加兩個小改動：

- Remote Pairing 的支援 App 清單加入 `Pikmin Pilot` → `rp_pairing_file.plist`
- 視窗名稱改成 `Pikmin Pilot Pairing Setup`

Upstream 已經支援 USB 產生 Remote Pairing、AFC/House Arrest 直接寫入 App Documents、以及 pairing 驗證。


## v1.2 patch strategy

`idevice_pair v1.1.0` keeps the destination metadata in `src/known_apps.rs`.
The toolkit now clones an existing known Remote-Pairing-capable app record (`Auto Capture`, fallback `StikDebug`) and rewrites only the display name, bundle id, and remote pairing filename for Pikmin Pilot. It no longer guesses a `supported_apps_for_mode()` function or map name.
