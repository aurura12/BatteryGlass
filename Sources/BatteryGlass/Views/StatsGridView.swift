import SwiftUI

struct MetricsGrid: View {
    let snapshot: BatterySnapshot

    private let columns = [
        GridItem(.flexible(), spacing: DesignTokens.spacingM),
        GridItem(.flexible(), spacing: DesignTokens.spacingM)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: DesignTokens.spacingM) {
            MetricCell(
                icon: "thermometer.medium",
                title: "温度",
                value: BatteryFormatters.temperature(snapshot.temperatureCelsius)
            )
            MetricCell(
                icon: "bolt",
                title: "电压",
                value: BatteryFormatters.voltage(snapshot.voltage)
            )
            MetricCell(
                icon: "cpu",
                title: "系统功耗",
                value: systemPowerText
            )
            MetricCell(
                icon: snapshot.adapterConnected ? "cable.connector" : "cable.connector.slash",
                title: "电源适配器",
                value: adapterText
            )
        }
    }

    private var systemPowerText: String {
        guard let systemPower = snapshot.systemPowerW, systemPower > 0 else { return "--" }
        return String(format: "%.1f W", systemPower)
    }

    private var adapterText: String {
        guard snapshot.adapterConnected else { return "未连接" }
        if let watts = snapshot.adapterWatts {
            return String(format: "%.0f W · %@", watts, snapshot.adapterName ?? "适配器")
        }
        return snapshot.adapterName ?? "已连接"
    }
}

struct MetricCell: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, DesignTokens.spacingS)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: DesignTokens.cornerRadiusSmall)
    }
}
