import SwiftUI
import AppKit

struct VoiceInputView: View {
    @ObservedObject var model: MacSpeechInputModel
    @ObservedObject var commands: VoiceCommandModel
    let isPaused: Bool

    var body: some View {
        GroupBox("Mac 设备端语音输入") {
            VStack(alignment: .leading, spacing: 14) {
                Text("主动开始录音，将语音转为可修改的文本。不保存录音，识别结果不会自动执行。")
                    .foregroundStyle(.secondary)
                Text("仅使用设备端识别；当前语言或设备不支持时会明确停止，不回退云端。每次最多录音 60 秒。")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("识别语言", selection: $model.localeIdentifier) {
                    Text("中文（普通话）").tag("zh-CN")
                    Text("English (US)").tag("en-US")
                    Text("Français").tag("fr-FR")
                }
                .disabled(model.isBusy)
                Text(model.permissionSummary).font(.caption)
                HStack {
                    Button("检查并申请语音权限") { Task { await model.requestPermissions() } }
                        .disabled(isPaused || model.isBusy || commands.isBusy)
                    Button("开始录音") { Task { await model.start() } }
                        .disabled(isPaused || model.isBusy || commands.isBusy)
                        .accessibilityIdentifier("voiceStart")
                    Button("停止") { model.stop() }
                        .disabled(!model.isBusy)
                        .accessibilityIdentifier("voiceStop")
                    if model.isBusy {
                        ProgressView().controlSize(.small)
                        Text(model.isRecording ? "正在录音…" : "正在准备…")
                    }
                }
                if isPaused { Text("本地能力已暂停。").foregroundStyle(.orange) }
                if let error = model.error { Text(error).foregroundStyle(.orange) }
                Text("识别预览").font(.headline)
                TextEditor(text: $model.transcript)
                    .font(.body)
                    .frame(minHeight: 180)
                    .border(Color.secondary.opacity(0.3))
                    .disabled(model.isBusy || commands.phase == .executing)
                    .accessibilityIdentifier("voiceTranscript")
                HStack {
                    Button("复制文本") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.transcript, forType: .string)
                    }.disabled(model.transcript.isEmpty || model.isBusy)
                    Button("清空预览") { model.transcript = "" }
                        .disabled(model.transcript.isEmpty || model.isBusy)
                }
                Text("停止、切换页面、窗口失去焦点或全局暂停会结束录音。输入不会自动执行；可在下方分析、核对并确认一项动作。")
                    .font(.caption).foregroundStyle(.secondary)
                VoiceCommandView(model: commands, text: model.transcript, recordingBusy: model.isBusy, isPaused: isPaused)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
        .onAppear { model.setPaused(isPaused) }
        .onChange(of: isPaused) { model.setPaused($0) }
        .onDisappear { model.stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            if model.isRecording || model.phase == .starting { model.stop() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            if model.isRecording || model.phase == .starting { model.stop() }
        }
    }
}
