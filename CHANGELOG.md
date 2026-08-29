# Changelog

记录本项目每次修改的内容。格式参照 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，按时间倒序排列。

## [2026-08-29]

### 修复
- 桌面小组件与主面板"实时功率"取值统一：新增 `BatterySnapshot.displayPower`/`displayPowerText`，适配器供电时显示系统功率（适配器输入 → 系统功率 → 电池功率，无符号），电池供电时显示充放电功率（带正负号）；小组件不再显示与主面板含义不同的电池侧功率（充满电时不再出现 "+0.0 W"）（BatterySnapshot.swift、DesktopWidgetView.swift、LiveDashboardView.swift）。
- 历史/诊断文件加载增加大小上限：历史文件 20 MB、诊断文件 50 MB，超限跳过加载，防止本机被篡改的文件导致启动卡顿或内存暴涨（BatteryHistoryStore.swift、HistorySampleRecovery.swift）。
- 移除 `list as? [AnyObject]` 恒成功转换警告（BatteryMonitor.swift）。

### 修改
- 修正 `systemPowerW` 取值逻辑的注释（优先 SystemLoad → 适配器输入 − 充电功率 → 放电功率，有 SystemPowerIn 时覆盖为直供估算）。
- README 同步：系统功耗取值说明、电源分配公式、持久化间隔改为"每 15 秒持久化（退出前 flush）"。

### 新增
- `EnergyConsumptionTests` 增加 3 个用例：`displayPower` 在已接通电源时优先适配器输入、无输入时回退系统功率、电池供电时取充放电功率。

### 修复
- `BatteryMonitor.readPowerSources()` 未设置 `externalConnected`：现根据 `kIOPSPowerSourceStateKey == kIOPSACPowerValue` 判断是否接入交流电源，修复 IOKit fallback 在 SmartBattery 读取失败时误判为电池供电的问题（BatteryMonitor.swift）。
- IOPS fallback 路径的适配器电流 `kIOPSPowerAdapterCurrentKey` 单位为 mA，此前未转换导致数值放大 1000 倍：现统一 `/1000` 转为 A，与 SmartBattery 路径一致（BatteryMonitor.swift）。

### 重构
- 将 IOPS 电源描述与适配器信息的解析逻辑提取为 `parsePowerSourceDescription(_:initial:)` 与 `applyAdapterDetails(_:to:)` static 方法，便于单元测试。

### 修改
- 为 `readPowerSources()` 与 `IOPSPowerSourceState` 补充注释，总结 externalConnected 两步判定逻辑：单电源描述按 `kIOPSPowerSourceStateKey` 判断（仅 AC 为外部供电），UPS 通过 `IOPSGetProvidingPowerSourceType` 检测并视为外部供电。

### 新增
- `BatteryMonitorIOPSParsingTests`：7 个用例覆盖 AC/电池电源状态判断、缺失状态键、电压/电流单位换算、适配器电流 mA→A 转换及零值处理。
- IOPS UPS 供电支持：新增 `BatteryMonitor.IOPSPowerSourceState` 枚举（AC/Battery/UPS），UPS 供电时视为外部供电，不误判为电池放电。UPS 不在 `kIOPSPowerSourceStateKey` 取值内，改用 `IOPSGetProvidingPowerSourceType()` 检测；补充 4 个枚举映射测试用例。

## [2026-08-29] 初始记录

### 新增
- 创建 `changelog.md`，作为项目修改记录文件。
