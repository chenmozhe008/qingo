import SwiftUI

/// Single source of truth for top-level navigation in Qingo 5.0 (6 zero-overlap sections).
enum AppDestination: String, CaseIterable, Identifiable, Sendable {
    case overview = "智能体检"
    case spaceLens = "空间透视"
    case clutter = "大文件与重复项"
    case chatAI = "社交与影视创作"
    case devMaintenance = "开发与 AI 工具"
    case apps = "应用与系统维护"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .overview: "sparkles"
        case .spaceLens: "chart.pie.fill"
        case .clutter: "doc.on.doc.fill"
        case .chatAI: "bubble.left.and.bubble.right.fill"
        case .devMaintenance: "hammer.fill"
        case .apps: "slider.horizontal.3"
        }
    }

    var tint: Color {
        switch self {
        case .overview: Theme.blue
        case .spaceLens: Theme.violet
        case .clutter: Theme.indigo
        case .chatAI: Theme.green
        case .devMaintenance: Theme.amber
        case .apps: Theme.orange
        }
    }
}

/// Filter tabs inside 「社交与影视创作」 (cleanly separated from developer AI tools).
enum ChatAITab: String, CaseIterable, Identifiable, Sendable {
    case chat = "聊天与办公"
    case creative = "影视与设计"

    var id: Self { self }
}

/// Sub-tabs inside 「开发与 AI 工具」.
enum DevMaintenanceTab: String, CaseIterable, Identifiable, Sendable {
    case ai = "AI 编程与大模型"
    case projects = "代码工程构建"
    case cli = "包管理与模拟器"

    var id: Self { self }
}

/// Sub-tabs inside 「应用与系统维护」.
enum AppsSystemTab: String, CaseIterable, Identifiable, Sendable {
    case apps = "应用卸载与瘦身"
    case leftovers = "卸载残留与自启"
    case system = "系统快照与修复"

    var id: Self { self }
}

/// Filter tabs inside the dedicated 「文件整理」 page.
enum ClutterTab: String, CaseIterable, Identifiable, Sendable {
    case large = "大文件"
    case installers = "安装包"
    case duplicates = "重复文件"
    case cloud = "iCloud 本地文件"

    var id: Self { self }
}

/// Size/age sub-filter inside 「文件整理 › 大文件」.
enum LargeFileScope: String, CaseIterable, Identifiable, Sendable {
    case all = "全部 ≥ 100 MB"
    case huge = "超大 ≥ 1 GB"
    case stale = "半年未修改"

    var id: Self { self }
}
