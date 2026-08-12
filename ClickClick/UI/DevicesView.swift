import SwiftUI

struct DevicesView: View {
    @Environment(AppModel.self) private var model
    @State private var drafts: [UUID: String] = [:]
    @State private var deletionTarget: KeyboardDevice?
    @State private var clearingTarget: KeyboardDevice?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("键盘设备").font(.largeTitle.bold())
                Text("分别查看、重命名或合并物理键盘的统计记录。").foregroundStyle(.secondary)
            }
            List {
                ForEach(model.dashboard.devices) { device in
                    HStack(spacing: 14) {
                        Image(systemName: device.isBuiltIn ? "laptopcomputer" : "keyboard")
                            .font(.title2).frame(width: 32).foregroundStyle(device.isConnected ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            TextField(device.name, text: draftBinding(for: device))
                                .textFieldStyle(.plain)
                                .font(.headline)
                                .onSubmit { Task { await model.renameDevice(device.id, to: drafts[device.id] ?? device.name) } }
                            HStack {
                                Text(device.kindLabel)
                                Text(device.isConnected ? "已连接" : "未连接")
                                if device.isHidden { Text("已隐藏") }
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing) {
                            Text(device.totalCount.formatted()).font(.headline).monospacedDigit()
                            Text("累计按键").font(.caption).foregroundStyle(.secondary)
                        }
                        Menu {
                            Button(device.isHidden ? "取消隐藏" : "隐藏") {
                                Task { await model.hideDevice(device.id, hidden: !device.isHidden) }
                            }
                            Menu("合并到…") {
                                ForEach(model.dashboard.devices.filter { $0.id != device.id }) { target in
                                    Button(target.name) { Task { await model.mergeDevice(device.id, into: target.id) } }
                                }
                            }
                            Button("清空该设备统计…") { clearingTarget = device }
                            Divider()
                            Button("删除设备及数据", role: .destructive) { deletionTarget = device }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 28)
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .padding(24)
        .confirmationDialog(
            "删除 \(deletionTarget?.name ?? "")？",
            isPresented: Binding(get: { deletionTarget != nil }, set: { if !$0 { deletionTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除设备及全部历史", role: .destructive) {
                if let id = deletionTarget?.id { Task { await model.deleteDevice(id) } }
                deletionTarget = nil
            }
        } message: {
            Text("该操作无法撤销。设备再次出现时会被当作新设备。")
        }
        .confirmationDialog(
            "清空 \(clearingTarget?.name ?? "") 的统计？",
            isPresented: Binding(get: { clearingTarget != nil }, set: { if !$0 { clearingTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("清空该设备统计", role: .destructive) {
                if let id = clearingTarget?.id { Task { await model.clearCounts(for: id) } }
                clearingTarget = nil
            }
        } message: {
            Text("设备名称和合并关系会保留，所有计数和趋势数据将被永久删除。")
        }
    }

    private func draftBinding(for device: KeyboardDevice) -> Binding<String> {
        Binding(
            get: { drafts[device.id] ?? device.name },
            set: { drafts[device.id] = $0 }
        )
    }
}
