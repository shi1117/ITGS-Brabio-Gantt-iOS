# ITGS Brabio Gantt v0.4.0 - Login UI

這一版把未登入畫面改成原生 SwiftUI 登入頁，版面依照最新設計稿：

- 上方：Brabio Gantt / 專案甘特圖管理
- 帳號 / Email
- 密碼
- 記住登入狀態
- 登入按鈕
- 「或者其他登入方式」
- Google / Facebook / Microsoft
- 下方淡化甘特圖視覺
- 已登入後維持 v0.3 的滿版 WebView

功能上採 Hybrid 方式：
1. App 背景先載入 Brabio。
2. 若偵測到 Brabio 登入頁，顯示原生登入 UI。
3. 按「登入」時，自動把帳密填入 Brabio 頁面並提交。
4. Google / Facebook / Microsoft 會嘗試點擊 Brabio 原有第三方登入按鈕。
5. 若 Brabio 日後改版導致自動登入失效，可按「使用 Brabio 原始登入頁」。

請覆蓋 GitHub repo 根目錄的：
- BrowserModel.swift
- ContentView.swift
- WebView.swift
- Info.plist

project.yml 不需要修改。
