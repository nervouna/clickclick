import Foundation
import Testing
@testable import ClickClick

struct StatisticsConcurrencyModelTests {
    @Test @MainActor
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
            revision: 7,
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

    @Test @MainActor
    func viewModelIsLatestWinsAndDoesNotQueryWhileHidden() async throws {
        let reader = StatisticsControlledReader()
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let publications = PublicationCounter()
        let model = StatisticsViewModel(
            reader: reader,
            now: { fixedNow },
            didPublish: { _ in publications.record() }
        )

        model.setGranularity(.day)
        model.selectDevice(UUID())
        model.retry()
        #expect(reader.requestCount == 0)

        model.setVisible(true)
        let first = await reader.nextRequest()
        #expect(first.query.granularity == .day)

        model.setGranularity(.month)
        let second = await reader.nextRequest()
        #expect(second.query.granularity == .month)
        #expect(first.id != second.id)

        let device = Self.device(id: UUID(), name: "Keyboard", hidden: false)
        reader.succeed(
            requestID: second.id,
            with: StatisticsSnapshot(
                query: second.query,
                revision: 2,
                devices: [device],
                trend: [],
                keyCounts: []
            )
        )
        await publications.wait(until: 1)

        #expect(model.snapshot?.query.granularity == .month)
        #expect(publications.value == 1)
        #expect(reader.interruptCount >= 1)

        model.setVisible(false)
        model.setGranularity(.week)
        model.retry()
        await Task.yield()
        #expect(reader.requestCount == 2)
    }

    @Test @MainActor
    func hiddenViewDropsFlushPayloadsAndReloadsAtTheLatestRevision() async {
        let reader = StatisticsControlledReader()
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let deviceID = UUID()
        let publications = PublicationCounter()
        let model = StatisticsViewModel(
            reader: reader,
            granularity: .day,
            now: { fixedNow },
            didPublish: { _ in publications.record() }
        )
        let query = StatisticsQuery(granularity: .day, deviceID: nil, now: fixedNow)

        for revision in 1...500 {
            model.consume(Self.flushResult(
                revision: Int64(revision),
                deviceID: deviceID,
                localDay: query.fromLocalDay
            ))
        }
        #expect(reader.requestCount == 0)
        #expect(model.bufferedRevisionCountForDiagnostics == 0)

        model.setVisible(true)
        let staleRequest = await reader.nextRequest()
        let device = Self.device(id: deviceID, name: "Keyboard", hidden: false)
        reader.succeed(
            requestID: staleRequest.id,
            with: StatisticsSnapshot(
                query: staleRequest.query,
                revision: 499,
                devices: [device],
                trend: [],
                keyCounts: []
            )
        )

        let currentRequest = await reader.nextRequest()
        #expect(publications.value == 0)
        reader.succeed(
            requestID: currentRequest.id,
            with: StatisticsSnapshot(
                query: currentRequest.query,
                revision: 500,
                devices: [device],
                trend: [],
                keyCounts: []
            )
        )
        await publications.wait(until: 1)
        #expect(model.snapshot?.revision == 500)
        #expect(model.bufferedRevisionCountForDiagnostics == 0)
        model.setVisible(false)
    }

    @Test @MainActor
    func queryCrossingABucketBoundaryReloadsInsteadOfStayingLoading() async {
        let reader = StatisticsControlledReader()
        let clock = StatisticsMutableClock(
            now: Date(timeIntervalSince1970: 1_800_000_059)
        )
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
        reader.succeed(
            requestID: expiredRequest.id,
            with: StatisticsSnapshot(
                query: expiredRequest.query,
                revision: 1,
                devices: [],
                trend: [],
                keyCounts: []
            )
        )

        let currentRequest = await reader.nextRequest()
        #expect(currentRequest.query != expiredRequest.query)
        #expect(publications.value == 0)
        reader.succeed(
            requestID: currentRequest.id,
            with: StatisticsSnapshot(
                query: currentRequest.query,
                revision: 1,
                devices: [],
                trend: [],
                keyCounts: []
            )
        )
        await publications.wait(until: 1)
        #expect(model.snapshot?.query == currentRequest.query)
        #expect(!model.isLoading)
        model.setVisible(false)
    }

    @Test @MainActor
    func unrelatedDeltaAdvancesWorkingRevisionWithoutPublishing() async {
        let reader = StatisticsControlledReader()
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let selected = UUID()
        let other = UUID()
        let publications = PublicationCounter()
        let model = StatisticsViewModel(
            reader: reader,
            granularity: .day,
            selectedDeviceID: selected,
            now: { fixedNow },
            didPublish: { _ in publications.record() }
        )

        model.setVisible(true)
        let request = await reader.nextRequest()
        let selectedDevice = Self.device(id: selected, name: "Selected", hidden: false)
        let otherDevice = Self.device(id: other, name: "Other", hidden: false)
        reader.succeed(
            requestID: request.id,
            with: StatisticsSnapshot(
                query: request.query,
                revision: 10,
                devices: [selectedDevice, otherDevice],
                trend: [],
                keyCounts: []
            )
        )
        await publications.wait(until: 1)

        let localDay = request.query.fromLocalDay
        let unrelated = Self.flushResult(
            revision: 11,
            deviceID: other,
            localDay: localDay
        )
        model.consume(unrelated)
        #expect(publications.value == 1)

        let relevant = Self.flushResult(
            revision: 12,
            deviceID: selected,
            localDay: localDay
        )
        model.consume(relevant)
        #expect(publications.value == 2)
        #expect(model.snapshot?.revision == 12)
        #expect(model.snapshot?.summary.total == 1)

        model.setVisible(false)
    }

    @Test func emptyFlushReturnsNilAndWrittenFlushCarriesExactDelta() async throws {
        let fixture = try StatisticsConcurrencyFixture()
        let engine = try StatisticsEngine(databaseURL: fixture.databaseURL)
        #expect(try await engine.flush() == nil)

        let device = try await engine.registerDevice(
            referenceID: 1,
            descriptor: fixture.descriptor
        )
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        await engine.record(
            deviceID: device,
            key: HIDKeyID(usagePage: 7, usage: 4),
            at: date
        )
        let flushed = try await engine.flush()
        let result = try #require(flushed)

        #expect(result.deltas.count == 1)
        #expect(result.deltas[0].deviceID == device)
        #expect(result.deltas[0].count == 1)
        #expect(result.invalidation.scope == .counts)
        let dashboard = try await engine.dashboard()
        #expect(dashboard.revision == result.revision)
        #expect(dashboard.snapshot.devices.first { $0.id == device }?.totalCount == 1)
        #expect(try await engine.flush() == nil)
    }

    @Test @MainActor
    func inFlightCountFlushesAreBufferedAndRevisionGapTriggersOneReload() async {
        let reader = StatisticsControlledReader()
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let deviceID = UUID()
        let publications = PublicationCounter()
        let model = StatisticsViewModel(
            reader: reader,
            granularity: .day,
            selectedDeviceID: deviceID,
            now: { fixedNow },
            didPublish: { _ in publications.record() }
        )

        model.setVisible(true)
        let first = await reader.nextRequest()
        model.consume(Self.flushResult(revision: 11, deviceID: deviceID, localDay: first.query.fromLocalDay))
        model.consume(Self.flushResult(revision: 12, deviceID: deviceID, localDay: first.query.fromLocalDay))
        #expect(reader.requestCount == 1)

        let device = Self.device(id: deviceID, name: "Keyboard", hidden: false)
        reader.succeed(
            requestID: first.id,
            with: StatisticsSnapshot(
                query: first.query,
                revision: 10,
                devices: [device],
                trend: [],
                keyCounts: []
            )
        )
        await publications.wait(until: 1)
        #expect(model.snapshot?.revision == 12)
        #expect(model.snapshot?.summary.total == 2)
        #expect(reader.requestCount == 1)

        model.consume(Self.flushResult(revision: 14, deviceID: deviceID, localDay: first.query.fromLocalDay))
        let second = await reader.nextRequest()
        #expect(reader.requestCount == 2)
        reader.succeed(
            requestID: second.id,
            with: StatisticsSnapshot(
                query: second.query,
                revision: 14,
                devices: [device],
                trend: [],
                keyCounts: []
            )
        )
        await publications.wait(until: 2)
        await Task.yield()
        #expect(reader.requestCount == 2)
        #expect(model.snapshot?.revision == 14)
        model.setVisible(false)
    }

    private static func flushResult(
        revision: Int64,
        deviceID: UUID,
        localDay: String
    ) -> FlushResult {
        let calendar = Calendar.autoupdatingCurrent
        let day = calendar.date(
            from: DateComponents(
                year: Int(localDay.prefix(4)),
                month: Int(localDay.dropFirst(5).prefix(2)),
                day: Int(localDay.suffix(2))
            )
        ) ?? Date()
        let delta = FlushDelta(
            minuteBucket: TimeBuckets.minute(for: day),
            hourBucket: TimeBuckets.hour(for: day),
            localDay: localDay,
            deviceID: deviceID,
            key: HIDKeyID(usagePage: 7, usage: 4),
            count: 1
        )
        return FlushResult(
            revision: revision,
            deltas: [delta],
            invalidation: .counts(revision: revision, deltas: [delta])
        )
    }

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
    private var nextID = 0
    private var pending: [Int: Pending] = [:]
    private var queuedRequests: [Request] = []
    private var requestWaiters: [CheckedContinuation<Request, Never>] = []
    private var _requestCount = 0
    private var _interruptCount = 0

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

private struct StatisticsConcurrencyFixture {
    let root: URL
    var databaseURL: URL { root.appending(path: "statistics-concurrency.sqlite") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "statistics-concurrency-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var descriptor: DeviceDescriptor {
        DeviceDescriptor(
            observedFingerprint: "statistics-concurrency-device",
            suggestedName: "Statistics Test Device",
            manufacturer: "Test",
            product: "Test",
            vendorID: 1,
            productID: 2,
            transport: "USB",
            isBuiltIn: false
        )
    }
}

@MainActor
private final class StatisticsMutableClock {
    var now: Date

    init(now: Date) {
        self.now = now
    }
}
