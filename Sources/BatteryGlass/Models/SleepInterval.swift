import Foundation

/// A recorded system-sleep boundary used to keep sleep time out of awake-sample integration.
struct SleepInterval: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var start: Date
    var end: Date

    init(id: UUID = UUID(), start: Date, end: Date) {
        self.id = id
        self.start = start
        self.end = end
    }

    /// Uses half-open intervals so touching boundaries remain awake time.
    func overlaps(_ rangeStart: Date, _ rangeEnd: Date) -> Bool {
        guard end > start, rangeEnd > rangeStart else { return false }
        return start < rangeEnd && end > rangeStart
    }
}
