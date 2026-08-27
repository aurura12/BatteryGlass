import AppKit
import Foundation

final class PowerDiagnosticsLogger {
    static let shared = PowerDiagnosticsLogger()

    private static let logDirectoryName = "BatteryGlass"
    private static let logFileName = "power-diagnostics.jsonl"
    private static let maximumLogBytes = 5_000_000
    private static let minimumInterval: TimeInterval = 1

    private let queue = DispatchQueue(label: "com.batteryglass.power-diagnostics", qos: .utility)
    private let lock = NSLock()
    private var lastLoggedAt = Date.distantPast

    private init() {}

    static var logDirectoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(logDirectoryName, isDirectory: true)
    }

    static var logFileURL: URL {
        logDirectoryURL.appendingPathComponent(logFileName, isDirectory: false)
    }

    func record(_ sample: PowerDiagnosticsSample) {
        lock.lock()
        defer { lock.unlock() }

        guard sample.timestamp.timeIntervalSince(lastLoggedAt) >= Self.minimumInterval else { return }
        lastLoggedAt = sample.timestamp

        let logURL = Self.logFileURL
        queue.async {
            Self.append(sample, to: logURL)
        }
    }

    func openLogDirectory() {
        let directory = Self.logDirectoryURL
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.open(directory)
    }

    private static func append(_ sample: PowerDiagnosticsSample, to logURL: URL) {
        do {
            let directory = logURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            var line = try encoder.encode(sample)
            line.append(0x0A)

            if let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path),
               let fileSize = attributes[.size] as? NSNumber,
               fileSize.intValue + line.count > maximumLogBytes {
                rotate(logURL)
            }

            if FileManager.default.fileExists(atPath: logURL.path) {
                let handle = try FileHandle(forWritingTo: logURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
                try handle.close()
            } else {
                try line.write(to: logURL, options: .atomic)
            }
        } catch {
            NSLog("BatteryGlass: 电源诊断日志保存失败 - %@", error.localizedDescription)
        }
    }

    private static func rotate(_ logURL: URL) {
        let backupURL = logURL.deletingPathExtension().appendingPathExtension("1.jsonl")
        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.moveItem(at: logURL, to: backupURL)
    }
}
