import SwiftUI
import UIKit
import WebKit

struct WebView: UIViewRepresentable {
    @ObservedObject var model: BrowserModel
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, startURL: url)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.allowsInlineMediaPlayback = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.keyboardDismissMode = .interactive
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.refreshControl = UIRefreshControl()
        webView.scrollView.refreshControl?.addTarget(
            context.coordinator,
            action: #selector(Coordinator.refresh(_:)),
            for: .valueChanged
        )

        model.webView = webView
        context.coordinator.observe(webView)

        webView.load(
            URLRequest(
                url: url,
                cachePolicy: .useProtocolCachePolicy,
                timeoutInterval: 60
            )
        )

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        model.webView = webView
        context.coordinator.startURL = url
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let model: BrowserModel
        var startURL: URL
        private var observations: [NSKeyValueObservation] = []

        init(model: BrowserModel, startURL: URL) {
            self.model = model
            self.startURL = startURL
        }

        func observe(_ webView: WKWebView) {
            observations = [
                webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
                    Task { @MainActor in
                        self?.model.progress = webView.estimatedProgress
                    }
                },
                webView.observe(\.canGoBack, options: [.new]) { [weak self] webView, _ in
                    Task { @MainActor in
                        self?.model.canGoBack = webView.canGoBack
                    }
                },
                webView.observe(\.canGoForward, options: [.new]) { [weak self] webView, _ in
                    Task { @MainActor in
                        self?.model.canGoForward = webView.canGoForward
                    }
                },
                webView.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
                    Task { @MainActor in
                        self?.model.isLoading = webView.isLoading
                    }
                },
                webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
                    Task { @MainActor in
                        self?.model.currentURL = webView.url
                    }
                }
            ]
        }

        func stopObserving() {
            observations.removeAll()
        }

        @objc func refresh(_ sender: UIRefreshControl) {
            model.webView?.reload()
            sender.endRefreshing()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.scrollView.refreshControl?.endRefreshing()

            Task { @MainActor in
                model.errorMessage = nil
                model.handlePageFinished(startURL: startURL)
            }
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            webView.scrollView.refreshControl?.endRefreshing()

            Task { @MainActor in
                model.errorMessage = error.localizedDescription
                model.authCheckComplete = true
            }
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            webView.scrollView.refreshControl?.endRefreshing()

            Task { @MainActor in
                model.errorMessage = error.localizedDescription
                model.authCheckComplete = true
            }
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil,
               let targetURL = navigationAction.request.url {
                webView.load(URLRequest(url: targetURL))
            }
            return nil
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }

            if ["http", "https", "about"].contains(url.scheme?.lowercased() ?? "") {
                decisionHandler(.allow)
            } else {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
            }
        }
    }
}
