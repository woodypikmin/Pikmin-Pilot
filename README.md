# Pikmin Pilot Distribution Toolkit v1.0

這個工具包**不修改 Pikmin Pilot App 核心**。它是給 Stage 11.5.3 / 11.6.x 之後的發佈與首次配對使用。

包含兩部分：

1. **Windows Pairing Setup**
   - 針對 iOS 17.4–26.x 使用者。
   - 使用者只需要 USB 接一次、解鎖並按「信任」。
   - 客製版 `idevice_pair` 會直接看到 **Pikmin Pilot** 按鈕，Remote Pairing 建立後可直接把 `rp_pairing_file.plist` 寫入 Pikmin Pilot 的 Documents。
   - 之後 Pikmin Pilot 自己保存 pairing，正常使用不再需要電腦。

2. **OTA Web Package**
   - 把已簽名的 Pikmin Pilot IPA 轉成 `manifest.plist + index.html + PikminPilot.ipa`。
   - 使用者在已註冊裝置的 Safari 打開頁面，按一次即可觸發 OTA 安裝。
   - 網站必須使用公開可存取的 HTTPS。

## 不變的 Apple 限制

- Development / Ad Hoc IPA 只能安裝到 provisioning profile 內已註冊的裝置。
- 從 IPA 安裝的 development build 仍需要在裝置上啟用 Developer Mode。
- OTA 只是把「安裝 IPA」變成 Safari 點一下；它不會替你繞過裝置註冊或 Apple 簽名。

## 建議使用流程

### iOS 27+

OTA 安裝 Pikmin Pilot → App 內 on-device RPPairing → START PILOT。

### iOS 17.4–26.x

OTA 安裝 Pikmin Pilot → Windows Pairing Setup USB 一次 → 之後全部 phone-local。
