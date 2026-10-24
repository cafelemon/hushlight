import Foundation
import BridgeCore

enum WorkbenchPage: String, CaseIterable, Identifiable {
    case overview, agents, automationCenter, calendar, music, qqChat, voice, windowVision, volume, timers, reminders, notes, weather, location, mail, permissions, history

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "总览"
        case .agents: "Agent 接入"
        case .automationCenter: "联动中心"
        case .calendar: "日历"
        case .music: "QQ 音乐"
        case .qqChat: "QQ 聊天"
        case .voice: "语音输入"
        case .windowVision: "窗口识别"
        case .volume: "系统音量"
        case .timers: "计时器"
        case .reminders: "提醒事项"
        case .notes: "备忘录"
        case .weather: "天气"
        case .location: "定位"
        case .mail: "Apple Mail"
        case .permissions: "权限"
        case .history: "最近动作"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .agents: "square.stack.3d.up"
        case .automationCenter: "arrow.triangle.branch"
        case .calendar: "calendar"
        case .music: "music.note"
        case .qqChat: "bubble.left.and.bubble.right"
        case .voice: "mic"
        case .windowVision: "viewfinder"
        case .volume: "speaker.wave.2"
        case .timers: "timer"
        case .reminders: "checklist"
        case .notes: "note.text"
        case .weather: "cloud.sun"
        case .location: "location"
        case .mail: "envelope"
        case .permissions: "checkmark.shield"
        case .history: "clock.arrow.circlepath"
        }
    }
}

enum CapabilityActivity: Hashable {
    case refresh, pause, music, qqChat, volume, timers, reminders, notes, weather, location, mail
}

enum BridgeStatus: String, CaseIterable, Sendable {
    case notConfigured
    case connecting
    case online
    case localReady
    case paused
    case unavailable

    var title: String {
        switch self {
        case .notConfigured: "未配置"
        case .connecting: "连接中"
        case .online: "已连接"
        case .localReady: "本地可用"
        case .paused: "已暂停"
        case .unavailable: "不可用"
        }
    }

    var detail: String {
        switch self {
        case .notConfigured: "尚未绑定云端或桌面设备"
        case .connecting: "正在建立安全连接"
        case .online: "可以接收经确认的本地动作"
        case .localReady: "本地执行核心已就绪；云端与设备未连接"
        case .paused: "所有本地动作都会被拒绝"
        case .unavailable: "服务当前不可用，请查看诊断信息"
        }
    }

    var menuBarSymbol: String {
        switch self {
        case .online, .localReady: "sparkles"
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
    case reminders
    case notes, mail, calendar, location

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accessibility: "辅助功能"
        case .automation: "自动化控制"
        case .notifications: "通知"
        case .reminders: "提醒事项"
        case .notes: "备忘录自动化"
        case .mail: "Mail 自动化"
        case .calendar: "日历"
        case .location: "定位"
        }
    }

    var reason: String {
        switch self {
        case .accessibility: "仅在正式适配器无法使用官方接口时申请"
        case .automation: "控制已支持的本地应用前按需申请"
        case .notifications: "展示提醒和动作结果"
        case .notes: "复用系统授权和已记录的专用文件夹，不自动接管同名内容"
        case .mail: "读取和草稿操作限定已选邮箱；发送逐封确认"
        case .calendar: "只管理专用日历与工作台创建的日程"
        case .location: "仅按需获取一次位置；早间天气使用常用城市"
        case .reminders: "仅访问工作台创建的专用列表并管理其中的提醒"
        }
    }
}

enum PermissionState: String, Sendable {
    case notChecked
    case notRequested
    case granted
    case denied

    var title: String {
        switch self {
        case .notChecked: "待核对"
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
    let callerID: String
    let correlationID: String?
    let stableError: String?

    init(
        id: UUID = UUID(),
        name: String,
        outcome: ActionOutcome,
        occurredAt: Date,
        callerID: String = "local_ui",
        correlationID: String? = nil,
        stableError: String? = nil
    ) {
        self.id = id
        self.name = name
        self.outcome = outcome
        self.occurredAt = occurredAt
        self.callerID = callerID
        self.correlationID = correlationID
        self.stableError = stableError
    }
}

struct BridgeSnapshot: Equatable, Sendable {
    let status: BridgeStatus
    let permissions: [PermissionStatus]
    let recentActions: [ActionRecord]
    var timers: [LocalTimerRecord] = []
    var timerError: String? = nil
    var reminders: [LocalReminderRecord] = []
    var reminderError: String? = nil
    var reminderReady = false
    var notesEnabled = false
    var locationAuthorization: LocationAuthorization = .notChecked
}

struct ReminderActionReadback: Equatable, Sendable {
    let outcome: ActionOutcome
    let stableError: String?
    let completedAt: Date

    var message: String {
        guard outcome != .succeeded else { return "提醒事项操作已完成，请以专用列表为准。" }
        switch stableError {
        case "permission_required": return "需要完整提醒事项权限；请在系统设置中允许工作台访问提醒事项。"
        case "bridge_paused": return "本地能力已暂停，请恢复后再管理提醒事项。"
        case "invalid_schema": return "提醒内容或时间无效，或目标不存在、标识重复。"
        case "result_unverifiable", "execution_timeout": return "操作结果无法核实，请刷新专用列表；不要重复创建。"
        case "capability_disabled": return "提醒事项当前不可用，请检查 App 授权与专用列表状态。"
        default: return "提醒事项操作未成功（\(stableError ?? outcome.rawValue)），请刷新专用列表核对。"
        }
    }
}

struct TimerActionReadback: Equatable, Sendable {
    let outcome: ActionOutcome
    let stableError: String?
    let completedAt: Date

    var message: String {
        guard outcome != .succeeded else { return "计时器操作已完成，请以待触发列表为准。" }
        switch stableError {
        case "permission_required": return "需要通知权限；请先允许通知。已拒绝时可在系统设置的通知中开启。"
        case "bridge_paused": return "本地能力已暂停，请恢复后再管理计时器。"
        case "invalid_schema": return "计时器参数无效，或目标已到期、不存在、标识重复。"
        case "result_unverifiable", "execution_timeout": return "操作结果无法核实，请刷新列表；不要重复创建。"
        case "capability_disabled": return "计时器当前不可用，请使用开发 App 并检查通知与存储状态。"
        default: return "计时器操作未成功（\(stableError ?? outcome.rawValue)），请检查列表和错误提示。"
        }
    }
}

struct VolumeReadback: Equatable, Sendable {
    let outcome: ActionOutcome
    let stableError: String?
    let value: Double?
    let muted: Bool?
    let readAt: Date
    var isSimulation: Bool = false

    var errorMessage: String? {
        guard outcome != .succeeded else { return nil }
        switch stableError {
        case "bridge_paused": return "本地能力已暂停，请恢复后再读取。"
        case "capability_disabled": return "当前输出设备不支持主音量读取。"
        case "result_unverifiable": return "无法核对当前音量，请稍后重试。"
        default: return "读取系统音量未成功（\(stableError ?? outcome.rawValue)）。"
        }
    }
}
