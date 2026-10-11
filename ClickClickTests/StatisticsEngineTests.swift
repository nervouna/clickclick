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
        try await engine.flush()

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
        try await engine.flush()
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
        try await engine.flush()
        let snapshot = (try await engine.dashboard()).snapshot
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
            _ = try await engine.flush()
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
                    _ = try await engine.clearCounts(deviceID: device)
                case .clearAll:
                    _ = try await engine.clearAllCounts()
                case .deleteDevice:
                    _ = try await engine.deleteDevice(id: device)
                }
            } catch {
                mutationFailed = true
            }
            #expect(mutationFailed)
            try fixture.executeSQL("DROP TRIGGER fail_minute_delete;")

            let recoveredFlush = try #require(try await engine.flush())
            #expect(recoveredFlush.deltas.reduce(Int64.zero) { $0 + $1.count } == 1)
            let snapshot = (try await engine.dashboard()).snapshot
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

        _ = try await engine.mergeDevice(source: source, target: target)
        await engine.record(referenceID: 1, key: key)
        _ = try #require(try await engine.flush())
        #expect((try await engine.dashboard()).snapshot.devices.first { $0.id == target }?.totalCount == 1)

        _ = try await engine.deleteDevice(id: target)
        await engine.record(referenceID: 1, key: key)
        await engine.record(referenceID: 2, key: key)
        await engine.record(referenceID: 3, key: key)
        let flush = try #require(try await engine.flush())
        #expect(flush.deltas.map(\.deviceID) == [survivor])
        #expect((try await engine.dashboard()).snapshot.todayTotal == 1)
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
