import SwiftUI

struct ContentView: View {
    @StateObject private var browser = BrowserModel()
    @AppStorage("projectURL") private var projectURL = AppConfig.defaultProjectURL
    @State private var showSettings = false

    private var startURL: URL {
        URL(string: projectURL) ?? URL(string: AppConfig.defaultProjectURL)!
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                WebView(model: browser, url: startURL)
                    .ignoresSafeArea(edges: .bottom)

                if browser.isLoading {
                    ProgressView(value: browser.progress)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Brabio Gantt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button(action: browser.goBack) {
                        Image(systemName: "chevron.backward")
                    }
                    .disabled(!browser.canGoBack)

                    Button(action: browser.goForward) {
                        Image(systemName: "chevron.forward")
                    }
                    .disabled(!browser.canGoForward)

                    Spacer()

                    Button(action: browser.reload) {
                        Image(systemName: "arrow.clockwise")
                    }

                    if let current = browser.currentURL {
                        ShareLink(item: current) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }

                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
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
