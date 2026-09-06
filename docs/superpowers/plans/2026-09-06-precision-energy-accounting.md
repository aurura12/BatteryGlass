# Precision Energy Accounting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Improve source-side energy accuracy by excluding short sleep interpolation, measuring confirmed mixed-source discharge, making plugged sleep fallback source-aware, and adding model-scoped counter calibration without rewriting old history.

**Architecture:** Keep pure interval, source-confirmation, counter, calibration, and sleep-energy calculations in Foundation-only models. `BatteryMonitor` owns raw telemetry reading, consecutive mixed-discharge confirmation, sleep lifecycle events, and maintenance samples. `BatteryHistoryStore` owns interval exclusion, backward-compatible persistence, and one-time daily aggregation. The primary metric remains battery discharge on battery and adapter input while externally powered.

**Tech Stack:** Swift 5.10, Foundation, AppKit, IOKit, Observation, XCTest, Swift Package Manager.

**Spec:** `docs/superpowers/specs/2026-09-06-precision-energy-accounting-design.md`

## Global Constraints

- Preserve source-side energy: battery discharge when on battery; adapter input when externally powered; adapter input plus confirmed battery discharge for a real mixed state.
- Exclude every recorded sleep interval from ordinary trapezoid integration, including intervals shorter than and exactly equal to 60 seconds.
- Keep `SleepEnergyCalculator`, `EnergyCalculator`, counter conversion, and calibration math free of AppKit/IOKit.
- Treat `AccumulatedWallEnergyEstimate` as untrusted; reject missing, reset, non-positive, non-finite, implausible, or invalidly calibrated values.
- Do not add raw source fields to `HistorySample` or recalculate old `DailySummary` values; new behavior is forward-only.
- Keep v2/v3 history files readable; absent `sleepIntervals` and `isCalibrated` fields use safe defaults.
- Never convert a missing adapter/direct sample into zero when no independently measured energy component exists.

### Task 1: Add persisted sleep intervals and pure integration exclusion

**Files:**
- Create: `Sources/BatteryGlass/Models/SleepInterval.swift`
- Modify: `Sources/BatteryGlass/Models/EnergyCalculator.swift`
- Test: `Tests/BatteryGlassTests/EnergyConsumptionTests.swift`

**Interfaces:**
- `SleepInterval`: `Codable`, `Identifiable`, `Equatable`, `Sendable`, with `id: UUID`, `start: Date`, and `end: Date`.
- `SleepInterval.overlaps(_ start: Date, _ end: Date) -> Bool` uses a half-open interval and returns false for invalid/zero-length ranges.
- `EnergyCalculator.dailyEnergyKWh(samples:calendar:maximumGap:excludedIntervals:)` keeps the existing defaults and skips a pair when any excluded interval overlaps the pair.
- Notification names `.sleepIntervalStarted` and `.sleepIntervalEnded` carry a start date, then start/end dates, respectively.

- [ ] **Step 1: Write the failing pure tests.**

Add tests that use two constant-power samples 30 seconds apart and assert that the ordinary integral is empty when an excluded interval covers the pair. Add a second test with a 60-second pair and an exactly-60-second interval, asserting no energy is returned. Add overlap-boundary tests showing a pair ending exactly at the interval start or beginning exactly at the interval end is not excluded.

```swift
func testDailyEnergySkipsPairCrossingShortSleepInterval() {
    let start = date("2026-09-06 10:00:00")
    let samples = [sample(at: start, power: 100), sample(at: start.addingTimeInterval(30), power: 100)]
    let interval = SleepInterval(start: start.addingTimeInterval(1), end: start.addingTimeInterval(29))

    let result = EnergyCalculator.dailyEnergyKWh(samples: samples, excludedIntervals: [interval])

    XCTAssertTrue(result.isEmpty)
}
```

- [ ] **Step 2: Run the focused tests and verify the intended failure.**

Run: `swift test --filter EnergyConsumptionTests/testDailyEnergySkipsPairCrossingShortSleepInterval`

Expected: compile failure because `SleepInterval` and `excludedIntervals` do not yet exist, or an assertion failure if the test helper is added before the API.

- [ ] **Step 3: Implement the minimal pure interval API.**

Create `SleepInterval`, implement its half-open overlap check, add the optional `excludedIntervals` parameter to `EnergyCalculator.dailyEnergyKWh`, and guard each sorted sample pair before interpolation. Keep the existing maximum-gap, invalid-power, midnight-splitting, and interpolation behavior unchanged for non-overlapping pairs.

- [ ] **Step 4: Run the focused and existing energy tests.**

Run: `swift test --filter EnergyConsumptionTests`

Expected: all energy tests pass, including the new short/exact-60-second exclusion cases and the existing integration cases.

- [ ] **Step 5: Commit the self-contained pure change.**

```bash
git add Sources/BatteryGlass/Models/SleepInterval.swift Sources/BatteryGlass/Models/EnergyCalculator.swift Sources/BatteryGlass/Support/Extensions.swift Tests/BatteryGlassTests/EnergyConsumptionTests.swift
git commit -m "feat: exclude sleep intervals from energy interpolation"
```

### Task 2: Confirm mixed-source battery discharge and fix awake source totals

**Files:**
- Create: `Sources/BatteryGlass/Models/BatteryDischargeConfirmation.swift`
- Modify: `Sources/BatteryGlass/Models/BatterySnapshot.swift`
- Modify: `Sources/BatteryGlass/Services/BatteryMonitor.swift`
- Modify: `Sources/BatteryGlass/Models/PowerDiagnosticsSample.swift`
- Test: `Tests/BatteryGlassTests/EnergyConsumptionTests.swift`
- Test: `Tests/BatteryGlassTests/BatteryMonitorStateTests.swift`
- Test: `Tests/BatteryGlassTests/PowerDiagnosticsTests.swift`

**Interfaces:**
- `BatteryDischargeConfirmation` is a pure mutable value type with a two-consecutive-sample threshold and `mutating func update(adapterConnected:state:batteryPowerW:) -> Bool`.
- `BatterySnapshot.batteryDischargePowerW` returns the positive magnitude of a finite negative battery power reading, otherwise `nil`.
- `BatterySnapshot.batteryDischargingWhilePlugged` defaults to `false` and is set by `BatteryMonitor` only after confirmation.
- `BatterySnapshot.consumptionPowerW` returns battery discharge alone on battery, adapter input alone while charging/idle, and adapter input plus confirmed battery discharge for a plugged mixed state.

- [ ] **Step 1: Write failing tests for the source rules.**

Add tests for: a confirmed plugged mixed snapshot returning `adapterInput + batteryDischarge`; a plugged snapshot without confirmation ignoring a single negative reading; a charging snapshot not adding a stale negative battery reading; and a missing adapter input returning only a confirmed battery discharge. Add confirmation tests for one negative sample (false), two consecutive negative samples (true), and reset on positive/absent/external-disconnected input.

```swift
func testConfirmedPluggedDischargeAddsBothSourceContributions() {
    var snapshot = BatterySnapshot()
    snapshot.state = .pluggedIn
    snapshot.adapterConnected = true
    snapshot.adapterInputPowerW = 80
    snapshot.voltage = 12
    snapshot.current = -2
    snapshot.batteryDischargingWhilePlugged = true

    XCTAssertEqual(snapshot.consumptionPowerW ?? 0, 104, accuracy: 0.000001)
}
```

- [ ] **Step 2: Run the new focused tests and confirm they fail for the missing behavior.**

Run: `swift test --filter BatteryMonitorStateTests` and `swift test --filter EnergyConsumptionTests/testConfirmedPluggedDischargeAddsBothSourceContributions`

Expected: the new assertions fail because the current snapshot model drops the battery contribution whenever the UI state is plugged in.

- [ ] **Step 3: Implement confirmation and source composition.**

Implement the two-sample confirmation type. Give `BatteryMonitor` one tracker instance, update it after the signed battery power is resolved and before diagnostics/snapshot notification, and copy the result into the snapshot. Update `consumptionPowerW` without changing `displayPower`, `systemPowerW`, or the definition of `adapterInputPowerW`. Add diagnostic fields for the positive battery-discharge component and confirmation flag so real hardware logs show why a mixed sample was counted.

- [ ] **Step 4: Run focused tests and the full existing energy/diagnostics set.**

Run: `swift test --filter BatteryMonitorStateTests`, `swift test --filter EnergyConsumptionTests`, and `swift test --filter PowerDiagnosticsTests`

Expected: all pass. Existing tests where `state == .discharging` and adapter input is merely a near-zero stale value continue to count only the battery source; only explicitly confirmed plugged mixed samples add both sources.

- [ ] **Step 5: Commit the source-accounting change.**

```bash
git add Sources/BatteryGlass/Models/BatteryDischargeConfirmation.swift Sources/BatteryGlass/Models/BatterySnapshot.swift Sources/BatteryGlass/Services/BatteryMonitor.swift Sources/BatteryGlass/Models/PowerDiagnosticsSample.swift Tests/BatteryGlassTests/EnergyConsumptionTests.swift Tests/BatteryGlassTests/BatteryMonitorStateTests.swift Tests/BatteryGlassTests/PowerDiagnosticsTests.swift
git commit -m "fix: count confirmed mixed power sources"
```

### Task 3: Make sleep fallback source-aware and add calibration metadata

**Files:**
- Create: `Sources/BatteryGlass/Models/PowerTelemetryCalibration.swift`
- Modify: `Sources/BatteryGlass/Models/PowerTelemetryEnergy.swift`
- Modify: `Sources/BatteryGlass/Models/SleepEnergyCalculator.swift`
- Modify: `Sources/BatteryGlass/Models/SleepSegment.swift`
- Test: `Tests/BatteryGlassTests/PowerTelemetryEnergyTests.swift`
- Test: `Tests/BatteryGlassTests/SleepEnergyCalculatorTests.swift`
- Create: `Tests/BatteryGlassTests/PowerTelemetryCalibrationTests.swift`

**Interfaces:**
- `PowerTelemetryEnergy.wallEnergyKWh(before:after:duration:calibrationFactor:)` keeps the existing default factor of `1.0`, validates the factor, and multiplies only after raw delta validation.
- `PowerTelemetryCalibrationContext` stores `hardwareModel` and `operatingSystem`; `.current` reads `hw.model` and the current macOS version.
- `PowerTelemetryCalibrationRecord` stores context, raw delta, uncalibrated energy, measured energy, factor, timestamp, and `isCalibrated`.
- `PowerTelemetryCalibrationStore` loads/saves a versioned JSON payload, exposes `calibrationFactor`/`isCalibrated` for its context, and ignores invalid records. Its default file is `Application Support/BatteryGlass/power-calibration.json`; tests inject a temporary URL and context.
- `SleepEnergyCalculator.Input` adds `maintenanceAdapterInputPowerW`, `batteryDischargingBefore`, `wallEnergyCalibrationFactor`, and `wallEnergyIsCalibrated`; remove the runtime reliance on `powerStateBefore`.
- `SleepSegment` adds `isCalibrated: Bool = false`; decoding a missing field yields `false`.

- [ ] **Step 1: Write failing counter, calibration, and fallback tests.**

Add tests for a factor-adjusted counter result, invalid factor rejection, calibration record factor calculation and JSON round trip, and old sleep-segment JSON defaulting `isCalibrated` to false. Replace/add sleep tests for these cases:

1. valid counter energy plus battery drop when `batteryDischargingBefore` is true;
2. net charge fallback = charge gain + direct-supply maintenance;
3. net charge fallback with missing direct sample preserves charge gain instead of adding zero as if measured;
4. no capacity gain/decline fallback = adapter input maintenance plus battery drop only when baseline mixed discharge is true;
5. plugged idle with no adapter sample returns `nil`;
6. invalid/missing counter falls back without double-counting charge.

```swift
func testPluggedChargeFallbackDoesNotDoubleCountAdapterInput() throws {
    let input = SleepEnergyCalculator.Input(
        sleepStart: date("2026-09-06 22:00:00"), capacityBeforeMAh: 3000, voltageBeforeV: 12.4,
        adapterConnectedBefore: true, wakeTime: date("2026-09-07 00:00:00"),
        capacityAfterMAh: 6000, voltageAfterV: 12.6, adapterConnectedAfter: true,
        maintenanceDirectPowerW: 20, maintenanceAdapterInputPowerW: 70,
        batteryDischargingBefore: false
    )

    let segment = try XCTUnwrap(SleepEnergyCalculator.segment(from: input))

    XCTAssertEqual(segment.energyKWh, 0.0375 + 20 * 7200 / 3_600_000, accuracy: 0.0000001)
}
```

- [ ] **Step 2: Run the focused tests and verify the old implementation fails.**

Run: `swift test --filter PowerTelemetryEnergyTests`, `swift test --filter SleepEnergyCalculatorTests`, and `swift test --filter PowerTelemetryCalibrationTests`

Expected: the new APIs either fail to compile or the existing fallback returns the old battery-drop-plus-maintenance formula instead of the specified source-aware branch.

- [ ] **Step 3: Implement counter calibration and JSON storage.**

Keep raw counter parsing unchanged. Add the positive finite factor guard to `PowerTelemetryEnergy`, define the calibration context/record/file payload, and implement atomic JSON writes using the same Application Support fallback pattern as history. Select the latest valid calibrated record matching both hardware model and OS context; otherwise return factor `1.0` and `isCalibrated == false`.

- [ ] **Step 4: Implement source-aware sleep calculation.**

Use one average voltage and compute `batteryChargeGainKWh`/`batteryDischargeKWh` from the signed capacity delta. Prefer a validated counter; add battery-drop energy only for `batteryDischargingBefore`. Without a counter, branch on a positive capacity gain: charge gain plus optional direct-supply maintenance. Otherwise use optional adapter-input maintenance plus optional confirmed battery drop. Return `nil` when no positive source component is available. Mark all fallback segments as `.fallbackEstimate`; mark a counter segment calibrated only when a valid calibrated factor was applied.

- [ ] **Step 5: Run the focused tests and preserve existing compatibility tests.**

Run: `swift test --filter PowerTelemetryEnergyTests`, `swift test --filter SleepEnergyCalculatorTests`, `swift test --filter PowerTelemetryCalibrationTests`, and `swift test --filter HistoryPersistenceTests/testV3SleepSegmentWithoutMeasurementMethodDefaultsToFallback`

Expected: all pass, including existing v3 measurement-method decoding and the new default-false calibration decoding.

- [ ] **Step 6: Commit the pure sleep/calibration change.**

```bash
git add Sources/BatteryGlass/Models/PowerTelemetryCalibration.swift Sources/BatteryGlass/Models/PowerTelemetryEnergy.swift Sources/BatteryGlass/Models/SleepEnergyCalculator.swift Sources/BatteryGlass/Models/SleepSegment.swift Tests/BatteryGlassTests/PowerTelemetryEnergyTests.swift Tests/BatteryGlassTests/SleepEnergyCalculatorTests.swift Tests/BatteryGlassTests/PowerTelemetryCalibrationTests.swift
git commit -m "feat: improve sleep fallback and counter calibration"
```

### Task 4: Wire sleep lifecycle, maintenance inputs, and calibration into the monitor

**Files:**
- Modify: `Sources/BatteryGlass/Services/BatteryMonitor.swift`
- Modify: `Sources/BatteryGlass/Support/Extensions.swift`
- Modify: `Tests/BatteryGlassTests/BatteryMonitorIOPSParsingTests.swift`
- Modify: `Tests/BatteryGlassTests/PowerDiagnosticsTests.swift`

**Interfaces:**
- `BatteryMonitor` owns a `PowerTelemetryCalibrationStore` (injectable for tests) and passes its factor/status to `SleepEnergyCalculator.Input`.
- Sleep baseline captures `batteryDischargingBefore` in addition to adapter state/capacity/voltage/counters.
- Maintenance sampling tracks the minimum direct-supply power and the minimum positive adapter-input power independently.
- `handleWillSleep()` posts `.sleepIntervalStarted` after capturing the baseline; `handleDidWake()` posts `.sleepIntervalEnded` immediately after the wake snapshot is recorded, before delayed maintenance sampling completes.

- [ ] **Step 1: Write failing monitor wiring tests.**

Extend parser/diagnostic tests to assert the raw counter remains unsigned and the mixed-source diagnostic fields are emitted. Add a pure test helper or initializer-level test seam showing that the calculator input receives separate adapter-input and direct-supply maintenance values; do not mock IOKit data in pure model tests.

- [ ] **Step 2: Run the focused tests and confirm missing wiring fails.**

Run: `swift test --filter BatteryMonitorIOPSParsingTests` and `swift test --filter PowerDiagnosticsTests`

Expected: existing parser tests remain green while new diagnostic/wiring assertions fail until the monitor fields and event posts are connected.

- [ ] **Step 3: Wire the lifecycle and maintenance data.**

Add the two notification names. In `handleWillSleep`, cancel prior maintenance, capture the signed-source confirmation, store the baseline, and post the start date. In `handleDidWake`, refresh once, capture wake counters/capacity/voltage, post the end date, and then start maintenance. During each maintenance tick, append positive `snapshot.directSupplyPowerW` and positive `snapshot.adapterInputPowerW` separately. Pass both minima, the baseline confirmation, and calibration state into the calculator. Keep the current six-sample cleanup and duplicate-segment notification flow.

- [ ] **Step 4: Run parser, diagnostics, and monitor-state tests.**

Run: `swift test --filter BatteryMonitorIOPSParsingTests`, `swift test --filter PowerDiagnosticsTests`, and `swift test --filter BatteryMonitorStateTests`

Expected: all pass, with no changes to the source-side metric semantics outside the confirmed mixed case.

- [ ] **Step 5: Commit the monitor wiring.**

```bash
git add Sources/BatteryGlass/Services/BatteryMonitor.swift Sources/BatteryGlass/Support/Extensions.swift Tests/BatteryGlassTests/BatteryMonitorIOPSParsingTests.swift Tests/BatteryGlassTests/PowerDiagnosticsTests.swift
git commit -m "feat: wire sleep boundaries and calibrated inputs"
```

### Task 5: Persist intervals, exclude them from store totals, and preserve old history

**Files:**
- Modify: `Sources/BatteryGlass/Stores/BatteryHistoryStore.swift`
- Modify: `Sources/BatteryGlass/Models/EnergyCalculator.swift`
- Modify: `Tests/BatteryGlassTests/HistoryPersistenceTests.swift`
- Modify: `Tests/BatteryGlassTests/HistoryRecoveryTests.swift`
- Modify: `Tests/BatteryGlassTests/HistoryRetentionTests.swift`

**Interfaces:**
- `BatteryHistoryStore` exposes `private(set) var sleepIntervals: [SleepInterval]` only for persistence/test inspection and keeps them out of chart/UI models.
- The store maintains an in-memory `activeSleepStart` while a sleep event is open.
- `record(_:)` calls `EnergyCalculator.dailyEnergyKWh` with completed intervals plus the active interval represented through the current boundary, so the wake sample cannot bridge across sleep.
- `recordSleepInterval(start:end:)` rejects invalid/duplicate ranges, persists valid ranges, and does not change energy totals.
- `recordSleepSegment(_:)` registers its interval before adding segment energy, rejects duplicate IDs, and adds `energyKWh` exactly once.
- History payload moves from version 3 to version 4 with optional `sleepIntervals`; v2/v3 decoding remains valid and old summaries are not recalculated.

- [ ] **Step 1: Write failing store and compatibility tests.**

Add tests that post a start event, record a pre-sleep sample and a wake sample whose timestamps are 30 seconds apart, then assert the daily energy does not include the bridge. Add an exactly-60-second boundary test asserting only the later `SleepSegment` energy is present. Add interval round-trip, duplicate interval, invalid range, and v3-without-intervals tests. Verify loading an old daily summary leaves its energy unchanged.

```swift
func testSleepStartAndWakeSamplesDoNotInterpolateAcrossShortSleep() {
    let start = date("2026-09-06 10:00:00")
    var before = BatterySnapshot()
    before.timestamp = start
    before.isPresent = true
    before.state = .discharging
    before.voltage = 12
    before.current = -2
    before.cycleCount = 1
    store.record(before)

    NotificationCenter.default.post(
        name: .sleepIntervalStarted,
        object: nil,
        userInfo: ["start": start]
    )

    var wake = before
    wake.timestamp = start.addingTimeInterval(30)
    wake.cycleCount = 2
    store.record(wake)

    XCTAssertEqual(store.allSummaries().first?.energyKWh, nil)
}
```

- [ ] **Step 2: Run the focused persistence tests and confirm the failures.**

Run: `swift test --filter HistoryPersistenceTests` and `swift test --filter HistoryRecoveryTests`

Expected: compile failures for missing interval storage/observers or assertions showing the current store still integrates the short sleep bridge.

- [ ] **Step 3: Implement active/completed interval handling.**

Load `sleepIntervals` before recovery, default missing data to an empty array, and set `lastRecordedSample` as today’s last sample. Register observers for start/end events. In pair integration, pass completed intervals plus an active open interval to the pure calculator, or skip the active crossing explicitly. When an end event arrives, create one interval, sort it, persist it, and leave daily energy untouched. Ensure `clearHistory` clears both active and completed interval state.

- [ ] **Step 4: Update payload version and recovery calculation.**

Encode version 4 with optional `sleepIntervals`. Pass stored intervals into `summaries(from:)` and `updateEnergySummaries(from:allowedDayKeys:)` so diagnostics recovery cannot reintroduce excluded sleep bridges. Do not alter pre-existing daily summary values for disallowed historical days. Keep the existing sleep-energy restoration behavior, now guarded by the interval/segment duplicate rules.

- [ ] **Step 5: Run focused persistence/retention/recovery tests.**

Run: `swift test --filter HistoryPersistenceTests`, `swift test --filter HistoryRecoveryTests`, and `swift test --filter HistoryRetentionTests`

Expected: all pass, including v2/v3 compatibility, interval round trips, duplicate segment protection, and unchanged forward-only history behavior.

- [ ] **Step 6: Commit store persistence and exclusion.**

```bash
git add Sources/BatteryGlass/Stores/BatteryHistoryStore.swift Sources/BatteryGlass/Models/EnergyCalculator.swift Tests/BatteryGlassTests/HistoryPersistenceTests.swift Tests/BatteryGlassTests/HistoryRecoveryTests.swift Tests/BatteryGlassTests/HistoryRetentionTests.swift
git commit -m "fix: persist sleep boundaries without rewriting history"
```

### Task 6: Document the accuracy model and perform final verification

**Files:**
- Modify: `README.md`
- Modify: `CHANGELOG.md`
- Test: all `Tests/BatteryGlassTests` tests

**Interfaces:**
- Documentation states the source-side metric, the mixed-source rule, the 60-second unknown interval policy, the fallback branches, the calibration JSON/manual-meter requirement, and forward-only history behavior.

- [ ] **Step 1: Update user-facing accuracy documentation.**

In the existing power/energy sections, state that adapter input is the user’s source-side electricity while plugged in, not `SystemLoad`; explain that confirmed plugged discharge adds the battery source; explain that short sleep is intentionally unknown rather than interpolated; and label no-counter sleep as an estimate. Add the calibration file location and physical watt-meter requirement without promising default counter accuracy.

- [ ] **Step 2: Add changelog entry.**

Record the four precision fixes and explicitly note that old daily summaries are preserved and new logic applies forward-only.

- [ ] **Step 3: Run the full verification suite.**

Run:

```bash
swift test
git diff --check
git status --short --branch
git log -6 --oneline
```

Expected: `swift test` reports 0 failures for the complete suite; `git diff --check` is silent; the status contains only intentional committed/uncommitted documentation changes before the final commit review.

- [ ] **Step 4: Review requirements against the specification.**

Check each requirement in `docs/superpowers/specs/2026-09-06-precision-energy-accounting-design.md`: short interval exclusion, mixed-source confirmation, no-counter branch formulas, calibration persistence/application/status, v2/v3 compatibility, and forward-only history. Inspect `git diff` for accidental UI or `SystemLoad` changes.

- [ ] **Step 5: Run the final full suite after documentation changes.**

Run: `swift test`

Expected: the same complete test count or higher, with 0 failures and exit code 0.

- [ ] **Step 6: Commit the documentation and verified implementation.**

```bash
git add README.md CHANGELOG.md Sources Tests
git commit -m "feat: improve source-side energy accuracy"
```
