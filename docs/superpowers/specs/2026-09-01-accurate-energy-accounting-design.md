# Accurate Energy Accounting Design

**Goal:** Measure the computer's total energy use using battery discharge while on battery and adapter input while externally powered, including sleep intervals.

## Scope and metric

The product metric is source-time energy, not strict wall-meter energy over a battery charge cycle:

- Battery-powered operation contributes battery discharge energy.
- External-powered operation contributes adapter input energy, including charging and conversion loss.
- A mixed state (external power present while the battery is discharging) must preserve both measurable source contributions and must not silently discard the battery contribution.
- A sleep interval must be counted once, separately from awake samples, and must retain the measurement method and whether it is estimated.

This metric intentionally follows the user's selected B definition. It can count energy once at the adapter while charging and again at the battery while later discharging; that is source-time accounting rather than a battery-cycle energy balance.

## Measurement hierarchy

1. During awake operation, integrate the best available instantaneous source power at the existing sampling cadence.
2. Around sleep, capture raw power-telemetry accumulators before sleep and after wake. Use a counter delta only after its monotonicity, reset behavior, and unit conversion are validated against awake telemetry.
3. If a validated counter delta is unavailable, use source-specific battery capacity/current fallbacks. Mark those segments as estimated.
4. Never manufacture zero energy from a missing counter or missing post-wake adapter sample; retain an unknown/estimated result instead.

## Data flow

`BatteryMonitor` will parse instantaneous telemetry plus raw cumulative fields into a small value type. The sleep baseline will include the power state, source flags, capacities, voltages, and cumulative counters. On wake, the monitor will calculate an energy result, post one sleep segment, and resume ordinary sampling without integrating across the sleep gap.

`SleepEnergyCalculator` remains pure and will accept optional counter deltas plus fallback inputs. It will return source components, total energy, calculation method, and an estimate flag. `BatteryHistoryStore` will add only the returned total to daily summaries, reject duplicate segment IDs, and honor `recordHistory` consistently.

## Counter safety

The `PowerTelemetryData` cumulative fields are private/undocumented registry data. The implementation must treat raw values as untrusted:

- parse them without lossy signed conversion;
- reject non-monotonic, reset, overflow, or implausibly large deltas;
- keep a single conversion function with tests;
- fall back to the existing calculation when validation fails;
- preserve raw counter values in diagnostics so the scale can be validated on real hardware.

## Testing and validation

Pure tests will cover counter deltas, counter resets, source selection, external-plus-discharging sleep, missing counters, and daily splitting. Store tests will cover duplicate protection and history-recording settings. A physical watt-meter comparison remains required to validate the counter scale and quantify residual error on each Mac model.
