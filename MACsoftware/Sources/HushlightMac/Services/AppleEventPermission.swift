import AppKit
import CoreServices
import Foundation

enum AppleEventPermission {
    enum Status: Equatable {
        case granted, needsConsent, denied, unavailable
    }

    private static let targetPreparation = AppleEventTargetPreparation(
        isRunning: { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty },
        launch: { bundleID in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.hides = true
            configuration.addsToRecentItems = false
            do {
                _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
                return true
            } catch { return false }
        },
        status: { status(bundleID: $0) })

    /// Used only after a saved scope and an enabled action are known. One hidden launch
    /// per target/process; the subsequent TCC check never asks for consent.
    static func prepareRunningTarget(bundleID: String) async -> Status {
        guard Bundle.main.bundleIdentifier == "com.hushlight.bridge.mac",
              ["com.apple.Notes", "com.apple.mail"].contains(bundleID) else { return .unavailable }
        return await targetPreparation.prepare(bundleID: bundleID)
    }

    /// Apple's no-prompt check requires an already running target. An absent target is unknown.
    static func status(bundleID: String) -> Status {
        guard Bundle.main.bundleIdentifier == "com.hushlight.bridge.mac",
              !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else {
            return .unavailable
        }
        let bytes = Array(bundleID.utf8)
        var address = AEDesc()
        let created = bytes.withUnsafeBytes {
            AECreateDesc(DescType(typeApplicationBundleID), $0.baseAddress, bytes.count, &address)
        }
        guard created == noErr else { return .unavailable }
        defer { AEDisposeDesc(&address) }
        switch AEDeterminePermissionToAutomateTarget(&address, typeWildCard, typeWildCard, false) {
        case noErr: return .granted
        case OSStatus(errAEEventWouldRequireUserConsent): return .needsConsent
        case OSStatus(errAEEventNotPermitted): return .denied
        default: return .unavailable
        }
    }
}

actor AppleEventTargetPreparation {
    private let isRunning: @Sendable (String) -> Bool
    private let launch: @Sendable (String) async -> Bool
    private let status: @Sendable (String) -> AppleEventPermission.Status
    private var launches: [String: Task<Bool, Never>] = [:]

    init(isRunning: @escaping @Sendable (String) -> Bool,
         launch: @escaping @Sendable (String) async -> Bool,
         status: @escaping @Sendable (String) -> AppleEventPermission.Status) {
        self.isRunning = isRunning
        self.launch = launch
        self.status = status
    }

    func prepare(bundleID: String) async -> AppleEventPermission.Status {
        if isRunning(bundleID) { return status(bundleID) }
        if let task = launches[bundleID] {
            _ = await task.value
            return status(bundleID)
        }
        let task = Task { await launch(bundleID) }
        launches[bundleID] = task
        _ = await task.value
        return status(bundleID)
    }
}
