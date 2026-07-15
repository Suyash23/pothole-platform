/// Data models representing GPS positions, accelerometer samples, recording settings,
/// and anomaly configuration thresholds.
///
/// If you are looking for specific configuration numbers or thresholds for the active filters
/// (such as phone handling gates or battery settings), inspect the [DetectionConfig] class.

/// Canonical event vocabulary.
///
/// Historically the same concept was stored three different ways (e.g. a pothole
/// as `userLabel='Pothole'`, `userLabel='pothole'`, and never as a flag; a bump
/// as both the `is_bump` column and `userLabel='bump'`). That fragmentation made
/// the collected data almost unusable for training/validation.
///
/// From v1.3.0 every label — whether produced by the detector or a human — is
/// normalised to one of these canonical snake_case strings before it is stored
/// or uploaded. Use [EventTypes.normalize] at every boundary.
class EventTypes {
  static const String pothole = 'pothole';
  static const String speedBump = 'speed_bump';
  static const String concreteJoint = 'concrete_joint';
  static const String bump = 'bump';
  static const String roughRoad = 'rough_road';
  static const String laneChange = 'lane_change';
  static const String turn = 'turn';
  static const String braking = 'braking';
  static const String tap = 'tap';

  static const List<String> all = [
    pothole, speedBump, concreteJoint, bump,
    roughRoad, laneChange, turn, braking, tap,
  ];

  /// Maps any legacy / display spelling to the canonical token.
  /// Returns the input lower-cased with spaces→underscores if unknown, so we
  /// never silently drop a label we don't recognise.
  static String normalize(String raw) {
    final key = raw.trim().toLowerCase().replaceAll(' ', '_');
    switch (key) {
      case 'pothole':
        return pothole;
      case 'speed_bump':
      case 'speedbump':
        return speedBump;
      case 'concrete_joint':
      case 'joint':
        return concreteJoint;
      case 'bump':
        return bump;
      case 'rough_road':
      case 'rough':
        return roughRoad;
      case 'lane_change':
      case 'lanechange':
        return laneChange;
      case 'turn':
        return turn;
      case 'braking':
      case 'brake':
        return braking;
      case 'tap':
      case 'tapping':
      case 'device_tapping':
        return tap;
      default:
        return key;
    }
  }
}

/// Source of a ground-truth annotation. Kept separate from the detector's own
/// output so the two are never confused (the core data-quality fix in v1.3.0).
class GtSource {
  /// Human tapped "Confirm" on a detector alert → positive ground truth.
  static const String confirm = 'confirm';

  /// Human tapped "False alarm" on a detector alert → negative ground truth.
  static const String falseAlarm = 'false_alarm';

  /// Human pressed a side "Mark X" button → positive ground truth, no alert.
  static const String manual = 'manual';

  /// Human corrected a detector alert to a different type ("that was not a
  /// concrete joint, it was a pothole"). Stored as a PAIR of events sharing
  /// this source and the same anchor timestamp: a NEGATIVE for the detector's
  /// type (isFalse=true) and a POSITIVE for the human-corrected type. This is
  /// richer training signal than a bare false alarm, because it says what the
  /// event actually was (v1.3.1).
  static const String reclassify = 'reclassify';

  /// Produced by the detection algorithm itself (NOT ground truth).
  static const String detector = 'detector';
}

/// Represents a single GPS location update combined with local motion, vibration,
/// and computed road roughness scores.
class GpsSample {
  GpsSample({
    required this.ts,
    required this.lat,
    required this.lon,
    required this.color,
    this.accelVal = 0.0,
    this.zScore = 0.0,
    this.speed = 0.0,
    this.ax = 0.0,
    this.ay = 0.0,
    this.az = 0.0,
    this.gx = 0.0,
    this.gy = 0.0,
    this.gz = 0.0,
    this.userLabel,
    this.gravX = 0.0,
    this.gravY = 0.0,
    this.gravZ = 0.0,
    this.rawAx = 0.0,
    this.rawAy = 0.0,
    this.rawAz = 0.0,
    this.altitude = 0.0,
    this.heading = 0.0,
    this.speedAccuracy = 0.0,
    this.headingAccuracy = 0.0,
    this.altitudeAccuracy = 0.0,
    this.isBraking = false,
    this.isTapping = false,
    this.isBump = false,
    this.isLaneChange = false,
    this.detectorLabel,
    this.gtLabel,
    this.gtSource,
    this.gtIsFalse = false,
  });

  /// Timestamp in milliseconds since epoch.
  final int ts;

  /// Latitude coordinate.
  final double lat;

  /// Longitude coordinate.
  final double lon;

  /// Map display color ('green', 'yellow', 'red') indicating road roughness.
  final String color;

  /// Smoothed vertical acceleration value.
  final double accelVal;

  /// Rolling Z-score showing how anomalous this vibration is compared to the baseline.
  final double zScore;

  /// GPS-reported vehicle speed in meters per second.
  final double speed;

  /// Dynamic linear acceleration values along the phone's local coordinate axes (filtered/gravity removed).
  final double ax;
  final double ay;
  final double az;

  /// Angular velocity values from the gyroscope.
  final double gx;
  final double gy;
  final double gz;

  /// User-defined event label (e.g., 'pothole', 'speed_bump').
  String? userLabel;

  /// Estimated gravity vector components in the phone's frame.
  final double gravX;
  final double gravY;
  final double gravZ;

  /// Raw unfiltered accelerometer measurements (includes gravity).
  final double rawAx;
  final double rawAy;
  final double rawAz;

  /// Altitude in meters above the WGS 84 reference ellipsoid.
  final double altitude;

  /// Bearing/direction of travel in degrees (0.0 - 360.0).
  final double heading;

  /// Accuracy metrics estimated by the GPS sensor.
  final double speedAccuracy;
  final double headingAccuracy;
  final double altitudeAccuracy;

  /// Anomaly flag indicating whether sudden deceleration (braking) was detected.
  bool isBraking;

  /// Anomaly flag indicating whether a screen tapping event was registered by the user.
  bool isTapping;

  /// Anomaly flag indicating whether a bump (double hit) was registered.
  bool isBump;

  /// Anomaly flag indicating whether the vehicle was performing a lane change
  /// when this sample was recorded. Samples tagged true should not be counted
  /// as road defects — raised pavement markers between lanes are expected.
  bool isLaneChange;

  /// Canonical detector classification anchored at this sample, if the detector
  /// fired an event here (see [EventTypes]). This is the algorithm's own output
  /// — NEVER treat it as ground truth. Null when no detector event anchors here.
  String? detectorLabel;

  /// Canonical HUMAN ground-truth label at/near this sample (see [EventTypes]).
  /// Null unless a person confirmed an alert or pressed a manual mark button.
  String? gtLabel;

  /// Where [gtLabel] came from (see [GtSource]): 'confirm' | 'false_alarm' | 'manual'.
  String? gtSource;

  /// When true, [gtLabel] is a NEGATIVE label: a human said "there is NO
  /// <gtLabel> here" (i.e. the detector's alert was a false positive). This is
  /// the single most valuable signal for driving the false-positive rate down,
  /// and before v1.3.0 it was silently discarded.
  bool gtIsFalse;

  /// Creates a [GpsSample] from a SQLite row query map.
  factory GpsSample.fromRow(Map<String, Object?> row) {
    return GpsSample(
      ts: row['ts'] as int,
      lat: row['lat'] as double,
      lon: row['lon'] as double,
      color: (row['accel_color'] as String?) ?? 'green',
      accelVal: (row['accel_val'] as num?)?.toDouble() ?? 0.0,
      zScore: (row['z_score'] as num?)?.toDouble() ?? 0.0,
      speed: (row['speed'] as num?)?.toDouble() ?? 0.0,
      ax: (row['ax'] as num?)?.toDouble() ?? 0.0,
      ay: (row['ay'] as num?)?.toDouble() ?? 0.0,
      az: (row['az'] as num?)?.toDouble() ?? 0.0,
      gx: (row['gx'] as num?)?.toDouble() ?? 0.0,
      gy: (row['gy'] as num?)?.toDouble() ?? 0.0,
      gz: (row['gz'] as num?)?.toDouble() ?? 0.0,
      userLabel: row['user_label'] as String?,
      gravX: (row['grav_x'] as num?)?.toDouble() ?? 0.0,
      gravY: (row['grav_y'] as num?)?.toDouble() ?? 0.0,
      gravZ: (row['grav_z'] as num?)?.toDouble() ?? 0.0,
      rawAx: (row['raw_ax'] as num?)?.toDouble() ?? 0.0,
      rawAy: (row['raw_ay'] as num?)?.toDouble() ?? 0.0,
      rawAz: (row['raw_az'] as num?)?.toDouble() ?? 0.0,
      altitude: (row['altitude'] as num?)?.toDouble() ?? 0.0,
      heading: (row['heading'] as num?)?.toDouble() ?? 0.0,
      speedAccuracy: (row['speed_accuracy'] as num?)?.toDouble() ?? 0.0,
      headingAccuracy: (row['heading_accuracy'] as num?)?.toDouble() ?? 0.0,
      altitudeAccuracy: (row['altitude_accuracy'] as num?)?.toDouble() ?? 0.0,
      isBraking: (row['is_braking'] as int?) == 1,
      isTapping: (row['is_tapping'] as int?) == 1,
      isBump: (row['is_bump'] as int?) == 1,
      isLaneChange: (row['is_lane_change'] as int?) == 1,
      detectorLabel: row['detector_label'] as String?,
      gtLabel: row['gt_label'] as String?,
      gtSource: row['gt_source'] as String?,
      gtIsFalse: (row['gt_is_false'] as int?) == 1,
    );
  }
}

/// A single discrete road/driving event — the queryable unit for analysis.
///
/// Before v1.3.0 events lived only as flags smeared across ~10 s of GPS samples
/// inside 500-sample Firestore array documents, which could not be queried by
/// type. Each [RoadEvent] is now stored as its own row/document so that "give me
/// every confirmed pothole" is a real query, and so that late human labels are
/// never lost to already-flushed sample batches.
class RoadEvent {
  RoadEvent({
    required this.ts,
    this.endTs,
    required this.type,
    required this.source,
    this.zScore = 0.0,
    this.peakG = 0.0,
    this.jerk = 0.0,
    this.speedKmh = 0.0,
    this.lat,
    this.lon,
    this.isFalse = false,
  });

  /// Anchor timestamp (ms since epoch) — the moment of the event, not the button press.
  final int ts;

  /// Optional end timestamp for events that span a window (bump, lane change, rough road).
  final int? endTs;

  /// Canonical event type (see [EventTypes]).
  final String type;

  /// Provenance (see [GtSource]): 'detector' | 'confirm' | 'false_alarm' | 'manual'.
  final String source;

  /// Rolling Z-score at the anchor (relative severity).
  final double zScore;

  /// Physical peak vertical acceleration in g (absolute severity).
  final double peakG;

  /// Physical peak jerk (|d(accel)/dt|) in g/s — the sharpness feature that
  /// separates a pothole (sharp) from a speed bump (smooth heave).
  final double jerk;

  /// Vehicle speed (km/h) at the event.
  final double speedKmh;

  /// Optional location of the event.
  final double? lat;
  final double? lon;

  /// True for a negative label (a rejected/false detector alert).
  final bool isFalse;

  Map<String, dynamic> toMap() => {
        'ts': ts,
        'endTs': endTs,
        'type': type,
        'source': source,
        'zScore': zScore,
        'peakG': peakG,
        'jerk': jerk,
        'speedKmh': speedKmh,
        'lat': lat,
        'lon': lon,
        'isFalse': isFalse,
      };

  factory RoadEvent.fromRow(Map<String, Object?> row) => RoadEvent(
        ts: row['ts'] as int,
        endTs: row['end_ts'] as int?,
        type: row['type'] as String,
        source: row['source'] as String,
        zScore: (row['z_score'] as num?)?.toDouble() ?? 0.0,
        peakG: (row['peak_g'] as num?)?.toDouble() ?? 0.0,
        jerk: (row['jerk'] as num?)?.toDouble() ?? 0.0,
        speedKmh: (row['speed_kmh'] as num?)?.toDouble() ?? 0.0,
        lat: (row['lat'] as num?)?.toDouble(),
        lon: (row['lon'] as num?)?.toDouble(),
        isFalse: (row['is_false'] as int?) == 1,
      );
}

/// Represents a single accelerometer vibration measurement.
class AccelSample {
  AccelSample(this.ts, this.vertAccel, {this.zScore = 0.0});

  /// Timestamp in milliseconds.
  final int ts;

  /// Calculated vertical acceleration (projected onto gravity axis, removing Earth gravity).
  final double vertAccel;

  /// The rolling Z-score at the time this sample was taken.
  final double zScore;
}

/// Defines sampling rates for a recording mode.
class FidelityPreset {
  const FidelityPreset(this.gpsHz, this.accelHz);

  /// Target frequency of GPS location requests.
  final double gpsHz;

  /// Target frequency of accelerometer and gyroscope polling.
  final double accelHz;
}

/// Represents the metadata of a recorded driving session.
class Trip {
  Trip({
    required this.id,
    required this.startTimeMs,
    this.endTimeMs,
    required this.fidelity,
    this.scenario,
    this.vehicle,
    this.mountType,
    this.deviceModel,
    this.osVersion,
  });

  /// Unique trip ID (primary key in SQLite).
  final int id;

  /// Trip start timestamp (ms since epoch).
  final int startTimeMs;

  /// Trip end timestamp (ms since epoch).
  final int? endTimeMs;

  /// Pinned recording fidelity mode ('high', 'medium', or 'low').
  final String fidelity;

  /// Categorical test scenario (e.g. 'Normal Drive', 'Speed Bumps').
  final String? scenario;

  /// Vehicle description (e.g. 'Tesla Model Y').
  final String? vehicle;

  /// Mount type information (e.g. 'Stiff Mount', 'Vent Clip').
  final String? mountType;

  /// Device hardware model name.
  final String? deviceModel;

  /// Host operating system version.
  final String? osVersion;

  /// Creates a [Trip] object from a SQLite query map.
  factory Trip.fromRow(Map<String, Object?> row) {
    return Trip(
      id: row['id'] as int,
      startTimeMs: row['start_time'] as int,
      endTimeMs: row['end_time'] as int?,
      fidelity: row['fidelity'] as String,
      scenario: row['scenario'] as String?,
      vehicle: row['vehicle'] as String?,
      mountType: row['mount_type'] as String?,
      deviceModel: row['device_model'] as String?,
      osVersion: row['os_version'] as String?,
    );
  }
}

/// Central configuration class defining default parameters for anomaly detection,
/// signal processing, adaptive sampling, and privacy trimming.
class DetectionConfig {
  // A1: Phone Handling Filters
  /// Minimum vehicle speed in km/h before we consider IMU data valid (prevents picking up phone handling when parked).
  /// Raised from 5.0 to 10.0: at 5 km/h the vehicle is barely moving (walking pace),
  /// which allowed false positives from phone handling in slow parking-lot situations.
  static const double gpsSpeedGateKmh = 10.0;

  /// Rotational velocity threshold in rad/s. Gyroscope readings above this indicate the phone is being moved by hand.
  static const double gyroThresholdRads = 2.0;

  /// Maximum angular shift in gravity vector direction (degrees) allowed within the stability window.
  static const double mountStabilityAngleDeg = 10.0;

  /// Window in milliseconds used to measure mount angular shift.
  static const int mountStabilityWindowMs = 1000;

  /// Suppression period in milliseconds after phone movement is detected, during which anomaly triggers are muted.
  static const int mountStabilitySuppressMs = 3000;

  // A7: Privacy Trimming
  /// Length in meters trimmed off the start and end of trips to obfuscate exact origin/destination coordinates.
  static const double trimDistanceMeters = 200.0;

  // Manual-mark reaction window (v1.3.0)
  //
  // When a driver presses a "Mark X" button, the physical event happened a
  // moment earlier (perception + reaction). Instead of smearing the label across
  // ±5 s of road, we snap it onto the acceleration peak inside the pre-press
  // window [pressTs - markReactionMaxMs, pressTs - markReactionMinMs].
  static const int markReactionMinMs = 300;
  static const int markReactionMaxMs = 2500;

  // A4: Sampling rate
  //
  // v1.3.0: adaptive sampling (rebinding sensor subscriptions 25→100→25 Hz on a
  // Z-score trigger) was REMOVED. Tearing down and recreating the sensor streams
  // at the onset of an anomaly dropped samples exactly when resolution mattered
  // most, and coupled detection to stream-restart latency. We now sample at a
  // single fixed rate and decimate for storage. The old constants are retained
  // only for backwards compatibility with older tests/tools and are unused.
  static const double samplingHz = 50.0; // fixed capture rate
  static const double storageDecimateHz = 25.0; // accel_samples written at this rate

  @Deprecated('Adaptive sampling removed in v1.3.0 — use samplingHz')
  static const double baselineSamplingHz = 25.0;
  @Deprecated('Adaptive sampling removed in v1.3.0 — use samplingHz')
  static const double triggerSamplingHz = 100.0;
  @Deprecated('Adaptive sampling removed in v1.3.0')
  static const double adaptivePreTriggerZScore = 1.5;
  @Deprecated('Adaptive sampling removed in v1.3.0')
  static const int adaptiveBurstDurationMs = 1000;
  static const double batterySaverBaselineHz = 10.0;
  static const double batterySaverTriggerHz = 50.0;

  // Z-Score Baseline Robustness
  /// Minimum standard deviation (in g) to prevent division by zero or extreme Z-score inflation on perfect roads.
  static const double minStdDevG = 0.03;

  /// Maximum Z-score value permitted before capping (Winsorizing) to prevent outliers from distorting the rolling baseline.
  static const double winsorizeZ = 2.5;

  // Turn Detection
  /// Gyro yaw rate (rad/s) above which we consider the vehicle to be turning.
  /// Typical 90-degree turn ≈ 0.3–0.7 rad/s. Phone-handling gate is 2.0 rad/s (much higher).
  static const double turnYawThresholdRads = 0.3;

  /// Gyro yaw rate (rad/s) above which we suppress sudden braking alerts.
  /// Gradual turns/ramps ≈ 0.15 rad/s.
  static const double brakingYawSuppressRads = 0.15;

  /// How long the yaw rate must exceed the threshold before a turn event fires (ms).
  static const int turnMinDurationMs = 400;

  /// Minimum gap between consecutive turn alerts (ms).
  static const int turnCooldownMs = 5000;

  // Speed Bump (broad, medium-amplitude impulse)
  /// Minimum Z-score for a speed bump candidate.
  static const double speedBumpMinZ = 2.5;

  /// Exceedance must last at least this long to be classified as a speed bump (ms).
  static const int speedBumpMinDurationMs = 200;

  /// Exceedance longer than this is more likely rough road than a discrete bump (ms).
  static const int speedBumpMaxDurationMs = 750;

  /// Minimum gap between consecutive speed bump alerts (ms).
  static const int speedBumpCooldownMs = 5000;

  // Concrete Joint (brief, lower-amplitude spike)
  /// Minimum Z-score for a concrete joint candidate.
  static const double concreteJointMinZ = 1.5;

  /// Peak Z must stay below this — above it the event is more likely a pothole.
  static const double concreteJointMaxZ = 4.0;

  /// Maximum exceedance duration for a concrete joint (ms). Longer events are bumps or potholes.
  static const int concreteJointMaxDurationMs = 100;

  /// Minimum gap between consecutive concrete joint alerts (ms).
  ///
  /// v1.3.1: raised 1500 → 4000. On 2026-07-01 drive data joints were 72% of
  /// all alerts (54/75), firing every 1.5–2 s on ordinary highway texture.
  ///
  /// v1.3.2: raised 4000 → 7000. The driver still couldn't keep up on a
  /// jointed-concrete drive (2026-07-02): even one joint alert per 4 s is far
  /// more than a human can confirm/correct while also watching the road, and
  /// jointed concrete highway can clear the per-alert gates continuously for
  /// minutes at a time. 7 s caps volume to a level a driver can actually act
  /// on; the storm guard below (now tighter) takes over for anything denser.
  static const int concreteJointCooldownMs = 7000;

  /// v1.3.1: absolute floor (g) for a concrete joint. The old floor was
  /// [impulseEntryG] (0.12 g) which ordinary asphalt texture clears constantly
  /// at 60+ km/h (drive data showed joints at peakG 0.12–0.16 every ~2 s).
  static const double concreteJointMinPeakG = 0.18;

  /// v1.3.1: relative gate for a concrete joint against the RAW baseline.
  /// Joints were the only impulse class with NO relative gate, so they became
  /// a catch-all for surface texture. A real joint must stand out from the
  /// recent road, not just clear a static floor.
  ///
  /// v1.3.2: raised 2.5 → 3.0 alongside the cooldown/storm changes below, to
  /// further cut candidate volume on textured-but-not-defective concrete.
  static const double concreteJointMinRawZ = 3.0;

  /// v1.3.1: joint-storm guard. If this many joint candidates pass the gates
  /// within [concreteJointStormWindowMs], the surface is textured/rough — stop
  /// emitting individual joint alerts (the sustained rough-road detector is the
  /// right classifier for that) until the rate drops again.
  ///
  /// v1.3.2: tightened 5-per-30s → 3-per-20s. At the old settings a driver on
  /// a jointed-concrete stretch still had to process up to 5 individual
  /// prompts (spread over the first ~20-28s at the new 7s cooldown) before the
  /// storm guard silenced the rest. Tripping after 3 hands off to the
  /// sustained rough-road classifier sooner, which is the correct label for a
  /// jointed surface anyway — it's road texture, not N discrete defects.
  static const int concreteJointStormCount = 3;
  static const int concreteJointStormWindowMs = 20000;

  // ── Rough patch (quick succession of potholes) ─────────────────────────────
  //
  // A "rough patch" is several genuine impacts (pothole / bump / speed bump) in
  // quick succession — a broken stretch of road, as opposed to one isolated
  // defect. It is detected by counting impact CANDIDATES (the moment they pass
  // their type gates, BEFORE the per-type cooldown throttles them) inside a
  // sliding window: [roughPatchMinImpacts] within [roughPatchWindowMs] raises a
  // single `rough_road` alert instead of a rapid-fire string of pothole pings.
  //
  // Concrete joints are deliberately NOT counted — evenly-spaced joints on a
  // smooth concrete highway are frequent but are not a rough patch (that is what
  // the joint-storm guard above is for). This targets clustered real defects.
  //
  // Sizing (2026-07-15, from the events of the roughest recent drives): impacts
  // in a genuine rough stretch arrive well under ~2 s apart even after the 3 s
  // pothole cooldown throttles the *emitted* events; counting pre-cooldown
  // candidates, 3-within-6 s reliably separates a broken patch from the isolated
  // single defects that dominate normal driving. Tune after a labelled rough
  // drive.
  static const int roughPatchWindowMs = 6000;
  static const int roughPatchMinImpacts = 3;

  /// Minimum gap between consecutive `rough_road` alerts (ms). Shared by the
  /// sustained-roughness path and the rough-patch cluster path so they cannot
  /// double-fire on the same stretch.
  static const int roughRoadCooldownMs = 10000;

  // ── Pothole detection ────────────────────────────────────────────────────
  //
  // A pothole is detected only when BOTH a relative gate (Z-score vs. rolling
  // baseline) AND an absolute physical gate (peak g and jerk) are satisfied. The
  // physical gate (see [potholeMinPeakG] / [potholeMinJerk]) makes detections
  // comparable across trips, vehicles and mounts — a σ-only trigger meant "how
  // bad is this pothole" depended on how rough the recent road was.
  //
  // Speed-adaptive Z threshold. Each row: [speedKmhLow, speedKmhHigh, zThreshold].
  //
  // v1.3.0 change: the table is now MONOTONICALLY DECREASING in speed and
  // physically motivated (faster impacts are sharper → lower relative Z is
  // still a real defect). The previous table peaked at 40–60 km/h "because
  // that's where the most data was collected", which calibrated sensitivity to
  // sampling density rather than physics and systematically missed defects at
  // under-sampled speeds.
  //
  // These remain PROVISIONAL until re-derived from labelled drives. Because the
  // absolute physical gate now runs in series, tightening/loosening these does
  // not by itself create the old ~2%-of-all-samples false-positive floor.
  // Top-20% calibration (2026-07-11): thresholds set to the 80th percentile of
  // the Z-scores of samples that the PREVIOUS thresholds already flagged, per
  // bucket, so only the worst ~20% of detected anomalies now fire. Derived from
  // 14.2k Firestore samples (speed >= 10 km/h) across 109 trips. Verified to
  // keep ≈18–20% of previously-detected events in every bucket with data.
  // Slow-city (10–20) had too few detections (3) for a stable P80, so it is set
  // to the highest value to honour the "slow speeds need a bigger spike" prior.
  static const List<List<double>> potholeSpeedThresholds = [
    [0,    20,  3.75],  // very slow — data-poor; ≥ all faster buckets by design
    [20,   40,  3.75],  // city        (P80 of detected = 3.70)
    [40,   60,  3.50],  // arterial    (P80 of detected = 3.46)
    [60,   80,  3.50],  // fast arterial (P80 of detected = 3.55)
    [80,  100,  3.50],  // freeway entry (P80 of detected = 3.44)
    [100, 9999, 3.50],  // freeway       (P80 of detected = 3.50)
  ];

  /// Fallback Z threshold used when GPS speed is unavailable or outside all buckets.
  static const double potholeFallbackThreshold = 3.50;

  /// Absolute physical gate: minimum peak vertical acceleration (g, gravity-removed)
  /// for a pothole regardless of Z-score. Prevents σ-only triggers on smooth roads
  /// where the baseline std has collapsed to [minStdDevG].
  static const double potholeMinPeakG = 0.35;

  /// Absolute physical gate: minimum peak jerk (|Δg|/Δt, g per second). Potholes
  /// are sharp; this rejects slow heaves (speed bumps) that reach the same peak g.
  static const double potholeMinJerk = 6.0;

  /// Minimum gap between consecutive pothole alerts (ms).
  ///
  /// v1.3.2: promoted out of an inline magic number in detector.dart so it's
  /// tunable/discoverable alongside the other per-type cooldowns. Value (3000)
  /// is unchanged — potholes were not the volume driver in the 2026-07-01/02
  /// data, only concrete joints were.
  static const int potholeCooldownMs = 3000;

  // ── Impulse detection on the RAW signal (v1.3.0) ───────────────────────────
  //
  // Impulse events (pothole / speed bump / concrete joint / bump) are detected
  // on the RAW vertical signal, NOT the 0.75 s moving average. Smoothing over
  // 0.75 s attenuates a sharp pothole almost to nothing, so classifying on it was
  // the root reason potholes and speed bumps were hard to tell apart. The moving
  // average is now used ONLY for the map colour and the sustained rough-road test.

  /// Raw |vertical accel| (g, gravity-removed) that opens an impulse window.
  static const double impulseEntryG = 0.12;

  /// The pothole relative gate is expressed against a RAW baseline: a pothole's
  /// peak must satisfy rawZ = (peakG - rawMean)/rawStd >= the speed-bucket value
  /// in [potholeSpeedThresholds], AND clear the absolute [potholeMinPeakG] /
  /// [potholeMinJerk] gates. Two gates in series keep detections both sensitive
  /// and comparable across trips.

  /// Absolute floor (g) for a double-hit bump candidate.
  static const double bumpMinPeakG = 0.20;

  /// A concrete joint is brief and small but still a sharp edge, so it needs a
  /// minimum jerk to separate it from gentle undulations.
  static const double concreteJointMinJerk = 3.0;

  // Lane Change Detection
  /// Minimum signed yaw rate (rad/s) to begin a lane-change phase.
  ///
  /// v1.3.1: lowered 0.12 → 0.05. The old comment claimed highway lane changes
  /// are 0.15–0.5 rad/s, but that is off by ~2×: a normal 3.5 m lane change at
  /// 100 km/h over ~4 s peaks at only ≈0.08 rad/s (peak heading ≈3°, sine
  /// profile). 0.12 was above almost every real highway lane change, which is
  /// why the 2026-07-01 highway drive produced ZERO lane_change events. Noise
  /// rejection is handled by the per-phase duration + integrated-heading gates
  /// and the cooldown, not by the raw entry threshold.
  static const double laneChangeYawMinRads = 0.05;

  /// Yaw rate above this is too aggressive for a lane change — it's a sharp turn.
  static const double laneChangeYawMaxRads = 0.80;

  /// Each yaw phase (initial deflection + return deflection) must last at least
  /// this long to be counted. Filters out brief sensor spikes.
  static const int laneChangePhaseMinMs = 300;

  /// If a single yaw phase lasts longer than this, it's a real turn, not a
  /// lane change. Reset the detector.
  ///
  /// v1.3.1: raised 2500 → 4000. Gentle highway lane changes take ~2 s per
  /// phase; 2.5 s left no headroom and aborted slow manoeuvres.
  static const int laneChangePhaseMaxMs = 4000;

  /// Maximum time allowed between the end of phase 1 and start of phase 2
  /// (the crossover zero-crossing). Longer gaps mean the driver held straight
  /// between two separate manoeuvres rather than completing one S-curve.
  ///
  /// v1.3.1: raised 800 → 1500. Drivers commonly hold ~1 s straight mid-change
  /// while straddling the line — exactly when raised markers are hit.
  static const int laneChangeCrossoverMaxMs = 1500;

  /// Minimum speed (km/h) for lane-change detection to be active.
  /// Below this we're in a parking lot, not a lane-change scenario.
  static const double laneChangeMinSpeedKmh = 30.0;

  /// How long to suppress pothole/bump/concrete-joint alerts after a confirmed
  /// lane change (covers the marker hit + sensor ring-down period).
  static const int laneChangeSuppressAfterMs = 1500;

  /// Minimum gap between two consecutive confirmed lane changes.
  ///
  /// At highway speed the absolute minimum real-world gap between lane changes
  /// is ~8 s; below this the S-curve is almost certainly road-vibration noise.
  /// At 120 km/h, normal asphalt vibration can produce rapid 0.12–0.80 rad/s
  /// yaw oscillations that complete fake S-curves every ~400 ms, keeping
  /// _lastIsLaneChange=true for 90%+ of samples without this guard.
  ///
  /// 8 s still allows two quick successive lane changes (e.g., overtaking
  /// from slow lane → fast lane → back), while eliminating the noise pattern.
  static const int laneChangeCooldownMs = 8000;

  // ── Lane change vs turn — heading-based discriminator (v1.3.0) ─────────────
  //
  // The old yaw-only S-curve state machine could not separate a lane change
  // from ordinary steering noise (its own comments admit it flagged >90% of
  // highway samples without the cooldown band-aid) and it "optimistically
  // confirmed" on a single opposite-direction blip.
  //
  // The physical distinction is the NET heading change over the manoeuvre:
  //   • a lane change returns to (nearly) the original heading  → |Δheading| small
  //   • a turn commits to a new heading                         → |Δheading| large
  // We integrate the signed yaw rate over the manoeuvre window (and cross-check
  // GPS heading when available) instead of counting sign reversals.

  /// Both S-curve phases must each reach their minimum duration before a lane
  /// change is confirmed (no more optimistic single-blip confirmation).
  static const bool laneChangeRequireBothPhases = true;

  /// Max |net integrated heading change| (degrees) across the manoeuvre for it to
  /// count as a lane change. Above this it committed to a new heading → a turn.
  static const double laneChangeMaxNetHeadingDeg = 18.0;

  /// Min |per-phase integrated heading| (degrees). Each deflection must turn the
  /// car at least this much, filtering lane-keeping micro-wander that grazes the
  /// yaw-rate threshold.
  ///
  /// v1.3.1: lowered 4.0 → 2.0. A 3.5 m lane change at 100–120 km/h only turns
  /// the car ~2.4–2.9° per phase, so 4° rejected every highway lane change.
  /// Noise half-cycles (2 Hz wander) integrate to ~1.8° and stay rejected.
  static const double laneChangeMinPhaseHeadingDeg = 2.0;

  // ── Speed bump smoothness gate (v1.3.0) ────────────────────────────────────
  /// A speed bump is a smooth heave, not a sharp edge. Its peak jerk must stay
  /// BELOW this (g/s) — above it the event is a pothole/expansion-joint edge.
  static const double speedBumpMaxJerk = 5.0;

  /// Absolute physical floor for a speed bump peak (g), so σ-only noise on a
  /// collapsed baseline cannot masquerade as a bump.
  static const double speedBumpMinPeakG = 0.20;

  // Bump (double-impact longer pulse)
  /// Minimum Z-score for a bump candidate.
  static const double bumpMinZ = 2.0;

  /// Exceedance must last at least this long to be classified as a bump candidate (ms).
  static const int bumpMinDurationMs = 150;

  /// Exceedance longer than this is more likely rough road than a discrete bump (ms).
  static const int bumpMaxDurationMs = 1000;

  /// Expected passenger vehicle wheelbase range in meters
  static const double bumpWheelbaseMinMeters = 2.0;
  static const double bumpWheelbaseMaxMeters = 3.5;

  /// Fallback double-hit delay bounds in ms when speed is very slow (< 2.0 m/s)
  static const int bumpFallbackMinDelayMs = 300;
  static const int bumpFallbackMaxDelayMs = 2500;
}
