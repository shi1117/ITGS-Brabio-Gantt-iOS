import Foundation
import WebKit

@MainActor
final class BrowserModel: ObservableObject {
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var progress: Double = 0
    @Published var currentURL: URL?
    @Published var errorMessage: String?

    @Published var authCheckComplete = false
    @Published var needsLogin = true
    @Published var isSubmittingLogin = false
    @Published var loginMessage: String?

    weak var webView: WKWebView?

    private struct PendingLogin {
        let account: String
        let password: String
        let remember: Bool
    }

    private var pendingLogin: PendingLogin?
    private var pendingSocialProvider: String?

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }

    func load(_ url: URL) {
        webView?.load(
            URLRequest(
                url: url,
                cachePolicy: .useProtocolCachePolicy,
                timeoutInterval: 60
            )
        )
    }

    func submitLogin(account: String, password: String, remember: Bool, startURL: URL) {
        let trimmed = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !password.isEmpty else {
            loginMessage = "請輸入帳號與密碼"
            return
        }

        loginMessage = nil
        isSubmittingLogin = true
        pendingSocialProvider = nil
        pendingLogin = PendingLogin(
            account: trimmed,
            password: password,
            remember: remember
        )

        attemptPendingAction(startURL: startURL)
    }

    func startSocialLogin(provider: String, startURL: URL) {
        loginMessage = nil
        isSubmittingLogin = true
        pendingLogin = nil
        pendingSocialProvider = provider
        attemptPendingAction(startURL: startURL)
    }

    func showOriginalLoginPage(startURL: URL) {
        loginMessage = nil
        pendingLogin = nil
        pendingSocialProvider = nil
        isSubmittingLogin = false
        needsLogin = false
        authCheckComplete = true
        load(startURL)
    }

    func handlePageFinished(startURL: URL) {
        guard let webView else { return }

        let detectionJS = """
        (function() {
            const password = Array.from(document.querySelectorAll('input[type="password"]'))
                .find(el => {
                    const s = window.getComputedStyle(el);
                    const r = el.getBoundingClientRect();
                    return s.display !== 'none' && s.visibility !== 'hidden' && r.width > 0 && r.height > 0;
                });

            if (password) return 'login';
            if (location.href.indexOf('/project/') >= 0) return 'project';
            return 'other';
        })();
        """

        webView.evaluateJavaScript(detectionJS) { [weak self] result, _ in
            Task { @MainActor in
                guard let self else { return }
                let state = result as? String ?? "other"

                self.authCheckComplete = true

                if state == "login" {
                    self.needsLogin = true
                    self.performPendingActionIfNeeded()
                } else {
                    self.needsLogin = false
                    self.isSubmittingLogin = false
                    self.loginMessage = nil
                    self.pendingLogin = nil
                    self.pendingSocialProvider = nil
                }
            }
        }
    }

    private func attemptPendingAction(startURL: URL) {
        guard let webView else { return }

        let hasPasswordJS = "document.querySelector('input[type=\"password\"]') !== null"
        webView.evaluateJavaScript(hasPasswordJS) { [weak self] result, _ in
            Task { @MainActor in
                guard let self else { return }
                if (result as? Bool) == true {
                    self.performPendingActionIfNeeded()
                } else {
                    self.load(startURL)
                }
            }
        }
    }

    private func performPendingActionIfNeeded() {
        if let pendingLogin {
            injectLogin(pendingLogin)
        } else if let provider = pendingSocialProvider {
            clickSocialProvider(provider)
        } else {
            isSubmittingLogin = false
        }
    }

    private func injectLogin(_ login: PendingLogin) {
        guard let webView else { return }

        let accountJSON = jsonLiteral(login.account)
        let passwordJSON = jsonLiteral(login.password)
        let rememberJS = login.remember ? "true" : "false"

        let js = """
        (function() {
            function visible(el) {
                if (!el) return false;
                const s = window.getComputedStyle(el);
                const r = el.getBoundingClientRect();
                return s.display !== 'none' &&
                       s.visibility !== 'hidden' &&
                       !el.disabled &&
                       r.width > 0 && r.height > 0;
            }

            function setNativeValue(el, value) {
                const setter = Object.getOwnPropertyDescriptor(
                    window.HTMLInputElement.prototype, 'value'
                ).set;
                setter.call(el, value);
                el.dispatchEvent(new Event('input', { bubbles: true }));
                el.dispatchEvent(new Event('change', { bubbles: true }));
            }

            const inputs = Array.from(document.querySelectorAll('input')).filter(visible);
            const passwordField = inputs.find(el => (el.type || '').toLowerCase() === 'password');

            const accountField =
                inputs.find(el => {
                    const blob = [
                        el.name, el.id, el.placeholder, el.autocomplete, el.type
                    ].join(' ').toLowerCase();
                    return el !== passwordField &&
                           ['text', 'email', ''].includes((el.type || '').toLowerCase()) &&
                           /(login|user|mail|email|account|id)/.test(blob);
                }) ||
                inputs.find(el =>
                    el !== passwordField &&
                    ['text', 'email', ''].includes((el.type || '').toLowerCase())
                );

            if (!accountField || !passwordField) {
                return 'fields-not-found';
            }

            setNativeValue(accountField, \(accountJSON));
            setNativeValue(passwordField, \(passwordJSON));

            if (\(rememberJS)) {
                const checkbox = inputs.find(el =>
                    (el.type || '').toLowerCase() === 'checkbox' &&
                    /(remember|keep|save|login)/.test(
                        [el.name, el.id, el.value].join(' ').toLowerCase()
                    )
                ) || inputs.find(el => (el.type || '').toLowerCase() === 'checkbox');

                if (checkbox && !checkbox.checked) checkbox.click();
            }

            const candidates = Array.from(
                document.querySelectorAll('button, input[type="submit"], input[type="button"], a')
            ).filter(visible);

            const submit = candidates.find(el => {
                const text = [
                    el.innerText, el.value, el.title, el.getAttribute('aria-label')
                ].join(' ').toLowerCase();
                return /(ログイン|login|sign in|登入)/.test(text);
            }) || candidates.find(el =>
                (el.type || '').toLowerCase() === 'submit'
            );

            if (submit) {
                submit.click();
                return 'submitted';
            }

            if (passwordField.form) {
                passwordField.form.requestSubmit
                    ? passwordField.form.requestSubmit()
                    : passwordField.form.submit();
                return 'form-submitted';
            }

            return 'submit-not-found';
        })();
        """

        webView.evaluateJavaScript(js) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }

                if let error {
                    self.isSubmittingLogin = false
                    self.loginMessage = "登入頁面操作失敗：\(error.localizedDescription)"
                    return
                }

                let status = result as? String ?? "unknown"
                if status == "fields-not-found" || status == "submit-not-found" {
                    self.isSubmittingLogin = false
                    self.loginMessage = "Brabio 登入頁面結構已變更，請使用原始登入頁"
                }
            }
        }
    }

    private func clickSocialProvider(_ provider: String) {
        guard let webView else { return }

        let providerJSON = jsonLiteral(provider.lowercased())

        let js = """
        (function() {
            const provider = \(providerJSON);

            function visible(el) {
                if (!el) return false;
                const s = window.getComputedStyle(el);
                const r = el.getBoundingClientRect();
                return s.display !== 'none' &&
                       s.visibility !== 'hidden' &&
                       r.width > 0 && r.height > 0;
            }

            const nodes = Array.from(
                document.querySelectorAll('a, button, input, img')
            ).filter(visible);

            const hit = nodes.find(el => {
                const text = [
                    el.innerText,
                    el.value,
                    el.alt,
                    el.title,
                    el.href,
                    el.src,
                    el.getAttribute('aria-label')
                ].join(' ').toLowerCase();
                return text.indexOf(provider) >= 0;
            });

            if (!hit) return 'provider-not-found';

            const clickable = hit.closest('a,button') || hit;
            clickable.click();
            return 'clicked';
        })();
        """

        webView.evaluateJavaScript(js) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }

                if let error {
                    self.isSubmittingLogin = false
                    self.loginMessage = "無法開啟 \(provider) 登入：\(error.localizedDescription)"
                    return
                }

                if (result as? String) == "provider-not-found" {
                    self.isSubmittingLogin = false
                    self.loginMessage = "找不到 \(provider) 登入按鈕，請使用原始登入頁"
                }
            }
        }
    }

    private func jsonLiteral(_ value: String) -> String {
        guard
            let data = try? JSONEncoder().encode(value),
            let string = String(data: data, encoding: .utf8)
        else {
            return "\"\""
        }
        return string
    }
}
