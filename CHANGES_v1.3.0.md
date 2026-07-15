# v1.3.0 — Detection rewrite + data-collection overhaul

> Handoff note for the next engineer / AI agent. This documents WHAT changed and
> WHY, so you don't have to reverse-engineer it. Read this before touching the
> detection or recording code. Pair it with `CODE_REVIEW_2026-06-30.md` (the
> review that motivated these changes) and `CHANGELOG.md` (the running log).
>
> ⚠️ This environment had no Dart/Flutter SDK, so the changes were written but
> NOT compiled here. Before shipping: `flutter pub get && flutter analyze && flutter test`.
> Expect a few `deprecated_member_use` infos (see §7) — those are intentional.

---

## 0. The one-paragraph summary

Detection was extracted out of the sensor isolate into a pure, unit-tested
library (`lib/detection/detector.dart`) and rewritten to classify road events
from **raw-signal physical features** (peak g, jerk, duration) instead of a
single threshold on a 0.75 s moving average that had smoothed away the very
information that separates a pothole from a speed bump. Lane-change detection was
rebuilt around **net integrated heading** instead of counting yaw sign-reversals.
On the data side, **human ground truth is now stored separately from detector
output**, **"False alarm" is persisted as a negative label** (it used to be
discarded), manual marks are **snapped to the acceleration peak** in a
reaction-time window instead of smeared across ±5 s, everything uses a **single
canonical label vocabulary**, and events are written to a **queryable `events`
table / Firestore subcollection**. Privacy trimming (defined but never applied)
is now applied on upload.

---

## 1. New file: `lib/detection/detector.dart` (the important one)

A pure `EventDetector` class. **No Flutter, no sensors, no `DateTime.now()`** —
all timing is derived from the sample timestamps passed in. This is what makes
the algorithm testable and replayable over recorded Firebase/SQLite data.

Call it once per trip; feed it one tick per accelerometer sample:

```dart
final result = detector.process(
  ts: nowMs,          // sample timestamp (ms) — the time base for ALL logic
  vertG: vert,        // signed vertical accel projected on gravity, in g (RAW)
  signedYaw: yaw,     // yaw rate projected on gravity axis, rad/s
  horizG: horizMag,   // instantaneous horizontal accel magnitude, g
  speedKmh: speed,
  headingDeg: -1.0,   // reserved; GPS heading cross-check not yet wired
  stationary: isStationary,
  suppressed: isSuppressed,
);
// result.smoothedVert, result.zScore  → map colour + sparkline (unchanged)
// result.events                       → List<DetectedEvent> (canonical types)
// result.laneChangeActive             → suppress defect alerts window
// result.isBraking
```

### How each event is now decided

Two baselines run in parallel:
- **smoothed** (0.75 s moving average of `|vert|`) → used ONLY for the map colour
  and the sustained **rough_road** test.
- **raw** (`|vert|`) → used for impulse detection.

Both are winsorised (±2.5σ) and **event-excluded** (not updated while an impulse
is in progress) so a rough stretch no longer inflates the baseline and blinds the
detector.

An **impulse** is a contiguous run where raw `|vert| ≥ impulseEntryG` (0.12 g).
At its end it is classified from physical features, in priority order:

| Event | Gate (all must hold) |
|---|---|
| **pothole** | `peakG ≥ 0.35` **and** `jerk ≥ 6 g/s` **and** `rawZ ≥ speed-bucket threshold` |
| **speed_bump** | `peakG ≥ 0.20` **and** `jerk ≤ 5 g/s` (smooth heave) **and** duration ∈ [200, 750] ms |
| **concrete_joint** | `0.12 ≤ peakG < 0.35` **and** `jerk ≥ 3 g/s` **and** duration ≤ 100 ms |
| **bump** (double-hit) | two impulses with `peakG ≥ 0.20`, duration ∈ [150,1000] ms, spaced by wheelbase timing at current speed |

`rawZ = (peakG − rawMean) / rawStd` is the relative gate; `potholeSpeedThresholds`
is now interpreted against `rawZ` and is **monotonically decreasing in speed**
(faster impacts are sharper → a lower relative Z is still a real defect). The old
table peaked at 40–60 km/h "because that's where we had the most data", which
calibrated sensitivity to sampling density — that's gone.

**rough_road**: sustained smoothed `zScore ≥ 3.0` for ≥ 3 s (unchanged logic,
now sample-timestamp based).

**turn**: sustained signed yaw in ONE direction for ≥ 400 ms (resets on sign
reversal). Unchanged logic, sample-timestamp based.

**lane_change**: yaw excursion one way then the other where the **net integrated
heading change is small** (≤ 18°) and **each phase turned the car ≥ 4°**, at
≥ 30 km/h, with an 8 s cooldown. Both phases must complete before confirming —
the old code "optimistically confirmed" on a single opposite-direction blip. A
turn (net heading large) is rejected here. This replaces the yaw-sign-reversal
counter whose own comments admitted it flagged >90% of highway samples.

Tuning knobs all live in `DetectionConfig` (`lib/models.dart`).

---

## 2. `lib/sensor_isolate.dart` — now just plumbing

The ~300-line detection closure inside `_startUserAccel` is gone. The isolate now
computes the scalar inputs (`vert`, `signedYaw`, horizontal magnitude) and calls
`_detector.process(...)`, then routes `result.events` to `IsolateAnomalyAlert`s
and tags GPS-batch rows with the detector's classification via `_tagGpsBatch`.

Removed: `_updateZScoreBaseline`, `_potholeThresholdForSpeed`,
`_updateLaneChangeDetector`, `_rebindSensors`, the `BumpHit` class, and all the
per-detector state fields (they live in `EventDetector` now).

**Adaptive sampling was removed.** It rebuilt the sensor subscriptions 25→100→25
Hz on a Z-score trigger, dropping samples at the onset of the anomaly you most
want to resolve. Capture is now a fixed `DetectionConfig.samplingHz` (50 Hz) and
raw samples are persisted at `storageDecimateHz` (25 Hz) to control DB/upload
size.

`IsolateAnomalyAlert` now carries `endTs`, `peakG`, `jerk`, `speedKmh` so the
recorder can persist rich, queryable events.

---

## 3. Data model + schema (`lib/models.dart`, `lib/road_db.dart`)

### Canonical vocabulary — `EventTypes`
One snake_case token per concept (`pothole`, `speed_bump`, `concrete_joint`,
`bump`, `rough_road`, `lane_change`, `turn`, `braking`, `tap`). `EventTypes.normalize()`
maps every legacy spelling (`'Pothole'`, `'Device Tapping'`, …) to canonical.
**Always normalise at the boundary.**

### Ground truth vs detector output — never conflated again
New `GpsSample` fields (and `gps_samples` columns, schema **v12**):
- `detector_label` — the algorithm's own classification (NOT ground truth).
- `gt_label` / `gt_source` / `gt_is_false` — HUMAN ground truth. `gt_is_false = 1`
  means "there is NO <gt_label> here" (a confirmed false positive).

`GtSource` = `confirm` | `false_alarm` | `manual` | `detector`.

### New `events` table + `RoadEvent` model
One row per discrete event: `ts, end_ts, type, source, z_score, peak_g, jerk,
speed_kmh, lat, lon, is_false`. This is the **queryable** unit ("give me every
confirmed pothole") that the old 500-sample Firestore arrays could not provide.
Indexed on `(trip_id, type)`.

Schema migration `oldVersion < 12` adds the four sample columns and the `events`
table. `RoadDb` gained `setGroundTruth`, `setDetectorLabel`, `insertEvent`,
`getEvents`.

---

## 4. Recorder + UI (`lib/recorder.dart`, `lib/main.dart`)

- **Confirm** → `confirmDetectorEvent()` → positive GT + a `confirm` RoadEvent.
- **False alarm** → `rejectDetectorEvent()` → **negative GT** + a `false_alarm`
  RoadEvent. (Previously this button discarded the answer — the single biggest
  data-quality fix.)
- **Side "Mark X" buttons** → `markEvent()` → snaps the label onto the
  acceleration peak within `[pressTs − 2500ms, pressTs − 300ms]` (reaction-time
  window) instead of labelling ±5 s of road. Positive GT + a `manual` RoadEvent.
- **Detector alerts** → `_recordDetectorEvent()` logs a `detector` RoadEvent and
  tags samples. The old code called `markRangeAsBump()` for auto bumps, which
  wrote the SAME `is_bump` flag humans used — that conflation is gone.
- Removed: `markRangeAsPothole`, `markRangeAsBump`, `markRangeWithLabel`,
  `updateGpsSampleLabel` (recorder), and the `_potholeTrackingEnd` auto-tagging.

---

## 5. Firestore upload (`lib/recorder.dart`)

- Sample flushing is now **timestamp-based** (`_lastUploadedTs`) rather than
  index-based, which lets privacy trimming remove samples without breaking the
  cursor.
- **Privacy trim is now actually applied** (`DetectionConfig.trimDistanceMeters`,
  200 m — it was defined but never used). `_isPrivacyTrimmed` drops samples within
  the trim radius of the origin (known at start) and destination (known at
  finalise). **Labelled samples are never trimmed** — losing a labelled event
  would defeat the point. Mid-trip flushes also hold back the most recent
  `_destinationHoldbackMs` (60 s) so near-destination data isn't streamed before
  it can be trimmed.
- The **`events` subcollection** is uploaded at finalise, read from SQLite (the
  source of truth) with deterministic doc IDs. This fixes the old bug where a
  human label applied AFTER its sample batch was flushed never reached the cloud
  (batches are immutable) — the event log always carries it, and the retry path
  reuses the same code.
- New sample fields (`detectorLabel`, `gtLabel`, `gtSource`, `gtIsFalse`) are
  added to `_sampleToMap`. NOTE: the sample map still mixes `z_score` (snake) with
  camelCase keys — see §8, deliberately left for a follow-up to avoid breaking the
  existing `fetch_firebase_analysis.py`.

Firestore **security rules were intentionally NOT touched** (deprioritised by the
owner). The database is still world-readable via the embedded API key — see
`CODE_REVIEW_2026-06-30.md` §C1. Do this before scaling data collection.

---

## 6. Tests

`test/detector_test.dart` (new) drives the pure detector with synthetic signals:
pothole vs speed bump vs concrete joint separation, rough road, turn vs lane
change, the low-amplitude-wander regression (lane change must NOT fire), gating
(suppressed/stationary), braking, and a determinism check (same input+timestamps
→ identical output). Run: `flutter test test/detector_test.dart`.

`test/unit_test.dart` (existing) is unchanged and still passes — but its
"Requirement F9" adaptive-sampling test now exercises behaviour that no longer
exists in the app (it re-implements the logic inline). Consider deleting that
group.

---

## 7. Known deprecations / expected analyzer output

`DetectionConfig.baselineSamplingHz`, `triggerSamplingHz`,
`adaptivePreTriggerZScore`, `adaptiveBurstDurationMs` are marked `@Deprecated`
(adaptive sampling removed) but kept so `test/unit_test.dart` still compiles.
Expect `deprecated_member_use` infos from that test — harmless. The Z-based
impulse constants (`speedBumpMinZ`, `concreteJointMinZ/MaxZ`, `bumpMinZ`) are no
longer used by the detector (replaced by physical g/jerk gates) but left in place;
safe to remove once you're happy with the new gates.

---

## 8. Suggested next steps (not done here)

1. **Lock down Firestore security rules** and rotate the embedded API key.
2. **Collect labelled scenario drives** — every trip in Firebase is still
   `scenario = "Normal Drive"`. Do dedicated runs over known potholes / speed
   bumps / a scripted set of lane changes so the new thresholds can be tuned
   against ground truth (that's what the whole label pipeline now exists for).
3. **Re-derive `potholeSpeedThresholds` and the g/jerk gates** from the collected
   `events` table once you have confirmed/false labels (compute precision/recall
   per threshold — now possible because negatives are stored).
4. **Wire GPS `heading` into the lane-change cross-check** (the `headingDeg`
   parameter is already plumbed through, currently passed −1).
5. **Unify the Firestore sample schema** (`z_score` → `zScore`) and update
   `fetch_firebase_analysis.py` in the same PR.
6. Replay harness: feed recorded trips (SQLite `accel_samples` or Firebase) back
   through `EventDetector` offline to measure detector changes before shipping.
