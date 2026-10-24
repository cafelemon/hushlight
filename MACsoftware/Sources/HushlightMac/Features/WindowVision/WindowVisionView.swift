import SwiftUI
import AppKit

struct WindowVisionView: View {
    @ObservedObject var model: WindowVisionModel
    let isPaused: Bool

    var body: some View {
        GroupBox("目标窗口本地识别") {
            VStack(alignment: .leading, spacing: 14) {
                Text("当辅助功能读不到控件时，按需识别选定窗口。需要 macOS 14.2 或更高版本。")
                    .foregroundStyle(.secondary)
                Text("工作台只读取目标 QQ 或微信窗口。本机 Vision 识别后，点击自动定位会把目标和有界识别文字交给 Codex 分析（使用其已配置模型服务），可能包含窗口内可见的私人文字。截图不上传，识别文字不写入工作台日志。AI选择后再校验位置，失败会刷新纠错一次。")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("目标应用", selection: Binding(get: { model.target }, set: { model.selectTarget($0) })) {
                    ForEach(WindowVisionTarget.allCases, id: \.self) { target in
                        Text(target.title).tag(target)
                    }
                }
                Text(model.permissionSummary).font(.caption)
                HStack {
                    Button("申请屏幕录制权限") { Task { await model.requestPermission() } }
                        .disabled(isPaused || model.isBusy)
                    Button("检查目标窗口") { Task { await model.loadWindows() } }
                        .disabled(isPaused || model.isBusy)
                    if model.isBusy { ProgressView().controlSize(.small) }
                }
                if !model.windows.isEmpty {
                    Picker("选定窗口", selection: Binding(get: { model.selectedWindowID }, set: { model.selectWindow($0) })) {
                        Text("请选择要识别的窗口").tag(Optional<UInt32>.none)
                        ForEach(model.windows) { window in
                            Text("窗口 \(window.id) · \(Int(window.width)) × \(Int(window.height))")
                                .tag(Optional(window.id))
                        }
                    }
                }
                TextField("要定位的目标文字，例如歌曲名或群名", text: $model.automaticTargetText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("windowAutomaticTarget")
                Button("让 AI 自动定位目标") { Task { await model.automaticallyLocate() } }
                    .disabled(isPaused || model.isBusy || model.automaticTargetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("windowAutomaticLocate")
                if let summary = model.automaticSummary { Text(summary).font(.caption).foregroundStyle(.secondary) }
                DisclosureGroup("手动校准（可选）") {
                HStack {
                    Button("取得窗口预览") { Task { await model.capturePreview() } }
                        .disabled(isPaused || model.isBusy || model.selectedWindowID == nil)
                        .accessibilityIdentifier("windowVisionPreview")
                    Button("识别框选区域") { Task { await model.recognize() } }
                        .disabled(isPaused || model.isBusy || model.selection == nil)
                        .accessibilityIdentifier("windowVisionRecognize")
                    Button("清空预览与结果") { model.clear() }
                }
                }
                if isPaused { Text("本地能力已暂停。").foregroundStyle(.orange) }
                if let error = model.error { Text(error).foregroundStyle(.orange) }
                if let preview = model.preview {
                    Text("预览时间：" + preview.checkedAt.formatted()).font(.caption)
                    Text("绿色框为自动定位或手动校准的目标；无需手动拖框。预览与识别有时间点，执行操作前仍需新鲜状态复核。")
                        .font(.caption).foregroundStyle(.secondary)
                    selectionCanvas(preview)
                        .disabled(isPaused || model.isBusy)
                }
                if let result = model.result {
                    Text("识别时间：" + result.checkedAt.formatted()).font(.caption)
                    if result.lines.isEmpty { Text("框选区域内未识别到文本。").foregroundStyle(.secondary) }
                    ForEach(Array(result.lines.enumerated()), id: \.offset) { _, line in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(line.text).textSelection(.enabled)
                            Text("区域：\(line.region) · 置信度：\(confidenceLabel(line.confidence))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("识别结果可能有误，不等同于联系人身份或操作成功。当前仅预览，不点击、不输入、不发送；离开页面或暂停会清除结果。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
        .onAppear { model.setPaused(isPaused) }
        .onChange(of: isPaused) { model.setPaused($0) }
        .onDisappear { model.clear() }
    }

    private func confidenceLabel(_ value: Float) -> String {
        guard value.isFinite else { return "未知" }
        return "\(Int(min(1, max(0, value)) * 100))%"
    }

    private func selectionCanvas(_ preview: WindowVisionPreview) -> some View {
        GeometryReader { geometry in
            let ratio = CGFloat(preview.image.width) / CGFloat(preview.image.height)
            let width = min(max(1, geometry.size.width), 400 * ratio)
            let size = CGSize(width: width, height: width / ratio)
            ZStack(alignment: .topLeading) {
                Image(nsImage: NSImage(cgImage: preview.image, size: size))
                    .resizable().frame(width: size.width, height: size.height)
                if let selection = model.selection {
                    Rectangle().fill(Color.green.opacity(0.15))
                        .overlay(Rectangle().stroke(Color.green, lineWidth: 2))
                        .frame(width: selection.width * size.width, height: selection.height * size.height)
                        .position(x: selection.midX * size.width, y: selection.midY * size.height)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2).onChanged { value in
                if let rect = WindowVisionSelection.normalized(start: value.startLocation, end: value.location, canvas: size) {
                    model.setSelection(rect)
                }
            })
            .accessibilityLabel("目标窗口预览与选定区域；可选手动拖动校准")
        }
        .frame(height: 400)
    }
}

struct WindowVisionSelection {
    static func normalized(start: CGPoint, end: CGPoint, canvas: CGSize) -> CGRect? {
        guard canvas.width.isFinite, canvas.height.isFinite, canvas.width > 0, canvas.height > 0,
              start.x.isFinite, start.y.isFinite, end.x.isFinite, end.y.isFinite,
              (0...canvas.width).contains(start.x), (0...canvas.height).contains(start.y) else { return nil }
        let bounded = CGPoint(x: min(canvas.width, max(0, end.x)), y: min(canvas.height, max(0, end.y)))
        let rect = CGRect(x: min(start.x, bounded.x) / canvas.width,
                          y: min(start.y, bounded.y) / canvas.height,
                          width: abs(start.x - bounded.x) / canvas.width,
                          height: abs(start.y - bounded.y) / canvas.height)
        return rect.isEmpty ? nil : rect
    }
}
