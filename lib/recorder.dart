import 'dart:async';
import 'dart:isolate';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'models.dart';
import 'road_db.dart';
import 'sensor_isolate.dart';

class AnomalyEvent {
  AnomalyEvent({
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
  final double peakG;
  final double jerk;
  final double speedKmh;
}

class RoadRecorder extends ChangeNotifier {
  RoadRecorder(this._db);

  final RoadDb _db;

  /// Trip id of the most recently *finished* recording.
  int? _lastCompletedTripId;
  int? get lastCompletedTripId => _lastCompletedTripId;

  bool _isRecording = false;
  bool get isRecording => _isRecording;

  String _fidelity = 'high';
  String get fidelity => _fidelity;

  final ValueNotifier<double> currentVibration = ValueNotifier(0.0);
  final ValueNotifier<List<AccelSample>> recentVibrations = ValueNotifier([]);

  int? _activeTripId;
  String? _activeScenario;
  String? _activeVehicle;
  String? _activeMountType;
  String? _activeDeviceModel;
  String? _activeOsVersion;
  final List<GpsSample> _gpsSamples = [];
  List<GpsSample> get gpsSamples => List.unmodifiable(_gpsSamples);

  final StreamController<AnomalyEvent> _anomalyController =
      StreamController<AnomalyEvent>.broadcast();
  Stream<AnomalyEvent> get anomalyStream => _anomalyController.stream;

  SensorProcessor? _processor;
  ReceivePort? _receivePort;

  // ── Demo mode ────────────────────────────────────────────────────────────────
  // startDemo() bypasses sensors/GPS entirely and injects a scripted 52-second
  // sequence of GPS samples, vibration values, and anomaly events so every
  // banner and color state can be tested without driving.
  bool _isDemoMode = false;
  bool get isDemoMode => _isDemoMode;
  Timer? _demoTimer;
  int _demoTick = 0;
  double _demoStartLat = 37.773972;
  double _demoStartLon = -122.431297;

  // ── Incremental Firestore upload state ──────────────────────────────────────
  // A trip doc is created in Firestore at start(). A Timer.periodic flushes
  // new samples every [_flushIntervalSeconds] so that data is saved to the
  // cloud incrementally rather than only at stop(). If the app is force-quit
  // mid-trip, at most [_flushIntervalSeconds] of data is lost.
  DocumentReference? _firestoreDocRef;
  int _lastUploadedTs = 0;        // ts of the newest sample already uploaded
  int _firestoreBatchIndex = 0;   // next batch doc index (batch_0, batch_1 …)
  Timer? _periodicFlushTimer;

  static const int _flushIntervalSeconds = 60;
  // Minimum new samples before a periodic flush is worth sending.
  static const int _flushMinNewSamples = 30;

  // Discrete event log for this trip (detector output + human ground truth).
  // Uploaded as its own queryable `events` subcollection, and re-read from
  // SQLite at finalisation so late human labels are never lost to an
  // already-flushed (immutable) sample batch.
  final List<RoadEvent> _events = [];

  // Mid-trip, hold back the most-recent samples from upload so that samples
  // near the (not-yet-known) destination aren't streamed before privacy
  // trimming can be applied at trip end. ~60 s at 1 Hz GPS.
  static const int _destinationHoldbackMs = 60000;

  // ── Manual upload state (v1.3.2) ────────────────────────────────────────────
  // Firestore uploads had been failing silently since 2026-07-01 (trip init
  // and finalize both swallow errors into debugPrint). These fields drive a
  // visible "Upload to Firebase" button after a ride plus snackbar feedback,
  // so a failed upload is finally something the driver can SEE and retry.
  bool _isUploading = false;
  bool get isUploading => _isUploading;

  /// Completed trips still sitting in SQLite with `firestore_uploaded = 0`.
  int _pendingUploadCount = 0;
  int get pendingUploadCount => _pendingUploadCount;

  /// Re-counts pending trips from SQLite and notifies the UI.
  Future<void> refreshPendingUploadCount() async {
    try {
      _pendingUploadCount = (await _db.getUnuploadedTrips()).length;
    } catch (e) {
      debugPrint('refreshPendingUploadCount failed: $e');
    }
    notifyListeners();
  }

  /// Stamps an end time on trips that were never closed (e.g. the app was
  /// killed mid-drive) so they stop being invisible to upload, then refreshes
  /// the pending count. Skips the in-progress recording. Returns how many
  /// trips were rescued.
  Future<int> finalizeOrphanedTrips() async {
    int fixed = 0;
    try {
      fixed = await _db.finalizeOrphanTrips(excludeTripId: _activeTripId);
    } catch (e) {
      debugPrint('finalizeOrphanedTrips failed: $e');
    }
    if (fixed > 0) await refreshPendingUploadCount();
    return fixed;
  }

  // ── Serialisation helper ─────────────────────────────────────────────────────
  static Map<String, dynamic> _sampleToMap(GpsSample s) => {
    'ts': s.ts,
    'lat': s.lat,
    'lon': s.lon,
    'color': s.color,
    'accelVal': s.accelVal,
    'z_score': s.zScore,
    'speed': s.speed,
    'ax': s.ax,
    'ay': s.ay,
    'az': s.az,
    'gx': s.gx,
    'gy': s.gy,
    'gz': s.gz,
    'userLabel': s.userLabel,
    'gravX': s.gravX,
    'gravY': s.gravY,
    'gravZ': s.gravZ,
    'rawAx': s.rawAx,
    'rawAy': s.rawAy,
    'rawAz': s.rawAz,
    'altitude': s.altitude,
    'heading': s.heading,
    'speedAccuracy': s.speedAccuracy,
    'headingAccuracy': s.headingAccuracy,
    'altitudeAccuracy': s.altitudeAccuracy,
    'isBraking': s.isBraking,
    'isTapping': s.isTapping,
    'isBump': s.isBump,
    'isLaneChange': s.isLaneChange,
    // v1.3.0: detector output vs human ground truth kept in separate fields,
    // all labels canonicalised (see [EventTypes]).
    'detectorLabel': s.detectorLabel,
    'gtLabel': s.gtLabel,
    'gtSource': s.gtSource,
    'gtIsFalse': s.gtIsFalse,
  };

  // ── Public API ───────────────────────────────────────────────────────────────

  Future<void> loadLatestTrip() async {
    final tripId = await _db.getLatestTripId();
    if (tripId == null) return;
    await loadTrip(tripId);
  }

  Future<void> loadTrip(int tripId) async {
    final rows = await _db.getGpsSamples(tripId);
    _gpsSamples
      ..clear()
      ..addAll(rows.map(GpsSample.fromRow));
    notifyListeners();
  }

  // ── Ground-truth labelling (v1.3.0) ────────────────────────────────────────
  //
  // Human ground truth is now kept strictly separate from detector output and
  // is always stored under a canonical label:
  //   • confirmDetectorEvent → positive GT for an alert the human agreed with
  //   • rejectDetectorEvent  → NEGATIVE GT for a false alarm (previously thrown
  //                            away entirely — the single biggest data-quality
  //                            fix, since negatives are what reduce the FP rate)
  //   • markEvent            → positive GT from a side "Mark X" button, snapped
  //                            to the acceleration peak in a reaction-time-shifted
  //                            window instead of smeared across ±5 s of road.
  // Each also appends a queryable [RoadEvent] to the trip's event log.

  Future<void> confirmDetectorEvent(int ts, String type, {double zScore = 0.0}) =>
      _recordGroundTruth(
        ts: ts,
        rawType: type,
        source: GtSource.confirm,
        isFalse: false,
        zScore: zScore,
      );

  Future<void> rejectDetectorEvent(int ts, String type, {double zScore = 0.0}) =>
      _recordGroundTruth(
        ts: ts,
        rawType: type,
        source: GtSource.falseAlarm,
        isFalse: true,
        zScore: zScore,
      );

  /// Manual side-button mark. [pressTs] is the button-press time; the true event
  /// happened ~0.3–2.5 s earlier (reaction time). Impact marks snap the label
  /// onto the vertical-acceleration peak within that pre-press window; manoeuvre
  /// marks (lane change / turn / braking) have no vertical signature to snap to,
  /// so they anchor at the middle of the reaction window instead (v1.3.3 —
  /// offline analysis pairs them with lc_diags rows by time, so ±1 s is fine).
  Future<void> markEvent(int pressTs, String type) {
    final canonical = EventTypes.normalize(type);
    final bool manoeuvre = canonical == EventTypes.laneChange ||
        canonical == EventTypes.turn ||
        canonical == EventTypes.braking;
    if (manoeuvre) {
      final int shift = (DetectionConfig.markReactionMinMs +
              DetectionConfig.markReactionMaxMs) ~/
          2;
      return _recordGroundTruth(
        ts: pressTs - shift,
        rawType: canonical,
        source: GtSource.manual,
        isFalse: false,
      );
    }
    return _recordGroundTruth(
      ts: pressTs,
      rawType: canonical,
      source: GtSource.manual,
      isFalse: false,
      snapToPeak: true,
    );
  }

  /// Human corrected a detector alert's type (v1.3.1): e.g. the detector said
  /// concrete_joint but the driver knows it was a pothole. Records TWO ground
  /// truths at the same anchor: a NEGATIVE for [detectedType] and a POSITIVE
  /// for [correctedType]. Both use [GtSource.reclassify] so analysis can pair
  /// them, and both survive in the event log (the sample-level gt columns end
  /// up holding the corrected, positive label).
  Future<void> reclassifyDetectorEvent(
    int ts,
    String detectedType,
    String correctedType, {
    double zScore = 0.0,
  }) async {
    await _recordGroundTruth(
      ts: ts,
      rawType: detectedType,
      source: GtSource.reclassify,
      isFalse: true,
      zScore: zScore,
    );
    await _recordGroundTruth(
      ts: ts,
      rawType: correctedType,
      source: GtSource.reclassify,
      isFalse: false,
      zScore: zScore,
    );
  }

  Future<void> _recordGroundTruth({
    required int ts,
    required String rawType,
    required String source,
    required bool isFalse,
    double zScore = 0.0,
    int windowMs = 3000,
    bool snapToPeak = false,
  }) async {
    final tripId = _activeTripId;
    final canonical = EventTypes.normalize(rawType);

    final GpsSample? anchorSample =
        snapToPeak ? _peakSampleBeforePress(ts) : _nearestSample(ts, windowMs);
    final int anchor = anchorSample?.ts ?? ts;

    if (tripId != null) {
      await _db.setGroundTruth(
        tripId: tripId,
        ts: anchor,
        canonicalLabel: canonical,
        source: source,
        isFalse: isFalse,
        windowMs: windowMs,
      );
    }

    if (anchorSample != null) {
      anchorSample.gtLabel = canonical;
      anchorSample.gtSource = source;
      anchorSample.gtIsFalse = isFalse;
      // Keep the legacy user_label column populated for positive labels only.
      if (!isFalse) anchorSample.userLabel = canonical;
    }

    final ev = RoadEvent(
      ts: anchor,
      type: canonical,
      source: source,
      zScore: zScore,
      isFalse: isFalse,
      speedKmh: (anchorSample?.speed ?? 0.0) * 3.6,
      lat: anchorSample?.lat,
      lon: anchorSample?.lon,
    );
    _events.add(ev);
    if (tripId != null) {
      await _db.insertEvent(tripId: tripId, event: ev);
    }
    notifyListeners();
  }

  /// Nearest recorded sample to [ts] within [windowMs], or null.
  GpsSample? _nearestSample(int ts, int windowMs) {
    GpsSample? best;
    int bestDelta = 1 << 62;
    for (final s in _gpsSamples) {
      final d = (s.ts - ts).abs();
      if (d <= windowMs && d < bestDelta) {
        bestDelta = d;
        best = s;
      }
    }
    return best;
  }

  /// Sample with the largest |accelVal| in the reaction-time-shifted window
  /// [pressTs - markReactionMaxMs, pressTs - markReactionMinMs]; falls back to
  /// the nearest sample at/just before the press.
  GpsSample? _peakSampleBeforePress(int pressTs) {
    final int lo = pressTs - DetectionConfig.markReactionMaxMs;
    final int hi = pressTs - DetectionConfig.markReactionMinMs;
    GpsSample? peak;
    double best = -1.0;
    for (final s in _gpsSamples) {
      if (s.ts >= lo && s.ts <= hi) {
        final v = s.accelVal.abs();
        if (v > best) {
          best = v;
          peak = s;
        }
      }
    }
    peak ??= _nearestSample(pressTs, DetectionConfig.markReactionMaxMs);
    return peak;
  }

  /// Records a detector-produced event (NOT ground truth) into the event log and
  /// tags the covered in-memory samples for map display / upload.
  Future<void> _recordDetectorEvent(AnomalyEvent a) async {
    final tripId = _activeTripId;
    final canonical = EventTypes.normalize(a.type);
    final anchor = _nearestSample(a.ts, 4000);

    final ev = RoadEvent(
      ts: a.ts,
      endTs: a.endTs,
      type: canonical,
      source: GtSource.detector,
      zScore: a.zScore,
      peakG: a.peakG,
      jerk: a.jerk,
      speedKmh: a.speedKmh,
      lat: anchor?.lat,
      lon: anchor?.lon,
    );
    _events.add(ev);

    // Tag covered in-memory samples so the map + Firestore reflect the detection
    // (kept separate from any human ground truth on the same samples).
    final int start = a.ts - 1000;
    final int end = (a.endTs ?? a.ts) + 1000;
    for (final s in _gpsSamples) {
      if (s.ts >= start && s.ts <= end) {
        s.detectorLabel = canonical;
        if (canonical == EventTypes.bump) s.isBump = true;
        if (canonical == EventTypes.laneChange) s.isLaneChange = true;
      }
    }

    if (tripId != null) {
      await _db.insertEvent(tripId: tripId, event: ev);
    }
  }

  /// User tapped the screen several times quickly — a manual "something happened
  /// here / I'm interacting with the phone" marker. Logged as a canonical `tap`.
  void triggerTappingAnomaly() {
    if (!_isRecording || _gpsSamples.isEmpty) return;
    final lastSample = _gpsSamples.last;
    lastSample.isTapping = true;

    final tripId = _activeTripId;
    if (tripId != null) {
      _db.database.then((db) {
        db.update(
          'gps_samples',
          {'is_tapping': 1},
          where: 'trip_id = ? AND ts = ?',
          whereArgs: [tripId, lastSample.ts],
        );
      });
    }

    _anomalyController.add(AnomalyEvent(
      ts: lastSample.ts,
      type: EventTypes.tap,
      zScore: lastSample.zScore,
    ));

    notifyListeners();
  }

  void setFidelity(String value) {
    if (_isRecording) return;
    _fidelity = value;
    notifyListeners();
  }

  Future<void> start({
    String? replayFilePath,
    String? scenario,
    String? vehicle,
    String? mountType,
  }) async {
    if (_isRecording) return;
    _firestoreDocRef = null;
    _lastUploadedTs = 0;
    _firestoreBatchIndex = 0;
    _events.clear();

    if (replayFilePath == null) {
      final permission = await _ensurePermissions();
      if (!permission) return;
    }

    String deviceModel = 'Unknown';
    String osVersion = 'Unknown';
    if (!kIsWeb) {
      deviceModel = Platform.localHostname;
      osVersion =
          '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
    }

    final tripId = await _db.insertTrip(
      startTimeMs: DateTime.now().millisecondsSinceEpoch,
      fidelity: _fidelity,
      scenario: scenario,
      vehicle: vehicle,
      mountType: mountType,
      deviceModel: deviceModel,
      osVersion: osVersion,
    );
    _activeTripId = tripId;
    _activeScenario = scenario;
    _activeVehicle = vehicle;
    _activeMountType = mountType;
    _activeDeviceModel = deviceModel;
    _activeOsVersion = osVersion;
    _gpsSamples.clear();
    recentVibrations.value = [];
    currentVibration.value = 0.0;

    _isRecording = true;
    notifyListeners();

    WakelockPlus.enable();

    // Create Firestore trip doc in background so start() is never blocked on
    // network. The periodic flush timer won't write until _firestoreDocRef
    // is populated, so a slow init just delays the first flush slightly.
    unawaited(_initFirestoreTrip());

    // Flush new samples to Firestore every minute during the trip.
    _periodicFlushTimer = Timer.periodic(
      const Duration(seconds: _flushIntervalSeconds),
      (_) => unawaited(_periodicFirestoreFlush()),
    );

    _receivePort = ReceivePort();
    _receivePort!.listen((message) {
      if (message is IsolateDataMessage) {
        currentVibration.value = message.currentVibration;
        recentVibrations.value = message.recentVibrations;
        if (message.latestGps != null) {
          final sample = message.latestGps!;
          _gpsSamples.add(sample);
          notifyListeners();
        }
      } else if (message is IsolateAnomalyAlert) {
        final anomaly = AnomalyEvent(
          ts: message.ts,
          type: message.type,
          zScore: message.zScore,
          endTs: message.endTs,
          peakG: message.peakG,
          jerk: message.jerk,
          speedKmh: message.speedKmh,
        );
        // Persist the detector's own event (separate from any human label).
        unawaited(_recordDetectorEvent(anomaly));
        // Surface it to the UI so the driver can confirm / reject it live.
        _anomalyController.add(anomaly);
      }
    });

    _processor = SensorProcessor(
      tripId,
      _fidelity,
      _receivePort!.sendPort,
      replayFilePath,
    );
    await _processor!.start();
  }

  /// Stops recording. The UI is unblocked immediately after SQLite is updated;
  /// the Firestore finalisation runs in the background.
  Future<void> stop() async {
    if (!_isRecording) return;

    _periodicFlushTimer?.cancel();
    _periodicFlushTimer = null;
    _demoTimer?.cancel();
    _demoTimer = null;
    _isDemoMode = false;

    _processor?.stop();
    _processor = null;
    _receivePort?.close();
    _receivePort = null;

    final tripId = _activeTripId;
    _lastCompletedTripId = tripId ?? _lastCompletedTripId;
    final endTime = DateTime.now().millisecondsSinceEpoch;
    if (tripId != null) {
      await _db.endTrip(tripId: tripId, endTimeMs: endTime);
    }

    // Snapshot everything needed for background upload before clearing state.
    final firestoreDocRef = _firestoreDocRef;
    final samplesSnapshot = List<GpsSample>.from(_gpsSamples);
    final lastUploadedTs = _lastUploadedTs;
    final batchIndex = _firestoreBatchIndex;
    final fidelitySnapshot = _fidelity;
    final scenarioSnapshot = _activeScenario;
    final vehicleSnapshot = _activeVehicle;
    final mountTypeSnapshot = _activeMountType;
    final deviceModelSnapshot = _activeDeviceModel;
    final osVersionSnapshot = _activeOsVersion;

    // Clear session state and notify the UI — recording is done from the user's
    // perspective. Firestore upload continues in the background.
    _activeTripId = null;
    _activeScenario = null;
    _activeVehicle = null;
    _activeMountType = null;
    _activeDeviceModel = null;
    _activeOsVersion = null;
    _firestoreDocRef = null;
    _lastUploadedTs = 0;
    _firestoreBatchIndex = 0;
    _events.clear();
    _isRecording = false;
    notifyListeners();

    WakelockPlus.disable();

    if (tripId != null) {
      // Show the manual "Upload to Firebase" button immediately (the trip is
      // pending until finalize succeeds), then refresh again when the
      // background upload settles so the button clears itself on success.
      unawaited(refreshPendingUploadCount());
      unawaited(_finalizeFirestoreUpload(
        tripId: tripId,
        endTime: endTime,
        firestoreDocRef: firestoreDocRef,
        samples: samplesSnapshot,
        lastUploadedTs: lastUploadedTs,
        batchIndex: batchIndex,
        fidelity: fidelitySnapshot,
        scenario: scenarioSnapshot,
        vehicle: vehicleSnapshot,
        mountType: mountTypeSnapshot,
        deviceModel: deviceModelSnapshot,
        osVersion: osVersionSnapshot,
      ).then((_) => refreshPendingUploadCount()));
    }
  }

  /// Uploads every trip that never made it to Firestore, from SQLite (so it
  /// works long after the ride, across app restarts). Called once on app
  /// launch after Firebase.initializeApp(), and manually from the "Upload to
  /// Firebase" button shown after a ride (v1.3.2).
  ///
  /// Returns true when NO trips remain pending afterwards. Note that
  /// [_finalizeFirestoreUpload] swallows per-trip errors by design (the
  /// SQLite `firestore_uploaded` flag simply stays 0), so success is judged
  /// by re-counting what's left rather than by caught exceptions.
  Future<bool> retryUnuploadedTrips() async {
    if (_isRecording || _isUploading) return false;
    _isUploading = true;
    notifyListeners();
    try {
      // Rescue trips that were never closed (app killed mid-drive) so they
      // become visible to the upload query below, instead of being stranded
      // forever with a NULL end_time.
      await _db.finalizeOrphanTrips(excludeTripId: _activeTripId);
      final unuploaded = await _db.getUnuploadedTrips();
      for (final row in unuploaded) {
        final tripId = row['id'] as int;
        final sampleRows = await _db.getGpsSamples(tripId);
        final samples = sampleRows.map(GpsSample.fromRow).toList();

        if (samples.isEmpty) {
          // Nothing to upload — just clear the flag.
          await _db.markTripUploaded(tripId);
          continue;
        }

        // Reuse the trip's original Firestore doc if we recorded one, so a retry
        // updates that document instead of spawning a duplicate. If none was ever
        // stored (init failed, or a pre-v14 trip), fall back to creating one.
        final storedDocId = row['firestore_doc_id'] as String?;
        final DocumentReference? docRef = (storedDocId != null && storedDocId.isNotEmpty)
            ? FirebaseFirestore.instance.collection('trips').doc(storedDocId)
            : null;

        await _finalizeFirestoreUpload(
          tripId: tripId,
          endTime: (row['end_time'] as int?) ?? samples.last.ts,
          firestoreDocRef: docRef,
          samples: samples,
          lastUploadedTs: 0,
          batchIndex: 0,
          // Re-uploading the full trip from SQLite: wipe any partial batches/
          // events on the reused doc first so nothing stale is left behind.
          fullReupload: true,
          fidelity: (row['fidelity'] as String?) ?? 'high',
          scenario: row['scenario'] as String?,
          vehicle: row['vehicle'] as String?,
          mountType: row['mount_type'] as String?,
          deviceModel: row['device_model'] as String?,
          osVersion: row['os_version'] as String?,
        );
      }
    } catch (e) {
      debugPrint('retryUnuploadedTrips failed: $e');
    }
    _isUploading = false;
    await refreshPendingUploadCount(); // notifies listeners
    return _pendingUploadCount == 0;
  }

  // ── Private helpers ──────────────────────────────────────────────────────────

  /// Creates the Firestore trip document at recording start. Called in background.
  Future<void> _initFirestoreTrip() async {
    final tripId = _activeTripId;
    try {
      final fs = FirebaseFirestore.instance;
      final docRef = fs.collection('trips').doc();
      // Persist the doc id BEFORE the network write returns, so that even if the
      // app is killed mid-drive a later retry can find and reuse this exact doc.
      if (tripId != null) {
        await _db.setTripFirestoreDocId(tripId, docRef.id);
      }
      await docRef.set({
        'startTimeMs': DateTime.now().millisecondsSinceEpoch,
        'endTimeMs': null,
        'fidelity': _fidelity,
        'scenario': _activeScenario,
        'vehicle': _activeVehicle,
        'mountType': _activeMountType,
        'deviceModel': _activeDeviceModel,
        'osVersion': _activeOsVersion,
        'sampleCount': 0,
        'uploadComplete': false,
      });
      _firestoreDocRef = docRef;
    } catch (e) {
      debugPrint('Firestore trip init failed: $e');
      // Will be handled at stop() or by retry on next launch.
    }
  }

  /// Writes new samples accumulated since the last flush as a new batch doc.
  /// Called every [_flushIntervalSeconds] during an active recording.
  ///
  /// Mid-trip we (a) skip samples inside the privacy-trim radius of the origin
  /// and (b) hold back the most-recent [_destinationHoldbackMs] of samples so
  /// that data near the not-yet-known destination is never streamed before it
  /// can be trimmed at trip end. Labelled samples are always kept.
  Future<void> _periodicFirestoreFlush() async {
    final docRef = _firestoreDocRef;
    if (docRef == null) return; // Trip doc not ready yet.

    final all = List<GpsSample>.from(_gpsSamples);
    if (all.isEmpty) return;
    final origin = all.first;
    final int boundaryTs = all.last.ts - _destinationHoldbackMs;

    final pending = <GpsSample>[];
    int maxConsidered = _lastUploadedTs;
    for (final s in all) {
      if (s.ts <= _lastUploadedTs) continue;
      if (s.ts > boundaryTs) break; // hold back the recent tail
      maxConsidered = s.ts;
      if (_isPrivacyTrimmed(s, origin: origin, dest: null)) continue;
      pending.add(s);
    }
    if (pending.length < _flushMinNewSamples) return;

    final batchIdx = _firestoreBatchIndex;
    try {
      await docRef.collection('samples').doc('batch_$batchIdx').set({
        'batchIndex': batchIdx,
        'startTs': pending.first.ts,
        'endTs': pending.last.ts,
        'samples': pending.map(_sampleToMap).toList(),
      });
      _lastUploadedTs = maxConsidered;
      _firestoreBatchIndex = batchIdx + 1;
    } catch (e) {
      debugPrint('Periodic Firestore flush failed: $e');
      // Next timer tick will include these samples again.
    }
  }

  /// Writes any remaining samples to Firestore, uploads the queryable event log,
  /// then stamps the trip doc and marks the trip uploaded in SQLite.
  Future<void> _finalizeFirestoreUpload({
    required int tripId,
    required int endTime,
    required DocumentReference? firestoreDocRef,
    required List<GpsSample> samples,
    required int lastUploadedTs,
    required int batchIndex,
    required String fidelity,
    bool fullReupload = false,
    String? scenario,
    String? vehicle,
    String? mountType,
    String? deviceModel,
    String? osVersion,
  }) async {
    try {
      final fs = FirebaseFirestore.instance;

      // Reuse the trip's existing doc when we have one; otherwise create a new
      // one and persist its id so any later retry reuses THIS doc (idempotent).
      DocumentReference docRef;
      if (firestoreDocRef != null) {
        docRef = firestoreDocRef;
      } else {
        docRef = fs.collection('trips').doc();
        await _db.setTripFirestoreDocId(tripId, docRef.id);
      }

      // Full re-upload from SQLite (retry path): wipe any partial samples/events
      // left by an interrupted live flush or a previous failed retry, so the
      // reused doc's subcollections are rebuilt cleanly with no stale duplicates.
      if (fullReupload) {
        await _clearSubcollection(docRef, 'samples');
        await _clearSubcollection(docRef, 'events');
        await _clearSubcollection(docRef, 'lc_diag');
        await _clearSubcollection(docRef, 'impulse_diag');
      }

      // Privacy-trim the remaining (not-yet-uploaded) samples against BOTH the
      // origin and the now-known destination; labelled samples are preserved.
      final GpsSample? origin = samples.isNotEmpty ? samples.first : null;
      final GpsSample? dest = samples.isNotEmpty ? samples.last : null;
      final pending = <GpsSample>[];
      for (final s in samples) {
        if (s.ts <= lastUploadedTs) continue;
        if (origin != null &&
            _isPrivacyTrimmed(s, origin: origin, dest: dest)) {
          continue;
        }
        pending.add(s);
      }

      // Write remaining samples in chunks of 500.
      var currentBatchIdx = batchIndex;
      const chunkSize = 500;
      var i = 0;
      while (i < pending.length) {
        final end = (i + chunkSize).clamp(0, pending.length);
        final chunk = pending.sublist(i, end);
        await docRef.collection('samples').doc('batch_$currentBatchIdx').set({
          'batchIndex': currentBatchIdx,
          'startTs': chunk.first.ts,
          'endTs': chunk.last.ts,
          'samples': chunk.map(_sampleToMap).toList(),
        });
        i = end;
        currentBatchIdx++;
      }

      // Upload the discrete event log as its own queryable subcollection. We read
      // it from SQLite (the authoritative store) so that late human labels — which
      // may have landed after their sample batch was already flushed — are always
      // included. Deterministic doc IDs make this idempotent across retries.
      final eventRows = await _db.getEvents(tripId);
      for (final row in eventRows) {
        final e = RoadEvent.fromRow(row);
        final docId = '${e.ts}_${e.type}_${e.source}';
        await docRef.collection('events').doc(docId).set(e.toMap());
      }

      // Lane-change telemetry (v1.3.3): upload the state machine's per-candidate
      // diagnostics as chunked batch docs, mirroring the samples layout.
      // Deterministic doc IDs keep retries idempotent.
      final lcDiagRows = await _db.getLcDiags(tripId);
      var lcBatchIdx = 0;
      var d = 0;
      while (d < lcDiagRows.length) {
        final end = (d + chunkSize).clamp(0, lcDiagRows.length);
        final chunk = lcDiagRows.sublist(d, end);
        await docRef.collection('lc_diag').doc('batch_$lcBatchIdx').set({
          'batchIndex': lcBatchIdx,
          'rows': [
            for (final row in chunk)
              Map<String, dynamic>.from(row)
                ..remove('id')
                ..remove('trip_id'),
          ],
        });
        d = end;
        lcBatchIdx++;
      }

      // Impulse-classifier telemetry (v1.3.4): same chunked-batch layout as
      // lc_diag. This is what makes the pothole / joint / speed-bump
      // thresholds tunable offline — the event log alone cannot show impulses
      // that were classified but never alerted, nor the features of the ones
      // that a rough-patch cluster swallowed.
      final impulseDiagRows = await _db.getImpulseDiags(tripId);
      var impBatchIdx = 0;
      var imp = 0;
      while (imp < impulseDiagRows.length) {
        final end = (imp + chunkSize).clamp(0, impulseDiagRows.length);
        final chunk = impulseDiagRows.sublist(imp, end);
        await docRef.collection('impulse_diag').doc('batch_$impBatchIdx').set({
          'batchIndex': impBatchIdx,
          'rows': [
            for (final row in chunk)
              Map<String, dynamic>.from(row)
                ..remove('id')
                ..remove('trip_id'),
          ],
        });
        imp = end;
        impBatchIdx++;
      }

      // Stamp the parent doc via a MERGE set (not update): a reused doc whose
      // original init write never landed would otherwise make update() throw.
      // merge:true creates-or-updates and fills any missing metadata.
      await docRef.set({
        'startTimeMs': samples.isNotEmpty ? samples.first.ts : endTime,
        'endTimeMs': endTime,
        'fidelity': fidelity,
        'scenario': scenario,
        'vehicle': vehicle,
        'mountType': mountType,
        'deviceModel': deviceModel,
        'osVersion': osVersion,
        'sampleCount': samples.length,
        'eventCount': eventRows.length,
        'lcDiagCount': lcDiagRows.length,
        'impulseDiagCount': impulseDiagRows.length,
        'uploadComplete': true,
      }, SetOptions(merge: true));

      await _db.markTripUploaded(tripId);
    } catch (e) {
      debugPrint('Firestore finalization failed (will retry on next launch): $e');
      // firestore_uploaded stays 0 in SQLite → retryUnuploadedTrips() picks it up.
    }
  }

  /// Deletes every document in a trip doc's [name] subcollection, so a full
  /// re-upload can rebuild it from scratch without leaving stale batches/events.
  Future<void> _clearSubcollection(DocumentReference docRef, String name) async {
    final snapshot = await docRef.collection(name).get();
    for (final doc in snapshot.docs) {
      await doc.reference.delete();
    }
  }

  // ── Privacy trimming ─────────────────────────────────────────────────────────

  /// True when [s] should be withheld from upload to obscure trip origin /
  /// destination. Any sample carrying a label (human or detector) is never
  /// trimmed — losing a labelled event would defeat the point of collecting it.
  bool _isPrivacyTrimmed(
    GpsSample s, {
    required GpsSample origin,
    GpsSample? dest,
  }) {
    final bool labelled = s.gtLabel != null ||
        s.detectorLabel != null ||
        s.isBump ||
        s.isLaneChange;
    if (labelled) return false;
    final double r = DetectionConfig.trimDistanceMeters;
    final bool nearOrigin =
        _distMeters(origin.lat, origin.lon, s.lat, s.lon) < r;
    final bool nearDest = dest != null &&
        _distMeters(dest.lat, dest.lon, s.lat, s.lon) < r;
    return nearOrigin || nearDest;
  }

  static double _distMeters(double lat1, double lon1, double lat2, double lon2) {
    const double earthR = 6371000.0;
    final double dLat = (lat2 - lat1) * math.pi / 180.0;
    final double dLon = (lon2 - lon1) * math.pi / 180.0;
    final double a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1 * math.pi / 180.0) *
            math.cos(lat2 * math.pi / 180.0) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    return earthR * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  // ── Demo playback ─────────────────────────────────────────────────────────────

  /// Starts a 52-second scripted demo that exercises every anomaly banner type
  /// without GPS or sensor permissions. Pass [startLat]/[startLon] to anchor
  /// the fake route at the map's current centre; defaults to San Francisco.
  Future<void> startDemo({double? startLat, double? startLon}) async {
    if (_isRecording) return;
    _isDemoMode = true;
    _demoTick = 0;
    _demoStartLat = startLat ?? 37.773972;
    _demoStartLon = startLon ?? -122.431297;

    _gpsSamples.clear();
    recentVibrations.value = [];
    currentVibration.value = 0.0;
    _isRecording = true;
    notifyListeners();

    WakelockPlus.enable();

    // 10 Hz tick drives the sparkline; GPS samples are added every 10 ticks.
    _demoTimer = Timer.periodic(
      const Duration(milliseconds: 100),
      _onDemoTick,
    );
  }

  void _onDemoTick(Timer _) {
    final t = _demoTick++;
    final now = DateTime.now().millisecondsSinceEpoch;

    // ── Vibration & sparkline ──
    final vib = _demoVibAt(t);
    final z = _demoZAt(t);
    currentVibration.value = vib;

    final sparkSamples = List<AccelSample>.from(recentVibrations.value)
      ..add(AccelSample(now, vib, zScore: z));
    if (sparkSamples.length > 120) sparkSamples.removeAt(0);
    recentVibrations.value = sparkSamples;

    // ── GPS sample at 1 Hz ──
    if (t % 10 == 0) {
      final gpsIdx = t ~/ 10;
      // Drive north at ~60 km/h: 0.000135 deg lat per second.
      final lat = _demoStartLat + gpsIdx * 0.000135;
      final color = z > 2.0 ? 'red' : (z > 0.8 ? 'yellow' : 'green');
      _gpsSamples.add(GpsSample(
        ts: now,
        lat: lat,
        lon: _demoStartLon,
        color: color,
        accelVal: vib,
        zScore: z,
        speed: 16.7, // 60 km/h in m/s
        isLaneChange: t >= 185 && t < 205,
      ));
      notifyListeners();
    }

    // ── Scripted anomaly events ──
    //  t=55  (5.5 s) → pothole spike; banner delayed 3 s → appears at 8.5 s
    //  t=185 (18.5 s) → lane change; banner immediate
    //  t=295 (29.5 s) → speed bump spike; banner delayed 2 s → appears at 31.5 s
    //  t=385 (38.5 s) → braking; banner delayed 3 s → appears at 41.5 s
    switch (t) {
      case 55:
        _anomalyController.add(
          AnomalyEvent(ts: now, type: 'pothole', zScore: 3.5),
        );
        break;
      case 185:
        _anomalyController.add(
          AnomalyEvent(ts: now, type: 'lane_change', zScore: 1.2),
        );
        break;
      case 295:
        _anomalyController.add(
          AnomalyEvent(ts: now, type: 'speed_bump', zScore: 2.6),
        );
        break;
      case 385:
        _anomalyController.add(
          AnomalyEvent(ts: now, type: 'braking', zScore: 2.1),
        );
        break;
    }

    // Auto-stop after 52 seconds (520 ticks).
    if (t >= 520) {
      stop();
    }
  }

  // Piecewise vibration profile (m/s²). Three scripted events on a noisy baseline.
  static double _demoVibAt(int t) {
    // Pothole: sharp Gaussian spike at t=55
    final pothole = 2.6 * math.exp(-0.05 * math.pow((t - 55).toDouble(), 2));
    // Speed bump: broader Gaussian spike at t=310
    final speedBump =
        1.7 * math.exp(-0.015 * math.pow((t - 310).toDouble(), 2));
    // Rough road: sinusoidal envelope for ticks 355–435
    final roughRoad = (t >= 355 && t <= 435)
        ? 0.45 *
            (0.5 +
                math.sin(t * 0.65).abs() +
                0.4 * math.sin(t * 1.5).abs())
        : 0.0;
    // Smooth baseline noise
    final baseline = 0.08 + 0.025 * math.sin(t * 0.19).abs();
    return baseline + pothole + speedBump + roughRoad;
  }

  static double _demoZAt(int t) =>
      ((_demoVibAt(t) - 0.10) / 0.09).clamp(0.0, 4.5);

  Future<bool> _ensurePermissions() async {
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.deniedForever ||
        permission == LocationPermission.denied) {
      return false;
    }
    if (permission == LocationPermission.whileInUse) {
      permission = await Geolocator.requestPermission();
    }
    return permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse;
  }
}
