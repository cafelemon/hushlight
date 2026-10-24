import SwiftUI

struct QQChatPreviewView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("在QQ中打开要查看的会话，再点击读取。仅显示当前窗口中可核实的文字。")
            Text("内容仅在本机预览，不提交给AI；离开页面或暂停后清除。本页暂不发送消息。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("读取当前QQ会话") { Task { await model.readQQChatPreview() } }
                    .disabled(model.isPaused || model.isBusy(.pause) || model.isBusy(.qqChat))
                    .accessibilityIdentifier("readQQChatPreview")
                if model.isBusy(.qqChat) { ProgressView().controlSize(.small) }
                Button("清除预览") { model.clearQQChatPreview() }
            }
            if let error = model.qqChatError { Text(error).foregroundStyle(.orange) }
            if let result = model.qqChatReadback {
                GroupBox("当前会话：\(result.conversationTitle)") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("读取时间：\(result.checkedAt.formatted())")
                            .font(.caption).foregroundStyle(.secondary)
                        if result.hasDraft { Text("QQ输入区存在草稿，未展示或修改草稿内容。") }
                        Text("仅为当时可见内容的快照，切换QQ会话后请重新读取。")
                            .font(.caption).foregroundStyle(.secondary)
                        if result.messages.isEmpty { Text("当前可见消息区域没有可核实的文字。") }
                        ForEach(Array(result.messages.enumerated()), id: \.offset) { _, message in
                            VStack(alignment: .leading, spacing: 4) {
                                if let sender = message.sender { Text(sender).font(.caption).foregroundStyle(.secondary) }
                                Text(message.body).textSelection(.enabled)
                            }
                            Divider()
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
            }
        }
    }
}
