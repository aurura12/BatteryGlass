import AppKit
import Foundation

final class PowerDiagnosticsLogger {
    static let shared = PowerDiagnosticsLogger()

    private static let logDirectoryName = "BatteryGlass"
    private static let defaultLogFileName = "power-diagnostics.jsonl"
    private static let defaultMaximumLogBytes = 5_000_000
    private static let defaultMinimumInterval: TimeInterval = 1

    let directoryURL: URL
    let fileURL: URL
    private let maximumLogBytes: Int
    private let minimumInterval: TimeInterval

    private let queue = DispatchQueue(label: "com.batteryglass.power-diagnostics", qos: .utility)
    private let lock = NSLock()
    private var lastLoggedAt = Date.distantPast

    /// 生产实例使用 Application Support 下的固定位置；测试可注入临时目录与极小阈值，
    /// 从而验证轮换行为而不污染真实日志。
    init(
        directory: URL = PowerDiagnosticsLogger.defaultDirectoryURL,
        fileName: String = PowerDiagnosticsLogger.defaultLogFileName,
        maximumLogBytes: Int = PowerDiagnosticsLogger.defaultMaximumLogBytes,
        minimumInterval: TimeInterval = PowerDiagnosticsLogger.defaultMinimumInterval
    ) {
        self.directoryURL = directory
        self.fileURL = directory.appendingPathComponent(fileName, isDirectory: false)
        self.maximumLogBytes = maximumLogBytes
        self.minimumInterval = minimumInterval
    }

    static var defaultDirectoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(logDirectoryName, isDirectory: true)
    }

    /// 默认实例的日志位置（恢复与设置页按固定路径读取）。
    static var logDirectoryURL: URL { shared.directoryURL }
    static var logFileURL: URL { shared.fileURL }

    func record(_ sample: PowerDiagnosticsSample) {
        lock.lock()
        defer { lock.unlock() }

        guard sample.timestamp.timeIntervalSince(lastLoggedAt) >= minimumInterval else { return }
        lastLoggedAt = sample.timestamp

        queue.async {
            self.append(sample)
        }
    }

    func openLogDirectory() {
        try? FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.open(directoryURL)
    }

    /// 同步写入一条记录。`record` 负责节流并转到串行队列；测试直接调用这里。
    func append(_ sample: PowerDiagnosticsSample) {
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            var line = try encoder.encode(sample)
            line.append(0x0A)

            if let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
               let fileSize = attributes[.size] as? NSNumber,
               fileSize.intValue + line.count > maximumLogBytes {
                rotate()
            }

            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
                try handle.close()
            } else {
                try line.write(to: fileURL, options: .atomic)
            }
        } catch {
            NSLog("BatteryGlass: 电源诊断日志保存失败 - %@", error.localizedDescription)
        }
    }

    /// 只保留一份备份：新的轮换会丢弃上一次的备份文件。
    private func rotate() {
        let backupURL = fileURL.deletingPathExtension().appendingPathExtension("1.jsonl")
        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.moveItem(at: fileURL, to: backupURL)
    }
}
