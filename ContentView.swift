import SwiftUI

struct ContentView: View {
    @StateObject private var browser = BrowserModel()
    @AppStorage("projectURL") private var projectURL = AppConfig.defaultProjectURL
    @State private var showMenu = false

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
                        browser.startSocialLogin(provider: provider, startURL: startURL)
                    },
                    onOriginalLogin: {
                        browser.showOriginalLoginPage(startURL: startURL)
                    }
                )
                .transition(.opacity)
            } else {
                nativeHeader
            }

            if showMenu && browser.authCheckComplete && !browser.needsLogin {
                drawer
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    .zIndex(20)
            }

            if browser.authCheckComplete && !browser.needsLogin && browser.isLoading {
                VStack(spacing: 0) {
                    ProgressView(value: browser.progress)
                        .progressViewStyle(.linear)
                    Spacer()
                }
                .ignoresSafeArea(edges: .top)
            }
        }
        .animation(.easeInOut(duration: 0.20), value: browser.needsLogin)
        .animation(.easeInOut(duration: 0.20), value: showMenu)
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
    }

    private var nativeHeader: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    showMenu.toggle()
                } label: {
                    HStack(spacing: 8) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Color(red: 1.0, green: 0.47, blue: 0.08))
                            Image(systemName: "chart.bar.fill")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 34, height: 34)

                        Text("Brabio")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(.black)

                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.black)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 44)
                    .background(.white.opacity(0.97), in: RoundedRectangle(cornerRadius: 13))
                    .shadow(color: .black.opacity(0.10), radius: 5, y: 2)
                }
                .buttonStyle(.plain)

                Spacer()

                Text(browser.currentSectionTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.black)
                    .lineLimit(1)

                Spacer()

                Button {
                    browser.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(width: 42, height: 42)
                        .background(.white.opacity(0.97), in: Circle())
                        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)

            Spacer()
        }
        .ignoresSafeArea()
        .allowsHitTesting(true)
        .zIndex(10)
    }

    private var drawer: some View {
        ZStack(alignment: .leading) {
            Color.black.opacity(0.24)
                .ignoresSafeArea()
                .onTapGesture {
                    showMenu = false
                }

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(Color(red: 1.0, green: 0.47, blue: 0.08))
                        Image(systemName: "chart.bar.fill")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 44, height: 44)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Brabio Gantt")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.black)
                        Text("專案目錄")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.black)
                    }

                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.top, 22)
                .padding(.bottom, 20)

                Divider()

                menuButton("甘特圖", icon: "chart.bar.xaxis", section: .gantt)
                menuButton("日程", icon: "calendar", section: .schedule)
                menuButton("負責狀況", icon: "person.2.fill", section: .assignee)
                menuButton("專案首頁", icon: "house.fill", section: .home)

                Spacer()

                Button {
                    browser.reload()
                    showMenu = false
                } label: {
                    Label("重新整理", systemImage: "arrow.clockwise")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .frame(height: 52)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 20)
            }
            .frame(width: min(UIScreen.main.bounds.width * 0.78, 320))
            .background(Color.white)
            .ignoresSafeArea()
            .shadow(color: .black.opacity(0.22), radius: 16, x: 8)
        }
    }

    private func menuButton(_ title: String, icon: String, section: BrowserModel.Section) -> some View {
        Button {
            browser.open(section)
            showMenu = false
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .semibold))
                    .frame(width: 28)
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                if browser.currentSection == section {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                }
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 20)
            .frame(height: 56)
            .background(
                browser.currentSection == section
                    ? Color.black.opacity(0.06)
                    : Color.clear
            )
        }
        .buttonStyle(.plain)
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

    private enum Field { case account, password }
    private let orange = Color(red: 1.0, green: 0.48, blue: 0.10)

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    Spacer(minLength: 26)

                    HStack(spacing: 12) {
                        ZStack {
                            Circle().fill(orange)
                            Image(systemName: "chart.bar.fill")
                                .font(.system(size: 27, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 62, height: 62)

                        HStack(spacing: 6) {
                            Text("Brabio").foregroundStyle(.black)
                            Text("Gantt").foregroundStyle(orange)
                        }
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                    }

                    Text("專案甘特圖管理")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.black)

                    Text("讓專案規劃更簡單，進度掌握更清晰")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.black)

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
                                        .foregroundStyle(remember ? orange : .black)
                                    Text("記住登入狀態")
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(.black)
                                }
                            }
                            .buttonStyle(.plain)

                            Spacer()

                            Button("忘記密碼？") { onOriginalLogin() }
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.black)
                        }

                        Button {
                            focusedField = nil
                            onLogin(account, password, remember)
                        } label: {
                            HStack(spacing: 12) {
                                if isLoading { ProgressView().tint(.white) }
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
                        }
                        .buttonStyle(.plain)
                        .disabled(isLoading)

                        if let message {
                            Text(message)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                        }

                        HStack(spacing: 12) {
                            Rectangle().fill(Color.black.opacity(0.35)).frame(height: 1)
                            Text("或者其他登入方式")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.black)
                                .fixedSize()
                            Rectangle().fill(Color.black.opacity(0.35)).frame(height: 1)
                        }

                        SocialLoginButton(title: "使用 Google 帳號登入", kind: .google) {
                            onSocial("google")
                        }
                        SocialLoginButton(title: "使用 Facebook 帳號登入", kind: .facebook) {
                            onSocial("facebook")
                        }
                        SocialLoginButton(title: "使用 Microsoft 帳號登入", kind: .microsoft) {
                            onSocial("microsoft")
                        }

                        Button("使用 Brabio 原始登入頁") { onOriginalLogin() }
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.black)
                    }
                    .padding(.horizontal, 24)

                    Spacer(minLength: 180)
                }
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .environment(\.colorScheme, .light)
    }

    private var accountField: some View {
        HStack(spacing: 14) {
            Image(systemName: "envelope")
                .foregroundStyle(.black)
                .frame(width: 26)
            TextField("", text: $account, prompt: Text("帳號 / Email").foregroundColor(.black))
                .foregroundStyle(.black)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.emailAddress)
                .textContentType(.username)
                .focused($focusedField, equals: .account)
                .submitLabel(.next)
                .onSubmit { focusedField = .password }
        }
        .padding(.horizontal, 18)
        .frame(height: 58)
        .background(.white, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.black.opacity(0.28), lineWidth: 1))
    }

    private var passwordField: some View {
        HStack(spacing: 14) {
            Image(systemName: "lock")
                .foregroundStyle(.black)
                .frame(width: 26)
            SecureField("", text: $password, prompt: Text("密碼").foregroundColor(.black))
                .foregroundStyle(.black)
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
        .background(.white, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.black.opacity(0.28), lineWidth: 1))
    }
}

private struct SocialLoginButton: View {
    enum Kind { case google, facebook, microsoft }
    let title: String
    let kind: Kind
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                logo.frame(width: 30, height: 30)
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.black)
                Spacer()
            }
            .padding(.horizontal, 18)
            .frame(height: 56)
            .background(.white, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.black.opacity(0.20), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var logo: some View {
        switch kind {
        case .google:
            ZStack { Circle().fill(.white); Text("G").font(.system(size: 23, weight: .bold)).foregroundStyle(.blue) }
        case .facebook:
            ZStack { Circle().fill(.blue); Text("f").font(.system(size: 25, weight: .bold)).foregroundStyle(.white) }
        case .microsoft:
            VStack(spacing: 2) {
                HStack(spacing: 2) { Rectangle().fill(.red); Rectangle().fill(.green) }
                HStack(spacing: 2) { Rectangle().fill(.blue); Rectangle().fill(.yellow) }
            }.frame(width: 25, height: 25)
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
                    Circle().fill(orange)
                    Image(systemName: "chart.bar.fill")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 62, height: 62)

                Text("Brabio Gantt")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)
                ProgressView().tint(orange)
            }
        }
    }
}
