import Foundation
import Testing
@testable import ClickClick

struct StatisticsConcurrencyModelTests {
    private static let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    @Test(.timeLimit(.minutes(1))) @MainActor
    func hostedTestsUseAnIsolatedDefaultDatabase() throws {
        #expect(ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil)
        let databaseURL = try AppModel.defaultDatabaseURL()
        #expect(databaseURL.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        #expect(!databaseURL.path.contains("/Data/Library/Application Support/ClickClick/"))
    }

    @Test func queryIdentityIsStableInsideAlignedBucketAndPreservesCalendarRules() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        calendar.locale = Locale(identifier: "zh_TW")
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        let first = Date(timeIntervalSince1970: 1_800_000_001)
        let second = first.addingTimeInterval(30)

        let lhs = StatisticsQuery(
            granularity: .hour,
            deviceID: nil,
            now: first,
            calendar: calendar
        )
        let rhs = StatisticsQuery(
            granularity: .hour,
            deviceID: nil,
            now: second,
            calendar: calendar
        )

        #expect(lhs == rhs)
        #expect(lhs.calendar.timeZone.identifier == "Asia/Taipei")
        #expect(lhs.calendar.firstWeekday == 2)
        #expect(lhs.calendar.minimumDaysInFirstWeek == 4)
        #expect(lhs.calendar.locale?.identifier == "zh_TW")
    }

    @Test func snapshotUsesStablePointIdentityAndExcludesHiddenDevices() {
        let visible = Self.device(id: UUID(), name: "Visible", hidden: false)
        let hidden = Self.device(id: UUID(), name: "Hidden", hidden: true)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let query = StatisticsQuery(granularity: .day, deviceID: nil, now: date)
        let snapshot = StatisticsSnapshot(
            query: query,
            devices: [visible, hidden],
            trend: [
                TrendPoint(date: date, deviceID: hidden.id, deviceName: hidden.name, count: 99),
                TrendPoint(date: date, deviceID: visible.id, deviceName: visible.name, count: 4)
            ],
            keyCounts: [KeyCount(key: HIDKeyID(usagePage: 7, usage: 4), count: 4)]
        )

        #expect(snapshot.devices.map(\.id) == [visible.id])
        #expect(snapshot.trend.map(\.deviceID) == [visible.id])
        #expect(snapshot.trend.first?.id == TrendPointID(bucketStart: date, deviceID: visible.id))
        #expect(snapshot.summary.total == 4)
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func latestQueryWinsAndInterruptsTheSupersededRead() async {
        let reader = StatisticsControlledReader()
        let publications = PublicationCounter()
        let model = Self.makeModel(reader, publications)

        model.setVisible(true)
        let first = await reader.nextRequest()
        #expect(first.query.granularity == .hour)

        model.setGranularity(.month)
        let second = await reader.nextRequest()
        #expect(second.query.granularity == .month)
        #expect(first.id != second.id)
        #expect(reader.interruptCount >= 1)

        reader.succeed(requestID: second.id, with: Self.snapshot(second.query))
        await publications.wait(until: 1)
        #expect(model.snapshot?.query.granularity == .month)
        #expect(publications.value == 1)
        model.setVisible(false)
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func staleCompletionsAreIgnored() async {
        let reader = StatisticsControlledReader(ignoresInterrupt: true)
        let publications = PublicationCounter()
        let model = Self.makeModel(reader, publications)
        let other = UUID()

        model.setVisible(true)
        let first = await reader.nextRequest()
        model.selectDevice(other)
        let second = await reader.nextRequest()
        #expect(second.query.deviceID == other)

        // The superseded read still finishes, but nobody may look at its result.
        reader.succeed(requestID: first.id, with: Self.snapshot(first.query))
        await settle()
        #expect(publications.value == 0)
        #expect(model.snapshot == nil)
        #expect(model.isLoading)

        reader.succeed(requestID: second.id, with: Self.snapshot(second.query))
        await publications.wait(until: 1)
        #expect(model.snapshot?.query.deviceID == other)
        #expect(!model.isLoading)
        await settle()
        #expect(publications.value == 1)
        model.setVisible(false)
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func hiddenModelNeverReads() async {
        let reader = StatisticsControlledReader()
        let model = Self.makeModel(reader)

        model.setGranularity(.day)
        model.selectDevice(UUID())
        model.retry()
        model.invalidateAndReload()
        model.dataDidChange()
        await settle()
        #expect(reader.requestCount == 0)

        model.setVisible(true)
        let request = await reader.nextRequest()
        #expect(request.query.granularity == .day)
        #expect(model.isLoading)

        model.setVisible(false)
        #expect(!model.isLoading)
        model.setGranularity(.week)
        model.retry()
        model.dataDidChange()
        await settle()
        #expect(reader.requestCount == 1)
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func changesWhileHiddenCauseExactlyOneReloadWhenShown() async {
        let reader = StatisticsControlledReader()
        let publications = PublicationCounter()
        let model = Self.makeModel(reader, publications)

        model.setVisible(true)
        let first = await reader.nextRequest()
        reader.succeed(requestID: first.id, with: Self.snapshot(first.query))
        await publications.wait(until: 1)

        model.setVisible(false)
        for _ in 0..<500 { model.dataDidChange() }
        await settle()
        #expect(reader.requestCount == 1)

        model.setVisible(true)
        let second = await reader.nextRequest()
        await settle()
        #expect(reader.requestCount == 2)
        #expect(!model.isLoading)
        #expect(model.snapshot != nil)
        reader.succeed(requestID: second.id, with: Self.snapshot(second.query, count: 3))
        await publications.wait(until: 2)
        #expect(model.snapshot?.summary.total == 3)

        // Nothing changed this time, so showing the window again reads nothing.
        model.setVisible(false)
        model.setVisible(true)
        await settle()
        #expect(reader.requestCount == 2)
        model.setVisible(false)
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func changeDuringAnInFlightLoadCausesExactlyOneFollowUpReload() async {
        let reader = StatisticsControlledReader()
        let publications = PublicationCounter()
        let model = Self.makeModel(reader, publications)

        model.setVisible(true)
        let first = await reader.nextRequest()
        for _ in 0..<5 { model.dataDidChange() }
        await settle()
        #expect(reader.requestCount == 1)
        #expect(reader.interruptCount == 0)

        reader.succeed(requestID: first.id, with: Self.snapshot(first.query))
        await publications.wait(until: 1)
        let second = await reader.nextRequest()
        #expect(reader.requestCount == 2)
        #expect(!model.isLoading)

        reader.succeed(requestID: second.id, with: Self.snapshot(second.query, count: 1))
        await publications.wait(until: 2)
        await settle()
        #expect(reader.requestCount == 2)
        #expect(model.snapshot?.summary.total == 1)
        model.setVisible(false)
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func backgroundReloadsDoNotShowTheLoadingIndicator() async {
        let reader = StatisticsControlledReader()
        let publications = PublicationCounter()
        let model = Self.makeModel(reader, publications)

        model.setVisible(true)
        #expect(model.isLoading)
        let first = await reader.nextRequest()
        reader.succeed(requestID: first.id, with: Self.snapshot(first.query))
        await publications.wait(until: 1)
        #expect(!model.isLoading)

        model.dataDidChange()
        #expect(!model.isLoading)
        let second = await reader.nextRequest()
        #expect(!model.isLoading)
        reader.succeed(requestID: second.id, with: Self.snapshot(second.query, count: 2))
        await publications.wait(until: 2)
        #expect(!model.isLoading)

        model.invalidateAndReload()
        #expect(!model.isLoading)
        let third = await reader.nextRequest()

        // A selection change or a retry replaces what the user is looking at.
        model.setGranularity(.day)
        #expect(model.isLoading)
        let fourth = await reader.nextRequest()
        #expect(third.id != fourth.id)
        reader.succeed(requestID: fourth.id, with: Self.snapshot(fourth.query))
        await publications.wait(until: 3)
        #expect(!model.isLoading)

        model.retry()
        #expect(model.isLoading)
        let fifth = await reader.nextRequest()
        reader.succeed(requestID: fifth.id, with: Self.snapshot(fifth.query, count: 5))
        await publications.wait(until: 4)
        #expect(!model.isLoading)
        model.setVisible(false)
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func unchangedSnapshotIsNotRepublished() async {
        let reader = StatisticsControlledReader()
        let publications = PublicationCounter()
        let model = Self.makeModel(reader, publications)

        model.setVisible(true)
        let first = await reader.nextRequest()
        reader.succeed(requestID: first.id, with: Self.snapshot(first.query, count: 4))
        await publications.wait(until: 1)

        model.dataDidChange()
        let second = await reader.nextRequest()
        reader.succeed(requestID: second.id, with: Self.snapshot(second.query, count: 4))

        // The next request can only start after the second load finished.
        model.dataDidChange()
        let third = await reader.nextRequest()
        #expect(publications.value == 1)

        reader.succeed(requestID: third.id, with: Self.snapshot(third.query, count: 5))
        await publications.wait(until: 2)
        #expect(model.snapshot?.summary.total == 5)
        model.setVisible(false)
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func queryCrossingABucketBoundaryDuringALoadReloadsInsteadOfStayingLoading() async {
        let reader = StatisticsControlledReader()
        let clock = StatisticsMutableClock(now: Date(timeIntervalSince1970: 1_800_000_059))
        let publications = PublicationCounter()
        let model = StatisticsViewModel(
            reader: reader,
            granularity: .minute,
            now: { clock.now },
            didPublish: { _ in publications.record() }
        )

        model.setVisible(true)
        let expiredRequest = await reader.nextRequest()
        clock.now = Date(timeIntervalSince1970: 1_800_000_061)
        reader.succeed(requestID: expiredRequest.id, with: Self.snapshot(expiredRequest.query))

        let currentRequest = await reader.nextRequest()
        #expect(currentRequest.query != expiredRequest.query)
        #expect(publications.value == 0)
        #expect(model.isLoading)
        reader.succeed(requestID: currentRequest.id, with: Self.snapshot(currentRequest.query))
        await publications.wait(until: 1)
        #expect(model.snapshot?.query == currentRequest.query)
        #expect(!model.isLoading)
        model.setVisible(false)
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func visibleModelReloadsInTheBackgroundWhenTheBucketRollsOver() async {
        let reader = StatisticsControlledReader()
        // Close enough to the end of the bucket that the boundary timer is short.
        let clock = StatisticsMutableClock(now: Date(timeIntervalSince1970: 1_800_000_059.99))
        let publications = PublicationCounter()
        let model = StatisticsViewModel(
            reader: reader,
            granularity: .minute,
            now: { clock.now },
            didPublish: { _ in publications.record() }
        )

        model.setVisible(true)
        let first = await reader.nextRequest()
        reader.succeed(requestID: first.id, with: Self.snapshot(first.query))
        await publications.wait(until: 1)

        clock.now = Date(timeIntervalSince1970: 1_800_000_061)
        let second = await reader.nextRequest()
        #expect(second.query != first.query)
        #expect(!model.isLoading)
        reader.succeed(requestID: second.id, with: Self.snapshot(second.query))
        await publications.wait(until: 2)
        #expect(model.snapshot?.query == second.query)
        model.setVisible(false)
    }

    // MARK: Helpers

    @MainActor
    private static func makeModel(
        _ reader: StatisticsControlledReader,
        _ publications: PublicationCounter? = nil
    ) -> StatisticsViewModel {
        StatisticsViewModel(
            reader: reader,
            now: { fixedNow },
            didPublish: { _ in publications?.record() }
        )
    }

    /// `count` > 0 adds one trend point so snapshots can be told apart.
    private static func snapshot(_ query: StatisticsQuery, count: Int64 = 0) -> StatisticsSnapshot {
        let keyboard = device(id: Self.keyboardID, name: "Keyboard", hidden: false)
        return StatisticsSnapshot(
            query: query,
            devices: [keyboard],
            trend: count == 0 ? [] : [
                TrendPoint(
                    date: query.currentBucketStart,
                    deviceID: keyboard.id,
                    deviceName: keyboard.name,
                    count: count
                )
            ],
            keyCounts: []
        )
    }

    private static let keyboardID = UUID()

    private static func device(id: UUID, name: String, hidden: Bool) -> KeyboardDevice {
        KeyboardDevice(
            id: id,
            name: name,
            manufacturer: nil,
            product: nil,
            transport: "USB",
            isBuiltIn: false,
            isConnected: true,
            isHidden: hidden,
            totalCount: 0
        )
    }
}

/// Lets already-enqueued main actor work run. Only used before asserting that
/// something did not happen, so it can hide a bug but never fail a correct run.
@MainActor
private func settle() async {
    for _ in 0..<20 { await Task.yield() }
}

@MainActor
private final class PublicationCounter {
    var value = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func wait(until expected: Int) async {
        if value >= expected { return }
        await withCheckedContinuation { continuation in
            waiters.append((expected, continuation))
        }
    }

    func record() {
        value += 1
        let ready = waiters.filter { value >= $0.0 }
        waiters.removeAll { value >= $0.0 }
        ready.forEach { $0.1.resume() }
    }
}

private final class StatisticsControlledReader: StatisticsSnapshotReading, @unchecked Sendable {
    struct Request: Sendable {
        let id: Int
        let query: StatisticsQuery
    }

    private struct Pending {
        let request: Request
        let continuation: CheckedContinuation<StatisticsSnapshot, Error>
    }

    private let lock = NSLock()
    private let ignoresInterrupt: Bool
    private var nextID = 0
    private var pending: [Int: Pending] = [:]
    private var queuedRequests: [Request] = []
    private var requestWaiters: [CheckedContinuation<Request, Never>] = []
    private var _requestCount = 0
    private var _interruptCount = 0

    /// A reader that ignores `interrupt()` still completes superseded reads,
    /// which is how a late result from a cancelled query shows up.
    init(ignoresInterrupt: Bool = false) {
        self.ignoresInterrupt = ignoresInterrupt
    }

    var requestCount: Int { withLock { _requestCount } }
    var interruptCount: Int { withLock { _interruptCount } }

    func snapshot(for query: StatisticsQuery) async throws -> StatisticsSnapshot {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let delivery: (CheckedContinuation<Request, Never>, Request)? = withLock {
                    nextID += 1
                    _requestCount += 1
                    let request = Request(id: nextID, query: query)
                    pending[request.id] = Pending(request: request, continuation: continuation)
                    if requestWaiters.isEmpty {
                        queuedRequests.append(request)
                        return nil
                    }
                    return (requestWaiters.removeFirst(), request)
                }
                if let delivery {
                    delivery.0.resume(returning: delivery.1)
                }
            }
        } onCancel: {
            self.interrupt()
        }
    }

    func interrupt() {
        let continuations: [CheckedContinuation<StatisticsSnapshot, Error>] = withLock {
            _interruptCount += 1
            guard !ignoresInterrupt else { return [] }
            let values = pending.values.map(\.continuation)
            pending.removeAll()
            return values
        }
        continuations.forEach { $0.resume(throwing: CancellationError()) }
    }

    func nextRequest() async -> Request {
        await withCheckedContinuation { continuation in
            let request: Request? = withLock {
                guard !queuedRequests.isEmpty else {
                    requestWaiters.append(continuation)
                    return nil
                }
                return queuedRequests.removeFirst()
            }
            if let request { continuation.resume(returning: request) }
        }
    }

    func succeed(requestID: Int, with snapshot: StatisticsSnapshot) {
        let continuation: CheckedContinuation<StatisticsSnapshot, Error>? = withLock {
            pending.removeValue(forKey: requestID)?.continuation
        }
        continuation?.resume(returning: snapshot)
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

@MainActor
private final class StatisticsMutableClock {
    var now: Date

    init(now: Date) {
        self.now = now
    }
}
