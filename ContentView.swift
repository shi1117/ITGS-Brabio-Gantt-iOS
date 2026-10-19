import SwiftUI

struct ContentView: View {
    @StateObject private var browser = BrowserModel()
    @AppStorage("projectURL") private var projectURL = AppConfig.defaultProjectURL
    @State private var showSettings = false

    private var startURL: URL {
        URL(string: projectURL) ?? URL(string: AppConfig.defaultProjectURL)!
    }

    var body: some View {
        ZStack {
            WebView(model: browser, url: startURL)
                .ignoresSafeArea()

            if !browser.authCheckComplete {
                LaunchLoadingView()
                    .transition(.opacity)
            } else if browser.needsLogin {
                LoginView(
                    isLoading: browser.isSubmittingLogin,
                    message: browser.loginMessage,
                    onLogin: { account, password, remember in
                        browser.submitLogin(
                            account: account,
                            password: password,
                            remember: remember,
                            startURL: startURL
                        )
                    },
                    onSocial: { provider in
                        browser.startSocialLogin(
                            provider: provider,
                            startURL: startURL
                        )
                    },
                    onOriginalLogin: {
                        browser.showOriginalLoginPage(startURL: startURL)
                    }
                )
                .transition(.opacity)
            } else {
                browserMenu
            }

            if browser.authCheckComplete && !browser.needsLogin && browser.isLoading {
                VStack {
                    ProgressView(value: browser.progress)
                        .progressViewStyle(.linear)
                    Spacer()
                }
                .ignoresSafeArea(edges: .top)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: browser.needsLogin)
        .statusBarHidden(browser.authCheckComplete && !browser.needsLogin)
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

    private var browserMenu: some View {
        VStack {
            HStack {
                Spacer()

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

            Spacer()
        }
        .ignoresSafeArea()
    }
}

private struct LoginView: View {
    let isLoading: Bool
    let message: String?
    let onLogin: (String, String, Bool) -> Void
    let onSocial: (String) -> Void
    let onOriginalLogin: () -> Void

    @State private var account = ""
    @State private var password = ""
    @State private var remember = true
    @FocusState private var focusedField: Field?

    private enum Field {
        case account
        case password
    }

    private let orange = Color(red: 1.0, green: 0.48, blue: 0.10)

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.white,
                    Color(red: 1.0, green: 0.985, blue: 0.965),
                    Color.white
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(orange.opacity(0.09))
                .frame(width: 330, height: 330)
                .blur(radius: 2)
                .offset(x: -180, y: -390)

            GanttDecoration()
                .opacity(0.34)
                .allowsHitTesting(false)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    header
                        .padding(.top, 34)

                    VStack(spacing: 16) {
                        accountField
                        passwordField

                        HStack {
                            Button {
                                remember.toggle()
                            } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: remember ? "checkmark.square.fill" : "square")
                                        .font(.system(size: 22, weight: .semibold))
                                        .foregroundStyle(remember ? orange : Color.secondary)

                                    Text("記住登入狀態")
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(.primary)
                                }
                            }
                            .buttonStyle(.plain)

                            Spacer()

                            Button("忘記密碼？") {
                                onOriginalLogin()
                            }
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(orange)
                        }

                        Button {
                            focusedField = nil
                            onLogin(account, password, remember)
                        } label: {
                            HStack(spacing: 12) {
                                if isLoading {
                                    ProgressView()
                                        .tint(.white)
                                }

                                Text(isLoading ? "登入中…" : "登入")
                                    .font(.system(size: 20, weight: .semibold))

                                if !isLoading {
                                    Image(systemName: "arrow.right")
                                        .font(.system(size: 18, weight: .semibold))
                                }
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 58)
                            .background(
                                LinearGradient(
                                    colors: [orange, Color(red: 1.0, green: 0.59, blue: 0.20)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                ),
                                in: RoundedRectangle(cornerRadius: 17, style: .continuous)
                            )
                            .shadow(color: orange.opacity(0.25), radius: 12, y: 7)
                        }
                        .buttonStyle(.plain)
                        .disabled(isLoading)

                        if let message {
                            Text(message)
                                .font(.system(size: 13))
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                        }

                        divider

                        SocialLoginButton(
                            title: "使用 Google 帳號登入",
                            kind: .google
                        ) {
                            onSocial("google")
                        }
                        .disabled(isLoading)

                        SocialLoginButton(
                            title: "使用 Facebook 帳號登入",
                            kind: .facebook
                        ) {
                            onSocial("facebook")
                        }
                        .disabled(isLoading)

                        SocialLoginButton(
                            title: "使用 Microsoft 帳號登入",
                            kind: .microsoft
                        ) {
                            onSocial("microsoft")
                        }
                        .disabled(isLoading)

                        Button("使用 Brabio 原始登入頁") {
                            onOriginalLogin()
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 30)

                    Spacer(minLength: 210)
                }
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(orange)

                    Image(systemName: "chart.bar.fill")
                        .font(.system(size: 25, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 58, height: 58)
                .shadow(color: orange.opacity(0.2), radius: 10, y: 5)

                HStack(spacing: 5) {
                    Text("Brabio")
                        .foregroundStyle(Color(red: 0.06, green: 0.08, blue: 0.14))

                    Text("Gantt")
                        .foregroundStyle(orange)
                }
                .font(.system(size: 36, weight: .bold, design: .rounded))
            }

            Text("專案甘特圖管理")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)

            Text("讓專案規劃更簡單，進度掌握更清晰")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
    }

    private var accountField: some View {
        HStack(spacing: 14) {
            Image(systemName: "envelope")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26)

            TextField("帳號 / Email", text: $account)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.emailAddress)
                .textContentType(.username)
                .focused($focusedField, equals: .account)
                .submitLabel(.next)
                .onSubmit {
                    focusedField = .password
                }
        }
        .padding(.horizontal, 18)
        .frame(height: 58)
        .background(.white.opacity(0.95), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 10, y: 5)
    }

    private var passwordField: some View {
        HStack(spacing: 14) {
            Image(systemName: "lock")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26)

            SecureField("密碼", text: $password)
                .textContentType(.password)
                .focused($focusedField, equals: .password)
                .submitLabel(.go)
                .onSubmit {
                    focusedField = nil
                    onLogin(account, password, remember)
                }
        }
        .padding(.horizontal, 18)
        .frame(height: 58)
        .background(.white.opacity(0.95), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 10, y: 5)
    }

    private var divider: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(Color.secondary.opacity(0.28))
                .frame(height: 1)

            Text("或者其他登入方式")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize()

            Rectangle()
                .fill(Color.secondary.opacity(0.28))
                .frame(height: 1)
        }
        .padding(.vertical, 4)
    }
}

private struct SocialLoginButton: View {
    enum Kind {
        case google
        case facebook
        case microsoft
    }

    let title: String
    let kind: Kind
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                logo
                    .frame(width: 30, height: 30)

                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer()
            }
            .padding(.horizontal, 18)
            .frame(height: 56)
            .background(.white.opacity(0.96), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.black.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.04), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var logo: some View {
        switch kind {
        case .google:
            ZStack {
                Circle()
                    .fill(Color.white)

                Text("G")
                    .font(.system(size: 23, weight: .bold))
                    .foregroundStyle(Color(red: 0.15, green: 0.42, blue: 0.95))
            }

        case .facebook:
            ZStack {
                Circle()
                    .fill(Color(red: 0.10, green: 0.39, blue: 0.92))

                Text("f")
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .offset(y: 2)
            }

        case .microsoft:
            VStack(spacing: 2) {
                HStack(spacing: 2) {
                    Rectangle().fill(Color(red: 0.95, green: 0.25, blue: 0.13))
                    Rectangle().fill(Color(red: 0.48, green: 0.72, blue: 0.11))
                }
                HStack(spacing: 2) {
                    Rectangle().fill(Color(red: 0.0, green: 0.64, blue: 0.91))
                    Rectangle().fill(Color(red: 1.0, green: 0.72, blue: 0.0))
                }
            }
            .frame(width: 25, height: 25)
        }
    }
}

private struct GanttDecoration: View {
    private let orange = Color(red: 1.0, green: 0.48, blue: 0.10)

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width

            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(.white.opacity(0.72))
                    .frame(width: min(w * 0.86, 540), height: 230)
                    .overlay {
                        VStack(spacing: 15) {
                            HStack {
                                ForEach(["4月", "5月", "6月", "7月"], id: \.self) { month in
                                    Text(month)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity)
                                }
                            }

                            ganttRow(start: 0.08, width: 0.24, color: orange)
                            ganttRow(start: 0.28, width: 0.20, color: orange.opacity(0.62))
                            ganttRow(start: 0.44, width: 0.31, color: orange)
                            ganttRow(start: 0.62, width: 0.22, color: Color.gray.opacity(0.55))
                            ganttRow(start: 0.72, width: 0.20, color: orange.opacity(0.75))
                        }
                        .padding(.horizontal, 28)
                        .padding(.vertical, 24)
                    }
                    .rotationEffect(.degrees(-5))
                    .offset(x: w * 0.09, y: proxy.size.height * 0.34)

                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.white.opacity(0.83))
                    .frame(width: min(w * 0.42, 240), height: 145)
                    .overlay {
                        VStack(alignment: .leading, spacing: 14) {
                            checklistRow(color: orange)
                            checklistRow(color: .gray)
                            checklistRow(color: orange.opacity(0.6))
                        }
                        .padding(20)
                    }
                    .rotationEffect(.degrees(6))
                    .offset(x: -w * 0.25, y: proxy.size.height * 0.40)
            }
        }
        .ignoresSafeArea()
    }

    private func ganttRow(start: CGFloat, width: CGFloat, color: Color) -> some View {
        GeometryReader { proxy in
            RoundedRectangle(cornerRadius: 6)
                .fill(color)
                .frame(width: proxy.size.width * width, height: 14)
                .offset(x: proxy.size.width * start)
        }
        .frame(height: 14)
    }

    private func checklistRow(color: Color) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 5)
                .fill(color)
                .frame(width: 22, height: 22)
                .overlay {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                }

            RoundedRectangle(cornerRadius: 4)
                .fill(Color.gray.opacity(0.18))
                .frame(height: 10)
        }
    }
}

private struct LaunchLoadingView: View {
    private let orange = Color(red: 1.0, green: 0.48, blue: 0.10)

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(orange)

                    Image(systemName: "chart.bar.fill")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 62, height: 62)

                Text("Brabio Gantt")
                    .font(.system(size: 28, weight: .bold, design: .rounded))

                ProgressView()
                    .tint(orange)
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
