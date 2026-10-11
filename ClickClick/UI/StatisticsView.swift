import Charts
import SwiftUI

struct StatisticsView: View {
    let model: StatisticsViewModel
    let hideZeroCountDevices: Bool

    @State private var section: StatisticsSection = .overview

    var body: some View {
        NavigationSplitView {
            List(StatisticsSection.allCases, selection: $section) { item in
                Label(item.title, systemImage: item.icon).tag(item)
            }
            .navigationTitle("咔咔咔咔")
            .navigationSplitViewColumnWidth(180)
        } detail: {
            detail
        }
        .onAppear { model.setVisible(true) }
        .onDisappear { model.setVisible(false) }
    }

    @ViewBuilder
    private var detail: some View {
        switch section {
        case .overview:
            statisticsOverview
        case .devices:
            DevicesView()
        case .privacy:
            PrivacyView()
        }
    }

    @ViewBuilder
    private var statisticsOverview: some View {
        if let snapshot = model.snapshot {
            OverviewView(
                data: OverviewData(
                    snapshot: snapshot,
                    hideZeroCountDevices: hideZeroCountDevices
                ),
                granularity: Binding(
                    get: { model.granularity },
                    set: { model.setGranularity($0) }
                ),
                selectedDeviceID: Binding(
                    get: { model.selectedDeviceID },
                    set: { model.selectDevice($0) }
                )
            )
            .overlay(alignment: .topTrailing) {
                RefreshStatusOverlay(model: model)
                .padding(16)
            }
        } else {
            InitialLoadStateView(model: model)
        }
    }
}

private enum StatisticsSection: String, CaseIterable, Identifiable {
    case overview, devices, privacy

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "统计"
        case .devices: "键盘设备"
        case .privacy: "隐私"
        }
    }

    var icon: String {
        switch self {
        case .overview: "chart.xyaxis.line"
        case .devices: "keyboard"
        case .privacy: "hand.raised"
        }
    }
}

private struct OverviewData {
    let rangeStart: Date
    let rangeEnd: Date
    let devices: [KeyboardDevice]
    let trend: [TrendPoint]
    let total: Int64
    let average: Int64
    let peak: Int64
    let activeDeviceCount: Int
    let keyboardRanking: [KeyCount]
    let consumerRanking: [KeyCount]
    let heatmapCounts: [HIDKeyID: Int64]
    let heatmapMaximum: Double
    let heatmapMediaCounts: [KeyCount]

    init(snapshot: StatisticsSnapshot, hideZeroCountDevices: Bool) {
        rangeStart = snapshot.rangeStart
        rangeEnd = snapshot.rangeEnd
        devices = hideZeroCountDevices
            ? snapshot.devices.filter { $0.totalCount > 0 }
            : snapshot.devices
        trend = Self.zeroFilledTrend(snapshot.trend, query: snapshot.query)
        total = snapshot.summary.total
        average = snapshot.summary.average
        peak = snapshot.summary.peak
        activeDeviceCount = snapshot.summary.activeDeviceCount
        keyboardRanking = snapshot.keyboardRanking
        consumerRanking = snapshot.consumerRanking
        heatmapCounts = snapshot.heatmapCounts
        heatmapMaximum = snapshot.heatmapMaximum
        heatmapMediaCounts = snapshot.heatmapMediaCounts
    }

    /// Emits a point for every bucket in the range for each device that has data, so charts
    /// do not interpolate across gaps. The snapshot itself stays sparse.
    private static func zeroFilledTrend(_ points: [TrendPoint], query: StatisticsQuery) -> [TrendPoint] {
        guard !points.isEmpty else { return [] }
        var counts: [TrendPointID: Int64] = [:]
        var names: [UUID: String] = [:]
        for point in points {
            counts[point.id] = point.count
            names[point.deviceID] = point.deviceName
        }
        let deviceIDs = names.keys.sorted { $0.uuidString < $1.uuidString }
        let dates = Set(query.bucketStarts).union(points.map(\.date)).sorted()

        var filled: [TrendPoint] = []
        filled.reserveCapacity(dates.count * deviceIDs.count)
        for date in dates {
            for deviceID in deviceIDs {
                filled.append(TrendPoint(
                    date: date,
                    deviceID: deviceID,
                    deviceName: names[deviceID] ?? "",
                    count: counts[TrendPointID(bucketStart: date, deviceID: deviceID)] ?? 0
                ))
            }
        }
        return filled
    }
}

private struct OverviewView: View {
    let data: OverviewData
    @Binding var granularity: TrendGranularity
    @Binding var selectedDeviceID: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                OverviewHeader(
                    rangeStart: data.rangeStart,
                    rangeEnd: data.rangeEnd,
                    devices: data.devices,
                    granularity: $granularity,
                    selectedDeviceID: $selectedDeviceID
                )
                SummaryCards(
                    total: data.total,
                    average: data.average,
                    peak: data.peak,
                    activeDeviceCount: data.activeDeviceCount
                )
                TrendChartView(
                    points: data.trend,
                    domain: data.rangeStart...data.rangeEnd,
                    showsDeviceBreakdown: selectedDeviceID == nil
                )
                HStack(alignment: .top, spacing: 18) {
                    KeyRankingsView(
                        keyboardItems: data.keyboardRanking,
                        consumerItems: data.consumerRanking
                    )
                    .frame(minWidth: 260, maxWidth: 330)

                    KeyboardHeatmap(
                        countMap: data.heatmapCounts,
                        maximum: data.heatmapMaximum,
                        mediaCounts: data.heatmapMediaCounts
                    )
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(24)
        }
        .navigationTitle("详细统计")
    }
}

private struct OverviewHeader: View {
    let rangeStart: Date
    let rangeEnd: Date
    let devices: [KeyboardDevice]
    @Binding var granularity: TrendGranularity
    @Binding var selectedDeviceID: UUID?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("输入趋势").font(.largeTitle.bold())
                Text(rangeDescription).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("设备", selection: $selectedDeviceID) {
                Text("全部键盘").tag(UUID?.none)
                ForEach(devices) { device in
                    Text(device.name).tag(Optional(device.id))
                }
            }
            .frame(width: 190)
            Picker("粒度", selection: $granularity) {
                ForEach(TrendGranularity.allCases) { granularity in
                    Text(granularity.rawValue).tag(granularity)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 330)
        }
    }

    private var rangeDescription: String {
        "\(rangeStart.formatted(date: .abbreviated, time: .shortened)) – \(rangeEnd.formatted(date: .abbreviated, time: .shortened))"
    }
}

private struct SummaryCards: View {
    let total: Int64
    let average: Int64
    let peak: Int64
    let activeDeviceCount: Int

    var body: some View {
        HStack(spacing: 12) {
            MetricCard(title: "总按键数", value: total.formatted(), icon: "keyboard")
            MetricCard(title: "平均每个时间桶", value: average.formatted(), icon: "chart.bar")
            MetricCard(title: "峰值", value: peak.formatted(), icon: "bolt.fill")
            MetricCard(title: "活跃键盘", value: activeDeviceCount.formatted(), icon: "externaldrive.connected.to.line.below")
        }
    }
}

private struct TrendChartView: View {
    let points: [TrendPoint]
    let domain: ClosedRange<Date>
    let showsDeviceBreakdown: Bool

    var body: some View {
        GroupBox {
            if points.isEmpty {
                ContentUnavailableView("这个时间范围还没有数据", systemImage: "chart.xyaxis.line")
                    .frame(height: 260)
            } else if showsDeviceBreakdown {
                Chart(points, id: \.id) { point in
                    AreaMark(
                        x: .value("时间", point.date),
                        y: .value("按键", point.count)
                    )
                    .foregroundStyle(by: .value("键盘", point.deviceName))
                    .interpolationMethod(.monotone)
                }
                .chartXScale(domain: domain)
                .chartLegend(position: .bottom, alignment: .leading)
                .frame(height: 280)
            } else {
                Chart(points, id: \.id) { point in
                    LineMark(
                        x: .value("时间", point.date),
                        y: .value("按键", point.count)
                    )
                    .interpolationMethod(.monotone)
                    if point.count > 0 {
                        PointMark(
                            x: .value("时间", point.date),
                            y: .value("按键", point.count)
                        )
                    }
                }
                .chartXScale(domain: domain)
                .frame(height: 280)
            }
        }
    }
}

private struct KeyRankingsView: View {
    let keyboardItems: [KeyCount]
    let consumerItems: [KeyCount]

    var body: some View {
        VStack(spacing: 18) {
            KeyRankingCard(title: "常用按键", items: keyboardItems, emptyHeight: 220)
            KeyRankingCard(title: "媒体键", items: consumerItems, emptyHeight: 100)
        }
    }
}

private struct KeyRankingCard: View {
    let title: String
    let items: [KeyCount]
    let emptyHeight: CGFloat

    var body: some View {
        GroupBox(title) {
            if items.isEmpty {
                ContentUnavailableView("暂无数据", systemImage: "list.number")
                    .frame(height: emptyHeight)
            } else {
                VStack(spacing: 10) {
                    ForEach(Array(items.prefix(12).enumerated()), id: \.element.id) { index, item in
                        HStack {
                            Text("\(index + 1)")
                                .foregroundStyle(.tertiary)
                                .frame(width: 20, alignment: .trailing)
                            Text(KeyCatalog.name(for: item.key)).lineLimit(1)
                            Spacer()
                            Text(item.count.formatted())
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 8)
            }
        }
    }
}

private struct RefreshStatusOverlay: View {
    let model: StatisticsViewModel

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if model.isLoading {
                Label {
                    Text("正在更新")
                } icon: {
                    ProgressView().controlSize(.small)
                }
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
                .allowsHitTesting(false)
            }
            if let errorMessage = model.errorMessage, !model.isLoading {
                HStack(spacing: 8) {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .lineLimit(2)
                    Button("重试") { model.retry() }
                }
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: 360)
            }
        }
    }
}

private struct InitialLoadStateView: View {
    let model: StatisticsViewModel

    @ViewBuilder
    var body: some View {
        if let errorMessage = model.errorMessage, !model.isLoading {
            ContentUnavailableView {
                Label("无法载入统计", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("重试") { model.retry() }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("详细统计")
        } else {
            ProgressView("正在载入统计…")
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("详细统计")
        }
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
