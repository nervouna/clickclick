import Foundation
import SQLite3
import Testing
@testable import ClickClick

struct SQLiteStoreTests {
    @Test func freshDatabaseGetsTheCurrentSchema() throws {
        let fixture = try StoreFixture()
        let store = try SQLiteStore(url: fixture.databaseURL)

        #expect(try store.revision() == 0)
        #expect(try fixture.int("PRAGMA user_version") == Int64(SQLiteStore.schemaVersion))
        #expect(try fixture.int("SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger'") == 0)
        #expect(try fixture.int("SELECT COUNT(*) FROM pragma_table_info('statistics_state')") == 2)
    }

    @Test func keyQueryCombinesPartialEdgesWithCompleteMiddleMonths() throws {
        let fixture = try StoreFixture()
        let store = try SQLiteStore(url: fixture.databaseURL)
        let (visible, hidden) = try fixture.seed(store)
        try store.apply([
            CountIncrement(
                minute: 0,
                hour: 0,
                localDay: "2026-03-15",
                deviceID: visible,
                key: HIDKeyID(usagePage: 7, usage: 4),
                count: 19
            )
        ])

        // Jan and Mar are daily edge reads; all of Feb is served by the month
        // rollup. The result keeps inclusive local-day semantics.
        let result = try store.keyCounts(fromDay: "2026-01-15", toDay: "2026-03-15", deviceID: visible)
        #expect(result.reduce(0) { $0 + $1.count } == 55)
        #expect(result.first(where: { $0.key.usage == 4 })?.count == 48)
        #expect(result.first(where: { $0.key.usage == 5 })?.count == 7)
        #expect(
            try store.keyCounts(fromDay: "2026-01-15", toDay: "2026-03-15", deviceID: hidden).isEmpty
        )
    }

    @Test func hiddenFiltersAndMutationsStayConsistentAcrossAllCountTables() throws {
        let fixture = try StoreFixture()
        let store = try SQLiteStore(url: fixture.databaseURL)
        let (visible, hidden) = try fixture.seed(store)
        try fixture.expectEveryCountTable(total: 56)

        // Hidden devices are absent from every query without a device selector.
        #expect(
            try store.keyCounts(fromDay: "2026-01-01", toDay: "2026-02-28", deviceID: nil)
                .reduce(0) { $0 + $1.count } == 39
        )
        #expect(
            try store.dailyTrendRows(fromDay: "2026-01-01", toDay: "2026-02-28", deviceID: nil)
                .map(\.count).reduce(0, +) == 39
        )
        let devices = try store.fetchDevices(connected: [])
        #expect(devices.first(where: { $0.id == visible })?.totalCount == 39)
        #expect(devices.first(where: { $0.id == hidden })?.totalCount == 17)

        let revisionBeforeMerge = try store.revision()
        let mergeRevision = try store.mergeDevice(source: hidden, target: visible)
        #expect(mergeRevision == revisionBeforeMerge + 1)
        let merged = try store.fetchDevices(connected: [])
        #expect(merged.count == 1)
        #expect(merged[0].totalCount == 56)
        try fixture.expectEveryCountTable(total: 56)

        let clearRevision = try store.clearCounts(deviceID: visible)
        #expect(clearRevision == mergeRevision + 1)
        #expect(try store.fetchDevices(connected: [visible])[0].totalCount == 0)
        #expect(try store.dailyTrendRows(fromDay: "2026-01-01", toDay: "2026-02-28", deviceID: nil).isEmpty)
        #expect(try store.keyCounts(fromDay: "2026-01-01", toDay: "2026-02-28", deviceID: nil).isEmpty)
        try fixture.expectEveryCountTable(total: 0)

        let applyRevision = try store.apply([
            CountIncrement(
                minute: 60,
                hour: 0,
                localDay: "2026-03-01",
                deviceID: visible,
                key: HIDKeyID(usagePage: 7, usage: 4),
                count: 4
            )
        ])
        try fixture.expectEveryCountTable(total: 4)
        #expect(try store.clearAllCounts() == applyRevision + 1)
        try fixture.expectEveryCountTable(total: 0)
        #expect(try store.fetchDevices(connected: [])[0].id == visible)

        let deleteRevision = try store.deleteDevice(id: visible)
        #expect(deleteRevision == applyRevision + 2)
        #expect(try store.fetchDevices(connected: []).isEmpty)
    }

    @Test func applyPreaggregatesBucketsAndAdvancesRevisionExactlyOnce() throws {
        let fixture = try StoreFixture()
        let store = try SQLiteStore(url: fixture.databaseURL)
        let deviceID = try store.resolveDevice(fixture.descriptor("fixture-device", name: "Fixture"))
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

    @Test func cleanMutationNoOpsDoNotAdvanceRevision() throws {
        let fixture = try StoreFixture()
        let store = try SQLiteStore(url: fixture.databaseURL)
        let (visible, _) = try fixture.seed(store)
        let baseline = try store.revision()

        #expect(try store.mergeDevice(source: visible, target: visible) == baseline)
        #expect(try store.clearCounts(deviceID: UUID()) == baseline)
        #expect(try store.deleteDevice(id: UUID()) == baseline)
        #expect(try store.apply([]) == baseline)
        #expect(try store.revision() == baseline)

        try store.clearAllCounts()
        let cleared = try store.revision()
        #expect(cleared == baseline + 1)
        #expect(try store.clearAllCounts() == cleared)
        #expect(try store.pruneMinuteData(before: Int64.max) == cleared)
    }

    @Test func opensSchemaV2DatabaseAndDropsTheDriftMachinery() throws {
        let fixture = try StoreFixture()
        let device = "11111111-1111-1111-1111-111111111111"
        try fixture.execute("""
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
                bucket_start INTEGER NOT NULL,
                device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
                count INTEGER NOT NULL CHECK(count >= 0),
                PRIMARY KEY (bucket_start, device_id)
            );
            CREATE TABLE hourly_device_counts (
                bucket_start INTEGER NOT NULL,
                device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
                count INTEGER NOT NULL CHECK(count >= 0),
                PRIMARY KEY (bucket_start, device_id)
            );
            CREATE TABLE daily_device_key_counts (
                local_day TEXT NOT NULL,
                device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
                usage_page INTEGER NOT NULL, usage INTEGER NOT NULL,
                count INTEGER NOT NULL CHECK(count >= 0),
                PRIMARY KEY (local_day, device_id, usage_page, usage)
            );
            CREATE TABLE daily_device_counts (
                local_day TEXT NOT NULL,
                device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
                count INTEGER NOT NULL CHECK(count >= 0),
                PRIMARY KEY (local_day, device_id)
            );
            CREATE TABLE monthly_device_key_counts (
                local_month TEXT NOT NULL,
                device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
                usage_page INTEGER NOT NULL, usage INTEGER NOT NULL,
                count INTEGER NOT NULL CHECK(count >= 0),
                PRIMARY KEY (local_month, device_id, usage_page, usage)
            );
            CREATE TABLE device_total_counts (
                device_id TEXT PRIMARY KEY REFERENCES devices(id) ON DELETE CASCADE,
                count INTEGER NOT NULL CHECK(count >= 0)
            );
            CREATE TABLE statistics_state (
                singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
                revision INTEGER NOT NULL,
                canonical_signature TEXT NOT NULL
            );
            CREATE TRIGGER mark_statistics_dirty_after_daily_insert
            AFTER INSERT ON daily_device_key_counts BEGIN
                UPDATE statistics_state SET canonical_signature = 'dirty' WHERE singleton = 1;
            END;
            CREATE TRIGGER mark_statistics_dirty_after_daily_update
            AFTER UPDATE ON daily_device_key_counts BEGIN
                UPDATE statistics_state SET canonical_signature = 'dirty' WHERE singleton = 1;
            END;
            CREATE TRIGGER mark_statistics_dirty_after_daily_delete
            AFTER DELETE ON daily_device_key_counts BEGIN
                UPDATE statistics_state SET canonical_signature = 'dirty' WHERE singleton = 1;
            END;
            CREATE INDEX idx_daily_key_device ON daily_device_key_counts(device_id, local_day);
            INSERT INTO devices VALUES ('\(device)', 'Legacy', 'Test', 'Legacy', 1, 2, 'USB', 0, 0, 1, 1);
            INSERT INTO device_aliases VALUES ('legacy', '\(device)');
            INSERT INTO minute_device_counts VALUES (60, '\(device)', 5);
            INSERT INTO hourly_device_counts VALUES (0, '\(device)', 5);
            INSERT INTO daily_device_key_counts VALUES ('2026-01-15', '\(device)', 7, 4, 5);
            INSERT INTO daily_device_counts VALUES ('2026-01-15', '\(device)', 5);
            INSERT INTO monthly_device_key_counts VALUES ('2026-01', '\(device)', 7, 4, 5);
            INSERT INTO device_total_counts VALUES ('\(device)', 5);
            INSERT INTO statistics_state VALUES (1, 7, 'v1:5');
            PRAGMA user_version = 2;
            """)
        try Data("stale backup".utf8).write(to: fixture.backupURL)

        let store = try SQLiteStore(url: fixture.databaseURL)

        #expect(try fixture.int("PRAGMA user_version") == 3)
        #expect(try fixture.int("SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger'") == 0)
        #expect(
            try fixture.int(
                "SELECT COUNT(*) FROM pragma_table_info('statistics_state') WHERE name = 'canonical_signature'"
            ) == 0
        )
        #expect(!FileManager.default.fileExists(atPath: fixture.backupURL.path))
        #expect(try store.revision() == 7)
        try fixture.expectEveryCountTable(total: 5)
        #expect(try store.fetchDevices(connected: [])[0].totalCount == 5)

        // The migrated store keeps writing, and reopening it is a no-op.
        let id = try #require(UUID(uuidString: device))
        #expect(
            try store.apply([
                CountIncrement(
                    minute: 60,
                    hour: 0,
                    localDay: "2026-01-15",
                    deviceID: id,
                    key: HIDKeyID(usagePage: 7, usage: 4),
                    count: 2
                )
            ]) == 8
        )
        _ = try SQLiteStore(url: fixture.databaseURL)
        #expect(try fixture.int("PRAGMA user_version") == 3)
        #expect(try fixture.int("SELECT revision FROM statistics_state") == 8)
        try fixture.expectEveryCountTable(total: 7)
    }

    @Test func rejectsLegacyDatabaseAndLeavesItUntouched() throws {
        let fixture = try StoreFixture()
        try fixture.execute("""
            CREATE TABLE devices (
                id TEXT PRIMARY KEY, display_name TEXT NOT NULL, manufacturer TEXT, product TEXT,
                vendor_id INTEGER NOT NULL, product_id INTEGER NOT NULL, transport TEXT,
                is_built_in INTEGER NOT NULL, is_hidden INTEGER NOT NULL DEFAULT 0,
                created_at INTEGER NOT NULL, last_seen_at INTEGER NOT NULL
            );
            INSERT INTO devices VALUES ('11111111-1111-1111-1111-111111111111', 'Legacy', NULL, NULL, 1, 2, NULL, 0, 0, 1, 1);
            """)
        let before = try Data(contentsOf: fixture.databaseURL)

        do {
            _ = try SQLiteStore(url: fixture.databaseURL)
            Issue.record("A legacy database must not open")
        } catch StoreError.open(let message) {
            #expect(message.contains("不支持"))
        }

        #expect(try Data(contentsOf: fixture.databaseURL) == before)
        #expect(!FileManager.default.fileExists(atPath: fixture.databaseURL.path + "-wal"))
        #expect(try fixture.int("PRAGMA user_version") == 0)
        #expect(try fixture.int("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table'") == 1)
        #expect(try fixture.int("SELECT COUNT(*) FROM devices") == 1)
    }
}

private final class StoreFixture {
    let root: URL
    var databaseURL: URL { root.appending(path: "clickclick.sqlite") }
    var backupURL: URL { root.appending(path: "clickclick-v1-backup.sqlite") }
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = .autoupdatingCurrent
        return value
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

    func descriptor(_ fingerprint: String, name: String) -> DeviceDescriptor {
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

    /// Creates a visible device (39 counts) and a hidden one (17 counts) with
    /// matching rows in every count table.
    func seed(_ store: SQLiteStore) throws -> (visible: UUID, hidden: UUID) {
        let visible = try store.resolveDevice(descriptor("visible", name: "Visible"))
        let hidden = try store.resolveDevice(descriptor("hidden", name: "Hidden"))
        try store.setDeviceHidden(id: hidden, hidden: true)
        let rows: [(day: String, device: UUID, usage: UInt16, count: Int64)] = [
            ("2026-01-01", visible, 4, 3), ("2026-01-15", visible, 4, 5), ("2026-01-31", visible, 5, 7),
            ("2026-02-01", visible, 4, 11), ("2026-02-28", visible, 4, 13), ("2026-01-15", hidden, 4, 17)
        ]
        try store.apply(rows.map { row in
            let date = try localNoon(row.day)
            return CountIncrement(
                minute: TimeBuckets.minute(for: date),
                hour: TimeBuckets.hour(for: date),
                localDay: row.day,
                deviceID: row.device,
                key: HIDKeyID(usagePage: 7, usage: row.usage),
                count: row.count
            )
        })
        return (visible, hidden)
    }

    func expectEveryCountTable(total: Int64, sourceLocation: SourceLocation = #_sourceLocation) throws {
        for table in [
            "minute_device_counts", "hourly_device_counts", "daily_device_key_counts",
            "daily_device_counts", "monthly_device_key_counts", "device_total_counts"
        ] {
            #expect(
                try int("SELECT COALESCE(SUM(count), 0) FROM \(table)") == total,
                "\(table) total",
                sourceLocation: sourceLocation
            )
        }
    }

    private func localNoon(_ localDay: String) throws -> Date {
        let values = localDay.split(separator: "-").compactMap { Int($0) }
        guard values.count == 3,
              let date = calendar.date(
                from: DateComponents(year: values[0], month: values[1], day: values[2], hour: 12)
              ) else { throw FixtureError.sqlite("date") }
        return date
    }

    func execute(_ sql: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK else {
            defer { sqlite3_close(database) }
            throw FixtureError.sqlite("open")
        }
        defer { sqlite3_close(database) }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw FixtureError.sqlite(message)
        }
    }

    func int(_ sql: String) throws -> Int64 {
        var database: OpaquePointer?
        // Read-write so a WAL database can recreate its -shm once every store is closed.
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            defer { sqlite3_close(database) }
            throw FixtureError.sqlite("open")
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw FixtureError.sqlite("\(String(cString: sqlite3_errmsg(database))): \(sql)")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw FixtureError.sqlite("\(String(cString: sqlite3_errmsg(database))): \(sql)")
        }
        return sqlite3_column_int64(statement, 0)
    }
}

private enum FixtureError: Error {
    case sqlite(String)
}
