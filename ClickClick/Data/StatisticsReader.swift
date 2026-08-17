import Foundation

protocol StatisticsSnapshotReading: Sendable {
    func snapshot(for query: StatisticsQuery) async throws -> StatisticsSnapshot
    nonisolated func interrupt()
}

enum StatisticsTrendSource: Equatable, Sendable {
    case minute
    case hour
    case daily
}

struct StatisticsReaderMetrics: Equatable, Sendable {
    var snapshotQueryCount = 0
    var lastQuery: StatisticsQuery?
    var lastTrendSource: StatisticsTrendSource?
    var lastTrendSourceRowCount = 0
    var lastKeyResultCount = 0
}

actor StatisticsReader {
    private let handle: StatisticsReadStoreHandle
    private var readMetrics = StatisticsReaderMetrics()

    init(databaseURL: URL) throws {
        handle = StatisticsReadStoreHandle(store: try SQLiteStore(readOnlyURL: databaseURL))
    }

    nonisolated func interrupt() {
        handle.store.interrupt()
    }

    func snapshot(for query: StatisticsQuery) throws -> StatisticsSnapshot {
        readMetrics.snapshotQueryCount += 1
        readMetrics.lastQuery = query
        let result = try withCancellableRead {
            try handle.store.readTransaction {
                let revision = try handle.store.revision()
                let devices = try handle.store.fetchDevices(connected: [])
                let trendRead = try readTrend(for: query)
                let keys = try handle.store.keyCounts(
                    fromDay: query.fromLocalDay,
                    toDay: query.throughLocalDay,
                    deviceID: query.deviceID
                )
                return (
                    StatisticsSnapshot(
                        query: query,
                        revision: revision,
                        devices: devices,
                        trend: trendRead.points,
                        keyCounts: keys
                    ),
                    trendRead,
                    keys.count
                )
            }
        }
        readMetrics.lastTrendSource = result.1.source
        readMetrics.lastTrendSourceRowCount = result.1.sourceRowCount
        readMetrics.lastKeyResultCount = result.2
        return result.0
    }

    func metrics() -> StatisticsReaderMetrics {
        readMetrics
    }

    func resetMetrics() {
        readMetrics = StatisticsReaderMetrics()
    }

    func dashboard(connected: Set<UUID>) throws -> RevisionedDashboardSnapshot {
        try withCancellableRead {
            let localDay = TimeBuckets.localDay(for: Date())
            return try handle.store.readTransaction {
                RevisionedDashboardSnapshot(
                    revision: try handle.store.revision(),
                    localDay: localDay,
                    snapshot: try handle.store.dashboard(
                        connected: connected,
                        localDay: localDay
                    )
                )
            }
        }
    }

    func trend(
        granularity: TrendGranularity,
        from: Date,
        to: Date,
        deviceID: UUID?,
        calendar: Calendar
    ) throws -> [TrendPoint] {
        try withCancellableRead {
            try handle.store.readTransaction {
                try readTrend(
                    granularity: granularity,
                    from: from,
                    to: to,
                    fromDay: TimeBuckets.localDay(for: from, calendar: calendar),
                    toDay: TimeBuckets.localDay(for: to.addingTimeInterval(-0.001), calendar: calendar),
                    deviceID: deviceID,
                    calendar: calendar
                ).points
            }
        }
    }

    func keyCounts(
        from: Date,
        to: Date,
        deviceID: UUID?,
        calendar: Calendar
    ) throws -> [KeyCount] {
        try withCancellableRead {
            try handle.store.readTransaction {
                try handle.store.keyCounts(
                    fromDay: TimeBuckets.localDay(for: from, calendar: calendar),
                    toDay: TimeBuckets.localDay(for: to.addingTimeInterval(-0.001), calendar: calendar),
                    deviceID: deviceID
                )
            }
        }
    }

    private func readTrend(for query: StatisticsQuery) throws -> TrendRead {
        try readTrend(
            granularity: query.granularity,
            from: query.rangeStart,
            to: query.rangeEnd,
            fromDay: query.fromLocalDay,
            toDay: query.throughLocalDay,
            deviceID: query.deviceID,
            calendar: query.calendar
        )
    }

    private func readTrend(
        granularity: TrendGranularity,
        from: Date,
        to: Date,
        fromDay: String,
        toDay: String,
        deviceID: UUID?,
        calendar: Calendar
    ) throws -> TrendRead {
        var grouped: [TrendPointID: Int64] = [:]
        var names: [UUID: String] = [:]
        let source: StatisticsTrendSource
        let sourceRowCount: Int

        switch granularity {
        case .minute, .hour:
            let rows = try handle.store.trendRows(
                from: from,
                to: to,
                minute: granularity == .minute,
                deviceID: deviceID
            )
            source = granularity == .minute ? .minute : .hour
            sourceRowCount = rows.count
            for row in rows {
                try Task.checkCancellation()
                let rawDate = Date(timeIntervalSince1970: TimeInterval(row.0))
                let bucket = TimeBuckets.start(of: granularity, for: rawDate, calendar: calendar)
                grouped[TrendPointID(bucketStart: bucket, deviceID: row.1), default: 0] += row.3
                names[row.1] = row.2
            }

        case .day, .week, .month:
            let rows = try handle.store.dailyTrendRows(
                fromDay: fromDay,
                toDay: toDay,
                deviceID: deviceID
            )
            source = .daily
            sourceRowCount = rows.count
            for row in rows {
                try Task.checkCancellation()
                guard let rawDate = Self.date(fromLocalDay: row.localDay, calendar: calendar) else {
                    continue
                }
                let bucket = TimeBuckets.start(of: granularity, for: rawDate, calendar: calendar)
                grouped[TrendPointID(bucketStart: bucket, deviceID: row.deviceID), default: 0] += row.count
                names[row.deviceID] = row.deviceName
            }
        }

        var points: [TrendPoint] = []
        points.reserveCapacity(grouped.count)
        for (identifier, count) in grouped {
            points.append(TrendPoint(
                date: identifier.bucketStart,
                deviceID: identifier.deviceID,
                deviceName: names[identifier.deviceID] ?? "未知键盘",
                count: count
            ))
        }
        points.sort { lhs, rhs in
            lhs.date == rhs.date
                ? lhs.deviceID.uuidString < rhs.deviceID.uuidString
                : lhs.date < rhs.date
        }
        return TrendRead(points: points, source: source, sourceRowCount: sourceRowCount)
    }

    private func withCancellableRead<T>(_ body: () throws -> T) throws -> T {
        handle.store.installProgressHandler(every: 512) {
            Task.isCancelled
        }
        defer { handle.store.clearProgressHandler() }

        do {
            try Task.checkCancellation()
            let value = try body()
            try Task.checkCancellation()
            return value
        } catch {
            if Task.isCancelled || error is CancellationError {
                throw CancellationError()
            }
            throw error
        }
    }

    private static func date(fromLocalDay value: String, calendar: Calendar) -> Date? {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(
            from: DateComponents(year: parts[0], month: parts[1], day: parts[2])
        )
    }
}

private struct TrendRead {
    let points: [TrendPoint]
    let source: StatisticsTrendSource
    let sourceRowCount: Int
}

extension StatisticsReader: StatisticsSnapshotReading {}

private final class StatisticsReadStoreHandle: @unchecked Sendable {
    let store: SQLiteStore

    init(store: SQLiteStore) {
        self.store = store
    }
}
