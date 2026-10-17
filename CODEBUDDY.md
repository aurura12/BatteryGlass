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

`script/install_app.sh` 只被 `build_and_run.sh` source（提供 `install_app` 函数），通常不单独运行。App bundle 的元数据（bundle id、`LSUIElement`、ad-hoc 签名）由 `script/build_and_run.sh` 内联生成 Info.plist（约 :83），没有独立的 plist 文件可改。

仓库**没有** SwiftLint / SwiftFormat / Makefile / pre-commit 等 lint 或格式化配置：质量闸门只有 `swift build` 与 `swift test`。`Package.swift` 为 `swift-tools-version: 5.10`（本机开发基准为 Swift 6.4 / macOS 27 SDK，见 README），`defaultLocalization` 为 `zh-Hans`，通过 `linkerSettings` 链接 `IOKit` 与 `ServiceManagement`——新增系统框架需改 manifest。

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
│                 PowerTelemetryCalibration、BatteryDischargeConfirmation、BatteryPowerThresholds、
│                 PowerDisplayTransition（插拔过渡期的实时展示状态）、
│                 ChartZoomWindow（图表横向视口）、ChartTimeAxis（随跨度变化的 X 轴刻度）、
│                 HistoryDaySelection（按天回看的日期导航状态）
├── Services/     有状态服务：BatteryMonitor（IOKit 采样）、DesktopWidgetController、
│                 LoginItemService、NotificationService、PowerDiagnosticsLogger、
│                 ChartWindowController（曲线放大窗口）
├── Stores/       持久化：AppSettings、BatteryHistoryStore、HistorySampleArchive（SQLite 曲线归档）、
│                 BoundedFileReader（+HistoryLoadLimits）、DailyEnergySummaryPolicy、
│                 HistorySampleRecovery（+PowerDiagnosticsHistoryLoader）
├── Support/      无状态工具：Formatters（BatteryFormatters）、BatteryStyling、DesignTokens、
│                 View+Glass（glassSurface / panelGlassSurface / GlassContainerIfAvailable）、
│                 PageTransition、Extensions（通知名与 Double 扩展）、EnergyAggregator、HistoryExporter、
│                 ChartViewport（可见域样本筛选与抽样）
└── Views/        SwiftUI 界面：DashboardView（含 PanelTab）、LiveDashboardView、HistoryView、
                  SettingsView、PowerCalibrationSection（电源校准会话）、DesktopWidgetView、
                  MenuBarLabel、AnimatedSegmentedControl、FluidGlassBackground、
                  StatsGridView（MetricsGrid）、ChartZoomInteraction（图表缩放/平移手势与标题栏按钮）、
                  PanelVisibilityObserver（面板窗口可见性，用于暂停动画）、
                  HistoryChartRendering（图表降采样）、ChartDetailView（放大窗口内容，
                  含 ExpandedChart / ChartDetailModel）
```

顶层目录：`script/`（构建/安装/回归 shell 脚本）、`scripts/generate_icon.swift`（图标生成）、`Resources/`（AppIcon）、`design-system/batteryglass/MASTER.md`（UI 规范基准）、`docs/superpowers/{specs,plans}/`（能耗设计动机与实施计划）、`.codex/environments/environment.toml`（Codex Run 按钮配置，指向 `build_and_run.sh`）、`dist/`（构建产物）。根目录另有 `README.md`、`CHANGELOG.md`、`HISTORY_PICKER_FLICKER.md`。

## 架构

### App 层（入口 / 场景 / 单实例）

`App/BatteryGlassApp.swift` 内含三个类型，改动启动顺序前先读其文件头注释：

- `AppInstanceGuard`（:12）与 `AppDelegate`（:42）与 `@main BatteryGlassApp`（:51）。
- `BatteryGlassApp.init` 的固定顺序：**单实例接管 → `AppSettings` → 用系统登录项回写 `launchAtLoginEnabled` → `PowerTelemetryCalibrationStore` → `BatteryMonitor` → `BatteryHistoryStore` → `DesktopWidgetController` → `ChartWindowController`**。前三步顺序不可换（见上文单实例说明）；校准 store 必须早于 `BatteryMonitor` 创建并注入同一实例，设置页改系数后监控立即生效。
- 两个 Scene：`MenuBarExtra`（`.menuBarExtraStyle(.window)`）→ `DashboardView`（注入 `monitor`/`history`/`settings`/`chartWindow`）；`Settings` → `SettingsView`（注入 `history`/`settings`/`calibrationStore`/`monitor`）。`MenuBarLabel` 只注入 `monitor`/`settings`。
- `AppDelegate` 在 `applicationDidFinishLaunching` 做两件事：`NSApp.setActivationPolicy(.accessory)`（不占 Dock）与 `NotificationService.installForegroundPresenter()`（应用在前台时也展示通知横幅，否则系统会静默丢弃）。

### 对象图与依赖注入

所有核心对象在 `BatteryGlassApp.init` 中创建，通过 `.environment()` 注入视图，不依赖任何 DI 框架：

```
AppSettings ─┬─→ BatteryMonitor ─→ DesktopWidgetController
             │        ↑ PowerTelemetryCalibrationStore（@Observable 共享引用，注入 monitor 与设置页）
             └─→ BatteryHistoryStore ─→ ChartWindowController（放大窗口）
```

核心对象之外：`NotificationService` 是单例（低电量/插拔本地通知，由 `BatteryMonitor` 在阈值/状态跃迁时触发）；`LoginItemService` 封装 `SMAppService.mainApp` 的登录项状态查询与注册/注销，App 启动时用系统登录项实际状态回写 `AppSettings.launchAtLoginEnabled`（BatteryGlassApp.swift:72-73，在 `AppInstanceGuard` 接管之后）。注意 `SMAppService.mainApp.status` 在首次注册前可能返回 `.notFound`，该状态独立保留（不等于 `.notRegistered`）：允许用户发起注册，但 `systemLaunchAtLoginEnabled()` 返回 nil，**不得**据此禁用开关或用 false 覆盖已保存值。纯决策函数 `desiredAction(current:desiredEnabled:)` 对应测试 `LoginItemServiceTests`；执行函数 `apply(desiredEnabled:)` 在 `.notFound` + 期望关闭时返回 `LoginItemApplyResult.cannotConfirm`（系统未报告状态、无从注销，语义上"未做任何操作"），设置页据此把开关回滚到原值并弹「无法确认开机自启动状态」提示，全程不调用系统 API。

全部核心类型都是 `@MainActor @Observable`（Swift Observation 框架），视图用 `@Environment(Type.self)` 读取。

### 数据流

1. `BatteryMonitor.refresh()` 按可见性分档从两个 IOKit 源读取并合并（面板可见 0.5 秒 / 2 Hz，其余 1 秒 / 1 Hz；`Timer` 挂 RunLoop `.common` 并设 `tolerance` 让系统合并唤醒）：
   - `readSmartBattery()`：`AppleSmartBattery` 注册表（容量/循环/温度/电气参数/AdapterDetails/PowerTelemetryData）
   - `readPowerSources()`：`IOPowerSources` IOPS 描述（容量/状态/剩余时间/适配器）
2. 合并后的 `BatterySnapshot` 通过通知发布（`userInfo["snapshot"]`）。全部通知名集中定义于 `Support/Extensions.swift`：`batterySnapshotUpdated`、`sleepSegmentRecorded`、`sleepIntervalStarted`、`sleepIntervalEnded`、`desktopWidgetVisibilityChanged`、`resetDesktopWidgetPosition`、`desktopWidgetStyleChanged`。
   - **采样 ≠ 界面刷新**：通知每拍都发（历史/诊断/状态判定一律走它），但 `@Observable` 的 `snapshot` / `recentPower` 只在 `shouldPublish(previous:next:mode:...)` 通过时才更新。三档 `UIPublishMode`：`.live`（面板可见，每拍发布）、`.widget`（仅桌面小组件可见，最多 1 秒一次）、`.background`（都不可见，只在菜单栏百分比/供电状态/剩余时间文本变化或 30 秒心跳时发布）。原因：`MenuBarExtra` 面板关闭后内容视图仍存活，每次 `snapshot` 变化都会让离屏面板完整重算视图图（实测占应用空闲 CPU 的 95%）。可见性由 `PanelVisibilityObserver`（面板）与 `DesktopWidgetController.setVisible`（小组件）上报。测试 `BatteryMonitorPublishPolicyTests`。
   - 内部最新快照为 `latest`（`@ObservationIgnored`），睡眠基线、维持功耗采样、`resolvedSystemPowerW` 的「上次值」都读它，因此降低发布频率不影响任何计量。
3. `BatteryHistoryStore` 观察 `batterySnapshotUpdated`、`sleepSegmentRecorded` 及 `sleepIntervalStarted/Ended`（睡眠边界）做记录；`DesktopWidgetController` 观察 widget 显隐/重置/风格通知。
4. 待机（睡眠）补测：`BatteryMonitor` 监听 `NSWorkspace.willSleep/didWake`（见 `Services/BatteryMonitor.swift`「待机（睡眠）监听」段）。睡眠前记录基线并发 `sleepIntervalStarted`，唤醒后发 `sleepIntervalEnded` 建立边界，随后约 30 秒内每 5 秒采样一次系统直供功率取最小值，再按睡眠前供电状态归属成 `SleepSegment`，发 `sleepSegmentRecorded` 通知供能耗计量使用。

### 电源状态判定与时间估算

- 电源状态 `PowerState`（`charging` / `discharging` / `pluggedIn` / `unknown`）由 `resolvedPowerState` 纯函数决定。插电后电池电流可能短暂仍为负，只有 `BatteryDischargeConfirmation`（`Models/BatteryDischargeConfirmation.swift`）才把“插电且电池放电”确认为混合来源，供能耗计量：**进入**需读数 < `-BatteryPowerThresholds.confirmedDischargeW`（0.1 W）并连续满足样本数（`.pluggedIn` 2 个、`.charging` 6 个——充电态的负读数可能是状态切换滞后），**维持**只要求仍 < `-minimumDischargeW`（0.01 W，与 `BatterySnapshot.batteryDischargePowerW` 同一阈值，避免读数在 0.01~0.1 W 抖动时面板在「电池放电 / 给电池 0.0 W」之间跳变），状态切换会重置连续计数。测试 `BatteryDischargeConfirmationTests`、`BatteryMonitorStateTests`、`EnergyConsumptionTests`。
- 插拔过渡展示：`Models/PowerDisplayTransition.swift` 是值类型纯状态机，在 `BatteryMonitor` 内跟踪适配器连接跃迁，产出 `BatterySnapshot.powerDisplayStatus`（`ready`/`updating`/`unavailable`）。连接信号可能先于电量计与功率遥测更新，过渡期实时页把功率/电源分配/系统功耗统一显示为「更新中」并暂时隐藏旧的剩余时间，出现与新供电方式一致的读数后自动退出，超过 90 秒仍无新测量则显示 `--`（`unavailable`）。**只控制实时展示，不改动原始功率与历史能耗取值**；面板、桌面小组件与菜单栏无障碍提示统一读取该状态。测试 `PowerDisplayTransitionTests`。
- 能耗计量口径 `BatterySnapshot.consumptionPowerW`：放电时优先电池放电读数（`batteryDischargePowerW`），读数不可用（电量计在拔插瞬间会冻结在 0 或残留充电值上数十秒）则回退 `systemPowerW`——放电状态下它由 SystemLoad 得来、恒为正，实测 3910/3910 为正且与 `|batteryPowerW|` 中位误差仅 1 mW、拔电前后数值一致，是无缝衔接的独立观测；未接入适配器但状态尚未切到放电（拔插瞬态）时也用 `batteryDischargePowerW` 兜底，不再返回 nil。三类读数**同时**符号翻转（`batteryPowerW` 与 telemetry 同为正而 `systemLoad` 为负）时保持 nil，交由采样缺口标记，**不用估计值填补**。`displayPower` 的放电分支有同样的回退（否则面板显示 0.0 W 而当日能耗仍在增长），但两个口径的取值链各自独立、互不改变定义（依据 `docs/superpowers/plans/2026-09-06-precision-energy-accounting.md`）。测试 `EnergyConsumptionTests`。
- 「充满还需 / 剩余时间」链路（`BatteryMonitor.refresh()` 组装 `TimeRemainingEstimator.Input` 后逐级处理）：
  - `TimeRemainingEstimator.estimateSeconds(_:)`（`Models/TimeRemainingEstimator.swift`）：按状态收敛分支，结果域校验 [60s, 48h]，越界返回 nil。输入刻意只吃 SmartBattery 真 mAh，**不读**被归一化污染的 `currentCapacityMAh/maxCapacityMAh`。
  - `ChargeRateTracker`：充电剩余时间的短窗实测速率（10 分钟滑窗、首尾斜率，拦截 1% 步进噪声与唤醒补跳）。
  - `TimeRemainingSmoother`：EMA 平滑、状态切换复位，消除 2 Hz 刷新跳变。
  - 对应测试 `TimeRemainingEstimatorTests`、`ChargeRateTrackerTests`、`TimeRemainingSmootherTests`。

### 能耗计量（睡眠补测 / 日能耗口径）

能耗口径是"来源侧能量"（电池放电取放电能量、外接电源取适配器输入），睡眠期间用系统累计遥测补测。相关逻辑分布在多个纯函数类型中，新增/修改决策前先读对应测试：

- `EnergyCalculator.dailyEnergyKWh(samples:)`：由相邻样本的 `consumptionPowerW` 梯形插值求区间能量，跨天边界切分，样本间隙 >60 s 视为断点。`BatteryHistoryStore` 用它做增量记入与全量重算（诊断回填后也会重算覆盖当天 summary）。测试 `EnergyConsumptionTests.swift`。
- `EnergyCalculator.unaccountedSecondsByDay(samples:)`：按日统计**未被积分覆盖的时长**并区分成因——`gapSeconds`（相邻样本间隔 > `maximumGap`：应用当时没在记录）与 `missingReadingSeconds`（间距正常但任一端缺有效 `consumptionPowerW`，实测集中在拔插电源前后约 1 分钟：`state` 已切到电池供电而电量计仍读 0），睡眠区间内不计，跨午夜按比例拆天。`DailyUnaccountedTime.needsWarning` = `gapSeconds > 0 || missingReadingSeconds >= missingReadingWarningSeconds`（600 秒）——前者是结构性空洞立即告警，后者一天通常只有 2~3 分钟（约 1.5 Wh、占日合计 0.4%），按累计时长过滤以免天天点亮橙色告警。测试 `SamplingGapAccountingTests.swift`、`SamplingGapQualityTests.swift`。
- `SleepEnergyCalculator.segment(from:)`：睡眠段能量归属，`minimumDuration = 60s`（更短的睡眠不生成区间、也不参与插值）。待机模式以**睡眠前供电状态**为准（睡眠中无法插拔）；插电待机优先用 `AccumulatedWallEnergyEstimate` 计数器差值，电池供电用睡眠前后电量差 × 平均电压，不可用时回退到唤醒后维持功耗估算。边界两侧供电状态变化（`SleepBoundaryPowerChange`，`batteryToAdapter`/`adapterToBattery`）走对称的 `sourceChanged` 分支，只计可观测来源并置 `SleepSegment.hasUnobservedSource = true`（该段能量为下界，见 `Models/SleepSegment.swift`）。测试 `SleepEnergyCalculatorTests.swift`。
- `PowerTelemetryEnergy.wallEnergyKWh(before:after:duration:)`：计数器差值 → kWh（单位假设 µWh，须按机型用插座电表校准），带合理性校验（平均功率 ≤500 W）。测试 `PowerTelemetryEnergyTests.swift`。
- `PowerTelemetryCalibrationStore`（`Models/PowerTelemetryCalibration.swift`）：按机型 + macOS 版本持久化校准系数到 `~/Library/Application Support/BatteryGlass/power-calibration.json`；无有效实测记录时系数为 1.0 且睡眠段 `isCalibrated = false`。现为 `@MainActor @Observable` 共享引用类型，由 `BatteryGlassApp` 创建唯一实例同时注入 `BatteryMonitor` 与设置页，设置页「电源校准」分节（`Views/PowerCalibrationSection.swift`）通过引导式校准会话录入并即时生效。测试 `PowerTelemetryCalibrationTests.swift`。
- `DailySummary`（`Models/HistorySample.swift`）是日能耗聚合载体，含 `energyQuality: DailyEnergyQuality?` 品质标记（旧汇总为 nil）。品质分两层：`hasAccuracyWarning`（采样断点 / 睡眠估算 / 未校准计数器 / 只统计到可观测来源——会让数值偏低或有偏差，橙色告警）与 `hasUnknownProvenance`（旧版本记录、口径未知，只做低强度提示）；`DailySummary.needsEnergyAttention`（无可用值或 `hasAccuracyWarning`）是图表/明细的统一告警谓词，`hasValidEnergy` 与 `EnergyCalculator.isValidPower` 共用同一判定。`DailyEnergySummaryPolicy` 处理 reconcile 与稀疏日清除；`EnergyAggregator`（`Support/EnergyAggregator.swift`）把每日能耗再按日/周/月聚合供图表分组，并统计周期内需要告警的天数 `incompleteDayCount`（旧口径不计入，否则整段历史变橙会淹没真实缺口）。测试 `DailyEnergySummaryPolicyTests.swift`、`EnergyAggregatorTests.swift`。

### 可测试性设计（重要）

- `BatterySnapshot` 是纯值类型，功率语义全部是只读计算属性（`power`、`chargingPowerW`、`directSupplyPowerW`、`adapterOutputPowerW`、`consumptionPowerW`、`displayPower`）。这些语义是多个测试的核心断言对象，修改前必须先看 `Tests/BatteryGlassTests/EnergyConsumptionTests.swift`。
- `BatteryMonitor` 的解析逻辑提取为 `static` 纯函数以支持单元测试：`parsePowerSourceDescription(_:initial:)`、`applyAdapterDetails(_:to:)`、`resolvedPowerState`、`resolvedCapacityMAh`、`resolvedDesignCapacityMAh`、`resolvedFullChargeCapacityMAh`、`resolvedCurrentCapacityMAh`、`resolvedSystemPowerW`、`dischargingSystemPowerW`、`minimumMaintenancePowers`、`parsePowerTelemetryCounters`，以及 `IOPSPowerSourceState` 枚举。测试直接构造 `[String: Any]` 字典调用它们，不 mock IOKit（对应测试类：`BatteryMonitorIOPSParsingTests`、`BatteryMonitorSmartBatteryTests`、`BatteryMonitorStateTests`、`EnergyConsumptionTests`）。新增可验证的决策逻辑时沿用此模式（纯函数提取 + 先写失败测试）。
- 容量语义：Apple Silicon 上 IOPS 的 Current/Max Capacity 是 0-100 归一化值而非 mAh，快照容量字段经 `resolvedCapacityMAh`（SmartBattery 真 mAh 优先、IOPS 仅量级 >500 时兜底）过滤后恒为真 mAh。
- 单位约定：电压 mV→V、电流 mA→A（IOPS 与 SmartBattery 两条路径必须一致）；`PowerTelemetryData` 功率为带符号 64 位整数 mW，须经 `signedMW` 按位转换。
- 测试类地图（`Tests/BatteryGlassTests/`）：解析/状态 `BatteryMonitorIOPSParsingTests`、`BatteryMonitorSmartBatteryTests`、`BatteryMonitorStateTests`、`PowerDisplayTransitionTests`（插拔过渡展示状态机）、`BatteryMonitorPublishPolicyTests`（采样与界面发布节拍的分档策略）；能耗 `EnergyConsumptionTests`、`SleepEnergyCalculatorTests`、`PowerTelemetryEnergyTests`、`PowerTelemetryCalibrationTests`、`EnergyAggregatorTests`、`DailyEnergySummaryPolicyTests`、`BatteryDischargeConfirmationTests`、`SamplingGapAccountingTests`（纯函数：断点/缺失读数累计、睡眠排除、跨午夜拆天）、`SamplingGapQualityTests`（`BatteryHistoryStore` 端到端：短缺失不点亮、长断点点亮、加载时重算可自愈）；时间估算 `TimeRemainingEstimatorTests`、`ChargeRateTrackerTests`、`TimeRemainingSmootherTests`；持久化 `HistoryPersistenceTests`、`HistoryRecoveryTests`、`HistoryRetentionTests`、`HistoryExporterTests`、`HistorySampleArchiveTests`（分钟 upsert/时区/DST/失败回滚）、`LongTermHistoryTests`（旧版迁移、跨天归档、重启边界、超大归档按需加载、清空、迁移失败重试）；图表 `PowerChartDataTests`、`PowerChartSegmentationTests`、`PowerChartInteractionTests`、`BatteryLevelChartDataTests`（后者覆盖 `HistoryView.swift` 内的 `BatteryLevelChartData` / `BatteryLevelChartDataCache`）、`AxisTickScaleTests`（`EnergyAxisScale.ticks`/`fractionDigits`：窄域标签唯一、刻度落在域内且升序、退化域不崩溃）、`ChartZoomWindowTests`、`ChartTimeAxisTests`、`ChartViewportTests`、`HistoryDaySelectionTests`；统计边界 `HistoryAccountingBoundaryTests`（近 N 个日历日、退出前结算、清空取消与旧事件拦截、已知修复备份清理、长睡眠缺失提示及跨天结算）、`DailyEnergyQualityTests`（`hasUnmeasuredSleepEnergy` 的旧文件兼容解码）、`PowerTrendStatisticsTests`（以当前快照时间计算的 120 秒窗口与过期读数；睡眠缺失提示由 `SleepInterval` 与已结算 `SleepSegment` 核对，仅增加质量说明、不重算旧日耗电）；其余 `AppSettingsTests`、`LoginItemServiceTests`、`MenuBarLabelTests`、`BatteryFormattersTests`、`PowerDiagnosticsTests`。

### Stores / 持久化

- `AppSettings`：UserDefaults 持久化，key 见文件内 static 常量。涵盖低电量通知开关与阈值（读取时钳制 10–50）、外接电源变化通知、菜单栏显示模式（`MenuBarDisplayMode`：无 / 百分比 / 剩余时间）、桌面小组件开关 / 尺寸（`DesktopWidgetStyle`）/ 位置、记录历史、电源诊断日志、开机自启动、动效浓度与速度。注意 `DashboardView` 的分页记忆另用 `@AppStorage("BatteryGlass.panelTab")`，**不在** `AppSettings` 内。
- `BatteryHistoryStore`：**双层持久化**，都在 `~/Library/Application Support/BatteryGlass/`。**热层 `history.json`** 只保留「今天 + 跨午夜前最后一条」的样本（`liveSamples`，保留末条是为保证重启后能量积分边界），payload 版本化（当前 **v8**：samples + dailySummaries + sleepSegments + sleepIntervals；`HistorySample` 已不再记录温度与电压），每 15 秒异步写盘（串行 `persistenceQueue`），退出时 `flush()` 先通过注入的 `finishPendingSleepEnergy` 回调结算待处理的睡眠，再同步写盘（`willTerminateNotification`）；清空时调用 `cancelPendingSleepEnergy` 并拒绝清空时间之前的旧事件。样本 ≥5 秒记一条，cycleCount/health 显著变化立即记。**冷层 `history.sqlite`**（`Stores/HistorySampleArchive.swift`，系统 SQLite3、无第三方依赖）以「epoch 分钟」为 PRIMARY KEY 存往日样本，正式取代早期「近 7 天降采样」方案：`pruneHistory()` 在跨天时先把昨日写入归档，**归档写成功后**才从热层淘汰，故历史分钟长期保留、不再受 7 天窗口限制（图表/导出改为按需读取）。读取路径：`samples(forDay:)` 取「归档单日 + 热层」合并（记忆化缓存 `cachedArchiveDay`/`cachedMergedSamples`），`availableDays()` 取「归档索引 + 热层」并集（`availableDays(from:)` 来自 `HistoryRetention`），导出走 `allCurveSamples()` 全量读归档。**要点**：① 归档写入先于 `history.json` 原子替换，中途崩溃安全——下次按同一分钟 bucket upsert 幂等；② `payload.version < 7` 的旧文件在迁移前备份为 `history.legacy.json`（`clearHistory()` 连带删除迁移备份和已知 `history.json.before-counter-unit-repair-*` 修复备份）；③ 采样断点按**当日累计未计入积分的时长**判定（`EnergyCalculator.unaccountedSecondsByDay` / `DailyUnaccountedTime.needsWarning`）：单次几秒的读数缺失不足以影响日合计，逐段报警会把告警变成噪声，因此「读数缺失」要累计 10 分钟才告警（实测一天只有 2~3 分钟），只有间隔 > 60 秒的真实断点才立即告警；`applyTodaySamplingGapQuality(in:)` 只在加载时用**回填后**的样本重算「今天」（否则诊断回填前会把已恢复的样本误标成缺口），且**只判定今天**——往日样本已降到 1 分钟一条、间隔本身就接近 `maximumGap`，据此重算会把每个旧日期都标成质量异常；今天始终原生精度，因此结论权威，可随样本补齐自动消除，且当天没有缺口也没有汇总时不会凭空创建空 summary；④ 加载时按 `payload.version` 逐级迁移（v2 起含 dailySummaries，v3 起含 sleepSegments，v4 起含 sleepIntervals，v5 起 `SleepSegment` 增 `hasUnobservedSource`/`boundaryPowerChange`、`DailySummary` 增 `energyQuality`，v6 起 `HistorySample` 增 `temperatureCelsius`，v7 起切到归档分层，v8 起**移除历史温度**（`HistorySample` 现仅含 id/timestamp/power/consumptionPowerW/percent/cycleCount/healthPercent，不再有温度与电压；加载时清除 `history.legacy.json` 备份与 `history.sqlite` 归档里残留的 `temperatureCelsius`，见 `removeTemperatureHistoryFromLegacyBackup` / `HistorySampleArchive.removeTemperatureHistory()`；旧文件/归档里多出的 `voltage` 键由合成 Codable 忽略、无需迁移分支）；新增字段均带默认值、经 `decodeIfPresent` 解码，旧文件无需新增迁移分支），并含"用 power-diagnostics.jsonl 回填 `consumptionPowerW`"的恢复逻辑（实现于 `Stores/HistorySampleRecovery.swift` 的 `backfillConsumptionPower`，同样经 `BoundedFileReader` / `HistoryLoadLimits` 限幅，重算只覆盖 `allowedDayKeys = [今天]`）。
- `HistorySampleArchive`（`Stores/HistorySampleArchive.swift`）：SQLite3 曲线归档，表 `samples(minute INTEGER PRIMARY KEY, timestamp REAL, payload BLOB)` + `timestamp` 索引，payload 为 `HistorySample` 的 ISO8601 JSON。提供 `store(_:)`（`BEGIN IMMEDIATE` 事务，失败 `ROLLBACK` 不半写）、`samples(forDay:calendar:)`（按 `calendar.dateInterval(of: .day:)` 查询，正确处理时区与 DST）、`allSamples()`、`availableDays()`、`remove()`（连带 `-wal`/`-shm`/`-journal`）。所有访问由 `BatteryHistoryStore` 在 `persistenceQueue` 上串行化，`open()` 设 5s `busy_timeout`。测试 `HistorySampleArchiveTests`。
- `PowerDiagnosticsLogger`（单例）：JSONL 追加写 `power-diagnostics.jsonl`，单份 5 MB 自动轮换为 `.1.jsonl`，两份合计最多约 10 MB。
- `BoundedFileReader` / `HistoryLoadLimits`：`history.json` 与诊断 JSONL 的读取必须走这里（历史上限 20 MB/10 万样本，诊断 50 MB/10 万样本），防止异常本地文件拖慢启动。**`history.sqlite` 不受此限**：归档由 SQLite 按日索引查询，容量可远超 10 万样本（`LongTermHistoryTests` 专门锁定「超出旧文件/样本上限仍只加载所请求的一天」）。
- `HistoryExporter`（`Support/HistoryExporter.swift`）：把历史样本与每日汇总序列化为 CSV、JSON（JSON 另含睡眠区间），设置页导出按钮调用，纯函数。
- 持久化模式是"主线程同步记录 → 后台串行队列写文件"，新增类似逻辑时保持一致。

### Views / UI

- `DashboardView` 是 `MenuBarExtra` window 的面板根视图；`PanelTab` 分段控件切换 `LiveDashboardView` / `HistoryView`（HistoryView 用 Swift Charts）。实时页用 `ViewThatFits(in: .vertical)`：标准字号直接展示完整面板，字号被系统放大导致空间不足时自动回退到 `ScrollView`。
- 菜单栏图标：`MenuBarLabel` 经 `MenuBarIconRenderer` 把多层 SwiftUI 合成为**单张模板 `NSImage`**（`MenuBarExtra` 会丢弃多层子视图），着色交给系统模板；图标旁文字由 `AppSettings.menuBarDisplayMode` 控制。`MenuBarAccessibility`、`MenuBarBatteryFill`、`MenuBarPowerIndicator` 均为纯函数，测试 `MenuBarLabelTests`。
- `Views/HistoryView.swift` 是仓库最大的单文件（约 2,020 行，占源码约 1/4），内联了多个纯函数缓存与纯数据类型：缓存 `TodaySamplesCache`、`PowerChartDataCache`、`BatteryLevelChartDataCache`、`DailyAggregateCache`；数据/坐标轴 `PowerChartData`/`PowerChartBreak`/`PowerChartConnection`/`PowerChartAxisMark`/`PowerChartTimeline`、`BatteryLevelChartData`/`BatteryLevelAxis`、`AxisTickScale`/`EnergyAxisScale`（能耗/能量轴刻度，保证窄域下标签不重复）、`PowerChartSegmentation`/`PowerChartWindow`/`PowerChartInteraction`，以及图表降采样 `HistoryChartRendering.downsamplePreservingExtrema`（保留局部极值，上限 800 点）。图表视图：`TodayPowerChart`、`TodayBatteryLevelChart`、`DailyEnergyComparisonChart`（按日/周/月的能耗对比）。改图表相关逻辑优先看这里；数据/缓存部分有独立测试（`PowerChartDataTests`、`PowerChartSegmentationTests`、`PowerChartInteractionTests`、`BatteryLevelChartDataTests`、`AxisTickScaleTests`），改动时不要破坏其纯函数边界。**注意**：温度/电压的历史曲线已整体移除（见「Stores / 持久化」v8 说明），历史页只剩功率与电量两条时间序列曲线。
- 两条曲线（`TodayPowerChart` / `TodayBatteryLevelChart`）支持**缩放 + 平移 + 点击放大窗口**：横向视口统一由纯模型 `ChartZoomWindow` 表达（功率图坐标是「曲线秒」，即断点塌缩为 0 宽度后的坐标；电量图是 `Date → timeIntervalSinceReferenceDate` 秒），每图 `@State window: ChartZoomWindow?`（`nil` = 默认：功率图贴最新 2 小时，其余整段），切换日期或跨天重置。压缩后的功率缺口用 `PowerChartConnection` 以同色蓝色竖线连接前后实测点（时间轴仍保留 `//` 标记），修正电源切换等读数缺失造成的视觉断线。**输入层不能用 `.chartOverlay` 里的 SwiftUI 手势**：`MagnifyGesture` 收不到事件、`.onContinuousHover` 会被盖在其上的真实 `NSView` 挡住。改用 `Views/ChartZoomInteraction.swift` 的 `ChartPlotEventCatcher`（真实 `NSView`，重写 `mouseDragged`/`scrollWheel`/`magnify(with:)`，自建 `NSTrackingArea` 上报悬停，`isFlipped` 必须为 `true` 否则 y 轴翻转；增量语义，无需缓存手势起点）覆盖在 `chartOverlay` 内容之上。**可靠入口是 `scrollWheel`（⌘+滚轮缩放、双指横扫平移）与标题栏 `🔍−`/`🔍＋`/`⟲`**；触控板捏合（`magnify`）在菜单栏面板上投递不稳定（实测有时能收到、多数时候收不到，`active=true` + key window 也不是原因），仅作尽力而为的补充。目标判定必须用「光标屏幕坐标 + `hitTest`」，不能用 `event.window === self.window`（`magnify` 的 `event.window` 不指向面板窗口）；`hitTest` 同时正确处理 z 序与遮挡。锚点/位移换算由纯函数 `ChartZoomGestureMath` 完成。不要再用 `PreferenceKey` 把绘图区矩形传出并在 `onPreferenceChange` 写 `@State`（与面板 2Hz 重渲染形成布局反馈环会严重卡顿）。**另一处性能陷阱**：`yDomain`/`yAxis`/`displaySegments`/`axisMarks` 这类含 O(样本数) 筛选或字符串格式化的计算属性不能直接写进逐样本的 `ForEach`（`AreaMark` 的 `yStart`），否则退化成 O(n²)；各图 `body` 开头每帧只求值一次再传进 `Chart`。缩放后 Y 轴按可见样本重算（未缩放时与整日预计算域逐值相等，有测试锁定），X 轴刻度由 `Models/ChartTimeAxis.swift` 随跨度在 6 小时 / 1 小时 / 30 分 / 10 分之间切换。**按天回看只在放大窗口可选**：两条曲线的 `day` 参数（当天 00:00）在面板固定为今天，放大窗口由顶部日期导航器 `◀  8/25  ▶`（左右箭头逐天 + 点日期弹菜单）驱动；往日整天并收在当天最后一条样本，今天收在最新样本。日期集合来自 `BatteryHistoryStore.availableDays()`（归档索引 + 热层的并集，底层用 `HistoryRetention.availableDays`），导航逻辑在纯类型 `Models/HistoryDaySelection.swift`（`days` 始终并入今天、选中日被清理后回退到最近可用日），电量曲线的 X 域由 `BatteryLevelAxis.xDomain(day:now:lastSample:calendar:)` 给出。放大按钮打开 `Services/ChartWindowController` 的**独立窗口**（普通可缩放窗口，默认 1000×600，位置与大小经 `setFrameAutosaveName` 记住；内容为 `Views/ChartDetailView`，自带一份记忆化缓存并随新样本刷新，`plotHeight: nil` 让绘图区撑满窗口）。相关测试：`ChartZoomWindowTests`、`ChartTimeAxisTests`、`ChartViewportTests`、`HistoryDaySelectionTests`、`HistoryRetentionTests`。
- 动效集中在 `Views/FluidGlassBackground.swift`（流体光斑）、`Views/AnimatedSegmentedControl.swift`（胶囊滑动）与 `Support/PageTransition.swift`（页面切换过渡）；设计令牌（8pt 间距栅格、交通灯状态色、数据蓝）见 `Support/DesignTokens.swift`，配色见 `Support/BatteryStyling.swift`。动效参数调节说明见 README「流体玻璃动画参数调节」。**性能注意**：`FluidGlassBackground` 的 `TimelineView(.animation)`（30fps）在 `MenuBarExtra(.window)` 面板关闭后**不会**自动停止（内容视图仍存活、布局不受窗口可见性门控），会持续让离屏窗口重新布局；因此 `DashboardView` 用 `Views/PanelVisibilityObserver.swift`（监听承载窗口的 order/occlusion 通知）把动画门控为「实时页 + 面板可见」，并把 `ViewThatFits` 换成基于 `dynamicTypeSize` 的单分支判断（`ViewThatFits` 每轮布局都会测量两个分支）。
- 桌面小组件是应用内 NSWindow（`DesktopWidgetController`），非 WidgetKit。
- 历史页顶部原生 `Picker`（「分组」菜单 / 「统计范围」分段）在 macOS 26 上曾观察到边框周期性闪烁，复现步骤与排查结论（暂无法复现、未改业务代码）见根目录 `HISTORY_PICKER_FLICKER.md`。
- UI 规范以 `design-system/batteryglass/MASTER.md` 为基准。
- 能耗口径的设计动机与边界见 `docs/superpowers/specs/`（尤其 `2026-09-06-precision-energy-accounting-design.md` 定义"从电源侧消耗了多少电"这一指标口径），配套实施计划在 `docs/superpowers/plans/`。修改能耗相关决策前先读这两处。

## 约定

- **每次修改代码/文件后，必须在根目录 `CHANGELOG.md` 顶部（时间倒序）追加记录**，格式参照 Keep a Changelog，分类：新增/修改/修复/重构。未记录变更不算任务完成。
- 不引入第三方依赖；保持 macOS 14 最低部署版本；不引入沙盒/公证（本地构建为 ad-hoc 签名）。
- 完成修改后运行完整 `swift test` 并检查 `git diff`，确认无无关变更。
- 新增/删除源文件或测试类时同步更新本文件的「项目结构」与「测试类地图」，避免清单与正文脱节。
