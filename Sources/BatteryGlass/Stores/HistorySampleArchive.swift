import Foundation
import SQLite3

/// Minute-resolution curves live in an indexed database; callers serialize access on the
/// history persistence queue. Only the requested day's rows are decoded for charting.
struct HistorySampleArchive: Sendable {
    let fileURL: URL

    func store(_ samples: [HistorySample]) throws {
        guard !samples.isEmpty else { return }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let database = try open(writable: true)
        defer { sqlite3_close(database) }
        try execute("CREATE TABLE IF NOT EXISTS samples (minute INTEGER PRIMARY KEY, timestamp REAL NOT NULL, payload BLOB NOT NULL)", in: database)
        try execute("CREATE INDEX IF NOT EXISTS samples_timestamp ON samples(timestamp)", in: database)
        try execute("BEGIN IMMEDIATE", in: database)
        do {
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
                let result = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, 3, bytes.baseAddress, Int32(bytes.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
                guard result == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else {
                    throw failure(in: database)
                }
            }
            try execute("COMMIT", in: database)
        } catch {
            try? execute("ROLLBACK", in: database)
            throw error
        }
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

    private func readSamples(from start: Date?, to end: Date?) throws -> [HistorySample] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let database = try open(writable: false)
        defer { sqlite3_close(database) }
        let query = start == nil
            ? "SELECT payload FROM samples ORDER BY timestamp"
            : "SELECT payload FROM samples WHERE timestamp >= ? AND timestamp < ? ORDER BY timestamp"
        let statement = try prepare(query, in: database)
        defer { sqlite3_finalize(statement) }
        if let start, let end {
            sqlite3_bind_double(statement, 1, start.timeIntervalSince1970)
            sqlite3_bind_double(statement, 2, end.timeIntervalSince1970)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var samples: [HistorySample] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return samples }
            guard result == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else {
                throw failure(in: database)
            }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
            samples.append(try decoder.decode(HistorySample.self, from: data))
        }
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
