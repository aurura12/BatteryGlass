import SwiftUI

/// 日期导航：`◀  今天  ▶`，点中间日期弹出最近日期的菜单。
/// 菜单面板历史页与放大窗口共用，避免两处各写一套箭头/菜单。
struct HistoryDayNavigator: View {
    let selection: HistoryDaySelection
    /// 菜单里最多渲染的最近日期数；更早的日期用左右箭头逐天回看。
    var menuLimit: Int = 120
    var labelFont: Font = .system(size: 12, weight: .medium)
    /// 选择日期（含点击箭头）。
    let onSelect: (Date) -> Void

    var body: some View {
        HStack(spacing: 2) {
            stepButton(
                systemName: "chevron.left",
                help: "前一天",
                isEnabled: selection.canGoOlder
            ) {
                if let day = selection.olderDay { onSelect(day) }
            }

            Menu {
                ForEach(selection.recentMenuDays(limit: menuLimit).reversed(), id: \.self) { day in
                    Button(selection.label(for: day)) { onSelect(day) }
                }
                if selection.days.count > menuLimit {
                    Divider()
                    Text("更早的日期可用左侧箭头逐天回看")
                }
            } label: {
                Text(selection.label)
                    .font(labelFont)
                    .monospacedDigit()
                    .frame(minWidth: 56)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("选择日期")

            stepButton(
                systemName: "chevron.right",
                help: "后一天",
                isEnabled: selection.canGoNewer
            ) {
                if let day = selection.newerDay { onSelect(day) }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.cornerRadiusSmall)
                .fill(.quaternary)
        )
    }

    private func stepButton(
        systemName: String,
        help: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? .secondary : .tertiary)
        .disabled(!isEnabled)
        .help(help)
        .accessibilityLabel(help)
    }
}
