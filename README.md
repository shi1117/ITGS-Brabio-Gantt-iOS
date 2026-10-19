## v0.3 Fullscreen

- 移除上方 `Brabio Gantt` 標題列
- 移除下方大型瀏覽器工具列
- WKWebView 改為全螢幕 edge-to-edge
- 隱藏狀態列，甘特圖可使用整個畫面
- 保留右上角小型 `…` 選單：上一頁 / 下一頁 / 重新整理 / 分享 / 設定
- 保留左右滑返回、下拉重新整理

# ITGS Brabio Gantt for iOS

iPhone/iPad 包裝版 Brabio 甘特圖 App。

預設專案：
https://brabioproject.jp/project/ganttchart/ahJzfmJyYWJpb3Byb2plY3RocmRyEQsSB1Byb2plY3QY1vTWm0UM/

## 功能
- WKWebView 載入 Brabio 甘特圖
- Cookie / 網站資料使用 WKWebsiteDataStore.default()，登入狀態可保留
- 返回 / 前進 / 重新整理
- 下拉重新整理
- 進度條
- Share Sheet 分享目前網址
- 網站 popup / target=_blank 會在同一個 WebView 開啟
- 非 http/https URL 交由 iOS 系統 App 處理
- 直向與橫向皆可使用，甘特圖建議橫向
- App 內可修改 Brabio 專案網址

## 產生 Xcode 專案
需要 macOS：

1. `brew install xcodegen`
2. 在專案根目錄執行 `xcodegen generate`
3. 開啟 `ITGSBrabioGantt.xcodeproj`

## GitHub Actions
`.github/workflows/build-simulator.yml` 可以在沒有 Apple 憑證的情況下驗證是否能成功編譯。

`.github/workflows/build-ipa.yml` 可產出可安裝 IPA，但需要 Apple Developer 簽章資料。

需要的 GitHub Secrets：
- `IOS_CERT_P12_BASE64`
- `IOS_CERT_PASSWORD`
- `IOS_PROVISION_PROFILE_BASE64`
- `IOS_TEAM_ID`
- `IOS_PROFILE_NAME`
- `KEYCHAIN_PASSWORD`

## Bundle ID
預設：`com.itgs.brabiogantt`

若 Apple Developer 後台已使用其他 Bundle ID，請同步修改 `project.yml`。
