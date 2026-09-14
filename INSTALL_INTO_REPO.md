# 加到現有 Pikmin Pilot repo

這包不需要覆蓋 App 原始碼。只把以下資料夾複製進你目前 repo 根目錄：

- `.github/workflows/build-pikmin-pilot-pairing-helper.yml`
- `.github/workflows/package-ota-from-url.yml`
- `WindowsPairingSetup/`
- `OTA/`

不要刪除你目前 Stage 11.5.3 / 11.6.x 的 App 檔案。

## Windows Pairing Helper

GitHub → Actions → `Build Pikmin Pilot Pairing Helper for Windows` → Run workflow。

## OTA

最直接：在 Windows 執行 `OTA/MAKE_OTA_PACKAGE.cmd`。

或使用 Actions 的 `Package Pikmin Pilot OTA Site`，輸入：

- `ipa_url`: 可直接下載已簽 IPA 的 HTTPS URL
- `public_base_url`: 最後你要放 `ota-site/` 的公開 HTTPS 目錄
