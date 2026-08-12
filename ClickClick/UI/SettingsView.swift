import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section("权限") {
                HStack {
                    StatusBadge(state: model.permissionState, paused: model.isPaused)
                    Spacer()
                    if model.permissionState != .granted {
                        Button("打开系统设置") { model.openPermissionSettings() }
                    }
                }
            }
            Section("启动") {
                Toggle("登录时启动", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
            }
            Section("显示") {
                Toggle("隐藏输入次数为 0 的设备", isOn: Binding(
                    get: { model.hideZeroCountDevices },
                    set: { model.setHideZeroCountDevices($0) }
                ))
                Text("菜单栏按今日次数判断，详细统计的设备筛选按累计次数判断。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("数据") {
                LabeledContent("分钟数据保留", value: "30 天")
                LabeledContent("小时与按键聚合", value: "永久")
                Button("清空全部统计…", role: .destructive) { confirmClear = true }
            }
            Section("隐私") {
                Text("数据只保存在这台 Mac 上。应用不记录文本、按键顺序、精确事件时间或当前应用。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .confirmationDialog("清空全部统计？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空统计", role: .destructive) { Task { await model.clearAllCounts() } }
        } message: {
            Text("设备名称会保留，所有计数和趋势数据将被永久删除。")
        }
    }
}

struct PrivacyView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("隐私边界").font(.largeTitle.bold())
            Text("咔咔咔咔计数器使用输入监控权限读取物理键位和键盘设备。")
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Label("保存：每块键盘的分钟/小时总量和每日按键次数", systemImage: "checkmark.shield")
                    Label("不保存：文本、按键顺序、组合键内容或窗口信息", systemImage: "xmark.shield")
                    Label("不传输：没有服务器、账号或分析 SDK", systemImage: "icloud.slash")
                }
                .padding(8)
            }
            Spacer()
        }
        .padding(24)
    }
}
