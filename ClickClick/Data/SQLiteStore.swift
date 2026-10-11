import Foundation
import SQLite3

enum StoreError: LocalizedError {
    case open(String)
    case execute(String)
    case prepare(String)

    var errorDescription: String? {
        switch self {
        case .open(let message): "无法打开统计数据库：\(message)"
        case .execute(let message): "数据库操作失败：\(message)"
        case .prepare(let message): "数据库查询失败：\(message)"
        }
    }
}

struct CountIncrement: Hashable, Sendable {
    let minute: Int64
    let hour: Int64
    let localDay: String
    let deviceID: UUID
    let key: HIDKeyID
    var count: Int64
}

struct DailyTrendRow: Equatable, Sendable {
    let localDay: String
    let deviceID: UUID
    let deviceName: String
    let count: Int64
}

/// SQLite store. Writer and reader actors own separate WAL connections so a
/// historical query cannot serialize input persistence behind itself.
final class SQLiteStore: @unchecked Sendable {
    static let schemaVersion = 3

    private var database: OpaquePointer?
    private let databaseURL: URL
    private let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        databaseURL = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try open(flags: SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX)
        do {
            // Reject unsupported databases before any pragma touches the file.
            try migrateIfNeeded()
            try run("PRAGMA journal_mode = WAL;")
            try run("PRAGMA foreign_keys = ON;")
            try run("PRAGMA synchronous = NORMAL;")
        } catch {
            if let database { sqlite3_close(database) }
            database = nil
            throw error
        }
    }

    init(readOnlyURL url: URL) throws {
        databaseURL = url
        try open(flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX)
        do {
            try run("PRAGMA foreign_keys = ON;")
            try run("PRAGMA query_only = ON;")
        } catch {
            if let database { sqlite3_close(database) }
            database = nil
            throw error
        }
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    // MARK: Cancellation and consistent reads

    func interrupt() {
        sqlite3_interrupt(database)
    }

    func readTransaction<T>(_ work: () throws -> T) throws -> T {
        try run("BEGIN DEFERRED;")
        do {
            let value = try work()
            try run("COMMIT;")
            return value
        } catch {
            try? run("ROLLBACK;")
            throw error
        }
    }

    // MARK: Device directory

    func resolveDevice(_ descriptor: DeviceDescriptor) throws -> UUID {
        if let existing = try textValue(
            "SELECT device_id FROM device_aliases WHERE fingerprint = ? LIMIT 1",
            bindings: [.text(descriptor.observedFingerprint)]
        ), let id = UUID(uuidString: existing) {
            try prepared(
                "UPDATE devices SET last_seen_at = ?, product = COALESCE(?, product), transport = COALESCE(?, transport) WHERE id = ?",
                bindings: [
                    .int(nowTimestamp()), .optionalText(descriptor.product),
                    .optionalText(descriptor.transport), .text(id.uuidString)
                ]
            )
            return id
        }

        let id = UUID()
        try writeTransaction {
            try prepared(
                """
                INSERT INTO devices
                    (id, display_name, manufacturer, product, vendor_id, product_id, transport, is_built_in, is_hidden, created_at, last_seen_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)
                """,
                bindings: [
                    .text(id.uuidString), .text(descriptor.suggestedName),
                    .optionalText(descriptor.manufacturer), .optionalText(descriptor.product),
                    .int(Int64(descriptor.vendorID)), .int(Int64(descriptor.productID)),
                    .optionalText(descriptor.transport), .int(descriptor.isBuiltIn ? 1 : 0),
                    .int(nowTimestamp()), .int(nowTimestamp())
                ]
            )
            try prepared(
                "INSERT INTO device_aliases (fingerprint, device_id) VALUES (?, ?)",
                bindings: [.text(descriptor.observedFingerprint), .text(id.uuidString)]
            )
        }
        return id
    }

    func renameDevice(id: UUID, name: String) throws {
        try prepared(
            "UPDATE devices SET display_name = ? WHERE id = ?",
            bindings: [.text(name), .text(id.uuidString)]
        )
    }

    func setDeviceHidden(id: UUID, hidden: Bool) throws {
        try prepared(
            "UPDATE devices SET is_hidden = ? WHERE id = ?",
            bindings: [.int(hidden ? 1 : 0), .text(id.uuidString)]
        )
    }

    // MARK: Incremental writes

    /// Batches each aggregate key once and updates all read models in one transaction.
    func apply(_ increments: [CountIncrement]) throws {
        let valid = increments.filter { $0.key.isCountable && $0.count > 0 }
        guard !valid.isEmpty else { return }

        var minuteCounts: [BucketDevice: Int64] = [:]
        var hourCounts: [BucketDevice: Int64] = [:]
        var dayCounts: [DayDevice: Int64] = [:]
        var dailyKeys: [DayDeviceKey: Int64] = [:]
        var monthlyKeys: [MonthDeviceKey: Int64] = [:]
        var totals: [UUID: Int64] = [:]
        for increment in valid {
            minuteCounts[.init(bucket: increment.minute, deviceID: increment.deviceID), default: 0] += increment.count
            hourCounts[.init(bucket: increment.hour, deviceID: increment.deviceID), default: 0] += increment.count
            dayCounts[.init(day: increment.localDay, deviceID: increment.deviceID), default: 0] += increment.count
            dailyKeys[
                .init(day: increment.localDay, deviceID: increment.deviceID, key: increment.key),
                default: 0
            ] += increment.count
            monthlyKeys[
                .init(month: String(increment.localDay.prefix(7)), deviceID: increment.deviceID, key: increment.key),
                default: 0
            ] += increment.count
            totals[increment.deviceID, default: 0] += increment.count
        }

        try writeTransaction {
            try batch(
                """
                INSERT INTO minute_device_counts (bucket_start, device_id, count) VALUES (?, ?, ?)
                ON CONFLICT(bucket_start, device_id) DO UPDATE SET count = count + excluded.count
                """,
                rows: minuteCounts.map { [.int($0.key.bucket), .text($0.key.deviceID.uuidString), .int($0.value)] }
            )
            try batch(
                """
                INSERT INTO hourly_device_counts (bucket_start, device_id, count) VALUES (?, ?, ?)
                ON CONFLICT(bucket_start, device_id) DO UPDATE SET count = count + excluded.count
                """,
                rows: hourCounts.map { [.int($0.key.bucket), .text($0.key.deviceID.uuidString), .int($0.value)] }
            )
            try batch(
                """
                INSERT INTO daily_device_counts (local_day, device_id, count) VALUES (?, ?, ?)
                ON CONFLICT(local_day, device_id) DO UPDATE SET count = count + excluded.count
                """,
                rows: dayCounts.map { [.text($0.key.day), .text($0.key.deviceID.uuidString), .int($0.value)] }
            )
            try batch(
                """
                INSERT INTO daily_device_key_counts (local_day, device_id, usage_page, usage, count)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(local_day, device_id, usage_page, usage) DO UPDATE SET count = count + excluded.count
                """,
                rows: dailyKeys.map {
                    [
                        .text($0.key.day), .text($0.key.deviceID.uuidString),
                        .int(Int64($0.key.key.usagePage)), .int(Int64($0.key.key.usage)), .int($0.value)
                    ]
                }
            )
            try batch(
                """
                INSERT INTO monthly_device_key_counts (local_month, device_id, usage_page, usage, count)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(local_month, device_id, usage_page, usage) DO UPDATE SET count = count + excluded.count
                """,
                rows: monthlyKeys.map {
                    [
                        .text($0.key.month), .text($0.key.deviceID.uuidString),
                        .int(Int64($0.key.key.usagePage)), .int(Int64($0.key.key.usage)), .int($0.value)
                    ]
                }
            )
            try batch(
                """
                INSERT INTO device_total_counts (device_id, count) VALUES (?, ?)
                ON CONFLICT(device_id) DO UPDATE SET count = count + excluded.count
                """,
                rows: totals.map { [.text($0.key.uuidString), .int($0.value)] }
            )
        }
    }

    func pruneMinuteData(before timestamp: Int64) throws {
        try prepared(
            "DELETE FROM minute_device_counts WHERE bucket_start < ?",
            bindings: [.int(timestamp)]
        )
    }

    // MARK: Read model

    func dashboard(
        connected: Set<UUID>,
        localDay: String = TimeBuckets.localDay(for: Date())
    ) throws -> DashboardSnapshot {
        let devices = try fetchDevices(connected: connected)
        let rows = try rows(
            """
            SELECT d.id, d.display_name, COALESCE(c.count, 0)
            FROM devices d
            LEFT JOIN daily_device_counts c ON c.device_id = d.id AND c.local_day = ?
            WHERE d.is_hidden = 0
            ORDER BY COALESCE(c.count, 0) DESC, d.display_name
            """,
            bindings: [.text(localDay)]
        )
        let counts = rows.compactMap { row -> DeviceCount? in
            guard let id = UUID(uuidString: row.text(0)) else { return nil }
            return DeviceCount(deviceID: id, deviceName: row.text(1), count: row.int(2))
        }
        return DashboardSnapshot(
            todayTotal: counts.reduce(0) { $0 + $1.count },
            devices: devices,
            todayByDevice: counts
        )
    }

    func fetchDevices(connected: Set<UUID>) throws -> [KeyboardDevice] {
        try rows(
            """
            SELECT d.id, d.display_name, d.manufacturer, d.product, d.transport,
                   d.is_built_in, d.is_hidden, COALESCE(t.count, 0)
            FROM devices d
            LEFT JOIN device_total_counts t ON t.device_id = d.id
            ORDER BY d.is_built_in DESC, d.display_name
            """
        ).compactMap { row in
            guard let id = UUID(uuidString: row.text(0)) else { return nil }
            return KeyboardDevice(
                id: id,
                name: row.text(1),
                manufacturer: row.optionalText(2),
                product: row.optionalText(3),
                transport: row.optionalText(4),
                isBuiltIn: row.int(5) != 0,
                isConnected: connected.contains(id),
                isHidden: row.int(6) != 0,
                totalCount: row.int(7)
            )
        }
    }

    func trendRows(
        from: Date,
        to: Date,
        minute: Bool,
        deviceID: UUID?
    ) throws -> [(Int64, UUID, String, Int64)] {
        let table = minute ? "minute_device_counts" : "hourly_device_counts"
        var sql = """
            SELECT c.bucket_start, d.id, d.display_name, c.count
            FROM \(table) c JOIN devices d ON d.id = c.device_id
            WHERE c.bucket_start >= ? AND c.bucket_start < ? AND d.is_hidden = 0
            """
        var bindings: [SQLBinding] = [
            .int(Int64(from.timeIntervalSince1970)),
            .int(Int64(to.timeIntervalSince1970))
        ]
        if let deviceID {
            sql += " AND d.id = ?"
            bindings.append(.text(deviceID.uuidString))
        }
        sql += " ORDER BY c.bucket_start, d.display_name"
        return try rows(sql, bindings: bindings).compactMap { row in
            guard let id = UUID(uuidString: row.text(1)) else { return nil }
            return (row.int(0), id, row.text(2), row.int(3))
        }
    }

    func dailyTrendRows(fromDay: String, toDay: String, deviceID: UUID?) throws -> [DailyTrendRow] {
        var sql = """
            SELECT c.local_day, d.id, d.display_name, c.count
            FROM daily_device_counts c JOIN devices d ON d.id = c.device_id
            WHERE c.local_day >= ? AND c.local_day <= ? AND d.is_hidden = 0
            """
        var bindings: [SQLBinding] = [.text(fromDay), .text(toDay)]
        if let deviceID {
            sql += " AND d.id = ?"
            bindings.append(.text(deviceID.uuidString))
        }
        sql += " ORDER BY c.local_day, d.display_name"
        return try rows(sql, bindings: bindings).compactMap { row in
            guard let id = UUID(uuidString: row.text(1)) else { return nil }
            return DailyTrendRow(
                localDay: row.text(0),
                deviceID: id,
                deviceName: row.text(2),
                count: row.int(3)
            )
        }
    }

    /// Complete months are read from the monthly key rollup. Only an
    /// incomplete first/last month reads the daily key table.
    func keyCounts(fromDay: String, toDay: String, deviceID: UUID?) throws -> [KeyCount] {
        guard fromDay <= toDay else { return [] }
        let completeMonths = Self.completeMonths(fromDay: fromDay, toDay: toDay)
        var totals: [HIDKeyID: Int64] = [:]

        if let first = completeMonths.first, let last = completeMonths.last {
            var sql = """
                SELECT c.usage_page, c.usage, SUM(c.count)
                FROM monthly_device_key_counts c
                JOIN devices d ON d.id = c.device_id
                WHERE c.local_month >= ? AND c.local_month <= ? AND d.is_hidden = 0
                """
            var bindings: [SQLBinding] = [.text(first), .text(last)]
            if let deviceID {
                sql += " AND d.id = ?"
                bindings.append(.text(deviceID.uuidString))
            }
            sql += " GROUP BY c.usage_page, c.usage"
            for row in try rows(sql, bindings: bindings) {
                let key = HIDKeyID(usagePage: UInt16(row.int(0)), usage: UInt16(row.int(1)))
                totals[key, default: 0] += row.int(2)
            }
        }

        for partialRange in Self.partialDayRanges(
            fromDay: fromDay,
            toDay: toDay,
            completeMonths: completeMonths
        ) {
            var sql = """
                SELECT c.usage_page, c.usage, SUM(c.count)
                FROM daily_device_key_counts c
                JOIN devices d ON d.id = c.device_id
                WHERE c.local_day >= ? AND c.local_day <= ? AND d.is_hidden = 0
                """
            var bindings: [SQLBinding] = [.text(partialRange.from), .text(partialRange.to)]
            if let deviceID {
                sql += " AND d.id = ?"
                bindings.append(.text(deviceID.uuidString))
            }
            sql += " GROUP BY c.usage_page, c.usage"
            for row in try rows(sql, bindings: bindings) {
                let key = HIDKeyID(usagePage: UInt16(row.int(0)), usage: UInt16(row.int(1)))
                totals[key, default: 0] += row.int(2)
            }
        }

        return totals.map { KeyCount(key: $0.key, count: $0.value) }.sorted {
            $0.count == $1.count ? $0.key.id < $1.key.id : $0.count > $1.count
        }
    }

    // MARK: Device/count mutations

    func mergeDevice(source: UUID, target: UUID) throws {
        guard source != target else { return }
        try writeTransaction {
            for table in ["minute_device_counts", "hourly_device_counts"] {
                try prepared(
                    """
                    INSERT INTO \(table) (bucket_start, device_id, count)
                    SELECT bucket_start, ?, count FROM \(table) WHERE device_id = ?
                    ON CONFLICT(bucket_start, device_id) DO UPDATE SET count = count + excluded.count
                    """,
                    bindings: [.text(target.uuidString), .text(source.uuidString)]
                )
            }
            try prepared(
                """
                INSERT INTO daily_device_counts (local_day, device_id, count)
                SELECT local_day, ?, count FROM daily_device_counts WHERE device_id = ?
                ON CONFLICT(local_day, device_id) DO UPDATE SET count = count + excluded.count
                """,
                bindings: [.text(target.uuidString), .text(source.uuidString)]
            )
            try prepared(
                """
                INSERT INTO daily_device_key_counts (local_day, device_id, usage_page, usage, count)
                SELECT local_day, ?, usage_page, usage, count FROM daily_device_key_counts WHERE device_id = ?
                ON CONFLICT(local_day, device_id, usage_page, usage) DO UPDATE SET count = count + excluded.count
                """,
                bindings: [.text(target.uuidString), .text(source.uuidString)]
            )
            try prepared(
                """
                INSERT INTO monthly_device_key_counts (local_month, device_id, usage_page, usage, count)
                SELECT local_month, ?, usage_page, usage, count FROM monthly_device_key_counts WHERE device_id = ?
                ON CONFLICT(local_month, device_id, usage_page, usage) DO UPDATE SET count = count + excluded.count
                """,
                bindings: [.text(target.uuidString), .text(source.uuidString)]
            )
            try prepared(
                """
                INSERT INTO device_total_counts (device_id, count)
                SELECT ?, count FROM device_total_counts WHERE device_id = ?
                ON CONFLICT(device_id) DO UPDATE SET count = count + excluded.count
                """,
                bindings: [.text(target.uuidString), .text(source.uuidString)]
            )
            try prepared(
                "UPDATE device_aliases SET device_id = ? WHERE device_id = ?",
                bindings: [.text(target.uuidString), .text(source.uuidString)]
            )
            try deleteDeviceRows(id: source)
            try prepared("DELETE FROM devices WHERE id = ?", bindings: [.text(source.uuidString)])
        }
    }

    func deleteDevice(id: UUID) throws {
        try writeTransaction {
            try deleteDeviceRows(id: id)
            try prepared("DELETE FROM devices WHERE id = ?", bindings: [.text(id.uuidString)])
        }
    }

    func clearAllCounts() throws {
        try writeTransaction {
            for table in Self.countTables { try run("DELETE FROM \(table);") }
        }
    }

    func clearCounts(deviceID: UUID) throws {
        try writeTransaction {
            for table in Self.countTables {
                try prepared(
                    "DELETE FROM \(table) WHERE device_id = ?",
                    bindings: [.text(deviceID.uuidString)]
                )
            }
        }
    }

    private func deleteDeviceRows(id: UUID) throws {
        for table in Self.countTables {
            try prepared("DELETE FROM \(table) WHERE device_id = ?", bindings: [.text(id.uuidString)])
        }
        try prepared("DELETE FROM device_aliases WHERE device_id = ?", bindings: [.text(id.uuidString)])
    }

    // MARK: Schema migration

    private func migrateIfNeeded() throws {
        let version = Int(try intValue("PRAGMA user_version") ?? 0)

        guard try tableExists("devices") else {
            try writeTransaction {
                try createSchema()
                try run("PRAGMA user_version = \(Self.schemaVersion);")
            }
            return
        }

        guard version >= 2 else {
            throw StoreError.open("不支持旧版本数据库（user_version \(version)）")
        }
        guard version == 2 else { return }

        try writeTransaction {
            for trigger in ["insert", "update", "delete"] {
                try run("DROP TRIGGER IF EXISTS mark_statistics_dirty_after_daily_\(trigger);")
            }
            try run("DROP TABLE IF EXISTS statistics_state;")
            try run("PRAGMA user_version = \(Self.schemaVersion);")
        }
        let backupURL = databaseURL.deletingLastPathComponent().appending(path: "clickclick-v1-backup.sqlite")
        try? FileManager.default.removeItem(at: backupURL)
    }

    private func createSchema() throws {
        try run("""
        CREATE TABLE IF NOT EXISTS devices (
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
        CREATE TABLE IF NOT EXISTS device_aliases (
            fingerprint TEXT PRIMARY KEY,
            device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE
        );
        CREATE TABLE IF NOT EXISTS minute_device_counts (
            bucket_start INTEGER NOT NULL,
            device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
            count INTEGER NOT NULL CHECK(count >= 0),
            PRIMARY KEY (bucket_start, device_id)
        );
        CREATE TABLE IF NOT EXISTS hourly_device_counts (
            bucket_start INTEGER NOT NULL,
            device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
            count INTEGER NOT NULL CHECK(count >= 0),
            PRIMARY KEY (bucket_start, device_id)
        );
        CREATE TABLE IF NOT EXISTS daily_device_key_counts (
            local_day TEXT NOT NULL,
            device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
            usage_page INTEGER NOT NULL,
            usage INTEGER NOT NULL,
            count INTEGER NOT NULL CHECK(count >= 0),
            PRIMARY KEY (local_day, device_id, usage_page, usage)
        );
        CREATE TABLE IF NOT EXISTS daily_device_counts (
            local_day TEXT NOT NULL,
            device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
            count INTEGER NOT NULL CHECK(count >= 0),
            PRIMARY KEY (local_day, device_id)
        );
        CREATE TABLE IF NOT EXISTS monthly_device_key_counts (
            local_month TEXT NOT NULL,
            device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
            usage_page INTEGER NOT NULL,
            usage INTEGER NOT NULL,
            count INTEGER NOT NULL CHECK(count >= 0),
            PRIMARY KEY (local_month, device_id, usage_page, usage)
        );
        CREATE TABLE IF NOT EXISTS device_total_counts (
            device_id TEXT PRIMARY KEY REFERENCES devices(id) ON DELETE CASCADE,
            count INTEGER NOT NULL CHECK(count >= 0)
        );
        CREATE INDEX IF NOT EXISTS idx_minute_device ON minute_device_counts(device_id, bucket_start);
        CREATE INDEX IF NOT EXISTS idx_hourly_device ON hourly_device_counts(device_id, bucket_start);
        CREATE INDEX IF NOT EXISTS idx_daily_key_device ON daily_device_key_counts(device_id, local_day);
        CREATE INDEX IF NOT EXISTS idx_daily_counts_device ON daily_device_counts(device_id, local_day);
        CREATE INDEX IF NOT EXISTS idx_monthly_key_device ON monthly_device_key_counts(device_id, local_month);
        """)
    }

    // MARK: Date helpers

    private static func completeMonths(fromDay: String, toDay: String) -> [String] {
        let calendar = Calendar.autoupdatingCurrent
        guard let start = TimeBuckets.date(fromLocalDay: fromDay, calendar: calendar),
              let end = TimeBuckets.date(fromLocalDay: toDay, calendar: calendar) else { return [] }
        var cursor = calendar.date(
            from: calendar.dateComponents([.year, .month], from: start)
        )!
        let finalMonth = calendar.date(
            from: calendar.dateComponents([.year, .month], from: end)
        )!
        var result: [String] = []
        while cursor <= finalMonth {
            guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: cursor),
                  let lastDay = calendar.date(byAdding: .day, value: -1, to: nextMonth) else { break }
            if cursor >= start && lastDay <= end {
                let components = calendar.dateComponents([.year, .month], from: cursor)
                result.append(String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0))
            }
            cursor = nextMonth
        }
        return result
    }

    private static func partialDayRanges(
        fromDay: String,
        toDay: String,
        completeMonths: [String]
    ) -> [(from: String, to: String)] {
        let calendar = Calendar.autoupdatingCurrent
        guard let firstMonth = completeMonths.first,
              let lastMonth = completeMonths.last,
              let firstCompleteDay = TimeBuckets.date(fromLocalDay: "\(firstMonth)-01", calendar: calendar),
              let lastCompleteDay = TimeBuckets.date(fromLocalDay: "\(lastMonth)-01", calendar: calendar),
              let headEndDate = calendar.date(byAdding: .day, value: -1, to: firstCompleteDay),
              let tailStartDate = calendar.date(byAdding: .month, value: 1, to: lastCompleteDay) else {
            return [(fromDay, toDay)]
        }

        let headEnd = TimeBuckets.localDay(for: headEndDate, calendar: calendar)
        let tailStart = TimeBuckets.localDay(for: tailStartDate, calendar: calendar)
        var ranges: [(from: String, to: String)] = []
        if fromDay <= headEnd { ranges.append((fromDay, min(toDay, headEnd))) }
        if tailStart <= toDay { ranges.append((max(fromDay, tailStart), toDay)) }
        return ranges
    }

    // MARK: SQLite primitives

    private func open(flags: Int32) throws {
        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK else {
            let message = Self.message(from: database)
            if let database { sqlite3_close(database) }
            database = nil
            throw StoreError.open(message)
        }
        sqlite3_busy_timeout(database, 5_000)
    }

    private func tableExists(_ name: String) throws -> Bool {
        try intValue(
            "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?)",
            bindings: [.text(name)]
        ) == 1
    }

    private func writeTransaction<T>(_ work: () throws -> T) throws -> T {
        try run("BEGIN IMMEDIATE;")
        do {
            let value = try work()
            try run("COMMIT;")
            return value
        } catch {
            try? run("ROLLBACK;")
            throw error
        }
    }

    private func run(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &error)
        guard result == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? Self.message(from: database)
            sqlite3_free(error)
            if result == SQLITE_INTERRUPT { throw CancellationError() }
            throw StoreError.execute(message)
        }
    }

    @discardableResult
    private func prepared(_ sql: String, bindings: [SQLBinding]) throws -> Int32 {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            if result == SQLITE_INTERRUPT { throw CancellationError() }
            throw StoreError.execute(Self.message(from: database))
        }
        return sqlite3_changes(database)
    }

    private func batch(_ sql: String, rows: [[SQLBinding]]) throws {
        guard !rows.isEmpty else { return }
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for bindings in rows {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            try bind(bindings, to: statement)
            let result = sqlite3_step(statement)
            guard result == SQLITE_DONE else {
                if result == SQLITE_INTERRUPT { throw CancellationError() }
                throw StoreError.execute(Self.message(from: database))
            }
        }
    }

    private func intValue(_ sql: String, bindings: [SQLBinding] = []) throws -> Int64? {
        try rows(sql, bindings: bindings).first?.optionalInt(0)
    }

    private func textValue(_ sql: String, bindings: [SQLBinding]) throws -> String? {
        try rows(sql, bindings: bindings).first?.optionalText(0)
    }

    private func rows(_ sql: String, bindings: [SQLBinding] = []) throws -> [SQLRow] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        var resultRows: [SQLRow] = []
        while true {
            let result = sqlite3_step(statement)
            switch result {
            case SQLITE_ROW:
                let columns = (0..<sqlite3_column_count(statement)).map { index -> SQLColumn in
                    switch sqlite3_column_type(statement, index) {
                    case SQLITE_NULL:
                        return .null
                    case SQLITE_INTEGER:
                        return .int(sqlite3_column_int64(statement, index))
                    default:
                        guard let value = sqlite3_column_text(statement, index) else { return .null }
                        return .text(String(cString: value))
                    }
                }
                resultRows.append(SQLRow(columns: columns))
            case SQLITE_DONE:
                return resultRows
            case SQLITE_INTERRUPT:
                throw CancellationError()
            default:
                throw StoreError.execute(Self.message(from: database))
            }
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK else {
            if result == SQLITE_INTERRUPT { throw CancellationError() }
            throw StoreError.prepare(Self.message(from: database))
        }
        return statement
    }

    private func bind(_ bindings: [SQLBinding], to statement: OpaquePointer?) throws {
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch binding {
            case .int(let value): result = sqlite3_bind_int64(statement, index, value)
            case .text(let value): result = sqlite3_bind_text(statement, index, value, -1, transientDestructor)
            case .null: result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else {
                if result == SQLITE_INTERRUPT { throw CancellationError() }
                throw StoreError.execute(Self.message(from: database))
            }
        }
    }

    private func nowTimestamp() -> Int64 { Int64(Date().timeIntervalSince1970) }

    private static func message(from database: OpaquePointer?) -> String {
        database.flatMap(sqlite3_errmsg).map(String.init(cString:)) ?? "unknown error"
    }

    private static let countTables = [
        "minute_device_counts",
        "hourly_device_counts",
        "daily_device_key_counts",
        "daily_device_counts",
        "monthly_device_key_counts",
        "device_total_counts"
    ]
}

private struct BucketDevice: Hashable {
    let bucket: Int64
    let deviceID: UUID
}

private struct DayDevice: Hashable {
    let day: String
    let deviceID: UUID
}

private struct DayDeviceKey: Hashable {
    let day: String
    let deviceID: UUID
    let key: HIDKeyID
}

private struct MonthDeviceKey: Hashable {
    let month: String
    let deviceID: UUID
    let key: HIDKeyID
}

private enum SQLBinding {
    case int(Int64)
    case text(String)
    case null

    static func optionalText(_ value: String?) -> SQLBinding {
        value.map(SQLBinding.text) ?? .null
    }
}

private enum SQLColumn {
    case int(Int64)
    case text(String)
    case null
}

private struct SQLRow {
    let columns: [SQLColumn]

    func int(_ index: Int) -> Int64 { optionalInt(index) ?? 0 }

    func optionalInt(_ index: Int) -> Int64? {
        if case .int(let value) = columns[index] { return value }
        return nil
    }

    func text(_ index: Int) -> String { optionalText(index) ?? "" }

    func optionalText(_ index: Int) -> String? {
        if case .text(let value) = columns[index] { return value }
        return nil
    }
}
