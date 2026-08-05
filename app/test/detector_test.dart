// Unit tests for the pure [EventDetector] (v1.3.0).
//
// Before v1.3.0 the detection logic lived in an untestable closure inside the
// sensor isolate and there were ZERO tests for pothole / bump / lane-change —
// the exact events the app author was least sure about. These tests drive the
// extracted, wall-clock-free detector with synthetic signals so every event
// class has a deterministic regression check, and so the algorithm can be tuned
// with confidence.
//
// Run with:  flutter test test/detector_test.dart

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:pothole_finder/detection/detector.dart';
import 'package:pothole_finder/models.dart';

const int _dtMs = 20; // 50 Hz capture cadence

DetectorResult _tick(
  EventDetector d,
  int ts,
  double vertG, {
  double yaw = 0.0,
  double horiz = 0.0,
  double speed = 50.0,
  bool stationary = false,
  bool suppressed = false,
}) {
  return d.process(
    ts: ts,
    vertG: vertG,
    signedYaw: yaw,
    horizG: horiz,
    speedKmh: speed,
    stationary: stationary,
    suppressed: suppressed,
  );
}

/// Feeds a quiet baseline so the rolling mean/std settle before an event.
int _warmup(EventDetector d, int startTs, {double speed = 50.0}) {
  int ts = startTs;
  for (int i = 0; i < 400; i++) {
    _tick(d, ts, i.isEven ? 0.01 : -0.01, speed: speed);
    ts += _dtMs;
  }
  return ts;
}

/// Feeds a list of vertical-accel values and collects every emitted event.
List<DetectedEvent> _feedVert(
  EventDetector d,
  int startTs,
  List<double> vals, {
  double speed = 50.0,
}) {
  final events = <DetectedEvent>[];
  int ts = startTs;
  for (final v in vals) {
    events.addAll(_tick(d, ts, v, speed: speed).events);
    ts += _dtMs;
  }
  return events;
}

void main() {
  group('Impulse classification (raw-signal features)', () {
    test('sharp strong impulse → pothole', () {
      final d = EventDetector();
      final ts = _warmup(d, 100000);
      // Sharp 3-tick burst (high peak g, very high jerk), then settle to close
      // the exceedance window.
      final events = _feedVert(
        d, ts, [0.3, 0.6, 0.3, 0.0, 0.0, 0.0], speed: 50);
      expect(events.any((e) => e.type == EventTypes.pothole), isTrue,
          reason: 'a sharp 0.6 g spike at 50 km/h should be a pothole');
      expect(events.any((e) => e.type == EventTypes.speedBump), isFalse);
    });

    test('smooth sustained heave → speed bump, not pothole', () {
      final d = EventDetector();
      final ts = _warmup(d, 100000);
      // Half-sine heave: amplitude 0.3 g over ~400 ms → low jerk, longer duration.
      final vals = <double>[
        for (int i = 0; i <= 20; i++) 0.3 * math.sin(math.pi * i / 20),
        0.0, 0.0, 0.0,
      ];
      final events = _feedVert(d, ts, vals, speed: 50);
      expect(events.any((e) => e.type == EventTypes.speedBump), isTrue,
          reason: 'a smooth 0.3 g heave should classify as a speed bump');
      expect(events.any((e) => e.type == EventTypes.pothole), isFalse,
          reason: 'low-jerk heave must NOT be a pothole');
    });

    test('brief small sharp edge → concrete joint', () {
      final d = EventDetector();
      final ts = _warmup(d, 100000);
      final events = _feedVert(d, ts, [0.25, 0.25, 0.0, 0.0, 0.0], speed: 50);
      expect(events.any((e) => e.type == EventTypes.concreteJoint), isTrue);
      expect(events.any((e) => e.type == EventTypes.pothole), isFalse);
    });

    test('repeated joint hits collapse into silence (storm guard, v1.3.1)', () {
      // 2026-07-01 drive: joints were 72% of all alerts, firing every 1.5–2 s
      // on ordinary highway texture. Rapid joint candidates now mean "textured
      // surface", not N separate defects.
      final d = EventDetector();
      int ts = _warmup(d, 100000);
      final events = <DetectedEvent>[];
      for (int burst = 0; burst < 10; burst++) {
        // One sharp 0.25 g blip …
        events.addAll(_tick(d, ts, 0.25, speed: 50).events);
        ts += _dtMs;
        events.addAll(_tick(d, ts, 0.25, speed: 50).events);
        ts += _dtMs;
        // … then ~1 s of quiet before the next.
        for (int i = 0; i < 48; i++) {
          events.addAll(_tick(d, ts, i.isEven ? 0.01 : -0.01, speed: 50).events);
          ts += _dtMs;
        }
      }
      final joints =
          events.where((e) => e.type == EventTypes.concreteJoint).length;
      expect(joints, equals(1),
          reason: '10 joint candidates in 10 s must alert once, then be '
              'recognised as surface texture');
    });

    test('same impulse → pothole in the city, concrete joint on the highway '
        '(speed-scaled boundary, v1.3.4)', () {
      // The 7 labelled drives ending 2026-08-04 showed the constant 0.35 g
      // boundary was bisecting one population: joint-branch peakG maxed at
      // exactly 0.35 while pothole-branch peakG had p10 = 0.35–0.36 in every
      // speed bucket. 46 of 54 judged rough_road alerts were really joints.
      // A 0.5 g sharp edge is a pothole at 40 km/h but a joint at 100 km/h.
      const vals = [0.25, 0.5, 0.25, 0.0, 0.0, 0.0];

      final city = EventDetector();
      final cityEvents =
          _feedVert(city, _warmup(city, 100000, speed: 40), vals, speed: 40);
      expect(cityEvents.any((e) => e.type == EventTypes.pothole), isTrue,
          reason: '0.5 g at 40 km/h is below the 50 km/h boundary row → pothole');

      final hwy = EventDetector();
      final hwyEvents =
          _feedVert(hwy, _warmup(hwy, 100000, speed: 100), vals, speed: 100);
      expect(hwyEvents.any((e) => e.type == EventTypes.pothole), isFalse,
          reason: '0.5 g at 100 km/h is below the 0.62 g boundary → not a pothole');
      expect(hwyEvents.any((e) => e.type == EventTypes.concreteJoint), isTrue,
          reason: 'it should land in the joint branch, not vanish');
    });

    test('a genuinely violent impulse is still a pothole at highway speed '
        '(v1.3.4 must not blind high-speed pothole detection)', () {
      final d = EventDetector();
      final ts = _warmup(d, 100000, speed: 110);
      // 0.9 g — above the 0.62 g boundary for the 95+ km/h row.
      final events = _feedVert(d, ts, [0.4, 0.9, 0.4, 0.0, 0.0, 0.0], speed: 110);
      expect(events.any((e) => e.type == EventTypes.pothole), isTrue,
          reason: 'raising the boundary must not suppress real high-speed potholes');
    });

    test('joint/pothole boundary rows meet exactly — no impulse falls through '
        'between the two branches (v1.3.4)', () {
      // Both branches read one boundary function, so for any speed every
      // impulse above concreteJointMinPeakG belongs to exactly one branch.
      for (final row in DetectionConfig.potholeJointBoundary) {
        final b = row[2];
        expect(b, greaterThanOrEqualTo(DetectionConfig.concreteJointMinPeakG),
            reason: 'a boundary below the joint floor would strand impulses');
      }
      // Monotonic in speed: a faster impulse never needs LESS g to be a pothole.
      for (int i = 1; i < DetectionConfig.potholeJointBoundary.length; i++) {
        expect(DetectionConfig.potholeJointBoundary[i][2],
            greaterThanOrEqualTo(DetectionConfig.potholeJointBoundary[i - 1][2]));
      }
    });

    test('telemetry (v1.3.4): every classified impulse records its branch and '
        'the thresholds it was judged against', () {
      final d = EventDetector();
      final ts = _warmup(d, 100000, speed: 100);
      final diags = <ImpulseDiag>[];
      int t = ts;
      for (final v in [0.25, 0.5, 0.25, 0.0, 0.0, 0.0]) {
        diags.addAll(_tick(d, t, v, speed: 100).impulseDiags);
        t += _dtMs;
      }
      expect(diags.length, equals(1),
          reason: 'one exceedance closed → exactly one diag row');
      final row = diags.single;
      expect(row.branch, equals('concrete_joint'),
          reason: '0.5 g at 100 km/h is below the 0.62 g boundary');
      expect(row.jointBoundaryG, equals(0.62),
          reason: 'the speed-scaled boundary in effect must be recorded, so '
              '"how far from the cut was it" is answerable offline');
      expect(row.peakG, greaterThan(0.0));
      expect(row.peakJerk, greaterThan(0.0));
      expect(row.rawStd, greaterThan(0.0),
          reason: 'the rawZ inputs are recorded so the baseline state can be '
              'reconstructed rather than guessed');
      expect(row.durationMs, greaterThan(0));
      expect(row.speedKmh, equals(100));
    });

    test('telemetry (v1.3.4): an impulse that no branch claims is still '
        'recorded — the population the event log cannot show', () {
      final d = EventDetector();
      final ts = _warmup(d, 100000, speed: 100);
      final diags = <ImpulseDiag>[];
      int t = ts;
      // 0.5 g but SMOOTH (low jerk) and too long for a joint: fails the
      // pothole jerk gate, the speed-bump duration window and the joint
      // duration cap. Previously this vanished without trace.
      final vals = <double>[
        for (int i = 0; i <= 60; i++) 0.5 * math.sin(math.pi * i / 60),
        0.0, 0.0, 0.0,
      ];
      for (final v in vals) {
        diags.addAll(_tick(d, t, v, speed: 100).impulseDiags);
        t += _dtMs;
      }
      expect(diags, isNotEmpty, reason: 'the impulse must leave a record');
      expect(diags.single.branch, equals('none'));
      expect(diags.single.emitted, isFalse);
    });

    test('telemetry (v1.3.4): a branch that fired but was swallowed downstream '
        'records emitted=false with the reason', () {
      final d = EventDetector();
      int t = _warmup(d, 100000, speed: 50);
      final diags = <ImpulseDiag>[];
      // Two joints inside the 7 s joint cooldown: the first alerts, the
      // second is claimed by the joint branch but suppressed.
      for (int burst = 0; burst < 2; burst++) {
        for (final v in [0.25, 0.25, 0.0, 0.0, 0.0]) {
          diags.addAll(_tick(d, t, v, speed: 50).impulseDiags);
          t += _dtMs;
        }
        for (int i = 0; i < 40; i++) {
          diags.addAll(_tick(d, t, i.isEven ? 0.01 : -0.01, speed: 50).impulseDiags);
          t += _dtMs;
        }
      }
      expect(diags.length, equals(2));
      expect(diags[0].emitted, isTrue);
      expect(diags[1].branch, equals('concrete_joint'),
          reason: 'the branch still claimed it …');
      expect(diags[1].emitted, isFalse, reason: '… but the driver never saw it');
      expect(diags[1].suppressedBy, equals('cooldown'));
    });

    test('double-hit bump is NOT also classified as a second event (v1.3.1)', () {
      // The same physical impulse used to be recorded twice: once by the
      // double-hit bump matcher and once by the impulse classifier.
      final d = EventDetector();
      int ts = _warmup(d, 100000);
      final events = <DetectedEvent>[];
      void feedOne(double v) {
        events.addAll(_tick(d, ts, v, speed: 50).events);
        ts += _dtMs;
      }

      // Front-axle hit: 0.25 g for 160 ms (bump-candidate duration).
      for (int i = 0; i < 8; i++) {
        feedOne(0.25);
      }
      for (int i = 0; i < 10; i++) {
        feedOne(0.0); // 200 ms gap
      }
      // Rear-axle hit ~360 ms after the first (wheelbase delay at 50 km/h).
      for (int i = 0; i < 8; i++) {
        feedOne(0.25);
      }
      for (int i = 0; i < 10; i++) {
        feedOne(0.0);
      }

      expect(events.where((e) => e.type == EventTypes.bump).length, equals(1));
      expect(events.any((e) => e.type == EventTypes.pothole), isFalse,
          reason: 'the rear-axle hit completed the bump; it must not ALSO be '
              'classified as a standalone event');
      expect(events.any((e) => e.type == EventTypes.concreteJoint), isFalse);
    });

    test('pothole event carries physical features (peakG, jerk)', () {
      final d = EventDetector();
      final ts = _warmup(d, 100000);
      final events =
          _feedVert(d, ts, [0.3, 0.6, 0.3, 0.0, 0.0, 0.0], speed: 50);
      final pothole = events.firstWhere((e) => e.type == EventTypes.pothole);
      expect(pothole.peakG, greaterThanOrEqualTo(DetectionConfig.potholeMinPeakG));
      expect(pothole.jerk, greaterThanOrEqualTo(DetectionConfig.potholeMinJerk));
    });
  });

  group('Rough road (sustained, smoothed signal)', () {
    test('sustained vibration for >3 s → rough_road', () {
      final d = EventDetector();
      int ts = _warmup(d, 100000);
      final events = <DetectedEvent>[];
      for (int i = 0; i < 240; i++) {
        // ~4.8 s of steady 0.2 g vibration.
        events.addAll(_tick(d, ts, i.isEven ? 0.2 : -0.2, speed: 50).events);
        ts += _dtMs;
      }
      expect(events.any((e) => e.type == EventTypes.roughRoad), isTrue);
    });
  });

  group('Rough patch (quick succession of potholes)', () {
    // Feeds [count] sharp pothole-like impulses, each [spacingMs] apart, with
    // quiet road in between.
    List<DetectedEvent> feedPotholeBurst(
      EventDetector d,
      int startTs, {
      required int count,
      required int spacingMs,
      double speed = 50,
    }) {
      final events = <DetectedEvent>[];
      int ts = startTs;
      final int gapTicks = (spacingMs ~/ _dtMs) - 6;
      for (int p = 0; p < count; p++) {
        for (final v in [0.3, 0.6, 0.3, 0.0, 0.0, 0.0]) {
          events.addAll(_tick(d, ts, v, speed: speed).events);
          ts += _dtMs;
        }
        for (int i = 0; i < gapTicks; i++) {
          events.addAll(_tick(d, ts, i.isEven ? 0.01 : -0.01, speed: speed).events);
          ts += _dtMs;
        }
      }
      return events;
    }

    test('3+ potholes in quick succession → one rough_road, not a burst', () {
      final d = EventDetector();
      final ts = _warmup(d, 100000);
      // 5 potholes ~1.5 s apart → all inside the 6 s window.
      final events = feedPotholeBurst(d, ts, count: 5, spacingMs: 1500);
      expect(events.any((e) => e.type == EventTypes.roughRoad), isTrue,
          reason: 'a quick succession of potholes is a rough patch');
      final potholes = events.where((e) => e.type == EventTypes.pothole).length;
      expect(potholes, lessThan(3),
          reason: 'individual pothole pings are suppressed during the patch, '
              'replaced by a single rough_road alert');
    });

    test('isolated potholes far apart do NOT form a rough patch', () {
      final d = EventDetector();
      final ts = _warmup(d, 100000);
      // 3 potholes 10 s apart → never 3 within the 6 s window.
      final events = feedPotholeBurst(d, ts, count: 3, spacingMs: 10000);
      expect(events.any((e) => e.type == EventTypes.roughRoad), isFalse,
          reason: 'well-separated single potholes are not a rough patch');
      expect(events.where((e) => e.type == EventTypes.pothole).length,
          greaterThanOrEqualTo(2),
          reason: 'isolated potholes still each alert individually');
    });
  });

  group('Turn vs lane change (heading-integrated)', () {
    test('sustained one-direction yaw → turn, never lane_change', () {
      final d = EventDetector();
      int ts = _warmup(d, 100000, speed: 50);
      final events = <DetectedEvent>[];
      for (int i = 0; i < 40; i++) {
        events.addAll(_tick(d, ts, 0.0, yaw: 0.5, speed: 50).events);
        ts += _dtMs;
      }
      expect(events.any((e) => e.type == EventTypes.turn), isTrue);
      expect(events.any((e) => e.type == EventTypes.laneChange), isFalse);
    });

    test('S-curve with ~zero net heading → lane_change', () {
      final d = EventDetector();
      int ts = _warmup(d, 100000, speed: 100);
      final events = <DetectedEvent>[];
      void feed(double yaw, int n) {
        for (int i = 0; i < n; i++) {
          events.addAll(_tick(d, ts, 0.0, yaw: yaw, speed: 100).events);
          ts += _dtMs;
        }
      }

      feed(0.25, 20); // phase 1: +yaw, 400 ms  (below the 0.3 turn threshold)
      feed(0.0, 10); //  crossover, 200 ms
      feed(-0.25, 20); // phase 2: -yaw, 400 ms
      feed(0.0, 40); //  settle → confirm (40 ticks: the v1.3.4 yaw band-pass
      //                 lags phase closure by ~0.4 s)

      expect(events.any((e) => e.type == EventTypes.laneChange), isTrue);
      expect(events.any((e) => e.type == EventTypes.turn), isFalse);
    });

    test('low-amplitude yaw wander does NOT spam lane changes', () {
      // The old detector flagged >90% of highway samples as lane changes; the
      // per-phase heading gate should reject small steering wander outright.
      final d = EventDetector();
      int ts = _warmup(d, 100000, speed: 120);
      final events = <DetectedEvent>[];
      for (int i = 0; i < 250; i++) {
        // 5 s of 2 Hz, 0.2 rad/s yaw oscillation (crosses the yaw min but each
        // half-cycle turns the car only ~1.8°, below the 2° per-phase gate,
        // and each half-cycle is shorter than the 300 ms phase minimum).
        final yaw = 0.2 * math.sin(2 * math.pi * 2 * (i * _dtMs) / 1000.0);
        events.addAll(_tick(d, ts, 0.0, yaw: yaw, speed: 120).events);
        ts += _dtMs;
      }
      final laneChanges =
          events.where((e) => e.type == EventTypes.laneChange).length;
      expect(laneChanges, lessThan(2));
    });

    test('gentle highway lane change (~0.06 rad/s peak yaw) IS detected', () {
      // v1.3.1 regression: a 3.5 m lane change at ~100 km/h peaks well below
      // the old 0.12 rad/s entry threshold, which is why the 2026-07-01
      // highway drive logged ZERO lane changes.
      final d = EventDetector();
      int ts = _warmup(d, 100000, speed: 100);
      final events = <DetectedEvent>[];
      bool suppressedDuringPhase2 = false;
      void feed(double yaw, int n, {bool phase2 = false}) {
        for (int i = 0; i < n; i++) {
          final r = _tick(d, ts, 0.0, yaw: yaw, speed: 100);
          events.addAll(r.events);
          if (phase2 && r.laneChangeActive) suppressedDuringPhase2 = true;
          ts += _dtMs;
        }
      }

      feed(0.06, 50); //   phase 1: 1 s of gentle yaw → ~3.4° heading
      feed(0.0, 25); //    crossover: 0.5 s straddling the line
      feed(-0.06, 50, phase2: true); // phase 2: return to original heading
      feed(0.0, 40); //    settle → confirm (see band-pass lag note above)

      expect(events.any((e) => e.type == EventTypes.laneChange), isTrue,
          reason: 'a gentle highway lane change must be detected');
      expect(suppressedDuringPhase2, isTrue,
          reason: 'defect alerts must be suppressed while crossing the line '
              '(raised markers are hit during crossover/phase 2)');
    });

    test(
        'quick, assertive lane change (peak yaw > turn threshold) is not '
        'swallowed by the turn interlock', () {
      // Regression: laneChangeYawMaxRads (0.80) is well above
      // turnYawThresholdRads (0.3), so a real lane change's peak yaw commonly
      // exceeds 0.3 rad/s briefly — the old interlock reset lane-change
      // tracking on the very FIRST such sample (before the S-curve ever
      // reached its direction reversal), which is why real lane changes were
      // almost never detected in practice. Each phase here is 320 ms — above
      // laneChangeYawMaxRads is never touched, but the peak (0.45 rad/s) is
      // above turnYawThresholdRads and each phase is under turnMinDurationMs
      // (400 ms), so a correct implementation must still confirm lane_change
      // and must never confirm turn.
      final d = EventDetector();
      int ts = _warmup(d, 100000, speed: 100);
      final events = <DetectedEvent>[];
      void feed(double yaw, int n) {
        for (int i = 0; i < n; i++) {
          events.addAll(_tick(d, ts, 0.0, yaw: yaw, speed: 100).events);
          ts += _dtMs;
        }
      }

      feed(0.45, 16); //  phase 1: 320 ms of assertive yaw → ~8.2° heading
      feed(0.0, 5); //     crossover: 100 ms straddling the line
      feed(-0.45, 16); //  phase 2: 320 ms return, mirrors phase 1
      feed(0.0, 40); //    settle → confirm (see band-pass lag note above)

      expect(events.any((e) => e.type == EventTypes.laneChange), isTrue,
          reason: 'a quick lane change whose peak yaw exceeds the turn '
              'threshold must still be detected as a lane change');
      expect(events.any((e) => e.type == EventTypes.turn), isFalse,
          reason: 'neither phase sustains long enough to be a real turn');
    });

    test(
        'speed-scaled entry (v1.3.3): very gentle 110 km/h lane change '
        '(0.04 rad/s, below the old fixed 0.05 floor) IS detected', () {
      // At 110 km/h the entry floor is laneChangeMinLatAccelMps2 / v ≈ 0.026,
      // clamped to 0.03 — so a 0.04 rad/s manoeuvre now qualifies. Under the
      // old fixed 0.05 gate this real lane change never opened phase 1, which
      // is one half of why the 2026-07-18 drives confirmed 0 of 30 alerts.
      final d = EventDetector();
      int ts = _warmup(d, 100000, speed: 110);
      final events = <DetectedEvent>[];
      void feed(double yaw, int n) {
        for (int i = 0; i < n; i++) {
          events.addAll(_tick(d, ts, 0.0, yaw: yaw, speed: 110).events);
          ts += _dtMs;
        }
      }

      feed(0.04, 75); //  phase 1: 1.5 s → ~3.4° heading
      feed(0.0, 25); //   crossover: 0.5 s
      feed(-0.04, 75); // phase 2: mirror return
      feed(0.0, 40); //   settle → confirm (see band-pass lag note above)

      expect(events.any((e) => e.type == EventTypes.laneChange), isTrue,
          reason: 'the entry floor must scale down with speed');
    });

    test(
        'speed-scaled entry (v1.3.3): sustained 0.05 rad/s wander at 40 km/h '
        '(above the old fixed floor) no longer opens a candidate', () {
      // At 40 km/h the entry floor is 0.8 / 11.1 ≈ 0.072 rad/s — city-speed
      // lane-keeping wander at 0.05 now stays below entry instead of opening
      // (and falsely confirming) candidates. This is the other half of the
      // 2026-07-18 failure: 21–41 mph false alarms.
      final d = EventDetector();
      int ts = _warmup(d, 100000, speed: 40);
      final events = <DetectedEvent>[];
      final diags = <LcDiag>[];
      void feed(double yaw, int n) {
        for (int i = 0; i < n; i++) {
          final r = _tick(d, ts, 0.0, yaw: yaw, speed: 40);
          events.addAll(r.events);
          diags.addAll(r.lcDiags);
          ts += _dtMs;
        }
      }

      feed(0.05, 50); // drift one way …
      feed(0.0, 15);
      feed(-0.05, 50); // … and correct back — an S-shape, but far too gentle
      feed(0.0, 10);

      expect(events.any((e) => e.type == EventTypes.laneChange), isFalse);
      expect(diags, isEmpty,
          reason: 'below the entry floor no candidate should even open');
    });

    test('telemetry (v1.3.3): confirmed lane change emits a confirm LcDiag '
        'with a ~lane-width lateral displacement estimate', () {
      final d = EventDetector();
      int ts = _warmup(d, 100000, speed: 110);
      final diags = <LcDiag>[];
      void feed(double yaw, int n) {
        for (int i = 0; i < n; i++) {
          diags.addAll(_tick(d, ts, 0.0, yaw: yaw, speed: 110).lcDiags);
          ts += _dtMs;
        }
      }

      feed(0.04, 75); //  phase 1: 1.5 s → ~3.4° heading
      feed(0.0, 25); //   crossover: 0.5 s
      feed(-0.04, 75); // phase 2: mirror return
      feed(0.0, 40); //   settle → confirm (see band-pass lag note above)

      final confirms = diags.where((g) => g.outcome == 'confirm').toList();
      expect(confirms, hasLength(1));
      final g = confirms.single;
      // The v1.3.4 band-pass shifts the stage boundaries: phase 1 opens once
      // the smoothed yaw climbs past the entry floor (~350 ms into a 1.5 s
      // deflection) and closes once it decays back below the crossover floor,
      // so the measured stage is shorter than the raw deflection it came from.
      expect(g.phase1Ms, greaterThanOrEqualTo(1000));
      expect(g.phase2Ms, greaterThan(0));
      expect(g.peakYawRads, closeTo(0.04, 0.005));
      expect(g.yawEntryRads, closeTo(0.03, 0.005),
          reason: 'the clamped speed-scaled entry floor should be recorded');
      expect(g.netHeadingDeg.abs(), lessThan(2.0),
          reason: 'an S-curve returns to ~the original heading');
      // The v1.3.4 band-pass attenuates the integrated heading, so the lateral
      // estimate now reads LOW against the true manoeuvre — 2.3 m here for what
      // was ~2.9 m unfiltered. Any future displacement-based gate has to be
      // calibrated on filtered data; the [2.0, 5.5] m band derived from the
      // pre-filter 2026-08-04 diags does NOT transfer as-is.
      expect(g.netLatM, inInclusiveRange(2.0, 5.0),
          reason: 'a real lane change displaces the car ~a lane width (3.5 m)');
    });

    test('a curved road is NOT a lane change, even with steering corrections '
        'on top of it (v1.3.4)', () {
      // The complaint this fixes: on a curve the raw yaw holds a sustained
      // non-zero mean, so the machine saw a large heading swing that had
      // nothing to do with changing lanes. 53 of 56 confirmations on the
      // 2026-08-04 dataset were this — both phases turning the SAME way, net
      // headings up to 16.8°, sneaking under the 18° gate. One swept 14.7 m.
      final d = EventDetector();
      int ts = _warmup(d, 100000, speed: 110);
      final events = <DetectedEvent>[];
      // A long right-hand curve: 0.10 rad/s held for 12 s, with ±0.03 rad/s of
      // ordinary steering correction riding on top. Never reverses direction.
      for (int i = 0; i < 600; i++) {
        final yaw = 0.10 + 0.03 * math.sin(2 * math.pi * i / 60);
        events.addAll(_tick(d, ts, 0.0, yaw: yaw, speed: 110).events);
        ts += _dtMs;
      }
      expect(events.any((e) => e.type == EventTypes.laneChange), isFalse,
          reason: 'holding a curve is not changing lanes — the yaw baseline '
              'must absorb the curvature');
    });

    test('a real lane change performed ON a curve is still detected (v1.3.4 '
        'removes curvature, not steering)', () {
      // The high-pass must not throw the baby out: subtracting road curvature
      // has to leave a genuine S-curve intact even mid-curve.
      final d = EventDetector();
      int ts = _warmup(d, 100000, speed: 110);
      final events = <DetectedEvent>[];
      void feed(double yaw, int n) {
        for (int i = 0; i < n; i++) {
          events.addAll(_tick(d, ts, 0.0, yaw: yaw, speed: 110).events);
          ts += _dtMs;
        }
      }

      // 25 s of steady curve first: the baseline needs ~2τ to absorb the step
      // of entering the curve (see laneChangeYawBaselineTauS's known
      // limitation). This test is about holding an ESTABLISHED curve.
      feed(0.10, 1250); //         25 s of steady curve → baseline settles on it
      feed(0.10 + 0.05, 75); //    phase 1: steer OUT of the curve's arc
      feed(0.10, 25); //           crossover, back on the arc
      feed(0.10 - 0.05, 75); //    phase 2: mirror return
      feed(0.10, 60); //           settle → confirm

      expect(events.any((e) => e.type == EventTypes.laneChange), isTrue,
          reason: 'a real S-curve deviation from the arc is still a lane change');
    });

    test('both phases turning the same way is rejected as a curve, and the '
        'reason is recorded (v1.3.4)', () {
      final d = EventDetector();
      expect(DetectionConfig.laneChangeRequireOppositePhases, isTrue,
          reason: 'the geometry gate must be on for this test to mean anything');
      int ts = _warmup(d, 100000, speed: 110);
      final diags = <LcDiag>[];
      void feed(double yaw, int n) {
        for (int i = 0; i < n; i++) {
          diags.addAll(_tick(d, ts, 0.0, yaw: yaw, speed: 110).lcDiags);
          ts += _dtMs;
        }
      }

      // A yaw excursion that dips toward zero and then resumes the SAME
      // direction — a curve being re-entered, not an S-curve.
      feed(0.06, 75);
      feed(0.0, 25);
      feed(0.06, 75);
      feed(0.0, 40);

      expect(diags.any((g) => g.outcome == 'confirm'), isFalse,
          reason: 'same-direction phases cannot be a lane change');
    });

    test('telemetry (v1.3.3): wander abort is recorded with its gate reason',
        () {
      // Strong enough to open a candidate at 120 km/h (floor ≈ 0.03) but each
      // half-cycle integrates well under the 2° per-phase heading gate — the
      // machine must log WHY it rejected the candidate.
      final d = EventDetector();
      int ts = _warmup(d, 100000, speed: 120);
      final diags = <LcDiag>[];
      for (int i = 0; i < 250; i++) {
        final yaw = 0.2 * math.sin(2 * math.pi * 2 * (i * _dtMs) / 1000.0);
        diags.addAll(_tick(d, ts, 0.0, yaw: yaw, speed: 120).lcDiags);
        ts += _dtMs;
      }
      expect(diags, isNotEmpty,
          reason: 'rejected candidates must still be logged for tuning');
      expect(diags.any((g) => g.outcome == 'confirm'), isFalse);
    });
  });

  group('Gating', () {
    test('suppressed ticks emit no events', () {
      final d = EventDetector();
      final ts = _warmup(d, 100000);
      final events = <DetectedEvent>[];
      int t = ts;
      for (final v in [0.3, 0.6, 0.3, 0.0, 0.0]) {
        events.addAll(_tick(d, t, v, speed: 50, suppressed: true).events);
        t += _dtMs;
      }
      expect(events, isEmpty);
    });

    test('stationary ticks emit no impulse events', () {
      final d = EventDetector();
      final ts = _warmup(d, 100000);
      final events = <DetectedEvent>[];
      int t = ts;
      for (final v in [0.3, 0.6, 0.3, 0.0, 0.0]) {
        events.addAll(_tick(d, t, v, speed: 3, stationary: true).events);
        t += _dtMs;
      }
      expect(events, isEmpty);
    });
  });

  group('Braking (longitudinal low-pass)', () {
    test('sustained longitudinal accel sets isBraking and emits a braking event', () {
      final d = EventDetector();
      int ts = _warmup(d, 100000);
      final events = <DetectedEvent>[];
      DetectorResult r = DetectorResult(
        smoothedVert: 0,
        zScore: 0,
        events: const [],
        laneChangeActive: false,
        isBraking: false,
      );
      for (int i = 0; i < 40; i++) {
        r = _tick(d, ts, 0.0, horiz: 0.6, speed: 50);
        events.addAll(r.events);
        ts += _dtMs;
      }
      expect(r.isBraking, isTrue);
      expect(events.any((e) => e.type == EventTypes.braking), isTrue);
    });

    test('braking is suppressed while cornering (high yaw)', () {
      final d = EventDetector();
      int ts = _warmup(d, 100000);
      DetectorResult r = _tick(d, ts, 0.0, horiz: 0.6, yaw: 0.5, speed: 50);
      for (int i = 0; i < 40; i++) {
        r = _tick(d, ts, 0.0, horiz: 0.6, yaw: 0.5, speed: 50);
        ts += _dtMs;
      }
      expect(r.isBraking, isFalse);
    });
  });

  group('Determinism (wall-clock independence)', () {
    test('same signal + same timestamps → identical events', () {
      List<String> run() {
        final d = EventDetector();
        final ts = _warmup(d, 100000);
        return _feedVert(d, ts, [0.3, 0.6, 0.3, 0.0, 0.0, 0.0], speed: 50)
            .map((e) => e.type)
            .toList();
      }

      expect(run(), equals(run()));
    });
  });
}
