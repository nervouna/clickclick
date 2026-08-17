import SwiftUI

struct KeyboardHeatmap: View {
    let countMap: [HIDKeyID: Int64]
    let maximum: Double
    let mediaCounts: [KeyCount]

    var body: some View {
        GroupBox("物理键位热力图") {
            VStack(spacing: 6) {
                ForEach(Array(KeyCatalog.keyboardRows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 5) {
                        ForEach(row) { key in
                            keyCell(key)
                        }
                    }
                }
                if !mediaCounts.isEmpty {
                    Divider().padding(.vertical, 6)
                    HStack {
                        ForEach(mediaCounts.prefix(8)) { item in
                            VStack(spacing: 3) {
                                Text(KeyCatalog.name(for: item.key)).lineLimit(1)
                                Text(item.count.formatted()).font(.caption2).foregroundStyle(.secondary)
                            }
                            .padding(7)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }
            .padding(.top, 8)
        }
    }

    private func keyCell(_ key: HIDKeyID) -> some View {
        let count = countMap[key] ?? 0
        let scaleMaximum = max(maximum, 1)
        let intensity = count == 0 ? 0 : max(0.15, log(Double(count) + 1) / log(scaleMaximum + 1))
        return VStack(spacing: 2) {
            Text(KeyCatalog.name(for: key)).lineLimit(1).minimumScaleFactor(0.55)
            if count > 0 { Text(count.formatted()).font(.system(size: 8)).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, minHeight: 38)
        .background(Color.accentColor.opacity(intensity * 0.72), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        .help("\(KeyCatalog.name(for: key))：\(count.formatted())")
    }
}
