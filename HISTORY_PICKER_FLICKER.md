# 历史页顶部控件闪烁现象记录

## 当前状态

- 记录日期：2026-09-15
- 当前状态：暂时无法复现，尚未修改业务代码。
- 影响范围：历史页顶部的“每日耗电量”卡片，重点是“按日”菜单和“统计范围”分段控件。
- 蓝色矩形是截图标注，不是应用代码绘制的边框。

## 视频中观察到的现象

视频：`/Users/mac/Library/Containers/com.sw33tlie.macshot.macshot/Data/tmp/809352BD-87DC-4FC3-B820-2A0D2029C5ED.mp4`

- 视频时长约 5.4 秒，画面约 730 × 718。
- “按日”控件周围以及“近 14 天”分段控件底部出现细黑线/边界。
- 这些线条会出现、消失或改变覆盖范围，变化节奏大约接近 1 秒一次，表现为明显闪烁。
- 选中的蓝色分段、柱状图和统计数据大部分时间保持不变，因此不像是选择值或数据本身在来回切换。
- 闪烁集中在原生控件的边框/焦点装饰层，不是整张卡片内容完全消失。

## 相关代码链路

1. [BatteryMonitor.swift](Sources/BatteryGlass/Services/BatteryMonitor.swift) 中的定时器每 0.5 秒执行一次 `refresh()`，并且每次都给 `snapshot` 赋新值。
2. [DashboardView.swift](Sources/BatteryGlass/Views/DashboardView.swift) 的根视图读取 `monitor.snapshot`，所以面板观察树会随监控刷新频繁失效重算。
3. [HistoryView.swift](Sources/BatteryGlass/Views/HistoryView.swift) 中的每日汇总会经过 `energyRange.summaries(from:)` 和 `EnergyAggregator.aggregate(...)` 重新生成；目前缓存只覆盖今日样本和功率曲线数据，没有覆盖每日汇总聚合。
4. 每日耗电量卡片使用原生 SwiftUI 控件：
   - `Picker("分组")` + `.pickerStyle(.menu)`
   - `Picker("统计范围")` + `.pickerStyle(.segmented)`
5. 历史卡片使用 `.glassSurface`；在 macOS 26 上会走 `glassEffect(Glass.clear)`，整个面板外层还包在 `GlassEffectContainer` 中。
6. 图表上的 `.onContinuousHover` 会更新 `hoveredAggregate`，鼠标位于图表区域时也可能触发局部视图重绘。

## 可能原因（按当前可信度排序）

### 1. macOS 26 原生 Picker 的焦点/边框渲染异常（最可能）

视频变化的正是两个原生 `Picker` 的细边界；项目没有给这些线条添加 `.stroke`、定时器或循环闪烁动画。结合当前系统为 macOS 26.5.2，更像是原生 `menu` / `segmented` 控件的焦点装饰层在重绘时出现了不完整或闪烁。

### 2. 高频观察失效放大了原生控件重绘问题

0.5 秒一次的快照更新会让面板父视图不断重算。即使历史数据没有变化，顶部卡片仍可能收到新的视图更新，导致原生 Picker 的焦点/边框层反复重合成。

### 3. Liquid Glass 合成使闪烁更明显

流体背景本身以约 60 FPS 动画，卡片又使用 `Glass.clear`。这可能放大控件边缘的亮度变化或重合成伪影，但不能单独解释视频中原生控件底部黑线的周期性变化，因此更像放大因素而非唯一根因。

### 4. 图表 hover 状态造成额外重绘

视频中鼠标曾进入图表区域；`.onContinuousHover` 会更新悬停状态，可能与父视图刷新叠加。但它只能解释部分触发条件，不能证明是唯一原因。

## 暂时排除的方向

- 没有发现每日耗电量卡片中存在显式的循环动画或闪烁定时器。
- `DashboardView` 的页面切换动画只绑定 `tab`，不会在停留历史页时持续执行。
- 统计范围的选中值没有在视频中来回切换。
- 蓝色标注框不是应用边框。

## 后续复现/修复时的验证顺序

不改代码即可先做：

1. 鼠标移出图表和两个控件，观察闪烁是否停止。
2. 打开 macOS“减弱动态效果”，或暂时降低 BatteryGlass 的流动速度/玻璃浓度。
3. 切换到实时页再切回历史页，观察是否只在首次出现或特定焦点状态下复现。
4. 仅将两个 Picker 的样式临时改为 `.automatic` 做 A/B 验证；如果消失，基本可确认是原生 Picker 样式路径。

如果问题再次出现，最稳妥的代码修复方向是用自定义 SwiftUI `Button` 分段控件和自定义菜单替代这两个原生 Picker；其次再考虑隔离历史页与 2 Hz 监控更新、减少玻璃合成范围。
