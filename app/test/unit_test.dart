import 'dart:collection';
import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math_64.dart';
import 'package:geolocator/geolocator.dart';

import 'package:pothole_finder/models.dart';
import 'package:pothole_finder/sensor_source.dart';

// Test implementation of the Douglas-Peucker decimation to verify mathematical correctness
List<GpsSample> runDouglasPeucker(List<GpsSample> points, double epsilon) {
  if (points.length < 3) return points;

  double dmax = 0.0;
  int index = 0;
  for (int i = 1; i < points.length - 1; i++) {
    double d = perpendicularDistance(points[i], points.first, points.last);
    if (d > dmax) {
      index = i;
      dmax = d;
    }
  }

  if (dmax > epsilon) {
    final res1 = runDouglasPeucker(points.sublist(0, index + 1), epsilon);
    final res2 = runDouglasPeucker(points.sublist(index, points.length), epsilon);
    return [...res1.sublist(0, res1.length - 1), ...res2];
  } else {
    return [points.first, points.last];
  }
}

double perpendicularDistance(GpsSample point, GpsSample lineStart, GpsSample lineEnd) {
  double x = point.lat;
  double y = point.lon;
  double x1 = lineStart.lat;
  double y1 = lineStart.lon;
  double x2 = lineEnd.lat;
  double y2 = lineEnd.lon;

  double num = ((y2 - y1) * x - (x2 - x1) * y + x2 * y1 - y2 * x1).abs();
  double den = math.sqrt(math.pow(y2 - y1, 2) + math.pow(x2 - x1, 2));
  if (den == 0) return 0.0;
  return (num / den) * 111000.0; // approximate distance in meters
}



void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Requirement F1: Vertical Acceleration Projection Tests', () {
    test('Calculates vertical acceleration parallel to gravity axis correctly', () {
      final gravity = Vector3(0.0, 0.0, 1.0); // perfect vertical gravity aligned with Z
      final userAccel = Vector3(0.1, -0.2, 1.5); // user movement dynamic vector

      final gNorm = gravity.normalized();
      final vert = userAccel.dot(gNorm);

      expect(vert, closeTo(1.5, 0.0001));
      expect(vert.abs(), closeTo(1.5, 0.0001));
    });

    test('Projects vertical acceleration with angled phone sensor frame', () {
      // Gravity is diagonal (phone tilted 45 degrees in Y-Z plane)
      final gravity = Vector3(0.0, 1.0, 1.0);
      final gNorm = gravity.normalized(); // [0.0, 0.7071, 0.7071]

      // Movement is purely vertical relative to earth (parallel to gravity)
      final userAccel = Vector3(0.0, 1.0, 1.0) * 2.0; 

      final vert = userAccel.dot(gNorm);
      // Expected: projection length should equal length of userAccel = sqrt(2^2 + 2^2) = sqrt(8) = 2.8284
      expect(vert.abs(), closeTo(math.sqrt(8.0), 0.0001));
    });
  });

  group('Requirement F2: Rolling Average Smoothing Tests', () {
    test('Averages samples within 0.75-second window correctly', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final Queue<AccelSample> window = Queue<AccelSample>();

      // Add samples within 750ms window
      window.add(AccelSample(now - 700, 1.0));
      window.add(AccelSample(now - 400, 2.0));
      window.add(AccelSample(now - 100, 3.0));

      final sum = window.fold<double>(0.0, (acc, s) => acc + s.vertAccel);
      final average = sum / window.length;

      expect(average, closeTo(2.0, 0.0001));
    });

    test('Evicts old samples outside 0.75-second window', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final Queue<AccelSample> window = Queue<AccelSample>();

      window.add(AccelSample(now - 1000, 10.0)); // Should be evicted
      window.add(AccelSample(now - 500, 1.5));
      window.add(AccelSample(now - 100, 2.5));

      final cutoff = now - 750;
      while (window.isNotEmpty && window.first.ts < cutoff) {
        window.removeFirst();
      }

      expect(window.length, equals(2));
      final sum = window.fold<double>(0.0, (acc, s) => acc + s.vertAccel);
      final average = sum / window.length;
      expect(average, closeTo(2.0, 0.0001));
    });
  });

  group('Requirement F3 & F4: Z-Score and Color Mapping Tests', () {
    test('Calculates rolling mean and standard deviation correctly', () {
      final List<double> values = [0.1, 0.2, 0.3, 0.4, 0.5]; // mean = 0.3, stdDev = 0.14142

      final mean = values.fold<double>(0.0, (acc, val) => acc + val) / values.length;
      final variance = values.fold<double>(0.0, (acc, val) => acc + math.pow(val - mean, 2)) / values.length;
      final stdDev = math.sqrt(variance);

      expect(mean, closeTo(0.3, 0.0001));
      expect(stdDev, closeTo(0.14142, 0.0001));

      // Test Z-score mapping for vertical acceleration = 0.58284 (2.0 standard deviations above mean)
      final sampleVal = 0.3 + 2.0 * stdDev;
      final zScore = (sampleVal - mean) / stdDev;
      expect(zScore, closeTo(2.0, 0.0001));
    });

    test('Correctly maps Z-scores to severity colors', () {
      // Bands updated to match data-driven P98 thresholds from drive analysis.
      // Old bands (2/3/4) were anchored to the old fixed 4.0 pothole threshold
      // which was too conservative. New bands anchored to 1.25/1.75/2.25.
      String getColor(double zScore) {
        if (zScore >= 2.25) return 'red';
        if (zScore >= 1.75) return 'orange';
        if (zScore >= 1.25) return 'yellow';
        return 'green';
      }

      expect(getColor(0.5),  equals('green'));
      expect(getColor(1.24), equals('green'));
      expect(getColor(1.25), equals('yellow'));
      expect(getColor(1.74), equals('yellow'));
      expect(getColor(1.75), equals('orange'));
      expect(getColor(2.24), equals('orange'));
      expect(getColor(2.25), equals('red'));
      expect(getColor(12.5), equals('red'));
    });
  });

  group('Requirement F5: Douglas-Peucker Decimation Tests', () {
    test('Simplifies a perfectly straight line to just start and end points', () {
      final List<GpsSample> line = [
        GpsSample(ts: 1000, lat: 37.7739, lon: -122.4312, color: 'green'),
        GpsSample(ts: 2000, lat: 37.7740, lon: -122.4311, color: 'green'),
        GpsSample(ts: 3000, lat: 37.7741, lon: -122.4310, color: 'green'),
        GpsSample(ts: 4000, lat: 37.7742, lon: -122.4309, color: 'green'),
      ];

      final simplified = runDouglasPeucker(line, 5.0); // epsilon of 5 meters

      expect(simplified.length, equals(2));
      expect(simplified.first.ts, equals(1000));
      expect(simplified.last.ts, equals(4000));
    });

    test('Retains significant jagged points above epsilon distance threshold', () {
      final List<GpsSample> path = [
        GpsSample(ts: 1000, lat: 37.7739, lon: -122.4312, color: 'green'),
        // Spiked point roughly 25 meters perpendicular away from the direct line (offset longitude)
        GpsSample(ts: 2000, lat: 37.7740, lon: -122.4315, color: 'green'), 
        GpsSample(ts: 3000, lat: 37.7741, lon: -122.4312, color: 'green'),
      ];

      final simplified = runDouglasPeucker(path, 5.0); // epsilon = 5 meters

      expect(simplified.length, equals(3)); // Spiked point must be retained
    });
  });





  group('Requirement F8: Phone Handling Noise Filters Tests', () {
    test('Triggers suppression when angular rotation magnitude exceeds 2.0 rads', () {
      bool shouldSuppressGyro(double gx, double gy, double gz) {
        final magnitude = Vector3(gx, gy, gz).length;
        return magnitude > DetectionConfig.gyroThresholdRads;
      }

      expect(shouldSuppressGyro(0.0, 0.0, 0.0), isFalse);
      expect(shouldSuppressGyro(1.0, 1.0, 1.0), isFalse); // length = sqrt(3) ~1.732
      expect(shouldSuppressGyro(1.2, 1.2, 1.2), isTrue);  // length = sqrt(4.32) ~2.08
      expect(shouldSuppressGyro(0.0, 0.0, 2.1), isTrue);  // length = 2.1
    });

    test('Triggers suppression when mount stability angle shifts by more than 10 degrees', () {
      bool shouldSuppressAngle(Vector3 gravityOld, Vector3 gravityNew) {
        final angleRads = gravityNew.angleTo(gravityOld);
        final angleDeg = angleRads * 180 / math.pi;
        return angleDeg > DetectionConfig.mountStabilityAngleDeg;
      }

      final vertical = Vector3(0.0, 0.0, 1.0);
      final tinyShift = Vector3(0.0, 0.05, 0.9987); // ~2.8 degrees
      final largeShift = Vector3(0.0, 0.25, 0.968); // ~14.4 degrees

      expect(shouldSuppressAngle(vertical, vertical), isFalse);
      expect(shouldSuppressAngle(vertical, tinyShift), isFalse);
      expect(shouldSuppressAngle(vertical, largeShift), isTrue);
    });
  });

  group('Requirement F9: Adaptive Sensor Ingestion Rates Tests', () {
    test('Adaptive rate trigger switches baseline to high rate based on Z-score threshold', () {
      double currentHz = DetectionConfig.baselineSamplingHz;

      void checkAdaptiveTrigger(double zScore) {
        if (zScore > DetectionConfig.adaptivePreTriggerZScore) {
          currentHz = DetectionConfig.triggerSamplingHz;
        }
      }

      checkAdaptiveTrigger(0.5);
      expect(currentHz, equals(25.0)); // remains baseline

      checkAdaptiveTrigger(1.6);
      expect(currentHz, equals(100.0)); // switches to high trigger rate
    });
  });

  group('Requirement F10: Parsing Models Data Integrity Tests', () {
    test('Parses GpsSample and Trip correctly from database row maps', () {
      final tripRow = {
        'id': 42,
        'start_time': 1716600000000,
        'end_time': 1716601800000,
        'fidelity': 'high',
        'vehicle': 'Tesla Model Y',
        'mount_type': 'Stiff Mount',
        'device_model': 'MacBook-Pro.local',
        'os_version': 'macos 14.5',
      };

      final trip = Trip.fromRow(tripRow);
      expect(trip.id, equals(42));
      expect(trip.startTimeMs, equals(1716600000000));
      expect(trip.endTimeMs, equals(1716601800000));
      expect(trip.fidelity, equals('high'));
      expect(trip.vehicle, equals('Tesla Model Y'));
      expect(trip.mountType, equals('Stiff Mount'));
      expect(trip.deviceModel, equals('MacBook-Pro.local'));
      expect(trip.osVersion, equals('macos 14.5'));

      final gpsRow = {
        'ts': 1716600050000,
        'lat': 37.773972,
        'lon': -122.431297,
        'accel_color': 'orange',
        'accel_val': 0.45,
        'z_score': 3.2,
        'gx': 0.1,
        'gy': -0.2,
        'gz': 0.3,
        'user_label': 'Pothole',
        'grav_x': 0.01,
        'grav_y': -0.02,
        'grav_z': 0.98,
        'raw_ax': 0.05,
        'raw_ay': -0.1,
        'raw_az': 1.05,
        'altitude': 25.4,
        'heading': 180.0,
        'speed_accuracy': 0.5,
        'heading_accuracy': 2.0,
        'altitude_accuracy': 1.5,
        'is_braking': 1,
        'is_tapping': 1,
      };

      final gpsSample = GpsSample.fromRow(gpsRow);
      expect(gpsSample.ts, equals(1716600050000));
      expect(gpsSample.lat, equals(37.773972));
      expect(gpsSample.lon, equals(-122.431297));
      expect(gpsSample.color, equals('orange'));
      expect(gpsSample.accelVal, equals(0.45));
      expect(gpsSample.zScore, equals(3.2));
      expect(gpsSample.gx, equals(0.1));
      expect(gpsSample.gy, equals(-0.2));
      expect(gpsSample.gz, equals(0.3));
      expect(gpsSample.userLabel, equals('Pothole'));
      expect(gpsSample.gravX, equals(0.01));
      expect(gpsSample.gravY, equals(-0.02));
      expect(gpsSample.gravZ, equals(0.98));
      expect(gpsSample.rawAx, equals(0.05));
      expect(gpsSample.rawAy, equals(-0.1));
      expect(gpsSample.rawAz, equals(1.05));
      expect(gpsSample.altitude, equals(25.4));
      expect(gpsSample.heading, equals(180.0));
      expect(gpsSample.speedAccuracy, equals(0.5));
      expect(gpsSample.headingAccuracy, equals(2.0));
      expect(gpsSample.altitudeAccuracy, equals(1.5));
      expect(gpsSample.isBraking, isTrue);
      expect(gpsSample.isTapping, isTrue);
    });
  });

  group('Interactive Anomaly Tagging Tests', () {
    test('Can modify GpsSample userLabel and serializes correctly', () {
      final gpsSample = GpsSample(
        ts: 1000,
        lat: 37.7,
        lon: -122.4,
        color: 'red',
        zScore: 4.5,
        gravX: 0.1,
        gravY: 0.2,
        gravZ: 0.9,
        isBraking: true,
        isTapping: true,
      );
      
      expect(gpsSample.userLabel, isNull);
      
      // Update the label
      gpsSample.userLabel = 'Pothole';
      expect(gpsSample.userLabel, equals('Pothole'));
      
      // Simulate mapping/serialization for Firestore
      final firestoreMap = {
        'ts': gpsSample.ts,
        'lat': gpsSample.lat,
        'lon': gpsSample.lon,
        'color': gpsSample.color,
        'accelVal': gpsSample.accelVal,
        'z_score': gpsSample.zScore,
        'speed': gpsSample.speed,
        'ax': gpsSample.ax,
        'ay': gpsSample.ay,
        'az': gpsSample.az,
        'gx': gpsSample.gx,
        'gy': gpsSample.gy,
        'gz': gpsSample.gz,
        'userLabel': gpsSample.userLabel,
        'gravX': gpsSample.gravX,
        'gravY': gpsSample.gravY,
        'gravZ': gpsSample.gravZ,
        'rawAx': gpsSample.rawAx,
        'rawAy': gpsSample.rawAy,
        'rawAz': gpsSample.rawAz,
        'altitude': gpsSample.altitude,
        'heading': gpsSample.heading,
        'speedAccuracy': gpsSample.speedAccuracy,
        'headingAccuracy': gpsSample.headingAccuracy,
        'altitudeAccuracy': gpsSample.altitudeAccuracy,
        'isBraking': gpsSample.isBraking,
        'isTapping': gpsSample.isTapping,
      };
      
      expect(firestoreMap['gx'], equals(0.0));
      expect(firestoreMap['userLabel'], equals('Pothole'));
      expect(firestoreMap['gravZ'], equals(0.9));
      expect(firestoreMap['isBraking'], isTrue);
      expect(firestoreMap['isTapping'], isTrue);
    });

    test('Manual pothole range tagging math', () {
      final samples = [
        GpsSample(ts: 1000, lat: 0, lon: 0, color: 'green'),
        GpsSample(ts: 4000, lat: 0, lon: 0, color: 'green'),
        GpsSample(ts: 6000, lat: 0, lon: 0, color: 'green'),
        GpsSample(ts: 9000, lat: 0, lon: 0, color: 'green'),
        GpsSample(ts: 12000, lat: 0, lon: 0, color: 'green'),
      ];

      final clickTime = 7000;
      final startTime = clickTime - 5000; // 2000
      final endTime = clickTime + 5000;   // 12000

      for (final sample in samples) {
        if (sample.ts >= startTime && sample.ts <= endTime) {
          sample.userLabel = 'Pothole';
        }
      }

      expect(samples[0].userLabel, isNull);      // 1000 (outside)
      expect(samples[1].userLabel, equals('Pothole')); // 4000 (inside)
      expect(samples[2].userLabel, equals('Pothole')); // 6000 (inside)
      expect(samples[3].userLabel, equals('Pothole')); // 9000 (inside)
      expect(samples[4].userLabel, equals('Pothole')); // 12000 (inside)
    });
  });

  group('Requirement Ingestion: Synthetic Sensor Source Serialization Tests', () {
    test('Verifies SyntheticSensorSource loads mock JSON structures accurately', () {
      final mockData = {
        'imu': {
          'ax': [0.0, 0.1],
          'ay': [0.0, -0.1],
          'az': [1.0, 1.2]
        },
        'gps': {
          'lat': [37.77, 37.78],
          'lon': [-122.43, -122.44],
          'speed': [10.0, 12.0]
        }
      };

      final source = SyntheticSensorSource(mockData, const Duration(milliseconds: 100));

      // Manually pull GPS positions to verify parsing accuracy
      expect(source.getCurrentPosition(), completion(predicate<Position>((p) {
        return p.latitude == 37.77 && p.longitude == -122.43 && p.speed == 10.0;
      })));

      expect(source.getCurrentPosition(), completion(predicate<Position>((p) {
        return p.latitude == 37.78 && p.longitude == -122.44 && p.speed == 12.0;
      })));
    });

    test('Verifies loading actual mixed_real_world.json scenario', () async {
      final path = '/Users/suyashpandya/Desktop/pothole_inference_engine/out/mixed_real_world.json';
      final source = await SyntheticSensorSource.fromFile(path, const Duration(milliseconds: 10));
      expect(source.traceData['imu']['ax'], isNotEmpty);
      final firstPos = await source.getCurrentPosition();
      expect(firstPos.latitude, isNotNull);
    });

    test('Verifies loading actual adversarial.json scenario', () async {
      final path = '/Users/suyashpandya/Desktop/pothole_inference_engine/out/adversarial.json';
      final source = await SyntheticSensorSource.fromFile(path, const Duration(milliseconds: 10));
      expect(source.traceData['imu']['ax'], isNotEmpty);
      final firstPos = await source.getCurrentPosition();
      expect(firstPos.latitude, isNotNull);
    });

    test('Verifies loading actual sf_to_fremont.json scenario', () async {
      final path = '/Users/suyashpandya/Desktop/pothole_inference_engine/out/sf_to_fremont.json';
      final source = await SyntheticSensorSource.fromFile(path, const Duration(milliseconds: 10));
      expect(source.traceData['imu']['ax'], isNotEmpty);
      final firstPos = await source.getCurrentPosition();
      expect(firstPos.latitude, isNotNull);
    });
  });

  group('Offline Algorithm Sandbox Tests', () {
    test('First-order High-Pass Filter removes low-frequency signals', () {
      // Input signal: slow linear ramp (drift) of 0.01g per sample, plus a high-frequency jump
      // az = 0.0, 0.01, 0.02, 0.03, 0.04, 0.05, 0.05, 0.05, 1.05 (sharp spike)
      final List<double> az = [0.0, 0.01, 0.02, 0.03, 0.04, 0.05, 0.05, 0.05, 1.05];
      final List<double> hpzResult = [];

      double lastHpZ = 0.0;
      double lastAz = 0.0;

      for (int i = 0; i < az.length; i++) {
        double hpZ = 0.0;
        if (i > 0) {
          hpZ = 0.88 * (lastHpZ + az[i] - lastAz);
        }
        lastHpZ = hpZ;
        lastAz = az[i];
        hpzResult.add(hpZ);
      }

      // During slow drift (index 1 to 5), the high-pass filter output should be attenuated
      expect(hpzResult[1], closeTo(0.0088, 0.0001));
      // By step 5, it should be well below the raw cumulative value 0.05
      expect(hpzResult[5], lessThan(0.05));

      // At step 8, we inject a sharp spike (+1.0 g change: 0.05 -> 1.05)
      // The high-pass filter should pass the sharp spike through clearly
      expect(hpzResult[8], greaterThan(0.8));
    });

    test('Covariance gating detects X/Y and Z correlation and suppresses vibration', () {
      // 1. Correlated data (wobbly mount simulation): both axes grow together
      final List<double> hMagCorrelated = List.generate(50, (i) => i * 0.02);
      final List<double> vMagCorrelated = List.generate(50, (i) => i * 0.02);

      double computeCorrelation(List<double> hHistory, List<double> vHistory) {
        final double avgH = hHistory.reduce((a, b) => a + b) / hHistory.length;
        final double avgV = vHistory.reduce((a, b) => a + b) / vHistory.length;
        double num = 0.0;
        double denH = 0.0;
        double denV = 0.0;

        for (int k = 0; k < hHistory.length; k++) {
          final diffH = hHistory[k] - avgH;
          final diffV = vHistory[k] - avgV;
          num += diffH * diffV;
          denH += diffH * diffH;
          denV += diffV * diffV;
        }
        final double den = math.sqrt(denH * denV);
        if (den > 0.0001) return num / den;
        return 0.0;
      }

      final rCorrelated = computeCorrelation(hMagCorrelated, vMagCorrelated);
      expect(rCorrelated, closeTo(1.0, 0.001)); // Perfect correlation

      // 2. Uncorrelated data (stiff mount road vibration simulation): Z has spikes, horizontal is flat
      final List<double> hMagUncorrelated = List.filled(50, 0.05);
      final List<double> vMagUncorrelated = List.generate(50, (i) => i % 2 == 0 ? 0.05 : 0.4);

      final rUncorrelated = computeCorrelation(hMagUncorrelated, vMagUncorrelated);
      expect(rUncorrelated.abs(), lessThan(0.1)); // Flat line correlation is 0
    });

    test('First-order Low-Pass Filter attenuates high-frequency spikes', () {
      // Simulated impulse: 0.0, 0.0, 1.0 (spike), 0.0, 0.0
      final List<double> vert = [0.0, 0.0, 1.0, 0.0, 0.0];
      final List<double> lpResult = [];

      double lastLp = 0.0;
      for (int i = 0; i < vert.length; i++) {
        double lp = vert[i];
        if (i > 0) {
          lp = 0.38 * vert[i] + 0.62 * lastLp;
        }
        lastLp = lp;
        lpResult.add(lp);
      }

      // At step 2, raw spike is 1.0. Low-pass should damp it significantly.
      expect(lpResult[2], closeTo(0.38, 0.001));
      // By step 3, lp should slowly decay
      expect(lpResult[3], closeTo(0.2356, 0.001));
    });
  });

  group('High-Frequency Real-time Anomaly Detection Tests', () {
    test('Pothole trigger and cooldown logic', () {
      // Simulate real-time pothole triggers
      int lastPotholeAlertTime = 0;
      int alertCount = 0;

      void checkPothole(int now, double zScore) {
        if (zScore >= 4.0) {
          if (lastPotholeAlertTime == 0 || now - lastPotholeAlertTime >= 3000) {
            lastPotholeAlertTime = now;
            alertCount++;
          }
        }
      }

      // First pothole event at t=1000
      checkPothole(1000, 4.2);
      expect(alertCount, equals(1));

      // Duplicate trigger within 3-second cooldown at t=2000
      checkPothole(2000, 4.5);
      expect(alertCount, equals(1)); // should be suppressed

      // Trigger after cooldown at t=4050
      checkPothole(4050, 4.1);
      expect(alertCount, equals(2));
    });

    test('Sudden braking trigger and cooldown logic', () {
      int lastBrakingAlertTime = 0;
      int alertCount = 0;

      void checkBraking(int now, bool isBraking) {
        if (isBraking) {
          if (lastBrakingAlertTime == 0 || now - lastBrakingAlertTime >= 4000) {
            lastBrakingAlertTime = now;
            alertCount++;
          }
        }
      }

      // First braking event at t=1000
      checkBraking(1000, true);
      expect(alertCount, equals(1));

      // Duplicate within cooldown at t=3000
      checkBraking(3000, true);
      expect(alertCount, equals(1)); // suppressed

      // Event after cooldown at t=5100
      checkBraking(5100, true);
      expect(alertCount, equals(2));
    });

    test('Rough road trigger and hysteresis logic', () {
      int? roughRoadActiveSince;
      int lastRoughSampleTime = 0;
      int lastRoughRoadAlertTime = 0;
      int alertCount = 0;

      void processSample(int now, double zScore) {
        if (zScore >= 3.0) {
          lastRoughSampleTime = now;
          if (roughRoadActiveSince == null) {
            roughRoadActiveSince = now;
          } else if (now - roughRoadActiveSince! >= 3000) {
            if (lastRoughRoadAlertTime == 0 || now - lastRoughRoadAlertTime >= 10000) {
              lastRoughRoadAlertTime = now;
              alertCount++;
            }
            roughRoadActiveSince = null;
          }
        } else {
          if (roughRoadActiveSince != null && now - lastRoughSampleTime > 1000) {
            roughRoadActiveSince = null;
          }
        }
      }

      // Start rough road at t=1000
      processSample(1000, 3.2);
      expect(roughRoadActiveSince, equals(1000));
      expect(alertCount, equals(0));

      // Sample at t=2000 (1s in)
      processSample(2000, 3.4);
      expect(roughRoadActiveSince, equals(1000));

      // Momentary dip at t=2500 (Z < 3.0)
      processSample(2500, 2.8);
      // Hysteresis allows it to continue since last rough sample (t=2000) was < 1000ms ago
      expect(roughRoadActiveSince, equals(1000));

      // Rough sample at t=3200
      processSample(3200, 3.5);
      expect(roughRoadActiveSince, equals(1000));

      // Trigger rough road alert at t=4100 (elapsed time: 3100ms >= 3000ms)
      processSample(4100, 3.6);
      expect(alertCount, equals(1));
      expect(roughRoadActiveSince, isNull); // Reset after trigger

      // Let's test a complete drop out and reset
      processSample(5000, 3.2);
      expect(roughRoadActiveSince, equals(5000));
      
      // Drop out for > 1000ms
      processSample(5500, 1.2);
      processSample(6100, 1.1); // at t=6100, now - lastRoughSampleTime (5000) = 1100ms > 1000ms
      expect(roughRoadActiveSince, isNull); // Should reset
    });

    test('Orientation-independent yaw rate turn detection and suppression', () {
      // Helper function to calculate projected yaw rate (same formula as in sensor_isolate.dart)
      double calculateYawRate(double gx, double gy, double gz, Vector3 gravity) {
        final gNorm = gravity.normalized();
        return (gx * gNorm.x + gy * gNorm.y + gz * gNorm.z).abs();
      }

      final turnThreshold = 0.3; // turnYawThresholdRads

      // Case 1: Phone is flat (Gravity is along Z axis: [0, 0, 1])
      final gravityFlat = Vector3(0.0, 0.0, 1.0);
      
      // Rotation is purely around the Z axis (flat yaw)
      expect(calculateYawRate(0.0, 0.0, 0.4, gravityFlat), greaterThan(turnThreshold)); // turns
      expect(calculateYawRate(0.4, 0.0, 0.0, gravityFlat), lessThan(turnThreshold));    // roll (not yaw)

      // Case 2: Phone is mounted upright in portrait mode (Gravity is along Y axis: [0, 1, 0])
      final gravityUprightY = Vector3(0.0, 1.0, 0.0);
      
      // Yaw rotation in the car (vertical relative to earth) is now around the phone's Y axis
      expect(calculateYawRate(0.0, 0.4, 0.0, gravityUprightY), greaterThan(turnThreshold)); // turns
      expect(calculateYawRate(0.0, 0.0, 0.4, gravityUprightY), lessThan(turnThreshold));    // pitch (not yaw)

      // Case 3: Phone is mounted at an angle (Gravity is [0.5, 0.8, 0.3])
      final gravityAngled = Vector3(0.5, 0.8, 0.3);
      final gNorm = gravityAngled.normalized();
      // Rotation parallel to gravity (yaw relative to earth)
      final turnGyro = gNorm * 0.4; // 0.4 rad/s rotation exactly around gravity vector
      expect(calculateYawRate(turnGyro.x, turnGyro.y, turnGyro.z, gravityAngled), closeTo(0.4, 0.0001));
      expect(calculateYawRate(turnGyro.x, turnGyro.y, turnGyro.z, gravityAngled), greaterThan(turnThreshold));
    });

    test('Speed-adaptive double-hit bump classification', () {
      final minWheelbase = 2.0;
      final maxWheelbase = 3.5;
      final toleranceMs = 200;

      bool isDoubleHit(int elapsedMs, double speedKmh) {
        final speedMps = speedKmh / 3.6;
        if (speedMps < 2.0) {
          return elapsedMs >= 300 && elapsedMs <= 2500;
        } else {
          final minDelay = (minWheelbase / speedMps) * 1000;
          final maxDelay = (maxWheelbase / speedMps) * 1000;
          final lower = math.max(100.0, minDelay - toleranceMs);
          final upper = maxDelay + toleranceMs;
          return elapsedMs >= lower && elapsedMs <= upper;
        }
      }

      // Speed 1: low speed = 5.0 km/h (1.38 m/s) -> falls back to [300, 2500] ms
      expect(isDoubleHit(200, 5.0), isFalse);
      expect(isDoubleHit(300, 5.0), isTrue);
      expect(isDoubleHit(1000, 5.0), isTrue);
      expect(isDoubleHit(2500, 5.0), isTrue);
      expect(isDoubleHit(2600, 5.0), isFalse);

      // Speed 2: medium speed = 36.0 km/h (10.0 m/s)
      // expected delay window: [2.0/10 * 1000, 3.5/10 * 1000] = [200, 350] ms
      // with tolerance: lower = max(100, 200-200) = 100ms, upper = 350+200 = 550ms
      expect(isDoubleHit(80, 36.0), isFalse);
      expect(isDoubleHit(100, 36.0), isTrue);
      expect(isDoubleHit(300, 36.0), isTrue);
      expect(isDoubleHit(550, 36.0), isTrue);
      expect(isDoubleHit(560, 36.0), isFalse);

      // Speed 3: high speed = 72.0 km/h (20.0 m/s)
      // expected delay window: [2.0/20 * 1000, 3.5/20 * 1000] = [100, 175] ms
      // with tolerance: lower = max(100, 100-200) = 100ms, upper = 175+200 = 375ms
      expect(isDoubleHit(90, 72.0), isFalse);
      expect(isDoubleHit(100, 72.0), isTrue);
      expect(isDoubleHit(200, 72.0), isTrue);
      expect(isDoubleHit(375, 72.0), isTrue);
      expect(isDoubleHit(380, 72.0), isFalse);
    });
  });
}
