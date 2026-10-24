import Combine
import Foundation

@MainActor
final class VoiceCommandModel: ObservableObject {
    enum Phase { case idle, analyzing, ready, executing }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var proposal: VoiceCommandAction?
    @Published private(set) var result: VoiceCommandExecutionResult?
    @Published private(set) var error: String?
    @Published private(set) var unresolvedTimerIDs: [UUID] = []

    var isBusy: Bool { phase == .analyzing || phase == .executing }
    private var canExecute: Bool {
        guard !paused, phase == .ready, proposalID != nil, proposalText == input, proposalText == currentInput, let proposal else { return false }
        if case .unsupported = proposal { return false }
        return true
    }

    var canConfirm: Bool {
        if case .songPlay = proposal { return false }
        return canExecute
    }

    private let planner: any VoiceCommandPlanning
    private let executor: any VoiceCommandExecuting
    private let now: @MainActor () -> Date
    private let inputProvider: (@MainActor () -> String)?
    private var inputObservation: AnyCancellable?
    private var currentInput: String { inputProvider?() ?? input }
    private var input = ""
    private var generation: UInt64 = 0
    private var paused = false
    private var proposalID: UUID?
    private var proposalText: String?
    private var proposalAt: Date?
    private var executionID: UUID?
    private var executionText: String?
    private var analysisTask: Task<VoiceCommandAction, Error>?

    init(planner: any VoiceCommandPlanning = SongAwareVoiceCommandPlanner(),
         executor: any VoiceCommandExecuting,
         now: @escaping @MainActor () -> Date = Date.init,
         inputProvider: (@MainActor () -> String)? = nil) {
        self.planner = planner
        self.executor = executor
        self.now = now
        self.inputProvider = inputProvider
    }

    func bindInput(_ publisher: Published<String>.Publisher) {
        inputObservation = publisher.sink { [weak self] text in self?.inputChanged(text) }
    }

    func inputChanged(_ text: String) {
        guard text != input else { return }
        input = text
        invalidatePlanning()
    }

    func invalidatePlanning() {
        generation &+= 1
        analysisTask?.cancel(); analysisTask = nil
        proposal = nil; proposalID = nil; proposalText = nil; proposalAt = nil
        error = nil
        if phase != .executing { phase = .idle }
    }

    func setPaused(_ value: Bool) {
        paused = value
        if value { invalidatePlanning() }
    }

    func analyze(text: String) async {
        guard !paused, phase != .executing, phase != .analyzing else { return }
        guard text == input, text == currentInput else { return }
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, source.count <= 4_000 else {
            error = "请输入 1–4000 字的明确指令。"
            return
        }
        invalidatePlanning()
        let token = generation
        result = nil
        phase = .analyzing
        let operation = Task { try await planner.propose(text: source) }
        analysisTask = operation
        do {
            let action = try await withTaskCancellationHandler(operation: { try await operation.value }, onCancel: { operation.cancel() })
            guard token == generation, !paused, input == text, currentInput == text, !Task.isCancelled else {
                if token == generation { phase = .idle; analysisTask = nil }
                return
            }
            proposal = action
            proposalID = UUID()
            proposalText = text
            proposalAt = now()
            phase = .ready
            if case .songPlay = action { await executeProposal() }
        } catch {
            guard token == generation, !paused else { return }
            self.error = "Codex 未生成可核实的提案，没有执行动作。请检查登录、额度或稍后重试。"
            phase = .idle
        }
        if token == generation { analysisTask = nil }
    }

    func confirm() async {
        guard canConfirm else { return }
        await executeProposal()
    }

    private func executeProposal() async {
        guard canExecute, let action = proposal, let id = proposalID, let created = proposalAt else { return }
        guard now().timeIntervalSince(created) >= 0, now().timeIntervalSince(created) <= 300 else {
            invalidatePlanning()
            error = "提案已过期，请重新分析后核对。"
            return
        }
        let token = generation
        proposalID = nil // Consume before suspension; repeated clicks cannot dispatch again.
        executionID = id
        executionText = proposalText
        phase = .executing
        error = nil
        let value = await executor.execute(id: id, action: action) { [weak self] in
            await self?.allowsExecution(token: token, id: id) ?? false
        }
        guard executionID == id else { return }
        // Preserve an already admitted action's actual outcome, even if pause or navigation occurred.
        result = value
        executionID = nil
        executionText = nil
        proposal = nil; proposalText = nil; proposalAt = nil
        phase = .idle
        await refreshUncertainTimers()
    }

    private func allowsExecution(token: UInt64, id: UUID) -> Bool {
        !paused && generation == token && executionID == id && phase == .executing && executionText == currentInput
    }

    func refreshUncertainTimers() async {
        unresolvedTimerIDs = await executor.unresolvedTimerIDs()
    }

    func acknowledgeUnknown(_ id: UUID) async {
        guard !paused, phase != .executing else { return }
        guard await executor.acknowledgeUnknown(id: id) else {
            error = "未能保存核对结果，未知记录仍保留。"
            return
        }
        await refreshUncertainTimers()
    }
}
