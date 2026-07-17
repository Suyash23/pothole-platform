/// Pure, dependency-free road-event detector.
///
/// WHY THIS FILE EXISTS
/// --------------------
/// Before v1.3.0 all detection lived inside a ~300-line closure in
/// `sensor_isolate.dart` (`_startUserAccel`). It mixed sensor plumbing, wall-clock
/// timing (`DateTime.now()`), UI messaging and classification, so it could not be
/// unit-tested or replayed deterministically over recorded data — which is exactly
/// what you need to improve an algorithm you're unsure about.
///
/// [EventDetector] is that logic extracted into a PURE function of its inputs:
///   • only `dart:math` / `dart:collection` (no Flutter, no sensors, no I/O)
///   • ALL timing is derived from the sample timestamps you pass in, never from
///     the wall clock — so the same recording always detects identically,
///     regardless of CPU speed (fixes the replay-nondeterminism bug).
///
/// WHAT CHANGED IN THE ALGORITHM (see CODE_REVIEW / CHANGES docs for the full why)
///   • Impulse events (pothole / speed bump / concrete joint / bump) are now
///     classified from RAW-signal features — peak g and peak JERK (|Δg|/Δt) — not
///     just a threshold on a 0.75 s moving average that had already filtered out
///     the sharpness that distinguishes a pothole from a speed bump.
///   • Detection now requires an ABSOLUTE physical gate (peak g, jerk) in series
///     with the relative Z-score gate, so results are comparable across trips /
///     vehicles / mounts instead of depending on how rough the recent road was.
///   • The Z-score baseline is no longer updated while an event is in progress,
///     so a rough stretch no longer inflates the baseline and blinds the detector
///     to the very defects it is meant to catch.
///   • Lane-change vs turn is decided by NET integrated heading change, not by
///     counting yaw sign-reversals, and both S-curve phases must complete before
///     a lane change is confirmed (no more optimistic single-blip confirmation).
library;

import 'dart:collection';
import 'dart:math' as math;

import '../models.dart';

double _degrees(double radians) => radians * 180.0 / math.pi;

/// A discrete event emitted by [EventDetector]. `type` is always canonical
/// ([EventTypes]). This is the detector's OWN output — never ground truth.
class DetectedEvent {
  DetectedEvent({
    required this.ts,
    this.endTs,
    required this.type,
    this.zScore = 0.0,
    this.peakG = 0.0,
    this.jerk = 0.0,
    this.speedKmh = 0.0,
  });

  final int ts;
  final int? endTs;
  final String type;
  final double zScore;
  final double peakG;
  final double jerk;
  final double speedKmh;
}

/// Everything the detector produces for a single accelerometer tick.
class DetectorResult {
  DetectorResult({
    required this.smoothedVert,
    required this.zScore,
    required this.events,
    required this.laneChangeActive,
    required this.isBraking,
  });

  /// 0.75 s moving average of |vertical accel| (unchanged semantics — still used
  /// for the map colour and the sparkline).
  final double smoothedVert;

  /// Rolling Z-score of [smoothedVert] against the adaptive baseline.
  final double zScore;

  /// Events detected on this tick (usually empty).
  final List<DetectedEvent> events;

  /// True while road-defect alerts should be suppressed because a lane change
  /// is in progress / just finished (raised lane markers mimic defects).
  final bool laneChangeActive;

  /// Low-passed longitudinal (braking) state.
  final bool isBraking;
}

class _BumpHit {
  _BumpHit(this.ts, this.duration, this.peakZ, this.peakG, this.jerk);
  final int ts;
  final int duration;
  final double peakZ;
  final double peakG;
  final double jerk;
}

/// Stateful detector. Create one per trip and feed it ticks in time order via
/// [process]. All thresholds come from [DetectionConfig].
class EventDetector {
  // ── Smoothing (0.75 s moving average of |vert|) ────────────────────────────
  static const int _rollingWindowMs = 750;
  final Queue<_TsVal> _accelWindow = Queue<_TsVal>();
  double _lastSmoothed = 0.0;

  // ── Rolling Z-score baseline of the SMOOTHED signal (5 min, winsorised) ──────
  // Used for the map colour + the sustained rough-road test only.
  static const int _zScoreWindowMs = 5 * 60 * 1000;
  final Queue<double> _valWindow = Queue<double>();
  final Queue<int> _valTimeWindow = Queue<int>();
  double _mean = 0.0;
  double _stdDev = 1.0;

  // ── Rolling baseline of the RAW |vert| signal (for impulse relative gating) ──
  final Queue<double> _rawValWindow = Queue<double>();
  final Queue<int> _rawTimeWindow = Queue<int>();
  double _rawMean = 0.0;
  double _rawStd = 1.0;

  // ── Raw-signal / jerk tracking ─────────────────────────────────────────────
  int _lastVertTs = 0;
  double _lastVertG = 0.0;

  // ── Impulse exceedance tracking (one contiguous run of raw |vert| ≥ entry) ──
  int _exSince = 0;
  int _exStartTs = 0;
  double _exPeakZ = 0.0;
  double _exPeakG = 0.0;
  double _exPeakJerk = 0.0;

  // ── Per-type cooldowns / alert times (all in sample-ts ms) ──────────────────
  int _lastPotholeTs = 0;
  int _lastSpeedBumpTs = 0;
  int _lastConcreteJointTs = 0;
  int _lastRoughRoadTs = 0;
  int _lastTurnTs = 0;
  int _lastBrakingTs = 0;

  // ── Rough road ─────────────────────────────────────────────────────────────
  int? _roughSince;
  int _lastRoughSampleTs = 0;

  // ── Turn ───────────────────────────────────────────────────────────────────
  int _turnActiveSince = 0;
  int _turnDirection = 0;
  int _turnBelowSince = 0;

  /// True once the CURRENT same-direction yaw excursion has been sustained for
  /// turnMinDurationMs — i.e. a turn the lane-change interlock should trust.
  /// Deliberately separate from [_turnActiveSince]/[_turnBelowSince]: those
  /// carry a 120 ms noise-tolerance grace period (for bridging brief sensor
  /// dropouts WITHIN a genuine turn), which a lane change's crossover dip can
  /// easily be shorter than — so reusing that bookkeeping for the interlock
  /// let a real lane change's crossover→phase-2 transition get vetoed by
  /// "elapsed time since phase 1 started" even though the direction had
  /// already reversed. This flag has NO grace period: any drop below the turn
  /// threshold clears it immediately.
  bool _turnConfirmed = false;

  // ── Braking low-pass (longitudinal) ────────────────────────────────────────
  double _smoothedHoriz = 0.0;
  int _lastHorizTs = 0;
  bool _isBraking = false;

  // ── Double-hit bump ────────────────────────────────────────────────────────
  final List<_BumpHit> _recentBumpHits = [];

  // ── Rough patch (quick succession of impacts) ──────────────────────────────
  // Timestamps of recent impact CANDIDATES (pothole / bump / speed bump, the
  // moment they pass their gates — before per-type cooldowns throttle them).
  // Concrete joints are excluded (see DetectionConfig.roughPatchWindowMs).
  final Queue<int> _impactClusterTs = Queue<int>();
  // While `ts <= _roughPatchActiveUntil` a rough patch is in progress and the
  // individual per-impact alerts are suppressed in favour of one rough_road.
  int _roughPatchActiveUntil = 0;

  // ── Concrete-joint storm guard (v1.3.1) ────────────────────────────────────
  // Timestamps of recent joint CANDIDATES (gates passed, before cooldown). If
  // too many arrive in a short window the surface is textured, not jointed.
  final Queue<int> _jointCandidateTs = Queue<int>();

  // ── Lane change (heading-integrated S-curve) ───────────────────────────────
  bool _lcInPhase1 = false;
  bool _lcInCrossover = false;
  int _lcPhaseStartTs = 0;
  int _lcCrossoverTs = 0;
  int _lcPhaseDirection = 0;
  double _lcPhase1HeadingDeg = 0.0; // signed integrated heading of phase 1
  double _lcPhase2HeadingDeg = 0.0; // signed integrated heading of phase 2
  int _lcSuppressUntil = 0;
  int _lastLaneChangeTs = 0;

  /// Exposed for callers/tests that want the current baseline.
  double get mean => _mean;
  double get stdDev => _stdDev;

  DetectorResult process({
    required int ts,
    required double vertG,
    required double signedYaw,
    required double horizG,
    required double speedKmh,
    double headingDeg = -1.0,
    required bool stationary,
    required bool suppressed,
  }) {
    final events = <DetectedEvent>[];

    // dt from sample timestamps (never the wall clock).
    final double dt = _lastVertTs == 0 ? 0.0 : (ts - _lastVertTs) / 1000.0;
    final double jerk =
        (dt > 0) ? (vertG - _lastVertG).abs() / dt : 0.0;
    _lastVertTs = ts;
    _lastVertG = vertG;

    if (suppressed) {
      // Mirror the pre-existing behaviour: drop transient state so the settling
      // period after a phone pick-up cannot produce false positives.
      _accelWindow.clear();
      _lastSmoothed = 0.0;
      _roughSince = null;
      _recentBumpHits.clear();
      _impactClusterTs.clear();
      _roughPatchActiveUntil = 0;
      _exSince = 0;
      _exPeakZ = _exPeakG = _exPeakJerk = 0.0;
      _smoothedHoriz = 0.0;
      _isBraking = false;
      // Lane-change machine keeps its suppress window but resets phase state.
      _lcInPhase1 = false;
      _lcInCrossover = false;
      _lcPhaseDirection = 0;
      return DetectorResult(
        smoothedVert: 0.0,
        zScore: 0.0,
        events: events,
        laneChangeActive: ts < _lcSuppressUntil,
        isBraking: false,
      );
    }

    final double vertAbs = vertG.abs();

    // 1. Smoothed |vert| (0.75 s moving average).
    _accelWindow.add(_TsVal(ts, vertAbs));
    final cutoff = ts - _rollingWindowMs;
    while (_accelWindow.isNotEmpty && _accelWindow.first.ts < cutoff) {
      _accelWindow.removeFirst();
    }
    double sum = 0.0;
    for (final s in _accelWindow) {
      sum += s.val;
    }
    _lastSmoothed = _accelWindow.isEmpty ? 0.0 : sum / _accelWindow.length;

    // 2. Update both baselines — but NOT while an impulse is in progress
    //    (event-excluded), and only while genuinely moving.
    final bool exceedanceActive = _exSince > 0;
    if (!stationary && !exceedanceActive) {
      _updateBaseline(ts, _lastSmoothed);
      _updateRawBaseline(ts, vertAbs);
    }
    final double zScore =
        _stdDev > 0 ? (_lastSmoothed - _mean) / _stdDev : 0.0;

    // 3. Braking low-pass (skip while yaw is high — cornering isn't braking).
    if (signedYaw.abs() > DetectionConfig.brakingYawSuppressRads) {
      _smoothedHoriz = 0.0;
      _isBraking = false;
    } else {
      if (_lastHorizTs == 0) {
        _smoothedHoriz = horizG;
      } else {
        final double hdt = (ts - _lastHorizTs) / 1000.0;
        if (hdt > 0) {
          const double timeConstant = 0.3;
          final double alpha = math.exp(-hdt / timeConstant);
          _smoothedHoriz = _smoothedHoriz * alpha + horizG * (1.0 - alpha);
        }
      }
      _isBraking = _smoothedHoriz > 0.35;
    }
    _lastHorizTs = ts;

    // 4. Lane change (always evaluated so it can suppress defect alerts).
    final bool laneChanging =
        _updateLaneChange(ts, signedYaw, speedKmh, events);

    if (!stationary) {
      // 4b. Sudden braking — emit on the low-passed longitudinal state, rate-limited.
      if (_isBraking &&
          (_lastBrakingTs == 0 || ts - _lastBrakingTs >= 4000)) {
        _lastBrakingTs = ts;
        events.add(DetectedEvent(
          ts: ts,
          type: EventTypes.braking,
          zScore: zScore,
          speedKmh: speedKmh,
        ));
      }

      // 5. Impulse classifier — an exceedance is a contiguous run where the RAW
      //    |vert| stays above impulseEntryG. We classify it (pothole / speed bump
      //    / concrete joint / bump) from raw physical features at its end.
      if (vertAbs >= DetectionConfig.impulseEntryG) {
        if (_exSince == 0) {
          _exSince = ts;
          _exStartTs = ts;
          _exPeakZ = 0.0;
          _exPeakG = 0.0;
          _exPeakJerk = 0.0;
        }
        if (zScore > _exPeakZ) _exPeakZ = zScore;
        if (vertAbs > _exPeakG) _exPeakG = vertAbs;
        if (jerk > _exPeakJerk) _exPeakJerk = jerk;
      } else if (_exSince > 0) {
        final int duration = ts - _exSince;
        _classifyImpulse(
          endTs: ts,
          startTs: _exStartTs,
          duration: duration,
          peakZ: _exPeakZ,
          peakG: _exPeakG,
          peakJerk: _exPeakJerk,
          speedKmh: speedKmh,
          laneChanging: laneChanging,
          events: events,
        );
        _exSince = 0;
        _exPeakZ = _exPeakG = _exPeakJerk = 0.0;
      }

      // 6. Rough road — sustained roughness (kept, sample-ts based).
      if (zScore >= 3.0) {
        _lastRoughSampleTs = ts;
        if (_roughSince == null) {
          _roughSince = ts;
        } else if (ts - _roughSince! >= 3000) {
          if (_lastRoughRoadTs == 0 ||
              ts - _lastRoughRoadTs >= DetectionConfig.roughRoadCooldownMs) {
            _lastRoughRoadTs = ts;
            events.add(DetectedEvent(
              ts: ts,
              type: EventTypes.roughRoad,
              zScore: zScore,
              peakG: vertAbs,
              speedKmh: speedKmh,
            ));
          }
          _roughSince = null;
        }
      } else if (_roughSince != null && ts - _lastRoughSampleTs > 1000) {
        _roughSince = null;
      }

      // 7. Turn — sustained SIGNED yaw in one direction.
      _updateTurn(ts, signedYaw, zScore, speedKmh, events);
    } else {
      _roughSince = null;
      _turnActiveSince = 0;
      _turnDirection = 0;
      _turnBelowSince = 0;
      _turnConfirmed = false;
      _exSince = 0;
      _exPeakZ = _exPeakG = _exPeakJerk = 0.0;
      _impactClusterTs.clear();
      _roughPatchActiveUntil = 0;
    }

    return DetectorResult(
      smoothedVert: _lastSmoothed,
      zScore: zScore,
      events: events,
      laneChangeActive: laneChanging,
      isBraking: _isBraking,
    );
  }

  // ── Impulse classification ─────────────────────────────────────────────────
  void _classifyImpulse({
    required int endTs,
    required int startTs,
    required int duration,
    required double peakZ,
    required double peakG,
    required double peakJerk,
    required double speedKmh,
    required bool laneChanging,
    required List<DetectedEvent> events,
  }) {
    // Feed the double-hit bump matcher first. v1.3.1: if the hit completes a
    // double-hit bump we STOP — previously classification continued and the
    // same physical impulse was recorded twice (2026-07-01 drive: bump at
    // …991401 and pothole at …991581 with identical peakG/jerk).
    if (!laneChanging &&
        peakG >= DetectionConfig.bumpMinPeakG &&
        duration >= DetectionConfig.bumpMinDurationMs &&
        duration <= DetectionConfig.bumpMaxDurationMs) {
      final DetectedEvent? bump = _matchDoubleHitBump(
        startTs: startTs,
        endTs: endTs,
        duration: duration,
        peakZ: peakZ,
        peakG: peakG,
        jerk: peakJerk,
        speedKmh: speedKmh,
      );
      if (bump != null) {
        final bool inPatch = _registerImpact(endTs, bump.peakG, speedKmh, events);
        if (!inPatch) events.add(bump);
        return;
      }
    }

    if (laneChanging) return; // raised markers mimic defects — suppress.

    // Relative gate against the RAW baseline: how extreme is this peak vs. how
    // rough the road has recently been. Combined in series with absolute gates.
    final double rawZ =
        _rawStd > 0 ? (peakG - _rawMean) / _rawStd : 0.0;
    final double potholeZ = _potholeThresholdForSpeed(speedKmh);

    // 1. Pothole — sharp AND strong: absolute peak g + jerk, plus relative rawZ.
    if (peakG >= DetectionConfig.potholeMinPeakG &&
        peakJerk >= DetectionConfig.potholeMinJerk &&
        rawZ >= potholeZ) {
      // Feed the rough-patch cluster; if a patch is active the single rough_road
      // alert stands in for this pothole and the individual ping is suppressed.
      final bool inPatch = _registerImpact(endTs, peakG, speedKmh, events);
      if (!inPatch &&
          (_lastPotholeTs == 0 ||
              endTs - _lastPotholeTs >= DetectionConfig.potholeCooldownMs)) {
        _lastPotholeTs = endTs;
        events.add(DetectedEvent(
          ts: startTs,
          endTs: endTs,
          type: EventTypes.pothole,
          zScore: rawZ,
          peakG: peakG,
          jerk: peakJerk,
          speedKmh: speedKmh,
        ));
      }
      return; // classified
    }

    // 2. Speed bump — smooth heave: reaches amplitude but LOW jerk, and lasts.
    if (peakG >= DetectionConfig.speedBumpMinPeakG &&
        peakJerk <= DetectionConfig.speedBumpMaxJerk &&
        duration >= DetectionConfig.speedBumpMinDurationMs &&
        duration <= DetectionConfig.speedBumpMaxDurationMs) {
      final bool inPatch = _registerImpact(endTs, peakG, speedKmh, events);
      if (!inPatch &&
          (_lastSpeedBumpTs == 0 ||
              endTs - _lastSpeedBumpTs >= DetectionConfig.speedBumpCooldownMs)) {
        _lastSpeedBumpTs = endTs;
        events.add(DetectedEvent(
          ts: startTs,
          endTs: endTs,
          type: EventTypes.speedBump,
          zScore: rawZ,
          peakG: peakG,
          jerk: peakJerk,
          speedKmh: speedKmh,
        ));
      }
      return;
    }

    // 3. Concrete joint — brief, small, but a SHARP edge (needs some jerk).
    //
    // v1.3.1: three changes, all driven by the 2026-07-01 drive where joints
    // were 72% of every alert emitted:
    //   • absolute floor raised from impulseEntryG (0.12 g) to a dedicated
    //     concreteJointMinPeakG — highway texture lives at 0.12–0.17 g;
    //   • a relative gate (rawZ) — joints were the only impulse class without
    //     one, making them a catch-all for any texture blip;
    //   • a storm guard — many qualifying joints per window means the surface
    //     is rough, which is the sustained rough-road detector's job.
    if (peakG >= DetectionConfig.concreteJointMinPeakG &&
        peakG < DetectionConfig.potholeMinPeakG &&
        peakJerk >= DetectionConfig.concreteJointMinJerk &&
        rawZ >= DetectionConfig.concreteJointMinRawZ &&
        duration <= DetectionConfig.concreteJointMaxDurationMs) {
      _jointCandidateTs.add(endTs);
      while (_jointCandidateTs.isNotEmpty &&
          endTs - _jointCandidateTs.first >
              DetectionConfig.concreteJointStormWindowMs) {
        _jointCandidateTs.removeFirst();
      }
      final bool storm =
          _jointCandidateTs.length >= DetectionConfig.concreteJointStormCount;
      if (!storm &&
          (_lastConcreteJointTs == 0 ||
              endTs - _lastConcreteJointTs >=
                  DetectionConfig.concreteJointCooldownMs)) {
        _lastConcreteJointTs = endTs;
        events.add(DetectedEvent(
          ts: startTs,
          endTs: endTs,
          type: EventTypes.concreteJoint,
          zScore: rawZ,
          peakG: peakG,
          jerk: peakJerk,
          speedKmh: speedKmh,
        ));
      }
    }
  }

  /// Returns the [EventTypes.bump] event when this hit completes a double-hit
  /// bump (front axle then rear axle), else null. The caller decides whether to
  /// emit it (it is suppressed while a rough patch is active).
  DetectedEvent? _matchDoubleHitBump({
    required int startTs,
    required int endTs,
    required int duration,
    required double peakZ,
    required double peakG,
    required double jerk,
    required double speedKmh,
  }) {
    _recentBumpHits.add(_BumpHit(startTs, duration, peakZ, peakG, jerk));
    _recentBumpHits.removeWhere((h) => startTs - h.ts > 4000);

    final double speedMps = speedKmh / 3.6;
    int matchedIdx = -1;
    for (int i = 0; i < _recentBumpHits.length - 1; i++) {
      final prev = _recentBumpHits[i];
      final elapsed = startTs - prev.ts;
      bool isMatch;
      if (speedMps < 2.0) {
        isMatch = elapsed >= DetectionConfig.bumpFallbackMinDelayMs &&
            elapsed <= DetectionConfig.bumpFallbackMaxDelayMs;
      } else {
        final minDelay =
            (DetectionConfig.bumpWheelbaseMinMeters / speedMps) * 1000;
        final maxDelay =
            (DetectionConfig.bumpWheelbaseMaxMeters / speedMps) * 1000;
        final lower = math.max(100.0, minDelay - 200.0);
        final upper = maxDelay + 200.0;
        isMatch = elapsed >= lower && elapsed <= upper;
      }
      if (isMatch) {
        matchedIdx = i;
        break;
      }
    }

    if (matchedIdx != -1) {
      final prev = _recentBumpHits[matchedIdx];
      final bump = DetectedEvent(
        ts: prev.ts,
        endTs: endTs,
        type: EventTypes.bump,
        zScore: math.max(prev.peakZ, peakZ),
        peakG: math.max(prev.peakG, peakG),
        jerk: math.max(prev.jerk, jerk),
        speedKmh: speedKmh,
      );
      _recentBumpHits.removeRange(0, matchedIdx + 1);
      return bump;
    }
    return null;
  }

  /// Records an impact candidate (pothole / bump / speed bump) into the
  /// rough-patch cluster and returns whether a rough patch is currently active.
  ///
  /// When [DetectionConfig.roughPatchMinImpacts] candidates fall inside a
  /// [DetectionConfig.roughPatchWindowMs] sliding window, a single
  /// [EventTypes.roughRoad] alert is emitted (rate-limited by
  /// [DetectionConfig.roughRoadCooldownMs], shared with the sustained-roughness
  /// path) and the caller suppresses its individual per-impact alert, so a
  /// broken stretch reads as one "rough patch" rather than a burst of pings.
  bool _registerImpact(
      int ts, double peakG, double speedKmh, List<DetectedEvent> events) {
    _impactClusterTs.add(ts);
    final int cutoff = ts - DetectionConfig.roughPatchWindowMs;
    while (_impactClusterTs.isNotEmpty && _impactClusterTs.first < cutoff) {
      _impactClusterTs.removeFirst();
    }

    if (_impactClusterTs.length >= DetectionConfig.roughPatchMinImpacts) {
      _roughPatchActiveUntil = ts + DetectionConfig.roughPatchWindowMs;
      if (_lastRoughRoadTs == 0 ||
          ts - _lastRoughRoadTs >= DetectionConfig.roughRoadCooldownMs) {
        _lastRoughRoadTs = ts;
        events.add(DetectedEvent(
          ts: ts,
          type: EventTypes.roughRoad,
          zScore: 0.0,
          peakG: peakG,
          speedKmh: speedKmh,
        ));
      }
    }
    return ts <= _roughPatchActiveUntil;
  }

  double _potholeThresholdForSpeed(double speedKmh) {
    for (final row in DetectionConfig.potholeSpeedThresholds) {
      if (speedKmh >= row[0] && speedKmh < row[1]) return row[2];
    }
    return DetectionConfig.potholeFallbackThreshold;
  }

  // ── Turn ───────────────────────────────────────────────────────────────────
  void _updateTurn(int ts, double signedYaw, double zScore, double speedKmh,
      List<DetectedEvent> events) {
    final double yawRate = signedYaw.abs();
    final int dir = signedYaw >= 0 ? 1 : -1;
    if (yawRate > DetectionConfig.turnYawThresholdRads) {
      _turnBelowSince = 0;
      if (_turnActiveSince == 0) {
        _turnActiveSince = ts;
        _turnDirection = dir;
      } else if (dir != _turnDirection) {
        // Sign reversal → S-curve oscillation, not a sustained turn.
        _turnActiveSince = 0;
        _turnDirection = 0;
        _turnConfirmed = false;
      } else if (ts - _turnActiveSince >= DetectionConfig.turnMinDurationMs) {
        _turnConfirmed = true;
        if (_lastTurnTs == 0 ||
            ts - _lastTurnTs >= DetectionConfig.turnCooldownMs) {
          _lastTurnTs = ts;
          // v1.3.1: turn events now carry speed (they uploaded speedKmh=0,
          // which read as a data bug in analysis).
          events.add(DetectedEvent(
              ts: ts,
              type: EventTypes.turn,
              zScore: zScore,
              speedKmh: speedKmh));
        }
      }
    } else {
      // Below the turn threshold this tick: the interlock signal drops
      // immediately (no grace period — see _turnConfirmed's doc comment),
      // even though _turnActiveSince itself keeps its 120 ms noise tolerance.
      _turnConfirmed = false;
      if (_turnActiveSince > 0) {
        if (_turnBelowSince == 0) _turnBelowSince = ts;
        if (ts - _turnBelowSince > 120) {
          _turnActiveSince = 0;
          _turnDirection = 0;
          _turnBelowSince = 0;
        }
      }
    }
  }

  // ── Lane change (heading-integrated) ────────────────────────────────────────
  //
  // Returns true while defect alerts should be suppressed. A lane change is a
  // yaw excursion one way then the other whose NET integrated heading change is
  // small; a turn commits to a new heading and is rejected here.
  //
  // v1.3.1: suppression is now also active DURING the crossover and phase 2 —
  // that is exactly when the tyres straddle the line and hit raised markers.
  // The old code only suppressed after confirmation, i.e. after the marker
  // hits had already fired as defect alerts. (Phase 1 alone does not suppress:
  // a single yaw deflection is far too common to blind the defect detector.)
  bool _lcSuppressActive(int ts) =>
      _lcInCrossover || _lcInPhase2 || ts < _lcSuppressUntil;

  bool _updateLaneChange(
      int ts, double signedYaw, double speedKmh, List<DetectedEvent> events) {
    // A CONFIRMED turn cannot also be a lane change. Gated on [_turnConfirmed]
    // — the turn detector's own confirmation bar (turnMinDurationMs sustained
    // in ONE direction, no grace period) — NOT merely "yaw exceeded the turn
    // threshold once" — a real lane change's peak yaw commonly briefly exceeds
    // turnYawThresholdRads (laneChangeYawMaxRads=0.80 vs turnYawThresholdRads
    // =0.3, so the ranges overlap). Resetting on the first over-threshold
    // sample killed the S-curve tracker before it ever reached the direction
    // reversal, which is why real lane changes were almost never detected.
    // [_turnConfirmed] (rather than raw _turnActiveSince elapsed time) also
    // matters here: _turnActiveSince carries its own 120 ms noise-tolerance
    // grace period, which a lane change's crossover dip can be shorter than —
    // using it directly let elapsed-time-since-phase-1-start cross the 400 ms
    // bar during the crossover, vetoing phase 2 even though the direction had
    // already reversed. The lane-change machine's own net-heading + crossover
    // gates already reject genuine turns on their own (a real turn never
    // reverses direction back near zero net heading), so this interlock only
    // needs to catch turns that actually got that far.
    if (_turnConfirmed) {
      _resetLaneChangePhases();
      return _lcSuppressActive(ts);
    }

    final double absYaw = signedYaw.abs();
    final bool above = absYaw >= DetectionConfig.laneChangeYawMinRads &&
        absYaw <= DetectionConfig.laneChangeYawMaxRads;
    final bool belowCross =
        absYaw < DetectionConfig.laneChangeYawMinRads * 0.4;
    // Per-tick heading increment (deg), integrated against the previous tick's
    // timestamp so the state machine never touches the wall clock.
    final double incDt = (_lcLastTs == 0) ? 0.0 : (ts - _lcLastTs) / 1000.0;
    _lcLastTs = ts;
    final double headingInc = _degreesSafe(signedYaw, incDt);

    // ── PHASE 1 ────────────────────────────────────────────────────────────
    // Phase 2 must be excluded here: its opposite-direction yaw would
    // otherwise re-enter phase 1 on the very first phase-2 tick, zeroing the
    // integrated headings and leaving the machine stuck (crossover shadows
    // the phase-2 confirm branch below), so no lane change could ever confirm.
    if (!_lcInPhase1 && !_lcInCrossover && !_lcInPhase2) {
      final bool inCooldown =
          ts - _lastLaneChangeTs < DetectionConfig.laneChangeCooldownMs;
      if (above &&
          speedKmh >= DetectionConfig.laneChangeMinSpeedKmh &&
          !inCooldown) {
        _lcInPhase1 = true;
        _lcPhaseStartTs = ts;
        _lcPhaseDirection = signedYaw > 0 ? 1 : -1;
        _lcPhase1HeadingDeg = 0.0;
        _lcPhase2HeadingDeg = 0.0;
      }
    } else if (_lcInPhase1) {
      _lcPhase1HeadingDeg += headingInc;
      if (ts - _lcPhaseStartTs > DetectionConfig.laneChangePhaseMaxMs ||
          absYaw > DetectionConfig.laneChangeYawMaxRads) {
        _resetLaneChangePhases();
        return _lcSuppressActive(ts);
      }
      final bool phase1LongEnough =
          ts - _lcPhaseStartTs >= DetectionConfig.laneChangePhaseMinMs;
      final bool phase1TurnedEnough = _lcPhase1HeadingDeg.abs() >=
          DetectionConfig.laneChangeMinPhaseHeadingDeg;
      if (belowCross && phase1LongEnough && phase1TurnedEnough) {
        _lcInPhase1 = false;
        _lcInCrossover = true;
        _lcCrossoverTs = ts;
      } else if (belowCross && phase1LongEnough && !phase1TurnedEnough) {
        // Grazed the yaw threshold but never actually turned → wander, abort.
        _resetLaneChangePhases();
      }
    }

    // ── CROSSOVER ──────────────────────────────────────────────────────────
    if (_lcInCrossover) {
      if (ts - _lcCrossoverTs > DetectionConfig.laneChangeCrossoverMaxMs) {
        _resetLaneChangePhases();
        return _lcSuppressActive(ts);
      }
      final int curDir = signedYaw > 0 ? 1 : -1;
      if (above && curDir != _lcPhaseDirection) {
        // Enter phase 2 — integrate until it completes; only THEN confirm.
        _lcInCrossover = false;
        _lcInPhase2 = true;
        _lcPhase2StartTs = ts;
        _lcPhase2HeadingDeg = headingInc;
      }
    } else if (_lcInPhase2) {
      _lcPhase2HeadingDeg += headingInc;
      final bool phase2LongEnough =
          ts - _lcPhase2StartTs >= DetectionConfig.laneChangePhaseMinMs;
      final bool phase2TurnedEnough = _lcPhase2HeadingDeg.abs() >=
          DetectionConfig.laneChangeMinPhaseHeadingDeg;
      final bool phase2Ended = absYaw < DetectionConfig.laneChangeYawMinRads * 0.4;
      final bool phase2TooLong =
          ts - _lcPhase2StartTs > DetectionConfig.laneChangePhaseMaxMs;

      if (phase2TooLong || absYaw > DetectionConfig.laneChangeYawMaxRads) {
        _resetLaneChangePhases();
        return _lcSuppressActive(ts);
      }

      final bool bothPhasesOk = !DetectionConfig.laneChangeRequireBothPhases ||
          (phase2LongEnough && phase2TurnedEnough);

      if (phase2Ended && phase2LongEnough) {
        final double netHeading =
            (_lcPhase1HeadingDeg + _lcPhase2HeadingDeg).abs();
        final bool isLaneChange = bothPhasesOk &&
            netHeading <= DetectionConfig.laneChangeMaxNetHeadingDeg;
        if (isLaneChange) {
          _lcSuppressUntil = ts + DetectionConfig.laneChangeSuppressAfterMs;
          _lastLaneChangeTs = ts;
          events.add(DetectedEvent(
            ts: _lcPhaseStartTs,
            endTs: ts,
            type: EventTypes.laneChange,
            speedKmh: speedKmh,
          ));
        }
        // Whether confirmed or reclassified as a turn, the manoeuvre is over.
        _resetLaneChangePhases();
      }
    }

    return _lcSuppressActive(ts);
  }

  // extra lane-change state that must persist across ticks
  int _lcLastTs = 0;
  bool _lcInPhase2 = false;
  int _lcPhase2StartTs = 0;

  void _resetLaneChangePhases() {
    _lcInPhase1 = false;
    _lcInCrossover = false;
    _lcInPhase2 = false;
    _lcPhaseDirection = 0;
    _lcPhase1HeadingDeg = 0.0;
    _lcPhase2HeadingDeg = 0.0;
  }

  double _degreesSafe(double signedYaw, double dt) {
    if (dt <= 0 || dt > 1.0) return 0.0; // ignore absurd gaps
    return _degrees(signedYaw * dt);
  }

  // ── Z-score baseline (winsorised, per original semantics) ───────────────────
  void _updateBaseline(int ts, double smoothed) {
    _valTimeWindow.add(ts);
    double clamped = smoothed;
    if (_valWindow.length > 10 && _stdDev > 0) {
      final double z = (smoothed - _mean) / _stdDev;
      if (z > DetectionConfig.winsorizeZ) {
        clamped = _mean + DetectionConfig.winsorizeZ * _stdDev;
      } else if (z < -DetectionConfig.winsorizeZ) {
        clamped = _mean - DetectionConfig.winsorizeZ * _stdDev;
      }
    }
    _valWindow.add(clamped);

    final cutoff = ts - _zScoreWindowMs;
    while (_valTimeWindow.isNotEmpty && _valTimeWindow.first < cutoff) {
      _valTimeWindow.removeFirst();
      _valWindow.removeFirst();
    }

    if (_valWindow.length > 10) {
      double m = 0.0;
      for (final v in _valWindow) {
        m += v;
      }
      m /= _valWindow.length;
      double variance = 0.0;
      for (final v in _valWindow) {
        variance += (v - m) * (v - m);
      }
      variance /= _valWindow.length;
      _mean = m;
      _stdDev = math.sqrt(variance);
      if (_stdDev < DetectionConfig.minStdDevG) {
        _stdDev = DetectionConfig.minStdDevG;
      }
    }
  }

  /// Rolling winsorised baseline of the RAW |vert| signal, used to compute the
  /// relative (rawZ) gate for impulse events. Same 5-minute window as the
  /// smoothed baseline.
  void _updateRawBaseline(int ts, double vertAbs) {
    _rawTimeWindow.add(ts);
    double clamped = vertAbs;
    if (_rawValWindow.length > 10 && _rawStd > 0) {
      final double z = (vertAbs - _rawMean) / _rawStd;
      if (z > DetectionConfig.winsorizeZ) {
        clamped = _rawMean + DetectionConfig.winsorizeZ * _rawStd;
      } else if (z < -DetectionConfig.winsorizeZ) {
        clamped = _rawMean - DetectionConfig.winsorizeZ * _rawStd;
      }
    }
    _rawValWindow.add(clamped);

    final cutoff = ts - _zScoreWindowMs;
    while (_rawTimeWindow.isNotEmpty && _rawTimeWindow.first < cutoff) {
      _rawTimeWindow.removeFirst();
      _rawValWindow.removeFirst();
    }

    if (_rawValWindow.length > 10) {
      double m = 0.0;
      for (final v in _rawValWindow) {
        m += v;
      }
      m /= _rawValWindow.length;
      double variance = 0.0;
      for (final v in _rawValWindow) {
        variance += (v - m) * (v - m);
      }
      variance /= _rawValWindow.length;
      _rawMean = m;
      _rawStd = math.sqrt(variance);
      if (_rawStd < DetectionConfig.minStdDevG) {
        _rawStd = DetectionConfig.minStdDevG;
      }
    }
  }
}

class _TsVal {
  _TsVal(this.ts, this.val);
  final int ts;
  final double val;
}
