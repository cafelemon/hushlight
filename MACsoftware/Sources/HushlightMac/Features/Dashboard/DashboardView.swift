import SwiftUI

struct DashboardView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List {
                Label("状态", systemImage: "circle.grid.2x2")
                Label("权限", systemImage: "checkmark.shield")
                Label("最近动作", systemImage: "clock.arrow.circlepath")
            }
            .navigationTitle("小熙")
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    statusCard
                    permissionsCard
                    recentActionsCard
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .task {
            await model.refresh()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Mac 连接中心")
                .font(.largeTitle.bold())
            Text("让小熙在获得授权后，安全地连接这台 Mac。")
                .foregroundStyle(.secondary)
        }
    }

    private var statusCard: some View {
        GroupBox {
            HStack(spacing: 16) {
                Image(systemName: model.status.menuBarSymbol)
                    .font(.system(size: 30))
                    .foregroundStyle(statusColor)
                    .frame(width: 48, height: 48)
                    .background(statusColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))

                VStack(alignment: .leading, spacing: 4) {
                    Text(model.status.title)
                        .font(.title3.bold())
                    Text(model.status.detail)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(model.isPaused ? "恢复" : "暂停本地能力") {
                    Task { await model.togglePause() }
                }
                .buttonStyle(.borderedProminent)
            }

            if let message = model.lastErrorMessage {
                Divider()
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        } label: {
            Label("Bridge 状态", systemImage: "link")
        }
    }

    private var permissionsCard: some View {
        GroupBox {
            VStack(spacing: 0) {
                ForEach(Array(model.permissions.enumerated()), id: \.element.id) { index, permission in
                    if index > 0 { Divider() }
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: permission.state == .granted ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(permission.state == .granted ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(permission.kind.title).fontWeight(.medium)
                            Text(permission.kind.reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(permission.state.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 10)
                }
            }
        } label: {
            Label("权限", systemImage: "checkmark.shield")
        }
    }

    private var recentActionsCard: some View {
        GroupBox {
            if model.recentActions.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "clock")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text("还没有本地动作")
                        .font(.headline)
                    Text("真实适配器接入后，这里只展示实际返回的结果。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.recentActions) { action in
                        HStack {
                            Text(action.name)
                            Spacer()
                            Text(action.outcome.title)
                                .foregroundStyle(.secondary)
                            Text(action.occurredAt, style: .time)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
        } label: {
            Label("最近动作", systemImage: "clock.arrow.circlepath")
        }
    }

    private var statusColor: Color {
        switch model.status {
        case .online: .green
        case .connecting: .blue
        case .paused: .orange
        case .unavailable: .red
        case .notConfigured: .secondary
        }
    }
}

struct MenuBarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(model.status.title, systemImage: model.status.menuBarSymbol)
                .font(.headline)
            Text(model.status.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 240, alignment: .leading)
            Divider()
            Button(model.isPaused ? "恢复本地能力" : "暂停本地能力") {
                Task { await model.togglePause() }
            }
            Divider()
            Button("退出小熙") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(12)
    }
}
