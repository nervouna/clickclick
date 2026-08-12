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

final class SQLiteStore {
    private var database: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK else {
            throw StoreError.open(Self.message(from: database))
        }
        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA foreign_keys = ON;")
        try execute("PRAGMA synchronous = NORMAL;")
        try migrate()
        try repairInvalidKeyCounts()
    }

    deinit {
        sqlite3_close(database)
    }

    func resolveDevice(_ descriptor: DeviceDescriptor) throws -> UUID {
        if let existing = try scalarText(
            "SELECT device_id FROM device_aliases WHERE fingerprint = ? LIMIT 1",
            bindings: [.text(descriptor.observedFingerprint)]
        ), let id = UUID(uuidString: existing) {
            try executePrepared(
                "UPDATE devices SET last_seen_at = ?, product = COALESCE(?, product), transport = COALESCE(?, transport) WHERE id = ?",
                bindings: [.int(timestamp()), .optionalText(descriptor.product), .optionalText(descriptor.transport), .text(id.uuidString)]
            )
            return id
        }

        let id = UUID()
        try transaction {
            try executePrepared(
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
                    .int(timestamp()), .int(timestamp())
                ]
            )
            try executePrepared(
                "INSERT INTO device_aliases (fingerprint, device_id) VALUES (?, ?)",
                bindings: [.text(descriptor.observedFingerprint), .text(id.uuidString)]
            )
        }
        return id
    }

    func apply(_ increments: [CountIncrement]) throws {
        guard !increments.isEmpty else { return }
        try transaction {
            for increment in increments {
                try executePrepared(
                    """
                    INSERT INTO minute_device_counts (bucket_start, device_id, count) VALUES (?, ?, ?)
                    ON CONFLICT(bucket_start, device_id) DO UPDATE SET count = count + excluded.count
                    """,
                    bindings: [.int(increment.minute), .text(increment.deviceID.uuidString), .int(increment.count)]
                )
                try executePrepared(
                    """
                    INSERT INTO hourly_device_counts (bucket_start, device_id, count) VALUES (?, ?, ?)
                    ON CONFLICT(bucket_start, device_id) DO UPDATE SET count = count + excluded.count
                    """,
                    bindings: [.int(increment.hour), .text(increment.deviceID.uuidString), .int(increment.count)]
                )
                try executePrepared(
                    """
                    INSERT INTO daily_device_key_counts (local_day, device_id, usage_page, usage, count)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(local_day, device_id, usage_page, usage) DO UPDATE SET count = count + excluded.count
                    """,
                    bindings: [
                        .text(increment.localDay), .text(increment.deviceID.uuidString),
                        .int(Int64(increment.key.usagePage)), .int(Int64(increment.key.usage)), .int(increment.count)
                    ]
                )
            }
        }
    }

    func pruneMinuteData(before timestamp: Int64) throws {
        try executePrepared("DELETE FROM minute_device_counts WHERE bucket_start < ?", bindings: [.int(timestamp)])
    }

    func dashboard(connected: Set<UUID>) throws -> DashboardSnapshot {
        let devices = try fetchDevices(connected: connected)
        let localDay = TimeBuckets.localDay(for: Date())
        let rows = try query(
            """
            SELECT d.id, d.display_name, COALESCE(SUM(k.count), 0)
            FROM devices d
            LEFT JOIN daily_device_key_counts k ON k.device_id = d.id AND k.local_day = ?
            WHERE d.is_hidden = 0
            GROUP BY d.id, d.display_name
            ORDER BY COALESCE(SUM(k.count), 0) DESC, d.display_name
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
        let rows = try query(
            """
            SELECT d.id, d.display_name, d.manufacturer, d.product, d.transport,
                   d.is_built_in, d.is_hidden, COALESCE(SUM(h.count), 0)
            FROM devices d
            LEFT JOIN hourly_device_counts h ON h.device_id = d.id
            GROUP BY d.id
            ORDER BY d.is_built_in DESC, d.display_name
            """
        )
        return rows.compactMap { row in
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

    func trendRows(from: Date, to: Date, minute: Bool, deviceID: UUID?) throws -> [(Int64, UUID, String, Int64)] {
        let table = minute ? "minute_device_counts" : "hourly_device_counts"
        var sql = """
            SELECT c.bucket_start, d.id, d.display_name, c.count
            FROM \(table) c JOIN devices d ON d.id = c.device_id
            WHERE c.bucket_start >= ? AND c.bucket_start < ? AND d.is_hidden = 0
            """
        var bindings: [Binding] = [.int(Int64(from.timeIntervalSince1970)), .int(Int64(to.timeIntervalSince1970))]
        if let deviceID {
            sql += " AND d.id = ?"
            bindings.append(.text(deviceID.uuidString))
        }
        sql += " ORDER BY c.bucket_start, d.display_name"
        return try query(sql, bindings: bindings).compactMap { row in
            guard let id = UUID(uuidString: row.text(1)) else { return nil }
            return (row.int(0), id, row.text(2), row.int(3))
        }
    }

    func keyCounts(fromDay: String, toDay: String, deviceID: UUID?) throws -> [KeyCount] {
        var sql = """
            SELECT usage_page, usage, SUM(count)
            FROM daily_device_key_counts
            WHERE local_day >= ? AND local_day <= ?
            """
        var bindings: [Binding] = [.text(fromDay), .text(toDay)]
        if let deviceID {
            sql += " AND device_id = ?"
            bindings.append(.text(deviceID.uuidString))
        }
        sql += " GROUP BY usage_page, usage ORDER BY SUM(count) DESC"
        return try query(sql, bindings: bindings).map {
            KeyCount(
                key: HIDKeyID(usagePage: UInt16($0.int(0)), usage: UInt16($0.int(1))),
                count: $0.int(2)
            )
        }
    }

    func renameDevice(id: UUID, name: String) throws {
        try executePrepared(
            "UPDATE devices SET display_name = ? WHERE id = ?",
            bindings: [.text(name), .text(id.uuidString)]
        )
    }

    func setDeviceHidden(id: UUID, hidden: Bool) throws {
        try executePrepared(
            "UPDATE devices SET is_hidden = ? WHERE id = ?",
            bindings: [.int(hidden ? 1 : 0), .text(id.uuidString)]
        )
    }

    func mergeDevice(source: UUID, target: UUID) throws {
        guard source != target else { return }
        try transaction {
            for table in ["minute_device_counts", "hourly_device_counts"] {
                try execute("""
                    INSERT INTO \(table) (bucket_start, device_id, count)
                    SELECT bucket_start, '\(target.uuidString)', count FROM \(table) WHERE device_id = '\(source.uuidString)'
                    ON CONFLICT(bucket_start, device_id) DO UPDATE SET count = count + excluded.count;
                    """)
            }
            try execute("""
                INSERT INTO daily_device_key_counts (local_day, device_id, usage_page, usage, count)
                SELECT local_day, '\(target.uuidString)', usage_page, usage, count
                FROM daily_device_key_counts WHERE device_id = '\(source.uuidString)'
                ON CONFLICT(local_day, device_id, usage_page, usage) DO UPDATE SET count = count + excluded.count;
                """)
            try executePrepared("UPDATE device_aliases SET device_id = ? WHERE device_id = ?", bindings: [.text(target.uuidString), .text(source.uuidString)])
            try deleteDeviceRows(id: source)
            try executePrepared("DELETE FROM devices WHERE id = ?", bindings: [.text(source.uuidString)])
        }
    }

    func deleteDevice(id: UUID) throws {
        try transaction {
            try deleteDeviceRows(id: id)
            try executePrepared("DELETE FROM devices WHERE id = ?", bindings: [.text(id.uuidString)])
        }
    }

    func clearAllCounts() throws {
        try transaction {
            try execute("DELETE FROM minute_device_counts;")
            try execute("DELETE FROM hourly_device_counts;")
            try execute("DELETE FROM daily_device_key_counts;")
        }
    }

    func clearCounts(deviceID: UUID) throws {
        try transaction {
            for table in ["minute_device_counts", "hourly_device_counts", "daily_device_key_counts"] {
                try executePrepared("DELETE FROM \(table) WHERE device_id = ?", bindings: [.text(deviceID.uuidString)])
            }
        }
    }

    private func deleteDeviceRows(id: UUID) throws {
        for table in ["minute_device_counts", "hourly_device_counts", "daily_device_key_counts"] {
            try executePrepared("DELETE FROM \(table) WHERE device_id = ?", bindings: [.text(id.uuidString)])
        }
        try executePrepared("DELETE FROM device_aliases WHERE device_id = ?", bindings: [.text(id.uuidString)])
    }

    private func migrate() throws {
        try execute("""
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
            count INTEGER NOT NULL,
            PRIMARY KEY (bucket_start, device_id)
        );
        CREATE TABLE IF NOT EXISTS hourly_device_counts (
            bucket_start INTEGER NOT NULL,
            device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
            count INTEGER NOT NULL,
            PRIMARY KEY (bucket_start, device_id)
        );
        CREATE TABLE IF NOT EXISTS daily_device_key_counts (
            local_day TEXT NOT NULL,
            device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
            usage_page INTEGER NOT NULL,
            usage INTEGER NOT NULL,
            count INTEGER NOT NULL,
            PRIMARY KEY (local_day, device_id, usage_page, usage)
        );
        CREATE INDEX IF NOT EXISTS idx_hourly_device ON hourly_device_counts(device_id, bucket_start);
        CREATE INDEX IF NOT EXISTS idx_daily_device ON daily_device_key_counts(device_id, local_day);
        """)
    }

    private func repairInvalidKeyCounts() throws {
        let invalidRows = try query(
            """
            SELECT local_day, device_id, SUM(count)
            FROM daily_device_key_counts
            WHERE (usage_page = 7 AND usage BETWEEN 0 AND 3)
               OR (usage_page = 12 AND usage = 0)
            GROUP BY local_day, device_id
            """
        )
        guard !invalidRows.isEmpty else { return }

        try transaction {
            for row in invalidRows {
                let localDay = row.text(0)
                let deviceID = row.text(1)
                let invalidCount = row.int(2)
                guard let interval = localDayInterval(localDay) else { continue }
                try repairAggregateTable(
                    "minute_device_counts",
                    deviceID: deviceID,
                    interval: interval,
                    invalidCount: invalidCount
                )
                try repairAggregateTable(
                    "hourly_device_counts",
                    deviceID: deviceID,
                    interval: interval,
                    invalidCount: invalidCount
                )
            }
            try execute(
                """
                DELETE FROM daily_device_key_counts
                WHERE (usage_page = 7 AND usage BETWEEN 0 AND 3)
                   OR (usage_page = 12 AND usage = 0);
                """
            )
        }
    }

    private func repairAggregateTable(
        _ table: String,
        deviceID: String,
        interval: DateInterval,
        invalidCount: Int64
    ) throws {
        let rows = try query(
            "SELECT bucket_start, count FROM \(table) WHERE device_id = ? AND bucket_start >= ? AND bucket_start < ? ORDER BY bucket_start",
            bindings: [
                .text(deviceID),
                .int(Int64(interval.start.timeIntervalSince1970)),
                .int(Int64(interval.end.timeIntervalSince1970))
            ]
        )
        var remainingInvalid = min(invalidCount, rows.reduce(0) { $0 + $1.int(1) })
        var remainingTotal = rows.reduce(0) { $0 + $1.int(1) }
        for (index, row) in rows.enumerated() {
            let bucket = row.int(0)
            let count = row.int(1)
            let removal: Int64
            if index == rows.index(before: rows.endIndex) {
                removal = min(count, remainingInvalid)
            } else if remainingTotal > 0 {
                removal = min(
                    count,
                    Int64((Double(remainingInvalid) * Double(count) / Double(remainingTotal)).rounded())
                )
            } else {
                removal = 0
            }
            try executePrepared(
                "UPDATE \(table) SET count = count - ? WHERE bucket_start = ? AND device_id = ?",
                bindings: [.int(removal), .int(bucket), .text(deviceID)]
            )
            remainingInvalid -= removal
            remainingTotal -= count
        }
        try executePrepared("DELETE FROM \(table) WHERE device_id = ? AND count <= 0", bindings: [.text(deviceID)])
    }

    private func localDayInterval(_ value: String) -> DateInterval? {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        let calendar = Calendar.autoupdatingCurrent
        guard let start = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        return DateInterval(start: start, end: end)
    }

    private func transaction(_ work: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE;")
        do {
            try work()
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? Self.message(from: database)
            sqlite3_free(error)
            throw StoreError.execute(message)
        }
    }

    private func executePrepared(_ sql: String, bindings: [Binding]) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw StoreError.execute(Self.message(from: database))
        }
    }

    private func scalarText(_ sql: String, bindings: [Binding]) throws -> String? {
        let rows = try query(sql, bindings: bindings)
        return rows.first?.optionalText(0)
    }

    private func query(_ sql: String, bindings: [Binding] = []) throws -> [Row] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        var rows: [Row] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let columns = (0..<sqlite3_column_count(statement)).map { index -> Column in
                if sqlite3_column_type(statement, index) == SQLITE_NULL { return .null }
                if sqlite3_column_type(statement, index) == SQLITE_INTEGER { return .int(sqlite3_column_int64(statement, index)) }
                guard let text = sqlite3_column_text(statement, index) else { return .null }
                return .text(String(cString: text))
            }
            rows.append(Row(columns: columns))
        }
        return rows
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.prepare(Self.message(from: database))
        }
        return statement
    }

    private func bind(_ bindings: [Binding], to statement: OpaquePointer?) throws {
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch binding {
            case .int(let value): result = sqlite3_bind_int64(statement, index, value)
            case .text(let value): result = sqlite3_bind_text(statement, index, value, -1, transient)
            case .null: result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw StoreError.execute(Self.message(from: database)) }
        }
    }

    private func timestamp() -> Int64 { Int64(Date().timeIntervalSince1970) }
    private static func message(from database: OpaquePointer?) -> String {
        database.flatMap(sqlite3_errmsg).map(String.init(cString:)) ?? "unknown error"
    }
}

private enum Binding {
    case int(Int64)
    case text(String)
    case null

    static func optionalText(_ value: String?) -> Binding {
        value.map(Binding.text) ?? .null
    }
}

private enum Column {
    case int(Int64)
    case text(String)
    case null
}

private struct Row {
    let columns: [Column]

    func int(_ index: Int) -> Int64 {
        if case .int(let value) = columns[index] { return value }
        return 0
    }

    func text(_ index: Int) -> String {
        optionalText(index) ?? ""
    }

    func optionalText(_ index: Int) -> String? {
        if case .text(let value) = columns[index] { return value }
        return nil
    }
}
