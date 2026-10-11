import Foundation

struct HIDKeyID: Hashable, Codable, Sendable, Identifiable {
    let usagePage: UInt16
    let usage: UInt16

    var id: String { "\(usagePage):\(usage)" }
    var isKeyboardKey: Bool { usagePage == 0x07 }
    var isConsumerKey: Bool { usagePage == 0x0C }
    var isCountable: Bool {
        if isKeyboardKey { return usage > 0x03 }
        if isConsumerKey { return usage != 0 }
        return usage != 0
    }
}

struct KeyboardDevice: Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var manufacturer: String?
    var product: String?
    var transport: String?
    var isBuiltIn: Bool
    var isConnected: Bool
    var isHidden: Bool
    var totalCount: Int64

    var kindLabel: String {
        if isBuiltIn { return "内置" }
        switch transport?.lowercased() {
        case let value? where value.contains("bluetooth"): return "蓝牙"
        case let value? where value.contains("usb"): return "USB"
        default: return "外接"
        }
    }
}

struct DeviceDescriptor: Sendable {
    let observedFingerprint: String
    let suggestedName: String
    let manufacturer: String?
    let product: String?
    let vendorID: UInt32
    let productID: UInt32
    let transport: String?
    let isBuiltIn: Bool
}

struct DeviceCount: Identifiable, Hashable, Sendable {
    let deviceID: UUID
    let deviceName: String
    let count: Int64
    var id: UUID { deviceID }
}

struct KeyCount: Identifiable, Hashable, Sendable {
    let key: HIDKeyID
    let count: Int64
    var id: HIDKeyID { key }
}

struct TrendPoint: Identifiable, Hashable, Sendable {
    let date: Date
    let deviceID: UUID
    let deviceName: String
    let count: Int64
    var id: TrendPointID { TrendPointID(bucketStart: date, deviceID: deviceID) }
}

struct TrendPointID: Hashable, Sendable {
    let bucketStart: Date
    let deviceID: UUID
}

enum TrendGranularity: String, CaseIterable, Identifiable, Sendable {
    case minute = "分钟"
    case hour = "小时"
    case day = "天"
    case week = "周"
    case month = "月"

    var id: Self { self }

    var defaultLookback: DateComponents {
        switch self {
        case .minute: return DateComponents(hour: -3)
        case .hour: return DateComponents(day: -7)
        case .day: return DateComponents(day: -90)
        case .week: return DateComponents(weekOfYear: -52)
        case .month: return DateComponents(month: -24)
        }
    }
}

struct StatisticsQuery: Hashable, Sendable, Identifiable {
    let granularity: TrendGranularity
    let deviceID: UUID?
    let currentBucketStart: Date
    let rangeStart: Date
    let rangeEnd: Date
    let calendarIdentifier: Calendar.Identifier
    let timeZoneIdentifier: String
    let localeIdentifier: String
    let firstWeekday: Int
    let minimumDaysInFirstWeek: Int

    var id: Self { self }

    init(
        granularity: TrendGranularity,
        deviceID: UUID?,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) {
        var fixedCalendar = Calendar(identifier: calendar.identifier)
        fixedCalendar.locale = calendar.locale
        fixedCalendar.timeZone = calendar.timeZone
        fixedCalendar.firstWeekday = calendar.firstWeekday
        fixedCalendar.minimumDaysInFirstWeek = calendar.minimumDaysInFirstWeek

        let bucketStart = TimeBuckets.start(of: granularity, for: now, calendar: fixedCalendar)
        let rangeEnd = granularity.nextBucket(after: bucketStart, calendar: fixedCalendar)
        let rangeStart = fixedCalendar.date(
            byAdding: granularity.defaultLookback,
            to: rangeEnd
        ) ?? bucketStart

        self.granularity = granularity
        self.deviceID = deviceID
        currentBucketStart = bucketStart
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        calendarIdentifier = fixedCalendar.identifier
        timeZoneIdentifier = fixedCalendar.timeZone.identifier
        localeIdentifier = fixedCalendar.locale?.identifier ?? Locale.current.identifier
        firstWeekday = fixedCalendar.firstWeekday
        minimumDaysInFirstWeek = fixedCalendar.minimumDaysInFirstWeek
    }

    var calendar: Calendar {
        var value = Calendar(identifier: calendarIdentifier)
        value.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .autoupdatingCurrent
        value.locale = Locale(identifier: localeIdentifier)
        value.firstWeekday = firstWeekday
        value.minimumDaysInFirstWeek = minimumDaysInFirstWeek
        return value
    }

    var fromLocalDay: String {
        TimeBuckets.localDay(for: rangeStart, calendar: calendar)
    }

    var throughLocalDay: String {
        TimeBuckets.localDay(for: rangeEnd.addingTimeInterval(-0.001), calendar: calendar)
    }

    func contains(localDay: String) -> Bool {
        localDay >= fromLocalDay && localDay <= throughLocalDay
    }

    func contains(bucket timestamp: Int64) -> Bool {
        timestamp >= Int64(rangeStart.timeIntervalSince1970)
            && timestamp < Int64(rangeEnd.timeIntervalSince1970)
    }

    /// Every bucket start in `[rangeStart, rangeEnd)`, using the same bucketing as the statistics reader.
    var bucketStarts: [Date] {
        let calendar = calendar
        var starts: [Date] = []
        var cursor = TimeBuckets.start(of: granularity, for: rangeStart, calendar: calendar)
        while cursor < rangeEnd {
            if cursor >= rangeStart { starts.append(cursor) }
            let next = granularity.nextBucket(after: cursor, calendar: calendar)
            guard next > cursor else { break }
            cursor = next
        }
        return starts
    }
}

extension TrendGranularity {
    func nextBucket(after start: Date, calendar: Calendar) -> Date {
        let component: Calendar.Component
        switch self {
        case .minute: component = .minute
        case .hour: component = .hour
        case .day: component = .day
        case .week: component = .weekOfYear
        case .month: component = .month
        }
        return calendar.date(byAdding: component, value: 1, to: start) ?? start
    }
}

struct StatisticsSummary: Equatable, Sendable {
    var total: Int64
    var average: Int64
    var peak: Int64
    var activeDeviceCount: Int

    static let empty = StatisticsSummary(total: 0, average: 0, peak: 0, activeDeviceCount: 0)
}

struct StatisticsSnapshot: Equatable, Sendable {
    let query: StatisticsQuery
    let revision: Int64
    let rangeStart: Date
    let rangeEnd: Date
    let devices: [KeyboardDevice]
    private let allDevices: [KeyboardDevice]
    let trend: [TrendPoint]
    let keyboardRanking: [KeyCount]
    let consumerRanking: [KeyCount]
    let summary: StatisticsSummary
    let heatmapCounts: [HIDKeyID: Int64]
    let heatmapMaximum: Double
    let heatmapMediaCounts: [KeyCount]

    init(
        query: StatisticsQuery,
        revision: Int64,
        devices: [KeyboardDevice],
        trend: [TrendPoint],
        keyCounts: [KeyCount]
    ) {
        let visibleDeviceIDs = Set(devices.lazy.filter { !$0.isHidden }.map(\.id))
        let stableTrend = trend.filter { visibleDeviceIDs.contains($0.deviceID) }.sorted { lhs, rhs in
            lhs.date == rhs.date
                ? lhs.deviceID.uuidString < rhs.deviceID.uuidString
                : lhs.date < rhs.date
        }
        let stableKeys = keyCounts.sorted { lhs, rhs in
            lhs.count == rhs.count ? lhs.key.id < rhs.key.id : lhs.count > rhs.count
        }
        let keyboard = stableKeys.filter { !$0.key.isConsumerKey }
        let consumer = stableKeys.filter { $0.key.isConsumerKey }
        let counts = Dictionary(uniqueKeysWithValues: stableKeys.map { ($0.key, $0.count) })
        let grouped = Dictionary(grouping: stableTrend, by: \.date).mapValues { points in
            points.reduce(Int64(0)) { $0 + $1.count }
        }
        let total = stableTrend.reduce(Int64(0)) { $0 + $1.count }
        let bucketSpan: Int64 = grouped.keys.min().map { first in
            Int64(max(1, query.bucketStarts.lazy.filter { $0 >= first }.count))
        } ?? 0

        self.query = query
        self.revision = revision
        rangeStart = query.rangeStart
        rangeEnd = query.rangeEnd
        allDevices = devices
        self.devices = devices.filter { !$0.isHidden }.sorted { lhs, rhs in
            lhs.isBuiltIn == rhs.isBuiltIn ? lhs.name < rhs.name : lhs.isBuiltIn && !rhs.isBuiltIn
        }
        self.trend = stableTrend
        keyboardRanking = keyboard
        consumerRanking = consumer
        summary = StatisticsSummary(
            total: total,
            average: bucketSpan == 0 ? 0 : total / bucketSpan,
            peak: grouped.values.max() ?? 0,
            activeDeviceCount: Set(stableTrend.map(\.deviceID)).count
        )
        heatmapCounts = counts
        heatmapMaximum = Double(keyboard.map(\.count).max() ?? 1)
        heatmapMediaCounts = Array(consumer.prefix(8))
    }

    func applying(_ result: FlushResult) -> StatisticsSnapshot? {
        guard result.revision == revision + 1 else { return nil }
        guard result.invalidation.scope == .counts else { return nil }
        guard result.invalidation.affects(query) else {
            return StatisticsSnapshot(
                query: query,
                revision: result.revision,
                devices: allDevices,
                trend: trend,
                keyCounts: heatmapCounts.map { KeyCount(key: $0.key, count: $0.value) }
            )
        }

        var updatedDevices = allDevices
        var trendByID = Dictionary(uniqueKeysWithValues: trend.map { ($0.id, $0) })
        var keys = heatmapCounts
        let calendar = query.calendar

        for delta in result.deltas where query.deviceID == nil || query.deviceID == delta.deviceID {
            guard query.contains(localDay: delta.localDay) else { continue }
            guard let deviceIndex = updatedDevices.firstIndex(where: { $0.id == delta.deviceID }) else {
                return nil
            }
            updatedDevices[deviceIndex].totalCount += delta.count
            if updatedDevices[deviceIndex].isHidden { continue }

            let rawDate: Date
            switch query.granularity {
            case .minute:
                guard query.contains(bucket: delta.minuteBucket) else { continue }
                rawDate = Date(timeIntervalSince1970: TimeInterval(delta.minuteBucket))
            case .hour:
                guard query.contains(bucket: delta.hourBucket) else { continue }
                rawDate = Date(timeIntervalSince1970: TimeInterval(delta.hourBucket))
            case .day, .week, .month:
                guard let day = Self.date(fromLocalDay: delta.localDay, calendar: calendar) else { return nil }
                rawDate = day
            }

            let bucket = TimeBuckets.start(of: query.granularity, for: rawDate, calendar: calendar)
            let pointID = TrendPointID(bucketStart: bucket, deviceID: delta.deviceID)
            let current = trendByID[pointID]
            trendByID[pointID] = TrendPoint(
                date: bucket,
                deviceID: delta.deviceID,
                deviceName: updatedDevices[deviceIndex].name,
                count: (current?.count ?? 0) + delta.count
            )
            keys[delta.key, default: 0] += delta.count
        }

        return StatisticsSnapshot(
            query: query,
            revision: result.revision,
            devices: updatedDevices,
            trend: Array(trendByID.values),
            keyCounts: keys.map { KeyCount(key: $0.key, count: $0.value) }
        )
    }

    func affectsVisibleContent(in result: FlushResult) -> Bool {
        guard result.invalidation.affects(query) else { return false }
        guard result.invalidation.scope == .counts else { return true }
        let visibleDeviceIDs = Set(devices.map(\.id))
        return result.deltas.contains { delta in
            visibleDeviceIDs.contains(delta.deviceID)
                && (query.deviceID == nil || query.deviceID == delta.deviceID)
                && query.contains(localDay: delta.localDay)
                && {
                    switch query.granularity {
                    case .minute: query.contains(bucket: delta.minuteBucket)
                    case .hour: query.contains(bucket: delta.hourBucket)
                    case .day, .week, .month: true
                    }
                }()
        }
    }

    private static func date(fromLocalDay value: String, calendar: Calendar) -> Date? {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

typealias StatisticsViewSnapshot = StatisticsSnapshot

struct FlushDelta: Hashable, Sendable {
    let minuteBucket: Int64
    let hourBucket: Int64
    let localDay: String
    let deviceID: UUID
    let key: HIDKeyID
    let count: Int64

    var localMonth: String { String(localDay.prefix(7)) }
}

struct StatisticsInvalidation: Equatable, Sendable {
    enum Scope: Equatable, Sendable {
        case counts
        case full
    }

    let revision: Int64
    let scope: Scope
    let deviceIDs: Set<UUID>
    let minuteBuckets: Set<Int64>
    let hourBuckets: Set<Int64>
    let localDays: Set<String>

    static func counts(revision: Int64, deltas: [FlushDelta]) -> StatisticsInvalidation {
        StatisticsInvalidation(
            revision: revision,
            scope: .counts,
            deviceIDs: Set(deltas.map(\.deviceID)),
            minuteBuckets: Set(deltas.map(\.minuteBucket)),
            hourBuckets: Set(deltas.map(\.hourBucket)),
            localDays: Set(deltas.map(\.localDay))
        )
    }

    static func full(revision: Int64, deviceIDs: Set<UUID> = []) -> StatisticsInvalidation {
        StatisticsInvalidation(
            revision: revision,
            scope: .full,
            deviceIDs: deviceIDs,
            minuteBuckets: [],
            hourBuckets: [],
            localDays: []
        )
    }

    func affects(_ query: StatisticsQuery) -> Bool {
        if scope == .full { return true }
        if let deviceID = query.deviceID, !deviceIDs.contains(deviceID) { return false }
        switch query.granularity {
        case .minute:
            return minuteBuckets.contains { query.contains(bucket: $0) }
        case .hour:
            return hourBuckets.contains { query.contains(bucket: $0) }
        case .day, .week, .month:
            return localDays.contains { query.contains(localDay: $0) }
        }
    }
}

struct FlushResult: Equatable, Sendable {
    let revision: Int64
    let deltas: [FlushDelta]
    let invalidation: StatisticsInvalidation

    static func full(revision: Int64, deviceIDs: Set<UUID> = []) -> FlushResult {
        FlushResult(
            revision: revision,
            deltas: [],
            invalidation: .full(revision: revision, deviceIDs: deviceIDs)
        )
    }
}

enum InputPermissionState: Equatable, Sendable {
    case notRequested
    case granted
    case denied
    case failed(String)

    var title: String {
        switch self {
        case .notRequested: "等待授权"
        case .granted: "统计中"
        case .denied: "未授予输入监控权限"
        case .failed: "监听失败"
        }
    }
}

struct DashboardSnapshot: Equatable, Sendable {
    var todayTotal: Int64 = 0
    var devices: [KeyboardDevice] = []
    var todayByDevice: [DeviceCount] = []

    func visibleDevices(hideZeroCount: Bool) -> [KeyboardDevice] {
        devices.filter { device in
            !device.isHidden && (!hideZeroCount || device.totalCount > 0)
        }
    }

    func visibleTodayCounts(hideZeroCount: Bool) -> [DeviceCount] {
        hideZeroCount ? todayByDevice.filter { $0.count > 0 } : todayByDevice
    }
}

struct RevisionedDashboardSnapshot: Equatable, Sendable {
    let revision: Int64
    let localDay: String
    let snapshot: DashboardSnapshot
}
