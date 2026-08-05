import SwiftUI

struct GlassContainerIfAvailable<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer {
                content
            }
        } else {
            content
        }
    }
}

extension View {
    @ViewBuilder
    func glassSurface(
        cornerRadius: CGFloat = DesignTokens.cornerRadiusCard
    ) -> some View {
        if #available(macOS 26.0, *) {
            // 使用 clear 玻璃：保留折射与光泽质感，同时底边线比 regular 淡。
            self.glassEffect(
                Glass.clear,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            self.background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
            )
        }
    }

    @ViewBuilder
    func panelGlassSurface(cornerRadius: CGFloat = 26) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self.background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
            }
        }
    }
}
