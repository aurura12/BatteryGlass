import Darwin
import Foundation
import Observation

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

/// 进行中的校准会话：用户「开始校准」时记录起始计数器，之后按电表实测值一次性结算。
struct PowerTelemetryCalibrationSession: Codable, Equatable, Sendable {
    var context: PowerTelemetryCalibrationContext
    var startedAt: Date
    var startCounter: UInt64
    var startBatteryPercent: Double?
}

/// 完成校准会话的结果，供 UI 分支提示。
enum PowerTelemetryCalibrationSessionResult: Equatable {
    case saved(PowerTelemetryCalibrationRecord)
    /// 结束计数器小于起始计数器（计数器被重置，通常因为期间重启过）。
    case counterReset
    /// 会话期间机型/系统版本发生变化，记录不再适用。
    case contextChanged
    /// 输入或计数器差值非法（如实测电量 ≤ 0、差值经校验失败）。
    case invalidInput
}

/// 按机型 + macOS 版本持久化校准记录，并托管进行中的校准会话。
///
/// 是 `@MainActor @Observable` 引用类型：App 层创建唯一实例后同时注入 `BatteryMonitor`
/// 与设置页，使设置页录入的校准能立即被睡眠能耗计量读取，无需重启。
@MainActor
@Observable
final class PowerTelemetryCalibrationStore {
    private struct Payload: Codable, Sendable {
        var version: Int
        var records: [PowerTelemetryCalibrationRecord]
        var session: PowerTelemetryCalibrationSession?
    }

    /// payload 版本；v2 新增可选 `session`（旧文件缺该键，解码为 nil，无需迁移分支）。
    static let payloadVersion = 2

    /// 系数合理性软区间：超出通常意味着单位误输（如把 Wh 当 kWh），UI 据此二次确认。
    static let plausibleFactorRange: ClosedRange<Double> = 0.05...20.0

    private let fileURL: URL
    private let context: PowerTelemetryCalibrationContext
    private(set) var records: [PowerTelemetryCalibrationRecord]
    private(set) var session: PowerTelemetryCalibrationSession?

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
        let loaded = Self.load(from: resolvedURL)
        self.records = loaded.records
        self.session = loaded.session
    }

    /// 当前机型 + 系统版本，也是新校准记录的归属上下文。
    var currentContext: PowerTelemetryCalibrationContext { context }

    /// 当前上下文下最新的有效记录；不匹配当前机型/系统的记录不参与生效。
    var activeRecord: PowerTelemetryCalibrationRecord? {
        records
            .filter { $0.context == context && $0.isValid }
            .max { $0.createdAt < $1.createdAt }
    }

    var calibrationFactor: Double {
        activeRecord?.calibrationFactor ?? 1.0
    }

    var isCalibrated: Bool {
        activeRecord != nil
    }

    func append(_ record: PowerTelemetryCalibrationRecord) {
        guard record.isValid else { return }
        records.append(record)
        save()
    }

    func remove(id: UUID) {
        let before = records.count
        records.removeAll { $0.id == id }
        guard records.count != before else { return }
        save()
    }

    func clearRecords() {
        guard !records.isEmpty else { return }
        records.removeAll()
        save()
    }

    // MARK: - 校准会话

    /// 开始一次校准会话；起始计数器必须为正数。
    @discardableResult
    func startSession(startCounter: UInt64, batteryPercent: Double?) -> Bool {
        guard startCounter > 0 else { return false }
        session = PowerTelemetryCalibrationSession(
            context: context,
            startedAt: Date(),
            startCounter: startCounter,
            startBatteryPercent: batteryPercent
        )
        save()
        return true
    }

    func cancelSession() {
        guard session != nil else { return }
        session = nil
        save()
    }

    /// 用结束计数器与电表实测电量结算会话。
    ///
    /// - `counterReset` / `contextChanged` 会同时清除会话（会话已不可用）；
    /// - `invalidInput` 保留会话，便于用户修正实测值后重试。
    func completeSession(
        endCounter: UInt64,
        measuredEnergyKWh: Double
    ) -> PowerTelemetryCalibrationSessionResult {
        guard let session else { return .invalidInput }

        guard session.context == context else {
            self.session = nil
            save()
            return .contextChanged
        }
        guard endCounter >= session.startCounter else {
            self.session = nil
            save()
            return .counterReset
        }

        let rawDelta = endCounter - session.startCounter
        let uncalibrated = PowerTelemetryEnergy.uncalibratedEnergyKWh(rawDelta: rawDelta)
        guard let record = PowerTelemetryCalibrationRecord(
            context: context,
            rawDelta: rawDelta,
            uncalibratedEnergyKWh: uncalibrated,
            measuredEnergyKWh: measuredEnergyKWh
        ) else {
            return .invalidInput
        }

        records.append(record)
        self.session = nil
        save()
        return .saved(record)
    }

    private static func load(
        from fileURL: URL
    ) -> (records: [PowerTelemetryCalibrationRecord], session: PowerTelemetryCalibrationSession?) {
        guard let data = try? Data(contentsOf: fileURL) else { return ([], nil) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(Payload.self, from: data) else { return ([], nil) }
        return (payload.records, payload.session)
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
            let data = try encoder.encode(
                Payload(version: Self.payloadVersion, records: records, session: session)
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("BatteryGlass: 校准数据保存失败 - %@", error.localizedDescription)
        }
    }
}
