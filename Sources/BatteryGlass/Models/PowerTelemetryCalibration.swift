import Darwin
import Foundation

struct PowerTelemetryCalibrationContext: Codable, Equatable, Sendable {
    var hardwareModel: String
    var operatingSystem: String

    static var current: Self {
        var size = 0
        let model: String
        if sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 {
            var buffer = [UInt8](repeating: 0, count: size)
            let result = buffer.withUnsafeMutableBytes { bytes in
                sysctlbyname("hw.model", bytes.baseAddress, &size, nil, 0)
            }
            model = result == 0 ? String(cString: buffer) : "unknown"
        } else {
            model = "unknown"
        }

        return Self(
            hardwareModel: model,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString
        )
    }
}

struct PowerTelemetryCalibrationRecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var context: PowerTelemetryCalibrationContext
    var rawDelta: UInt64
    var uncalibratedEnergyKWh: Double
    var measuredEnergyKWh: Double
    var calibrationFactor: Double
    var createdAt: Date
    var isCalibrated: Bool

    init?(
        id: UUID = UUID(),
        context: PowerTelemetryCalibrationContext,
        rawDelta: UInt64,
        uncalibratedEnergyKWh: Double,
        measuredEnergyKWh: Double,
        createdAt: Date = Date()
    ) {
        guard rawDelta > 0,
              uncalibratedEnergyKWh.isFinite,
              uncalibratedEnergyKWh > 0,
              measuredEnergyKWh.isFinite,
              measuredEnergyKWh > 0 else {
            return nil
        }

        let factor = measuredEnergyKWh / uncalibratedEnergyKWh
        guard factor.isFinite, factor > 0 else { return nil }

        self.id = id
        self.context = context
        self.rawDelta = rawDelta
        self.uncalibratedEnergyKWh = uncalibratedEnergyKWh
        self.measuredEnergyKWh = measuredEnergyKWh
        self.calibrationFactor = factor
        self.createdAt = createdAt
        self.isCalibrated = true
    }

    var isValid: Bool {
        isCalibrated
            && rawDelta > 0
            && calibrationFactor.isFinite
            && calibrationFactor > 0
            && uncalibratedEnergyKWh.isFinite
            && uncalibratedEnergyKWh > 0
            && measuredEnergyKWh.isFinite
            && measuredEnergyKWh > 0
    }
}

struct PowerTelemetryCalibrationStore: Sendable {
    private struct Payload: Codable, Sendable {
        var version: Int
        var records: [PowerTelemetryCalibrationRecord]
    }

    private let fileURL: URL
    private let context: PowerTelemetryCalibrationContext
    private(set) var records: [PowerTelemetryCalibrationRecord]

    init(
        fileURL: URL? = nil,
        context: PowerTelemetryCalibrationContext = .current
    ) {
        let resolvedURL: URL
        if let fileURL {
            resolvedURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            resolvedURL = base.appendingPathComponent(
                "BatteryGlass/power-calibration.json",
                isDirectory: false
            )
        }

        self.fileURL = resolvedURL
        self.context = context
        self.records = Self.loadRecords(from: resolvedURL)
    }

    var calibrationFactor: Double {
        latestValidRecord?.calibrationFactor ?? 1.0
    }

    var isCalibrated: Bool {
        latestValidRecord != nil
    }

    mutating func append(_ record: PowerTelemetryCalibrationRecord) {
        guard record.isValid else { return }
        records.append(record)
        save()
    }

    private var latestValidRecord: PowerTelemetryCalibrationRecord? {
        records
            .filter { $0.context == context && $0.isValid }
            .max { $0.createdAt < $1.createdAt }
    }

    private static func loadRecords(from fileURL: URL) -> [PowerTelemetryCalibrationRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(Payload.self, from: data))?.records ?? []
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(Payload(version: 1, records: records))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("BatteryGlass: 校准数据保存失败 - %@", error.localizedDescription)
        }
    }
}
