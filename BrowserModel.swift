import Foundation
import Combine
import WebKit

@MainActor
final class BrowserModel: ObservableObject {
    @Published var authCheckComplete = false
    @Published var needsLogin = true
    @Published var showOriginalBrowser = false
    @Published var isSubmittingLogin = false
    @Published var loginMessage: String?
    @Published var errorMessage: String?

    @Published var projects: [ProjectItem] = []
    @Published var selectedProject: ProjectItem?
    @Published var tasks: [GanttTask] = []
    @Published var syncState: SyncState = .idle

    weak var webView: WKWebView?

    private struct PendingLogin {
        let account: String
        let password: String
        let remember: Bool
    }

    private var pendingLogin: PendingLogin?
    private var startURL: URL?
    private var lastParsedURL: URL?

    private let fallbackProjects: [ProjectItem] = [
        ProjectItem(name: "Side car-500kW事業", href: nil),
        ProjectItem(name: "Control box(MCU)事業", href: nil),
        ProjectItem(name: "Control box(ADAM研華模組)事業", href: nil),
        ProjectItem(name: "In row Cdu-1.8MW事業", href: nil),
        ProjectItem(name: "2.5MW事業", href: nil),
        ProjectItem(name: "5MW事業", href: nil),
        ProjectItem(name: "金日水塔專案", href: nil),
        ProjectItem(name: "美超微水塔專案", href: nil),
        ProjectItem(name: "Row cooler專案", href: nil),
        ProjectItem(name: "請假", href: nil)
    ]

    func attach(_ webView: WKWebView, startURL: URL) {
        self.webView = webView
        self.startURL = startURL
    }

    func reload() {
        webView?.reload()
    }

    func load(_ url: URL) {
        webView?.load(URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 60))
    }

    func submitLogin(account: String, password: String, remember: Bool, startURL: URL) {
        let trimmed = account.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty, !password.isEmpty else {
            loginMessage = "請輸入帳號與密碼"
            return
        }

        self.startURL = startURL
        loginMessage = nil
        isSubmittingLogin = true
        pendingLogin = PendingLogin(account: trimmed, password: password, remember: remember)

        guard let webView else {
            isSubmittingLogin = false
            loginMessage = "登入元件尚未就緒，請再試一次"
            return
        }

        let hasPasswordJS = "document.querySelector('input[type=\"password\"]') !== null"
        webView.evaluateJavaScript(hasPasswordJS) { [weak self] result, _ in
            Task { @MainActor in
                guard let self else { return }
                if (result as? Bool) == true {
                    self.performPendingLogin()
                } else {
                    self.load(startURL)
                }
            }
        }
    }

    func openOriginalLogin(startURL: URL) {
        self.startURL = startURL
        pendingLogin = nil
        isSubmittingLogin = false
        loginMessage = nil
        showOriginalBrowser = true
        load(startURL)
    }

    func closeOriginalBrowser() {
        showOriginalBrowser = false
    }

    func handlePageFinished(currentURL: URL?) {
        guard let webView else { return }

        let detectionJS = """
        (function() {
            const password = Array.from(document.querySelectorAll('input[type="password"]'))
                .find(el => {
                    const s = window.getComputedStyle(el);
                    const r = el.getBoundingClientRect();
                    return s.display !== 'none' &&
                           s.visibility !== 'hidden' &&
                           r.width > 0 &&
                           r.height > 0;
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

                    if self.pendingLogin != nil {
                        self.performPendingLogin()
                    } else {
                        self.isSubmittingLogin = false
                    }
                    return
                }

                self.needsLogin = false
                self.isSubmittingLogin = false
                self.loginMessage = nil
                self.pendingLogin = nil

                if self.showOriginalBrowser {
                    self.showOriginalBrowser = false
                }

                if currentURL != self.lastParsedURL || self.projects.isEmpty || self.tasks.isEmpty {
                    self.lastParsedURL = currentURL
                    self.refreshNativeData()
                }
            }
        }
    }

    func refreshNativeData() {
        guard webView != nil else { return }

        syncState = .syncing

        extractProjects { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.extractTasks()
            }
        }
    }

    func selectProject(_ project: ProjectItem) {
        selectedProject = project
        tasks = []
        syncState = .syncing

        if let href = project.href,
           let base = webView?.url ?? startURL,
           let target = URL(string: href, relativeTo: base)?.absoluteURL {
            load(target)
            return
        }

        guard let webView else {
            syncState = .failed("找不到 Brabio 頁面")
            return
        }

        let nameLiteral = jsonLiteral(project.name)
        let js = """
        (function() {
            const targetName = \(nameLiteral);

            const nodes = Array.from(document.querySelectorAll('a, button, [onclick], td, span, div'))
                .filter(el => {
                    const r = el.getBoundingClientRect();
                    const s = window.getComputedStyle(el);
                    return r.width > 0 &&
                           r.height > 0 &&
                           s.display !== 'none' &&
                           s.visibility !== 'hidden';
                });

            const exact = nodes.find(el => (el.innerText || el.textContent || '').trim() === targetName);
            const fuzzy = nodes.find(el => (el.innerText || el.textContent || '').trim().indexOf(targetName) >= 0);
            const hit = exact || fuzzy;

            if (!hit) return 'not-found';

            const clickable = hit.closest('a,button,[onclick]') || hit;
            clickable.click();
            return 'clicked';
        })();
        """

        webView.evaluateJavaScript(js) { [weak self] result, _ in
            Task { @MainActor in
                guard let self else { return }

                if (result as? String) != "clicked" {
                    self.syncState = .failed("找不到「\(project.name)」的 Brabio 連結")
                    return
                }

                try? await Task.sleep(nanoseconds: 900_000_000)
                self.refreshNativeData()
            }
        }
    }

    private func extractProjects(completion: @escaping () -> Void) {
        guard let webView else {
            completion()
            return
        }

        let js = """
        (function() {
            const bad = /^(トップページ|チャート|カレンダー|担当状況|全画面|表示設定|Brabio|ログアウト|ヘルプ)$/i;

            const candidates = Array.from(document.querySelectorAll('a, [onclick], td, span'))
                .map(el => {
                    const r = el.getBoundingClientRect();
                    const s = window.getComputedStyle(el);
                    const name = (el.innerText || el.textContent || '').replace(/\\s+/g, ' ').trim();
                    const a = el.closest('a');
                    return {
                        name: name,
                        href: a ? (a.getAttribute('href') || '') : '',
                        x: r.left,
                        y: r.top,
                        w: r.width,
                        h: r.height,
                        visible: r.width > 0 && r.height > 0 && s.display !== 'none' && s.visibility !== 'hidden'
                    };
                })
                .filter(x =>
                    x.visible &&
                    x.x < 460 &&
                    x.y > 100 &&
                    x.name.length >= 2 &&
                    x.name.length <= 60 &&
                    !bad.test(x.name) &&
                    !/^\\d+$/.test(x.name) &&
                    !/^(全員|全ての進捗|タスクを追加する)$/i.test(x.name)
                );

            const preferred = candidates.filter(x =>
                /(事業|專案|项目|プロジェクト|請假|休暇)/i.test(x.name)
            );

            const source = preferred.length >= 2 ? preferred : candidates;

            const seen = new Set();
            const out = [];
            for (const item of source) {
                if (seen.has(item.name)) continue;
                seen.add(item.name);
                out.push({ name: item.name, href: item.href });
            }

            return out.slice(0, 80);
        })();
        """

        webView.evaluateJavaScript(js) { [weak self] result, _ in
            Task { @MainActor in
                guard let self else {
                    completion()
                    return
                }

                var parsed: [ProjectItem] = []

                if let array = result as? [[String: Any]] {
                    for item in array {
                        guard let name = item["name"] as? String else { continue }
                        let href = item["href"] as? String
                        parsed.append(ProjectItem(name: name, href: (href?.isEmpty == false ? href : nil)))
                    }
                }

                if parsed.count >= 2 {
                    self.projects = parsed
                } else if self.projects.isEmpty {
                    self.projects = self.fallbackProjects
                }

                if self.selectedProject == nil {
                    self.selectedProject = self.projects.first
                }

                completion()
            }
        }
    }

    private func extractTasks() {
        guard let webView else {
            syncState = .failed("無法讀取 Brabio")
            return
        }

        let js = """
        (function() {
            function visible(el) {
                const r = el.getBoundingClientRect();
                const s = window.getComputedStyle(el);
                return r.width > 0 &&
                       r.height > 0 &&
                       s.display !== 'none' &&
                       s.visibility !== 'hidden';
            }

            function textOf(el) {
                return (el.innerText || el.textContent || '').replace(/\\s+/g, ' ').trim();
            }

            function parseDateParts(str) {
                const m = str.match(/(20\\d{2})[\\/年\\-](\\d{1,2})[\\/月\\-](\\d{1,2})/);
                if (!m) return null;
                return {
                    y: Number(m[1]),
                    m: Number(m[2]),
                    d: Number(m[3])
                };
            }

            function iso(d) {
                const y = d.getFullYear();
                const m = String(d.getMonth() + 1).padStart(2, '0');
                const day = String(d.getDate()).padStart(2, '0');
                return `${y}-${m}-${day}`;
            }

            const bodyText = document.body ? document.body.innerText : '';

            let overallStart = null;
            let overallEnd = null;

            const ranges = Array.from(bodyText.matchAll(
                /(20\\d{2})[\\/年\\-](\\d{1,2})[\\/月\\-](\\d{1,2})\\s*[～~\\-]\\s*(20\\d{2})[\\/年\\-](\\d{1,2})[\\/月\\-](\\d{1,2})/g
            ));

            if (ranges.length) {
                const r = ranges[ranges.length - 1];
                overallStart = new Date(Number(r[1]), Number(r[2]) - 1, Number(r[3]));
                overallEnd = new Date(Number(r[4]), Number(r[5]) - 1, Number(r[6]));
            }

            if (!overallStart || !overallEnd || overallEnd <= overallStart) {
                const month = bodyText.match(/(20\\d{2})年(\\d{1,2})月/);
                if (month) {
                    overallStart = new Date(Number(month[1]), Number(month[2]) - 1, 1);
                    overallEnd = new Date(Number(month[1]), Number(month[2]) + 2, 0);
                } else {
                    const now = new Date();
                    overallStart = new Date(now.getFullYear(), now.getMonth(), 1);
                    overallEnd = new Date(now.getFullYear(), now.getMonth() + 3, 0);
                }
            }

            const all = Array.from(document.querySelectorAll('*')).filter(visible);

            const scrollContainers = all
                .filter(el => {
                    const r = el.getBoundingClientRect();
                    return el.scrollWidth > el.clientWidth + 250 &&
                           r.width > 250 &&
                           r.height > 120;
                })
                .sort((a, b) => b.scrollWidth - a.scrollWidth);

            const timeline = scrollContainers[0] || document.scrollingElement || document.documentElement;
            const timelineRect = timeline.getBoundingClientRect ? timeline.getBoundingClientRect() : { left: 0, top: 0 };
            const scrollLeft = timeline.scrollLeft || 0;
            const totalWidth = Math.max(timeline.scrollWidth || 1, 1);

            const textCandidates = Array.from(document.querySelectorAll('a,span,td,div'))
                .filter(visible)
                .map(el => {
                    const r = el.getBoundingClientRect();
                    return {
                        el,
                        text: textOf(el),
                        cy: r.top + r.height / 2,
                        x: r.left,
                        w: r.width,
                        h: r.height
                    };
                })
                .filter(x =>
                    x.x < 480 &&
                    x.cy > 120 &&
                    x.text.length >= 2 &&
                    x.text.length <= 90 &&
                    !/^\\d+$/.test(x.text) &&
                    !/(トップページ|チャート|カレンダー|担当状況|全画面|表示設定)/.test(x.text)
                );

            function rgbBrightness(color) {
                const m = color.match(/rgba?\\((\\d+),\\s*(\\d+),\\s*(\\d+)/);
                if (!m) return 255;
                return (Number(m[1]) + Number(m[2]) + Number(m[3])) / 3;
            }

            const bars = all
                .map(el => {
                    const r = el.getBoundingClientRect();
                    const style = window.getComputedStyle(el);
                    return {
                        el,
                        r,
                        bg: style.backgroundColor,
                        brightness: rgbBrightness(style.backgroundColor)
                    };
                })
                .filter(x =>
                    x.r.width >= 24 &&
                    x.r.height >= 7 &&
                    x.r.height <= 32 &&
                    x.r.top > 120 &&
                    x.brightness < 205 &&
                    x.bg !== 'rgba(0, 0, 0, 0)'
                );

            const totalMS = overallEnd.getTime() - overallStart.getTime();
            const dayMS = 86400000;
            const results = [];
            const seenRows = new Set();

            for (const bar of bars) {
                const cy = bar.r.top + bar.r.height / 2;

                let nearest = null;
                let nearestDelta = 9999;

                for (const candidate of textCandidates) {
                    const delta = Math.abs(candidate.cy - cy);
                    if (delta < nearestDelta && delta <= 18) {
                        nearest = candidate;
                        nearestDelta = delta;
                    }
                }

                if (!nearest) continue;

                let name = nearest.text
                    .replace(/^[-+▶▼■□●○\\s]+/, '')
                    .replace(/\\s+/g, ' ')
                    .trim();

                if (name.length < 2) continue;
                if (/(事業|專案|项目|プロジェクト)$/.test(name) && name.length < 50) {
                    continue;
                }

                const rowKey = Math.round(cy / 4);
                const key = `${rowKey}:${name}`;
                if (seenRows.has(key)) continue;
                seenRows.add(key);

                const localX = Math.max(0, bar.r.left - timelineRect.left + scrollLeft);
                const startRatio = Math.max(0, Math.min(1, localX / totalWidth));
                const endRatio = Math.max(startRatio, Math.min(1, (localX + bar.r.width) / totalWidth));

                const startDate = new Date(overallStart.getTime() + totalMS * startRatio);
                const endDate = new Date(overallStart.getTime() + totalMS * endRatio);

                const rowText = (() => {
                    const tr = bar.el.closest('tr');
                    if (tr) return textOf(tr);
                    const parent = bar.el.parentElement;
                    return parent ? textOf(parent) : '';
                })();

                const progressMatch = rowText.match(/(\\d{1,3})\\s*%/);
                const progress = progressMatch ? Math.max(0, Math.min(100, Number(progressMatch[1]))) : 0;

                const emailMatch = rowText.match(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}/i);
                let assignee = emailMatch ? emailMatch[0] : '';

                if (!assignee) {
                    const bits = rowText.split(/\\s+/).filter(Boolean);
                    const possible = bits.filter(t =>
                        t.length >= 2 &&
                        t.length <= 24 &&
                        !/\\d/.test(t) &&
                        !/(完了|進行|開始|終了|日|月|年|100%|0%)/.test(t)
                    );
                    assignee = possible.length ? possible[possible.length - 1] : '未指定';
                }

                results.push({
                    name,
                    start: iso(startDate),
                    end: iso(endDate < startDate ? startDate : endDate),
                    progress,
                    assignee
                });
            }

            if (results.length === 0) {
                const rows = Array.from(document.querySelectorAll('tr')).filter(visible);

                for (const row of rows) {
                    const t = textOf(row);
                    if (t.length < 3 || t.length > 200) continue;

                    const dates = Array.from(t.matchAll(/20\\d{2}[\\/年\\-]\\d{1,2}[\\/月\\-]\\d{1,2}/g))
                        .map(m => parseDateParts(m[0]))
                        .filter(Boolean);

                    if (!dates.length) continue;

                    const first = dates[0];
                    const second = dates[1] || dates[0];

                    const start = new Date(first.y, first.m - 1, first.d);
                    const end = new Date(second.y, second.m - 1, second.d);

                    const cells = Array.from(row.querySelectorAll('td,th'))
                        .map(textOf)
                        .filter(x => x.length >= 2 && x.length <= 80);

                    const name = cells.find(x =>
                        !/^\\d+$/.test(x) &&
                        !/20\\d{2}/.test(x) &&
                        !/%/.test(x)
                    );

                    if (!name) continue;

                    const progressMatch = t.match(/(\\d{1,3})\\s*%/);
                    const emailMatch = t.match(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}/i);

                    results.push({
                        name,
                        start: iso(start),
                        end: iso(end),
                        progress: progressMatch ? Number(progressMatch[1]) : 0,
                        assignee: emailMatch ? emailMatch[0] : '未指定'
                    });
                }
            }

            return results.slice(0, 300);
        })();
        """

        webView.evaluateJavaScript(js) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }

                if let error {
                    self.syncState = .failed("甘特圖讀取失敗：\(error.localizedDescription)")
                    return
                }

                guard let array = result as? [[String: Any]] else {
                    self.syncState = .failed("Brabio 回傳資料格式無法辨識")
                    return
                }

                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyy-MM-dd"
                formatter.timeZone = TimeZone(secondsFromGMT: 0)

                var parsed: [GanttTask] = []

                for (index, item) in array.enumerated() {
                    guard
                        let name = item["name"] as? String,
                        let startString = item["start"] as? String,
                        let endString = item["end"] as? String,
                        let start = formatter.date(from: startString),
                        let endRaw = formatter.date(from: endString)
                    else { continue }

                    let end = max(start, endRaw)
                    let progress = (item["progress"] as? NSNumber)?.intValue ?? 0
                    let assignee = (item["assignee"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let safeAssignee = (assignee?.isEmpty == false) ? assignee! : "未指定"

                    let task = GanttTask(
                        id: "\(index)-\(name)-\(startString)",
                        name: name,
                        start: start,
                        end: end,
                        progress: min(max(progress, 0), 100),
                        assignee: safeAssignee
                    )

                    parsed.append(task)
                }

                let unique = Dictionary(grouping: parsed, by: {
                    "\($0.name)|\(formatter.string(from: $0.start))|\(formatter.string(from: $0.end))"
                }).compactMap { $0.value.first }

                self.tasks = unique.sorted {
                    if $0.start == $1.start { return $0.name < $1.name }
                    return $0.start < $1.start
                }

                self.syncState = .ready
            }
        }
    }

    private func performPendingLogin() {
        guard let login = pendingLogin, let webView else {
            isSubmittingLogin = false
            return
        }

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
                       r.width > 0 &&
                       r.height > 0;
            }

            function setValue(el, value) {
                const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
                setter.call(el, value);
                el.dispatchEvent(new Event('input', { bubbles: true }));
                el.dispatchEvent(new Event('change', { bubbles: true }));
            }

            const inputs = Array.from(document.querySelectorAll('input')).filter(visible);
            const passwordField = inputs.find(el => (el.type || '').toLowerCase() === 'password');
            const accountField =
                inputs.find(el => {
                    const blob = [el.name, el.id, el.placeholder, el.autocomplete, el.type].join(' ').toLowerCase();
                    return el !== passwordField &&
                           ['text', 'email', ''].includes((el.type || '').toLowerCase()) &&
                           /(login|user|mail|email|account|id)/.test(blob);
                }) ||
                inputs.find(el =>
                    el !== passwordField &&
                    ['text', 'email', ''].includes((el.type || '').toLowerCase())
                );

            if (!accountField || !passwordField) return 'fields-not-found';

            setValue(accountField, \(accountJSON));
            setValue(passwordField, \(passwordJSON));

            if (\(rememberJS)) {
                const checkbox = inputs.find(el => (el.type || '').toLowerCase() === 'checkbox');
                if (checkbox && !checkbox.checked) checkbox.click();
            }

            const submitCandidates = Array.from(
                document.querySelectorAll('button, input[type="submit"], input[type="button"], a')
            ).filter(visible);

            const submit = submitCandidates.find(el => {
                const text = [el.innerText, el.value, el.title, el.getAttribute('aria-label')]
                    .join(' ')
                    .toLowerCase();
                return /(ログイン|login|sign in|登入)/.test(text);
            }) || submitCandidates.find(el => (el.type || '').toLowerCase() === 'submit');

            if (submit) {
                submit.click();
                return 'submitted';
            }

            if (passwordField.form) {
                if (passwordField.form.requestSubmit) {
                    passwordField.form.requestSubmit();
                } else {
                    passwordField.form.submit();
                }
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
                    self.loginMessage = "登入失敗：\(error.localizedDescription)"
                    return
                }

                let status = result as? String ?? "unknown"
                if status == "fields-not-found" || status == "submit-not-found" {
                    self.isSubmittingLogin = false
                    self.loginMessage = "Brabio 登入頁面結構不同，請使用原始登入頁"
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
