# Alert System v2 — Evidence-Based Labelling (Design)

> Problem statement (2026-07-06): alerts pile up during driving, and after a few
> seconds the driver can no longer remember whether an alert was real. The goal
> is to reliably know that a bump/pothole happened when we hit one.

---

## 1. Why the current approach cannot be patched further

The v1.3.x alert system asks the **driver's memory** to be the ground-truth
sensor, in real time, while they drive. Three iterations of tuning
(cooldowns 1.5s→4s→7s, storm guards, FIFO queue, ×N grouping, 10s timeouts)
all attack symptoms of the same root cause:

1. **The confirmation window is human reaction time.** A prompt must be seen,
   remembered, matched to a physical jolt, and answered — all within ~10s,
   while driving. Drive data shows ~5% of alerts get any response.
2. **Memory decays faster than the queue drains.** By the time prompt #2 is
   promoted, the driver can't distinguish it from prompt #3's jolt. Stale
   labels are worse than no labels.
3. **Attention is a safety budget.** Every improvement that increases response
   rate (bigger buttons, more prompts shown) spends more driver attention.
   That trade is capped, and we've hit the cap.

Conclusion: **stop requiring a decision at drive time.** Capture *evidence* at
the moment of impact, and move the human decision to a moment when the human
is good at it (parked, trip over, full context on screen).

---

## 2. Options considered

### Option A — Camera evidence capture + post-trip review  ✅ recommended

The phone is windshield/dash-mounted with the rear camera facing the road
(user-confirmed typical setup). A pothole passes through the camera's view
**~0.5–2s *before* the wheels hit it** (at 30–100 km/h, a defect visible 10–30m
ahead). So a continuously running **frame ring buffer** holds exactly the
evidence a human needs: what the road looked like right before the jolt.

On every detector event:
- Freeze the ring buffer's pre-impact frames (+ ~1.5s of post-impact frames).
- Snapshot the vertical-acceleration trace ±4s around the impact.
- Persist both as an *evidence packet* bound to the detector event.

After the trip, a **review screen** shows each event with its frames (scrub
with a slider), the accel waveform, severity, and speed. One tap confirms,
rejects, or reclassifies — with *evidence* on screen, memory is not needed at
all, and a whole trip can be reviewed in under a minute.

- Pros: ground-truth quality goes up (evidence beats memory); driver attention
  during the drive goes to ~zero; works offline; frames double as future ML
  training data (vision model, Option E).
- Cons: camera adds battery cost (~5–8%/h at 480p preview); needs the camera
  permission; evidence is weaker at night / heavy rain (sensor trace still
  captured); useless when the phone is in a cupholder (degrades gracefully to
  sensor-trace-only packets).

### Option B — Real-time on-device vision confirmation (TFLite)

Run a pothole-detection model on the camera stream; only alert when IMU spike
AND vision agree. Strongest long-term answer, but it needs a trained model —
which needs labelled data — which is exactly what Option A produces. Phase 2:
the review screen's confirmed frames are the training set. Do not build first.

### Option C — Voice confirmation ("Pothole — say yes or no")

Hands-free, but speech in a moving car (road noise, music, passengers) is
unreliable; TTS every ~7s is far more annoying than a banner; still spends
real-time attention; still relies on the driver having felt/remembered the
event. Rejected as primary; can be added later on top of A for power users.

### Option D — Cross-trip corroboration (auto-labelling, no human at all)

The same pothole produces spikes at the same GPS location on repeated passes.
N≥2 detections within ~15m across different trips ⇒ auto-confirm; a location
that alerts once in 50 passes ⇒ auto-reject. Zero driver cost and it improves
with fleet size — but it needs many repeat passes, can't label one-off events,
and does nothing for today's single-driver data volume. **Adopt as a cheap
Phase-1.5 addition** (it's a Firestore query, not an app feature); not a
replacement for A.

### Option E — Keep real-time prompts, tune harder

Rejected — see §1. Three versions of evidence say this asymptotes at ~5%
response rate.

---

## 3. Chosen architecture (Option A, with D as follow-up)

```
                     ┌────────────── during drive ──────────────┐
IMU pipeline ──► AnomalyEvent ──► EvidenceService ──► evidence packet (SQLite + files)
                     │                  ▲
                     │           camera frame ring buffer
                     │           (pre-impact road view)
                     ▼
              Passive ticker (glanceable, no response required)

                     ┌────────────── after drive ───────────────┐
Trip stop ──► Review screen: frames + waveform per event ──► confirm / reclassify /
                                                             false alarm  (GT rows)
```

### 3.1 EvidenceService (`lib/evidence/evidence_service.dart`)

- Owns a `CameraController` (rear camera, 480p, `startImageStream`).
- Maintains a ring buffer of the last **8s of frames at ~4 fps** (raw YUV/BGRA
  bytes; ~15–20 MB RAM at 480p — bounded and constant).
- Maintains a ring buffer of the last 8s of `AccelSample`s from the recorder.
- On `AnomalyEvent` (road-surface types only): waits ~1.5s to collect
  post-impact frames, then converts the ~20 selected frames to JPEG **in a
  background isolate** (`compute` + `package:image`) and writes them to
  `<app-docs>/evidence/trip_<id>/event_<ts>/frame_<ts>.jpg`.
- Persists an `evidence` row (SQLite): frame timestamps, sensor trace JSON,
  `review_status='pending'`.
- Degrades gracefully: no camera / no permission / macOS ⇒ sensor-trace-only
  packets, review still works (waveform is often enough to spot a false alarm
  from phone handling).
- Storage bounded: evidence directories deleted after review (or on trip
  deletion); a whole trip's unreviewed evidence is ~1–2 MB per event.

### 3.2 Persistence (`road_db.dart` v13)

```sql
CREATE TABLE evidence (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  trip_id INTEGER NOT NULL,
  event_ts INTEGER NOT NULL,          -- anchors to events.ts (detector row)
  event_type TEXT NOT NULL,           -- detector's label at capture time
  dir TEXT,                           -- frame directory (NULL = no camera)
  frame_count INTEGER DEFAULT 0,
  trace_json TEXT,                    -- [[ts, vertAccel, z], ...] ±4s
  peak_g REAL DEFAULT 0, z_score REAL DEFAULT 0, speed_kmh REAL DEFAULT 0,
  lat REAL, lon REAL,
  review_status TEXT DEFAULT 'pending',  -- pending|confirmed|reclassified|false_alarm
  review_label TEXT,                  -- final human label when reviewed
  reviewed_at INTEGER
);
```

Review verdicts reuse the existing ground-truth machinery (`setGroundTruth`,
`insertEvent` with `GtSource.confirm/false_alarm/reclassify`), so the
dashboard, Firestore upload, and training exports see post-trip labels exactly
like the old live labels — no downstream changes.

### 3.3 Live UI: passive ticker (replaces the prompt queue)

The in-drive banner becomes **informational only** — it never asks a question:

- Shows the latest detection (icon, type, severity, "3s ago") plus a
  per-trip counter and an `● evidence` dot when a packet was captured.
- Auto-fades after ~6s idle. New events replace the content (nothing is lost —
  every event is in the evidence queue for review).
- One *optional* affordance: an ✗ button records an immediate false-alarm
  (for the obvious cases — driver just adjusted the mount). No timeout, no
  queue, no obligation; skipping it costs nothing because review catches it.

### 3.4 Post-trip review (`lib/review.dart`)

On Stop, if pending evidence exists the app offers "Review N events". Each
card: frame scrubber (slider across the captured frames, impact moment
marked), accel waveform with the impact centered, severity/speed chips, then
one-tap verdicts: **Confirm ✓ · type chips (reclassify) · False alarm ✗**.
Bulk action: "everything else was real / false" for fast clearing. Verdicts
write GT rows and delete the frames.

---

## 4. Why this meets the goal

"Know a bump/pothole when we hit one" means high-quality confirmed labels:

| | v1.3.x live prompts | v2 evidence review |
|---|---|---|
| Response rate | ~5% of alerts | Every event reviewable; 100% of reviewed |
| Label quality | Memory under time pressure | Visual + waveform evidence, no time pressure |
| Driver attention | Constant interruption | Glanceable ticker, zero required interaction |
| Night/rain | Same | Waveform-only fallback |
| Path to automation | None | Confirmed frames feed the Phase-2 vision model; Phase 1.5 cross-trip corroboration auto-labels repeat hits |

## 5. Phasing

1. **Phase 1 (this change):** EvidenceService + evidence table + passive
   ticker + review screen.
2. **Phase 1.5:** Firestore query for cross-trip corroboration (auto-confirm
   N≥2 hits within 15m; auto-reject chronic one-off locations).
3. **Phase 2:** TFLite pothole detector trained on reviewed frames; fuse with
   IMU for real-time high-confidence detection (Option B).
