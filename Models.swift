import Foundation

struct ProjectItem: Identifiable, Hashable {
    let name: String
    let href: String?

    var id: String {
        if let href, !href.isEmpty { return href }
        return name
    }
}

struct GanttTask: Identifiable, Hashable {
    let id: String
    let name: String
    let start: Date
    let end: Date
    let progress: Int
    let assignee: String

    var normalizedProgress: Double {
        min(max(Double(progress) / 100.0, 0), 1)
    }
}

struct TaskDetail: Equatable {
    let title: String
    let period: String
    let progress: Int
    let progressOptions: [Int]
    let status: String
    let lastUpdated: String
    let registeredBy: String
    let updatedBy: String
    let content: String
    let members: [String]
    let attachmentInfo: String
    let canEditContent: Bool
}

enum WorkspaceTab: String, CaseIterable, Identifiable {
    case gantt = "甘特圖"
    case schedule = "日程"
    case assignee = "負責狀況"
    case overview = "專案首頁"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .gantt: return "chart.bar.xaxis"
        case .schedule: return "calendar"
        case .assignee: return "person.2.fill"
        case .overview: return "rectangle.grid.2x2.fill"
        }
    }
}

enum SyncState: Equatable {
    case idle
    case syncing
    case ready
    case failed(String)

    var title: String {
        switch self {
        case .idle: return "尚未同步"
        case .syncing: return "同步中…"
        case .ready: return "已同步"
        case .failed(let message): return message
        }
    }
}
