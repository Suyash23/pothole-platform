import 'dart:async';
import 'dart:collection';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import 'models.dart';
import 'road_db.dart';
import 'sensor_source.dart';
import 'detection/detector.dart';

class IsolateInitMessage {
  IsolateInitMessage({
    required this.token,
    required this.sendPort,
    required this.tripId,
    required this.fidelity,
    this.replayFilePath,
  });
  final RootIsolateToken token;
  final SendPort sendPort;
  final int tripId;
  final String fidelity;
  final String? replayFilePath;
}

class IsolateDataMessage {
  IsolateDataMessage({
    required this.currentVibration,
    required this.recentVibrations,
    this.latestGps,
  });
  final double currentVibration;
  final List<AccelSample> recentVibrations;
  final GpsSample? latestGps;
}

class IsolateAnomalyAlert {
  IsolateAnomalyAlert({
    required this.ts,
    required this.type,
    required this.zScore,
    this.endTs,
    this.peakG = 0.0,
    this.jerk = 0.0,
    this.speedKmh = 0.0,
  });
  final int ts;
  final String type; // canonical EventTypes token
  final double zScore;
  final int? endTs;

  /// Physical severity features carried through so the recorder can persist a
  /// rich, queryable detector event (peak g and jerk distinguish pothole vs bump).
  final double peakG;
  final double jerk;
  final double speedKmh;
}

void sensorIsolateEntry(IsolateInitMessage initMessage) async {
  BackgroundIsolateBinaryMessenger.ensureInitialized(initMessage.token);
  
  final processor = SensorProcessor(
    initMessage.tripId,
    initMessage.fidelity,
    initMessage.sendPort,
    initMessage.replayFilePath,
  );
  
  await processor.start();
}

class SensorProcessor {
  SensorProcessor(this.tripId, this.fidelity, this.sendPort, this.replayFilePath);

  final int tripId;
  final String fidelity;
  final SendPort sendPort;
  final String? replayFilePath;

  Timer? _batchTimer;
  StreamSubscription<Position>? _gpsSub;

  SensorSource? _sensorSource;

  // DB Batching
  final List<Map<String, dynamic>> _gpsBatch = [];
  final List<Map<String, dynamic>> _accelBatch = [];
  final List<Map<String, dynamic>> _lcDiagBatch = [];

  // Sensors
  StreamSubscription<AccelerometerEvent>? _accelSub;
  StreamSubscription<UserAccelerometerEvent>? _userAccelSub;
  StreamSubscription<GyroscopeEvent>? _gyroSub;

  // Latest raw sensor state (shared with the gravity/gyro handlers).
  Vector3 _gravity = Vector3(0.0, 0.0, 9.81);
  final Queue<MapEntry<int, Vector3>> _gravityHistory = Queue();
  double _currentGpsSpeedKmh = 0.0;
  int _suppressUntilMs = 0;
  int _lastGpsMs = 0;
  double _lastUx = 0.0;
  double _lastUy = 0.0;
  double _lastUz = 0.0;
  double _lastGx = 0.0;
  double _lastGy = 0.0;
  double _lastGz = 0.0;
  double _lastRawAx = 0.0;
  double _lastRawAy = 0.0;
  double _lastRawAz = 0.0;

  // Detection is delegated to the pure, unit-tested [EventDetector]. All the
  // rolling-window / Z-score / lane-change / bump state now lives inside it, so
  // this isolate only does sensor plumbing + persistence.
  final EventDetector _detector = EventDetector();

  // Latest detector outputs, mirrored here for the per-sample record + UI.
  bool _lastIsBraking = false;
  double _lastSmoothed = 0.0;
  double _lastZScore = 0.0;
  bool _lastIsBump = false;
  int _bumpResetTime = 0;
  bool _lastIsLaneChange = false;

  // Charting (UI sparkline only).
  static const int _graphWindowMs = 10000;
  final Queue<AccelSample> _graphWindow = Queue<AccelSample>();
  int _lastAccelMs = 0;
  int _lastAccelStoreMs = 0; // storage decimation gate

  // Fixed capture rate. Adaptive sensor rebinding (25→100→25 Hz on a Z trigger)
  // was removed in v1.3.0 — it dropped samples at the onset of anomalies.
  final double _currentAccelHz = DetectionConfig.samplingHz;

  Future<void> start() async {
    // Setup batch writer
    _batchTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) => _flushBatch());
    
    // Init source
    if (replayFilePath != null) {
      _sensorSource = await SyntheticSensorSource.fromFile(replayFilePath!, _getSensorInterval());
    } else {
      _sensorSource = RealSensorSource(_getSensorInterval());
    }
    
    // Setup sensors
    _startSensors();
    
    // GPS
    final gpsHz = _getFidelityGpsHz(fidelity);
    _startGps(gpsHz);
  }
  
  void _startSensors() {
    _startGyro();
    _startGravity();
    _startUserAccel();
  }

  void _startGyro() {
    try {
      _gyroSub = _sensorSource!.gyroscope.listen((event) {
        _lastGx = event.x;
        _lastGy = event.y;
        _lastGz = event.z;
        final magnitude = Vector3(event.x, event.y, event.z).length;
        if (magnitude > DetectionConfig.gyroThresholdRads) {
          final now = DateTime.now().millisecondsSinceEpoch;
          // Suppress for 1500ms: a gyro spike from picking up the phone is
          // followed by seconds of re-settling — 200ms was far too short and
          // caused false positives during the transition period.
          final targetMs = now + 1500;
          if (targetMs > _suppressUntilMs) {
            _suppressUntilMs = targetMs;
          }
        }
      }, onError: (err) {
        // Safe stub for platforms without physical sensors
      });
    } catch (_) {}
  }

  void _startGravity() {
    try {
      _accelSub = _sensorSource!.accelerometer.listen((event) {
        final ax = event.x / 9.81;
        final ay = event.y / 9.81;
        final az = event.z / 9.81;
        _lastRawAx = ax;
        _lastRawAy = ay;
        _lastRawAz = az;
        final magnitude = Vector3(ax, ay, az).length;

        if ((magnitude - 1.0).abs() < 0.1) {
          const alpha = 0.95;
          _gravity = _gravity * alpha + Vector3(ax, ay, az) * (1 - alpha);

          final now = DateTime.now().millisecondsSinceEpoch;
          _gravityHistory.add(MapEntry(now, _gravity.clone()));

          final windowCutoff = now - DetectionConfig.mountStabilityWindowMs;
          while (_gravityHistory.isNotEmpty && _gravityHistory.first.key < windowCutoff) {
            _gravityHistory.removeFirst();
          }

          if (_gravityHistory.isNotEmpty) {
            final oldestGravity = _gravityHistory.first.value;
            final angleRads = _gravity.angleTo(oldestGravity);
            final angleDeg = degrees(angleRads);
            if (angleDeg > DetectionConfig.mountStabilityAngleDeg) {
              final targetMs = now + DetectionConfig.mountStabilitySuppressMs;
              if (targetMs > _suppressUntilMs) {
                _suppressUntilMs = targetMs;
              }
            }
          }
        }
      }, onError: (err) {
        // Safe stub for platforms without physical sensors
      });
    } catch (_) {}
  }

  void _startUserAccel() {
    try {
      _userAccelSub = _sensorSource!.userAccelerometer.listen((event) {
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - _lastAccelMs < (1000 / _currentAccelHz).round()) return;
        _lastAccelMs = now;

        if (_lastIsBump && now > _bumpResetTime) {
          _lastIsBump = false;
        }

        final ux = event.x / 9.81;
        final uy = event.y / 9.81;
        final uz = event.z / 9.81;
        _lastUx = ux;
        _lastUy = uy;
        _lastUz = uz;
        final gNorm = _gravity.normalized();

        final vert = Vector3(ux, uy, uz).dot(gNorm);
        double vertAbs = vert.abs();

        final bool isSuppressed = now < _suppressUntilMs;
        final bool isStationary =
            _currentGpsSpeedKmh < DetectionConfig.gpsSpeedGateKmh;

        // Orientation-independent signed yaw (projected onto the gravity axis).
        final double signedYaw =
            _lastGx * gNorm.x + _lastGy * gNorm.y + _lastGz * gNorm.z;
        // Instantaneous horizontal (longitudinal/lateral) acceleration magnitude.
        final Vector3 horizontalVector = Vector3(ux, uy, uz) - gNorm * vert;
        final double horizG = horizontalVector.length;

        // All detection now happens in the pure, testable EventDetector, driven
        // by sample timestamps (no wall-clock coupling).
        final DetectorResult result = _detector.process(
          ts: now,
          vertG: vert,
          signedYaw: signedYaw,
          horizG: horizG,
          speedKmh: _currentGpsSpeedKmh,
          headingDeg: -1.0,
          stationary: isStationary,
          suppressed: isSuppressed,
        );

        _lastSmoothed = result.smoothedVert;
        final double zScore = result.zScore;
        _lastZScore = zScore;
        _lastIsBraking = result.isBraking;
        _lastIsLaneChange = result.laneChangeActive;
        if (isSuppressed) vertAbs = 0.0;
        if (_lastIsBump && now > _bumpResetTime) _lastIsBump = false;
        _lastAccelMs = now;

        // Lane-change telemetry → SQLite (batched with the sample writes).
        for (final d in result.lcDiags) {
          _lcDiagBatch.add({
            'trip_id': tripId,
            'ts': d.ts,
            'outcome': d.outcome,
            'phase_start_ts': d.phaseStartTs,
            'phase1_ms': d.phase1Ms,
            'crossover_ms': d.crossoverMs,
            'phase2_ms': d.phase2Ms,
            'phase1_heading_deg': d.phase1HeadingDeg,
            'phase2_heading_deg': d.phase2HeadingDeg,
            'phase1_lat_m': d.phase1LatM,
            'phase2_lat_m': d.phase2LatM,
            'peak_yaw_rads': d.peakYawRads,
            'yaw_entry_rads': d.yawEntryRads,
            'speed_kmh': d.speedKmh,
          });
        }

        // Route detector events → UI alerts + per-sample detector tags.
        for (final ev in result.events) {
          if (ev.type == EventTypes.bump) {
            _lastIsBump = true;
            _bumpResetTime = now + 2000;
          }
          _tagGpsBatch(ev);
          sendPort.send(IsolateAnomalyAlert(
            ts: ev.ts,
            endTs: ev.endTs,
            type: ev.type,
            zScore: ev.zScore,
            peakG: ev.peakG,
            jerk: ev.jerk,
            speedKmh: ev.speedKmh,
          ));
        }

        _graphWindow.add(AccelSample(now, _lastSmoothed, zScore: zScore));
        final graphCutoff = now - _graphWindowMs;
        while (_graphWindow.isNotEmpty && _graphWindow.first.ts < graphCutoff) {
          _graphWindow.removeFirst();
        }

        // Detection runs at the full capture rate, but raw samples are persisted
        // at the lower storageDecimateHz to keep the DB / upload size in check.
        if (now - _lastAccelStoreMs >=
            (1000 / DetectionConfig.storageDecimateHz).round()) {
          _lastAccelStoreMs = now;
          _accelBatch.add({
            'trip_id': tripId,
            'ts': now,
            'ax': ux,
            'ay': uy,
            'az': uz,
            'vert_accel': vertAbs,
            'vert_accel_smoothed': _lastSmoothed,
            'z_score': zScore,
          });
        }

        // Send to UI ~15Hz
        if (now % 66 < 20) {
          sendPort.send(IsolateDataMessage(
            currentVibration: _lastSmoothed,
            recentVibrations: _graphWindow.toList(),
          ));
        }
      }, onError: (err) {
        // Safe stub for platforms without physical sensors
      });
    } catch (_) {}
  }
  
  Duration _getSensorInterval() {
    return Duration(microseconds: (1000000 / _currentAccelHz).round());
  }

  /// Tags GPS-batch rows inside an event's window with the detector's own
  /// classification (kept strictly separate from human ground truth).
  void _tagGpsBatch(DetectedEvent ev) {
    final int start = ev.ts - 1000;
    final int end = (ev.endTs ?? ev.ts) + 1000;
    for (final g in _gpsBatch) {
      final int ts = g['ts'] as int? ?? 0;
      if (ts >= start && ts <= end) {
        g['detector_label'] = ev.type;
        if (ev.type == EventTypes.bump) g['is_bump'] = 1;
        if (ev.type == EventTypes.laneChange) g['is_lane_change'] = 1;
      }
    }
  }

  void _startGps(double gpsHz) {
    final intervalMs = (1000 / gpsHz).round();
    _gpsSub = _sensorSource!.positionStream.listen((position) {
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastGpsMs < intervalMs) return;
      _lastGpsMs = now;

      if (position.accuracy > 25.0) return;
      _currentGpsSpeedKmh = position.speed * 3.6;

      final zScore = _lastZScore;
      final color = _colorForZScore(zScore);

      _gpsBatch.add({
        'trip_id': tripId,
        'ts': now,
        'lat': position.latitude,
        'lon': position.longitude,
        'speed': position.speed,
        'accuracy': position.accuracy,
        'accel_color': color,
        'accel_val': _lastSmoothed,
        'z_score': zScore,
        'ax': _lastUx,
        'ay': _lastUy,
        'az': _lastUz,
        'gx': _lastGx,
        'gy': _lastGy,
        'gz': _lastGz,
        'user_label': null,
        'grav_x': _gravity.x,
        'grav_y': _gravity.y,
        'grav_z': _gravity.z,
        'raw_ax': _lastRawAx,
        'raw_ay': _lastRawAy,
        'raw_az': _lastRawAz,
        'altitude': position.altitude,
        'heading': position.heading,
        'speed_accuracy': position.speedAccuracy,
        'heading_accuracy': position.headingAccuracy,
        'is_braking': _lastIsBraking ? 1 : 0,
        'is_tapping': 0,
        'is_bump': _lastIsBump ? 1 : 0,
        'is_lane_change': _lastIsLaneChange ? 1 : 0,
        'detector_label': null,
      });

      sendPort.send(IsolateDataMessage(
        currentVibration: _lastSmoothed,
        recentVibrations: _graphWindow.toList(),
        latestGps: GpsSample(
          ts: now,
          lat: position.latitude,
          lon: position.longitude,
          color: color,
          accelVal: _lastSmoothed,
          zScore: zScore,
          speed: position.speed,
          ax: _lastUx,
          ay: _lastUy,
          az: _lastUz,
          gx: _lastGx,
          gy: _lastGy,
          gz: _lastGz,
          gravX: _gravity.x,
          gravY: _gravity.y,
          gravZ: _gravity.z,
          rawAx: _lastRawAx,
          rawAy: _lastRawAy,
          rawAz: _lastRawAz,
          altitude: position.altitude,
          heading: position.heading,
          speedAccuracy: position.speedAccuracy,
          headingAccuracy: position.headingAccuracy,
          altitudeAccuracy: position.altitudeAccuracy,
          isBraking: _lastIsBraking,
          isTapping: false,
          isBump: _lastIsBump,
          isLaneChange: _lastIsLaneChange,
        ),
      ));
    });
  }

  String _colorForZScore(double zScore) {
    // Severity bands scaled to match the new data-driven thresholds.
    // Previously anchored to 4.0 (rarely triggered); now anchored to ~2.25
    // (the highest per-speed threshold from the P98 analysis).
    if (zScore >= 2.25) return 'red';    // At or above pothole threshold
    if (zScore >= 1.75) return 'orange'; // Approaching threshold — notable roughness
    if (zScore >= 1.25) return 'yellow'; // Mild roughness
    return 'green';
  }

  double _getFidelityGpsHz(String fidelity) {
    switch (fidelity) {
      case 'high': return 1.0;
      case 'medium': return 0.5;
      case 'low': return 0.2;
      default: return 0.5;
    }
  }

  Future<void> _flushBatch() async {
    if (_gpsBatch.isEmpty && _accelBatch.isEmpty && _lcDiagBatch.isEmpty) {
      return;
    }

    final db = await RoadDb.instance.database;
    final batch = db.batch();

    for (final g in _gpsBatch) {
      batch.insert('gps_samples', g);
    }
    for (final a in _accelBatch) {
      batch.insert('accel_samples', a);
    }
    for (final d in _lcDiagBatch) {
      batch.insert('lc_diags', d);
    }

    _gpsBatch.clear();
    _accelBatch.clear();
    _lcDiagBatch.clear();

    await batch.commit(noResult: true);
  }

  void stop() {
    _accelSub?.cancel();
    _userAccelSub?.cancel();
    _gyroSub?.cancel();
    _batchTimer?.cancel();
    _gpsSub?.cancel();
    _flushBatch();
  }
}
