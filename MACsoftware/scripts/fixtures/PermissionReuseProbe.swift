import AppKit
import CoreServices
import Foundation
import SwiftUI

@MainActor
final class ProbeModel: ObservableObject {
    @Published var status = "待核对"
    @Published var busy = false
    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    private let evidenceURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Hushlight/Development/permission-probe.json")

    func inspect(request: Bool = false) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        if (request || version == "2") && NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Notes").isEmpty {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Notes") else { record("target_unavailable", requested: false); return }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false; config.hides = true; config.addsToRecentItems = false
            do { _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config) }
            catch { record("target_unavailable", requested: false); return }
        }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Notes").isEmpty else {
            record("target_not_running", requested: false); return
        }
        var address = AEDesc()
        let bytes = Array("com.apple.Notes".utf8)
        let created = bytes.withUnsafeBytes { AECreateDesc(DescType(typeApplicationBundleID), $0.baseAddress, bytes.count, &address) }
        guard created == noErr else { record("unavailable", requested: false); return }
        defer { AEDisposeDesc(&address) }
        // Only the user's explicit button can set askUserIfNeeded=true. No event reads note contents.
        let result = AEDeterminePermissionToAutomateTarget(&address, typeWildCard, typeWildCard, request)
        switch result {
        case noErr: record("granted", requested: request)
        case OSStatus(errAEEventWouldRequireUserConsent): record("needs_consent", requested: request)
        case OSStatus(errAEEventNotPermitted): record("denied", requested: request)
        default: record("unavailable", requested: request)
        }
    }

    private func record(_ value: String, requested: Bool) {
        let labels = ["granted": "已授权（本次系统核对）", "needs_consent": "尚未授权，请点击下方按钮", "denied": "系统已拒绝，需在系统设置修复", "target_not_running": "系统备忘录未运行，请点击下方按钮进行测试", "target_unavailable": "无法启动系统备忘录", "unavailable": "系统状态无法核实"]
        status = labels[value] ?? value
        do {
            let folder = evidenceURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            let data = try JSONSerialization.data(withJSONObject: ["version": 1, "build": version, "compiledBuild": probeBuildIdentity, "checkedAt": ISO8601DateFormatter().string(from: Date()), "notesAutomation": value, "requestedByButton": requested], options: [.sortedKeys, .prettyPrinted])
            try data.write(to: evidenceURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: evidenceURL.path)
        } catch { status += "；证据保存失败" }
    }
}

@main
struct PermissionReuseProbe: App {
    @StateObject private var model = ProbeModel()
    var body: some Scene {
        WindowGroup("工作台权限复用测试") {
            VStack(alignment: .leading, spacing: 16) {
                Text("独立签名测试包").font(.title2.bold())
                Text("这只测试系统是否记住同一签名应用的备忘录自动化授权。不读取笔记正文、不创建文件夹、不接管工作台权限。")
                Text("构建版本：" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"))
                Text(model.status).fontWeight(.medium).accessibilityIdentifier("permissionProbeStatus")
                HStack {
                    Button("申请本测试包的备忘录权限") { Task { await model.inspect(request: true) } }
                        .disabled(model.busy).accessibilityIdentifier("requestProbePermission")
                    Button("仅核对，不申请") { Task { await model.inspect() } }.disabled(model.busy)
                }
                Text("首次测试需要你亲自处理 macOS 授权提示。之后重建版本 2，再检查是否直接显示已授权。这个结果只覆盖 Notes 自动化，不代表其他权限全部通过。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(24).frame(width: 580).task { await model.inspect() }
        }.defaultSize(width: 620, height: 330)
    }
}
