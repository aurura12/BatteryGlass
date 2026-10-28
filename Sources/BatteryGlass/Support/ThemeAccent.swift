import AppKit
import SwiftUI

/// 可自定义的主题强调色。
///
/// 只描述颜色本身（sRGB 分量）与其序列化形式，不依赖 `AppSettings`，
/// 便于用纯值做单测。持久化时保存 `hexString`，读取失败回退到 `.fallback`。
struct ThemeAccent: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }

    /// 默认主题色与旧版本的「数据蓝 #127AF5」一致：未设置时外观不变。
    static let defaultHex = "#127AF5"
    static let fallback = ThemeAccent(
        red: 0x12 / 255.0,
        green: 0x7A / 255.0,
        blue: 0xF5 / 255.0
    )

    /// 解析 `#RRGGBB` / `RRGGBB`（也接受 8 位 `#RRGGBBAA`，忽略 alpha）。
    init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6 || value.count == 8,
              value.allSatisfy(\.isHexDigit),
              let raw = UInt32(value.prefix(6), radix: 16)
        else { return nil }

        self.init(
            red: Double((raw >> 16) & 0xFF) / 255,
            green: Double((raw >> 8) & 0xFF) / 255,
            blue: Double(raw & 0xFF) / 255
        )
    }

    /// 从取色器返回的 `Color` 转换；无法转成 sRGB 时回退到默认主题色。
    init(color: Color) {
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else {
            self = .fallback
            return
        }
        self.init(
            red: srgb.redComponent,
            green: srgb.greenComponent,
            blue: srgb.blueComponent
        )
    }

    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }

    var hexString: String {
        String(
            format: "#%02X%02X%02X",
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded())
        )
    }
}

/// 设置页的预设主题色。预设只是常用色板，用户仍可用取色器自定义任意颜色。
enum ThemeAccentPreset: String, CaseIterable, Identifiable {
    case blue
    case indigo
    case teal
    case orange
    case pink
    case graphite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blue: return "经典蓝"
        case .indigo: return "靛紫"
        case .teal: return "青绿"
        case .orange: return "暖橙"
        case .pink: return "玫红"
        case .graphite: return "石墨"
        }
    }

    var hex: String {
        switch self {
        case .blue: return ThemeAccent.defaultHex
        case .indigo: return "#6C5BF2"
        case .teal: return "#12A594"
        case .orange: return "#E07A12"
        case .pink: return "#D94F8A"
        case .graphite: return "#5E6B78"
        }
    }

    var accent: ThemeAccent {
        ThemeAccent(hex: hex) ?? .fallback
    }
}

private struct ThemeAccentEnvironmentKey: EnvironmentKey {
    static let defaultValue = ThemeAccent.fallback.color
}

extension EnvironmentValues {
    /// 当前主题强调色。由各界面入口从 `AppSettings.themeAccentHex` 注入，
    /// 视图改动即时传播（`AppSettings` 是 `@Observable`）。
    var themeAccent: Color {
        get { self[ThemeAccentEnvironmentKey.self] }
        set { self[ThemeAccentEnvironmentKey.self] = newValue }
    }
}
