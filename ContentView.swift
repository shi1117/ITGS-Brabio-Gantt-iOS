import SwiftUI

struct ContentView: View {
    @StateObject private var browser = BrowserModel()
    @AppStorage("projectURL") private var projectURL = AppConfig.defaultProjectURL
    @State private var showSettings = false

    private var startURL: URL {
        URL(string: projectURL) ?? URL(string: AppConfig.defaultProjectURL)!
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            WebView(model: browser, url: startURL)
                .ignoresSafeArea()

            if browser.isLoading {
                ProgressView(value: browser.progress)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: .infinity)
                    .ignoresSafeArea(edges: .top)
            }

            // 滿版模式只保留一顆小型功能鍵，不佔用甘特圖空間。
            Menu {
                Button(action: browser.goBack) {
                    Label("上一頁", systemImage: "chevron.backward")
                }
                .disabled(!browser.canGoBack)

                Button(action: browser.goForward) {
                    Label("下一頁", systemImage: "chevron.forward")
                }
                .disabled(!browser.canGoForward)

                Button(action: browser.reload) {
                    Label("重新整理", systemImage: "arrow.clockwise")
                }

                if let current = browser.currentURL {
                    ShareLink(item: current) {
                        Label("分享目前頁面", systemImage: "square.and.arrow.up")
                    }
                }

                Divider()

                Button {
                    showSettings = true
                } label: {
                    Label("設定", systemImage: "gearshape")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 42, height: 42)
                    .background(.ultraThinMaterial, in: Circle())
                    .shadow(radius: 2, y: 1)
            }
            .padding(.top, 8)
            .padding(.trailing, 8)
        }
        .statusBarHidden(true)
        .alert("網頁載入失敗", isPresented: Binding(
            get: { browser.errorMessage != nil },
            set: { if !$0 { browser.errorMessage = nil } }
        )) {
            Button("重新整理") { browser.reload() }
            Button("關閉", role: .cancel) { browser.errorMessage = nil }
        } message: {
            Text(browser.errorMessage ?? "未知錯誤")
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(projectURL: $projectURL) {
                if let url = URL(string: projectURL) {
                    browser.load(url)
                }
            }
        }
    }
}

private struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var projectURL: String
    let apply: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Brabio 專案網址") {
                    TextField("https://...", text: $projectURL, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    Button("恢復預設專案") {
                        projectURL = AppConfig.defaultProjectURL
                    }
                }
            }
            .navigationTitle("設定")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("套用") {
                        apply()
                        dismiss()
                    }
                }
            }
        }
    }
}
