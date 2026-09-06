# Precision Energy Accounting Design

**Date:** 2026-09-06

**Goal:** 在保持“从用户电源侧消耗了多少电”这一指标定义不变的前提下，消除短睡眠的虚构插值、补齐插电同时放电的能量来源、让墙上计数器可按机型校准，并明确旧历史只向前生效。

## Metric and boundaries

主指标仍是 source-side energy（电源侧能量），不是 `SystemLoad` 或电脑内部负载：

- 不插电时，累计电池放电功率/能量。
- 插电且正常供电时，累计 `SystemPowerIn` 适配器输入；该值本身包含电脑运行、给电池充电和转换损耗。
- 插电但确认电池仍在放电时，同时累计适配器输入和电池放电贡献。这里的“同时”表示两个可观测电源来源，不把 `SystemLoad` 当成主指标，也不把充电功率再次加到适配器输入上。
- 睡眠区间单独计算一次，并从普通样本积分中排除，避免重复计算。

本次不承诺未经实测的 Apple 私有计数器已经是物理墙上电表真值；计数器只能在通过单调性/合理功率校验后使用，校准系数仍需要真实电表样本。

## Q1: short sleep is an explicit unknown interval

`SleepEnergyCalculator.minimumDuration` 继续保持 60 秒。低于 60 秒的睡眠不生成 `SleepSegment`，也不人为补一段低置信功率；但必须阻断普通样本之间的梯形插值。

新增内部持久化模型 `SleepInterval`，只记录 `start`、`end` 和唯一 ID，不进入图表和用户展示：

1. `BatteryMonitor` 在 `willSleep` 发布开始事件，在 `didWake` 发布结束事件。
2. `BatteryHistoryStore` 在收到开始事件后，把下一次跨过开始时间的样本对视为睡眠边界，不做普通积分。
3. 结束事件落库后，所有已落库的区间都参与边界判断，因此恰好 60 秒的睡眠也不会出现“普通积分 + SleepSegment”双计。
4. 60 秒以上的区间再由 `SleepEnergyCalculator` 生成 `SleepSegment` 并单独加入每日汇总；低于 60 秒只有未知区间记录，不加入能耗。

历史文件新增可选 `sleepIntervals` 字段并提升当前 payload 版本；缺字段的旧文件按空数组读取。它只保证新版本记录的睡眠边界，不能追溯已经被裁剪或没有原始边界的旧天数据。

## Q2: source-aware plugged fallback

### Awake samples

`BatterySnapshot` 增加独立于 UI `PowerState` 的电池放电来源字段。`BatteryMonitor` 用带符号的电池功率连续确认“插电时电池放电”，避免把插电瞬间残留的负电流误判成真实混合放电。确认后的快照按以下规则计算 `consumptionPowerW`：

- 插电混合放电：`adapterInputPowerW + batteryDischargePowerW`。
- 插电充电或停充：仅 `adapterInputPowerW`。
- 不插电放电：仅 `batteryDischargePowerW`。
- 缺少相应可靠来源：返回 `nil`，不以 `SystemLoad` 冒充电源侧输入。

### Sleep without a valid wall counter

睡眠前的“是否确认混合放电”作为独立 baseline 字段传入纯计算器；不再依赖运行时不会出现的 `adapterConnected && powerState == .discharging` 组合。回退按睡眠前后电量净变化分支：

- 电量净增加：
  `batteryChargeGainKWh + min(directSupplyPowerW) × duration`。
  其中 `directSupplyPowerW = adapterInputPowerW - chargingPowerW`，避免把适配器输入和电池充电重复相加。若直供样本缺失，只保留可由容量差得到的充入能量，不把缺失当成零。
- 电量不增加或下降：
  `min(adapterInputPowerW) × duration`，并且仅在 baseline 已确认混合放电时追加电池容量下降能量。
- 没有任何可用的来源能量时返回未知，不生成一个伪造的零功耗段。

所有无计数器路径仍标记为 `fallbackEstimate`。容量变化存在但无法观测另一部分时，结果保守保留可观测部分，并通过估算标记表达不确定性；不能从睡前/唤醒两个端点恢复睡眠中途发生又被抵消的多次充放电。

## Q3: calibration data path without UI

新增 `PowerTelemetryCalibrationStore`，以 JSON 保存到 Application Support，与历史样本分开。记录按 `hw.model` 归属，并保存：

- 硬件型号、macOS 版本、记录时间；
- 原始计数器差值；
- 按默认单位换算的未校准 kWh；
- 电表实测 kWh；
- `measured / uncalibrated` 系数和是否已校准。

`PowerTelemetryEnergy.wallEnergyKWh` 接受默认值为 `1.0` 的校准系数。当前机型存在已校准记录时，睡眠计数器能量乘以该系数；没有记录时保持原有换算并将 `SleepSegment.isCalibrated` 设为 `false`。使用有效校准记录时设为 `true`。旧 `SleepSegment` 缺少该字段时解码为 `false`。

本期不增加设置页录入 UI；存储/API/计算链路先完整，校准记录可由调试工具或直接编辑 JSON 产生。README 明确说明必须用物理电表验证，避免把默认单位假设误写成准确值。

## Q4: forward-only history policy

不迁移 `HistorySample`，不重算旧 `DailySummary`：旧样本没有 `adapterInputPowerW`、原始计数器和睡眠边界，且历史样本会被裁剪，物理上无法可靠恢复。新逻辑从发布后的新快照、新睡眠区间和新计数器开始生效；旧天汇总保持原值。

新字段全部可选或带默认值，以兼容现有 v2/v3 文件：`sleepIntervals` 缺失为空，`SleepSegment.isCalibrated` 缺失为 `false`，校准文件不存在等同于系数 `1.0`。

## Components and data flow

```text
BatteryMonitor
  ├─ signed battery source + confirmation → BatterySnapshot.consumptionPowerW
  ├─ sleep start/end events → BatteryHistoryStore boundary state
  └─ wake counter/input samples → SleepEnergyCalculator
                                      └─ SleepSegment(method, calibrated)
BatteryHistoryStore
  ├─ skips sample pairs crossing SleepInterval
  ├─ persists new intervals/segments without migrating old totals
  └─ adds each accepted SleepSegment exactly once
PowerTelemetryCalibrationStore
  └─ model-scoped factor → wallEnergyKWh(..., calibrationFactor:)
```

Pure calculation types remain free of AppKit/IOKit. `BatteryMonitor` is responsible for reading and confirming raw signals; the store is responsible for persistence and aggregation.

## Error handling and invariants

- Counter delta must be present, monotonic, positive, finite after conversion, and below the existing plausible average-power ceiling.
- Calibration factor must be finite and positive; invalid/missing data falls back to `1.0` and remains uncalibrated.
- Sleep interval end must be later than start; duplicate interval/segment IDs are ignored.
- A missing adapter/direct sample is not converted to zero unless an independently measured capacity component is the only available component.
- A sleep interval is never counted by both ordinary trapezoid integration and a `SleepSegment`.

## Verification

Tests will cover:

- ordinary integration skipping short and exactly-60-second sleep intervals;
- two-sample confirmation and awake mixed-source sums;
- plugged fallback for net charge, no change, decline, missing direct input, and no-source unknown;
- counter factor application, invalid factors, calibration JSON round trip, and old segment decoding;
- interval persistence, duplicate protection, v2/v3 history compatibility, and forward-only behavior.

Full `swift test` must pass, followed by `git diff --check` and a final clean-status/diff review. A physical watt-meter comparison remains a manual acceptance step outside automated tests.
