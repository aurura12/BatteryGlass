import Foundation
import SQLite3

/// Minute-resolution curves live in an indexed database; callers serialize access on the
/// history persistence queue. Only the requested day's rows are decoded for charting.
struct HistorySampleArchive: Sendable {
    let fileURL: URL

    /// 往日曲线：按 epoch 分钟桶 upsert，每桶保留时间戳较新的一条。
    func store(_ samples: [HistorySample]) throws {
        guard !samples.isEmpty else { return }
        try withWritableDatabase { database in
            try createTable(.minute, in: database)
            try insertMinuteRows(samples, in: database)
        }
    }

    /// 当天曲线：按原生时间戳保存，重复写入幂等。跨天后由
    /// `archiveLiveSamples(before:)` 降采样进分钟表并删除。
    func storeLiveSamples(_ samples: [HistorySample]) throws {
        guard !samples.isEmpty else { return }
        try withWritableDatabase { database in
            try createTable(.live, in: database)
            try insertLiveRows(samples, in: database)
        }
    }

    /// 读取某天的当天高精度曲线（重启后恢复当天样本用）。
    func liveSamples(forDay day: Date, calendar: Calendar = .current) throws -> [HistorySample] {
        guard let interval = calendar.dateInterval(of: .day, for: day) else { return [] }
        return try readSamples(from: interval.start, to: interval.end, table: .live)
    }

    /// 跨午夜前的最后一条当天样本：重启后用它和今天首条样本续接能量积分。
    func lastLiveSample(before date: Date) throws -> HistorySample? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let database = try open(writable: false)
        defer { sqlite3_close(database) }
        guard try hasTable(.live, in: database) else { return nil }
        let statement = try prepare(
            "SELECT timestamp, payload FROM live_samples WHERE timestamp < ? ORDER BY timestamp DESC LIMIT 1",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 1) else {
            throw failure(in: database)
        }
        return try? decodeSample(
            Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1))),
            timestamp: sqlite3_column_double(statement, 0)
        )
    }

    /// 已写入 `live_samples` 的最新样本时间；没有任何当天样本时为 nil。
    func latestLiveTimestamp() throws -> Date? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let database = try open(writable: false)
        defer { sqlite3_close(database) }
        guard try hasTable(.live, in: database) else { return nil }
        let statement = try prepare("SELECT MAX(timestamp) FROM live_samples", in: database)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure(in: database) }
        guard sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
    }

    /// 跨天：把 `date` 之前的当天样本降采样进分钟表并删除，返回搬移条数。
    /// 分钟表的 upsert 语义天然实现「每分钟保留最后一个点」。
    @discardableResult
    func archiveLiveSamples(before date: Date) throws -> Int {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return 0 }
        var archived = 0
        try withWritableDatabase { database in
            try createTable(.minute, in: database)
            try createTable(.live, in: database)
            let old = try decodeSamples(from: nil, to: date, table: .live, in: database)
            guard !old.isEmpty else { return }
            archived = old.count
            try insertMinuteRows(old, in: database)
            let statement = try prepare("DELETE FROM live_samples WHERE timestamp < ?", in: database)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw failure(in: database) }
        }
        return archived
    }

    func samples(forDay day: Date, calendar: Calendar = .current) throws -> [HistorySample] {
        guard let interval = calendar.dateInterval(of: .day, for: day) else { return [] }
        return try readSamples(from: interval.start, to: interval.end)
    }

    func allSamples() throws -> [HistorySample] {
        try readSamples(from: nil, to: nil)
    }

    func availableDays(calendar: Calendar = .current) throws -> [Date] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let database = try open(writable: false)
        defer { sqlite3_close(database) }
        let statement = try prepare("SELECT timestamp FROM samples ORDER BY timestamp", in: database)
        defer { sqlite3_finalize(statement) }
        var days: [Date] = []
        var nextDay = Date.distantPast
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return days }
            guard result == SQLITE_ROW else { throw failure(in: database) }
            let date = Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
            if date >= nextDay, let interval = calendar.dateInterval(of: .day, for: date) {
                days.append(interval.start)
                nextDay = interval.end
            }
        }
    }

    func remove() throws {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let url = URL(fileURLWithPath: fileURL.path + suffix)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    /// One-time rewrite of archived JSON rows. Decoding with the current `HistorySample`
    /// ignores the retired temperature field, and encoding removes it from stored blobs.
    func removeTemperatureHistory() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let database = try open(writable: true)
        defer { sqlite3_close(database) }

        try execute("BEGIN IMMEDIATE", in: database)
        do {
            if try userVersion(in: database) >= 1 {
                try execute("COMMIT", in: database)
                return
            }

            guard try hasTable(.minute, in: database) else {
                try execute("PRAGMA user_version = 1", in: database)
                try execute("COMMIT", in: database)
                return
            }

            let samples = try archivedSamples(in: database)
            let statement = try prepare("UPDATE samples SET payload = ? WHERE minute = ?", in: database)
            defer { sqlite3_finalize(statement) }

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            for (minute, sample) in samples {
                let data = try encoder.encode(sample)
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                let bindResult = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(
                        statement,
                        1,
                        bytes.baseAddress,
                        Int32(bytes.count),
                        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                    )
                }
                guard bindResult == SQLITE_OK else { throw failure(in: database) }
                sqlite3_bind_int64(statement, 2, minute)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw failure(in: database) }
            }

            try execute("PRAGMA user_version = 1", in: database)
            try execute("COMMIT", in: database)
        } catch {
            try? execute("ROLLBACK", in: database)
            throw error
        }
    }

    private func readSamples(
        from start: Date?,
        to end: Date?,
        table: Table = .minute
    ) throws -> [HistorySample] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let database = try open(writable: false)
        defer { sqlite3_close(database) }
        guard try hasTable(table, in: database) else { return [] }
        return try decodeSamples(from: start, to: end, table: table, in: database)
    }

    private func decodeSamples(
        from start: Date?,
        to end: Date?,
        table: Table,
        in database: OpaquePointer
    ) throws -> [HistorySample] {
        var clauses: [String] = []
        if start != nil { clauses.append("timestamp >= ?") }
        if end != nil { clauses.append("timestamp < ?") }
        let filter = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        let query = "SELECT timestamp, payload FROM \(table.rawValue)\(filter) ORDER BY timestamp"
        let statement = try prepare(query, in: database)
        defer { sqlite3_finalize(statement) }
        var index: Int32 = 1
        if let start {
            sqlite3_bind_double(statement, index, start.timeIntervalSince1970)
            index += 1
        }
        if let end {
            sqlite3_bind_double(statement, index, end.timeIntervalSince1970)
        }
        var samples: [HistorySample] = []
        var skipped = 0
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE {
                if skipped > 0 {
                    // 单条 payload 损坏（旧版本写入中断、磁盘位翻转）不应让整天陪葬：
                    // 跳过坏行继续读，其余分钟仍能正常展示。
                    NSLog("BatteryGlass: 曲线归档跳过 %d 条无法解码的记录", skipped)
                }
                return samples
            }
            guard result == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 1) else {
                throw failure(in: database)
            }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1)))
            if let sample = try? decodeSample(data, timestamp: sqlite3_column_double(statement, 0)) {
                samples.append(sample)
            } else {
                skipped += 1
            }
        }
    }

    /// payload 里的时间戳精度有限（ISO 8601 不带小数秒），行主键才是原始值。
    /// 解码后用行内时间戳覆盖，保证内存样本与主键一致：否则诊断回填按时间戳
    /// upsert 时会因小数秒差新增一行，重启后加载出同一 id 的两条记录。
    private func decodeSample(_ data: Data, timestamp: Double) throws -> HistorySample {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var sample = try decoder.decode(HistorySample.self, from: data)
        sample.timestamp = Date(timeIntervalSince1970: timestamp)
        return sample
    }

    private enum Table: String {
        case minute = "samples"
        case live = "live_samples"
    }

    private func withWritableDatabase(_ body: (OpaquePointer) throws -> Void) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let database = try open(writable: true)
        defer { sqlite3_close(database) }
        try execute("BEGIN IMMEDIATE", in: database)
        do {
            try body(database)
            try execute("COMMIT", in: database)
        } catch {
            try? execute("ROLLBACK", in: database)
            throw error
        }
    }

    private func createTable(_ table: Table, in database: OpaquePointer) throws {
        switch table {
        case .minute:
            try execute("CREATE TABLE IF NOT EXISTS samples (minute INTEGER PRIMARY KEY, timestamp REAL NOT NULL, payload BLOB NOT NULL)", in: database)
            try execute("CREATE INDEX IF NOT EXISTS samples_timestamp ON samples(timestamp)", in: database)
        case .live:
            try execute("CREATE TABLE IF NOT EXISTS live_samples (timestamp REAL PRIMARY KEY, payload BLOB NOT NULL)", in: database)
        }
    }

    private func insertMinuteRows(_ samples: [HistorySample], in database: OpaquePointer) throws {
        let statement = try prepare("""
            INSERT INTO samples(minute, timestamp, payload) VALUES (?, ?, ?)
            ON CONFLICT(minute) DO UPDATE SET timestamp = excluded.timestamp, payload = excluded.payload
            WHERE excluded.timestamp >= samples.timestamp
            """, in: database)
        defer { sqlite3_finalize(statement) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        for sample in samples {
            let data = try encoder.encode(sample)
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_int64(statement, 1, Int64(floor(sample.timestamp.timeIntervalSince1970 / 60)))
            sqlite3_bind_double(statement, 2, sample.timestamp.timeIntervalSince1970)
            try bindBlob(data, at: 3, in: statement, database: database)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw failure(in: database) }
        }
    }

    private func insertLiveRows(_ samples: [HistorySample], in database: OpaquePointer) throws {
        let statement = try prepare(
            "INSERT OR REPLACE INTO live_samples(timestamp, payload) VALUES (?, ?)",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        for sample in samples {
            let data = try encoder.encode(sample)
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_double(statement, 1, sample.timestamp.timeIntervalSince1970)
            try bindBlob(data, at: 2, in: statement, database: database)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw failure(in: database) }
        }
    }

    private func bindBlob(
        _ data: Data,
        at index: Int32,
        in statement: OpaquePointer,
        database: OpaquePointer
    ) throws {
        let result = data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(
                statement, index, bytes.baseAddress, Int32(bytes.count),
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            )
        }
        guard result == SQLITE_OK else { throw failure(in: database) }
    }

    private func open(writable: Bool) throws -> OpaquePointer {
        var database: OpaquePointer?
        let flags = writable ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE : SQLITE_OPEN_READONLY
        let result = sqlite3_open_v2(fileURL.path, &database, flags, nil)
        guard result == SQLITE_OK, let database else {
            let error = failure(in: database)
            if let database { sqlite3_close(database) }
            throw error
        }
        sqlite3_busy_timeout(database, 5_000)
        return database
    }

    private func userVersion(in database: OpaquePointer) throws -> Int32 {
        let statement = try prepare("PRAGMA user_version", in: database)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure(in: database) }
        return sqlite3_column_int(statement, 0)
    }

    private func hasTable(_ table: Table, in database: OpaquePointer) throws -> Bool {
        let statement = try prepare(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, table.rawValue, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW { return true }
        if result == SQLITE_DONE { return false }
        throw failure(in: database)
    }

    private func archivedSamples(in database: OpaquePointer) throws -> [(Int64, HistorySample)] {
        let statement = try prepare("SELECT minute, payload FROM samples ORDER BY timestamp", in: database)
        defer { sqlite3_finalize(statement) }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var samples: [(Int64, HistorySample)] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return samples }
            guard result == SQLITE_ROW,
                  let bytes = sqlite3_column_blob(statement, 1) else {
                throw failure(in: database)
            }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1)))
            let sample = try decoder.decode(HistorySample.self, from: data)
            samples.append((sqlite3_column_int64(statement, 0), sample))
        }
    }

    private func prepare(_ sql: String, in database: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw failure(in: database) }
        return statement
    }

    private func execute(_ sql: String, in database: OpaquePointer) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw failure(in: database)
        }
    }

    private func failure(in database: OpaquePointer?) -> NSError {
        NSError(domain: "BatteryGlass.HistoryArchive", code: Int(sqlite3_errcode(database)), userInfo: [
            NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))
        ])
    }
}
