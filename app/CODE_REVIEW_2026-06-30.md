# Pothole Finder — Code Review

_Focus: the bump / pothole / lane-change detection algorithm and the Firebase recording path. Goal in mind: collect data that can actually improve the algorithm._

Reviewed: `lib/sensor_isolate.dart`, `lib/models.dart` (`DetectionConfig`), `lib/recorder.dart`, `lib/road_db.dart`, `lib/main.dart`, the test suite, and the live Firestore data (93 trips, plus the local `drives_after_update.json` export).

---

## TL;DR — the biggest problems

1. **Your "confirmed" data isn't ground truth.** The events you think are confirmed bumps/potholes/lane changes are mostly the algorithm labeling itself. You can't improve a detector using its own output as the answer key.
2. **"False alarm" throws the label away.** The single most valuable signal for improving precision — "the detector was wrong here" — is never recorded.
3. **The classifier runs on the wrong signal.** Everything keys off one number (Z-score of a 0.75 s smoothed vertical accel), which filters out exactly the sharp, high-frequency content that separates a pothole from a speed bump. The raw high-rate data you already store is ignored by the classifier.
4. **Firestore is wide open and privacy trimming is not applied.** I read your entire trip database — including raw GPS traces of real drives — with no authentication.

Everything below expands on these.

---

## A. Data collection — this is where the goal lives

### A1. The labels are circular (most important)
- `is_lane_change` is written **only** from the detector's own state (`_lastIsLaneChange`). There is no human-confirmed lane-change signal anywhere in the data.
- `is_bump` is **conflated**: `markRangeAsBump()` is called both by the manual "Mark Bump" button *and* automatically whenever the algorithm emits a `bump` alert (`recorder.dart` ~L336). So a `1` in Firestore can mean "human confirmed" or "detector guessed" — indistinguishable.
- Net effect: for two of the three event types you care about, you cannot compute precision/recall or train anything, because the "answer" is the model's own prediction.

**Fix:** record ground truth in a separate, explicit channel from detector output. Every stored event should carry `{source: human|auto, label, confidence}`. Never overwrite a human field with an auto value or vice-versa.

### A2. "False alarm" is discarded
In the anomaly banner (`main.dart` ~L983), **Confirm** writes a label but **False alarm** just dismisses the banner — nothing is persisted. I grepped: there is no `false_alarm` / `reject` / negative-label path anywhere.

You are throwing away the highest-value data you can collect. Negative labels (confirmed false positives) are what let you push the false-positive rate down. Persist them, e.g. `userLabel = 'not_<type>'` on the event sample.

### A3. No labeled scenarios — all 93 trips are "Normal Drive"
Every trip in Firestore that has a `scenario` is `"Normal Drive"`; the rest are blank. There isn't a single controlled run (e.g. a "Speed Bumps" drive over a known bump repeated 10×). So all "confirmed" events are opportunistic taps during ordinary commutes. To actually improve detection you want a handful of **deliberate labeled drives**: known bumps, known potholes, a stretch of scripted lane changes on an empty road, each tagged.

### A4. Manual marks smear labels across ~10 seconds of road
`markRangeAsPothole(now)` labels `[now − 5 s, now + 5 s]`; `markRangeAsBump` uses `[now − 5 s, now + 5 s]` too. That's **10 seconds ≈ 170 m at 60 km/h**, hundreds of samples, all tagged as one pothole. And it's centered on the button press, with **no reaction-time offset** — the real impact was ~1–2 s *before* the press. You lose all localization: you can't tell which sample is the actual impact.

**Fix:** store the raw press timestamp and label a tight, reaction-shifted window (e.g. `[now − 2.5 s, now − 0.5 s]`), or better, snap the label to the vertical-accel peak inside that window during offline processing.

### A5. Label vocabulary and storage are fragmented
The same concept is stored three different ways:
- `userLabel = 'Pothole'` (manual button, Title Case)
- `userLabel = 'pothole'` (Confirm button, lower snake)
- `is_bump` / `is_lane_change` columns (flags)

`'Rough Road'` / `'Concrete Joint'` only exist as `userLabel` strings; `bump` exists as *both* `is_bump` and `userLabel='bump'`. Any analysis has to reconcile all of this. Standardize on **one** label column + a `source` field + a canonical vocabulary.

### A6. Late confirmations can silently never reach Firestore
Batches are immutable docs written once; the periodic flush uploads `samples[flushedCount:]`, and `_finalizeFirestoreUpload` also only writes from `flushedCount` on. If a sample was already flushed and the user *then* taps Confirm (or a manual mark touches an already-flushed sample), the label updates SQLite but **not** the already-written Firestore batch. Some ground truth stays trapped on-device. (Full re-upload via `retryUnuploadedTrips` won't fire either, because the trip is already marked uploaded.)

---

## B. The detection algorithm

### B1. Classifying on the wrong signal (root cause)
Pothole, speed bump, concrete joint, bump, and rough road are all separated by just two things on the **same** signal: a Z-score threshold and an exceedance **duration**. But that signal is `_lastSmoothed` — a **0.75 s moving average** (`_rollingWindowMs = 750`), i.e. a ~1.3 Hz low-pass filter.

A pothole is a sharp, high-frequency (~10–30 Hz) impact; a speed bump is a slower heave. Averaging over 0.75 s deletes precisely the frequency content that distinguishes them, then you try to classify on what's left. Meanwhile you already record raw `ax/ay/az` at 25–100 Hz in `accel_samples`, and the classifier never looks at it.

**Fix:** classify on the raw / high-passed vertical signal — features like peak magnitude, peak **jerk** (da/dt), event duration at native rate, and spectral energy in a band. That single change will do more for pothole-vs-bump separation than any threshold tuning.

### B2. The Z-score baseline is contaminated and non-comparable
The rolling 5-minute mean/σ is updated with the smoothed vertical of nearly every sample (winsorized at ±2.5σ). Two consequences:
- On a rough stretch, σ inflates and the detector **goes numb exactly where the road is worst** — the events raise the bar that's used to detect them.
- Thresholds are in σ, so "how bad is a pothole" depends on how bad the *recent road* was, not on physical acceleration. Labels aren't comparable across trips, vehicles, or mounts — which undermines using the collected data for a global model.

**Fix:** keep a physical-units detector (m/s² / jerk thresholds) in parallel, and/or compute the baseline from a longer, event-excluded reference rather than folding event energy back in.

### B3. The speed-adaptive pothole table calibrates to sampling density, not physics
`potholeSpeedThresholds` peaks at **2.25 in the 40–60 km/h bucket**, and the comment says that's "because that's where the most data was collected." That's tuning sensitivity to how much you drove, not to the physics of impacts — you'll systematically **miss** potholes at speeds you sampled less. Also, deriving thresholds as a P98 of normal samples means ~2% of all normal driving fires *by construction*, i.e. a built-in false-positive floor whether or not a pothole exists. The table is also non-monotonic in a way physics doesn't obviously justify.

### B4. Lane-change detector is fighting noise it created
The design is a yaw-only S-curve state machine. Your own comments are the tell: without the 8 s cooldown it "marks >90% of GPS samples as lane changes" at highway speed. That means, at the chosen thresholds, the signal isn't separable from road/steering noise — the cooldown is a band-aid over a detector that fires constantly.

Specific issues:
- **`laneChangeYawMinRads = 0.12`** is very low — ordinary lane-keeping wander reaches it.
- It **"optimistically confirms"** on phase-2 entry without requiring phase 2 to reach minimum duration (comments ~L708–711). A single opposite-direction blip after one deflection confirms a lane change.
- It **ignores heading**, even though GPS `heading` is recorded. A lane change nets ~0° heading change; a turn nets ~30–90°. Comparing net heading change (or integrating yaw) over the maneuver is far more robust than counting sign reversals.
- It's ~8 hand-tuned magic numbers with **no validation data** (see A1), so you can't tell whether tuning helps.

**Fix:** use integrated yaw / net heading delta as the primary discriminator, require both phases to meet duration, and — critically — get real labeled lane-change drives to tune against.

### B5. Wall-clock time as the physics time base
Durations, cooldowns, and wheelbase timing use `DateTime.now()` rather than sample timestamps. On **synthetic replay** this means the same recording detects differently depending on CPU speed (detection is coupled to real time, not the data's own clock). On device, GC pauses and the adaptive rebind make tick spacing jittery while the logic treats ticks as evenly spaced. Use sample timestamps consistently.

### B6. Adaptive sampling tears down sensors mid-event
When `z > 1.5`, `_rebindSensors()` cancels and re-subscribes gyro/accel/gravity to jump 25→100 Hz, then does it again 1 s later to drop back. You drop sensor events during the resubscribe **right at the onset of an anomaly** — the moment you most need resolution — and churn stream state while `_gravityHistory` / `_accelWindow` persist. Simpler and safer: sample at a fixed high rate and decimate for storage.

### B7. Stale GPS speed drives speed-dependent logic
`_currentGpsSpeedKmh` updates at most 1 Hz (high fidelity), only after the `accuracy > 25` filter, and everything speed-dependent (pothole threshold bucket, wheelbase double-hit timing) uses that possibly-several-seconds-stale value. A pothole right after pulling away from a stop is classified with the wrong speed.

### B8. No tests on the logic you doubt
The unit tests cover math primitives (projection, smoothing window, z-score, color bands) — but there are **zero** tests for bump, pothole, or lane-change detection. That logic lives in one ~300-line closure inside `_startUserAccel` with `DateTime.now()` side effects, so it isn't testable as written. Extract the detector into a pure function `(samples, config) -> events` and you can both unit-test it and replay it offline over your Firebase data.

---

## C. Firebase recording

### C1. Security: the database is open and the API key ships in the app
I read your **entire** `trips` collection unauthenticated, using the web API key from `fetch_firebase_analysis.py` (which itself notes "as long as your Firestore rules allow unauthenticated reads"). There are no `firestore.rules` in the repo. That key is embedded in every built binary. Anyone who has it can read — and quite likely write/delete — all data. Lock down security rules before collecting more; treat the current dataset as public.

### C2. Privacy trimming is defined but never applied
`DetectionConfig.trimDistanceMeters = 200.0` exists only as a constant — it's used **nowhere**. Full `lat/lon` including trip start and end (i.e. home/work) are uploaded. Either implement the trim on the upload path or stop implying it happens.

### C3. Two schemas, drifting field names
Firestore samples use camelCase (`isBump`, `isLaneChange`) mixed with `z_score`; SQLite uses snake_case (`is_bump`, `accel_val`); the older JSON export lacks `is_lane_change` entirely. Every analysis script must special-case all three. Pick one canonical schema and map to it at the boundary.

### C4. Storage shape blocks the analysis you want
Samples are stored as **arrays inside batch docs** (≈30–500 per doc). Good for the 1 MB limit (the subcollection batching is done — nice), but you **cannot query inside arrays**: "give me every sample where `userLabel != null`" requires downloading whole trips and scanning client-side. For a data/ML pipeline, also write each **labeled event** as its own queryable doc (or export to BigQuery). Right now getting at your labels means pulling ~88 KB of typed JSON per batch.

---

## D. Quick wins vs. structural work

**Quick wins (days):**
- Persist "False alarm" as a negative label (A2).
- Split human vs auto labels; stop reusing `is_bump` for both (A1).
- Tighten and reaction-shift manual mark windows (A4).
- Standardize the label vocabulary + add a `source` field (A5).
- Add Firestore security rules; rotate the exposed key; apply or remove trimming (C1, C2).
- Run a few deliberately labeled scenario drives (A3).

**Structural (the real improvement):**
- Move classification onto the raw high-rate signal with jerk/duration/spectral features (B1).
- Extract the detector into a pure, testable, replayable function; run it offline over collected data (B8).
- Rebuild lane-change detection around net heading / integrated yaw (B4).
- Reconsider the σ-based, self-contaminating baseline in favor of physical units for cross-trip comparability (B2).

---

## E. One note on the existing analysis doc
`ALGORITHM_ANALYSIS.md` is partly stale relative to the current code — it describes a 200 ms gyro suppression (now 1500 ms) and a static Z ≥ 4.0 pothole threshold (now the speed-adaptive table). Worth refreshing so it doesn't send future work chasing already-fixed items. Its structural points (warmup cold-start, mount classification, covariance gating from `sandbox.dart` never promoted to the live pipeline) still stand.
