# BatteryGlass Audit Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复审计发现的功耗切换、容量兜底、退出持久化竞态和本地历史文件加载健壮性问题。

**Architecture:** 保持现有 macOS SwiftUI/IOKit 架构不变，将可验证的决策逻辑提取为纯函数；历史和诊断文件统一通过有上限的文件读取器，并在 JSON 解码后限制对象数量。电池通知在主线程/主 actor 上同步记录，确保终止 flush 能看到最新样本。

**Tech Stack:** Swift 5.10、SwiftPM、SwiftUI、AppKit、IOKit、XCTest。

**Spec:** 本次对 BatteryGlass 代码审计的修复清单（会话中已确认的 4 项问题）。

## Global Constraints

- 保持 macOS 14 最低部署版本。
- 不引入第三方依赖。
- 不覆盖或回退用户已有提交 `5a3c964`。
- 每个生产代码变化必须先有能失败的回归测试。
- 完成前必须运行完整 `swift test` 并检查 Git diff/status。

### Task 1: 修复断电后的系统功耗兜底

**Files:**
- Modify: `Tests/BatteryGlassTests/EnergyConsumptionTests.swift`
- Modify: `Sources/BatteryGlass/Services/BatteryMonitor.swift`

- [x] 写测试：无 BatteryPower 遥测但有负的电池电气功率时，系统功耗使用电气功率绝对值。
- [x] 运行测试确认当前实现失败。
- [x] 提取并接入最小的纯函数决策逻辑。
- [x] 运行该测试和完整测试确认通过。

### Task 2: 修复 SmartBattery 容量兜底

**Files:**
- Modify: `Tests/BatteryGlassTests/BatteryMonitorIOPSParsingTests.swift`
- Modify: `Sources/BatteryGlass/Services/BatteryMonitor.swift`

- [x] 写测试：IOPS 最大容量缺失时使用 SmartBattery 满充容量；IOPS 有值时优先 IOPS。
- [x] 运行测试确认当前实现失败。
- [x] 接入容量选择函数到 snapshot 构造流程。
- [x] 运行相关测试和完整测试确认通过。

### Task 3: 消除通知记录与终止 flush 的竞态

**Files:**
- Modify: `Tests/BatteryGlassTests/HistoryPersistenceTests.swift`
- Modify: `Sources/BatteryGlass/Stores/BatteryHistoryStore.swift`

- [x] 写测试：发送快照通知后立即发送终止通知，flush 文件必须包含该快照。
- [x] 运行测试确认当前异步通知实现失败。
- [x] 在主线程回调中同步进入 MainActor 并记录样本。
- [x] 运行相关测试和完整测试确认通过。

### Task 4: 限制并统一本地文件读取

**Files:**
- Create: `Sources/BatteryGlass/Stores/BoundedFileReader.swift`
- Modify: `Sources/BatteryGlass/Stores/BatteryHistoryStore.swift`
- Modify: `Sources/BatteryGlass/Stores/HistorySampleRecovery.swift`
- Modify: `Tests/BatteryGlassTests/HistoryPersistenceTests.swift`
- Modify: `Tests/BatteryGlassTests/HistoryRecoveryTests.swift`

- [x] 写测试：读取器拒绝超过上限的文件，并允许上限以内的文件。
- [x] 运行测试确认读取器缺失导致失败。
- [x] 用打开后的 FileHandle 限量读取替换 Data(contentsOf:)；增加历史样本和诊断样本数量上限。
- [x] 运行相关测试和完整测试确认通过。

### Task 5: 完成验证

**Files:**
- Modify: `CHANGELOG.md`

- [x] 更新 changelog 记录本次修复。
- [x] 运行 `swift test`、`bash -n script/build_and_run.sh`、`git diff --check`。
- [x] 检查 `git status` 和最终 diff，确认不包含无关变更。
- [x] 提交修复。
