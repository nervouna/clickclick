import Foundation

actor StatisticsEngine {
    private let store: SQLiteStore
    private let dashboardReader: StatisticsReader
    nonisolated let reader: StatisticsReader
    private let flushDelay: Duration

    private var pending: [PendingKey: Int64] = [:]
    private var connectedReferences: [UInt64: UUID] = [:]
    private(set) var scheduledFlush: Task<Void, Never>?
    private var flushDidFinish: (@Sendable (Error?) async -> Void)?

    init(databaseURL: URL, flushDelay: Duration = .seconds(2)) throws {
        store = try SQLiteStore(url: databaseURL)
        dashboardReader = try StatisticsReader(databaseURL: databaseURL)
        reader = try StatisticsReader(databaseURL: databaseURL)
        self.flushDelay = flushDelay
    }

    /// Called after a scheduled flush wrote counts (`nil`) or failed (the error).
    func setFlushHandler(_ handler: (@Sendable (Error?) async -> Void)?) {
        flushDidFinish = handler
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
        scheduleFlushIfNeeded()
    }

    func record(referenceID: UInt64, key: HIDKeyID, at date: Date = Date()) {
        guard let deviceID = connectedReferences[referenceID] else { return }
        record(deviceID: deviceID, key: key, at: date)
    }

    /// Writes pending counts. Returns whether anything was written.
    @discardableResult
    func flush() throws -> Bool {
        guard !pending.isEmpty else { return false }

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
        try store.apply(batch)
        pending.removeAll(keepingCapacity: true)
        return true
    }

    func performMaintenance(now: Date = Date()) throws {
        let cutoff = TimeBuckets.minute(for: now.addingTimeInterval(-30 * 24 * 60 * 60))
        try store.pruneMinuteData(before: cutoff)
    }

    func dashboard() async throws -> DashboardSnapshot {
        try await dashboardReader.dashboard(connected: Set(connectedReferences.values))
    }

    func renameDevice(id: UUID, name: String) throws {
        try flush()
        try store.renameDevice(id: id, name: name)
    }

    func setDeviceHidden(id: UUID, hidden: Bool) throws {
        try flush()
        try store.setDeviceHidden(id: id, hidden: hidden)
    }

    func deleteDevice(id: UUID) throws {
        try store.deleteDevice(id: id)
        pending = pending.filter { $0.key.deviceID != id }
        connectedReferences = connectedReferences.filter { $0.value != id }
    }

    func clearAllCounts() throws {
        try store.clearAllCounts()
        pending.removeAll(keepingCapacity: true)
    }

    func clearCounts(deviceID: UUID) throws {
        try store.clearCounts(deviceID: deviceID)
        pending = pending.filter { $0.key.deviceID != deviceID }
    }

    func mergeDevice(source: UUID, target: UUID) throws {
        try flush()
        try store.mergeDevice(source: source, target: target)
        for (reference, id) in connectedReferences where id == source {
            connectedReferences[reference] = target
        }
    }

    /// One task at a time. While the user is idle nothing is pending and nothing is scheduled.
    private func scheduleFlushIfNeeded() {
        guard scheduledFlush == nil else { return }
        scheduledFlush = Task { [weak self, flushDelay] in
            do {
                try await Task.sleep(for: flushDelay, tolerance: flushDelay / 2)
            } catch {
                return
            }
            await self?.runScheduledFlush()
        }
    }

    private func runScheduledFlush() async {
        scheduledFlush = nil
        do {
            guard try flush() else { return }
            await flushDidFinish?(nil)
        } catch {
            // Pending counts are kept; the next keystroke schedules another attempt.
            await flushDidFinish?(error)
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
