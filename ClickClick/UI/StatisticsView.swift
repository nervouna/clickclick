import Charts
import SwiftUI

struct StatisticsView: View {
    @Environment(AppModel.self) private var model
    @State private var section: StatisticsSection = .overview

    var body: some View {
        NavigationSplitView {
            List(StatisticsSection.allCases, selection: $section) { item in
                Label(item.title, systemImage: item.icon).tag(item)
            }
            .navigationTitle("咔咔咔咔")
            .navigationSplitViewColumnWidth(180)
        } detail: {
            Group {
                switch section {
                case .overview: OverviewView()
                case .devices: DevicesView()
                case .privacy: PrivacyView()
                }
            }
            .environment(model)
        }
        .task { await model.refresh() }
    }
}

private enum StatisticsSection: String, CaseIterable, Identifiable {
    case overview, devices, privacy
    var id: Self { self }
    var title: String {
        switch self { case .overview: "统计"; case .devices: "键盘设备"; case .privacy: "隐私" }
    }
    var icon: String {
        switch self { case .overview: "chart.xyaxis.line"; case .devices: "keyboard"; case .privacy: "hand.raised" }
    }
}

private struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("输入趋势").font(.largeTitle.bold())
                        Text(rangeDescription).foregroundStyle(.secondary)
                    }
                    Spacer()
                    devicePicker
                    Picker("粒度", selection: Bindable(model).granularity) {
                        ForEach(TrendGranularity.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 330)
                    .onChange(of: model.granularity) { _, value in Task { await model.setGranularity(value) } }
                }

                summaryCards
                trendChart

                HStack(alignment: .top, spacing: 18) {
                    VStack(spacing: 18) {
                        keyRanking(title: "常用按键", items: model.keyCounts.filter { !$0.key.isConsumerKey })
                        keyRanking(title: "媒体键", items: model.keyCounts.filter { $0.key.isConsumerKey })
                    }
                        .frame(minWidth: 260, maxWidth: 330)
                    KeyboardHeatmap(counts: model.keyCounts)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(24)
        }
        .navigationTitle("详细统计")
    }

    private var devicePicker: some View {
        Picker("设备", selection: Bindable(model).selectedDeviceID) {
            Text("全部键盘").tag(UUID?.none)
            ForEach(model.visibleDevices) { device in
                Text(device.name).tag(Optional(device.id))
            }
        }
        .frame(width: 190)
        .onChange(of: model.selectedDeviceID) { _, value in Task { await model.selectDevice(value) } }
    }

    private var summaryCards: some View {
        let total = model.trend.reduce(Int64(0)) { $0 + $1.count }
        let grouped = Dictionary(grouping: model.trend, by: \.date).mapValues { $0.reduce(Int64(0)) { $0 + $1.count } }
        let peak = grouped.values.max() ?? 0
        let average = grouped.isEmpty ? 0 : total / Int64(grouped.count)
        return HStack(spacing: 12) {
            MetricCard(title: "总按键数", value: total.formatted(), icon: "keyboard")
            MetricCard(title: "平均每个时间桶", value: average.formatted(), icon: "chart.bar")
            MetricCard(title: "峰值", value: peak.formatted(), icon: "bolt.fill")
            MetricCard(title: "活跃键盘", value: Set(model.trend.map(\.deviceID)).count.formatted(), icon: "externaldrive.connected.to.line.below")
        }
    }

    @ViewBuilder
    private var trendChart: some View {
        GroupBox {
            if model.trend.isEmpty {
                ContentUnavailableView("这个时间范围还没有数据", systemImage: "chart.xyaxis.line")
                    .frame(height: 260)
            } else if model.selectedDeviceID == nil {
                Chart(model.trend) { point in
                    AreaMark(
                        x: .value("时间", point.date),
                        y: .value("按键", point.count)
                    )
                    .foregroundStyle(by: .value("键盘", point.deviceName))
                    .interpolationMethod(.monotone)
                }
                .chartLegend(position: .bottom, alignment: .leading)
                .frame(height: 280)
            } else {
                Chart(model.trend) { point in
                    LineMark(
                        x: .value("时间", point.date),
                        y: .value("按键", point.count)
                    )
                    .interpolationMethod(.monotone)
                    PointMark(x: .value("时间", point.date), y: .value("按键", point.count))
                }
                .frame(height: 280)
            }
        }
    }

    private func keyRanking(title: String, items: [KeyCount]) -> some View {
        GroupBox(title) {
            if items.isEmpty {
                ContentUnavailableView("暂无数据", systemImage: "list.number")
                    .frame(height: title == "媒体键" ? 100 : 220)
            } else {
                VStack(spacing: 10) {
                    ForEach(Array(items.prefix(12).enumerated()), id: \.element.id) { index, item in
                        HStack {
                            Text("\(index + 1)").foregroundStyle(.tertiary).frame(width: 20, alignment: .trailing)
                            Text(KeyCatalog.name(for: item.key)).lineLimit(1)
                            Spacer()
                            Text(item.count.formatted()).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    private var rangeDescription: String {
        "\(model.rangeStart.formatted(date: .abbreviated, time: .shortened)) – \(model.rangeEnd.formatted(date: .abbreviated, time: .shortened))"
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.title2.bold()).monospacedDigit()
            }
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }
}
