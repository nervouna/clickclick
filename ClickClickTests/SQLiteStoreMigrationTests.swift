import Foundation
import SQLite3
import Testing
@testable import ClickClick

struct SQLiteStoreMigrationTests {
    @Test func migrationPreservesAllFiveTrendGranularities() async throws {
        let fixture = try LegacyStoreFixture()
        try fixture.createCanonicalV1()
        try fixture.addAlignedLegacyTimeSeries()
        _ = try SQLiteStore(url: fixture.databaseURL)
        let reader = try StatisticsReader(databaseURL: fixture.databaseURL)
        let calendar = fixture.calendar
        let from = try #require(fixture.date("2026-01-01"))
        let to = try #require(fixture.date("2026-03-01"))

        for granularity in TrendGranularity.allCases {
            let points = try await reader.trend(
                granularity: granularity,
                from: from,
                to: to,
                deviceID: fixture.visibleID,
                calendar: calendar
            )
            #expect(
                points.reduce(0) { $0 + $1.count } == 39,
                "\(granularity.rawValue) migration total changed"
            )
        }
    }

    @Test func migratesV1OnceCreatesBackupAndBackfillsEveryReadModel() throws {
        let fixture = try LegacyStoreFixture()
        try fixture.createCanonicalV1()

        do {
            let store = try SQLiteStore(url: fixture.databaseURL)
            #expect(try store.revision() == 0)

            let devices = try store.fetchDevices(connected: [])
            #expect(devices.first(where: { $0.id == fixture.visibleID })?.totalCount == 39)
            #expect(devices.first(where: { $0.id == fixture.hiddenID })?.totalCount == 17)

            let daily = try store.dailyTrendRows(
                fromDay: "2026-01-01",
                toDay: "2026-02-28",
                deviceID: fixture.visibleID
            )
            #expect(daily.map(\.count).reduce(0, +) == 39)
            #expect(daily.count == 5)

            let keys = try store.keyCounts(
                fromDay: "2026-01-01",
                toDay: "2026-02-28",
                deviceID: fixture.visibleID
            )
            #expect(keys.reduce(0) { $0 + $1.count } == 39)
            #expect(keys.first(where: { $0.key.usage == 4 })?.count == 32)
            #expect(keys.first(where: { $0.key.usage == 5 })?.count == 7)
            #expect(
                try store.keyCounts(
                    fromDay: "2026-01-01",
                    toDay: "2026-02-28",
                    deviceID: fixture.hiddenID
                ).isEmpty
            )
        }

        #expect(FileManager.default.fileExists(atPath: fixture.backupURL.path))
        #expect(try fixture.int("PRAGMA user_version") == 2)
        #expect(try fixture.int("SELECT SUM(count) FROM daily_device_counts") == 56)
        #expect(try fixture.int("SELECT SUM(count) FROM monthly_device_key_counts") == 56)
        #expect(try fixture.int("SELECT SUM(count) FROM device_total_counts") == 56)

        // A second open must not add the canonical rows again or replace the
        // one-time v1 backup.
        let backupAttributes = try FileManager.default.attributesOfItem(atPath: fixture.backupURL.path)
        let backupDate = backupAttributes[.modificationDate] as? Date
        _ = try SQLiteStore(url: fixture.databaseURL)
        #expect(try fixture.int("SELECT SUM(count) FROM daily_device_counts") == 56)
        #expect(
            (try FileManager.default.attributesOfItem(atPath: fixture.backupURL.path)[.modificationDate] as? Date)
                == backupDate
        )

        let backup = try LegacyStoreFixture.readOnly(url: fixture.backupURL)
        defer { sqlite3_close(backup) }
        #expect(try LegacyStoreFixture.int("PRAGMA user_version", database: backup) == 0)
        #expect(
            try LegacyStoreFixture.int(
                "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='daily_device_counts')",
                database: backup
            ) == 0
        )
    }

    @Test func migrationRepairsReservedKeysBeforeBackfillAndAdjustsTimeSeries() throws {
        let fixture = try LegacyStoreFixture()
        try fixture.createCanonicalV1()
        let date = Date()
        let day = TimeBuckets.localDay(for: date)
        let minute = TimeBuckets.minute(for: date)
        let hour = TimeBuckets.hour(for: date)
        try fixture.execute("""
            INSERT INTO minute_device_counts VALUES (\(minute), '\(fixture.visibleID.uuidString)', 9);
            INSERT INTO hourly_device_counts VALUES (\(hour), '\(fixture.visibleID.uuidString)', 9);
            INSERT INTO daily_device_key_counts VALUES
                ('\(day)', '\(fixture.visibleID.uuidString)', 7, 0, 4),
                ('\(day)', '\(fixture.visibleID.uuidString)', 7, 6, 5);
            """)

        let store = try SQLiteStore(url: fixture.databaseURL)
        #expect(
            try store.keyCounts(fromDay: day, toDay: day, deviceID: fixture.visibleID)
                == [KeyCount(key: HIDKeyID(usagePage: 7, usage: 6), count: 5)]
        )
        #expect(
            try store.trendRows(
                from: date.addingTimeInterval(-60),
                to: date.addingTimeInterval(60),
                minute: true,
                deviceID: fixture.visibleID
            ).reduce(0) { $0 + $1.3 } == 5
        )
        #expect(
            try store.trendRows(
                from: date.addingTimeInterval(-3_600),
                to: date.addingTimeInterval(3_600),
                minute: false,
                deviceID: fixture.visibleID
            ).reduce(0) { $0 + $1.3 } == 5
        )
        #expect(
            try fixture.int(
                "SELECT COUNT(*) FROM daily_device_key_counts WHERE (usage_page = 7 AND usage BETWEEN 0 AND 3) OR (usage_page = 12 AND usage = 0)"
            ) == 0
        )
        #expect(try fixture.int("SELECT SUM(count) FROM device_total_counts") == 61)
    }

    @Test func keyQueryCombinesPartialEdgesWithCompleteMiddleMonths() throws {
        let fixture = try LegacyStoreFixture()
        try fixture.createCanonicalV1()
        let store = try SQLiteStore(url: fixture.databaseURL)
        _ = try store.apply([
            CountIncrement(
                minute: 0,
                hour: 0,
                localDay: "2026-03-15",
                deviceID: fixture.visibleID,
                key: HIDKeyID(usagePage: 7, usage: 4),
                count: 19
            )
        ])

        // Jan and Mar are daily edge reads; all of Feb is served by the month
        // rollup. The result keeps the old inclusive local-day semantics.
        let result = try store.keyCounts(
            fromDay: "2026-01-15",
            toDay: "2026-03-15",
            deviceID: fixture.visibleID
        )
        #expect(result.reduce(0) { $0 + $1.count } == 55)
        #expect(result.first(where: { $0.key.usage == 4 })?.count == 48)
        #expect(result.first(where: { $0.key.usage == 5 })?.count == 7)
        #expect(
            try store.keyCounts(
                fromDay: "2026-01-15",
                toDay: "2026-03-15",
                deviceID: fixture.hiddenID
            ).isEmpty
        )
    }

    @Test func canonicalSignatureDetectsLegacyWriterDriftAndRebuildsIdempotently() throws {
        let fixture = try LegacyStoreFixture()
        try fixture.createCanonicalV1()
        var priorRevision: Int64 = 0
        do {
            let store = try SQLiteStore(url: fixture.databaseURL)
            priorRevision = try store.revision()
        }

        // Simulate an old executable writing only the canonical v1 table after
        // this process has already migrated the database.
        try fixture.execute(
            "UPDATE daily_device_key_counts SET count = count + 4 WHERE device_id = '\(fixture.visibleID.uuidString)' AND local_day = '2026-01-15' AND usage = 4;"
        )
        do {
            let reopened = try SQLiteStore(url: fixture.databaseURL)
            #expect(try reopened.revision() == priorRevision + 1)
            #expect(
                try reopened.fetchDevices(connected: []).first(where: { $0.id == fixture.visibleID })?.totalCount == 43
            )
            #expect(
                try reopened.keyCounts(
                    fromDay: "2026-01-01",
                    toDay: "2026-02-28",
                    deviceID: fixture.visibleID
                ).reduce(0) { $0 + $1.count } == 43
            )
        }

        let rebuiltRevision = try fixture.int("SELECT revision FROM statistics_state")
        _ = try SQLiteStore(url: fixture.databaseURL)
        #expect(try fixture.int("SELECT revision FROM statistics_state") == rebuiltRevision)

        // A legacy merge preserves the global total, so a total-only startup
        // comparison would miss it. Persistent canonical triggers mark this
        // rewrite dirty and force the device-level derived rows to rebuild.
        try fixture.execute("""
            INSERT INTO daily_device_key_counts (local_day, device_id, usage_page, usage, count)
            SELECT local_day, '\(fixture.visibleID.uuidString)', usage_page, usage, count
            FROM daily_device_key_counts WHERE device_id = '\(fixture.hiddenID.uuidString)'
            ON CONFLICT(local_day, device_id, usage_page, usage)
            DO UPDATE SET count = count + excluded.count;
            DELETE FROM daily_device_key_counts WHERE device_id = '\(fixture.hiddenID.uuidString)';
            UPDATE device_aliases SET device_id = '\(fixture.visibleID.uuidString)'
            WHERE device_id = '\(fixture.hiddenID.uuidString)';
            DELETE FROM devices WHERE id = '\(fixture.hiddenID.uuidString)';
            """)
        let beforeLegacyMergeRecovery = try fixture.int("SELECT revision FROM statistics_state")
        do {
            let recovered = try SQLiteStore(url: fixture.databaseURL)
            #expect(try recovered.revision() == beforeLegacyMergeRecovery + 1)
            let devices = try recovered.fetchDevices(connected: [])
            #expect(devices.count == 1)
            #expect(devices[0].id == fixture.visibleID)
            #expect(devices[0].totalCount == 60)
        }
    }

    @Test func migrationFailureRollsBackSchemaAndCanonicalRows() throws {
        let fixture = try LegacyStoreFixture()
        try fixture.createCanonicalV1()
        // A legacy/corrupt object with the v2 name makes the backfill fail. All
        // migration mutations, including invalid-key repair, must roll back.
        try fixture.execute("CREATE TABLE daily_device_counts (unexpected TEXT);")

        #expect(throws: (any Error).self) {
            _ = try SQLiteStore(url: fixture.databaseURL)
        }
        #expect(FileManager.default.fileExists(atPath: fixture.backupURL.path))
        #expect(try fixture.int("PRAGMA user_version") == 0)
        #expect(try fixture.int("SELECT SUM(count) FROM daily_device_key_counts") == 56)
        #expect(
            try fixture.int(
                "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='monthly_device_key_counts')"
            ) == 0
        )
    }

    @Test func hiddenFiltersAndMutationsStayConsistentAcrossAllAggregates() throws {
        let fixture = try LegacyStoreFixture()
        try fixture.createCanonicalV1()
        let store = try SQLiteStore(url: fixture.databaseURL)

        // Hidden devices are absent even from key queries without an explicit
        // device selector.
        let visibleKeys = try store.keyCounts(
            fromDay: "2026-01-01",
            toDay: "2026-02-28",
            deviceID: nil
        )
        #expect(visibleKeys.reduce(0) { $0 + $1.count } == 39)

        let revisionBeforeMerge = try store.revision()
        let mergeRevision = try store.mergeDevice(source: fixture.hiddenID, target: fixture.visibleID)
        #expect(mergeRevision == revisionBeforeMerge + 1)
        let mergedDevices = try store.fetchDevices(connected: [])
        #expect(mergedDevices.count == 1)
        #expect(mergedDevices[0].totalCount == 56)
        #expect(
            try store.keyCounts(
                fromDay: "2026-01-01",
                toDay: "2026-02-28",
                deviceID: fixture.visibleID
            ).reduce(0) { $0 + $1.count } == 56
        )

        let clearRevision = try store.clearCounts(deviceID: fixture.visibleID)
        #expect(clearRevision == mergeRevision + 1)
        #expect(try store.fetchDevices(connected: [fixture.visibleID])[0].totalCount == 0)
        #expect(try store.dailyTrendRows(fromDay: "2026-01-01", toDay: "2026-02-28", deviceID: nil).isEmpty)
        #expect(try store.keyCounts(fromDay: "2026-01-01", toDay: "2026-02-28", deviceID: nil).isEmpty)
        #expect(try fixture.int("SELECT SUM(count) FROM monthly_device_key_counts") == 0)

        // A partially written/legacy process may leave a time-series row even
        // when canonical daily rows are empty. Clear operations still remove
        // every aggregate and publish a revision.
        try fixture.execute(
            "INSERT INTO minute_device_counts VALUES (123, '\(fixture.visibleID.uuidString)', 9);"
        )
        let orphanRevision = try store.clearCounts(deviceID: fixture.visibleID)
        #expect(orphanRevision == clearRevision + 1)
        #expect(try fixture.int("SELECT COUNT(*) FROM minute_device_counts") == 0)

        try fixture.execute(
            "INSERT INTO hourly_device_counts VALUES (456, '\(fixture.visibleID.uuidString)', 7);"
        )
        let allRevision = try store.clearAllCounts()
        #expect(allRevision == orphanRevision + 1)
        #expect(try fixture.int("SELECT COUNT(*) FROM hourly_device_counts") == 0)
    }

    @Test func applyPreaggregatesBucketsAndAdvancesRevisionExactlyOnce() throws {
        let fixture = try LegacyStoreFixture()
        let store = try SQLiteStore(url: fixture.databaseURL)
        let deviceID = try store.resolveDevice(fixture.descriptor)
        let baseline = try store.revision()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let minute = TimeBuckets.minute(for: date)
        let hour = TimeBuckets.hour(for: date)
        let day = TimeBuckets.localDay(for: date)
        let revision = try store.apply([
            CountIncrement(
                minute: minute,
                hour: hour,
                localDay: day,
                deviceID: deviceID,
                key: HIDKeyID(usagePage: 7, usage: 4),
                count: 3
            ),
            CountIncrement(
                minute: minute,
                hour: hour,
                localDay: day,
                deviceID: deviceID,
                key: HIDKeyID(usagePage: 7, usage: 5),
                count: 5
            )
        ])

        #expect(revision == baseline + 1)
        #expect(try fixture.int("SELECT COUNT(*) FROM minute_device_counts") == 1)
        #expect(try fixture.int("SELECT count FROM minute_device_counts") == 8)
        #expect(try fixture.int("SELECT COUNT(*) FROM hourly_device_counts") == 1)
        #expect(try fixture.int("SELECT count FROM daily_device_counts") == 8)
        #expect(try fixture.int("SELECT count FROM device_total_counts") == 8)
        #expect(try fixture.int("SELECT SUM(count) FROM monthly_device_key_counts") == 8)
        #expect(try store.apply([]) == revision)
    }
}

private final class LegacyStoreFixture {
    let root: URL
    let visibleID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let hiddenID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    var databaseURL: URL { root.appending(path: "clickclick.sqlite") }
    var backupURL: URL { root.appending(path: SQLiteStore.backupName) }
    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = .autoupdatingCurrent
        return value
    }
    var descriptor: DeviceDescriptor {
        DeviceDescriptor(
            observedFingerprint: "fixture-device",
            suggestedName: "Fixture",
            manufacturer: "Test",
            product: "Fixture",
            vendorID: 1,
            productID: 2,
            transport: "USB",
            isBuiltIn: false
        )
    }

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func createCanonicalV1() throws {
        try execute("""
        CREATE TABLE devices (
            id TEXT PRIMARY KEY, display_name TEXT NOT NULL, manufacturer TEXT, product TEXT,
            vendor_id INTEGER NOT NULL, product_id INTEGER NOT NULL, transport TEXT,
            is_built_in INTEGER NOT NULL, is_hidden INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL, last_seen_at INTEGER NOT NULL
        );
        CREATE TABLE device_aliases (
            fingerprint TEXT PRIMARY KEY,
            device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE
        );
        CREATE TABLE minute_device_counts (
            bucket_start INTEGER NOT NULL, device_id TEXT NOT NULL, count INTEGER NOT NULL,
            PRIMARY KEY (bucket_start, device_id)
        );
        CREATE TABLE hourly_device_counts (
            bucket_start INTEGER NOT NULL, device_id TEXT NOT NULL, count INTEGER NOT NULL,
            PRIMARY KEY (bucket_start, device_id)
        );
        CREATE TABLE daily_device_key_counts (
            local_day TEXT NOT NULL, device_id TEXT NOT NULL, usage_page INTEGER NOT NULL,
            usage INTEGER NOT NULL, count INTEGER NOT NULL,
            PRIMARY KEY (local_day, device_id, usage_page, usage)
        );
        INSERT INTO devices VALUES
            ('\(visibleID.uuidString)', 'Visible', 'Test', 'Visible', 1, 2, 'USB', 0, 0, 1, 1),
            ('\(hiddenID.uuidString)', 'Hidden', 'Test', 'Hidden', 1, 3, 'USB', 0, 1, 1, 1);
        INSERT INTO device_aliases VALUES
            ('visible', '\(visibleID.uuidString)'), ('hidden', '\(hiddenID.uuidString)');
        INSERT INTO daily_device_key_counts VALUES
            ('2026-01-01', '\(visibleID.uuidString)', 7, 4, 3),
            ('2026-01-15', '\(visibleID.uuidString)', 7, 4, 5),
            ('2026-01-31', '\(visibleID.uuidString)', 7, 5, 7),
            ('2026-02-01', '\(visibleID.uuidString)', 7, 4, 11),
            ('2026-02-28', '\(visibleID.uuidString)', 7, 4, 13),
            ('2026-01-15', '\(hiddenID.uuidString)', 7, 4, 17);
        """)
    }

    func addAlignedLegacyTimeSeries() throws {
        let visible: [(String, Int64)] = [
            ("2026-01-01", 3), ("2026-01-15", 5), ("2026-01-31", 7),
            ("2026-02-01", 11), ("2026-02-28", 13)
        ]
        for (day, count) in visible {
            guard let date = date(day) else { throw LegacyFixtureError.sqlite("date") }
            try execute("""
                INSERT INTO minute_device_counts VALUES
                    (\(TimeBuckets.minute(for: date)), '\(visibleID.uuidString)', \(count));
                INSERT INTO hourly_device_counts VALUES
                    (\(TimeBuckets.hour(for: date)), '\(visibleID.uuidString)', \(count));
                """)
        }
        guard let hiddenDate = date("2026-01-15") else { throw LegacyFixtureError.sqlite("date") }
        try execute("""
            INSERT INTO minute_device_counts VALUES
                (\(TimeBuckets.minute(for: hiddenDate)), '\(hiddenID.uuidString)', 17);
            INSERT INTO hourly_device_counts VALUES
                (\(TimeBuckets.hour(for: hiddenDate)), '\(hiddenID.uuidString)', 17);
            """)
    }

    func date(_ localDay: String) -> Date? {
        let values = localDay.split(separator: "-").compactMap { Int($0) }
        guard values.count == 3 else { return nil }
        return calendar.date(
            from: DateComponents(year: values[0], month: values[1], day: values[2], hour: 12)
        )
    }

    func execute(_ sql: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK else {
            defer { sqlite3_close(database) }
            throw LegacyFixtureError.sqlite("open")
        }
        defer { sqlite3_close(database) }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw LegacyFixtureError.sqlite(message)
        }
    }

    func int(_ sql: String) throws -> Int64 {
        let database = try Self.readOnly(url: databaseURL)
        defer { sqlite3_close(database) }
        return try Self.int(sql, database: database)
    }

    static func readOnly(url: URL) throws -> OpaquePointer? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            defer { sqlite3_close(database) }
            throw LegacyFixtureError.sqlite("read-only open")
        }
        return database
    }

    static func int(_ sql: String, database: OpaquePointer?) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw LegacyFixtureError.sqlite("prepare")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw LegacyFixtureError.sqlite("step")
        }
        return sqlite3_column_int64(statement, 0)
    }
}

private enum LegacyFixtureError: Error {
    case sqlite(String)
}
