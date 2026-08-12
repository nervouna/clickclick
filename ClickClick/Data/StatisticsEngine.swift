import Foundation

actor StatisticsEngine {
    private let store: SQLiteStore
    private var pending: [PendingKey: Int64] = [:]
    private var connectedReferences: [UInt64: UUID] = [:]
    private var flushTask: Task<Void, Never>?

    init(databaseURL: URL) throws {
        store = try SQLiteStore(url: databaseURL)
    }

    func startPeriodicFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                try? await self?.flush()
            }
        }
    }

    deinit {
        flushTask?.cancel()
    }

    func registerDevice(referenceID: UInt64, descriptor: DeviceDescriptor) throws -> UUID {
        let id = try store.resolveDevice(descriptor)
        connectedReferences[referenceID] = id
        return id
    }

    func disconnect(referenceID: UInt64) {
        connectedReferences.removeValue(forKey: referenceID)
    }

    func record(deviceID: UUID, key: HIDKeyID, at date: Date = Date()) {
        guard key.isCountable else { return }
        let pendingKey = PendingKey(
            minute: TimeBuckets.minute(for: date),
            hour: TimeBuckets.hour(for: date),
            localDay: TimeBuckets.localDay(for: date),
            deviceID: deviceID,
            key: key
        )
        pending[pendingKey, default: 0] += 1
    }

    func flush() throws {
        guard !pending.isEmpty else { return }
        let batch = pending.map {
            CountIncrement(
                minute: $0.key.minute,
                hour: $0.key.hour,
                localDay: $0.key.localDay,
                deviceID: $0.key.deviceID,
                key: $0.key.key,
                count: $0.value
            )
        }
        try store.apply(batch)
        pending.removeAll(keepingCapacity: true)
    }

    func performMaintenance(now: Date = Date()) throws {
        let cutoff = TimeBuckets.minute(for: now.addingTimeInterval(-30 * 24 * 60 * 60))
        try store.pruneMinuteData(before: cutoff)
    }

    func dashboard() throws -> DashboardSnapshot {
        try flush()
        return try store.dashboard(connected: Set(connectedReferences.values))
    }

    func trend(
        granularity: TrendGranularity,
        from: Date,
        to: Date,
        deviceID: UUID?
    ) throws -> [TrendPoint] {
        try flush()
        let rows = try store.trendRows(from: from, to: to, minute: granularity == .minute, deviceID: deviceID)
        let calendar = Calendar.autoupdatingCurrent
        var grouped: [TrendGroup: Int64] = [:]
        var names: [UUID: String] = [:]
        for row in rows {
            let rawDate = Date(timeIntervalSince1970: TimeInterval(row.0))
            let bucket = TimeBuckets.start(of: granularity, for: rawDate, calendar: calendar)
            grouped[TrendGroup(date: bucket, deviceID: row.1), default: 0] += row.3
            names[row.1] = row.2
        }
        return grouped.map {
            TrendPoint(date: $0.key.date, deviceID: $0.key.deviceID, deviceName: names[$0.key.deviceID] ?? "未知键盘", count: $0.value)
        }.sorted { lhs, rhs in
            lhs.date == rhs.date ? lhs.deviceName < rhs.deviceName : lhs.date < rhs.date
        }
    }

    func keyCounts(from: Date, to: Date, deviceID: UUID?) throws -> [KeyCount] {
        try flush()
        return try store.keyCounts(
            fromDay: TimeBuckets.localDay(for: from),
            toDay: TimeBuckets.localDay(for: to),
            deviceID: deviceID
        )
    }

    func renameDevice(id: UUID, name: String) throws { try store.renameDevice(id: id, name: name) }
    func setDeviceHidden(id: UUID, hidden: Bool) throws { try store.setDeviceHidden(id: id, hidden: hidden) }
    func deleteDevice(id: UUID) throws { try store.deleteDevice(id: id) }
    func clearAllCounts() throws { pending.removeAll(); try store.clearAllCounts() }

    func clearCounts(deviceID: UUID) throws {
        pending = pending.filter { $0.key.deviceID != deviceID }
        try store.clearCounts(deviceID: deviceID)
    }

    func mergeDevice(source: UUID, target: UUID) throws {
        try flush()
        try store.mergeDevice(source: source, target: target)
        for (reference, id) in connectedReferences where id == source {
            connectedReferences[reference] = target
        }
    }
}

private struct PendingKey: Hashable {
    let minute: Int64
    let hour: Int64
    let localDay: String
    let deviceID: UUID
    let key: HIDKeyID
}

private struct TrendGroup: Hashable {
    let date: Date
    let deviceID: UUID
}
