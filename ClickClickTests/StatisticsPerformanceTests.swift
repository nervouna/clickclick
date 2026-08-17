import AppKit
import Darwin
import Foundation
import SQLite3
import SwiftUI
import Testing
@testable import ClickClick

@Suite(.serialized)
struct StatisticsPerformanceTests {
    @Test func twoYearSnapshotsStayBoundedAndRecordingStaysResponsive() async throws {
        let fixture = try TwoYearStatisticsFixture()
        do {
            try await Self.exerciseTwoYearCorpus(fixture)
            try fixture.remove()
        } catch {
            try? fixture.remove()
            throw error
        }
    }

    private static func exerciseTwoYearCorpus(
        _ fixture: TwoYearStatisticsFixture
    ) async throws {
        let reader = try StatisticsReader(databaseURL: fixture.databaseURL)
        let calendar = fixture.calendar
        let now = fixture.now

        for granularity in [TrendGranularity.day, .week, .month] {
            let query = StatisticsQuery(
                granularity: granularity,
                deviceID: nil,
                now: now,
                calendar: calendar
            )
            await reader.resetMetrics()
            let snapshot = try await reader.snapshot(for: query)
            try Self.expectCorrectSnapshot(snapshot, fixture: fixture)

            let metrics = await reader.metrics()
            let expectedDailyRows = Self.dayCount(in: query) * fixture.deviceIDs.count
            #expect(metrics.snapshotQueryCount == 1)
            #expect(metrics.lastTrendSource == .daily)
            #expect(metrics.lastTrendSourceRowCount == expectedDailyRows)
            #expect(metrics.lastKeyResultCount == fixture.keyIDs.count)

            if granularity == .month {
                // A two-year month view must read one row per local day and
                // device, never the much larger hourly or per-key corpus.
                #expect(metrics.lastTrendSourceRowCount == fixture.dayCount * fixture.deviceIDs.count)
                #expect(metrics.lastTrendSourceRowCount <= 24 * 31 * fixture.deviceIDs.count)
            }
        }

        let monthQuery = StatisticsQuery(
            granularity: .month,
            deviceID: nil,
            now: now,
            calendar: calendar
        )

        let interruptedStore = try SQLiteStore(readOnlyURL: fixture.databaseURL)
        let cancellationFlag = PerformanceCancellationFlag()
        interruptedStore.installProgressHandler(every: 1) {
            cancellationFlag.isCancelled
        }
        cancellationFlag.cancel()
        var sqliteInterruptBecameCancellation = false
        do {
            _ = try interruptedStore.readTransaction {
                try interruptedStore.dailyTrendRows(
                    fromDay: monthQuery.fromLocalDay,
                    toDay: monthQuery.throughLocalDay,
                    deviceID: nil
                )
            }
        } catch is CancellationError {
            sqliteInterruptBecameCancellation = true
        }
        interruptedStore.clearProgressHandler()
        #expect(sqliteInterruptBecameCancellation)

        let cancelledReader = try StatisticsReader(databaseURL: fixture.databaseURL)
        let cancellationGate = PerformanceCancellationGate()
        let cancelledRead = Task {
            await cancellationGate.waitForRelease()
            return try await cancelledReader.snapshot(for: monthQuery)
        }
        await cancellationGate.waitUntilArrived()
        cancelledRead.cancel()
        await cancellationGate.release()
        var readerReturnedCancellation = false
        do {
            _ = try await cancelledRead.value
        } catch is CancellationError {
            readerReturnedCancellation = true
        } catch {
            throw error
        }
        #expect(readerReturnedCancellation)

        let clock = ContinuousClock()
        let freshReader = try StatisticsReader(databaseURL: fixture.databaseURL)
        let coldStart = clock.now
        _ = try await freshReader.snapshot(for: monthQuery)
        let coldDuration = coldStart.duration(to: clock.now)

        _ = try await freshReader.snapshot(for: monthQuery)
        var warmDurations: [Duration] = []
        for _ in 0..<20 {
            let start = clock.now
            _ = try await freshReader.snapshot(for: monthQuery)
            warmDurations.append(start.duration(to: clock.now))
        }
        let warmP95 = Self.percentile(warmDurations, percentile: 0.95)
        Self.reportTiming(cold: coldDuration, warmP95: warmP95)

        // Debug builds spend materially more time in Swift Calendar and model
        // construction. The product performance contract is enforced against
        // optimized code; Debug still emits the observed values above.
        #if !DEBUG
        #expect(coldDuration < .milliseconds(100))
        #expect(warmP95 < .milliseconds(50))
        #endif

        await freshReader.resetMetrics()
        let hiddenModel = await MainActor.run {
            StatisticsViewModel(
                reader: freshReader,
                granularity: .day,
                now: { now }
            )
        }
        await MainActor.run {
            hiddenModel.setVisible(false)
            hiddenModel.setGranularity(.week)
            hiddenModel.selectDevice(fixture.deviceIDs[0])
            hiddenModel.retry()
        }
        await Task.yield()
        #expect((await freshReader.metrics()).snapshotQueryCount == 0)

        let writableURL = try fixture.makeWritableClone()
        let engine = try StatisticsEngine(databaseURL: writableURL)
        let baseline = try await engine.reader.snapshot(for: monthQuery)
        let barrier = PerformanceBarrier(parties: 2)
        let recordCount = 5_000
        let recordedAt = now

        let readTask = Task {
            await barrier.arrive()
            for _ in 0..<20 {
                _ = try await engine.reader.snapshot(for: monthQuery)
            }
        }
        let recordTask = Task {
            await barrier.arrive()
            var durations: [Duration] = []
            durations.reserveCapacity(recordCount)
            for index in 0..<recordCount {
                let start = clock.now
                await engine.record(
                    deviceID: fixture.deviceIDs[0],
                    key: fixture.keyIDs[index % fixture.keyIDs.count],
                    at: recordedAt
                )
                durations.append(start.duration(to: clock.now))
            }
            return durations
        }

        let recordDurations = await recordTask.value
        try await readTask.value
        let recordP99 = Self.percentile(recordDurations, percentile: 0.99)
        print("statistics performance record p99: \(Self.milliseconds(recordP99)) ms")
        #if !DEBUG
        #expect(recordP99 < .milliseconds(5))
        #endif

        let flush = try #require(try await engine.flush())
        #expect(flush.deltas.reduce(Int64(0)) { $0 + $1.count } == Int64(recordCount))
        let final = try await engine.reader.snapshot(for: monthQuery)
        #expect(final.summary.total == baseline.summary.total + Int64(recordCount))
    }

    @Test @MainActor
    func rapidPeriodChangesPublishOnlyTheLatestSnapshot() async {
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let reader = PerformanceControlledReader()
        let publications = PerformancePublicationProbe()
        let model = StatisticsViewModel(
            reader: reader,
            granularity: .day,
            now: { fixedNow },
            didPublish: { publications.record($0) }
        )

        model.setVisible(true)
        let dayRequest = await reader.nextRequest()
        #expect(dayRequest.query.granularity == .day)

        model.setGranularity(TrendGranularity.week)
        let weekRequest = await reader.nextRequest()
        #expect(weekRequest.query.granularity == .week)

        model.setGranularity(.month)
        let monthRequest = await reader.nextRequest()
        #expect(monthRequest.query.granularity == .month)

        reader.complete(
            monthRequest,
            with: Self.emptySnapshot(for: monthRequest.query, revision: 3)
        )
        let published = await publications.next()
        #expect(published.query.granularity == .month)
        #expect(model.snapshot?.revision == 3)

        // Simulate a non-cooperative reader returning cancelled, stale work.
        reader.complete(
            weekRequest,
            with: Self.emptySnapshot(for: weekRequest.query, revision: 2)
        )
        reader.complete(
            dayRequest,
            with: Self.emptySnapshot(for: dayRequest.query, revision: 1)
        )
        for _ in 0..<4 { await Task.yield() }
        #expect(publications.count == 1)
        #expect(model.snapshot?.query.granularity == .month)

        model.setVisible(false)
        let requestCountAtClose = reader.requestCount
        model.setGranularity(.day)
        model.selectDevice(UUID())
        model.retry()
        await Task.yield()
        #expect(reader.requestCount == requestCountAtClose)

        let neverVisibleReader = PerformanceControlledReader()
        let neverVisibleModel = StatisticsViewModel(
            reader: neverVisibleReader,
            now: { fixedNow }
        )
        neverVisibleModel.setGranularity(.month)
        neverVisibleModel.selectDevice(UUID())
        neverVisibleModel.retry()
        await Task.yield()
        #expect(neverVisibleReader.requestCount == 0)
    }

    @Test @MainActor
    func statisticsViewKeepsResidentMemoryBoundedAcrossPublishedDeltas() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let reader = PerformanceControlledReader()
        let publications = PerformancePublicationCounter()
        let model = StatisticsViewModel(
            reader: reader,
            granularity: .month,
            now: { fixedNow },
            didPublish: { _ in publications.record() }
        )

        model.setVisible(true)
        let request = await reader.nextRequest()
        reader.complete(
            request,
            with: Self.resourceSnapshot(for: request.query, revision: 0)
        )
        await publications.wait(until: 1)
        #expect(model.snapshot?.revision == 0)

        let hostingView = NSHostingView(
            rootView: StatisticsView(model: model, hideZeroCountDevices: false)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 1_280, height: 900)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        Self.driveLayout(of: hostingView)

        // Warm the SwiftUI graph and allocator before taking a process-level
        // resident-memory baseline. Each update is a real snapshot publication
        // through StatisticsViewModel.consume(_:), followed by a layout pass.
        var revision: Int64 = 0
        for _ in 0..<20 {
            revision += 1
            model.consume(Self.resourceDelta(for: request.query, revision: revision))
            await Task.yield()
            Self.driveLayout(of: hostingView)
        }

        let baselineRSS = try #require(Self.residentMemoryBytes())
        let publicationCountAtBaseline = publications.count
        for _ in 0..<300 {
            revision += 1
            model.consume(Self.resourceDelta(for: request.query, revision: revision))
            await Task.yield()
            Self.driveLayout(of: hostingView)
        }
        let finalRSS = try #require(Self.residentMemoryBytes())
        let growth = finalRSS > baselineRSS ? finalRSS - baselineRSS : 0
        let growthMiB = Double(growth) / 1_048_576
        print("statistics view 300-publication RSS growth: \(growthMiB) MiB")
        #expect(growth < UInt64(10 * 1_048_576))
        #expect(publications.count == publicationCountAtBaseline + 300)
        #expect(model.snapshot?.revision == revision)
        #expect(reader.requestCount == 1)

        model.setVisible(false)
        let hiddenRequestCount = reader.requestCount
        model.setGranularity(.week)
        model.selectDevice(Self.resourceDeviceIDs[0])
        model.retry()
        for _ in 0..<20 {
            await Task.yield()
            Self.driveLayout(of: hostingView)
        }
        #expect(reader.requestCount == hiddenRequestCount)
        print(
            "statistics view reader queries: visible \(hiddenRequestCount), "
                + "hidden \(reader.requestCount)"
        )

        window.contentView = nil
    }

    private static func expectCorrectSnapshot(
        _ snapshot: StatisticsSnapshot,
        fixture: TwoYearStatisticsFixture
    ) throws {
        let query = snapshot.query
        let calendar = query.calendar
        var expectedTrend: [TrendPointID: Int64] = [:]
        var cursor = query.rangeStart
        var days = 0
        while cursor < query.rangeEnd {
            let bucket = TimeBuckets.start(of: query.granularity, for: cursor, calendar: calendar)
            for deviceID in fixture.deviceIDs {
                expectedTrend[TrendPointID(bucketStart: bucket, deviceID: deviceID), default: 0] += 120
            }
            days += 1
            cursor = try #require(calendar.date(byAdding: .day, value: 1, to: cursor))
        }

        #expect(query.fromLocalDay >= fixture.firstLocalDay)
        #expect(query.throughLocalDay <= fixture.lastLocalDay)
        #expect(snapshot.devices.map(\.id).sorted { $0.uuidString < $1.uuidString } == fixture.deviceIDs)
        #expect(snapshot.devices.allSatisfy { $0.totalCount == Int64(fixture.dayCount * 120) })

        let actualIDs = snapshot.trend.map(\.id)
        #expect(Set(actualIDs).count == actualIDs.count)
        let actualTrend = Dictionary(uniqueKeysWithValues: snapshot.trend.map { ($0.id, $0.count) })
        #expect(actualTrend == expectedTrend)

        let expectedPerKey = Int64(days * fixture.deviceIDs.count)
        #expect(snapshot.keyboardRanking.count == fixture.keyIDs.count)
        #expect(snapshot.consumerRanking.isEmpty)
        #expect(snapshot.keyboardRanking.allSatisfy {
            fixture.keyIDs.contains($0.key) && $0.count == expectedPerKey
        })
        #expect(snapshot.heatmapMaximum == Double(expectedPerKey))
        #expect(snapshot.heatmapMediaCounts.isEmpty)

        var totalsByBucket: [Date: Int64] = [:]
        for (id, count) in expectedTrend {
            totalsByBucket[id.bucketStart, default: 0] += count
        }
        let expectedTotal = expectedTrend.values.reduce(Int64(0), +)
        #expect(snapshot.summary == StatisticsSummary(
            total: expectedTotal,
            average: expectedTotal / Int64(totalsByBucket.count),
            peak: totalsByBucket.values.max() ?? 0,
            activeDeviceCount: fixture.deviceIDs.count
        ))
    }

    private static func dayCount(in query: StatisticsQuery) -> Int {
        query.calendar.dateComponents([.day], from: query.rangeStart, to: query.rangeEnd).day ?? 0
    }

    private static func percentile(_ values: [Duration], percentile: Double) -> Duration {
        guard !values.isEmpty else { return .zero }
        let ordered = values.sorted()
        let rank = max(1, Int(ceil(Double(ordered.count) * percentile)))
        return ordered[min(rank - 1, ordered.count - 1)]
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private static func reportTiming(cold: Duration, warmP95: Duration) {
        print(
            "statistics performance fresh-reader: \(milliseconds(cold)) ms, "
                + "warm p95: \(milliseconds(warmP95)) ms"
        )
    }

    private static func emptySnapshot(
        for query: StatisticsQuery,
        revision: Int64
    ) -> StatisticsSnapshot {
        StatisticsSnapshot(
            query: query,
            revision: revision,
            devices: [],
            trend: [],
            keyCounts: []
        )
    }

    private static let resourceDeviceIDs = (1...5).map { index in
        UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", index))!
    }

    private static func resourceSnapshot(
        for query: StatisticsQuery,
        revision: Int64
    ) -> StatisticsSnapshot {
        let devices = resourceDeviceIDs.enumerated().map { offset, id in
            KeyboardDevice(
                id: id,
                name: "Resource Keyboard \(offset + 1)",
                manufacturer: "Fixture",
                product: "Keyboard \(offset + 1)",
                transport: "USB",
                isBuiltIn: offset == 0,
                isConnected: true,
                isHidden: false,
                totalCount: 100_000
            )
        }
        var trend: [TrendPoint] = []
        trend.reserveCapacity(24 * devices.count)
        for monthOffset in 0..<24 {
            let date = query.calendar.date(
                byAdding: .month,
                value: monthOffset,
                to: query.rangeStart
            ) ?? query.rangeStart
            for (deviceOffset, device) in devices.enumerated() {
                trend.append(TrendPoint(
                    date: date,
                    deviceID: device.id,
                    deviceName: device.name,
                    count: Int64((monthOffset + 1) * (deviceOffset + 1) * 100)
                ))
            }
        }
        let keyCounts = (4..<124).map { usage in
            KeyCount(
                key: HIDKeyID(usagePage: 0x07, usage: UInt16(usage)),
                count: Int64(usage * 10)
            )
        }
        return StatisticsSnapshot(
            query: query,
            revision: revision,
            devices: devices,
            trend: trend,
            keyCounts: keyCounts
        )
    }

    private static func resourceDelta(
        for query: StatisticsQuery,
        revision: Int64
    ) -> FlushResult {
        let deviceID = resourceDeviceIDs[Int(revision % Int64(resourceDeviceIDs.count))]
        let key = HIDKeyID(
            usagePage: 0x07,
            usage: UInt16(4 + revision % 120)
        )
        let timestamp = Int64(query.rangeStart.timeIntervalSince1970)
        let delta = FlushDelta(
            minuteBucket: timestamp,
            hourBucket: timestamp,
            localDay: query.fromLocalDay,
            deviceID: deviceID,
            key: key,
            count: 1
        )
        return FlushResult(
            revision: revision,
            deltas: [delta],
            invalidation: .counts(revision: revision, deltas: [delta])
        )
    }

    @MainActor
    private static func driveLayout(of view: NSView) {
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        view.needsDisplay = true
        view.displayIfNeeded()
    }

    private static func residentMemoryBytes() -> UInt64? {
        var information = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size
                / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &information) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    rebound,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(information.resident_size)
    }
}

private final class TwoYearStatisticsFixture: @unchecked Sendable {
    let root: URL
    let databaseURL: URL
    let deviceIDs: [UUID]
    let keyIDs: [HIDKeyID]
    let calendar: Calendar
    let now: Date
    let dayCount = 730
    let firstLocalDay = "2024-08-01"
    let lastLocalDay = "2026-07-31"

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "statistics-performance-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        databaseURL = root.appending(path: "two-years.sqlite")
        deviceIDs = (1...5).map { index in
            UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
        }
        keyIDs = (4..<124).map {
            HIDKeyID(usagePage: 0x07, usage: UInt16($0))
        }

        var fixedCalendar = Calendar(identifier: .gregorian)
        fixedCalendar.locale = Locale(identifier: "en_US_POSIX")
        fixedCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        fixedCalendar.firstWeekday = 2
        fixedCalendar.minimumDaysInFirstWeek = 4
        calendar = fixedCalendar
        guard let fixedNow = fixedCalendar.date(
            from: DateComponents(year: 2026, month: 7, day: 15, hour: 12)
        ) else {
            throw StatisticsPerformanceFixtureError.invalidDate
        }
        now = fixedNow

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.createLegacyCorpus(
            at: databaseURL,
            deviceIDs: deviceIDs,
            firstLocalDay: firstLocalDay,
            dayCount: dayCount
        )

        // Let the production migrator create and backfill all optimized
        // rollups from the legacy source-of-truth tables.
        do {
            _ = try SQLiteStore(url: databaseURL)
        }
        try Self.checkpoint(at: databaseURL)
    }

    func makeWritableClone() throws -> URL {
        let destination = root.appending(path: "writable-\(UUID().uuidString).sqlite")
        try FileManager.default.copyItem(at: databaseURL, to: destination)
        return destination
    }

    func remove() throws {
        try FileManager.default.removeItem(at: root)
    }

    private static func createLegacyCorpus(
        at url: URL,
        deviceIDs: [UUID],
        firstLocalDay: String,
        dayCount: Int
    ) throws {
        let devices = deviceIDs.enumerated().map { offset, id in
            "('\(id.uuidString)', 'Fixture Keyboard \(offset + 1)', 'Fixture', "
                + "'Keyboard \(offset + 1)', 1, \(offset + 1), 'USB', 0, 0, 0, 0)"
        }.joined(separator: ",")
        let fixtureDeviceValues = deviceIDs.map { "('\($0.uuidString)')" }.joined(separator: ",")

        try withDatabase(at: url) { database in
            try execute(
                """
                PRAGMA journal_mode = DELETE;
                PRAGMA synchronous = OFF;
                PRAGMA temp_store = MEMORY;
                PRAGMA foreign_keys = OFF;
                BEGIN IMMEDIATE;
                CREATE TABLE devices (
                    id TEXT PRIMARY KEY,
                    display_name TEXT NOT NULL,
                    manufacturer TEXT,
                    product TEXT,
                    vendor_id INTEGER NOT NULL,
                    product_id INTEGER NOT NULL,
                    transport TEXT,
                    is_built_in INTEGER NOT NULL,
                    is_hidden INTEGER NOT NULL DEFAULT 0,
                    created_at INTEGER NOT NULL,
                    last_seen_at INTEGER NOT NULL
                );
                CREATE TABLE device_aliases (
                    fingerprint TEXT PRIMARY KEY,
                    device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE
                );
                CREATE TABLE minute_device_counts (
                    bucket_start INTEGER NOT NULL,
                    device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
                    count INTEGER NOT NULL,
                    PRIMARY KEY (bucket_start, device_id)
                );
                CREATE TABLE hourly_device_counts (
                    bucket_start INTEGER NOT NULL,
                    device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
                    count INTEGER NOT NULL,
                    PRIMARY KEY (bucket_start, device_id)
                );
                CREATE TABLE daily_device_key_counts (
                    local_day TEXT NOT NULL,
                    device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
                    usage_page INTEGER NOT NULL,
                    usage INTEGER NOT NULL,
                    count INTEGER NOT NULL,
                    PRIMARY KEY (local_day, device_id, usage_page, usage)
                );
                INSERT INTO devices VALUES \(devices);

                WITH RECURSIVE
                    days(day_index, local_day) AS (
                        VALUES (0, date('\(firstLocalDay)'))
                        UNION ALL
                        SELECT day_index + 1, date(local_day, '+1 day')
                        FROM days WHERE day_index + 1 < \(dayCount)
                    ),
                    hours(value) AS (
                        VALUES (0) UNION ALL SELECT value + 1 FROM hours WHERE value < 23
                    ),
                    fixture_devices(device_id) AS (VALUES \(fixtureDeviceValues))
                INSERT INTO hourly_device_counts(bucket_start, device_id, count)
                SELECT CAST(strftime('%s', local_day || ' 00:00:00') AS INTEGER) + hours.value * 3600,
                       fixture_devices.device_id,
                       5
                FROM days CROSS JOIN hours CROSS JOIN fixture_devices;

                WITH RECURSIVE
                    days(day_index, local_day) AS (
                        VALUES (0, date('\(firstLocalDay)'))
                        UNION ALL
                        SELECT day_index + 1, date(local_day, '+1 day')
                        FROM days WHERE day_index + 1 < \(dayCount)
                    ),
                    keys(usage) AS (
                        VALUES (4) UNION ALL SELECT usage + 1 FROM keys WHERE usage < 123
                    ),
                    fixture_devices(device_id) AS (VALUES \(fixtureDeviceValues))
                INSERT INTO daily_device_key_counts(local_day, device_id, usage_page, usage, count)
                SELECT days.local_day, fixture_devices.device_id, 7, keys.usage, 1
                FROM days CROSS JOIN fixture_devices CROSS JOIN keys;

                CREATE INDEX idx_hourly_device ON hourly_device_counts(device_id, bucket_start);
                CREATE INDEX idx_daily_device ON daily_device_key_counts(device_id, local_day);
                COMMIT;
                """,
                on: database
            )
        }
    }

    private static func checkpoint(at url: URL) throws {
        try withDatabase(at: url) { database in
            try execute("PRAGMA wal_checkpoint(TRUNCATE);", on: database)
        }
    }

    private static func withDatabase<T>(
        at url: URL,
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let database else {
            defer { sqlite3_close(database) }
            throw StatisticsPerformanceFixtureError.sqlite(
                database.flatMap(sqlite3_errmsg).map(String.init(cString:)) ?? "open failed"
            )
        }
        defer { sqlite3_close(database) }
        return try body(database)
    }

    private static func execute(_ sql: String, on database: OpaquePointer) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
            let detail = message.map { String(cString: $0) }
                ?? sqlite3_errmsg(database).map(String.init(cString:))
                ?? "unknown SQLite error"
            sqlite3_free(message)
            throw StatisticsPerformanceFixtureError.sqlite(detail)
        }
    }
}

private enum StatisticsPerformanceFixtureError: Error {
    case sqlite(String)
    case invalidDate
}

private final class PerformanceCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func cancel() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

private actor PerformanceCancellationGate {
    private var arrived = false
    private var released = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitForRelease() async {
        arrived = true
        let ready = arrivalWaiters
        arrivalWaiters.removeAll()
        ready.forEach { $0.resume() }
        if released { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilArrived() async {
        if arrived { return }
        await withCheckedContinuation { continuation in
            arrivalWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let ready = releaseWaiters
        releaseWaiters.removeAll()
        ready.forEach { $0.resume() }
    }
}

private actor PerformanceBarrier {
    private let parties: Int
    private var arrivals = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(parties: Int) {
        self.parties = parties
    }

    func arrive() async {
        arrivals += 1
        if arrivals == parties {
            let ready = waiters
            waiters.removeAll()
            ready.forEach { $0.resume() }
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private final class PerformanceControlledReader: StatisticsSnapshotReading, @unchecked Sendable {
    struct Request: Sendable {
        let id: Int
        let query: StatisticsQuery
    }

    private let lock = NSLock()
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<StatisticsSnapshot, Error>] = [:]
    private var queued: [Request] = []
    private var requestWaiters: [CheckedContinuation<Request, Never>] = []
    private var _requestCount = 0

    var requestCount: Int {
        withLock { _requestCount }
    }

    func snapshot(for query: StatisticsQuery) async throws -> StatisticsSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            let delivery: (CheckedContinuation<Request, Never>, Request)? = withLock {
                nextID += 1
                _requestCount += 1
                let request = Request(id: nextID, query: query)
                pending[request.id] = continuation
                guard !requestWaiters.isEmpty else {
                    queued.append(request)
                    return nil
                }
                return (requestWaiters.removeFirst(), request)
            }
            delivery?.0.resume(returning: delivery!.1)
        }
    }

    func interrupt() {
        // Deliberately ignore interruption so the ViewModel test can deliver
        // stale results and verify its generation guard.
    }

    func nextRequest() async -> Request {
        await withCheckedContinuation { continuation in
            let request: Request? = withLock {
                guard !queued.isEmpty else {
                    requestWaiters.append(continuation)
                    return nil
                }
                return queued.removeFirst()
            }
            if let request { continuation.resume(returning: request) }
        }
    }

    func complete(_ request: Request, with snapshot: StatisticsSnapshot) {
        let continuation = withLock { pending.removeValue(forKey: request.id) }
        continuation?.resume(returning: snapshot)
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

@MainActor
private final class PerformancePublicationCounter {
    private struct Waiter {
        let target: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var waiters: [Waiter] = []
    private(set) var count = 0

    func record() {
        count += 1
        let ready = waiters.filter { $0.target <= count }
        waiters.removeAll { $0.target <= count }
        ready.forEach { $0.continuation.resume() }
    }

    func wait(until target: Int) async {
        if count >= target { return }
        await withCheckedContinuation { continuation in
            waiters.append(Waiter(target: target, continuation: continuation))
        }
    }
}

@MainActor
private final class PerformancePublicationProbe {
    private var queued: [StatisticsSnapshot] = []
    private var waiters: [CheckedContinuation<StatisticsSnapshot, Never>] = []
    private(set) var count = 0

    func record(_ snapshot: StatisticsSnapshot) {
        count += 1
        guard !waiters.isEmpty else {
            queued.append(snapshot)
            return
        }
        waiters.removeFirst().resume(returning: snapshot)
    }

    func next() async -> StatisticsSnapshot {
        if !queued.isEmpty { return queued.removeFirst() }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
