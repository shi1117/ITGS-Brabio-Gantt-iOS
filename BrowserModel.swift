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
                self.extractTasks(attempt: 0)
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

        guard let webView else {
            syncState = .failed("找不到 Brabio 頁面")
            return
        }

        let nameLiteral = jsonLiteral(project.name)

        let js = """
        (function() {
            function docs(root) {
                const out = [root];
                const frames = Array.from(root.querySelectorAll('iframe,frame'));
                for (const frame of frames) {
                    try {
                        if (frame.contentDocument) out.push(...docs(frame.contentDocument));
                    } catch (_) {}
                }
                return out;
            }

            const targetName = \(nameLiteral);

            for (const d of docs(document)) {
                const w = d.defaultView || window;

                const nodes = Array.from(
                    d.querySelectorAll('a,button,[onclick],td,span,div')
                ).filter(el => {
                    const r = el.getBoundingClientRect();
                    const s = w.getComputedStyle(el);
                    return r.width > 0 &&
                           r.height > 0 &&
                           s.display !== 'none' &&
                           s.visibility !== 'hidden';
                });

                const exact = nodes.find(
                    el => (el.innerText || el.textContent || '').trim() === targetName
                );

                const fuzzy = nodes.find(
                    el => (el.innerText || el.textContent || '').trim().indexOf(targetName) >= 0
                );

                const hit = exact || fuzzy;

                if (hit) {
                    const clickable = hit.closest('a,button,[onclick]') || hit;
                    clickable.click();
                    return 'clicked';
                }
            }

            return 'not-found';
        })();
        """

        webView.evaluateJavaScript(js) { [weak self] result, _ in
            Task { @MainActor in
                guard let self else { return }

                if (result as? String) != "clicked" {
                    self.syncState = .failed("找不到「\(project.name)」的 Brabio 連結")
                    return
                }

                try? await Task.sleep(nanoseconds: 1_500_000_000)
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

        let js = """
        (function() {
            const selectedProjectName = \(projectNameJSON);

            // Convert coordinates from nested frames into one common coordinate system.
            function collectDocs(root, offsetX = 0, offsetY = 0, depth = 0) {
                const result = [{
                    doc: root,
                    offsetX,
                    offsetY,
                    depth
                }];

                for (const frame of Array.from(root.querySelectorAll('iframe,frame'))) {
                    try {
                        if (!frame.contentDocument) continue;

                        const r = frame.getBoundingClientRect();

                        result.push(
                            ...collectDocs(
                                frame.contentDocument,
                                offsetX + r.left,
                                offsetY + r.top,
                                depth + 1
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

            function isBadTaskName(value) {
                const name = cleanName(value);

                if (name.length < 2 || name.length > 90) return true;
                if (name === selectedProjectName) return true;
                if (/^(トップページ|チャート|カレンダー|担当状況|全画面|表示設定|Brabio|ログアウト|ヘルプ)$/i.test(name)) return true;
                if (/^(全員|全ての進捗|タスクを追加する)$/i.test(name)) return true;
                if (/ログインユーザー|メンバー未設定/.test(name)) return true;
                if (/^[0-9]+$/.test(name)) return true;
                if (/^[0-9]{1,2}月[0-9]{1,2}日/.test(name)) return true;
                if (/^20[0-9]{2}[\\/年.-]/.test(name)) return true;
                if (/^[0-9]{1,3}%$/.test(name)) return true;
                if (/@/.test(name)) return true;

                return false;
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

                const maxV = Math.max(c.r, c.g, c.b);
                const minV = Math.min(c.r, c.g, c.b);

                return maxV - minV;
            }

            function iso(date) {
                const y = date.getFullYear();
                const m = String(date.getMonth() + 1).padStart(2, '0');
                const d = String(date.getDate()).padStart(2, '0');
                return `${y}-${m}-${d}`;
            }

            function parseDate(value) {
                const m = String(value || '').match(
                    /(20\\d{2})[\\/年.\\-](\\d{1,2})[\\/月.\\-](\\d{1,2})/
                );

                if (!m) return null;

                return new Date(
                    Number(m[1]),
                    Number(m[2]) - 1,
                    Number(m[3])
                );
            }

            const allText = entries
                .map(e => e.doc.body ? (e.doc.body.innerText || '') : '')
                .join('\\n');

            // -------- 1. Scope the task tree to the SELECTED project --------
            // IMPORTANT:
            // Never scan the whole Brabio page as one task list.
            // Every project has its own expanded tree. We first locate the exact
            // selected project row, then only keep the indented rows below it,
            // stopping at the next project row at the same indentation level.
            //
            // This logic is generic. It works for 金日水塔專案, Side car-500kW事業,
            // Control box projects, 2.5MW / 5MW, Row cooler, etc. No project is
            // hard-coded here.
            // -------- 1. Find the SELECTED PROJECT in the LEFT task tree --------
            // The same project name also appears in Brabio's breadcrumb/detail pane.
            // v1.4 sometimes picked that right-side breadcrumb, which is why member names,
            // business-day counts and dates were incorrectly treated as tasks.
            //
            // v1.5 always chooses the LEFTMOST exact project-name hit first.
            // -------- 1. Find the SELECTED PROJECT in the LEFT task tree --------
            //
            // v1.5 proved the correct project tree is found (tree:left),
            // but labels:0 showed that Brabio does NOT expose these task names
            // as plain <a> / [onclick] elements. Its old UI uses delegated click
            // handlers / nested table cells.
            //
            // v1.6 therefore reads VISUAL ROW TEXT from the selected project's
            // left tree only, then keeps one atomic label per row.
            let projectMarker = null;

            for (const entry of entries) {
                const nodes = Array.from(
                    entry.doc.querySelectorAll('a,span,td,div')
                );

                for (const el of nodes) {
                    if (!visible(entry, el)) continue;

                    const r = rectFor(entry, el);
                    const name = cleanName(textOf(el));

                    if (name !== selectedProjectName) continue;

                    const area = r.width * r.height;

                    // Exact project-name hit furthest to the LEFT wins.
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
                            area,
                            name
                        };
                    }
                }
            }

            let labels = [];
            let rawTreeRows = 0;

            if (projectMarker !== null) {
                const entry = projectMarker.entry;
                const projectX = projectMarker.r.left;
                const projectY = projectMarker.r.cy;

                // The Brabio project tree is the narrow pane on the left.
                // Keep all extraction inside the SAME frame/document as the marker.
                const treeLeft = Math.max(entry.offsetX, projectX - 40);
                const treeRight = projectX + 430;

                // Find next top-level project row. That is the end of this project's
                // children. We deliberately use the same frame only.
                let stopY = Number.POSITIVE_INFINITY;

                const allTreeNodes = Array.from(
                    entry.doc.querySelectorAll('a,span,td,div')
                );

                for (const el of allTreeNodes) {
                    if (!visible(entry, el)) continue;

                    const r = rectFor(entry, el);
                    const name = cleanName(textOf(el));

                    if (r.cy <= projectY + 3) continue;
                    if (r.left < treeLeft || r.left > projectX + 28) continue;

                    const looksLikeProject =
                        /(事業|專案|项目|プロジェクト|請假|休暇)$/i.test(name);

                    if (
                        looksLikeProject &&
                        name !== selectedProjectName
                    ) {
                        stopY = Math.min(stopY, r.cy);
                    }
                }

                function isMetadata(value) {
                    const name = cleanName(value);

                    if (!name) return true;
                    if (/^\\d+\\s*営業日$/i.test(name)) return true;
                    if (/^\\d{1,2}\\/\\d{1,2}\\s*\\([^)]+\\)$/i.test(name)) return true;
                    if (/^\\d{1,2}月\\d{1,2}日(?:\\s*\\([^)]+\\))?$/i.test(name)) return true;
                    if (/^\\d{1,3}\\s*%$/i.test(name)) return true;
                    if (/^(登録|更新|期間|進捗|最終更新|メンバー|あしあと|内容|添付ファイル)$/i.test(name)) return true;
                    if (/@/.test(name)) return true;

                    return false;
                }

                const candidates = [];

                for (const el of allTreeNodes) {
                    if (!visible(entry, el)) continue;

                    const r = rectFor(entry, el);
                    const name = cleanName(textOf(el));

                    if (r.cy <= projectY + 3 || r.cy >= stopY - 2) continue;
                    if (r.left < treeLeft || r.left > treeRight) continue;
                    if (r.width < 12 || r.width > 430) continue;
                    if (r.height < 9 || r.height > 48) continue;
                    if (isBadTaskName(name)) continue;
                    if (isMetadata(name)) continue;

                    // Exclude another project heading that happens to be nested.
                    if (
                        /(事業|專案|项目|プロジェクト|請假|休暇)$/i.test(name) &&
                        r.left <= projectX + 26
                    ) {
                        continue;
                    }

                    // Reject container elements whose text is made of multiple visible
                    // child labels. Keep the "atomic" text node for that row.
                    const visibleChildren = Array.from(el.children || [])
                        .filter(child => visible(entry, child))
                        .map(child => cleanName(textOf(child)))
                        .filter(t => t && !isMetadata(t));

                    const distinctChildTexts = Array.from(
                        new Set(visibleChildren)
                    );

                    const isContainer =
                        distinctChildTexts.length >= 2 &&
                        distinctChildTexts.some(t => t !== name);

                    if (isContainer) continue;

                    const clickable =
                        el.tagName === 'A' ||
                        el.hasAttribute('onclick') ||
                        !!el.closest('a,[onclick]');

                    candidates.push({
                        entry,
                        el,
                        name,
                        r,
                        clickable,
                        area: r.width * r.height,
                        quality: clickable ? 3 : 1
                    });
                }

                rawTreeRows = candidates.length;

                // Group by visual row. Brabio creates several nested DOM elements for
                // the same row; choose the best candidate from each row.
                candidates.sort((a, b) => {
                    if (Math.abs(a.r.cy - b.r.cy) > 3) {
                        return a.r.cy - b.r.cy;
                    }

                    if (a.quality !== b.quality) {
                        return b.quality - a.quality;
                    }

                    // Prefer the smaller atomic text box.
                    return a.area - b.area;
                });

                const rowGroups = [];

                for (const item of candidates) {
                    let group = rowGroups.find(g =>
                        Math.abs(g.cy - item.r.cy) <= 7
                    );

                    if (!group) {
                        group = {
                            cy: item.r.cy,
                            items: []
                        };
                        rowGroups.push(group);
                    }

                    group.items.push(item);
                }

                for (const group of rowGroups) {
                    const items = group.items
                        .filter(item => !isMetadata(item.name))
                        .sort((a, b) => {
                            if (a.quality !== b.quality) {
                                return b.quality - a.quality;
                            }

                            // Prefer the visually indented child text, then smaller area.
                            if (Math.abs(a.r.left - b.r.left) > 8) {
                                return b.r.left - a.r.left;
                            }

                            return a.area - b.area;
                        });

                    if (!items.length) continue;

                    const chosen = items[0];

                    // Final hard filters for known non-task labels.
                    if (chosen.name === selectedProjectName) continue;
                    if (/^(ITG|Brabio)$/i.test(chosen.name)) continue;
                    if (/ブラビオへようこそ|トップページ/.test(chosen.name)) continue;
                    if (/全画面表示設定|チャート|カレンダー|担当状況/.test(chosen.name)) continue;

                    labels.push(chosen);
                }
            }

            labels.sort((a, b) => a.r.cy - b.r.cy);

            // -------- 2. Find real Gantt bars --------
            let bars = [];

            for (const entry of entries) {
                const w = winFor(entry);

                for (const el of Array.from(entry.doc.querySelectorAll('*'))) {
                    if (!visible(entry, el)) continue;

                    const r = rectFor(entry, el);

                    if (r.width < 12) continue;
                    if (r.height < 5 || r.height > 34) continue;

                    const style = w.getComputedStyle(el);
                    const marker = [
                        el.id,
                        typeof el.className === 'string' ? el.className : '',
                        el.getAttribute('name') || '',
                        el.getAttribute('title') || ''
                    ].join(' ').toLowerCase();

                    const bg = style.backgroundColor || '';
                    const bgImage = style.backgroundImage || '';

                    const painted =
                        (
                            bg &&
                            bg !== 'rgba(0, 0, 0, 0)' &&
                            bg !== 'transparent' &&
                            brightness(bg) < 247
                        ) ||
                        (
                            bgImage &&
                            bgImage !== 'none'
                        ) ||
                        /gantt|task|bar|schedule|progress/.test(marker);

                    if (!painted) continue;

                    // Ignore common borders/grid cells.
                    if (
                        saturation(bg) < 8 &&
                        brightness(bg) > 225 &&
                        !/gantt|task|bar|progress/.test(marker)
                    ) {
                        continue;
                    }

                    bars.push({
                        entry,
                        el,
                        r,
                        bg,
                        sat: saturation(bg),
                        marker
                    });
                }
            }

            // -------- 3. Build date anchors from Brabio's actual header --------
            // This is more reliable than assuming the visible month.
            const dateAnchors = [];

            for (const entry of entries) {
                const monthNodes = [];

                for (const el of Array.from(
                    entry.doc.querySelectorAll('div,span,td,th')
                )) {
                    if (!visible(entry, el)) continue;

                    const t = textOf(el);
                    const m = t.match(/^(20\\d{2})年(\\d{1,2})月$/);

                    if (!m) continue;

                    monthNodes.push({
                        r: rectFor(entry, el),
                        year: Number(m[1]),
                        month: Number(m[2])
                    });
                }

                const dayNodes = [];

                for (const el of Array.from(
                    entry.doc.querySelectorAll('div,span,td,th')
                )) {
                    if (!visible(entry, el)) continue;

                    const t = textOf(el);

                    if (!/^(?:[1-9]|[12]\\d|3[01])$/.test(t)) continue;

                    const r = rectFor(entry, el);

                    if (r.width < 8 || r.width > 70) continue;
                    if (r.height < 8 || r.height > 55) continue;

                    dayNodes.push({
                        r,
                        day: Number(t)
                    });
                }

                for (const day of dayNodes) {
                    let bestMonth = null;
                    let bestScore = Number.POSITIVE_INFINITY;

                    for (const month of monthNodes) {
                        const contains =
                            day.r.cx >= month.r.left - 20 &&
                            day.r.cx <= month.r.right + 20;

                        const distance = Math.abs(
                            day.r.cx - month.r.cx
                        );

                        const score = contains
                            ? distance * 0.2
                            : distance + 1000;

                        if (score < bestScore) {
                            bestScore = score;
                            bestMonth = month;
                        }
                    }

                    if (!bestMonth) continue;

                    const date = new Date(
                        bestMonth.year,
                        bestMonth.month - 1,
                        day.day
                    );

                    dateAnchors.push({
                        x: day.r.cx,
                        date
                    });
                }
            }

            dateAnchors.sort((a, b) => a.x - b.x);

            // Remove duplicated day-label descendants.
            const compactAnchors = [];

            for (const anchor of dateAnchors) {
                const duplicate = compactAnchors.some(existing =>
                    Math.abs(existing.x - anchor.x) <= 2 &&
                    iso(existing.date) === iso(anchor.date)
                );

                if (!duplicate) compactAnchors.push(anchor);
            }

            function dateFromX(x) {
                if (compactAnchors.length >= 2) {
                    let closest = compactAnchors[0];

                    for (const a of compactAnchors) {
                        if (Math.abs(a.x - x) < Math.abs(closest.x - x)) {
                            closest = a;
                        }
                    }

                    const distances = [];

                    for (let i = 1; i < compactAnchors.length; i++) {
                        const dx = compactAnchors[i].x - compactAnchors[i - 1].x;
                        const dd = (
                            compactAnchors[i].date.getTime() -
                            compactAnchors[i - 1].date.getTime()
                        ) / 86400000;

                        if (dx > 5 && Math.abs(dd) >= 1 && Math.abs(dd) <= 3) {
                            distances.push(dx / dd);
                        }
                    }

                    let pxPerDay = 30;

                    if (distances.length) {
                        distances.sort((a, b) => a - b);
                        pxPerDay = distances[Math.floor(distances.length / 2)];
                    }

                    const dayOffset = Math.round(
                        (x - closest.x) / pxPerDay
                    );

                    const d = new Date(closest.date);
                    d.setDate(d.getDate() + dayOffset);

                    return d;
                }

                // Header not found: try project-wide date text.
                const explicitDates = Array.from(
                    allText.matchAll(
                        /20\\d{2}[\\/年.\\-]\\d{1,2}[\\/月.\\-]\\d{1,2}/g
                    )
                )
                .map(x => parseDate(x[0]))
                .filter(Boolean);

                if (explicitDates.length) {
                    explicitDates.sort((a, b) => a - b);
                    return explicitDates[0];
                }

                return new Date();
            }

            // -------- 4. Pair each task label with a bar on the same row --------
            const results = [];

            for (const label of labels) {
                const nearbyBars = bars
                    .filter(bar =>
                        Math.abs(bar.r.cy - label.r.cy) <= 16 &&
                        bar.r.left >= label.r.right - 5
                    )
                    .sort((a, b) => {
                        // Prefer colored Brabio bars over gray background rails.
                        if (Math.abs(a.sat - b.sat) > 4) {
                            return b.sat - a.sat;
                        }

                        // Then prefer a reasonable task-bar width.
                        const aPenalty = a.r.width > 1200 ? 500 : 0;
                        const bPenalty = b.r.width > 1200 ? 500 : 0;

                        return (
                            (a.r.left - label.r.right) + aPenalty
                        ) - (
                            (b.r.left - label.r.right) + bPenalty
                        );
                    });

                const bar = nearbyBars[0] || null;

                const labelContainer =
                    label.el.closest('tr,[role="row"],li') ||
                    label.el.parentElement;

                let context = textOf(labelContainer || label.el);

                if (labelContainer) {
                    context += ' ' + Array.from(
                        labelContainer.attributes || []
                    ).map(a => a.value).join(' ');
                }

                // Add nearby percentage / assignee text from the same visual row.
                for (const entry of entries) {
                    for (const node of Array.from(
                        entry.doc.querySelectorAll('span,td,div,a')
                    )) {
                        if (!visible(entry, node)) continue;

                        const r = rectFor(entry, node);

                        if (Math.abs(r.cy - label.r.cy) > 13) continue;

                        const t = textOf(node);

                        if (
                            /\\d{1,3}\\s*%/.test(t) ||
                            /[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}/i.test(t)
                        ) {
                            context += ' ' + t;
                        }
                    }
                }

                const explicitDates = Array.from(
                    context.matchAll(
                        /20\\d{2}[\\/年.\\-]\\d{1,2}[\\/月.\\-]\\d{1,2}/g
                    )
                )
                .map(x => parseDate(x[0]))
                .filter(Boolean);

                let startDate = null;
                let endDate = null;

                if (explicitDates.length >= 1) {
                    startDate = explicitDates[0];
                    endDate = explicitDates[1] || explicitDates[0];
                } else if (bar) {
                    startDate = dateFromX(bar.r.left);
                    endDate = dateFromX(bar.r.right);
                } else {
                    // Keep the task visible even when Brabio has no painted bar.
                    startDate = dateFromX(label.r.right + 40);
                    endDate = startDate;
                }

                if (endDate < startDate) {
                    endDate = startDate;
                }

                const progressMatch = context.match(/(\\d{1,3})\\s*%/);

                const progress = progressMatch
                    ? Math.max(
                        0,
                        Math.min(100, Number(progressMatch[1]))
                    )
                    : 0;

                const emailMatch = context.match(
                    /[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}/i
                );

                let assignee = emailMatch
                    ? emailMatch[0]
                    : '未指定';

                results.push({
                    name: label.name,
                    start: iso(startDate),
                    end: iso(endDate),
                    progress,
                    assignee,
                    y: label.r.cy
                });
            }

            // -------- 5. Final visual-row de-duplication --------
            results.sort((a, b) => a.y - b.y);

            const final = [];

            for (const item of results) {
                const duplicate = final.some(existing =>
                    existing.name === item.name &&
                    Math.abs(existing.y - item.y) <= 7
                );

                if (!duplicate) {
                    final.push(item);
                }
            }

            return {
                tasks: final.slice(0, 400),
                debug:
                    `frames:${entries.length - 1} ` +
                    `tree:${projectMarker ? 'left' : 'none'} ` +
                    `raw:${rawTreeRows} ` +
                    `labels:${labels.length} ` +
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
}
