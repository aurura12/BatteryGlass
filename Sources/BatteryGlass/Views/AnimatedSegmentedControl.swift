import SwiftUI

/// 自定义动画分段控件：选中高亮胶囊弹性滑动，标题文字有选中态过渡。
struct AnimatedSegmentedControl<T: Hashable>: View {
    let items: [T]
    @Binding var selection: T
    let label: (T) -> String

    var body: some View {
        GeometryReader { proxy in
            let segmentWidth = proxy.size.width / CGFloat(max(items.count, 1))
            let selectedIndex = items.firstIndex(of: selection) ?? 0

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.06))

                Group {
                    if #available(macOS 26.0, *) {
                        // 液态玻璃高亮胶囊
                        Capsule()
                            .fill(Color.clear)
                            .glassEffect(Glass.clear, in: Capsule())
                    } else {
                        Capsule()
                            .fill(.regularMaterial)
                            .overlay(
                                Capsule()
                                    .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
                            )
                            .shadow(color: .black.opacity(0.10), radius: 3, y: 1)
                    }
                }
                .frame(width: segmentWidth)
                .offset(x: CGFloat(selectedIndex) * segmentWidth)
                .animation(.spring(response: 0.42, dampingFraction: 0.82), value: selection)

                HStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        Button {
                            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                                selection = item
                            }
                        } label: {
                            Text(label(item))
                                .font(.system(size: 11, weight: item == selection ? .semibold : .regular))
                                .foregroundStyle(item == selection ? Color.primary : Color.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(Rectangle())
                                .scaleEffect(item == selection ? 1.0 : 0.96)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(label(item))
                    }
                }
            }
        }
        .frame(height: 28)
        .clipShape(Capsule())
    }
}
