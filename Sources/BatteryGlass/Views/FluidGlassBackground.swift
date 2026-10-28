import SwiftUI

/// 流体光晕的相位模型：相位 = 基准 + 自 `epoch` 起的时长 × 速度。
///
/// 相位只用于 `sin`/`cos`，视觉上关心的是连续性：速度变化时把旧速度已走过的
/// 角度并入 `base`，再从当前时刻重新计时，光斑就不会瞬移。
struct FluidGlassPhase: Equatable {
    var epoch: Date
    var base: Double

    init(epoch: Date = Date(), base: Double = 0) {
        self.epoch = epoch
        self.base = base
    }

    func phase(at date: Date, speed: Double) -> Double {
        base + date.timeIntervalSince(epoch) * speed
    }

    /// 以 `date` 为新起点、沿用旧速度累计出的相位作为新基准。
    func rebased(at date: Date, from oldSpeed: Double) -> FluidGlassPhase {
        FluidGlassPhase(epoch: date, base: phase(at: date, speed: oldSpeed))
    }
}

struct FluidGlassBackground: View {
    var colors: [Color]
    var intensity: Double
    var speed: Double
    var isAnimated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.themeAccent) private var themeAccent
    /// 相位基准：用「基准 + 时长 × 速度」累计，速度变化时重新归基准，
    /// 避免原先「绝对时间 × 速度」在拖动速度滑块时让光斑瞬间跳到别处。
    @State private var phaseState = FluidGlassPhase()

    var body: some View {
        Group {
            if reduceMotion || !isAnimated {
                fluid(phase: 0, intensity: intensity)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    fluid(
                        phase: phaseState.phase(at: context.date, speed: speed),
                        intensity: intensity
                    )
                }
            }
        }
        .allowsHitTesting(false)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cornerRadiusPanel, style: .continuous))
        .onChange(of: speed) { oldSpeed, _ in
            phaseState = phaseState.rebased(at: Date(), from: oldSpeed)
        }
    }

    @ViewBuilder
    private func fluid(phase: Double, intensity: Double) -> some View {
        ZStack {
            // 克制的流体光晕：两个柔和径向光斑，避免高饱和色带
            RadialGradient(
                colors: [(colors.first ?? themeAccent).opacity(0.30), .clear],
                center: UnitPoint(x: 0.82, y: 0.10),
                startRadius: 0,
                endRadius: 320
            )
            .offset(
                x: CGFloat(sin(phase * 0.30) * 26),
                y: CGFloat(cos(phase * 0.22) * 20)
            )

            RadialGradient(
                colors: [themeAccent.opacity(0.20), .clear],
                center: UnitPoint(x: 0.15, y: 0.92),
                startRadius: 0,
                endRadius: 340
            )
            .offset(
                x: CGFloat(sin(phase * 0.24) * 22),
                y: CGFloat(cos(phase * 0.33) * 16)
            )
        }
        .blur(radius: 56)
        .compositingGroup()
        .opacity(0.55 + 0.25 * intensity)
    }
}
