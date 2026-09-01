# Accurate Energy Accounting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the B-metric energy total source-aware and improve sleep accounting with validated telemetry counters and safe fallbacks.

**Architecture:** Add a pure telemetry-counter layer, feed it from `BatteryMonitor`, and keep `BatteryHistoryStore` responsible only for persistence and daily aggregation. The wall-energy counter is used only when its delta passes validation; otherwise the calculator falls back to battery/source measurements and labels the result estimated.

**Tech Stack:** Swift 5.10, Foundation, AppKit, XCTest, existing Swift Package Manager target.

**Spec:** `docs/superpowers/specs/2026-09-01-accurate-energy-accounting-design.md`

## Global Constraints

- Preserve the selected B metric: battery discharge while on battery, adapter input while externally powered.
- Do not count the sleep interval through ordinary awake-sample interpolation and then add it again.
- Treat `PowerTelemetryData` cumulative fields as undocumented and reject unsafe deltas.
- Keep all pure calculation logic unit-testable without IOKit or AppKit.
- Do not break v3 history decoding; new sleep fields must be backward-compatible.

### Task 1: Add pure telemetry counter and sleep-energy models

**Files:**
- Create: `Sources/BatteryGlass/Models/PowerTelemetryEnergy.swift`
- Modify: `Sources/BatteryGlass/Models/SleepSegment.swift`
- Modify: `Sources/BatteryGlass/Models/SleepEnergyCalculator.swift`
- Test: `Tests/BatteryGlassTests/SleepEnergyCalculatorTests.swift`
- Test: `Tests/BatteryGlassTests/PowerTelemetryEnergyTests.swift`

**Interfaces:**
- `PowerTelemetryCounters` stores the raw `UInt64` wall-energy counter currently used by the sleep path.
- `PowerTelemetryEnergy.wallEnergyKWh(before:after:duration:)` validates a monotonic delta, rejects implausible average power, and converts the currently calibrated raw unit.
- `SleepSegment.measurementMethod` records whether the result came from the telemetry counter or a fallback estimate.
- `SleepEnergyCalculator.segment(from:)` remains the source of truth for the existing persistence/UI flow.

- [x] **Step 1: Write failing tests** for valid counter deltas, reset rejection, external-plus-discharging fallback, and method/estimate propagation.
- [x] **Step 2: Run the focused tests** with `swift test --filter PowerTelemetryEnergyTests` and `swift test --filter SleepEnergyCalculatorTests`; confirm the new APIs fail to compile or assert as expected.
- [x] **Step 3: Implement the smallest pure models and calculator changes**; use optional validated counter energy first and existing capacity/maintenance formulas only as fallback.
- [x] **Step 4: Run the focused tests** again and confirm all new and existing sleep tests pass.

### Task 2: Parse telemetry counters and wire sleep baselines

**Files:**
- Modify: `Sources/BatteryGlass/Services/BatteryMonitor.swift:18-29,184-275,591-672`
- Modify: `Sources/BatteryGlass/Models/PowerDiagnosticsSample.swift`
- Modify: `Tests/BatteryGlassTests/BatteryMonitorIOPSParsingTests.swift`
- Modify: `Tests/BatteryGlassTests/PowerDiagnosticsTests.swift`

**Interfaces:**
- `SmartBatteryData` exposes parsed `PowerTelemetryCounters` and instantaneous source values.
- Sleep baseline stores `PowerTelemetryCounters` and `PowerState`, not only `adapterConnected`.
- `BatteryMonitor` passes before/after counters to `SleepEnergyCalculator` and records the raw values in diagnostics.

- [x] **Step 1: Write failing parsing tests** for unsigned raw counters and missing fields.
- [x] **Step 2: Run the focused parsing tests** and confirm they fail for the missing fields/API.
- [x] **Step 3: Parse the wall counter without converting it through `Double`**, capture the sleep-before state, and calculate the wake result once the validation layer accepts a delta.
- [x] **Step 4: Run the focused parsing and diagnostics tests** and confirm the raw/derived fields survive round trips.

### Task 3: Make persistence and daily totals source-correct

**Files:**
- Modify: `Sources/BatteryGlass/Stores/BatteryHistoryStore.swift:73-117,160-239`
- Modify: `Sources/BatteryGlass/Models/SleepSegment.swift`
- Modify: `Tests/BatteryGlassTests/HistoryPersistenceTests.swift`

**Interfaces:**
- `recordSleepSegment(_:)` ignores duplicate IDs and returns without mutation when `recordHistory` is false.
- v3 sleep data decodes older segments with default method metadata.
- Daily summary receives the segment's `totalKWh` exactly once.

- [x] **Step 1: Write failing store tests** for duplicate segment IDs and disabled history.
- [x] **Step 2: Run the focused persistence tests** and confirm the new assertions fail.
- [x] **Step 3: Implement guards, compatible decoding, and one-time daily aggregation** while preserving the existing recovery behavior.
- [x] **Step 4: Run the focused persistence tests** and confirm they pass.

### Task 4: Verify end-to-end behavior and document calibration

**Files:**
- Modify: `README.md`
- Modify: `CHANGELOG.md`
- Test: all existing tests

- [x] **Step 1: Run `swift test`** and confirm the full suite passes with zero failures.
- [x] **Step 2: Run `git diff --check`** and inspect the final diff for accidental unrelated changes.
- [x] **Step 3: Document that cumulative counter units must be validated with a physical watt-meter** and that fallback sleep values are estimates.
- [x] **Step 4: Run `swift test` once more** after documentation changes and confirm the same zero-failure result.
