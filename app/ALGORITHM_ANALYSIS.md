# Road Quality Mapper — Algorithm Analysis & Improvement Roadmap

> Prepared from deep code analysis of `sensor_isolate.dart`, `models.dart`, `recorder.dart`, and the test suite.
> Run `fetch_firebase_analysis.py` first to get per-trip statistics that validate the recommendations below.

---

## 1. Current State: What's Already Solid

The existing pipeline is well-structured. Key strengths:

- **Gravity rotation** correctly isolates vertical suspension movement regardless of phone tilt.
- **Winsorized Z-score baseline** (capped at ±2.5σ) prevents extreme outliers from inflating the adaptive window.
- **Turn detection via projected yaw rate** is orientation-independent — it projects the gyro vector onto the gravity axis rather than using raw Z-axis gyro, which would break on tilted mounts.
- **Speed-adaptive double-hit bump** uses actual wheelbase physics (2.0–3.5 m at current speed) to classify speed bumps vs potholes.
- **Multi-class event taxonomy** (pothole, rough road, braking, bump, speed bump, concrete joint) is more granular than most research implementations.

---

## 2. Gaps Found in the Code

### 2.1 Gyro Suppression Window is Too Short

**File:** `sensor_isolate.dart` L192–196

When the gyroscope fires above `gyroThresholdRads` (2.0 rad/s), the code only suppresses for **200 ms**:

```dart
final targetMs = now + 200;  // ← only 200ms
```

But `mountStabilitySuppressMs` is 3000 ms. A user picking up the phone generates a gyro spike followed by seconds of re-settling. 200 ms is nowhere near long enough — the isolate will resume recording during the transition period and generate false positives. **Fix: change this to at least 1500–2000 ms, or match `mountStabilitySuppressMs`.**

### 2.2 Z-Score Cold Start Problem

The 5-minute rolling window means the baseline is unreliable for the **first 5 minutes of every trip**. With `_validVertWindow.length > 10` as the gate, you only need 10 samples but the statistical window doesn't represent road context until it's substantially filled. Early detections (first 2–3 minutes) will have inflated Z-scores on any road above perfect asphalt.

**Fix:** Add a `_warmupPhaseComplete` flag that fires once `_validVertWindow.length > 150` (roughly 1 minute of data at 25 Hz). Suppress pothole/rough-road alerts during warmup, or mark synced samples with `is_warmup: true` so the dashboard can dim them.

### 2.3 `gpsSpeedGateKmh` is 5.0 km/h — Too Permissive

**File:** `models.dart` L227

At 5 km/h you're essentially walking pace. A user carrying their phone to the car, or inching through a parking lot, will be in-scope. This generates false positives, especially during the gyro suppression window mismatch noted above.

**Recommendation:** Raise to **10–12 km/h** for pothole/bump detection, and keep 5 km/h only for rough road classification (which uses a 3-second sustained window and is less susceptible to brief spikes).

### 2.4 No Phone Placement Classification

The code tracks `_gravity` continuously but never classifies *where* the phone is physically located. The gravity vector angle directly encodes placement:

| Gravity vector angle from Z | Placement |
|---|---|
| 0–15° | Flat (dashboard, cupholder flat) |
| 15–60° | Tilted (vent clip, angled dash mount) |
| 60–90° | Upright portrait (windshield suction, cupholder upright) |
| >90° | Inverted (upside-down in cupholder — rare) |

Each placement has a different vibration transfer function. A vent clip wobbles differently than a windshield mount. **Recording placement at trip start and detecting mid-trip shifts gives you per-placement calibration data.**

**What to add to `GpsSample` / `Trip`:**
- `mount_angle_deg`: rolling mean of tilt angle computed from gravity vector
- `phone_placement_class`: `flat` / `angled` / `upright` — derived from `mount_angle_deg` at trip start

### 2.5 Wobbly Mount Detection is Incomplete

The current mount stability check only fires a 3-second suppression when the **gravity vector shifts by > 10°**. This catches hard mount slippage but misses the more common problem: a **resonant wobbly mount** that vibrates in sync with the road.

A wobbly mount has a distinctive signature:
1. Horizontal and vertical vibration are **highly correlated** (the mount amplifies all directions equally).
2. The gravity vector standard deviation over a rolling 5-second window is **consistently elevated** (0.5–3°) rather than stable.

**What to add:**
```
// In SensorProcessor, track a 5-second rolling window of gravity angles
// Compute stdev — if stdev > 1.5° consistently for 10+ seconds:
//   → set isMountWobbly = true
//   → tag all gps_samples with is_suspect_mount: 1
//   → reduce anomaly confidence score, don't suppress entirely
```

The covariance gating logic already exists in `sandbox.dart` as an experiment — it should be promoted into the live pipeline as a mount quality score.

### 2.6 No Passive Background Operation

This is the largest gap for the end goal. The current design has two blockers:

**Blocker A — `wakelock_plus`:** The app holds a wakelock to keep the CPU running. On iOS, background apps cannot hold arbitrary wakelocks. The screen will sleep and the app will be suspended.

**Blocker B — No background task registration:** iOS requires apps to declare background modes (`UIBackgroundModes`) and use `BGTaskScheduler` / `CLLocationManager` significant-change updates to stay alive.

**What's needed for true passive background:**

1. **iOS Info.plist:** Add `location` and `processing` to `UIBackgroundModes`.
2. **Replace `wakelock_plus` with a foreground service:** On iOS use a background location task. On Android use a foreground service notification with `flutter_foreground_task`.
3. **CLLocationManager significant-change API:** When the app is fully suspended, iOS wakes it on significant location changes (~500 m). Use this as a heartbeat to flush SQLite and check if the device is in a moving vehicle.
4. **Motion Activity API (`CMMotionActivityManager`):** iOS provides automotive activity detection natively. Use `flutter_activity_recognition` to only activate the full sensor pipeline when the OS reports `automotive` confidence, and suspend it on `stationary`/`walking`. This eliminates battery drain during non-drive periods.
5. **Remove the wakelock for battery saver mode:** The adaptive sampling already has `batterySaverBaselineHz = 10.0` but it's never triggered because the wakelock prevents sleep. Tie battery saver mode to a low-power background state.

### 2.7 No Passive Touch/Interaction Detection

`isTapping` is currently set only when the user manually presses the on-screen annotation button. There is no passive detection of accidental phone touches, pick-ups, or pocket bumps.

**What you can detect passively:**

1. **Phone pick-up:** Sudden simultaneous spike in all three axes (ax, ay, az all > 0.5g together) followed by a rapid gravity vector rotation. Signature: total user acceleration magnitude > 1.5g lasting < 300 ms while gyro spikes.

2. **Pocket/bag bounce:** The gravity vector is unstable (not converging to ~1g) and all axes have high noise but no GPS speed increase. Detect by checking `|gravity_magnitude - 9.81| > 1.5` sustained for > 2 seconds.

3. **Screen tap (capacitive):** Flutter's `GestureDetector` can catch taps even in background if the app has a foreground service with a notification. Alternatively, the micro-jolt from finger contact on a rigid phone mount is detectable as a brief impulse spike (< 50 ms, high frequency, all axes similar magnitude). This is more reliable than capacitive detection.

**What to log:**
- Add `is_handling: bool` to `GpsSample` — true when any of the above is detected.
- Store `handling_type: String` (`pickup`, `pocket`, `tap`) for analysis.

### 2.8 Altitude Data is Collected but Never Used

Every `GpsSample` stores `altitude` and `altitudeAccuracy` but the algorithm never uses it. Altitude changes cause gravity vector drift on steep hills — the mount stability checker will wrongly suppress data on mountain roads.

**Fix:** Subtract expected gravity-vector change due to altitude gradient from the stability check. If altitude is changing at > 5 m/s (steep descent), tolerate up to 20° gravity drift before suppressing.

### 2.9 Firestore Document Size Risk

**File:** `recorder.dart`

The entire trip is stored as a single Firestore document with all GPS samples in an `array`. Firestore has a **1 MB document size limit**. A 1-hour trip at 1 Hz GPS = 3600 samples × ~400 bytes per sample ≈ 1.4 MB. This will silently fail to sync for long trips.

**Fix:** Split into subcollections: `trips/{tripId}/samples/{batchId}` with 500 samples per batch document. This also enables incremental syncing during a trip rather than one atomic upload at the end.

---

## 3. Algorithm Improvements

### 3.1 Speed-Adaptive Anomaly Thresholds

The current pothole threshold (Z ≥ 4.0) is static. At high speed (> 80 km/h), a pothole generates a much sharper impact pulse. At low speed (< 20 km/h), the same physical pothole produces a lower Z-score because the suspension has more time to travel through the defect.

**Improvement:** Scale the pothole threshold by speed:
```
adjustedThreshold = 4.0 * (1.0 - 0.15 * clamp((speedKmh - 30) / 70, -0.5, 0.5))
// At 30 km/h: threshold stays 4.0
// At 100 km/h: threshold drops to ~3.4 (easier to trigger — faster hits are sharper)
// At 10 km/h: threshold rises to ~4.45 (harder to trigger — slow hits are softer)
```

### 3.2 Per-Mount-Type Baseline Calibration

The data you need from Firebase (see `fetch_firebase_analysis.py`) is `mount_type_baselines` — the mean Z-score observed per mount type across all trips. A vent clip consistently generates more vibration than a windshield suction mount.

Once you have those baselines, inject a per-mount Z-score offset into `DetectionConfig`:

```dart
static const Map<String, double> mountBaselineOffsets = {
  'Vent Clip':        0.15,   // vent resonance adds baseline noise
  'Windshield Suct':  0.05,
  'Dashboard Pad':    0.08,
  'Stiff Mount':      0.0,    // reference baseline
};
```

### 3.3 Promote Covariance Gating into the Live Pipeline

`sandbox.dart` implements a horizontal/vertical covariance gate as an experimental filter. The idea: if horizontal (X/Y) and vertical (Z) acceleration are **strongly correlated (r > 0.7)**, the vibration source is the mount vibrating as a rigid body — not the road. This cleanly eliminates most wobbly-mount false positives.

The gate should run as a rolling 2-second Pearson correlation check and inject `is_mount_artifact` into the GPS sample.

### 3.4 Barometric Pressure for Bridge/Tunnel Context

Adding `sensors_plus` barometer support (available on iOS 8+ and most Android devices) gives you:

- **Bridge detection:** Altitude increase followed by flat section followed by equal decrease, no GPS accuracy degradation.
- **Tunnel detection:** GPS accuracy drops to > 25 m (already dropped from processing), but barometric pressure changes match expected altitude. Mark these segments as `gps_degraded`.
- **Gradient correction:** Use barometric altitude rate of change (m/s) to correct the gravity projection on steep hills.

### 3.5 Vehicle Motion State Machine

Replace the binary speed gate with a proper motion state machine:

```
STATES: parked → accelerating → cruising → braking → parked
```

Transitions driven by GPS speed + horizontal acceleration. Key benefit: you can calibrate the Z-score baseline **per state** — a vehicle braking hard has different vertical vibration characteristics than one cruising. The rough road detector wrongly fires during aggressive acceleration/braking on smooth roads because the baseline hasn't settled.

---

## 4. Data You Need From Firebase to Validate All of This

Run `fetch_firebase_analysis.py` — it produces exactly these metrics. Key things to look at in the output:

| What to check | Why it matters |
|---|---|
| `mount_type_baselines` | Quantifies how much each mount type adds to baseline noise — feeds per-mount calibration |
| `mean_mount_wobble` per trip | Validates whether the gravity-stdev wobble detector is well-calibrated |
| `low_speed_high_z_count` | Direct count of false positives at low speed — tells you if the speed gate (5 km/h) is too low |
| `z_p99` distribution across trips | If P99 is consistently > 6, the pothole threshold (4.0) is catching normal road variation |
| `gps_accuracy_p90_m` | If P90 > 20 m, the 25 m accuracy cutoff is dropping too much data — loosen to 35 m |
| `braking_events` vs `vehicle_baselines` | High braking counts on smooth roads = braking detector too sensitive on heavy vehicles |
| `altitude_range_m` | Trips with > 100 m elevation change are candidates for gravity drift false suppression |
| Color distribution (% red/orange) | Should be < 5% red on a typical urban commute. Higher = threshold too loose or mount issue |

### Additional Data to Start Collecting (Not Yet in Schema)

These fields should be added to `gps_samples` for future analysis:

| Field | Type | Purpose |
|---|---|---|
| `is_warmup` | bool | Flags samples from the first 60 seconds of a trip |
| `is_handling` | bool | Passive pick-up / pocket detection |
| `handling_type` | string | `pickup` / `pocket` / `tap` |
| `mount_wobble_score` | double | Rolling 5s gravity stdev in degrees |
| `phone_placement` | string | `flat` / `angled` / `upright` |
| `horiz_vert_correlation` | double | Covariance gate value (−1 to 1) |
| `motion_state` | string | `parked` / `accelerating` / `cruising` / `braking` |
| `barometric_altitude` | double | Barometer reading if available |
| `is_mount_artifact` | bool | Covariance gate suppression flag |

---

## 5. Priority Order for Implementation

| Priority | Change | Impact |
|---|---|---|
| 🔴 **P0** | Fix gyro suppression window: 200 ms → 1500 ms | Eliminates a major false positive source right now |
| 🔴 **P0** | Raise speed gate to 10–12 km/h for pothole/bump | Eliminates low-speed false positives |
| 🔴 **P0** | Fix Firestore document size (subcollection batching) | Prevents silent data loss on long trips |
| 🟠 **P1** | Add warmup phase flag (suppress alerts for first 60s) | Reduces noisy trip-start detections |
| 🟠 **P1** | Phone placement classification from gravity angle | Enables per-placement calibration, feeds mount wobble |
| 🟠 **P1** | Promote covariance gating into live pipeline | Eliminates wobbly-mount false positives structurally |
| 🟡 **P2** | Passive background operation (BGTaskScheduler + foreground service) | Required for end-goal passive operation |
| 🟡 **P2** | Motion activity API (automotive detection) | Eliminates non-driving battery drain |
| 🟡 **P2** | Speed-adaptive anomaly thresholds | Improves precision at highway and low speeds |
| 🟢 **P3** | Per-mount-type baseline offsets (after Firebase data collected) | Reduces false positives per mount type |
| 🟢 **P3** | Barometric pressure integration | Tunnel/bridge context, gradient correction |
| 🟢 **P3** | Vehicle motion state machine | Better baseline calibration during acceleration |
| 🟢 **P3** | Passive interaction detection (pickup/pocket) | Better data quality flagging |
