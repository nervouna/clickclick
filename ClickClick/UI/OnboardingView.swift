import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "keyboard.badge.ellipsis")
                .font(.system(size: 54))
                .foregroundStyle(.tint)
            VStack(spacing: 8) {
                Text("看见你的按键节奏")
                    .font(.title.bold())
                Text("分别统计 MacBook 内置键盘和每一块外接键盘。")
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 12) {
                PrivacyLine(icon: "text.badge.xmark", title: "不记录文本", detail: "只保存物理键位的聚合次数")
                PrivacyLine(icon: "clock.badge.xmark", title: "不记录顺序", detail: "无法还原你输入的内容")
                PrivacyLine(icon: "icloud.slash", title: "完全本地", detail: "没有账号、服务器或云同步")
            }
            .frame(maxWidth: 380)
            Button("授予输入监控权限") {
                Task { await model.enableCounting(); dismiss() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Button("稍后再说") { dismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(36)
        .frame(width: 500)
    }
}
private struct PrivacyLine: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).frame(width: 26).foregroundStyle(.tint)
            VStack(alignment: .leading) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
