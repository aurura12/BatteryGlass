# CODEBUDDY.md

This file provides guidance to CodeBuddy Code when working with code in this repository.

## 项目概览

BatteryGlass 是纯 SwiftPM 的 macOS 菜单栏电池监测应用（SwiftUI + AppKit + IOKit），无第三方依赖，最低部署 macOS 14（开发基准 macOS 27）。应用是菜单栏常驻 accessory 应用（`LSUIElement`，无 Dock 图标），界面与注释均为简体中文。

## 常用命令

```bash
swift build                                      # 构建可执行目标 BatteryGlass
swift test                                       # 运行全部测试
swift test --filter BatteryMonitorIOPSParsingTests/testACPowerStateMarksExternalConnected   # 运行单个测试
swift test --filter BatteryMonitorIOPSParsingTests                                          # 运行某个测试类
./script/build_and_run.sh                        # 构建 → 生成 dist/BatteryGlass.app → 安装到 /Applications → 启动
./script/build_and_run.sh --verify               # 启动并确认进程存在（CI/验证用）
./script/build_and_run.sh --logs                 # 启动并跟随进程日志
./script/build_and_run.sh --telemetry            # 启动并跟随 subsystem 日志
./script/build_and_run.sh --debug                # 用 lldb 运行二进制（不启动安装后的 .app）
swift scripts/generate_icon.swift                # 重新生成 AppIcon.icns
./script/install_app_test.sh                     # App bundle 安装替换测试（纯脚本，不构建）
./script/menu_bar_only_test.sh                   # 断言应用保持“纯菜单栏”（不得出现主窗口入口/通知路径）
```

`script/install_app.sh` 只被 `build_and_run.sh` source（提供 `install_app` 函数），通常不单独运行。

仓库**没有** SwiftLint / SwiftFormat / Makefile / pre-commit 等 lint 或格式化配置：质量闸门只有 `swift build` 与 `swift test`。`Package.swift` 为 `swift-tools-version: 5.10`（本机开发基准为 Swift 6.4 / macOS 27 SDK，见 README）。

测试目标依赖可执行目标，`swift test` 会同时编译 app 二进制。访问 `@MainActor` 类型（如 `BatteryMonitor`）的测试类需标注 `@MainActor`。

应用带单实例保护（`AppInstanceGuard.enforceSingleInstance`，在 `BatteryGlassApp.init` 构造核心对象**之前**调用）：新实例会先终止同 bundle 的旧实例并等其 flush 落盘再接管，无法接管则 `exit(0)`；检查必须早于对象构造，否则旧实例未退出时新实例已启动定时器并写盘，会造成双进程并发写 history.json / power-diagnostics.jsonl。

## 项目结构

```
Sources/BatteryGlass/
├── App/          BatteryGlassApp.swift —— @main BatteryGlassApp、AppDelegate、AppInstanceGuard
├── Models/       纯值类型与纯函数：BatterySnapshot（含 PowerState）、PowerSample、
│                 HistorySample（含 DailySummary / DailyEnergyQuality）、SleepSegment、SleepInterval、
│                 PowerDiagnosticsSample、EnergyCalculator、SleepEnergyCalculator、TimeRemainingEstimator、
│                 ChargeRateTracker、TimeRemainingSmoother、PowerTelemetryEnergy、
│                 PowerTelemetryCalibration、BatteryDischargeConfirmation
├── Services/     有状态服务：BatteryMonitor（IOKit 采样）、DesktopWidgetController、
│                 LoginItemService、NotificationService、PowerDiagnosticsLogger
├── Stores/       持久化：AppSettings、BatteryHistoryStore、BoundedFileReader（+HistoryLoadLimits）、
│                 DailyEnergySummaryPolicy、HistorySampleRecovery（+PowerDiagnosticsHistoryLoader）
├── Support/      无状态工具：Formatters（BatteryFormatters）、BatteryStyling、DesignTokens、
│                 View+Glass（glassSurface / panelGlassSurface / GlassContainerIfAvailable）、
│                 PageTransition、Extensions（通知名与 Double 扩展）、EnergyAggregator、HistoryExporter
└── Views/        SwiftUI 界面：DashboardView（含 PanelTab）、LiveDashboardView、HistoryView、
                  SettingsView、DesktopWidgetView、MenuBarLabel、AnimatedSegmentedControl、
                  FluidGlassBackground、StatsGridView（MetricsGrid）
```

顶层目录：`script/`（构建/安装/回归 shell 脚本）、`scripts/generate_icon.swift`（图标生成）、`Resources/`（AppIcon）、`design-system/batteryglass/MASTER.md`（UI 规范基准）、`docs/superpowers/{specs,plans}/`（能耗设计动机与实施计划）、`dist/`（构建产物）。根目录另有 `README.md`、`CHANGELOG.md`、`HISTORY_PICKER_FLICKER.md`。

## 架构

### App 层（入口 / 场景 / 单实例）

`App/BatteryGlassApp.swift` 内含三个类型，改动启动顺序前先读其文件头注释：

- `AppInstanceGuard`（:12）与 `AppDelegate`（:42）与 `@main BatteryGlassApp`（:49）。
- `BatteryGlassApp.init` 的固定顺序：**单实例接管 → `AppSettings` → 用系统登录项回写 `launchAtLoginEnabled` → `BatteryMonitor` → `BatteryHistoryStore` → `DesktopWidgetController`**。前三步顺序不可换（见上文单实例说明）。
- 两个 Scene：`MenuBarExtra`（`.menuBarExtraStyle(.window)`）→ `DashboardView`（注入 `monitor`/`history`/`settings`）；`Settings` → `SettingsView`（注入 `history`/`settings`）。`MenuBarLabel` 只注入 `monitor`/`settings`。
- `AppDelegate` 只做一件事：`applicationDidFinishLaunching` 里 `NSApp.setActivationPolicy(.accessory)`（不占 Dock）。

### 对象图与依赖注入

所有核心对象在 `BatteryGlassApp.init` 中创建，通过 `.environment()` 注入视图，不依赖任何 DI 框架：

```
AppSettings ─┬─→ BatteryMonitor ─→ DesktopWidgetController
             └─→ BatteryHistoryStore
```

核心对象之外：`NotificationService` 是单例（低电量/插拔本地通知，由 `BatteryMonitor` 在阈值/状态跃迁时触发）；`LoginItemService` 封装 `SMAppService.mainApp` 的登录项状态查询与注册/注销，App 启动时用系统登录项实际状态回写 `AppSettings.launchAtLoginEnabled`（BatteryGlassApp.swift:68-69，在 `AppInstanceGuard` 接管之后）。注意 `SMAppService.mainApp.status` 在首次注册前可能返回 `.notFound`，该状态独立保留（不等于 `.notRegistered`）：允许用户发起注册，但 `systemLaunchAtLoginEnabled()` 返回 nil，**不得**据此禁用开关或用 false 覆盖已保存值。纯决策函数 `desiredAction(current:desiredEnabled:)` 对应测试 `LoginItemServiceTests`。

全部核心类型都是 `@MainActor @Observable`（Swift Observation 框架），视图用 `@Environment(Type.self)` 读取。

### 数据流

1. `BatteryMonitor.refresh()` 每 0.5 秒（2 Hz，`Timer` 挂在 RunLoop `.common` 模式）从两个 IOKit 源读取并合并：
   - `readSmartBattery()`：`AppleSmartBattery` 注册表（容量/循环/温度/电气参数/AdapterDetails/PowerTelemetryData）
   - `readPowerSources()`：`IOPowerSources` IOPS 描述（容量/状态/剩余时间/适配器）
2. 合并后的 `BatterySnapshot` 通过通知发布（`userInfo["snapshot"]`）。全部通知名集中定义于 `Support/Extensions.swift`：`batterySnapshotUpdated`、`sleepSegmentRecorded`、`sleepIntervalStarted`、`sleepIntervalEnded`、`desktopWidgetVisibilityChanged`、`resetDesktopWidgetPosition`、`desktopWidgetStyleChanged`。
3. `BatteryHistoryStore` 观察 `batterySnapshotUpdated`、`sleepSegmentRecorded` 及 `sleepIntervalStarted/Ended`（睡眠边界）做记录；`DesktopWidgetController` 观察 widget 显隐/重置/风格通知。
4. 待机（睡眠）补测：`BatteryMonitor` 监听 `NSWorkspace.willSleep/didWake`（见 `Services/BatteryMonitor.swift`「待机（睡眠）监听」段）。睡眠前记录基线并发 `sleepIntervalStarted`，唤醒后发 `sleepIntervalEnded` 建立边界，随后约 30 秒内每 5 秒采样一次系统直供功率取最小值，再按睡眠前供电状态归属成 `SleepSegment`，发 `sleepSegmentRecorded` 通知供能耗计量使用。

### 电源状态判定与时间估算

- 电源状态 `PowerState`（`charging` / `discharging` / `pluggedIn` / `unknown`）由 `resolvedPowerState` 纯函数决定。插电后电池电流可能短暂仍为负，只有 `BatteryDischargeConfirmation`（`Models/BatteryDischargeConfirmation.swift`，连续 ≥2 个样本 `batteryPowerW < -0.01 W`）才把“插电且电池放电”确认为混合来源，供能耗计量。测试 `BatteryMonitorStateTests`、`EnergyConsumptionTests`。
- 「充满还需 / 剩余时间」链路（`BatteryMonitor.refresh()` 组装 `TimeRemainingEstimator.Input` 后逐级处理）：
  - `TimeRemainingEstimator.estimateSeconds(_:)`（`Models/TimeRemainingEstimator.swift`）：按状态收敛分支，结果域校验 [60s, 48h]，越界返回 nil。输入刻意只吃 SmartBattery 真 mAh，**不读**被归一化污染的 `currentCapacityMAh/maxCapacityMAh`。
  - `ChargeRateTracker`：充电剩余时间的短窗实测速率（10 分钟滑窗、首尾斜率，拦截 1% 步进噪声与唤醒补跳）。
  - `TimeRemainingSmoother`：EMA 平滑、状态切换复位，消除 2 Hz 刷新跳变。
  - 对应测试 `TimeRemainingEstimatorTests`、`ChargeRateTrackerTests`、`TimeRemainingSmootherTests`。

### 能耗计量（睡眠补测 / 日能耗口径）

能耗口径是"来源侧能量"（电池放电取放电能量、外接电源取适配器输入），睡眠期间用系统累计遥测补测。相关逻辑分布在多个纯函数类型中，新增/修改决策前先读对应测试：

- `EnergyCalculator.dailyEnergyKWh(samples:)`：由相邻样本的 `consumptionPowerW` 梯形插值求区间能量，跨天边界切分，样本间隙 >60 s 视为断点。`BatteryHistoryStore` 用它做增量记入与全量重算（诊断回填后也会重算覆盖当天 summary）。测试 `EnergyConsumptionTests.swift`。
- `SleepEnergyCalculator.segment(from:)`：睡眠段能量归属，`minimumDuration = 60s`（更短的睡眠不生成区间、也不参与插值）。待机模式以**睡眠前供电状态**为准（睡眠中无法插拔）；插电待机优先用 `AccumulatedWallEnergyEstimate` 计数器差值，电池供电用睡眠前后电量差 × 平均电压，不可用时回退到唤醒后维持功耗估算。边界两侧供电状态变化（`SleepBoundaryPowerChange`，`batteryToAdapter`/`adapterToBattery`）走对称的 `sourceChanged` 分支，只计可观测来源并置 `SleepSegment.hasUnobservedSource = true`（该段能量为下界，见 `Models/SleepSegment.swift`）。测试 `SleepEnergyCalculatorTests.swift`。
- `PowerTelemetryEnergy.wallEnergyKWh(before:after:duration:)`：计数器差值 → kWh（单位假设 µWh，须按机型用插座电表校准），带合理性校验（平均功率 ≤500 W）。测试 `PowerTelemetryEnergyTests.swift`。
- `PowerTelemetryCalibrationStore`（`Models/PowerTelemetryCalibration.swift`）：按机型 + macOS 版本持久化校准系数到 `~/Library/Application Support/BatteryGlass/power-calibration.json`；无有效实测记录时系数为 1.0 且睡眠段 `isCalibrated = false`。测试 `PowerTelemetryCalibrationTests.swift`。
- `DailySummary`（`Models/HistorySample.swift`）是日能耗聚合载体，含 `energyQuality: DailyEnergyQuality?` 品质标记（旧汇总为 nil）；`DailyEnergySummaryPolicy` 处理 reconcile 与稀疏日清除；`EnergyAggregator`（`Support/EnergyAggregator.swift`）把每日能耗再按日/周/月聚合供图表分组。测试 `DailyEnergySummaryPolicyTests.swift`、`EnergyAggregatorTests.swift`。

### 可测试性设计（重要）

- `BatterySnapshot` 是纯值类型，功率语义全部是只读计算属性（`power`、`chargingPowerW`、`directSupplyPowerW`、`adapterOutputPowerW`、`consumptionPowerW`、`displayPower`）。这些语义是多个测试的核心断言对象，修改前必须先看 `Tests/BatteryGlassTests/EnergyConsumptionTests.swift`。
- `BatteryMonitor` 的解析逻辑提取为 `static` 纯函数以支持单元测试：`parsePowerSourceDescription(_:initial:)`、`applyAdapterDetails(_:to:)`、`resolvedPowerState`、`resolvedCapacityMAh`、`resolvedDesignCapacityMAh`、`resolvedFullChargeCapacityMAh`、`resolvedCurrentCapacityMAh`、`resolvedSystemPowerW`、`dischargingSystemPowerW`、`minimumMaintenancePowers`、`parsePowerTelemetryCounters`，以及 `IOPSPowerSourceState` 枚举。测试直接构造 `[String: Any]` 字典调用它们，不 mock IOKit（对应测试类：`BatteryMonitorIOPSParsingTests`、`BatteryMonitorSmartBatteryTests`、`BatteryMonitorStateTests`、`EnergyConsumptionTests`）。新增可验证的决策逻辑时沿用此模式（纯函数提取 + 先写失败测试）。
- 容量语义：Apple Silicon 上 IOPS 的 Current/Max Capacity 是 0-100 归一化值而非 mAh，快照容量字段经 `resolvedCapacityMAh`（SmartBattery 真 mAh 优先、IOPS 仅量级 >500 时兜底）过滤后恒为真 mAh。
- 单位约定：电压 mV→V、电流 mA→A（IOPS 与 SmartBattery 两条路径必须一致）；`PowerTelemetryData` 功率为带符号 64 位整数 mW，须经 `signedMW` 按位转换。
- 测试类地图（`Tests/BatteryGlassTests/`）：解析/状态 `BatteryMonitorIOPSParsingTests`、`BatteryMonitorSmartBatteryTests`、`BatteryMonitorStateTests`；能耗 `EnergyConsumptionTests`、`SleepEnergyCalculatorTests`、`PowerTelemetryEnergyTests`、`PowerTelemetryCalibrationTests`、`EnergyAggregatorTests`、`DailyEnergySummaryPolicyTests`；时间估算 `TimeRemainingEstimatorTests`、`ChargeRateTrackerTests`、`TimeRemainingSmootherTests`；持久化 `HistoryPersistenceTests`、`HistoryRecoveryTests`、`HistoryRetentionTests`、`HistoryExporterTests`；图表 `PowerChartDataTests`、`PowerChartSegmentationTests`、`PowerChartInteractionTests`、`BatteryLevelChartDataTests`（后者覆盖 `HistoryView.swift` 内的 `BatteryLevelChartData` / `BatteryLevelChartDataCache`）；其余 `AppSettingsTests`、`LoginItemServiceTests`、`MenuBarLabelTests`、`BatteryFormattersTests`、`PowerDiagnosticsTests`。

### Stores / 持久化

- `AppSettings`：UserDefaults 持久化，key 见文件内 static 常量。涵盖低电量通知开关与阈值（读取时钳制 10–50）、外接电源变化通知、菜单栏显示模式（`MenuBarDisplayMode`：无 / 百分比 / 剩余时间）、桌面小组件开关 / 尺寸（`DesktopWidgetStyle`）/ 位置、记录历史、电源诊断日志、开机自启动、动效浓度与速度。注意 `DashboardView` 的分页记忆另用 `@AppStorage("BatteryGlass.panelTab")`，**不在** `AppSettings` 内。
- `BatteryHistoryStore`：`~/Library/Application Support/BatteryGlass/history.json`。payload 版本化（当前 v5：samples + dailySummaries + sleepSegments + sleepIntervals），每 15 秒异步写盘（串行 `persistenceQueue`），退出时 `flush()` 同步写盘（`willTerminateNotification`）。样本 ≥5 秒记一条，cycleCount/health 显著变化立即记。加载时按 `payload.version` 逐级迁移（v2 起含 dailySummaries，v3 起含 sleepSegments，v4 起含 sleepIntervals，v5 起 `SleepSegment` 增 `hasUnobservedSource`/`boundaryPowerChange`、`DailySummary` 增 `energyQuality`；新增字段均带默认值、经 `decodeIfPresent` 解码，旧文件无需新增迁移分支），并含"用 power-diagnostics.jsonl 回填 `consumptionPowerW`"的恢复逻辑（实现于 `Stores/HistorySampleRecovery.swift` 的 `backfillConsumptionPower`，同样经 `BoundedFileReader` / `HistoryLoadLimits` 限幅）。
- `PowerDiagnosticsLogger`（单例）：JSONL 追加写 `power-diagnostics.jsonl`，5 MB 自动轮换为 `.1.jsonl`。
- `BoundedFileReader` / `HistoryLoadLimits`：所有本地文件读取必须走这里（历史上限 20 MB/10 万样本，诊断 50 MB/10 万样本），防止异常本地文件拖慢启动。
- `HistoryExporter`（`Support/HistoryExporter.swift`）：把历史样本与每日汇总序列化为 CSV、JSON（JSON 另含睡眠区间），设置页导出按钮调用，纯函数。
- 持久化模式是"主线程同步记录 → 后台串行队列写文件"，新增类似逻辑时保持一致。

### Views / UI

- `DashboardView` 是 `MenuBarExtra` window 的面板根视图；`PanelTab` 分段控件切换 `LiveDashboardView` / `HistoryView`（HistoryView 用 Swift Charts）。实时页用 `ViewThatFits(in: .vertical)`：标准字号直接展示完整面板，字号被系统放大导致空间不足时自动回退到 `ScrollView`。
- 菜单栏图标：`MenuBarLabel` 经 `MenuBarIconRenderer` 把多层 SwiftUI 合成为**单张模板 `NSImage`**（`MenuBarExtra` 会丢弃多层子视图），着色交给系统模板；图标旁文字由 `AppSettings.menuBarDisplayMode` 控制。`MenuBarAccessibility`、`MenuBarBatteryFill`、`MenuBarPowerIndicator` 均为纯函数，测试 `MenuBarLabelTests`。
- `Views/HistoryView.swift` 是仓库最大的单文件（约 1,690 行，占源码约 1/4），内联了三个纯函数缓存与两个纯数据类型：`TodaySamplesCache`(:66)、`PowerChartDataCache`(:86)、`BatteryLevelChartDataCache`(:114)，以及 `PowerChartData`(:1175)、`BatteryLevelChartData`(:1351)。改图表相关逻辑优先看这里；数据/缓存部分有独立测试（`PowerChartDataTests`、`PowerChartSegmentationTests`、`PowerChartInteractionTests`、`BatteryLevelChartDataTests`），改动时不要破坏其纯函数边界。
- 动效集中在 `Views/FluidGlassBackground.swift`（流体光斑）、`Views/AnimatedSegmentedControl.swift`（胶囊滑动）与 `Support/PageTransition.swift`（页面切换过渡）；设计令牌（8pt 间距栅格、交通灯状态色、数据蓝）见 `Support/DesignTokens.swift`，配色见 `Support/BatteryStyling.swift`。动效参数调节说明见 README「流体玻璃动画参数调节」。
- 桌面小组件是应用内 NSWindow（`DesktopWidgetController`），非 WidgetKit。
- 历史页顶部原生 `Picker`（「分组」菜单 / 「统计范围」分段）在 macOS 26 上曾观察到边框周期性闪烁，复现步骤与排查结论（暂无法复现、未改业务代码）见根目录 `HISTORY_PICKER_FLICKER.md`。
- UI 规范以 `design-system/batteryglass/MASTER.md` 为基准。
- 能耗口径的设计动机与边界见 `docs/superpowers/specs/`（尤其 `2026-09-06-precision-energy-accounting-design.md` 定义"从电源侧消耗了多少电"这一指标口径），配套实施计划在 `docs/superpowers/plans/`。修改能耗相关决策前先读这两处。

## 约定

- **每次修改代码/文件后，必须在根目录 `CHANGELOG.md` 顶部（时间倒序）追加记录**，格式参照 Keep a Changelog，分类：新增/修改/修复/重构。未记录变更不算任务完成。
- 不引入第三方依赖；保持 macOS 14 最低部署版本；不引入沙盒/公证（本地构建为 ad-hoc 签名）。
- 完成修改后运行完整 `swift test` 并检查 `git diff`，确认无无关变更。
