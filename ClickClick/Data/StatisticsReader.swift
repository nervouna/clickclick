import Foundation

protocol StatisticsSnapshotReading: Sendable {
    func snapshot(for query: StatisticsQuery) async throws -> StatisticsSnapshot
    nonisolated func interrupt()
}

actor StatisticsReader {
    private let handle: StatisticsReadStoreHandle

    init(databaseURL: URL) throws {
        handle = StatisticsReadStoreHandle(store: try SQLiteStore(readOnlyURL: databaseURL))
    }

    nonisolated func interrupt() {
        handle.store.interrupt()
    }

    func snapshot(for query: StatisticsQuery) throws -> StatisticsSnapshot {
        try withCancellableRead {
            try handle.store.readTransaction {
                StatisticsSnapshot(
                    query: query,
                    devices: try handle.store.fetchDevices(connected: []),
                    trend: try readTrend(for: query),
                    keyCounts: try handle.store.keyCounts(
                        fromDay: query.fromLocalDay,
                        toDay: query.throughLocalDay,
                        deviceID: query.deviceID
                    )
                )
            }
        }
    }

    func dashboard(connected: Set<UUID>) throws -> DashboardSnapshot {
        try withCancellableRead {
            try handle.store.readTransaction {
                try handle.store.dashboard(connected: connected)
            }
        }
    }

    private func readTrend(for query: StatisticsQuery) throws -> [TrendPoint] {
        let granularity = query.granularity
        let calendar = query.calendar
        var grouped: [TrendPointID: Int64] = [:]
        var names: [UUID: String] = [:]

        switch granularity {
        case .minute, .hour:
            let rows = try handle.store.trendRows(
                from: query.rangeStart,
                to: query.rangeEnd,
                minute: granularity == .minute,
                deviceID: query.deviceID
            )
            for row in rows {
                try Task.checkCancellation()
                let rawDate = Date(timeIntervalSince1970: TimeInterval(row.0))
                let bucket = TimeBuckets.start(of: granularity, for: rawDate, calendar: calendar)
                grouped[TrendPointID(bucketStart: bucket, deviceID: row.1), default: 0] += row.3
                names[row.1] = row.2
            }

        case .day, .week, .month:
            let rows = try handle.store.dailyTrendRows(
                fromDay: query.fromLocalDay,
                toDay: query.throughLocalDay,
                deviceID: query.deviceID
            )
            for row in rows {
                try Task.checkCancellation()
                guard let rawDate = TimeBuckets.date(fromLocalDay: row.localDay, calendar: calendar) else {
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
        return points
    }

    private func withCancellableRead<T>(_ body: () throws -> T) throws -> T {
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
}

extension StatisticsReader: StatisticsSnapshotReading {}

private final class StatisticsReadStoreHandle: @unchecked Sendable {
    let store: SQLiteStore

    init(store: SQLiteStore) {
        self.store = store
    }
}
