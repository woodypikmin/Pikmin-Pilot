# Pikmin Pilot OTA Packager

用途：把**已簽名**的 Pikmin Pilot IPA 變成 Safari 可點擊安裝的靜態網站。

## Windows 最簡單

1. 電腦要有 Python 3。
2. 雙擊 `MAKE_OTA_PACKAGE.cmd`。
3. 輸入已簽好的 IPA 路徑。
4. 輸入你準備放檔案的公開 HTTPS 目錄，例如：
   `https://your-domain.example/pikminpilot/`
5. 產生 `ota-site/`。
6. 把 `ota-site/` 內所有檔案原樣上傳到該 HTTPS 目錄。
7. 使用者 Safari 開 `https://your-domain.example/pikminpilot/`，按「安裝 Pikmin Pilot」。

產物：

- `index.html`
- `manifest.plist`
- `PikminPilot.ipa`
- `ota-metadata.json`

## 必要條件

- 必須是 HTTPS。
- IPA 必須已正確簽名。
- 如果用 Development / Ad Hoc，目標 iPhone/iPad 的 UDID 必須已包含在 provisioning profile。
- 這種 IPA 安裝後仍可能需要 Developer Mode。

## GitHub Pages

可以把 `ota-site/` 作為 GitHub Pages 的靜態內容；但若 repo/page 是公開的，IPA 也等同公開可下載。不要把含私人 pairing record 的 IPA 放到公開 Pages。
