import SwiftUI

struct KeyboardHeatmap: View {
    let counts: [KeyCount]

    private var countMap: [HIDKeyID: Int64] { Dictionary(uniqueKeysWithValues: counts.map { ($0.key, $0.count) }) }
    private var maximum: Double { Double(counts.filter { $0.key.isKeyboardKey }.map(\.count).max() ?? 1) }

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
                let media = counts.filter { $0.key.isConsumerKey }.prefix(8)
                if !media.isEmpty {
                    Divider().padding(.vertical, 6)
                    HStack {
                        ForEach(Array(media)) { item in
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
        let intensity = count == 0 ? 0 : max(0.15, log(Double(count) + 1) / log(maximum + 1))
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
