import Foundation
import BridgeCore
import CryptoKit
import Darwin

enum VoiceCommandOutcome: String, Codable, Sendable {
    case succeeded, failed, denied, unknown
}

struct VoiceCommandExecutionResult: Equatable, Sendable {
    let id: UUID
    let outcome: VoiceCommandOutcome
    let message: String
    let completedAt: Date
    let isSimulation: Bool
    let timerID: String?
}

protocol VoiceCommandExecuting: Sendable {
    func execute(id: UUID, action: VoiceCommandAction,
                 authorize: @escaping @Sendable () async -> Bool) async -> VoiceCommandExecutionResult
    func unresolvedTimerIDs() async -> [UUID]
    func acknowledgeUnknown(id: UUID) async -> Bool
}

/// The journal deliberately stores only an action hash and dispatch state. It never stores voice text,
/// timer labels, weather coordinates, or model output. A dispatching receipt is never replayed.
actor BridgeVoiceCommandExecutor: VoiceCommandExecuting {
    private struct Receipt: Codable {
        let id: UUID
        let actionDigest: String
        var state: String
        let dispatchedAt: Date
    }

    private let bridge: any BridgeService
    private let journalURL: URL
    private let activeLimit: Int
    private var receipts: [Receipt] = []
    private var corrupt = false
    private var activeIDs: Set<UUID> = []
    private var readDigests: [UUID: String] = [:]
    private var timerAdmissionBusy = false

    init(bridge: any BridgeService,
         journalURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hushlight/Bridge/voice-command-journal.json"),
         activeLimit: Int = 256) {
        self.bridge = bridge
        self.journalURL = journalURL
        self.activeLimit = max(1, min(activeLimit, 256))
        if FileManager.default.fileExists(atPath: journalURL.path) {
            do {
                receipts = try JSONDecoder().decode([Receipt].self, from: Data(contentsOf: journalURL))
                guard receipts.count <= 256, Set(receipts.map(\.id)).count == receipts.count,
                      receipts.allSatisfy({ ["dispatching", "succeeded", "failed", "unknown", "acknowledged_unknown"].contains($0.state) }) else {
                    corrupt = true; receipts = []; return
                }
                for i in receipts.indices where receipts[i].state == "dispatching" { receipts[i].state = "unknown" }
            } catch { corrupt = true }
        }
    }

    func execute(id: UUID, action: VoiceCommandAction,
                 authorize: @escaping @Sendable () async -> Bool) async -> VoiceCommandExecutionResult {
        func result(_ outcome: VoiceCommandOutcome, _ message: String, timerID: String? = nil,
                    isSimulation: Bool = false) -> VoiceCommandExecutionResult {
            .init(id: id, outcome: outcome, message: message, completedAt: Date(), isSimulation: isSimulation, timerID: timerID)
        }
        guard Self.valid(action) else { return result(.denied, "指令参数无效，请重新描述。") }
        guard case .unsupported = action else {
            if activeIDs.contains(id) { return result(.unknown, "该指令正在执行，请等待结果；不要重复提交。") }
            activeIDs.insert(id)
            defer { activeIDs.remove(id) }
            return await executeValidated(id: id, action: action, authorize: authorize)
        }
        return result(.denied, "该指令暂不支持。")
    }

    private func executeValidated(id: UUID, action: VoiceCommandAction,
                                  authorize: @escaping @Sendable () async -> Bool) async -> VoiceCommandExecutionResult {
        func result(_ outcome: VoiceCommandOutcome, _ message: String, timerID: String? = nil,
                    isSimulation: Bool = false) -> VoiceCommandExecutionResult {
            .init(id: id, outcome: outcome, message: message, completedAt: Date(), isSimulation: isSimulation, timerID: timerID)
        }
        if case .songPlay(let song) = action {
            do {
                let state = try await bridge.workbenchState()
                guard Self.ready(state), !state.isSimulation, await authorize(), !Task.isCancelled else {
                    return result(.denied, "播放指令已失效、本地能力暂停或正在模拟。", isSimulation: state.isSimulation)
                }
                let played = try await bridge.searchAndPlayQQMusic(id: id.uuidString, request: song, authorize: authorize)
                return result(played.status == "succeeded" ? .succeeded : played.status == "unknown" ? .unknown : .failed,
                              played.displayMessage)
            } catch { return result(.failed, "搜索播放未完成，请检查QQ和音乐页的执行记录。") }
        }
        let digest = Self.digest(action)
        if let prior = readDigests[id] {
            return result(prior == digest ? .unknown : .denied,
                          prior == digest ? "该读取指令已提交，请使用新指令重新读取。" : "指令标识已用于另一项操作，请重新确认。")
        }
        if let receipt = receipts.first(where: { $0.id == id }) {
            guard receipt.actionDigest == digest else { return result(.denied, "指令标识已用于另一项操作，请重新确认。") }
            return result(receipt.state == "succeeded" ? .succeeded : receipt.state == "failed" ? .failed : .unknown,
                          receipt.state == "succeeded" ? "此计时器先前已创建。" : "此指令已处理，不能使用同一标识重试；请核对计时器列表。",
                          timerID: id.uuidString)
        }
        do {
            if let archived = try archivedReceipt(id: id) {
                guard archived.actionDigest == digest else {
                    return result(.denied, "指令标识已用于另一项操作，请重新确认。")
                }
                return result(archived.state == "succeeded" ? .succeeded : archived.state == "failed" ? .failed : .unknown,
                              archived.state == "succeeded" ? "此计时器先前已创建。" : "此指令已处理，不能使用同一标识重试。",
                              timerID: id.uuidString)
            }
        } catch { return result(.denied, "该指令的历史记录无法核对，拒绝重复执行。") }
        if corrupt, case .timerCreate = action { return result(.denied, "计时器记录损坏，创建已暂停；请先处理本地记录。") }
        do {
            let state = try await bridge.workbenchState()
            guard Self.ready(state) else { return result(.denied, "本地能力已暂停或不可用。", isSimulation: state.isSimulation) }
        } catch { return result(.denied, "无法核对本地能力状态。") }
        guard await authorize() else { return result(.denied, "未获得本次人工确认。") }
        do {
            let state = try await bridge.workbenchState()
            guard Self.ready(state) else { return result(.denied, "确认后本地能力状态已改变，请重新确认。", isSimulation: state.isSimulation) }
        } catch { return result(.denied, "确认后无法核对本地能力状态。") }
        guard await authorize() else { return result(.denied, "确认状态已改变，请重新确认。") }

        switch action {
        case .volumeRead:
            readDigests[id] = digest
            do {
                let reading = try await bridge.readSystemVolume()
                guard !reading.isSimulation else { return result(.denied, "模拟结果不能作为真实音量。", isSimulation: true) }
                let latest = try await bridge.workbenchState()
                guard Self.ready(latest), await authorize() else {
                    return result(.denied, "读取期间确认或本地能力状态已改变。", isSimulation: latest.isSimulation)
                }
                switch reading.outcome {
                case .succeeded:
                    guard let value = reading.value, value.isFinite, (0...100).contains(value) else {
                        return result(.unknown, "音量读取结果缺少有效数值。")
                    }
                    return result(.succeeded, "当前系统音量为 \(Int(value.rounded()))%。")
                case .failed, .rejected: return result(.failed, reading.errorMessage ?? "音量读取未成功。")
                case .unknown: return result(.unknown, reading.errorMessage ?? "音量读取结果无法核实。")
                }
            } catch { return result(.failed, "音量读取失败。") }
        case .weatherGet(let cityID):
            readDigests[id] = digest
            do {
                let reading = try await bridge.readWeather(cityID: cityID)
                guard !reading.isSimulation else { return result(.denied, "模拟结果不能作为真实天气。", isSimulation: true) }
                let latest = try await bridge.workbenchState()
                guard Self.ready(latest), await authorize() else {
                    return result(.denied, "查询期间确认或本地能力状态已改变。", isSimulation: latest.isSimulation)
                }
                if reading.status == "succeeded", let report = reading.report, report.city.id == cityID,
                   report.current.temperatureC.isFinite, (-100...100).contains(report.current.temperatureC) {
                    return result(.succeeded, "\(report.city.name)当前气温 \(Int(report.current.temperatureC.rounded()))℃。")
                }
                return result(reading.status == "unknown" ? .unknown : .failed,
                              reading.status == "unknown" ? "天气查询结果无法核实。" : "天气查询未成功。")
            } catch { return result(.failed, "天气查询失败。") }
        case .timerCreate(let label, let seconds):
            return await createTimer(id: id, digest: digest, label: label, seconds: seconds, authorize: authorize)
        case .songPlay:
            return result(.denied, "播放指令未进入执行服务。")
        case .unsupported:
            return result(.denied, "该指令暂不支持。")
        }
    }

    private func createTimer(id: UUID, digest: String, label: String, seconds: Int,
                             authorize: @escaping @Sendable () async -> Bool) async -> VoiceCommandExecutionResult {
        func result(_ outcome: VoiceCommandOutcome, _ message: String, isSimulation: Bool = false) -> VoiceCommandExecutionResult {
            .init(id: id, outcome: outcome, message: message, completedAt: Date(), isSimulation: isSimulation,
                  timerID: outcome == .succeeded || outcome == .unknown ? id.uuidString : nil)
        }
        guard !timerAdmissionBusy else { return result(.denied, "另一项计时器指令正在核对，请稍后重新确认。") }
        timerAdmissionBusy = true
        defer { timerAdmissionBusy = false }
        if receipts.contains(where: { $0.state == "unknown" || $0.state == "dispatching" }) {
            return result(.denied, "有计时器结果仍不明确。请核对待触发列表，再明确允许新的指令。")
        }
        // Archive old terminal receipts before the final state and UI authorization checks.
        do { try retireTerminalReceiptsIfNeeded() }
        catch { return result(.denied, "计时器历史记录无法安全归档，创建已暂停。") }
        guard receipts.count < activeLimit else { return result(.denied, "结果不明的计时器记录已占满容量，请先逐项核对。") }
        guard await authorize() else { return result(.denied, "核对计时器期间确认状态已改变，请重新确认。") }
        do {
            let state = try await bridge.workbenchState()
            guard Self.ready(state) else {
                return result(.denied, "核对计时器期间本地能力状态已改变，请重新确认。", isSimulation: state.isSimulation)
            }
        } catch { return result(.denied, "无法再次核对本地能力状态。") }
        guard await authorize() else { return result(.denied, "核对计时器期间确认状态已改变，请重新确认。") }
        // This timestamp is the final admission point, immediately after the last UI grant.
        let admittedAt = Date()
        receipts.append(.init(id: id, actionDigest: digest, state: "dispatching", dispatchedAt: admittedAt))
        do { try persist() }
        catch {
            receipts[receipts.count - 1].state = "unknown"
            return result(.unknown, "无法确认计时器记录是否写入，未发起创建；请核对列表。")
        }
        let fireAt = admittedAt.addingTimeInterval(TimeInterval(seconds))
        let outcome: VoiceCommandOutcome
        do {
            let readback = try await bridge.createTimer(id: id.uuidString, fireAt: fireAt, label: label)
            switch readback.outcome {
            case .succeeded: outcome = .succeeded
            case .failed, .rejected: outcome = .failed
            case .unknown: outcome = .unknown
            }
        } catch { outcome = .unknown }
        guard let index = receipts.firstIndex(where: { $0.id == id }) else { return result(.unknown, "计时器结果无法核实。") }
        receipts[index].state = outcome.rawValue
        do { try persist() }
        catch {
            receipts[index].state = "unknown"
            return result(.unknown, "计时器可能已创建，但结果记录失败；请核对列表。")
        }
        return result(outcome, outcome == .succeeded ? "计时器已创建，请以待触发列表为准。" :
                      outcome == .failed ? "计时器创建未成功。" : "计时器结果无法核实，请核对待触发列表。")
    }

    func unresolvedTimerIDs() async -> [UUID] {
        return receipts.filter { $0.state == "unknown" || $0.state == "dispatching" }.map(\.id)
    }

    func acknowledgeUnknown(id: UUID) async -> Bool {
        guard !corrupt, let i = receipts.firstIndex(where: { $0.id == id }),
              receipts[i].state == "unknown" else { return false }
        receipts[i].state = "acknowledged_unknown"
        do { try persist(); return true }
        catch { receipts[i].state = "unknown"; return false }
    }

    private static func ready(_ state: WorkbenchServiceState) -> Bool {
        (state.status == "localReady" || state.status == "online") && !state.isSimulation
    }

    private static func valid(_ action: VoiceCommandAction) -> Bool {
        switch action {
        case .songPlay(let song): return (try? song.validate()) != nil
        case .volumeRead: return true
        case .timerCreate(let label, let seconds):
            return !label.isEmpty && label.count <= 80 && label == label.trimmingCharacters(in: .whitespacesAndNewlines)
                && !label.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                && (5...86_400).contains(seconds)
        case .weatherGet(let cityID): return WeatherCities.byID(cityID) != nil
        case .unsupported: return true
        }
    }

    private static func digest(_ action: VoiceCommandAction) -> String {
        let canonical: String
        switch action {
        case .songPlay(let song): canonical = "song:\(song.title.utf8.count):\(song.title):\(song.artist ?? ""):\(song.version.rawValue)"
        case .volumeRead: canonical = "volume_read"
        case .timerCreate(let label, let seconds): canonical = "timer_create:\(seconds):\(label.utf8.count):\(label)"
        case .weatherGet(let cityID): canonical = "weather_get:\(cityID)"
        case .unsupported: canonical = "unsupported"
        }
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private var archiveDirectory: URL {
        journalURL.deletingLastPathComponent().appendingPathComponent("voice-command-receipts", isDirectory: true)
    }

    private func archivedReceipt(id: UUID) throws -> Receipt? {
        let path = archiveDirectory.appendingPathComponent(id.uuidString + ".json")
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: path))
        guard receipt.id == id,
              ["succeeded", "failed", "acknowledged_unknown"].contains(receipt.state),
              receipt.actionDigest.count == 64 else { throw CocoaError(.fileReadCorruptFile) }
        return receipt
    }

    private func retireTerminalReceiptsIfNeeded() throws {
        guard receipts.count >= activeLimit else { return }
        guard let index = receipts.firstIndex(where: { ["succeeded", "failed", "acknowledged_unknown"].contains($0.state) }) else { return }
        let receipt = receipts[index]
        try persistArchive(receipt)
        receipts.remove(at: index)
        do { try persist() }
        catch { receipts.insert(receipt, at: index); throw error }
    }

    private func persistArchive(_ receipt: Receipt) throws {
        let directory = archiveDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard chmod(directory.path, 0o700) == 0 else { throw CocoaError(.fileWriteUnknown) }
        if let existing = try archivedReceipt(id: receipt.id) {
            guard existing.actionDigest == receipt.actionDigest, existing.state == receipt.state,
                  existing.dispatchedAt == receipt.dispatchedAt else { throw CocoaError(.fileReadCorruptFile) }
        } else {
            let destination = directory.appendingPathComponent(receipt.id.uuidString + ".json")
            let temporary = directory.appendingPathComponent(UUID().uuidString)
            let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
            defer { try? FileManager.default.removeItem(at: temporary) }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            do {
                try handle.write(contentsOf: JSONEncoder().encode(receipt))
                try handle.synchronize()
                try handle.close()
            } catch { try? handle.close(); throw error }
            guard link(temporary.path, destination.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        }
        let directoryFD = open(directory.path, O_RDONLY)
        guard directoryFD >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(directoryFD) }
        guard fsync(directoryFD) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    private func persist() throws {
        guard !corrupt else { throw CocoaError(.fileReadCorruptFile) }
        let directory = journalURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard chmod(directory.path, 0o700) == 0 else { throw CocoaError(.fileWriteUnknown) }
        let temporary = directory.appendingPathComponent(UUID().uuidString)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: JSONEncoder().encode(receipts))
            try handle.synchronize()
            try handle.close()
        } catch { try? handle.close(); throw error }
        guard rename(temporary.path, journalURL.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        let directoryFD = open(directory.path, O_RDONLY)
        guard directoryFD >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(directoryFD) }
        guard fsync(directoryFD) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
