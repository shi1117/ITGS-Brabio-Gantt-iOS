import SwiftUI

struct ContentView: View {
    @StateObject private var model = BrowserModel()
    @AppStorage("projectURL") private var projectURL = AppConfig.defaultProjectURL

    @State private var path: [ProjectItem] = []

    private var startURL: URL {
        URL(string: projectURL) ?? URL(string: AppConfig.defaultProjectURL)!
    }

    var body: some View {
        ZStack {
            // Brabio stays alive in the background for login/session/data sync.
            // IMPORTANT: keep it screen-sized. The old 1024x768 hidden view enlarged
            // the whole SwiftUI layout and caused the "blank rows / clipped page" issue.
            WebView(model: model, url: startURL, desktopViewport: true)
                .ignoresSafeArea()
                .opacity(model.showOriginalBrowser ? 1.0 : 0.001)
                .allowsHitTesting(model.showOriginalBrowser)

            if model.showOriginalBrowser {
                originalBrowserControls
            } else if !model.authCheckComplete {
                loadingView
            } else if model.needsLogin {
                LoginView(
                    isLoading: model.isSubmittingLogin,
                    message: model.loginMessage,
                    onLogin: { account, password, remember in
                        model.submitLogin(
                            account: account,
                            password: password,
                            remember: remember,
                            startURL: startURL
                        )
                    },
                    onOriginalLogin: {
                        model.openOriginalLogin(startURL: startURL)
                    }
                )
            } else {
                NavigationStack(path: $path) {
                    NativeProjectListView(model: model) { project in
                        path.append(project)
                    }
                    .navigationDestination(for: ProjectItem.self) { _ in
                        ProjectWorkspaceView(model: model)
                    }
                }
                .background(Color(uiColor: .systemBackground))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .environment(\.colorScheme, .light)
        .alert("同步錯誤", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("重新整理") { model.reload() }
            Button("關閉", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "未知錯誤")
        }
    }

    private var originalBrowserControls: some View {
        VStack {
            HStack {
                Spacer()

                Button {
                    model.closeOriginalBrowser()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 42, height: 42)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .padding(.top, 8)
                .padding(.trailing, 8)
            }

            Spacer()
        }
    }

    private var loadingView: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 64, height: 64)

                    Image(systemName: "chart.bar.fill")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)
                }

                Text("Brabio Gantt")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)

                ProgressView()
                    .tint(.black)
            }
        }
    }
}

private struct LoginView: View {
    let isLoading: Bool
    let message: String?
    let onLogin: (String, String, Bool) -> Void
    let onOriginalLogin: () -> Void

    @State private var account = ""
    @State private var password = ""
    @State private var remember = true
    @FocusState private var focused: Field?

    private enum Field {
        case account
        case password
    }

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 22) {
                    Spacer(minLength: 34)

                    ZStack {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 70, height: 70)

                        Image(systemName: "chart.bar.fill")
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(.white)
                    }

                    VStack(spacing: 5) {
                        Text("Brabio Gantt")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundStyle(.black)

                        Text("專案甘特圖管理")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.black)
                    }

                    VStack(spacing: 14) {
                        HStack(spacing: 12) {
                            Image(systemName: "envelope")
                                .foregroundStyle(.black)

                            TextField(
                                "",
                                text: $account,
                                prompt: Text("帳號 / Email").foregroundColor(.black)
                            )
                            .foregroundStyle(.black)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.username)
                            .focused($focused, equals: .account)
                            .submitLabel(.next)
                            .onSubmit { focused = .password }
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 58)
                        .overlay {
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.black.opacity(0.25), lineWidth: 1)
                        }

                        HStack(spacing: 12) {
                            Image(systemName: "lock")
                                .foregroundStyle(.black)

                            SecureField(
                                "",
                                text: $password,
                                prompt: Text("密碼").foregroundColor(.black)
                            )
                            .foregroundStyle(.black)
                            .textContentType(.password)
                            .focused($focused, equals: .password)
                            .submitLabel(.go)
                            .onSubmit {
                                focused = nil
                                onLogin(account, password, remember)
                            }
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 58)
                        .overlay {
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.black.opacity(0.25), lineWidth: 1)
                        }

                        Toggle("記住登入狀態", isOn: $remember)
                            .tint(.black)
                            .foregroundStyle(.black)

                        Button {
                            focused = nil
                            onLogin(account, password, remember)
                        } label: {
                            HStack {
                                if isLoading {
                                    ProgressView()
                                        .tint(.white)
                                }

                                Text(isLoading ? "登入中…" : "登入")
                                    .font(.system(size: 18, weight: .bold))
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .foregroundStyle(.white)
                            .background(Color.black, in: RoundedRectangle(cornerRadius: 16))
                        }
                        .buttonStyle(.plain)
                        .disabled(isLoading)

                        if let message {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                        }

                        Button("使用 Brabio 原始登入頁") {
                            onOriginalLogin()
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.top, 4)
                    }
                    .padding(.horizontal, 24)

                    Spacer(minLength: 140)
                }
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }
}
