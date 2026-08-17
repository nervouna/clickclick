import Foundation

actor StatisticsEngine {
    private let store: SQLiteStore
    private let dashboardReader: StatisticsReader
    nonisolated let reader: StatisticsReader

    private var pending: [PendingKey: Int64] = [:]
    private var connectedReferences: [UInt64: UUID] = [:]

    init(databaseURL: URL) throws {
        store = try SQLiteStore(url: databaseURL)
        dashboardReader = try StatisticsReader(databaseURL: databaseURL)
        reader = try StatisticsReader(databaseURL: databaseURL)
    }

    @available(*, deprecated, message: "The application owns the flush cadence.")
    func startPeriodicFlush() {
        // Kept as a source-compatible no-op while callers move to an
        // application-owned timer. Having a second timer here would recreate
        // the refresh storm this split is intended to remove.
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

    func record(referenceID: UInt64, key: HIDKeyID, at date: Date = Date()) {
        guard let deviceID = connectedReferences[referenceID] else { return }
        record(deviceID: deviceID, key: key, at: date)
    }

    @discardableResult
    func flush() throws -> FlushResult? {
        guard !pending.isEmpty else { return nil }

        let batch = pending.map { entry in
            CountIncrement(
                minute: entry.key.minute,
                hour: entry.key.hour,
                localDay: entry.key.localDay,
                deviceID: entry.key.deviceID,
                key: entry.key.key,
                count: entry.value
            )
        }
        let outcome = try store.applyWithOutcome(batch)
        pending.removeAll(keepingCapacity: true)

        let deltas = batch.map(FlushDelta.init)
        return FlushResult(
            revision: outcome.revision,
            deltas: deltas,
            invalidation: outcome.reconciledCanonicalState
                ? .full(revision: outcome.revision)
                : .counts(revision: outcome.revision, deltas: deltas)
        )
    }

    @discardableResult
    func performMaintenance(now: Date = Date()) throws -> FlushResult? {
        let before = try store.revision()
        let cutoff = TimeBuckets.minute(for: now.addingTimeInterval(-30 * 24 * 60 * 60))
        try store.pruneMinuteData(before: cutoff)
        let after = try store.revision()
        guard after != before else { return nil }
        return .full(revision: after)
    }

    func currentRevision() throws -> Int64 {
        try store.revision()
    }

    // Compatibility reads delegate to the independent reader connection. They
    // no longer hold the writer actor or block input accumulation.
    func dashboard() async throws -> RevisionedDashboardSnapshot {
        return try await dashboardReader.dashboard(connected: Set(connectedReferences.values))
    }

    func trend(
        granularity: TrendGranularity,
        from: Date,
        to: Date,
        deviceID: UUID?
    ) async throws -> [TrendPoint] {
        _ = try flush()
        return try await reader.trend(
            granularity: granularity,
            from: from,
            to: to,
            deviceID: deviceID,
            calendar: .autoupdatingCurrent
        )
    }

    func keyCounts(from: Date, to: Date, deviceID: UUID?) async throws -> [KeyCount] {
        _ = try flush()
        return try await reader.keyCounts(
            from: from,
            to: to,
            deviceID: deviceID,
            calendar: .autoupdatingCurrent
        )
    }

    @discardableResult
    func renameDevice(id: UUID, name: String) throws -> FlushResult {
        _ = try flush()
        try store.renameDevice(id: id, name: name)
        return .full(revision: try store.revision(), deviceIDs: [id])
    }

    @discardableResult
    func setDeviceHidden(id: UUID, hidden: Bool) throws -> FlushResult {
        _ = try flush()
        try store.setDeviceHidden(id: id, hidden: hidden)
        return .full(revision: try store.revision(), deviceIDs: [id])
    }

    @discardableResult
    func deleteDevice(id: UUID) throws -> FlushResult {
        try store.deleteDevice(id: id)
        pending = pending.filter { $0.key.deviceID != id }
        connectedReferences = connectedReferences.filter { $0.value != id }
        return .full(revision: try store.revision(), deviceIDs: [id])
    }

    @discardableResult
    func clearAllCounts() throws -> FlushResult {
        try store.clearAllCounts()
        pending.removeAll(keepingCapacity: true)
        return .full(revision: try store.revision())
    }

    @discardableResult
    func clearCounts(deviceID: UUID) throws -> FlushResult {
        try store.clearCounts(deviceID: deviceID)
        pending = pending.filter { $0.key.deviceID != deviceID }
        return .full(revision: try store.revision(), deviceIDs: [deviceID])
    }

    @discardableResult
    func mergeDevice(source: UUID, target: UUID) throws -> FlushResult {
        _ = try flush()
        try store.mergeDevice(source: source, target: target)
        for (reference, id) in connectedReferences where id == source {
            connectedReferences[reference] = target
        }
        return .full(revision: try store.revision(), deviceIDs: [source, target])
    }
}

private struct PendingKey: Hashable {
    let minute: Int64
    let hour: Int64
    let localDay: String
    let deviceID: UUID
    let key: HIDKeyID
}

private extension FlushDelta {
    init(_ increment: CountIncrement) {
        self.init(
            minuteBucket: increment.minute,
            hourBucket: increment.hour,
            localDay: increment.localDay,
            deviceID: increment.deviceID,
            key: increment.key,
            count: increment.count
        )
    }
}
