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

/// SQLite v2 store. Writer and reader actors own separate WAL connections so a
/// historical query cannot serialize input persistence behind itself.
final class SQLiteStore: @unchecked Sendable {
    static let schemaVersion = 2
    static let backupName = "clickclick-v1-backup.sqlite"

    private var database: OpaquePointer?
    private let databaseURL: URL
    private let isReadOnly: Bool
    private let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let progressLock = NSLock()
    private var progressCancellation: (() -> Bool)?

    init(url: URL) throws {
        databaseURL = url
        isReadOnly = false
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try open(flags: SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX)
        do {
            try run("PRAGMA journal_mode = WAL;")
            try run("PRAGMA foreign_keys = ON;")
            try run("PRAGMA synchronous = NORMAL;")
            try migrateIfNeeded()
            try rebuildDerivedTablesIfCanonicalDataDrifted()
        } catch {
            if let database { sqlite3_close(database) }
            database = nil
            throw error
        }
    }

    init(readOnlyURL url: URL) throws {
        databaseURL = url
        isReadOnly = true
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
        if let database {
            sqlite3_progress_handler(database, 0, nil, nil)
            sqlite3_close(database)
        }
    }

    // MARK: Cancellation and consistent reads

    func installProgressHandler(every operations: Int32, shouldCancel: @escaping () -> Bool) {
        progressLock.withLock { progressCancellation = shouldCancel }
        sqlite3_progress_handler(
            database,
            max(1, operations),
            sqliteStoreV2ProgressCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    func clearProgressHandler() {
        sqlite3_progress_handler(database, 0, nil, nil)
        progressLock.withLock { progressCancellation = nil }
    }

    func interrupt() {
        sqlite3_interrupt(database)
    }

    fileprivate func shouldCancelProgress() -> Bool {
        progressLock.withLock { progressCancellation?() ?? false }
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
            _ = try bumpRevision()
        }
        return id
    }

    @discardableResult
    func renameDevice(id: UUID, name: String) throws -> Int64 {
        try writeTransaction {
            let changed = try prepared(
                "UPDATE devices SET display_name = ? WHERE id = ? AND display_name <> ?",
                bindings: [.text(name), .text(id.uuidString), .text(name)]
            )
            return changed > 0 ? try bumpRevision() : try revision()
        }
    }

    @discardableResult
    func setDeviceHidden(id: UUID, hidden: Bool) throws -> Int64 {
        try writeTransaction {
            let value: Int64 = hidden ? 1 : 0
            let changed = try prepared(
                "UPDATE devices SET is_hidden = ? WHERE id = ? AND is_hidden <> ?",
                bindings: [.int(value), .text(id.uuidString), .int(value)]
            )
            return changed > 0 ? try bumpRevision() : try revision()
        }
    }

    // MARK: Incremental writes

    /// Batches each aggregate key once and updates all read models plus the
    /// revision in one transaction.
    @discardableResult
    func apply(_ increments: [CountIncrement]) throws -> Int64 {
        let valid = increments.filter { $0.key.isCountable && $0.count > 0 }
        guard !valid.isEmpty else { return try revision() }

        var minuteCounts: [V2BucketDevice: Int64] = [:]
        var hourCounts: [V2BucketDevice: Int64] = [:]
        var dayCounts: [V2DayDevice: Int64] = [:]
        var dailyKeys: [V2DayDeviceKey: Int64] = [:]
        var monthlyKeys: [V2MonthDeviceKey: Int64] = [:]
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

        let totalDelta = valid.reduce(Int64(0)) { $0 + $1.count }
        return try writeTransaction {
            let canonicalTotalBeforeApply = try prepareCanonicalStateForWrite()
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
            try setCanonicalSignature(total: canonicalTotalBeforeApply + totalDelta)
            return try bumpRevision()
        }
    }

    @discardableResult
    func pruneMinuteData(before timestamp: Int64) throws -> Int64 {
        try writeTransaction {
            let changed = try prepared(
                "DELETE FROM minute_device_counts WHERE bucket_start < ?",
                bindings: [.int(timestamp)]
            )
            return changed > 0 ? try bumpRevision() : try revision()
        }
    }

    // MARK: Read model

    func revision() throws -> Int64 {
        try intValue("SELECT revision FROM statistics_state WHERE singleton = 1") ?? 0
    }

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
        var bindings: [V2Binding] = [
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
        var bindings: [V2Binding] = [.text(fromDay), .text(toDay)]
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
    /// incomplete first/last month touches the canonical daily-key table.
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
            var bindings: [V2Binding] = [.text(first), .text(last)]
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
            var bindings: [V2Binding] = [.text(partialRange.from), .text(partialRange.to)]
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

    @discardableResult
    func mergeDevice(source: UUID, target: UUID) throws -> Int64 {
        guard source != target else { return try revision() }
        return try writeTransaction {
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
            // Canonical-table triggers mark the signature dirty during the
            // merge. All six aggregates are already synchronized here, so only
            // recompute the signature instead of rebuilding them.
            try refreshCanonicalSignature()
            return try bumpRevision()
        }
    }

    @discardableResult
    func deleteDevice(id: UUID) throws -> Int64 {
        try writeTransaction {
            let exists = try intValue(
                "SELECT EXISTS(SELECT 1 FROM devices WHERE id = ?)",
                bindings: [.text(id.uuidString)]
            ) == 1
            guard exists else { return try revision() }
            try deleteDeviceRows(id: id)
            try prepared("DELETE FROM devices WHERE id = ?", bindings: [.text(id.uuidString)])
            try refreshCanonicalSignature()
            return try bumpRevision()
        }
    }

    @discardableResult
    func clearAllCounts() throws -> Int64 {
        try writeTransaction {
            let hasCounts = try hasAnyCounts(deviceID: nil)
            guard hasCounts else { return try revision() }
            for table in Self.countTables { try run("DELETE FROM \(table);") }
            try setCanonicalSignature(total: 0)
            return try bumpRevision()
        }
    }

    @discardableResult
    func clearCounts(deviceID: UUID) throws -> Int64 {
        try writeTransaction {
            let hasCounts = try hasAnyCounts(deviceID: deviceID)
            guard hasCounts else { return try revision() }
            for table in Self.countTables {
                try prepared(
                    "DELETE FROM \(table) WHERE device_id = ?",
                    bindings: [.text(deviceID.uuidString)]
                )
            }
            try refreshCanonicalSignature()
            return try bumpRevision()
        }
    }

    private func hasAnyCounts(deviceID: UUID?) throws -> Bool {
        let predicate = deviceID == nil ? "" : " WHERE device_id = ?"
        let union = Self.countTables
            .map { "SELECT 1 FROM \($0)\(predicate)" }
            .joined(separator: " UNION ALL ")
        let bindings = deviceID.map { id in
            Array(repeating: V2Binding.text(id.uuidString), count: Self.countTables.count)
        } ?? []
        return try intValue(
            "SELECT EXISTS(SELECT 1 FROM (\(union)) LIMIT 1)",
            bindings: bindings
        ) == 1
    }

    private func deleteDeviceRows(id: UUID) throws {
        for table in Self.countTables {
            try prepared("DELETE FROM \(table) WHERE device_id = ?", bindings: [.text(id.uuidString)])
        }
        try prepared("DELETE FROM device_aliases WHERE device_id = ?", bindings: [.text(id.uuidString)])
    }

    // MARK: Schema v2 migration

    private func migrateIfNeeded() throws {
        let hasLegacySchema = try tableExists("devices")
        let version = Int(try intValue("PRAGMA user_version") ?? 0)

        if !hasLegacySchema {
            try writeTransaction {
                try createSchemaV2()
                try ensureStatisticsState()
                try run("PRAGMA user_version = \(Self.schemaVersion);")
            }
            return
        }

        guard version < Self.schemaVersion else {
            try createSchemaV2()
            try ensureStatisticsState()
            return
        }

        // The online backup reads the source connection, including its WAL,
        // before the first migration mutation occurs.
        try createV1BackupIfNeeded()
        do {
            try writeTransaction {
                try repairInvalidKeyCountsInCurrentTransaction()
                try createSchemaV2()
                try ensureStatisticsState()
                try rebuildDerivedTablesInCurrentTransaction()
                try validateDerivedTables()
                try refreshCanonicalSignature()
                try run("PRAGMA user_version = \(Self.schemaVersion);")
            }
        } catch {
            throw StoreError.execute("迁移已回滚：\(error.localizedDescription)")
        }
    }

    private func createSchemaV2() throws {
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
        CREATE TABLE IF NOT EXISTS statistics_state (
            singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
            revision INTEGER NOT NULL,
            canonical_signature TEXT NOT NULL
        );
        CREATE TRIGGER IF NOT EXISTS mark_statistics_dirty_after_daily_insert
        AFTER INSERT ON daily_device_key_counts BEGIN
            UPDATE statistics_state SET canonical_signature = 'dirty' WHERE singleton = 1;
        END;
        CREATE TRIGGER IF NOT EXISTS mark_statistics_dirty_after_daily_update
        AFTER UPDATE ON daily_device_key_counts BEGIN
            UPDATE statistics_state SET canonical_signature = 'dirty' WHERE singleton = 1;
        END;
        CREATE TRIGGER IF NOT EXISTS mark_statistics_dirty_after_daily_delete
        AFTER DELETE ON daily_device_key_counts BEGIN
            UPDATE statistics_state SET canonical_signature = 'dirty' WHERE singleton = 1;
        END;
        CREATE INDEX IF NOT EXISTS idx_minute_device ON minute_device_counts(device_id, bucket_start);
        CREATE INDEX IF NOT EXISTS idx_hourly_device ON hourly_device_counts(device_id, bucket_start);
        CREATE INDEX IF NOT EXISTS idx_daily_key_device ON daily_device_key_counts(device_id, local_day);
        CREATE INDEX IF NOT EXISTS idx_daily_counts_device ON daily_device_counts(device_id, local_day);
        CREATE INDEX IF NOT EXISTS idx_monthly_key_device ON monthly_device_key_counts(device_id, local_month);
        """)
    }

    private func ensureStatisticsState() throws {
        try run(
            "INSERT OR IGNORE INTO statistics_state (singleton, revision, canonical_signature) VALUES (1, 0, 'v1:0');"
        )
    }

    private func rebuildDerivedTablesIfCanonicalDataDrifted() throws {
        guard !isReadOnly else { return }
        let expected = try canonicalSignatureFromSource()
        let stored = try textValue(
            "SELECT canonical_signature FROM statistics_state WHERE singleton = 1",
            bindings: []
        ) ?? ""
        guard stored != expected else { return }
        try writeTransaction {
            try rebuildDerivedTablesInCurrentTransaction()
            try validateDerivedTables()
            try prepared(
                "UPDATE statistics_state SET canonical_signature = ?, revision = revision + 1 WHERE singleton = 1",
                bindings: [.text(expected)]
            )
        }
    }

    private func rebuildDerivedTablesInCurrentTransaction() throws {
        try run("DELETE FROM daily_device_counts;")
        try run("DELETE FROM monthly_device_key_counts;")
        try run("DELETE FROM device_total_counts;")
        try run("""
            INSERT INTO daily_device_counts (local_day, device_id, count)
            SELECT local_day, device_id, SUM(count)
            FROM daily_device_key_counts
            GROUP BY local_day, device_id;
            INSERT INTO monthly_device_key_counts (local_month, device_id, usage_page, usage, count)
            SELECT substr(local_day, 1, 7), device_id, usage_page, usage, SUM(count)
            FROM daily_device_key_counts
            GROUP BY substr(local_day, 1, 7), device_id, usage_page, usage;
            INSERT INTO device_total_counts (device_id, count)
            SELECT device_id, SUM(count)
            FROM daily_device_key_counts
            GROUP BY device_id;
            """)
    }

    private func validateDerivedTables() throws {
        let canonical = try intValue("SELECT COALESCE(SUM(count), 0) FROM daily_device_key_counts") ?? 0
        let daily = try intValue("SELECT COALESCE(SUM(count), 0) FROM daily_device_counts") ?? 0
        let monthly = try intValue("SELECT COALESCE(SUM(count), 0) FROM monthly_device_key_counts") ?? 0
        let totals = try intValue("SELECT COALESCE(SUM(count), 0) FROM device_total_counts") ?? 0
        guard canonical == daily, canonical == monthly, canonical == totals else {
            throw StoreError.execute("全局派生聚合校验不一致")
        }

        let mismatchCount = try intValue(
            """
            SELECT COUNT(*) FROM (
                SELECT d.id,
                       COALESCE(k.total, 0) canonical_total,
                       COALESCE(dd.total, 0) daily_total,
                       COALESCE(mm.total, 0) monthly_total,
                       COALESCE(dt.count, 0) stored_total
                FROM devices d
                LEFT JOIN (
                    SELECT device_id, SUM(count) total FROM daily_device_key_counts GROUP BY device_id
                ) k ON k.device_id = d.id
                LEFT JOIN (
                    SELECT device_id, SUM(count) total FROM daily_device_counts GROUP BY device_id
                ) dd ON dd.device_id = d.id
                LEFT JOIN (
                    SELECT device_id, SUM(count) total FROM monthly_device_key_counts GROUP BY device_id
                ) mm ON mm.device_id = d.id
                LEFT JOIN device_total_counts dt ON dt.device_id = d.id
            ) WHERE canonical_total <> daily_total
                   OR canonical_total <> monthly_total
                   OR canonical_total <> stored_total
            """
        ) ?? 0
        guard mismatchCount == 0 else {
            throw StoreError.execute("逐设备派生聚合校验不一致")
        }
    }

    private func createV1BackupIfNeeded() throws {
        let backupURL = databaseURL.deletingLastPathComponent().appending(path: Self.backupName)
        if FileManager.default.fileExists(atPath: backupURL.path) {
            guard try isValidV1Backup(at: backupURL) else {
                throw StoreError.execute("现有 v1 备份不完整，已停止升级并保留该文件")
            }
            return
        }

        let temporaryURL = backupURL.deletingLastPathComponent().appending(
            path: ".\(Self.backupName).\(UUID().uuidString).partial"
        )
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        var destination: OpaquePointer?
        guard sqlite3_open_v2(
            temporaryURL.path,
            &destination,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK else {
            let message = Self.message(from: destination)
            if let destination { sqlite3_close(destination) }
            throw StoreError.execute("无法创建 v1 备份：\(message)")
        }
        defer {
            if let destination { sqlite3_close(destination) }
        }

        guard let backup = sqlite3_backup_init(destination, "main", database, "main") else {
            throw StoreError.execute("无法初始化 v1 备份：\(Self.message(from: destination))")
        }
        let stepResult = sqlite3_backup_step(backup, -1)
        let finishResult = sqlite3_backup_finish(backup)
        guard stepResult == SQLITE_DONE, finishResult == SQLITE_OK else {
            throw StoreError.execute("v1 备份写入失败：\(Self.message(from: destination))")
        }

        // The writer enables WAL before migration. A standalone recovery file
        // must not depend on a sibling `-wal` file that will not be retained
        // with the backup, so normalize the destination back to DELETE mode.
        var journalError: UnsafeMutablePointer<CChar>?
        let journalResult = sqlite3_exec(
            destination,
            "PRAGMA journal_mode = DELETE;",
            nil,
            nil,
            &journalError
        )
        guard journalResult == SQLITE_OK else {
            let message = journalError.map { String(cString: $0) } ?? Self.message(from: destination)
            sqlite3_free(journalError)
            throw StoreError.execute("v1 备份收尾失败：\(message)")
        }

        sqlite3_close(destination)
        destination = nil
        guard try isValidV1Backup(at: temporaryURL) else {
            throw StoreError.execute("v1 备份完整性检查失败")
        }
        do {
            try FileManager.default.moveItem(at: temporaryURL, to: backupURL)
        } catch {
            throw StoreError.execute("无法保存 v1 备份：\(error.localizedDescription)")
        }
    }

    private func isValidV1Backup(at url: URL) throws -> Bool {
        var backupDatabase: OpaquePointer?
        guard sqlite3_open_v2(
            url.path,
            &backupDatabase,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK else {
            if let backupDatabase { sqlite3_close(backupDatabase) }
            return false
        }
        defer { sqlite3_close(backupDatabase) }

        func backupText(_ sql: String) throws -> String? {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(backupDatabase, sql, -1, &statement, nil) == SQLITE_OK else {
                throw StoreError.execute("无法检查 v1 备份：\(Self.message(from: backupDatabase))")
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let value = sqlite3_column_text(statement, 0) else { return nil }
            return String(cString: value)
        }

        let quickCheck = try backupText("PRAGMA quick_check;")
        let hasCanonicalTable = try backupText(
            "SELECT CAST(EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'daily_device_key_counts') AS TEXT);"
        )
        return quickCheck == "ok" && hasCanonicalTable == "1"
    }

    // MARK: Legacy invalid-key repair

    private func repairInvalidKeyCountsInCurrentTransaction() throws {
        let invalid = try rows(
            """
            SELECT local_day, device_id, SUM(count)
            FROM daily_device_key_counts
            WHERE (usage_page = 7 AND usage BETWEEN 0 AND 3)
               OR (usage_page = 12 AND usage = 0)
            GROUP BY local_day, device_id
            """
        )
        for row in invalid {
            guard let interval = localDayInterval(row.text(0)) else { continue }
            try repairAggregate(
                table: "minute_device_counts",
                deviceID: row.text(1),
                interval: interval,
                invalidCount: row.int(2)
            )
            try repairAggregate(
                table: "hourly_device_counts",
                deviceID: row.text(1),
                interval: interval,
                invalidCount: row.int(2)
            )
        }
        try run("""
            DELETE FROM daily_device_key_counts
            WHERE (usage_page = 7 AND usage BETWEEN 0 AND 3)
               OR (usage_page = 12 AND usage = 0);
            """)
    }

    private func repairAggregate(
        table: String,
        deviceID: String,
        interval: DateInterval,
        invalidCount: Int64
    ) throws {
        let source = try rows(
            "SELECT bucket_start, count FROM \(table) WHERE device_id = ? AND bucket_start >= ? AND bucket_start < ? ORDER BY bucket_start",
            bindings: [
                .text(deviceID),
                .int(Int64(interval.start.timeIntervalSince1970)),
                .int(Int64(interval.end.timeIntervalSince1970))
            ]
        )
        var remainingInvalid = min(invalidCount, source.reduce(0) { $0 + $1.int(1) })
        var remainingTotal = source.reduce(0) { $0 + $1.int(1) }
        for (index, row) in source.enumerated() {
            let bucket = row.int(0)
            let count = row.int(1)
            let removal: Int64
            if index == source.index(before: source.endIndex) {
                removal = min(count, remainingInvalid)
            } else if remainingTotal > 0 {
                removal = min(
                    count,
                    Int64((Double(remainingInvalid) * Double(count) / Double(remainingTotal)).rounded())
                )
            } else {
                removal = 0
            }
            try prepared(
                "UPDATE \(table) SET count = count - ? WHERE bucket_start = ? AND device_id = ?",
                bindings: [.int(removal), .int(bucket), .text(deviceID)]
            )
            remainingInvalid -= removal
            remainingTotal -= count
        }
        try prepared(
            "DELETE FROM \(table) WHERE device_id = ? AND count <= 0",
            bindings: [.text(deviceID)]
        )
    }

    // MARK: State and date helpers

    private func canonicalSignatureFromSource() throws -> String {
        let total = try intValue("SELECT COALESCE(SUM(count), 0) FROM daily_device_key_counts") ?? 0
        return "v1:\(total)"
    }

    private func prepareCanonicalStateForWrite() throws -> Int64 {
        let stored = try textValue(
            "SELECT canonical_signature FROM statistics_state WHERE singleton = 1",
            bindings: []
        ) ?? "v1:0"
        if stored.hasPrefix("v1:"), let total = Int64(stored.dropFirst(3)) {
            return total
        }

        // A v1 executable can still write the canonical table because the
        // format is intentionally retained. Persistent triggers mark that as
        // dirty even when its operation (for example merge) preserves the
        // global total, so synchronize before accepting another v2 flush.
        try rebuildDerivedTablesInCurrentTransaction()
        try validateDerivedTables()
        let signature = try canonicalSignatureFromSource()
        try prepared(
            "UPDATE statistics_state SET canonical_signature = ? WHERE singleton = 1",
            bindings: [.text(signature)]
        )
        return Int64(signature.dropFirst(3)) ?? 0
    }

    private func refreshCanonicalSignature() throws {
        try prepared(
            "UPDATE statistics_state SET canonical_signature = ? WHERE singleton = 1",
            bindings: [.text(try canonicalSignatureFromSource())]
        )
    }

    private func setCanonicalSignature(total: Int64) throws {
        try prepared(
            "UPDATE statistics_state SET canonical_signature = ? WHERE singleton = 1",
            bindings: [.text("v1:\(total)")]
        )
    }

    private func bumpRevision() throws -> Int64 {
        try run("UPDATE statistics_state SET revision = revision + 1 WHERE singleton = 1;")
        return try revision()
    }

    private func localDayInterval(_ value: String) -> DateInterval? {
        guard let components = Self.dayComponents(value) else { return nil }
        let calendar = Calendar.autoupdatingCurrent
        guard let start = calendar.date(from: components),
              let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        return DateInterval(start: start, end: end)
    }

    private static func completeMonths(fromDay: String, toDay: String) -> [String] {
        guard let startComponents = dayComponents(fromDay),
              let endComponents = dayComponents(toDay) else { return [] }
        let calendar = Calendar.autoupdatingCurrent
        guard let start = calendar.date(from: startComponents),
              let end = calendar.date(from: endComponents) else { return [] }
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
        guard let firstMonth = completeMonths.first,
              let lastMonth = completeMonths.last,
              let firstComponents = dayComponents("\(firstMonth)-01"),
              let lastComponents = dayComponents("\(lastMonth)-01") else {
            return [(fromDay, toDay)]
        }
        let calendar = Calendar.autoupdatingCurrent
        guard let firstCompleteDay = calendar.date(from: firstComponents),
              let lastCompleteDay = calendar.date(from: lastComponents),
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

    private static func dayComponents(_ value: String) -> DateComponents? {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return DateComponents(year: parts[0], month: parts[1], day: parts[2])
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
    private func prepared(_ sql: String, bindings: [V2Binding]) throws -> Int32 {
        let statement = try prepareV2(sql)
        defer { sqlite3_finalize(statement) }
        try bindV2(bindings, to: statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            if result == SQLITE_INTERRUPT { throw CancellationError() }
            throw StoreError.execute(Self.message(from: database))
        }
        return sqlite3_changes(database)
    }

    private func batch(_ sql: String, rows: [[V2Binding]]) throws {
        guard !rows.isEmpty else { return }
        let statement = try prepareV2(sql)
        defer { sqlite3_finalize(statement) }
        for bindings in rows {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            try bindV2(bindings, to: statement)
            let result = sqlite3_step(statement)
            guard result == SQLITE_DONE else {
                if result == SQLITE_INTERRUPT { throw CancellationError() }
                throw StoreError.execute(Self.message(from: database))
            }
        }
    }

    private func intValue(_ sql: String, bindings: [V2Binding] = []) throws -> Int64? {
        try rows(sql, bindings: bindings).first?.optionalInt(0)
    }

    private func textValue(_ sql: String, bindings: [V2Binding]) throws -> String? {
        try rows(sql, bindings: bindings).first?.optionalText(0)
    }

    private func rows(_ sql: String, bindings: [V2Binding] = []) throws -> [V2Row] {
        let statement = try prepareV2(sql)
        defer { sqlite3_finalize(statement) }
        try bindV2(bindings, to: statement)
        var resultRows: [V2Row] = []
        while true {
            let result = sqlite3_step(statement)
            switch result {
            case SQLITE_ROW:
                let columns = (0..<sqlite3_column_count(statement)).map { index -> V2Column in
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
                resultRows.append(V2Row(columns: columns))
            case SQLITE_DONE:
                return resultRows
            case SQLITE_INTERRUPT:
                throw CancellationError()
            default:
                throw StoreError.execute(Self.message(from: database))
            }
        }
    }

    private func prepareV2(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK else {
            if result == SQLITE_INTERRUPT { throw CancellationError() }
            throw StoreError.prepare(Self.message(from: database))
        }
        return statement
    }

    private func bindV2(_ bindings: [V2Binding], to statement: OpaquePointer?) throws {
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

private let sqliteStoreV2ProgressCallback: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { context in
    guard let context else { return 0 }
    let store = Unmanaged<SQLiteStore>.fromOpaque(context).takeUnretainedValue()
    return store.shouldCancelProgress() ? 1 : 0
}

private struct V2BucketDevice: Hashable {
    let bucket: Int64
    let deviceID: UUID
}

private struct V2DayDevice: Hashable {
    let day: String
    let deviceID: UUID
}

private struct V2DayDeviceKey: Hashable {
    let day: String
    let deviceID: UUID
    let key: HIDKeyID
}

private struct V2MonthDeviceKey: Hashable {
    let month: String
    let deviceID: UUID
    let key: HIDKeyID
}

private enum V2Binding {
    case int(Int64)
    case text(String)
    case null

    static func optionalText(_ value: String?) -> V2Binding {
        value.map(V2Binding.text) ?? .null
    }
}

private enum V2Column {
    case int(Int64)
    case text(String)
    case null
}

private struct V2Row {
    let columns: [V2Column]

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
