import SwiftUI

struct VoiceCommandView: View {
    @ObservedObject var model: VoiceCommandModel
    let text: String
    let recordingBusy: Bool
    let isPaused: Bool

    var body: some View {
        GroupBox("处理文字或语音指令") {
            VStack(alignment: .leading, spacing: 12) {
                Text("支持读取系统音量、创建相对计时器、指定城市天气及QQ歌曲播放。一次一项；例如“播放周杰伦的晴天”。")
                Text("点击处理会提交上方文本给独立 Codex 会话。明确歌曲指令会直接搜索播放，不额外确认；其他动作先核对提案。Codex没有执行工具，所有执行均由工作台核验。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("处理这条指令") {
                        model.inputChanged(text)
                        Task { await model.analyze(text: text) }
                    }
                        .disabled(isPaused || recordingBusy || model.isBusy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if model.phase == .analyzing {
                        ProgressView().controlSize(.small)
                        Button("取消分析") { model.invalidatePlanning() }
                    }
                }
                if let proposal = model.proposal {
                    Text(proposal.reviewDescription).fontWeight(.medium)
                    Text("计时器时长从确认执行时开始计算；提案五分钟后失效。修改输入会使旧提案失效。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("确认执行此动作") { Task { await model.confirm() } }
                        .disabled(isPaused || recordingBusy || !model.canConfirm)
                        .accessibilityIdentifier("voiceConfirmAction")
                }
                if model.phase == .executing { Text("正在执行，请勿重复提交…").foregroundStyle(.secondary) }
                if let error = model.error { Text(error).foregroundStyle(.orange) }
                if let result = model.result {
                    Text(result.message).foregroundStyle(result.outcome == .succeeded ? Color.primary : Color.orange)
                    Text("请求：\(result.id.uuidString) · \(result.completedAt.formatted())").font(.caption)
                    if result.isSimulation { Text("模拟结果").foregroundStyle(.orange) }
                }
                if !model.unresolvedTimerIDs.isEmpty {
                    Text("存在结果未知的计时器请求。请先在“计时器”页核对；不会自动重建。")
                        .foregroundStyle(.orange)
                    ForEach(model.unresolvedTimerIDs, id: \.self) { id in
                        VStack(alignment: .leading) {
                            Text(id.uuidString).font(.caption)
                            Button("我已人工核对，保留未知记录并允许新指令") {
                                Task { await model.acknowledgeUnknown(id) }
                            }.disabled(isPaused || model.phase == .executing)
                        }
                    }
                }
                Button("检查语音计时器记录") { Task { await model.refreshUncertainTimers() } }
                    .disabled(model.phase == .executing)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
        .onAppear { model.inputChanged(text); model.setPaused(isPaused) }
        .onChange(of: text) { model.inputChanged($0) }
        .onChange(of: isPaused) { model.setPaused($0) }
        .onDisappear { model.invalidatePlanning() }
    }
}
