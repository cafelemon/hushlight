import BridgeCore
import Foundation
import UserNotifications

protocol NotificationAccess: TimerNotificationScheduling {
    func requestAuthorization() async throws -> Bool
}

enum UserNotificationSchedulerError: LocalizedError, Sendable {
    case requiresAppBundle
    case permissionRequired
    case pastTime
    case readbackFailed

    var errorDescription: String? {
        switch self {
        case .requiresAppBundle: "请在 com.hushlight.bridge.mac 开发版 App 中使用计时器通知。"
        case .permissionRequired: "请先授予通知权限。"
        case .pastTime: "计时器时间必须晚于现在。"
        case .readbackFailed: "系统通知未能完成回读核对，请重试。"
        }
    }
}

private final class ForegroundTimerNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }
}

/// The notification center is never acquired by a SwiftPM executable or test bundle.
actor UserNotificationScheduler: NotificationAccess {
    private static let appBundleIdentifier = "com.hushlight.bridge.mac"
    private static let identifierPrefix = "hushlight.timer."
    private let center: UNUserNotificationCenter?
    private let delegate: ForegroundTimerNotificationDelegate?

    init() {
        if Bundle.main.bundleIdentifier == Self.appBundleIdentifier {
            let center = UNUserNotificationCenter.current()
            let delegate = ForegroundTimerNotificationDelegate()
            center.delegate = delegate
            self.center = center
            self.delegate = delegate
        } else {
            center = nil
            delegate = nil
        }
    }

    func authorizationStatus() async -> TimerNotificationAuthorization {
        guard let center else { return .denied }
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .authorized
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    func requestAuthorization() async throws -> Bool {
        guard let center else { throw UserNotificationSchedulerError.requiresAppBundle }
        return try await center.requestAuthorization(options: [.alert])
    }

    func schedule(_ timer: LocalTimerRecord) async throws {
        guard let center else { throw UserNotificationSchedulerError.requiresAppBundle }
        guard timer.fireAt > Date() else { throw UserNotificationSchedulerError.pastTime }
        guard await authorizationStatus() == .authorized else {
            throw UserNotificationSchedulerError.permissionRequired
        }

        let content = UNMutableNotificationContent()
        content.title = "工作台计时器"
        content.body = timer.label
        let trigger = Self.trigger(fireAt: timer.fireAt)
        let identifier = Self.identifierPrefix + timer.id
        try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))

        let pending = await center.pendingNotificationRequests()
        guard let readback = pending.first(where: { $0.identifier == identifier }),
              readback.content.title == content.title,
              readback.content.body == timer.label,
              let actualTrigger = readback.trigger as? UNCalendarNotificationTrigger,
              !actualTrigger.repeats,
              let actualDate = actualTrigger.nextTriggerDate(),
              abs(actualDate.timeIntervalSince(timer.fireAt)) < 1 else {
            throw UserNotificationSchedulerError.readbackFailed
        }
    }

    func cancel(timerID: String) async throws {
        guard let center else { throw UserNotificationSchedulerError.requiresAppBundle }
        let identifier = Self.identifierPrefix + timerID
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        let pending = await center.pendingNotificationRequests()
        guard !pending.contains(where: { $0.identifier == identifier }) else {
            throw UserNotificationSchedulerError.readbackFailed
        }
    }

    static func trigger(fireAt: Date) -> UNCalendarNotificationTrigger {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: fireAt
        )
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        return UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
    }
}
