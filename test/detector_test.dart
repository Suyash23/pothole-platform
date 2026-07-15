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
      feed(0.0, 10); //  settle → confirm

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
      feed(0.0, 10); //    settle → confirm

      expect(events.any((e) => e.type == EventTypes.laneChange), isTrue,
          reason: 'a gentle highway lane change must be detected');
      expect(suppressedDuringPhase2, isTrue,
          reason: 'defect alerts must be suppressed while crossing the line '
              '(raised markers are hit during crossover/phase 2)');
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
