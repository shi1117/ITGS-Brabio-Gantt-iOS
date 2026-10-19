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
    @Published var diagnosticText: String = ""

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
        webView?.load(
            URLRequest(
                url: url,
                cachePolicy: .reloadRevalidatingCacheData,
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

        self.startURL = startURL
        loginMessage = nil
        isSubmittingLogin = true
        pendingLogin = PendingLogin(
            account: trimmed,
            password: password,
            remember: remember
        )

        guard let webView else {
            isSubmittingLogin = false
            loginMessage = "登入元件尚未就緒，請再試一次"
            return
        }

        let js = """
        (function() {
            function docs(root) {
                const out = [root];
                const frames = Array.from(root.querySelectorAll('iframe,frame'));
                for (const frame of frames) {
                    try {
                        if (frame.contentDocument) {
                            out.push(...docs(frame.contentDocument));
                        }
                    } catch (_) {}
                }
                return out;
            }

            return docs(document).some(d => d.querySelector('input[type="password"]') !== null);
        })();
        """

        webView.evaluateJavaScript(js) { [weak self] result, _ in
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
            function docs(root) {
                const out = [root];
                const frames = Array.from(root.querySelectorAll('iframe,frame'));
                for (const frame of frames) {
                    try {
                        if (frame.contentDocument) {
                            out.push(...docs(frame.contentDocument));
                        }
                    } catch (_) {}
                }
                return out;
            }

            const allDocs = docs(document);

            for (const d of allDocs) {
                const password = Array.from(d.querySelectorAll('input[type="password"]'))
                    .find(el => {
                        const w = d.defaultView || window;
                        const s = w.getComputedStyle(el);
                        const r = el.getBoundingClientRect();
                        return s.display !== 'none' &&
                               s.visibility !== 'hidden' &&
                               r.width > 0 &&
                               r.height > 0;
                    });

                if (password) return 'login';
            }

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

                    // Brabio's chart is partly rendered after didFinish.
                    // Give its old JS/AJAX UI a moment before reading the DOM.
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    self.refreshNativeData()
                }
            }
        }
    }

    func refreshNativeData() {
        guard webView != nil else { return }

        syncState = .syncing
        diagnosticText = ""

        extractProjects { [weak self] in
            Task { @MainActor in
                guard let self else { return }

                if let project = self.selectedProject {
                    self.prepareSelectedProject(project, attempt: 0)
                } else {
                    self.extractTasks(attempt: 0)
                }
            }
        }
    }

    func selectProject(_ project: ProjectItem) {
        selectedProject = project
        tasks = []
        syncState = .syncing
        diagnosticText = ""

        if let href = project.href,
           let base = webView?.url ?? startURL,
           let target = URL(string: href, relativeTo: base)?.absoluteURL {
            load(target)
            return
        }

        prepareSelectedProject(project, attempt: 0)
    }

    private func prepareSelectedProject(_ project: ProjectItem, attempt: Int) {
        guard let webView else {
            syncState = .failed("找不到 Brabio 頁面")
            return
        }

        let nameLiteral = jsonLiteral(project.name)

        let js = """
        (function() {
            const targetName = \(nameLiteral);

            function collectDocs(root, offsetX = 0, offsetY = 0) {
                const out = [{ doc: root, offsetX, offsetY }];

                for (const frame of Array.from(root.querySelectorAll('iframe,frame'))) {
                    try {
                        if (!frame.contentDocument) continue;

                        const r = frame.getBoundingClientRect();

                        out.push(
                            ...collectDocs(
                                frame.contentDocument,
                                offsetX + r.left,
                                offsetY + r.top
                            )
                        );
                    } catch (_) {}
                }

                return out;
            }

            function rect(entry, el) {
                const r = el.getBoundingClientRect();

                return {
                    left: r.left + entry.offsetX,
                    right: r.right + entry.offsetX,
                    top: r.top + entry.offsetY,
                    bottom: r.bottom + entry.offsetY,
                    width: r.width,
                    height: r.height,
                    cx: r.left + entry.offsetX + r.width / 2,
                    cy: r.top + entry.offsetY + r.height / 2
                };
            }

            function visible(entry, el) {
                if (!el) return false;

                const w = entry.doc.defaultView || window;
                const s = w.getComputedStyle(el);
                const r = el.getBoundingClientRect();

                return r.width > 0 &&
                       r.height > 0 &&
                       s.display !== 'none' &&
                       s.visibility !== 'hidden';
            }

            function text(el) {
                return (el.innerText || el.textContent || '')
                    .replace(/\\s+/g, ' ')
                    .trim();
            }

            const entries = collectDocs(document);
            let marker = null;

            for (const entry of entries) {
                for (const el of Array.from(
                    entry.doc.querySelectorAll('a,span,td,div')
                )) {
                    if (!visible(entry, el)) continue;
                    if (text(el) !== targetName) continue;

                    const r = rect(entry, el);
                    const area = r.width * r.height;

                    if (
                        marker === null ||
                        r.left < marker.r.left - 8 ||
                        (
                            Math.abs(r.left - marker.r.left) <= 8 &&
                            area < marker.area
                        )
                    ) {
                        marker = { entry, el, r, area };
                    }
                }
            }

            if (!marker) {
                return {
                    status: 'project-not-found',
                    expanded: false
                };
            }

            const entry = marker.entry;
            const projectX = marker.r.left;
            const projectY = marker.r.cy;

            // Determine whether task rows are already visible directly below this project.
            let hasChildren = false;

            for (const el of Array.from(
                entry.doc.querySelectorAll('a,span,td,div')
            )) {
                if (!visible(entry, el)) continue;

                const r = rect(entry, el);
                const t = text(el);

                if (r.cy <= projectY + 4 || r.cy > projectY + 900) continue;
                if (r.left < projectX + 10 || r.left > projectX + 430) continue;
                if (r.height < 8 || r.height > 48) continue;
                if (!t || t.length < 2 || t.length > 100) continue;

                hasChildren = true;
                break;
            }

            let clickedExpand = false;

            if (!hasChildren) {
                const controls = [];

                for (const el of Array.from(
                    entry.doc.querySelectorAll('img,a,button,input,span,div')
                )) {
                    if (!visible(entry, el)) continue;

                    const r = rect(entry, el);

                    if (Math.abs(r.cy - projectY) > 16) continue;
                    if (r.right > projectX + 10) continue;
                    if (r.left < projectX - 120) continue;
                    if (r.width < 6 || r.width > 42) continue;
                    if (r.height < 6 || r.height > 42) continue;

                    const blob = [
                        text(el),
                        el.id || '',
                        typeof el.className === 'string' ? el.className : '',
                        el.getAttribute('title') || '',
                        el.getAttribute('alt') || '',
                        el.getAttribute('src') || '',
                        el.getAttribute('name') || ''
                    ].join(' ').toLowerCase();

                    let score = 0;

                    if (/(plus|expand|closed|tree.*plus)/i.test(blob)) {
                        score += 150;
                    }

                    if (/(minus|collapse|opened|tree.*minus)/i.test(blob)) {
                        score -= 150;
                    }

                    if (el.tagName === 'IMG') score += 20;
                    if (el.closest('a,button,[onclick]')) score += 15;

                    score -= Math.abs(projectX - r.right) * 0.2;

                    controls.push({ el, score });
                }

                controls.sort((a, b) => b.score - a.score);

                const control = controls.find(x => x.score > 10);

                if (control) {
                    const clickable =
                        control.el.closest('a,button,[onclick]') ||
                        control.el;

                    try {
                        clickable.click();
                        clickedExpand = true;
                    } catch (_) {}
                }
            }

            // Select/activate the exact project row, but never collapse other projects.
            const directLink =
                marker.el.closest('a,button,[onclick]') ||
                marker.el.querySelector?.('a,button,[onclick]');

            if (directLink) {
                try {
                    directLink.click();
                } catch (_) {}
            }

            return {
                status: 'selected',
                expanded: hasChildren || clickedExpand
            };
        })();
        """

        webView.evaluateJavaScript(js) { [weak self] result, _ in
            Task { @MainActor in
                guard let self else { return }

                let object = result as? [String: Any]
                let status = object?["status"] as? String ?? "unknown"

                if status == "project-not-found" {
                    self.syncState = .failed("找不到「\(project.name)」的 Brabio 專案列")
                    return
                }

                try? await Task.sleep(
                    nanoseconds: UInt64(
                        850_000_000 + min(attempt, 3) * 250_000_000
                    )
                )

                self.extractTasks(attempt: 0)
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
            function docs(root) {
                const out = [root];
                const frames = Array.from(root.querySelectorAll('iframe,frame'));

                for (const frame of frames) {
                    try {
                        if (frame.contentDocument) {
                            out.push(...docs(frame.contentDocument));
                        }
                    } catch (_) {}
                }

                return out;
            }

            const bad = /^(トップページ|チャート|カレンダー|担当状況|全画面|表示設定|Brabio|ログアウト|ヘルプ)$/i;
            const candidates = [];

            for (const d of docs(document)) {
                const w = d.defaultView || window;

                for (const el of Array.from(d.querySelectorAll('a,[onclick],td,span'))) {
                    const r = el.getBoundingClientRect();
                    const s = w.getComputedStyle(el);
                    const name = (el.innerText || el.textContent || '')
                        .replace(/\\s+/g, ' ')
                        .trim();

                    const a = el.closest('a');

                    const visible =
                        r.width > 0 &&
                        r.height > 0 &&
                        s.display !== 'none' &&
                        s.visibility !== 'hidden';

                    if (!visible) continue;
                    if (name.length < 2 || name.length > 70) continue;
                    if (bad.test(name)) continue;
                    if (/^\\d+$/.test(name)) continue;
                    if (/^(全員|全ての進捗|タスクを追加する)$/i.test(name)) continue;

                    candidates.push({
                        name,
                        href: a ? (a.getAttribute('href') || '') : ''
                    });
                }
            }

            const preferred = candidates.filter(x =>
                /(事業|專案|项目|プロジェクト|請假|休暇)/i.test(x.name)
            );

            const source = preferred.length >= 2 ? preferred : candidates;

            const seen = new Set();
            const out = [];

            for (const item of source) {
                if (seen.has(item.name)) continue;
                seen.add(item.name);
                out.push(item);
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
                        parsed.append(
                            ProjectItem(
                                name: name,
                                href: (href?.isEmpty == false ? href : nil)
                            )
                        )
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

    private func extractTasks(attempt: Int) {
        guard let webView else {
            syncState = .failed("無法讀取 Brabio")
            return
        }

        let projectNameJSON = jsonLiteral(selectedProject?.name ?? "")
        let allProjectNamesJSON = jsonArrayLiteral(projects.map(\.name))

        let js = """
        (function() {
            const selectedProjectName = \(projectNameJSON);
            const knownProjectNames = new Set(\(allProjectNamesJSON));

            function collectDocs(root, offsetX = 0, offsetY = 0) {
                const result = [{ doc: root, offsetX, offsetY }];

                for (const frame of Array.from(root.querySelectorAll('iframe,frame'))) {
                    try {
                        if (!frame.contentDocument) continue;

                        const r = frame.getBoundingClientRect();

                        result.push(
                            ...collectDocs(
                                frame.contentDocument,
                                offsetX + r.left,
                                offsetY + r.top
                            )
                        );
                    } catch (_) {}
                }

                return result;
            }

            const entries = collectDocs(document);

            function winFor(entry) {
                return entry.doc.defaultView || window;
            }

            function rectFor(entry, el) {
                const r = el.getBoundingClientRect();

                return {
                    left: r.left + entry.offsetX,
                    right: r.right + entry.offsetX,
                    top: r.top + entry.offsetY,
                    bottom: r.bottom + entry.offsetY,
                    width: r.width,
                    height: r.height,
                    cx: r.left + entry.offsetX + r.width / 2,
                    cy: r.top + entry.offsetY + r.height / 2
                };
            }

            function visible(entry, el) {
                if (!el) return false;

                const s = winFor(entry).getComputedStyle(el);
                const r = el.getBoundingClientRect();

                return r.width > 0 &&
                       r.height > 0 &&
                       s.display !== 'none' &&
                       s.visibility !== 'hidden' &&
                       Number(s.opacity || 1) > 0.01;
            }

            function textOf(el) {
                return (el.innerText || el.textContent || '')
                    .replace(/\\s+/g, ' ')
                    .trim();
            }

            function cleanName(value) {
                return String(value || '')
                    .replace(/^[-+▶▼■□●○▸▾●◉✓✔→↪📁📂\\s]+/, '')
                    .replace(/\\s+/g, ' ')
                    .trim();
            }

            function iso(date) {
                const y = date.getFullYear();
                const m = String(date.getMonth() + 1).padStart(2, '0');
                const d = String(date.getDate()).padStart(2, '0');
                return `${y}-${m}-${d}`;
            }

            function rgb(color) {
                const m = String(color || '')
                    .match(/rgba?\\((\\d+),\\s*(\\d+),\\s*(\\d+)/);

                if (!m) return null;

                return {
                    r: Number(m[1]),
                    g: Number(m[2]),
                    b: Number(m[3])
                };
            }

            function brightness(color) {
                const c = rgb(color);
                if (!c) return 255;
                return (c.r + c.g + c.b) / 3;
            }

            function saturation(color) {
                const c = rgb(color);
                if (!c) return 0;
                return Math.max(c.r, c.g, c.b) - Math.min(c.r, c.g, c.b);
            }

            function isMetadata(value) {
                const text = cleanName(value);

                if (!text) return true;
                if (/^\\d+\\s*営業日$/i.test(text)) return true;
                if (/^\\d{1,2}\\/\\d{1,2}\\s*\\([^)]+\\)$/i.test(text)) return true;
                if (/^\\d{1,2}月\\d{1,2}日(?:\\s*\\([^)]+\\))?$/i.test(text)) return true;
                if (/^\\d{1,3}\\s*%$/i.test(text)) return true;
                if (/^(登録|更新|期間|進捗|最終更新|メンバー|あしあと|内容|添付ファイル)$/i.test(text)) return true;
                if (/ログインユーザー|メンバー未設定/.test(text)) return true;
                if (/@/.test(text)) return true;

                return false;
            }

            function isBadTaskName(value) {
                const text = cleanName(value);

                if (text.length < 2 || text.length > 100) return true;
                if (knownProjectNames.has(text)) return true;
                if (isMetadata(text)) return true;
                if (/^(ITG|Brabio)$/i.test(text)) return true;
                if (/ブラビオへようこそ|トップページ/.test(text)) return true;
                if (/^(チャート|カレンダー|担当状況|全画面|表示設定)$/i.test(text)) return true;
                if (/^(全員|全ての進捗|タスクを追加する)$/i.test(text)) return true;
                if (/^[0-9]+$/.test(text)) return true;

                return false;
            }

            // ------------------------------------------------------------
            // A. Find the selected project in the LEFT tree.
            // ------------------------------------------------------------
            let projectMarker = null;

            for (const entry of entries) {
                for (const el of Array.from(
                    entry.doc.querySelectorAll('a,span,td,div')
                )) {
                    if (!visible(entry, el)) continue;

                    const name = cleanName(textOf(el));

                    if (name !== selectedProjectName) continue;

                    const r = rectFor(entry, el);
                    const area = r.width * r.height;

                    if (
                        projectMarker === null ||
                        r.left < projectMarker.r.left - 8 ||
                        (
                            Math.abs(r.left - projectMarker.r.left) <= 8 &&
                            area < projectMarker.area
                        )
                    ) {
                        projectMarker = {
                            entry,
                            el,
                            r,
                            area
                        };
                    }
                }
            }

            if (!projectMarker) {
                return {
                    tasks: [],
                    debug: 'tree:none treeRows:0 tasks:0'
                };
            }

            const entry = projectMarker.entry;
            const projectX = projectMarker.r.left;
            const projectY = projectMarker.r.cy;

            // ------------------------------------------------------------
            // B. Get the ACTUAL immediate child task rows from the left tree.
            //
            // Prefer DOM row order (TR / role=row / LI). This is much more stable
            // than guessing a Y cutoff from chart graphics.
            // ------------------------------------------------------------
            function nearestRow(el) {
                if (!el) return null;

                return (
                    el.closest('tr') ||
                    el.closest('[role="row"]') ||
                    el.closest('li')
                );
            }

            const projectRow = nearestRow(projectMarker.el);
            let rowList = [];

            if (projectRow) {
                if (projectRow.tagName === 'TR') {
                    const table = projectRow.closest('table');
                    if (table) {
                        rowList = Array.from(table.querySelectorAll('tr'));
                    }
                } else if (projectRow.matches('[role="row"]')) {
                    const owner =
                        projectRow.closest('[role="treegrid"],[role="grid"],[role="table"]') ||
                        projectRow.parentElement;

                    if (owner) {
                        rowList = Array.from(owner.querySelectorAll('[role="row"]'));
                    }
                } else if (projectRow.tagName === 'LI') {
                    const owner = projectRow.parentElement;
                    if (owner) {
                        rowList = Array.from(owner.children).filter(
                            el => el.tagName === 'LI'
                        );
                    }
                }
            }

            function bestTaskNameInRow(row) {
                const candidates = [];

                for (const el of Array.from(
                    row.querySelectorAll('a,span,td,div')
                )) {
                    if (!visible(entry, el)) continue;

                    const r = rectFor(entry, el);
                    const name = cleanName(textOf(el));

                    if (r.left < projectX + 8 || r.left > projectX + 430) continue;
                    if (r.height < 8 || r.height > 48) continue;
                    if (isBadTaskName(name)) continue;

                    const childTexts = Array.from(el.children || [])
                        .filter(child => visible(entry, child))
                        .map(child => cleanName(textOf(child)))
                        .filter(t => t && !isMetadata(t));

                    const isContainer =
                        Array.from(new Set(childTexts))
                            .filter(t => t !== name)
                            .length >= 2;

                    if (isContainer) continue;

                    let score = 0;
                    if (el.tagName === 'A') score += 100;
                    if (el.closest('a')) score += 50;
                    if (el.hasAttribute('onclick')) score += 25;
                    score += Math.min(40, Math.max(0, r.left - projectX) * 0.15);
                    score -= (r.width * r.height) / 5000;

                    candidates.push({
                        name,
                        r,
                        score
                    });
                }

                candidates.sort((a, b) => b.score - a.score);
                return candidates[0] || null;
            }

            const taskRows = [];
            let stopProjectName = '';

            if (projectRow && rowList.length) {
                const projectIndex = rowList.indexOf(projectRow);

                if (projectIndex >= 0) {
                    for (let i = projectIndex + 1; i < rowList.length; i++) {
                        const row = rowList[i];

                        if (!visible(entry, row)) continue;

                        const rowText = cleanName(textOf(row));

                        // Hard stop at the first following known project heading.
                        let foundProject = '';

                        for (const projectName of knownProjectNames) {
                            if (
                                projectName !== selectedProjectName &&
                                (
                                    rowText === projectName ||
                                    Array.from(row.querySelectorAll('a,span,td,div'))
                                        .some(el =>
                                            visible(entry, el) &&
                                            cleanName(textOf(el)) === projectName
                                        )
                                )
                            ) {
                                foundProject = projectName;
                                break;
                            }
                        }

                        if (foundProject) {
                            stopProjectName = foundProject;
                            break;
                        }

                        const task = bestTaskNameInRow(row);

                        if (!task) continue;

                        // Use the real row center, not text element center, when possible.
                        const rr = rectFor(entry, row);

                        taskRows.push({
                            name: task.name,
                            y: rr.cy,
                            r: task.r
                        });
                    }
                }
            }

            // Fallback for old Brabio markup without semantic/table rows:
            // use geometry, but ONLY between selected project and the next exact
            // known project name.
            if (taskRows.length === 0) {
                let stopY = Number.POSITIVE_INFINITY;

                for (const el of Array.from(
                    entry.doc.querySelectorAll('a,span,td,div')
                )) {
                    if (!visible(entry, el)) continue;

                    const name = cleanName(textOf(el));
                    const r = rectFor(entry, el);

                    if (r.cy <= projectY + 3) continue;
                    if (name === selectedProjectName) continue;
                    if (!knownProjectNames.has(name)) continue;
                    if (r.left > projectX + 430) continue;

                    if (r.cy < stopY) {
                        stopY = r.cy;
                        stopProjectName = name;
                    }
                }

                const candidates = [];

                for (const el of Array.from(
                    entry.doc.querySelectorAll('a,span,td,div')
                )) {
                    if (!visible(entry, el)) continue;

                    const r = rectFor(entry, el);
                    const name = cleanName(textOf(el));

                    if (r.cy <= projectY + 4 || r.cy >= stopY - 2) continue;
                    if (r.left < projectX + 8 || r.left > projectX + 430) continue;
                    if (r.height < 8 || r.height > 48) continue;
                    if (isBadTaskName(name)) continue;

                    let score = 0;
                    if (el.tagName === 'A') score += 100;
                    if (el.closest('a')) score += 50;
                    if (el.hasAttribute('onclick')) score += 25;
                    score += Math.min(40, Math.max(0, r.left - projectX) * 0.15);

                    candidates.push({
                        name,
                        r,
                        score
                    });
                }

                candidates.sort((a, b) => {
                    if (Math.abs(a.r.cy - b.r.cy) > 6) {
                        return a.r.cy - b.r.cy;
                    }

                    return b.score - a.score;
                });

                for (const item of candidates) {
                    const sameRow = taskRows.find(
                        x => Math.abs(x.y - item.r.cy) <= 7
                    );

                    if (sameRow) continue;

                    taskRows.push({
                        name: item.name,
                        y: item.r.cy,
                        r: item.r
                    });
                }
            }

            // De-duplicate by row + name.
            const cleanTaskRows = [];

            for (const item of taskRows) {
                if (
                    cleanTaskRows.some(existing =>
                        existing.name === item.name &&
                        Math.abs(existing.y - item.y) <= 7
                    )
                ) {
                    continue;
                }

                cleanTaskRows.push(item);
            }

            cleanTaskRows.sort((a, b) => a.y - b.y);

            // ------------------------------------------------------------
            // C. Read progress / business days / dates / Gantt bars,
            // but ONLY match them to the task rows found above.
            // ------------------------------------------------------------
            const evidence = [];

            for (const el of Array.from(
                entry.doc.querySelectorAll('span,td,div,a')
            )) {
                if (!visible(entry, el)) continue;

                const r = rectFor(entry, el);
                const text = textOf(el);

                if (r.height < 8 || r.height > 48) continue;

                const progressMatch =
                    text.match(/(?:^|\\s)(\\d{1,3})\\s*%(?:\\s|$)/);

                const businessMatch =
                    text.match(/(?:^|\\s)(\\d+)\\s*営業日(?:\\s|$)/);

                const dateMatch =
                    text.match(/(?:^|\\s)(\\d{1,2}\\/\\d{1,2})\\s*\\([^)]+\\)(?:\\s|$)/);

                if (!progressMatch && !businessMatch && !dateMatch) continue;

                evidence.push({
                    r,
                    progress: progressMatch
                        ? Math.max(0, Math.min(100, Number(progressMatch[1])))
                        : null,
                    businessDays: businessMatch
                        ? Number(businessMatch[1])
                        : null,
                    dateText: dateMatch
                        ? dateMatch[1]
                        : null
                });
            }

            const bars = [];
            const w = winFor(entry);

            for (const el of Array.from(entry.doc.querySelectorAll('*'))) {
                if (!visible(entry, el)) continue;

                const r = rectFor(entry, el);

                if (r.width < 16) continue;
                if (r.height < 5 || r.height > 36) continue;

                const style = w.getComputedStyle(el);
                const bg = style.backgroundColor || '';
                const bgImage = style.backgroundImage || '';
                const marker = [
                    el.id,
                    typeof el.className === 'string' ? el.className : '',
                    el.getAttribute('name') || '',
                    el.getAttribute('title') || ''
                ].join(' ').toLowerCase();

                const painted =
                    (
                        bg &&
                        bg !== 'rgba(0, 0, 0, 0)' &&
                        bg !== 'transparent' &&
                        brightness(bg) < 245
                    ) ||
                    (
                        bgImage &&
                        bgImage !== 'none'
                    ) ||
                    /gantt|task|bar|schedule|progress/.test(marker);

                if (!painted) continue;

                if (
                    saturation(bg) < 8 &&
                    brightness(bg) > 225 &&
                    !/gantt|task|bar|progress/.test(marker)
                ) {
                    continue;
                }

                const barName = [
                    textOf(el),
                    el.getAttribute('title') || '',
                    el.getAttribute('alt') || '',
                    el.getAttribute('aria-label') || '',
                    el.getAttribute('data-title') || '',
                    el.getAttribute('data-name') || ''
                ]
                .map(cleanName)
                .find(t => t && !isBadTaskName(t)) || '';

                bars.push({
                    r,
                    name: barName,
                    sat: saturation(bg)
                });
            }

            // Date anchors.
            const monthNodes = [];

            for (const el of Array.from(
                entry.doc.querySelectorAll('div,span,td,th')
            )) {
                if (!visible(entry, el)) continue;

                const text = textOf(el);
                const m = text.match(/^(20\\d{2})年(\\d{1,2})月$/);

                if (!m) continue;

                monthNodes.push({
                    r: rectFor(entry, el),
                    year: Number(m[1]),
                    month: Number(m[2])
                });
            }

            const dateAnchors = [];

            for (const el of Array.from(
                entry.doc.querySelectorAll('div,span,td,th')
            )) {
                if (!visible(entry, el)) continue;

                const text = textOf(el);

                if (!/^(?:[1-9]|[12]\\d|3[01])$/.test(text)) continue;

                const r = rectFor(entry, el);

                if (r.width < 8 || r.width > 70) continue;
                if (r.height < 8 || r.height > 55) continue;

                let bestMonth = null;
                let bestScore = Number.POSITIVE_INFINITY;

                for (const month of monthNodes) {
                    const contains =
                        r.cx >= month.r.left - 20 &&
                        r.cx <= month.r.right + 20;

                    const distance = Math.abs(r.cx - month.r.cx);
                    const score = contains
                        ? distance * 0.2
                        : distance + 1000;

                    if (score < bestScore) {
                        bestScore = score;
                        bestMonth = month;
                    }
                }

                if (!bestMonth) continue;

                dateAnchors.push({
                    x: r.cx,
                    date: new Date(
                        bestMonth.year,
                        bestMonth.month - 1,
                        Number(text)
                    )
                });
            }

            dateAnchors.sort((a, b) => a.x - b.x);

            const compactAnchors = [];

            for (const anchor of dateAnchors) {
                const duplicate = compactAnchors.some(existing =>
                    Math.abs(existing.x - anchor.x) <= 2 &&
                    iso(existing.date) === iso(anchor.date)
                );

                if (!duplicate) compactAnchors.push(anchor);
            }

            function dateFromX(x) {
                if (compactAnchors.length < 2) {
                    return new Date();
                }

                let closest = compactAnchors[0];

                for (const anchor of compactAnchors) {
                    if (
                        Math.abs(anchor.x - x) <
                        Math.abs(closest.x - x)
                    ) {
                        closest = anchor;
                    }
                }

                const spacings = [];

                for (let i = 1; i < compactAnchors.length; i++) {
                    const dx =
                        compactAnchors[i].x -
                        compactAnchors[i - 1].x;

                    const dd = (
                        compactAnchors[i].date.getTime() -
                        compactAnchors[i - 1].date.getTime()
                    ) / 86400000;

                    if (
                        dx > 5 &&
                        Math.abs(dd) >= 1 &&
                        Math.abs(dd) <= 3
                    ) {
                        spacings.push(dx / dd);
                    }
                }

                let pxPerDay = 30;

                if (spacings.length) {
                    spacings.sort((a, b) => a - b);
                    pxPerDay =
                        spacings[Math.floor(spacings.length / 2)];
                }

                const offset = Math.round(
                    (x - closest.x) / pxPerDay
                );

                const result = new Date(closest.date);
                result.setDate(result.getDate() + offset);

                return result;
            }

            const results = [];

            for (const task of cleanTaskRows) {
                const y = task.y;

                const rowEvidence = evidence.filter(
                    item => Math.abs(item.r.cy - y) <= 12
                );

                const progressEvidence =
                    rowEvidence.find(item => item.progress !== null);

                const rowBars = bars
                    .filter(bar => Math.abs(bar.r.cy - y) <= 14)
                    .sort((a, b) => {
                        // Prefer the bar whose printed text exactly matches this task.
                        const aMatch = a.name === task.name ? 1 : 0;
                        const bMatch = b.name === task.name ? 1 : 0;

                        if (aMatch !== bMatch) return bMatch - aMatch;
                        if (Math.abs(a.sat - b.sat) > 4) return b.sat - a.sat;
                        return b.r.width - a.r.width;
                    });

                const bar = rowBars[0] || null;

                let startDate = new Date();
                let endDate = startDate;

                if (bar) {
                    startDate = dateFromX(bar.r.left);
                    endDate = dateFromX(bar.r.right);

                    if (endDate < startDate) {
                        endDate = startDate;
                    }
                }

                let assignee = '未指定';

                for (const el of Array.from(
                    entry.doc.querySelectorAll('span,td,div,a')
                )) {
                    if (!visible(entry, el)) continue;

                    const r = rectFor(entry, el);

                    if (Math.abs(r.cy - y) > 12) continue;
                    if (r.left <= projectX + 430) continue;

                    const text = textOf(el);
                    const email = text.match(
                        /[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}/i
                    );

                    if (email) {
                        assignee = email[0];
                        break;
                    }
                }

                results.push({
                    name: task.name,
                    start: iso(startDate),
                    end: iso(endDate),
                    progress: progressEvidence
                        ? progressEvidence.progress
                        : 0,
                    assignee
                });
            }

            return {
                tasks: results.slice(0, 400),
                debug:
                    `tree:left ` +
                    `treeRows:${rowList.length} ` +
                    `stop:${stopProjectName || 'END'} ` +
                    `tasks:${cleanTaskRows.length} ` +
                    `bars:${bars.length} ` +
                    `dates:${compactAnchors.length}`
            };
        })();
        """

        webView.evaluateJavaScript(js) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }

                if let error {
                    self.syncState = .failed(
                        "甘特圖讀取失敗：\(error.localizedDescription)"
                    )
                    return
                }

                guard
                    let object = result as? [String: Any],
                    let array = object["tasks"] as? [[String: Any]]
                else {
                    self.syncState = .failed("Brabio 回傳資料格式無法辨識")
                    return
                }

                self.diagnosticText =
                    object["debug"] as? String ?? ""

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
                    else {
                        continue
                    }

                    let end = max(start, endRaw)

                    let progress =
                        (item["progress"] as? NSNumber)?.intValue ?? 0

                    let assignee = (
                        item["assignee"] as? String
                    )?.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )

                    let safeAssignee =
                        (assignee?.isEmpty == false)
                        ? assignee!
                        : "未指定"

                    parsed.append(
                        GanttTask(
                            id: "\(index)-\(name)-\(startString)",
                            name: name,
                            start: start,
                            end: end,
                            progress: min(max(progress, 0), 100),
                            assignee: safeAssignee
                        )
                    )
                }

                if parsed.isEmpty && attempt < 4 {
                    self.syncState = .syncing

                    try? await Task.sleep(
                        nanoseconds: UInt64(
                            1_300_000_000 +
                            attempt * 500_000_000
                        )
                    )

                    self.extractTasks(attempt: attempt + 1)
                    return
                }

                self.tasks = parsed

                if parsed.isEmpty {
                    self.syncState = .failed(
                        "未讀到任務資料（\(self.diagnosticText)）"
                    )
                } else {
                    self.syncState = .ready
                }
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
            function docs(root) {
                const out = [root];
                const frames = Array.from(root.querySelectorAll('iframe,frame'));

                for (const frame of frames) {
                    try {
                        if (frame.contentDocument) {
                            out.push(...docs(frame.contentDocument));
                        }
                    } catch (_) {}
                }

                return out;
            }

            function visible(d, el) {
                if (!el) return false;

                const w = d.defaultView || window;
                const s = w.getComputedStyle(el);
                const r = el.getBoundingClientRect();

                return s.display !== 'none' &&
                       s.visibility !== 'hidden' &&
                       !el.disabled &&
                       r.width > 0 &&
                       r.height > 0;
            }

            function setValue(el, value) {
                const setter = Object
                    .getOwnPropertyDescriptor(
                        window.HTMLInputElement.prototype,
                        'value'
                    ).set;

                setter.call(el, value);
                el.dispatchEvent(new Event('input', { bubbles: true }));
                el.dispatchEvent(new Event('change', { bubbles: true }));
            }

            for (const d of docs(document)) {
                const inputs = Array.from(
                    d.querySelectorAll('input')
                ).filter(el => visible(d, el));

                const passwordField = inputs.find(
                    el => (el.type || '').toLowerCase() === 'password'
                );

                const accountField =
                    inputs.find(el => {
                        const blob = [
                            el.name,
                            el.id,
                            el.placeholder,
                            el.autocomplete,
                            el.type
                        ].join(' ').toLowerCase();

                        return el !== passwordField &&
                               ['text', 'email', ''].includes(
                                   (el.type || '').toLowerCase()
                               ) &&
                               /(login|user|mail|email|account|id)/.test(blob);
                    }) ||
                    inputs.find(el =>
                        el !== passwordField &&
                        ['text', 'email', ''].includes(
                            (el.type || '').toLowerCase()
                        )
                    );

                if (!accountField || !passwordField) continue;

                setValue(accountField, \(accountJSON));
                setValue(passwordField, \(passwordJSON));

                if (\(rememberJS)) {
                    const checkbox = inputs.find(
                        el => (el.type || '').toLowerCase() === 'checkbox'
                    );

                    if (checkbox && !checkbox.checked) {
                        checkbox.click();
                    }
                }

                const submitCandidates = Array.from(
                    d.querySelectorAll(
                        'button,input[type="submit"],input[type="button"],a'
                    )
                ).filter(el => visible(d, el));

                const submit =
                    submitCandidates.find(el => {
                        const text = [
                            el.innerText,
                            el.value,
                            el.title,
                            el.getAttribute('aria-label')
                        ]
                        .join(' ')
                        .toLowerCase();

                        return /(ログイン|login|sign in|登入)/.test(text);
                    }) ||
                    submitCandidates.find(
                        el => (el.type || '').toLowerCase() === 'submit'
                    );

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
            }

            return 'fields-not-found';
        })();
        """

        webView.evaluateJavaScript(js) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }

                if let error {
                    self.isSubmittingLogin = false
                    self.loginMessage =
                        "登入失敗：\(error.localizedDescription)"
                    return
                }

                let status = result as? String ?? "unknown"

                if status == "fields-not-found" ||
                   status == "submit-not-found" {
                    self.isSubmittingLogin = false
                    self.loginMessage =
                        "Brabio 登入頁面結構不同，請使用原始登入頁"
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

    private func jsonArrayLiteral(_ values: [String]) -> String {
        let parts = values.map { jsonLiteral($0) }
        return "[" + parts.joined(separator: ",") + "]"
    }

}
