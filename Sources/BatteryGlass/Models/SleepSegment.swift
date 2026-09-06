import Foundation

/// 待机（系统睡眠）场景分类。
enum SleepSegmentMode: String, Codable, Sendable {
    /// 不插电，电池放电
    case discharging
    /// 插电且正在充电
    case charging
    /// 插电，未充电（充满停充/浮充）
    case pluggedIdle
}

enum SleepEnergyMeasurementMethod: String, Codable, Sendable, Equatable {
    case telemetryCounter
    case fallbackEstimate
}

/// 一次待机区间的能量统计。
///
/// `energyKWh` 为电脑从电源（插座或电池）消耗的总能量，恒为正：
/// - 不插电待机：电池放电能量（电量差 × 电压）；
/// - 插电待机：优先累计墙上输入能量；不可用时回退到充入电池能量和系统维持功耗估算。
struct SleepSegment: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var start: Date
    var end: Date
    /// 从电源消耗的能量（kWh），恒正
    var energyKWh: Double
    /// 待机期间平均功率（W）= energyKWh 换算后 / 时长
    var averagePowerW: Double?
    var mode: SleepSegmentMode
    /// 记录该区间是由累计遥测还是回退估算得到。
    var measurementMethod: SleepEnergyMeasurementMethod = .fallbackEstimate
    /// Whether a validated, physically calibrated counter factor was applied.
    var isCalibrated: Bool = false

    private enum CodingKeys: String, CodingKey {
        case id, start, end, energyKWh, averagePowerW, mode, measurementMethod, isCalibrated
    }

    init(
        id: UUID,
        start: Date,
        end: Date,
        energyKWh: Double,
        averagePowerW: Double?,
        mode: SleepSegmentMode,
        measurementMethod: SleepEnergyMeasurementMethod = .fallbackEstimate,
        isCalibrated: Bool = false
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.energyKWh = energyKWh
        self.averagePowerW = averagePowerW
        self.mode = mode
        self.measurementMethod = measurementMethod
        self.isCalibrated = isCalibrated
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        start = try container.decode(Date.self, forKey: .start)
        end = try container.decode(Date.self, forKey: .end)
        energyKWh = try container.decode(Double.self, forKey: .energyKWh)
        averagePowerW = try container.decodeIfPresent(Double.self, forKey: .averagePowerW)
        mode = try container.decode(SleepSegmentMode.self, forKey: .mode)
        measurementMethod = try container.decodeIfPresent(
            SleepEnergyMeasurementMethod.self,
            forKey: .measurementMethod
        ) ?? .fallbackEstimate
        isCalibrated = try container.decodeIfPresent(Bool.self, forKey: .isCalibrated) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
        try container.encode(energyKWh, forKey: .energyKWh)
        try container.encodeIfPresent(averagePowerW, forKey: .averagePowerW)
        try container.encode(mode, forKey: .mode)
        try container.encode(measurementMethod, forKey: .measurementMethod)
        try container.encode(isCalibrated, forKey: .isCalibrated)
    }
}
