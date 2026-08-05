# Changelog

All notable changes to this project are recorded here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project aims to follow [Semantic Versioning](https://semver.org/).

Version lines map to `pubspec.yaml` (`version: <semver>+<build>`). The local
SQLite schema version is tracked separately (see `lib/road_db.dart`, currently
**v12**) and is noted per release when it changes.

## [Unreleased]

Follow-up to 1.3.1, driven by the 2026-07-02 drive: even with the one-at-a-time
alert queue, the driver still couldn't keep pace confirming/correcting alerts,
and the concrete-joint ↔ pothole correction specifically needed a menu tap
while driving.

### Changed — detector (`lib/models.dart`, `lib/detection/detector.dart`)
- **Concrete joint volume cut further**: cooldown 4 s → 7 s, relative gate
  `concreteJointMinRawZ` 2.5 → 3.0, storm guard tightened from "≥5 candidates
  in 30 s" to "≥3 in 20 s" so a jointed-concrete stretch hands off to the
  rough-road classifier sooner instead of continuing to prompt individually.
  Concrete joints were still the dominant alert source after 1.3.1's fix.
- Promoted the pothole cooldown out of an inline magic number (`3000`) into
  `DetectionConfig.potholeCooldownMs` (value unchanged — potholes were not
  implicated as a volume source).
- Firestore data for 2026-07-02 was not available to re-derive these numbers
  precisely (network to Firestore wasn't reachable from this environment);
  treat the new cooldown/storm values as a conservative first pass and
  re-tune from `fetch_firebase_analysis.py` output once a fresh drive is
  recorded against them.

### Changed — alert UI (`lib/main.dart`)
- ~~**Reclassify is now a one-tap button for the common pairs**, not a
  dropdown~~ — superseded on 2026-07-04, see below. The inline "Actually …"
  button squeezed the banner Row past its limit: on a phone the `Expanded`
  title collapsed to ~1 character per line and the banner stretched to full
  screen height (2026-07-04 TestFlight screenshot).
- **Banner rebuilt as two bounded rows (2026-07-04)**: a one-line ellipsized
  header (type · peak-g · age · +queued) and a 32 px horizontally scrollable
  action strip that cannot overflow, so the layout is stable no matter how
  many actions exist.
- **Every correction is now one tap, and the ✎ menu is gone**: the strip is
  Confirm · False alarm · correction chips for ALL other types (each records
  the negative+positive `reclassify` ground-truth pair). The most-confused
  alternate (pothole ↔ joint, speed bump ↔ bump) is placed first so it is
  visible without scrolling; rarer corrections (rough road, turn, lane
  change) just need a swipe of the strip — never a menu.

### Added — manual Firebase upload (2026-07-04, `lib/main.dart`, `lib/recorder.dart`)
- Firestore has received NO trips since 2026-07-01 (verified via the REST
  API): both trip-doc creation and finalisation swallow errors into
  `debugPrint`, so every upload since then failed invisibly while data
  accumulated safely in SQLite.
- After a ride ends, an **"Upload N trips to Firebase"** button now appears
  above Start whenever completed trips are still local-only
  (`firestore_uploaded = 0`), with a spinner while uploading and a
  green/red snackbar reporting success or how many trips remain pending.
  The button clears itself when the automatic background upload succeeds.
- `retryUnuploadedTrips()` now reports success (by re-counting pending trips)
  and exposes `isUploading` / `pendingUploadCount` on the recorder; the count
  refreshes at launch, at ride end, and after finalisation settles.

### Suggested next
- Re-run `fetch_firebase_analysis.py` after a drive on the new thresholds to
  confirm alert volume actually dropped to a driver-manageable rate, and to
  re-check the concrete-joint share of total alerts.
- If volume is still too high, consider a cross-type minimum alert spacing
  (today's fix only tightened concrete joint specifically) — but that trades
  off against missing genuinely back-to-back distinct defects, so it should
  be data-driven rather than guessed.

## [1.3.1] - 2026-07-01

Alert-flood + confirm-UX fix, driven by the 2026-07-01 drive
(trip `Xj0gaXd5VH2uwpHU3equ`): 75 detector alerts in ~3.5 min of driving
(one per ~2.4 s), 72% of them `concrete_joint`, and only ~5% received a
human Confirm/False-alarm.

### Changed — detector (`lib/detection/detector.dart`, `lib/models.dart`)
- **Concrete joint** no longer a texture catch-all: dedicated absolute floor
  (`concreteJointMinPeakG` 0.18 g, was the 0.12 g impulse entry), a new
  relative gate (`concreteJointMinRawZ` 2.5 — joints were the only impulse
  class without one), cooldown 1.5 s → 4 s, and a storm guard (≥5 candidates
  in 30 s = textured surface → stop alerting; rough-road detector owns that).
- **Double-hit bump** no longer double-recorded: if a hit completes a bump,
  impulse classification stops (previously the same impulse could also emit a
  pothole with identical peakG/jerk).
- **Lane change actually detects highway lane changes**: yaw entry 0.12 →
  0.05 rad/s (a 3.5 m lane change at 100 km/h peaks at ~0.08 rad/s — the old
  threshold rejected essentially all of them; today's highway drive logged
  zero), per-phase heading gate 4° → 2°, phase max 2.5 s → 4 s, crossover
  0.8 s → 1.5 s. Noise rejection still enforced by phase duration + integrated
  heading + net-heading + 8 s cooldown (regression-tested).
- **Defect suppression during the manoeuvre**: crossover + phase 2 now
  suppress pothole/joint/bump alerts — that is when tyres straddle the line
  and hit raised markers. Previously suppression started only *after*
  confirmation, when the marker hits had already alerted.
- Turn and lane-change events now carry `speedKmh` (turns uploaded speed 0).

### Changed — alert UI (`lib/main.dart`)
- Prompt banner is now a FIFO **queue shown one at a time**: the visible
  prompt is never replaced mid-glance (the old single slot swapped on every
  new alert, so Confirm could label the wrong event). Per-type display delays
  (pothole 3 s, joint 1.5 s, …) removed — they inverted display order.
- Banner shows **event age** ("· 3s ago", live) and a "+N queued" chip;
  prompts older than 20 s are dropped unshown; severity chip now shows
  physical `peakG` in g (the old banner printed a z-score labelled "g").
- `braking` is recorded but no longer prompts — manoeuvres need no road
  ground truth and only added churn.
- **Reclassify**: new edit (✎) menu on the banner — "It was actually a
  pothole / speed bump / …". Records a NEGATIVE ground truth for the
  detector's type plus a POSITIVE for the corrected type at the same anchor
  (new `GtSource.reclassify`, `RoadRecorder.reclassifyDetectorEvent`). The
  auto-dismiss timer pauses while the menu is open, and all banner actions
  now verify the prompt hasn't rotated before dismissing.

### Added — tests (`test/detector_test.dart`)
- Gentle highway lane change (~0.06 rad/s) is detected, with suppression
  active during phase 2; joint storm collapses to a single alert; double-hit
  bump is not also classified as a second event.

### Suggested next
- Lock down Firestore security rules; rotate the embedded web API key.
- Run dedicated labelled scenario drives (potholes / speed bumps / lane changes)
  instead of only "Normal Drive", then re-derive detection thresholds from the
  new `events` table (precision/recall now measurable — negatives are stored).
- Wire GPS `heading` into the lane-change cross-check (`headingDeg` already plumbed).
- Unify the Firestore sample schema (`z_score` → `zScore`) and update
  `fetch_firebase_analysis.py` in the same change.

## [1.3.0] - 2026-06-30

Detection rewrite + data-collection overhaul. Full detail in
`CHANGES_v1.3.0.md`; motivation in `CODE_REVIEW_2026-06-30.md`.
**SQLite schema → v12.**

### Added
- `lib/detection/detector.dart`: pure, unit-tested `EventDetector`. Wall-clock-free
  (all timing from sample timestamps); classifies impulse events from raw-signal
  physical features (peak g, jerk, duration).
- `test/detector_test.dart`: first-ever tests for pothole / speed bump / concrete
  joint / bump / rough road / turn / lane change, plus gating and determinism.
- Ground-truth model kept separate from detector output: `gps_samples.gt_label`,
  `gt_source`, `gt_is_false`, and `detector_label`.
- Negative labels: the **"False alarm"** button now persists a rejected-detection
  label (previously discarded).
- Queryable event log: new `events` table + `RoadEvent` model, uploaded as a
  Firestore `events` subcollection.
- Canonical event vocabulary (`EventTypes`) with `normalize()`.
- Privacy trimming is now actually applied on upload (`trimDistanceMeters`),
  preserving labelled samples.
- Storage decimation (`storageDecimateHz`) for raw accel samples.

### Changed
- Impulse detection now runs on the RAW vertical signal; the 0.75 s moving average
  is used only for map colour and the sustained rough-road test.
- Pothole/speed-bump/concrete-joint separation now uses jerk (sharpness) +
  absolute g gates in series with a relative (rawZ) gate.
- `potholeSpeedThresholds` made monotonic in speed and physically motivated
  (provisional — retune from labelled data).
- Lane-change detection rebuilt around net integrated heading; both S-curve
  phases must complete before confirming.
- Manual "Mark X" buttons snap the label to the acceleration peak in a
  reaction-time window instead of smearing it across ±5 s.
- Firestore sample flushing is timestamp-based (enables privacy trimming).
- Detection extracted out of `sensor_isolate.dart`; the isolate is now plumbing.

### Removed
- Adaptive sensor-rate sampling (dropped samples at anomaly onset).
- Conflated `is_bump` writes (auto detector + manual button shared one flag).
- `markRangeAsPothole` / `markRangeAsBump` / `markRangeWithLabel` /
  `updateGpsSampleLabel` (recorder) and `_potholeTrackingEnd` auto-tagging.

### Deprecated
- `DetectionConfig.baselineSamplingHz`, `triggerSamplingHz`,
  `adaptivePreTriggerZScore`, `adaptiveBurstDurationMs` (adaptive sampling gone;
  kept for the legacy `unit_test.dart`).

### Security / privacy
- Firestore remains world-readable via the embedded API key — **intentionally not
  addressed in this release** (deprioritised). Track in `CODE_REVIEW_2026-06-30.md`
  §C1 and address before scaling data collection.

## [1.2.0+3] - prior

Baseline before this review. Firestore incremental sample batching (subcollections),
speed-adaptive pothole thresholds, yaw-based turn and lane-change detection, mount
stability / gyro suppression, SQLite schema v11 (`firestore_uploaded`).

<!--
Older versions were not tracked in a changelog. Schema history from
lib/road_db.dart migrations: v2 accel_val · v3 z_score · v4 scenario ·
v5 ax/ay/az · v6 gyro+user_label · v7 vehicle/mount/device/os + gravity/raw/alt ·
v8 is_braking/is_tapping · v9 is_bump · v10 is_lane_change · v11 firestore_uploaded ·
v12 detector_label/gt_* + events table (this release).
-->

[Unreleased]: #unreleased
[1.3.0]: #130---2026-06-30
[1.2.0+3]: #1203---prior
