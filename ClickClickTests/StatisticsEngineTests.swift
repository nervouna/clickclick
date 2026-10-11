import Foundation
import SQLite3
import Testing
@testable import ClickClick

struct StatisticsEngineTests {
    @Test func persistsAggregatesAndSeparatesDevices() async throws {
        let fixture = try Fixture()
        let engine = try StatisticsEngine(databaseURL: fixture.databaseURL)
        let first = try await engine.registerDevice(referenceID: 1, descriptor: fixture.descriptor(fingerprint: "first", name: "First"))
        let second = try await engine.registerDevice(referenceID: 2, descriptor: fixture.descriptor(fingerprint: "second", name: "Second"))
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        await engine.record(deviceID: first, key: HIDKeyID(usagePage: 0x07, usage: 0x04), at: date)
        await engine.record(deviceID: first, key: HIDKeyID(usagePage: 0x07, usage: 0x04), at: date)
        await engine.record(deviceID: second, key: HIDKeyID(usagePage: 0x07, usage: 0xE1), at: date)
        #expect(try await engine.flush())

        let snapshot = try await engine.reader.snapshot(
            for: StatisticsQuery(granularity: .minute, deviceID: nil, now: date)
        )
        #expect(snapshot.trend.reduce(0) { $0 + $1.count } == 3)
        #expect(Set(snapshot.trend.map(\.deviceID)) == [first, second])
    }

    @Test func mergesCountsAndAliases() async throws {
        let fixture = try Fixture()
        let engine = try StatisticsEngine(databaseURL: fixture.databaseURL)
        let source = try await engine.registerDevice(referenceID: 1, descriptor: fixture.descriptor(fingerprint: "source", name: "Source"))
        let target = try await engine.registerDevice(referenceID: 2, descriptor: fixture.descriptor(fingerprint: "target", name: "Target"))
        await engine.record(deviceID: source, key: HIDKeyID(usagePage: 0x07, usage: 0x04))
        try await engine.mergeDevice(source: source, target: target)

        let resolved = try await engine.registerDevice(referenceID: 3, descriptor: fixture.descriptor(fingerprint: "source", name: "Source"))
        #expect(resolved == target)
    }

    @Test func prunesOnlyOldMinuteRows() async throws {
        let fixture = try Fixture()
        let engine = try StatisticsEngine(databaseURL: fixture.databaseURL)
        let device = try await engine.registerDevice(referenceID: 1, descriptor: fixture.descriptor(fingerprint: "device", name: "Device"))
        let old = Date().addingTimeInterval(-31 * 24 * 60 * 60)
        await engine.record(deviceID: device, key: HIDKeyID(usagePage: 0x07, usage: 0x04), at: old)
        #expect(try await engine.flush())
        try await engine.performMaintenance()

        let minute = try await engine.reader.snapshot(
            for: StatisticsQuery(granularity: .minute, deviceID: nil, now: old)
        )
        let hour = try await engine.reader.snapshot(
            for: StatisticsQuery(granularity: .hour, deviceID: nil, now: old)
        )
        #expect(minute.trend.isEmpty)
        #expect(hour.trend.reduce(0) { $0 + $1.count } == 1)
    }

    @Test func engineRejectsReservedUsagesAtStorageBoundary() async throws {
        let fixture = try Fixture()
        let engine = try StatisticsEngine(databaseURL: fixture.databaseURL)
        let device = try await engine.registerDevice(
            referenceID: 1,
            descriptor: fixture.descriptor(fingerprint: "reserved", name: "Reserved")
        )
        await engine.record(deviceID: device, key: HIDKeyID(usagePage: 0x07, usage: 0))
        await engine.record(deviceID: device, key: HIDKeyID(usagePage: 0x07, usage: 1))
        #expect(try await engine.flush() == false)
        let snapshot = try await engine.dashboard()
        #expect(snapshot.todayTotal == 0)
    }

    @Test func failedDestructiveMutationsRetainPendingCountsForTheNextFlush() async throws {
        for mutation in FailingDestructiveMutation.allCases {
            let fixture = try Fixture()
            let engine = try StatisticsEngine(databaseURL: fixture.databaseURL)
            let device = try await engine.registerDevice(
                referenceID: 1,
                descriptor: fixture.descriptor(
                    fingerprint: "failure-\(mutation)",
                    name: "Failure \(mutation)"
                )
            )
            let key = HIDKeyID(usagePage: 0x07, usage: 0x04)
            let date = Date()
            await engine.record(deviceID: device, key: key, at: date)
            #expect(try await engine.flush())
            await engine.record(deviceID: device, key: key, at: date)

            try fixture.executeSQL("""
                CREATE TRIGGER fail_minute_delete
                BEFORE DELETE ON minute_device_counts
                BEGIN SELECT RAISE(ABORT, 'injected destructive failure'); END;
                """)
            var mutationFailed = false
            do {
                switch mutation {
                case .clearDevice:
                    try await engine.clearCounts(deviceID: device)
                case .clearAll:
                    try await engine.clearAllCounts()
                case .deleteDevice:
                    try await engine.deleteDevice(id: device)
                }
            } catch {
                mutationFailed = true
            }
            #expect(mutationFailed)
            try fixture.executeSQL("DROP TRIGGER fail_minute_delete;")

            #expect(try await engine.flush())
            let snapshot = try await engine.dashboard()
            #expect(snapshot.todayTotal == 2)
        }
    }

    @Test func referenceRoutingSurvivesMergeAndDropsDeletedDevices() async throws {
        let fixture = try Fixture()
        let engine = try StatisticsEngine(databaseURL: fixture.databaseURL)
        let source = try await engine.registerDevice(
            referenceID: 1,
            descriptor: fixture.descriptor(fingerprint: "route-source", name: "Route Source")
        )
        let target = try await engine.registerDevice(
            referenceID: 2,
            descriptor: fixture.descriptor(fingerprint: "route-target", name: "Route Target")
        )
        let survivor = try await engine.registerDevice(
            referenceID: 3,
            descriptor: fixture.descriptor(fingerprint: "route-survivor", name: "Route Survivor")
        )
        let key = HIDKeyID(usagePage: 0x07, usage: 0x04)

        try await engine.mergeDevice(source: source, target: target)
        await engine.record(referenceID: 1, key: key)
        #expect(try await engine.flush())
        #expect(try await engine.dashboard().devices.first { $0.id == target }?.totalCount == 1)

        try await engine.deleteDevice(id: target)
        await engine.record(referenceID: 1, key: key)
        await engine.record(referenceID: 2, key: key)
        await engine.record(referenceID: 3, key: key)
        #expect(try await engine.flush())
        let dashboard = try await engine.dashboard()
        #expect(dashboard.todayTotal == 1)
        #expect(dashboard.devices.first { $0.id == survivor }?.totalCount == 1)
    }

    @Test func flushReportsWhetherAnythingWasWritten() async throws {
        let fixture = try Fixture()
        let engine = try StatisticsEngine(databaseURL: fixture.databaseURL)
        #expect(try await engine.flush() == false)

        let device = try await engine.registerDevice(
            referenceID: 1,
            descriptor: fixture.descriptor(fingerprint: "flush", name: "Flush")
        )
        await engine.record(deviceID: device, key: HIDKeyID(usagePage: 0x07, usage: 0x04))
        #expect(try await engine.flush() == true)
        #expect(try await engine.flush() == false)
        #expect(try await engine.dashboard().devices.first?.totalCount == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func recordSchedulesOneFlushThatPersistsCountsAndNotifiesTheHandler() async throws {
        let fixture = try Fixture()
        let engine = try StatisticsEngine(databaseURL: fixture.databaseURL, flushDelay: .milliseconds(20))
        let recorder = FlushRecorder()
        await engine.setFlushHandler { error in await recorder.record(error) }
        let device = try await engine.registerDevice(
            referenceID: 1,
            descriptor: fixture.descriptor(fingerprint: "scheduled", name: "Scheduled")
        )
        let key = HIDKeyID(usagePage: 0x07, usage: 0x04)

        // Nothing is scheduled until the first keystroke arrives.
        #expect(await engine.scheduledFlush == nil)

        await engine.record(deviceID: device, key: key)
        await engine.record(deviceID: device, key: key)
        await recorder.wait(until: 1)
        #expect(await recorder.errors.count == 1)
        #expect(await recorder.errors[0] == nil)
        #expect(try await engine.dashboard().devices.first?.totalCount == 2)

        // The slot is free again, so the next keystroke schedules the next flush.
        #expect(await engine.scheduledFlush == nil)
        await engine.record(deviceID: device, key: key)
        await recorder.wait(until: 2)
        #expect(try await engine.dashboard().devices.first?.totalCount == 3)
        #expect(await engine.scheduledFlush == nil)
    }

    @Test func recordsWhileAFlushIsScheduledDoNotScheduleAnother() async throws {
        let fixture = try Fixture()
        // Long enough that the task never fires inside this test.
        let engine = try StatisticsEngine(databaseURL: fixture.databaseURL, flushDelay: .seconds(60))
        let device = try await engine.registerDevice(
            referenceID: 1,
            descriptor: fixture.descriptor(fingerprint: "single", name: "Single")
        )
        let key = HIDKeyID(usagePage: 0x07, usage: 0x04)

        // Reserved usages are not counted, so they schedule nothing.
        await engine.record(deviceID: device, key: HIDKeyID(usagePage: 0x07, usage: 0))
        #expect(await engine.scheduledFlush == nil)

        await engine.record(deviceID: device, key: key)
        let scheduled = try #require(await engine.scheduledFlush)
        await engine.record(deviceID: device, key: key)
        await engine.record(referenceID: 1, key: key)
        #expect(await engine.scheduledFlush == scheduled)

        scheduled.cancel()
        #expect(try await engine.flush())
    }

    @Test(.timeLimit(.minutes(1)))
    func failedScheduledFlushKeepsPendingCountsAndReportsTheError() async throws {
        let fixture = try Fixture()
        let engine = try StatisticsEngine(databaseURL: fixture.databaseURL, flushDelay: .milliseconds(20))
        let recorder = FlushRecorder()
        await engine.setFlushHandler { error in await recorder.record(error) }
        let device = try await engine.registerDevice(
            referenceID: 1,
            descriptor: fixture.descriptor(fingerprint: "failing", name: "Failing")
        )
        let key = HIDKeyID(usagePage: 0x07, usage: 0x04)

        try fixture.executeSQL("""
            CREATE TRIGGER fail_minute_insert
            BEFORE INSERT ON minute_device_counts
            BEGIN SELECT RAISE(ABORT, 'injected flush failure'); END;
            """)
        await engine.record(deviceID: device, key: key)
        await recorder.wait(until: 1)
        let reported = try #require(await recorder.errors[0])
        #expect(reported.localizedDescription.contains("injected flush failure"))
        #expect(try await engine.dashboard().todayTotal == 0)
        #expect(await engine.scheduledFlush == nil)

        // The count survived, and the next keystroke schedules another attempt.
        try fixture.executeSQL("DROP TRIGGER fail_minute_insert;")
        await engine.record(deviceID: device, key: key)
        await recorder.wait(until: 2)
        #expect(await recorder.errors[1] == nil)
        #expect(try await engine.dashboard().todayTotal == 2)
    }
}

private enum FailingDestructiveMutation: String, CaseIterable {
    case clearDevice
    case clearAll
    case deleteDevice
}

private struct Fixture {
    let root: URL
    var databaseURL: URL { root.appending(path: "test.sqlite") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func descriptor(fingerprint: String, name: String) -> DeviceDescriptor {
        DeviceDescriptor(
            observedFingerprint: fingerprint,
            suggestedName: name,
            manufacturer: "Test",
            product: name,
            vendorID: 1,
            productID: 2,
            transport: "USB",
            isBuiltIn: false
        )
    }

    func executeSQL(_ sql: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            throw StoreError.open("无法打开故障注入连接")
        }
        defer { sqlite3_close(database) }

        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        guard result == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? "unknown sqlite error"
            sqlite3_free(message)
            throw StoreError.execute(detail)
        }
    }
}

private actor FlushRecorder {
    private(set) var errors: [(any Error)?] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func record(_ error: (any Error)?) {
        errors.append(error)
        let ready = waiters.filter { errors.count >= $0.0 }
        waiters.removeAll { errors.count >= $0.0 }
        ready.forEach { $0.1.resume() }
    }

    func wait(until expected: Int) async {
        if errors.count >= expected { return }
        await withCheckedContinuation { waiters.append((expected, $0)) }
    }
}
