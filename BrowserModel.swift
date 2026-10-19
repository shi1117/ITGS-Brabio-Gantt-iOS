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

        let js = """
        (function() {
            function collectDocs(root, depth = 0) {
                const result = [{ doc: root, depth }];

                for (const frame of Array.from(root.querySelectorAll('iframe,frame'))) {
                    try {
                        if (frame.contentDocument) {
                            result.push(...collectDocs(frame.contentDocument, depth + 1));
                        }
                    } catch (_) {}
                }

                return result;
            }

            const docEntries = collectDocs(document);

            function winFor(d) {
                return d.defaultView || window;
            }

            function visible(d, el) {
                if (!el) return false;

                const w = winFor(d);
                const s = w.getComputedStyle(el);
                const r = el.getBoundingClientRect();

                return r.width > 0 &&
                       r.height > 0 &&
                       s.display !== 'none' &&
                       s.visibility !== 'hidden';
            }

            function textOf(el) {
                return (el.innerText || el.textContent || '')
                    .replace(/\\s+/g, ' ')
                    .trim();
            }

            function parseDateParts(str) {
                const m = str.match(
                    /(20\\d{2})[\\/年\\.\\-](\\d{1,2})[\\/月\\.\\-](\\d{1,2})/
                );

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

            function brightness(color) {
                const m = String(color || '')
                    .match(/rgba?\\((\\d+),\\s*(\\d+),\\s*(\\d+)/);

                if (!m) return 255;

                return (
                    Number(m[1]) +
                    Number(m[2]) +
                    Number(m[3])
                ) / 3;
            }

            function cleanTaskName(value) {
                return String(value || '')
                    .replace(/^[-+▶▼■□●○▸▾\\s]+/, '')
                    .replace(/\\s+/g, ' ')
                    .trim();
            }

            const bodies = docEntries
                .map(x => x.doc.body ? (x.doc.body.innerText || '') : '')
                .join('\\n');

            let overallStart = null;
            let overallEnd = null;

            const ranges = Array.from(
                bodies.matchAll(
                    /(20\\d{2})[\\/年\\.\\-](\\d{1,2})[\\/月\\.\\-](\\d{1,2})\\s*[～~〜―—\\-]\\s*(20\\d{2})[\\/年\\.\\-](\\d{1,2})[\\/月\\.\\-](\\d{1,2})/g
                )
            );

            if (ranges.length) {
                const r = ranges[ranges.length - 1];

                overallStart = new Date(
                    Number(r[1]),
                    Number(r[2]) - 1,
                    Number(r[3])
                );

                overallEnd = new Date(
                    Number(r[4]),
                    Number(r[5]) - 1,
                    Number(r[6])
                );
            }

            if (!overallStart || !overallEnd || overallEnd <= overallStart) {
                const month = bodies.match(/(20\\d{2})年(\\d{1,2})月/);

                if (month) {
                    overallStart = new Date(
                        Number(month[1]),
                        Number(month[2]) - 1,
                        1
                    );

                    overallEnd = new Date(
                        Number(month[1]),
                        Number(month[2]) + 2,
                        0
                    );
                } else {
                    const now = new Date();
                    overallStart = new Date(now.getFullYear(), now.getMonth(), 1);
                    overallEnd = new Date(now.getFullYear(), now.getMonth() + 3, 0);
                }
            }

            const results = [];
            const debug = {
                docs: docEntries.length,
                rows: 0,
                bars: 0,
                attributeHits: 0,
                textCandidates: 0
            };

            // PASS 1:
            // Read any element/row whose text, title, data attributes or onclick
            // already contain dates. Brabio often stores more information in
            // attributes than it visually prints.
            for (const entry of docEntries) {
                const d = entry.doc;

                const nodes = Array.from(
                    d.querySelectorAll(
                        'tr,[role="row"],li,a,td,div,span'
                    )
                );

                debug.rows += nodes.length;

                for (const el of nodes) {
                    if (!visible(d, el)) continue;

                    const attrs = Array.from(el.attributes || [])
                        .map(a => `${a.name}=${a.value}`)
                        .join(' ');

                    const blob = `${textOf(el)} ${attrs}`;
                    const dates = Array.from(
                        blob.matchAll(
                            /20\\d{2}[\\/年\\.\\-]\\d{1,2}[\\/月\\.\\-]\\d{1,2}/g
                        )
                    );

                    if (dates.length === 0) continue;

                    let name = '';

                    const cells = Array.from(el.querySelectorAll('td,th,a,span'))
                        .map(textOf)
                        .filter(x => x.length >= 2 && x.length <= 90);

                    name =
                        cells.find(x =>
                            !/^\\d+$/.test(x) &&
                            !/20\\d{2}/.test(x) &&
                            !/^\\d{1,3}%$/.test(x) &&
                            !/^(日|週|月|年|前月|次月)$/.test(x)
                        ) || cleanTaskName(textOf(el));

                    name = cleanTaskName(name);

                    if (name.length < 2 || name.length > 100) continue;

                    const first = parseDateParts(dates[0][0]);
                    const second = parseDateParts(
                        (dates[1] ? dates[1][0] : dates[0][0])
                    );

                    if (!first || !second) continue;

                    const progressMatch = blob.match(/(\\d{1,3})\\s*%/);
                    const emailMatch = blob.match(
                        /[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}/i
                    );

                    results.push({
                        name,
                        start: iso(new Date(first.y, first.m - 1, first.d)),
                        end: iso(new Date(second.y, second.m - 1, second.d)),
                        progress: progressMatch
                            ? Math.max(0, Math.min(100, Number(progressMatch[1])))
                            : 0,
                        assignee: emailMatch ? emailMatch[0] : '未指定'
                    });

                    debug.attributeHits += 1;
                }
            }

            // PASS 2:
            // Geometry-based extraction. This handles the classic Brabio chart
            // where the task bar is painted as an element with width/position.
            if (results.length < 2) {
                for (const entry of docEntries) {
                    const d = entry.doc;
                    const w = winFor(d);

                    const all = Array.from(d.querySelectorAll('*'))
                        .filter(el => visible(d, el));

                    const scrollContainers = all
                        .filter(el => {
                            const r = el.getBoundingClientRect();

                            return el.scrollWidth > el.clientWidth + 150 &&
                                   r.width > 200 &&
                                   r.height > 100;
                        })
                        .sort((a, b) => b.scrollWidth - a.scrollWidth);

                    const timeline =
                        scrollContainers[0] ||
                        d.scrollingElement ||
                        d.documentElement;

                    const timelineRect = timeline.getBoundingClientRect
                        ? timeline.getBoundingClientRect()
                        : { left: 0, top: 0 };

                    const scrollLeft = timeline.scrollLeft || 0;
                    const totalWidth = Math.max(
                        timeline.scrollWidth || timeline.clientWidth || 1,
                        1
                    );

                    const viewportWidth =
                        d.documentElement.clientWidth ||
                        w.innerWidth ||
                        980;

                    const textCandidates = Array.from(
                        d.querySelectorAll('a,span,td,div,input')
                    )
                    .filter(el => visible(d, el))
                    .map(el => {
                        const r = el.getBoundingClientRect();

                        let t = textOf(el);

                        if (!t && el.value) {
                            t = String(el.value).trim();
                        }

                        return {
                            el,
                            text: cleanTaskName(t),
                            cy: r.top + r.height / 2,
                            x: r.left,
                            w: r.width,
                            h: r.height
                        };
                    })
                    .filter(x =>
                        x.x < Math.max(520, viewportWidth * 0.55) &&
                        x.cy > 80 &&
                        x.text.length >= 2 &&
                        x.text.length <= 90 &&
                        !/^\\d+$/.test(x.text) &&
                        !/(トップページ|チャート|カレンダー|担当状況|全画面|表示設定)/.test(x.text) &&
                        !/^(日|週|月|年|前月|次月)$/.test(x.text)
                    );

                    debug.textCandidates += textCandidates.length;

                    const bars = all
                        .map(el => {
                            const r = el.getBoundingClientRect();
                            const s = w.getComputedStyle(el);
                            const marker = [
                                el.id,
                                el.className,
                                el.getAttribute('name'),
                                el.getAttribute('title')
                            ].join(' ').toLowerCase();

                            const hasPaint =
                                (
                                    s.backgroundColor &&
                                    s.backgroundColor !== 'rgba(0, 0, 0, 0)' &&
                                    s.backgroundColor !== 'transparent' &&
                                    brightness(s.backgroundColor) < 238
                                ) ||
                                (
                                    s.backgroundImage &&
                                    s.backgroundImage !== 'none'
                                ) ||
                                /gantt|chart|task|bar|schedule|progress/.test(marker);

                            return {
                                el,
                                r,
                                marker,
                                hasPaint
                            };
                        })
                        .filter(x =>
                            x.r.width >= 18 &&
                            x.r.height >= 5 &&
                            x.r.height <= 38 &&
                            x.r.top > 80 &&
                            x.hasPaint
                        );

                    debug.bars += bars.length;

                    const totalMS =
                        overallEnd.getTime() - overallStart.getTime();

                    const seenRows = new Set();

                    for (const bar of bars) {
                        const cy = bar.r.top + bar.r.height / 2;

                        let nearest = null;
                        let nearestDelta = 99999;

                        for (const candidate of textCandidates) {
                            const delta = Math.abs(candidate.cy - cy);

                            if (delta < nearestDelta && delta <= 24) {
                                nearest = candidate;
                                nearestDelta = delta;
                            }
                        }

                        if (!nearest) continue;

                        let name = cleanTaskName(nearest.text);

                        if (name.length < 2) continue;
                        if (/^(タスクを追加する|全員|全ての進捗)$/.test(name)) continue;
                        if (/(事業|專案|项目|プロジェクト)$/.test(name) && name.length < 50) continue;

                        const rowKey = `${Math.round(cy / 4)}:${name}`;

                        if (seenRows.has(rowKey)) continue;
                        seenRows.add(rowKey);

                        const localX = Math.max(
                            0,
                            bar.r.left - timelineRect.left + scrollLeft
                        );

                        const startRatio = Math.max(
                            0,
                            Math.min(1, localX / totalWidth)
                        );

                        const endRatio = Math.max(
                            startRatio,
                            Math.min(
                                1,
                                (localX + bar.r.width) / totalWidth
                            )
                        );

                        const startDate = new Date(
                            overallStart.getTime() + totalMS * startRatio
                        );

                        const endDate = new Date(
                            overallStart.getTime() + totalMS * endRatio
                        );

                        const container =
                            bar.el.closest('tr,[role="row"]') ||
                            bar.el.parentElement;

                        const rowText = container
                            ? `${textOf(container)} ${Array.from(container.attributes || []).map(a => a.value).join(' ')}`
                            : '';

                        const progressMatch =
                            rowText.match(/(\\d{1,3})\\s*%/);

                        const emailMatch =
                            rowText.match(
                                /[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}/i
                            );

                        results.push({
                            name,
                            start: iso(startDate),
                            end: iso(endDate < startDate ? startDate : endDate),
                            progress: progressMatch
                                ? Math.max(0, Math.min(100, Number(progressMatch[1])))
                                : 0,
                            assignee: emailMatch
                                ? emailMatch[0]
                                : '未指定'
                        });
                    }
                }
            }

            // PASS 3:
            // Last fallback: visible table rows with date-like text.
            if (results.length === 0) {
                for (const entry of docEntries) {
                    const d = entry.doc;

                    for (const row of Array.from(d.querySelectorAll('tr'))) {
                        if (!visible(d, row)) continue;

                        const t = textOf(row);

                        if (t.length < 3 || t.length > 260) continue;

                        const dates = Array.from(
                            t.matchAll(
                                /20\\d{2}[\\/年\\.\\-]\\d{1,2}[\\/月\\.\\-]\\d{1,2}/g
                            )
                        );

                        if (!dates.length) continue;

                        const first = parseDateParts(dates[0][0]);
                        const second = parseDateParts(
                            dates[1] ? dates[1][0] : dates[0][0]
                        );

                        if (!first || !second) continue;

                        const cells = Array.from(
                            row.querySelectorAll('td,th')
                        )
                        .map(textOf)
                        .filter(x => x.length >= 2 && x.length <= 90);

                        const name = cleanTaskName(
                            cells.find(x =>
                                !/^\\d+$/.test(x) &&
                                !/20\\d{2}/.test(x) &&
                                !/%/.test(x)
                            ) || ''
                        );

                        if (!name) continue;

                        const progressMatch = t.match(/(\\d{1,3})\\s*%/);
                        const emailMatch = t.match(
                            /[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}/i
                        );

                        results.push({
                            name,
                            start: iso(
                                new Date(first.y, first.m - 1, first.d)
                            ),
                            end: iso(
                                new Date(second.y, second.m - 1, second.d)
                            ),
                            progress: progressMatch
                                ? Math.max(0, Math.min(100, Number(progressMatch[1])))
                                : 0,
                            assignee: emailMatch
                                ? emailMatch[0]
                                : '未指定'
                        });
                    }
                }
            }

            const unique = [];
            const keys = new Set();

            for (const item of results) {
                const key =
                    `${item.name}|${item.start}|${item.end}|${item.assignee}`;

                if (keys.has(key)) continue;
                keys.add(key);
                unique.push(item);
            }

            return {
                tasks: unique.slice(0, 300),
                debug: `frames:${debug.docs - 1} rows:${debug.rows} bars:${debug.bars} attrs:${debug.attributeHits} text:${debug.textCandidates}`
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

                let unique = Dictionary(
                    grouping: parsed,
                    by: {
                        "\($0.name)|\(formatter.string(from: $0.start))|\(formatter.string(from: $0.end))|\($0.assignee)"
                    }
                )
                .compactMap { $0.value.first }

                let sorted = unique.sorted {
                    if $0.start == $1.start {
                        return $0.name < $1.name
                    }

                    return $0.start < $1.start
                }

                if sorted.isEmpty && attempt < 4 {
                    self.syncState = .syncing

                    try? await Task.sleep(
                        nanoseconds: UInt64(1_200_000_000 + attempt * 500_000_000)
                    )

                    self.extractTasks(attempt: attempt + 1)
                    return
                }

                self.tasks = sorted

                if sorted.isEmpty {
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
