import Foundation
import CryptoKit
import Darwin

struct QQSongPlayResult: Codable, Sendable {
    let requestID: String
    let status: String
    let error: String?
    let playback: QQMusicPlayback?
    var replayed = false
    var displayMessage: String {
        if status == "succeeded" { return "已回读核实播放结果" }
        if status == "unknown" { return "播放结果未知，请先核对QQ实际曲目。不会自动重按。" }
        switch error {
        case "permission_required": return "请在权限页检查辅助功能和屏幕录制授权。"
        case "authorization_changed": return "工作台已暂停或连接授权已变化，本次操作停止。"
        case "app_not_running": return "请先打开QQ音乐，再发出播放指令。"
        case "target_window_unverifiable": return "无法核实QQ主窗口或搜索框，请检查窗口后重试。"
        case "song_not_found": return "未找到能核实的歌曲，请检查歌曲名和歌手。"
        case "song_ambiguous": return "存在多个候选，请补充歌手或版本。"
        case "invalid_schema": return "歌曲名或歌手格式不正确。"
        case "unresolved_playback_requires_review": return "请先核对上一条未知的播放结果。"
        case "execution_in_progress": return "已有播放操作正在处理。"
        case "playback_storage_unavailable": return "无法核实本地执行记录，播放已停止。"
        default: return "本次搜索播放未完成。"
        }
    }
}
struct QQSongPending: Codable, Sendable, Equatable {
    let requestID: String
    let callerID: String
}

/// Stores only identities, action digests and outcomes. No song query or OCR content is persisted.
actor QQSongPlaybackCoordinator {
    private struct Receipt: Codable {
        let requestID: String
        let callerID: String
        let digest: String
        var status: String
        var error: String?
        var attempts: Int
    }
    private let directory: URL
    private let backend: any QQSongSearchPlaying
    private var lockFD: Int32
    private var active: Receipt?
    private var busyKey: String?
    private var healthy = true

    init(directory: URL, backend: any QQSongSearchPlaying) throws {
        self.directory = directory; self.backend = backend
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard chmod(directory.path, 0o700) == 0 else { throw CocoaError(.fileWriteUnknown) }
        let fd = open(directory.appendingPathComponent(".lock").path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(fd); throw QQSongSearchError.busy }
        lockFD = fd
        do {
            let url = directory.appendingPathComponent("active.json")
            if FileManager.default.fileExists(atPath: url.path) {
                var loaded = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: url))
                guard Self.valid(loaded), ["dispatching", "unknown"].contains(loaded.status) else { throw CocoaError(.fileReadCorruptFile) }
                let archivedURL = directory.appendingPathComponent(Self.key(loaded.callerID, loaded.requestID) + ".json")
                if FileManager.default.fileExists(atPath: archivedURL.path) {
                    let terminal = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: archivedURL))
                    guard Self.valid(terminal), terminal.digest == loaded.digest,
                          terminal.requestID == loaded.requestID, terminal.callerID == loaded.callerID,
                          ["succeeded", "failed", "rejected", "acknowledged_unknown"].contains(terminal.status) else { throw CocoaError(.fileReadCorruptFile) }
                    try FileManager.default.removeItem(at: url)
                } else {
                    loaded.status = "unknown"; loaded.error = "interrupted_playback"
                    try Self.write(loaded, to: url)
                    active = loaded
                }
            }
        } catch { healthy = false }
    }
    deinit { if lockFD >= 0 { Darwin.close(lockFD) } }
    func close() {
        guard busyKey == nil else { return }
        if lockFD >= 0 { flock(lockFD, LOCK_UN); Darwin.close(lockFD); lockFD = -1 }
    }
    func pending() -> QQSongPending? { active.map { .init(requestID: $0.requestID, callerID: $0.callerID) } }
    func acknowledge(_ pending: QQSongPending) throws {
        guard healthy, lockFD >= 0, busyKey == nil,
              var receipt = active, receipt.requestID == pending.requestID,
              receipt.callerID == pending.callerID else { throw QQSongSearchError.unauthorized }
        receipt.status = "acknowledged_unknown"
        try terminal(receipt)
    }
    func play(id: String, caller: String, request: QQSongRequest,
              authorize: @escaping @Sendable () async -> Bool) async -> QQSongPlayResult {
        func result(_ status: String, _ error: String? = nil, _ playback: QQMusicPlayback? = nil) -> QQSongPlayResult {
            .init(requestID: id, status: status, error: error, playback: playback)
        }
        guard healthy, lockFD >= 0 else { return result("failed", "playback_storage_unavailable") }
        do { try request.validate() } catch { return result("rejected", "invalid_schema") }
        guard UUID(uuidString: id) != nil, !caller.isEmpty, caller.count <= 128 else { return result("rejected", "invalid_schema") }
        let key = Self.key(caller, id)
        // Use a canonical field encoding; JSON dictionary order is not stable.
        let canonicalDigest = Self.hash(Data([request.title, request.artist ?? "", request.version.rawValue]
            .map { "\($0.utf8.count):\($0)" }.joined().utf8))
        do {
            if let old = try receipt(key: key) {
                guard old.digest == canonicalDigest else { return result("rejected", "request_id_conflict") }
                var cached = result(["acknowledged_unknown", "dispatching"].contains(old.status) ? "unknown" : old.status, old.error)
                cached.replayed = true
                return cached
            }
        } catch { return result("failed", "playback_storage_unavailable") }
        guard active == nil else { return result("rejected", "unresolved_playback_requires_review") }
        guard busyKey == nil else { return result("rejected", "execution_in_progress") }
        busyKey = key
        defer { busyKey = nil }
        let original = Receipt(requestID: id, callerID: caller, digest: canonicalDigest, status: "dispatching", attempts: 0)
        do {
            guard await authorize(), !Task.isCancelled else { throw QQSongSearchError.unauthorized }
            let playback = try await backend.play(request, authorize: authorize, beforePlay: { [weak self] in
                guard await authorize(), !Task.isCancelled, let self else { throw QQSongSearchError.unauthorized }
                try await self.admit(original, key: key)
            })
            guard active != nil else { throw QQSongSearchError.unknownOutcome }
            var receipt = active!; receipt.status = "succeeded"; receipt.error = nil
            try terminal(receipt)
            return result("succeeded", nil, playback)
        } catch {
            let admitted = active != nil
            let known = error as? QQSongSearchError
            let unknown = known == .unknownOutcome || (admitted && known == nil)
            let code: String
            switch known {
            case .permissionRequired: code = "permission_required"
            case .unauthorized: code = "authorization_changed"
            case .notRunning: code = "app_not_running"
            case .unavailableWindow: code = "target_window_unverifiable"
            case .notFound: code = "song_not_found"
            case .ambiguous: code = "song_ambiguous"
            case .invalidInput: code = "invalid_schema"
            default: code = unknown ? "result_unverifiable" : "search_incomplete"
            }
            var receipt = active ?? original
            receipt.status = unknown ? "unknown" : "failed"; receipt.error = code
            do {
                if unknown { try Self.write(receipt, to: activeURL); active = receipt }
                else { try terminal(receipt) }
            } catch { healthy = false; return result(admitted ? "unknown" : "failed", "playback_storage_unavailable") }
            return result(receipt.status, code)
        }
    }

    private func admit(_ original: Receipt, key: String) throws {
        guard healthy, lockFD >= 0, busyKey == key else { throw QQSongSearchError.unauthorized }
        var receipt = active ?? original
        guard receipt.digest == original.digest, receipt.attempts < 2 else { throw QQSongSearchError.unknownOutcome }
        receipt.attempts += 1
        try Self.write(receipt, to: activeURL)
        active = receipt
    }
    private var activeURL: URL { directory.appendingPathComponent("active.json") }
    private func receipt(key: String) throws -> Receipt? {
        if let active, Self.key(active.callerID, active.requestID) == key { return active }
        let url = directory.appendingPathComponent(key + ".json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let value = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: url))
        guard Self.valid(value), Self.key(value.callerID, value.requestID) == key else { throw CocoaError(.fileReadCorruptFile) }
        return value
    }
    private func terminal(_ receipt: Receipt) throws {
        try Self.write(receipt, to: directory.appendingPathComponent(Self.key(receipt.callerID, receipt.requestID) + ".json"))
        if FileManager.default.fileExists(atPath: activeURL.path) {
            try FileManager.default.removeItem(at: activeURL)
            try Self.syncDirectory(directory)
        }
        active = nil
    }
    private static func valid(_ value: Receipt) -> Bool {
        UUID(uuidString: value.requestID) != nil && !value.callerID.isEmpty && value.callerID.count <= 128 &&
        value.digest.count == 64 && (0...2).contains(value.attempts) &&
        ["dispatching", "unknown", "succeeded", "failed", "rejected", "acknowledged_unknown"].contains(value.status)
    }
    private static func key(_ caller: String, _ id: String) -> String { hash(Data("\(caller.utf8.count):\(caller)\(id.lowercased())".utf8)) }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func syncDirectory(_ directory: URL) throws {
        let fd = open(directory.path, O_RDONLY); guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(fd) }; guard fsync(fd) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
    private static func write(_ receipt: Receipt, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: JSONEncoder().encode(receipt)); try handle.synchronize(); try handle.close()
        guard rename(temporary.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        try syncDirectory(url.deletingLastPathComponent())
    }
}
