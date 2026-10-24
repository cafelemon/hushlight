import Combine
import Foundation
import CoreGraphics

@MainActor
final class WindowVisionModel: ObservableObject {
    @Published private(set) var target: WindowVisionTarget = .qqMusic
    @Published private(set) var windows: [WindowVisionWindow] = []
    @Published private(set) var selectedWindowID: UInt32?
    @Published private(set) var preview: WindowVisionPreview?
    @Published private(set) var selection: CGRect?
    @Published private(set) var result: WindowVisionResult?
    @Published private(set) var isBusy = false
    @Published private(set) var permissionSummary = "屏幕录制权限尚未检查"
    @Published private(set) var error: String?
    @Published var automaticTargetText = "" {
        didSet { if oldValue != automaticTargetText { clear() } }
    }
    @Published private(set) var automaticSummary: String?

    private let backend: any WindowVisionProviding
    private let automaticService: AutomaticWindowSelectionService
    private var generation: UInt64 = 0
    private var paused = false
    private var permissionInFlight = false
    private var listTask: Task<[WindowVisionWindow], Error>?
    private var captureTask: Task<WindowVisionPreview, Error>?
    private var recognitionTask: Task<WindowVisionResult, Error>?
    private var automaticTask: Task<AutomaticWindowSelectionResult, Error>?

    init(backend: any WindowVisionProviding = NativeWindowVisionBackend(),
         selector: any AutomaticWindowTextSelecting = CodexWindowTextSelector()) {
        self.backend = backend
        self.automaticService = AutomaticWindowSelectionService(backend: backend, selector: selector)
    }

    func selectTarget(_ value: WindowVisionTarget) {
        guard value != target else { return }
        clear()
        windows = []
        selectedWindowID = nil
        target = value
    }

    func selectWindow(_ id: UInt32?) {
        clear()
        selectedWindowID = windows.contains(where: { $0.id == id }) ? id : nil
    }

    func setPaused(_ value: Bool) {
        paused = value
        if value { clear() }
    }

    func setSelection(_ rect: CGRect) {
        guard !paused, !isBusy, preview != nil else { return }
        generation &+= 1
        recognitionTask?.cancel()
        recognitionTask = nil
        result = nil
        error = nil
        let bounded = rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        automaticSummary = nil
        selection = bounded.isNull || bounded.isEmpty ? nil : bounded
    }

    /// Release all image/text state and cancel work. An admitted system capture may still finish;
    /// its result is discarded and no new OCR can begin after cancellation.
    func clear() {
        generation &+= 1
        listTask?.cancel(); listTask = nil
        captureTask?.cancel(); captureTask = nil
        recognitionTask?.cancel(); recognitionTask = nil
        automaticTask?.cancel(); automaticTask = nil
        automaticSummary = nil
        preview = nil
        selection = nil
        result = nil
        error = nil
        isBusy = false
    }

    private func finish(_ token: UInt64) {
        guard token == generation else { return }
        listTask = nil; captureTask = nil; recognitionTask = nil
        isBusy = false
    }

    func requestPermission() async {
        guard !paused, !isBusy, !permissionInFlight else { return }
        clear()
        let token = generation
        isBusy = true
        permissionInFlight = true
        let granted = await backend.requestPermission()
        permissionInFlight = false
        guard token == generation, !paused else { return }
        finish(token)
        permissionSummary = granted ? "屏幕录制已授权" : "尚未获得屏幕录制权限，请在系统设置允许后重新检查"
    }

    func loadWindows() async {
        guard !paused, !isBusy, !permissionInFlight else { return }
        clear()
        windows = []
        selectedWindowID = nil
        let token = generation
        let requestedTarget = target
        isBusy = true
        defer { finish(token) }
        let granted = await backend.permissionGranted()
        guard token == generation, !paused, !Task.isCancelled else { return }
        permissionSummary = granted ? "屏幕录制已授权" : "需要在系统设置允许屏幕录制"
        guard granted else {
            error = "请先点击“申请屏幕录制权限”，再检查目标窗口。"
            return
        }
        let operation = Task { try await backend.listWindows(target: requestedTarget) }
        listTask = operation
        do {
            let found = try await withTaskCancellationHandler(operation: { try await operation.value }, onCancel: { operation.cancel() })
            guard token == generation, !paused, !Task.isCancelled else { return }
            guard found.allSatisfy({ $0.target == requestedTarget && $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0 }) else {
                throw WindowVisionModelError.unverified
            }
            windows = found
            if found.isEmpty { error = "未找到目标窗口，请先自行打开所选应用的主窗口。" }
        } catch {
            guard token == generation, !paused, !Task.isCancelled else { return }
            self.error = "未能核实目标窗口。请检查系统权限、应用窗口及系统版本（需 macOS 14.2 或更高版本）。"
        }
    }

    func capturePreview() async {
        guard !paused, !isBusy, !permissionInFlight,
              let window = windows.first(where: { $0.id == selectedWindowID && $0.target == target }) else { return }
        clear()
        let token = generation
        isBusy = true
        defer { finish(token) }
        let operation = Task { try await backend.capturePreview(window: window) }
        captureTask = operation
        do {
            let value = try await withTaskCancellationHandler(operation: { try await operation.value }, onCancel: { operation.cancel() })
            guard token == generation, !paused, !Task.isCancelled else { return }
            guard value.window == window else { throw WindowVisionModelError.unverified }
            preview = value
        } catch {
            guard token == generation, !paused, !Task.isCancelled else { return }
            self.error = (error as? WindowVisionError) == .sharingRestricted
                ? "微信将此窗口标记为不共享，当前无法读取正文；重复申请屏幕录制权限不会解决。详见本地微信排障记录。"
                : "无法核实目标窗口预览。请重新检查窗口或屏幕录制权限。"
        }
    }

    func automaticallyLocate() async {
        guard !paused, !isBusy, !permissionInFlight else { return }
        let goal = automaticTargetText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty, goal.count <= 120 else {
            error = "请输入要定位的歌曲名、群名或其他明确目标（1–120字）。"
            return
        }
        let hadSelection = selectedWindowID != nil
        let chosenWindow = windows.first(where: { $0.id == selectedWindowID })
        let requestedTarget = target
        clear()
        let token = generation
        isBusy = true
        defer { finish(token) }
        let backend = self.backend, service = automaticService
        let operation = Task { [weak self] () async throws -> AutomaticWindowSelectionResult in
            guard await backend.permissionGranted() else { throw WindowVisionError.permissionRequired }
            let found = try await backend.listWindows(target: requestedTarget)
            guard !found.isEmpty, found.allSatisfy({ $0.target == requestedTarget }) else { throw WindowVisionModelError.unverified }
            let selected: WindowVisionWindow
            if hadSelection {
                guard let chosenWindow, found.contains(chosenWindow) else { throw WindowVisionModelError.unverified }
                selected = chosenWindow
            } else if found.count == 1 { selected = found[0] }
            else { throw WindowVisionModelError.multipleWindows }
            return try await service.select(window: selected, targetText: goal, authorize: { [weak self] in
                guard let self else { return false }
                return await self.automaticAuthorized(token: token, target: requestedTarget, text: goal)
            })
        }
        automaticTask = operation
        do {
            let selected = try await withTaskCancellationHandler(operation: { try await operation.value }, onCancel: { operation.cancel() })
            guard automaticAuthorized(token: token, target: requestedTarget, text: goal), !Task.isCancelled else { return }
            windows = [selected.preview.window]
            selectedWindowID = selected.preview.window.id
            preview = selected.preview
            selection = selected.region
            result = selected.result
            permissionSummary = "屏幕录制已授权"
            automaticSummary = "已自动定位目标 · 使用第\(selected.attempts)次窗口识别结果"
        } catch {
            guard token == generation, !paused, !Task.isCancelled else { return }
            if (error as? WindowVisionError) == .permissionRequired {
                self.error = "请先允许屏幕录制，再自动定位目标。"
            } else if (error as? WindowVisionError) == .sharingRestricted {
                self.error = "微信将此窗口标记为不共享，已停止捕获；没有提交文字给AI或执行发送。重复授权不能解除窗口限制。"
            } else if let agentError = error as? CodexAutomationError {
                switch agentError {
                case .rateLimited: self.error = "Codex额度或速率受限，本次未完成AI定位。稍后可重试。"
                case .loginRequired: self.error = "Codex需要重新登录，本次未完成AI定位。"
                case .timedOut, .requestTimedOut: self.error = "Codex分析超时，本次未完成AI定位。"
                default: self.error = "Codex未返回有效的定位结果，没有执行点击或发送。"
                }
            } else if (error as? WindowVisionModelError) == .multipleWindows {
                self.error = "目标应用存在多个窗口，请先选择窗口，再自动定位。无需手动框选。"
            } else {
                self.error = "自动复核后仍无法唯一定位目标。请核对目标文字与窗口内容；没有执行点击或发送。"
            }
        }
    }

    private func automaticAuthorized(token: UInt64, target: WindowVisionTarget, text: String) -> Bool {
        token == generation && !paused && self.target == target &&
            automaticTargetText.trimmingCharacters(in: .whitespacesAndNewlines) == text
    }

    func recognize() async {
        guard !paused, !isBusy, !permissionInFlight, let preview, let selection else { return }
        result = nil
        error = nil
        generation &+= 1
        let token = generation
        isBusy = true
        defer { finish(token) }
        let operation = Task { try await backend.recognize(preview: preview, region: selection) }
        recognitionTask = operation
        do {
            let value = try await withTaskCancellationHandler(operation: { try await operation.value }, onCancel: { operation.cancel() })
            guard token == generation, !paused, !Task.isCancelled else { return }
            guard value.window == preview.window else { throw WindowVisionModelError.unverified }
            result = value
        } catch {
            guard token == generation, !paused, !Task.isCancelled else { return }
            self.error = "未能识别所选预览区域。窗口可能已改变，请重新取得预览并框选。"
        }
    }
}

private enum WindowVisionModelError: Error, Equatable { case unverified, multipleWindows }
