import SwiftUI

struct NativeProjectListView: View {
    @ObservedObject var model: BrowserModel
    let openProject: (ProjectItem) -> Void

    var body: some View {
        Group {
                if model.projects.isEmpty {
                    emptyState
                } else {
                    List(model.projects) { project in
                        Button {
                            model.selectProject(project)
                            openProject(project)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 22))
                                    .foregroundStyle(.orange)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(project.name)
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(.black)
                                        .multilineTextAlignment(.leading)

                                    if model.selectedProject?.id == project.id {
                                        Text("目前專案")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("專案目錄")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        model.refreshNativeData()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        .safeAreaInset(edge: .bottom) {
            syncBanner
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("正在讀取 Brabio 專案…")
                .font(.system(size: 16, weight: .semibold))
            Text("首次登入後會自動同步專案目錄")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var syncBanner: some View {
        switch model.syncState {
        case .syncing:
            HStack(spacing: 9) {
                ProgressView()
                Text("正在同步 Brabio")
                    .font(.footnote.weight(.medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.bottom, 8)

        case .failed(let message):
            Text(message)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.red)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 8)

        default:
            EmptyView()
        }
    }
}

struct ProjectWorkspaceView: View {
    @ObservedObject var model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var tab: WorkspaceTab = .gantt

    var body: some View {
        VStack(spacing: 0) {
            workspaceHeader
            Divider()

            Group {
                switch tab {
                case .gantt:
                    NativeGanttView(tasks: model.tasks)
                case .schedule:
                    NativeScheduleView(tasks: model.tasks)
                case .assignee:
                    NativeAssigneeView(tasks: model.tasks)
                case .overview:
                    NativeOverviewView(
                        tasks: model.tasks,
                        projectName: model.selectedProject?.name ?? "專案"
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            bottomTabs
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .toolbar(.hidden, for: .navigationBar)
    }

    private var workspaceHeader: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .bold))
                    .frame(width: 40, height: 40)
                    .background(Color(uiColor: .secondarySystemBackground), in: Circle())
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(model.selectedProject?.name ?? "專案")
                    .font(.system(size: 17, weight: .bold))
                    .lineLimit(1)

                Text(
                    model.syncState == .ready
                    ? "已同步 · \(model.tasks.count) 項"
                    : model.syncState.title
                )
                    .font(.caption)
                    .foregroundStyle(model.syncState == .ready ? Color.secondary : Color.orange)
            }

            Spacer()

            Button {
                model.refreshNativeData()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .background(Color(uiColor: .secondarySystemBackground), in: Circle())
            }
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(uiColor: .systemBackground))
    }

    private var bottomTabs: some View {
        HStack(spacing: 0) {
            ForEach(WorkspaceTab.allCases) { item in
                Button {
                    tab = item
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: item.icon)
                            .font(.system(size: 18, weight: .semibold))
                        Text(item.rawValue)
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(tab == item ? Color.black : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color(uiColor: .systemBackground))
    }
}

struct NativeGanttView: View {
    let tasks: [GanttTask]

    private let rowHeight: CGFloat = 52
    private let dayWidth: CGFloat = 34
    private let labelWidth: CGFloat = 148

    private var range: ClosedRange<Date>? {
        guard
            let minDate = tasks.map(\.start).min(),
            let maxDate = tasks.map(\.end).max()
        else { return nil }

        let calendar = Calendar.current
        let start = calendar.startOfDay(for: minDate)
        let end = calendar.startOfDay(for: maxDate)

        return start...max(start, end)
    }

    private var days: [Date] {
        guard let range else { return [] }
        let calendar = Calendar.current

        var result: [Date] = []
        var current = range.lowerBound
        let hardLimit = 900

        while current <= range.upperBound && result.count < hardLimit {
            result.append(current)
            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }

        return result
    }

    var body: some View {
        Group {
            if tasks.isEmpty {
                noData
            } else {
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        labelColumn

                        ScrollView(.horizontal, showsIndicators: true) {
                            timeline
                        }
                    }
                }
                .background(Color(uiColor: .systemBackground))
            }
        }
    }

    private var labelColumn: some View {
        VStack(spacing: 0) {
            Text("任務")
                .font(.system(size: 13, weight: .bold))
                .frame(width: labelWidth, height: 42, alignment: .leading)
                .padding(.leading, 10)
                .background(Color(uiColor: .secondarySystemBackground))

            ForEach(tasks) { task in
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.black)
                        .lineLimit(2)

                    Text("\(task.progress)%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(width: labelWidth, height: rowHeight, alignment: .leading)
                .padding(.horizontal, 10)
                .background(Color(uiColor: .systemBackground))
                .overlay(alignment: .bottom) {
                    Divider()
                }
            }
        }
    }

    private var timeline: some View {
        VStack(spacing: 0) {
            LazyHStack(spacing: 0) {
                ForEach(days, id: \.self) { day in
                    VStack(spacing: 2) {
                        Text(day.formatted(.dateTime.month(.abbreviated)))
                            .font(.system(size: 9, weight: .medium))
                        Text(day.formatted(.dateTime.day()))
                            .font(.system(size: 12, weight: .bold))
                    }
                    .foregroundStyle(.black)
                    .frame(width: dayWidth, height: 42)
                    .background(day.isWeekend ? Color.black.opacity(0.04) : Color.clear)
                    .overlay(alignment: .trailing) {
                        Divider()
                    }
                }
            }
            .background(Color(uiColor: .secondarySystemBackground))

            ForEach(tasks) { task in
                TimelineTaskRow(
                    task: task,
                    rangeStart: range?.lowerBound ?? task.start,
                    totalDays: max(days.count, 1),
                    dayWidth: dayWidth,
                    rowHeight: rowHeight
                )
                .frame(width: CGFloat(max(days.count, 1)) * dayWidth, height: rowHeight)
                .overlay(alignment: .bottom) {
                    Divider()
                }
            }
        }
    }

    private var noData: some View {
        VStack(spacing: 14) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)

            Text("尚未取得甘特圖資料")
                .font(.headline)

            Text("系統會自動重試讀取 Brabio。若仍抓不到，畫面上方會顯示偵測結果，方便直接調整解析規則。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TimelineTaskRow: View {
    let task: GanttTask
    let rangeStart: Date
    let totalDays: Int
    let dayWidth: CGFloat
    let rowHeight: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let calendar = Calendar.current
            let startOffset = max(
                calendar.dateComponents([.day], from: rangeStart, to: task.start).day ?? 0,
                0
            )
            let duration = max(
                (calendar.dateComponents([.day], from: task.start, to: task.end).day ?? 0) + 1,
                1
            )

            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(0..<totalDays, id: \.self) { index in
                        Rectangle()
                            .fill(index % 2 == 0 ? Color.clear : Color.black.opacity(0.015))
                            .frame(width: dayWidth)
                            .overlay(alignment: .trailing) {
                                Rectangle()
                                    .fill(Color.black.opacity(0.06))
                                    .frame(width: 0.5)
                            }
                    }
                }

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.black.opacity(0.14))

                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.black.opacity(0.72))
                        .frame(width: max(CGFloat(duration) * dayWidth * task.normalizedProgress, 0))

                    Text("\(task.progress)%")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                }
                .frame(
                    width: max(CGFloat(duration) * dayWidth - 4, 24),
                    height: 24
                )
                .offset(x: CGFloat(startOffset) * dayWidth + 2)
            }
            .frame(width: proxy.size.width, height: rowHeight)
        }
    }
}

struct NativeScheduleView: View {
    let tasks: [GanttTask]
    @State private var selectedDate = Date()

    private var tasksForDay: [GanttTask] {
        let calendar = Calendar.current
        let target = calendar.startOfDay(for: selectedDate)

        return tasks.filter {
            let start = calendar.startOfDay(for: $0.start)
            let end = calendar.startOfDay(for: $0.end)
            return start <= target && target <= end
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                DatePicker(
                    "日期",
                    selection: $selectedDate,
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .tint(.black)
                .padding(.horizontal, 12)
                .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 18))

                VStack(alignment: .leading, spacing: 10) {
                    Text(selectedDate.formatted(date: .long, time: .omitted))
                        .font(.headline)

                    if tasksForDay.isEmpty {
                        Text("這一天沒有排程")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 28)
                    } else {
                        ForEach(tasksForDay) { task in
                            NativeTaskCard(task: task)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 18))
            }
            .padding(12)
        }
    }
}

struct NativeAssigneeView: View {
    let tasks: [GanttTask]

    private var grouped: [(String, [GanttTask])] {
        Dictionary(grouping: tasks, by: \.assignee)
            .map { ($0.key, $0.value) }
            .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
    }

    var body: some View {
        List {
            ForEach(grouped, id: \.0) { assignee, items in
                Section {
                    ForEach(items) { task in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(task.name)
                                .font(.system(size: 15, weight: .semibold))

                            HStack {
                                Text("\(task.progress)%")
                                Spacer()
                                Text(task.start.formatted(date: .abbreviated, time: .omitted))
                                Text("→")
                                Text(task.end.formatted(date: .abbreviated, time: .omitted))
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    HStack {
                        Image(systemName: "person.crop.circle.fill")
                        Text(assignee)
                        Spacer()
                        Text("\(items.count)")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

struct NativeOverviewView: View {
    let tasks: [GanttTask]
    let projectName: String

    private var completed: Int {
        tasks.filter { $0.progress >= 100 }.count
    }

    private var inProgress: Int {
        tasks.filter { $0.progress > 0 && $0.progress < 100 }.count
    }

    private var notStarted: Int {
        tasks.filter { $0.progress <= 0 }.count
    }

    private var averageProgress: Int {
        guard !tasks.isEmpty else { return 0 }
        return Int(tasks.map(\.progress).reduce(0, +) / tasks.count)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(projectName)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.black)

                HStack(spacing: 10) {
                    statCard(title: "總任務", value: "\(tasks.count)", icon: "list.bullet")
                    statCard(title: "完成", value: "\(completed)", icon: "checkmark.circle.fill")
                }

                HStack(spacing: 10) {
                    statCard(title: "進行中", value: "\(inProgress)", icon: "clock.fill")
                    statCard(title: "未開始", value: "\(notStarted)", icon: "circle")
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("整體進度")
                            .font(.headline)
                        Spacer()
                        Text("\(averageProgress)%")
                            .font(.headline)
                    }

                    ProgressView(value: Double(averageProgress), total: 100)
                        .tint(.black)
                        .scaleEffect(x: 1, y: 2, anchor: .center)
                }
                .padding(16)
                .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 18))

                if let next = tasks
                    .filter({ $0.progress < 100 })
                    .sorted(by: { $0.start < $1.start })
                    .first {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("下一個進行項目")
                            .font(.headline)
                        NativeTaskCard(task: next)
                    }
                    .padding(16)
                    .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 18))
                }
            }
            .padding(14)
        }
    }

    private func statCard(title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.black)

            Text(value)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.black)

            Text(title)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct NativeTaskCard: View {
    let task: GanttTask

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(task.name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.black)

            HStack {
                Label(task.assignee, systemImage: "person.fill")
                Spacer()
                Text("\(task.progress)%")
                    .fontWeight(.semibold)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            ProgressView(value: Double(task.progress), total: 100)
                .tint(.black)

            HStack {
                Text(task.start.formatted(date: .abbreviated, time: .omitted))
                Spacer()
                Text(task.end.formatted(date: .abbreviated, time: .omitted))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

private extension Date {
    var isWeekend: Bool {
        Calendar.current.isDateInWeekend(self)
    }
}
