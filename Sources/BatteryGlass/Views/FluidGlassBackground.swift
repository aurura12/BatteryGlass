import SwiftUI

struct FluidGlassBackground: View {
    var state: PowerState
    var colors: [Color]
    var intensity: Double
    var speed: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                fluid(phase: 0, intensity: intensity)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
                    let phase = context.date.timeIntervalSinceReferenceDate * speed
                    fluid(phase: phase, intensity: intensity)
                }
            }
        }
        .allowsHitTesting(false)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cornerRadiusPanel, style: .continuous))
    }

    @ViewBuilder
    private func fluid(phase: Double, intensity: Double) -> some View {
        ZStack {
            // 克制的流体光晕：两个柔和径向光斑，避免高饱和色带
            RadialGradient(
                colors: [(colors.first ?? DesignTokens.dataBlue).opacity(0.30), .clear],
                center: UnitPoint(x: 0.82, y: 0.10),
                startRadius: 0,
                endRadius: 320
            )
            .offset(
                x: CGFloat(sin(phase * 0.30) * 26),
                y: CGFloat(cos(phase * 0.22) * 20)
            )

            RadialGradient(
                colors: [DesignTokens.dataBlue.opacity(0.20), .clear],
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
