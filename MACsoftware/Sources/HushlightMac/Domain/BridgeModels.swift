import Foundation

enum BridgeStatus: String, CaseIterable, Sendable {
    case notConfigured
    case connecting
    case online
    case paused
    case unavailable

    var title: String {
        switch self {
        case .notConfigured: "未配置"
        case .connecting: "连接中"
        case .online: "已连接"
        case .paused: "已暂停"
        case .unavailable: "不可用"
        }
    }

    var detail: String {
        switch self {
        case .notConfigured: "尚未绑定云端或桌面设备"
        case .connecting: "正在建立安全连接"
        case .online: "可以接收经确认的本地动作"
        case .paused: "所有本地动作都会被拒绝"
        case .unavailable: "服务当前不可用，请查看诊断信息"
        }
    }

    var menuBarSymbol: String {
        switch self {
        case .online: "sparkles"
        case .connecting: "arrow.triangle.2.circlepath"
        case .paused: "pause.circle.fill"
        case .unavailable: "exclamationmark.triangle.fill"
        case .notConfigured: "moon.stars"
        }
    }
}

enum PermissionKind: String, CaseIterable, Sendable, Identifiable {
    case accessibility
    case automation
    case notifications

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accessibility: "辅助功能"
        case .automation: "自动化控制"
        case .notifications: "通知"
        }
    }

    var reason: String {
        switch self {
        case .accessibility: "仅在正式适配器无法使用官方接口时申请"
        case .automation: "控制已支持的本地应用前按需申请"
        case .notifications: "展示提醒和动作结果"
        }
    }
}

enum PermissionState: String, Sendable {
    case notRequested
    case granted
    case denied

    var title: String {
        switch self {
        case .notRequested: "未申请"
        case .granted: "已授权"
        case .denied: "已拒绝"
        }
    }
}

struct PermissionStatus: Identifiable, Equatable, Sendable {
    let kind: PermissionKind
    let state: PermissionState

    var id: PermissionKind { kind }
}

enum ActionOutcome: String, Sendable {
    case succeeded
    case failed
    case rejected
    case unknown

    var title: String {
        switch self {
        case .succeeded: "成功"
        case .failed: "失败"
        case .rejected: "已拒绝"
        case .unknown: "结果未知"
        }
    }
}

struct ActionRecord: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let outcome: ActionOutcome
    let occurredAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        outcome: ActionOutcome,
        occurredAt: Date
    ) {
        self.id = id
        self.name = name
        self.outcome = outcome
        self.occurredAt = occurredAt
    }
}

struct BridgeSnapshot: Equatable, Sendable {
    let status: BridgeStatus
    let permissions: [PermissionStatus]
    let recentActions: [ActionRecord]
}
