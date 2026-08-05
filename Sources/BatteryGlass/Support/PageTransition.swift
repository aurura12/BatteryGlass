import SwiftUI

struct PageTransitionModifier: ViewModifier {
    var offsetX: CGFloat
    var opacity: Double
    var scale: CGFloat
    var blur: CGFloat

    func body(content: Content) -> some View {
        content
            .offset(x: offsetX)
            .opacity(opacity)
            .scaleEffect(scale)
            .blur(radius: blur)
    }
}

extension AnyTransition {
    /// 复合页面切换：滑动 + 缩放 + 模糊 + 淡入淡出。
    static func pageSwitch(insertionEdge: Edge, removalEdge: Edge) -> AnyTransition {
        let insertionOffset: CGFloat = insertionEdge == .trailing ? 70 : -70
        let removalOffset: CGFloat = removalEdge == .trailing ? 70 : -70
        return .asymmetric(
            insertion: .modifier(
                active: PageTransitionModifier(
                    offsetX: insertionOffset,
                    opacity: 0,
                    scale: 0.96,
                    blur: 6
                ),
                identity: PageTransitionModifier(
                    offsetX: 0,
                    opacity: 1,
                    scale: 1,
                    blur: 0
                )
            ),
            removal: .modifier(
                active: PageTransitionModifier(
                    offsetX: removalOffset,
                    opacity: 0,
                    scale: 0.96,
                    blur: 6
                ),
                identity: PageTransitionModifier(
                    offsetX: 0,
                    opacity: 1,
                    scale: 1,
                    blur: 0
                )
            )
        )
    }
}
