import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("今日按键")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(model.dashboard.todayTotal.formatted())
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                }
                Spacer()
                StatusBadge(state: model.permissionState, paused: model.isPaused)
            }

            if model.permissionState != .granted {
                PermissionCard(compact: true)
            } else if model.visibleTodayDeviceCounts.isEmpty {
                ContentUnavailableView("还没有按键记录", systemImage: "keyboard", description: Text("开始打字后会在这里显示设备贡献。"))
                    .frame(height: 130)
            } else {
                VStack(spacing: 8) {
                    ForEach(model.visibleTodayDeviceCounts.prefix(4)) { item in
                        HStack {
                            Circle().fill(color(for: item.deviceID)).frame(width: 8, height: 8)
                            Text(item.deviceName).lineLimit(1)
                            Spacer()
                            Text(item.count.formatted()).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }

            Divider()
            HStack {
                Button(model.isPaused ? "继续统计" : "暂停统计", systemImage: model.isPaused ? "play.fill" : "pause.fill") {
                    Task { await model.togglePaused() }
                }
                .disabled(model.permissionState != .granted)

                Spacer()
                SettingsLink {
                    Label("设置", systemImage: "gearshape")
                }
                Button("详细统计", systemImage: "chart.xyaxis.line") {
                    openWindow(id: "statistics")
                    NSApplication.shared.activate()
                }
                Button("退出") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 390)
        .sheet(isPresented: Binding(
            get: { model.showingOnboarding },
            set: { model.showingOnboarding = $0 }
        )) {
            OnboardingView()
                .environment(model)
        }
    }

    private func color(for id: UUID) -> Color {
        let palette: [Color] = [.blue, .purple, .orange, .green, .pink, .cyan]
        return palette[abs(id.hashValue) % palette.count]
    }
}

struct StatusBadge: View {
    let state: InputPermissionState
    let paused: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(paused ? "已暂停" : state.title)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary, in: Capsule())
    }

    private var color: Color {
        if paused { return .secondary }
        switch state {
        case .granted: return Color.green
        case .notRequested: return Color.blue
        case .denied, .failed: return Color.orange
        }
    }
}

struct PermissionCard: View {
    @Environment(AppModel.self) private var model
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("需要输入监控权限", systemImage: "hand.raised.fill")
                .font(.headline)
            Text("咔咔咔咔计数器只会在本地保存按键次数，不保存文本、顺序或当前应用。")
                .font(compact ? .caption : .body)
                .foregroundStyle(.secondary)
            HStack {
                if model.permissionState == .notRequested {
                    Button("启用统计") { Task { await model.enableCounting() } }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("打开系统设置") { model.openPermissionSettings() }
                    Button("重新检查") { Task { await model.recheckPermission() } }
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
    }
}
