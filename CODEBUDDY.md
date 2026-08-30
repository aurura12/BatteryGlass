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
./script/build_and_run.sh                        # 构建（swift build）→ 生成 dist/BatteryGlass.app → 启动
./script/build_and_run.sh --verify               # 启动并确认进程存在（CI/验证用）
./script/build_and_run.sh --logs                 # 启动并跟随进程日志
./script/build_and_run.sh --telemetry            # 启动并跟随 subsystem 日志
./script/build_and_run.sh --debug                # 用 lldb 运行二进制（跳过 .app 打包）
swift scripts/generate_icon.swift                # 重新生成 AppIcon.icns
```

测试目标依赖可执行目标，`swift test` 会同时编译 app 二进制。访问 `@MainActor` 类型（如 `BatteryMonitor`）的测试类需标注 `@MainActor`。

## 架构

### 对象图与依赖注入

所有核心对象在 `BatteryGlassApp.init` 中创建，通过 `.environment()` 注入视图，不依赖任何 DI 框架：

```
AppSettings → BatteryMonitor → BatteryHistoryStore
                             → DesktopWidgetController
```

全部核心类型都是 `@MainActor @Observable`（Swift Observation 框架），视图用 `@Environment(Type.self)` 读取。

### 数据流

1. `BatteryMonitor.refresh()` 每 0.5 秒（2 Hz，`Timer` 挂在 RunLoop `.common` 模式）从两个 IOKit 源读取并合并：
   - `readSmartBattery()`：`AppleSmartBattery` 注册表（容量/循环/温度/电气参数/AdapterDetails/PowerTelemetryData）
   - `readPowerSources()`：`IOPowerSources` IOPS 描述（容量/状态/剩余时间/适配器）
2. 合并后的 `BatterySnapshot` 通过 `batterySnapshotUpdated` 通知发布（`userInfo["snapshot"]`，通知名定义见 `Support/Extensions.swift`）。
3. `BatteryHistoryStore` 观察该通知做记录；`DesktopWidgetController` 观察 widget 显隐/重置通知。

### 可测试性设计（重要）

- `BatterySnapshot` 是纯值类型，功率语义全部是只读计算属性（`power`、`chargingPowerW`、`directSupplyPowerW`、`adapterOutputPowerW`、`consumptionPowerW`、`displayPower`）。这些语义是多个测试的核心断言对象，修改前必须先看 `Tests/BatteryGlassTests/EnergyConsumptionTests.swift`。
- `BatteryMonitor` 的解析逻辑提取为 `static` 纯函数以支持单元测试：`parsePowerSourceDescription(_:initial:)`、`applyAdapterDetails(_:to:)`、`resolvedMaxCapacity`、`dischargingSystemPowerW`，以及 `IOPSPowerSourceState` 枚举。测试直接构造 `[String: Any]` 字典调用它们，不 mock IOKit。新增可验证的决策逻辑时沿用此模式（纯函数提取 + 先写失败测试）。
- 单位约定：电压 mV→V、电流 mA→A（IOPS 与 SmartBattery 两条路径必须一致）；`PowerTelemetryData` 功率为带符号 64 位整数 mW，须经 `signedMW` 按位转换。

### Stores / 持久化

- `AppSettings`：UserDefaults 持久化，key 见文件内 static 常量。
- `BatteryHistoryStore`：`~/Library/Application Support/BatteryGlass/history.json`。payload 版本化（当前 v2：samples + dailySummaries），每 15 秒异步写盘（串行 `persistenceQueue`），退出时 `flush()` 同步写盘（`willTerminateNotification`）。样本 ≥5 秒记一条，cycleCount/health 显著变化立即记。加载时含版本迁移与"用 power-diagnostics.jsonl 回填 `consumptionPowerW`"的恢复逻辑。
- `PowerDiagnosticsLogger`（单例）：JSONL 追加写 `power-diagnostics.jsonl`，5 MB 自动轮换为 `.1.jsonl`。
- `BoundedFileReader` / `HistoryLoadLimits`：所有本地文件读取必须走这里（历史上限 20 MB/10 万样本，诊断 50 MB/10 万样本），防止异常本地文件拖慢启动。
- 持久化模式是"主线程同步记录 → 后台串行队列写文件"，新增类似逻辑时保持一致。

### Views / UI

- `DashboardView` 是面板根视图，同时用于主窗口与 `MenuBarExtra` window；`PanelTab` 分段控件切换 `LiveDashboardView` / `HistoryView`（HistoryView 用 Swift Charts）。
- 动效集中在 `Views/FluidGlassBackground.swift`、`EnergyRingView.swift`、`PowerWaveformView.swift`；设计令牌（8pt 间距栅格、交通灯状态色、数据蓝）见 `Support/DesignTokens.swift`，配色见 `Support/BatteryStyling.swift`。动效参数调节说明见 README「流体玻璃动画参数调节」。
- 桌面小组件是应用内 NSWindow（`DesktopWidgetController`），非 WidgetKit。
- UI 规范以 `design-system/batteryglass/MASTER.md` 为基准。

## 约定

- **每次修改代码/文件后，必须在根目录 `CHANGELOG.md` 顶部（时间倒序）追加记录**，格式参照 Keep a Changelog，分类：新增/修改/修复/重构。未记录变更不算任务完成。
- 不引入第三方依赖；保持 macOS 14 最低部署版本；不引入沙盒/公证（本地构建为 ad-hoc 签名）。
- 完成修改后运行完整 `swift test` 并检查 `git diff`，确认无无关变更。
