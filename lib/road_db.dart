import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'models.dart';

/// Database management layer wrapping SQLite.
///
/// Implements SQLite table configurations, indexes, data insert transactions,
/// and incremental schema upgrades.
class RoadDb {
  // Private constructor for singleton pattern.
  RoadDb._();

  /// Global singleton database instance.
  static final RoadDb instance = RoadDb._();
  Database? _db;

  /// Evidence packets (alert system v2). One row per detector event captured
  /// during a trip: an optional directory of pre/post-impact camera frames,
  /// a JSON sensor trace around the impact, and the human review verdict
  /// applied after the trip. Shared between onCreate and the v13 migration.
  static const String _createEvidenceTableSql = '''
    CREATE TABLE IF NOT EXISTS evidence (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      trip_id INTEGER NOT NULL,
      event_ts INTEGER NOT NULL,
      event_type TEXT NOT NULL,
      dir TEXT,
      frame_count INTEGER DEFAULT 0,
      impact_frame_index INTEGER DEFAULT -1,
      trace_json TEXT,
      peak_g REAL DEFAULT 0.0,
      z_score REAL DEFAULT 0.0,
      speed_kmh REAL DEFAULT 0.0,
      lat REAL,
      lon REAL,
      review_status TEXT DEFAULT 'pending',
      review_label TEXT,
      reviewed_at INTEGER,
      FOREIGN KEY (trip_id) REFERENCES trips(id)
    )
  ''';

  /// Lane-change state-machine telemetry (v1.3.3). One row per candidate
  /// manoeuvre that opened phase 1 (plus turn-vetoes), recording which gate
  /// terminated it and every quantity the machine measured — the data needed
  /// to tune the lane-change detector offline, since the 1–2 s uploaded GPS
  /// samples are far too coarse to replay a 300–4000 ms state machine.
  /// Shared between onCreate and the v15 migration.
  static const String _createLcDiagsTableSql = '''
    CREATE TABLE IF NOT EXISTS lc_diags (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      trip_id INTEGER NOT NULL,
      ts INTEGER NOT NULL,
      outcome TEXT NOT NULL,
      phase_start_ts INTEGER NOT NULL,
      phase1_ms INTEGER DEFAULT 0,
      crossover_ms INTEGER DEFAULT 0,
      phase2_ms INTEGER DEFAULT 0,
      phase1_heading_deg REAL DEFAULT 0.0,
      phase2_heading_deg REAL DEFAULT 0.0,
      phase1_lat_m REAL DEFAULT 0.0,
      phase2_lat_m REAL DEFAULT 0.0,
      peak_yaw_rads REAL DEFAULT 0.0,
      yaw_entry_rads REAL DEFAULT 0.0,
      speed_kmh REAL DEFAULT 0.0,
      FOREIGN KEY (trip_id) REFERENCES trips(id)
    )
  ''';

  /// Lazy-loaded SQLite database client.
  ///
  /// Initializes the local sqlite instance on first call. 
  /// Note: WAL (Write-Ahead Logging) is disabled in [onConfigure] to prevent 
  /// SQLite Darwin Engine error codes on macOS hosts.
  Future<Database> get database async {
    final existing = _db;
    if (existing != null) {
      return existing;
    }
    final dir = await getApplicationSupportDirectory();
    final dbPath = p.join(dir.path, 'road_quality.db');
    final db = await openDatabase(
      dbPath,
      version: 15,
      onConfigure: (db) async {
        // WAL mode removed to prevent SqfliteDarwinDatabase Code=0 error on macOS
      },
      onCreate: (db, version) async {
        // Create trips metadata table
        await db.execute('''
          CREATE TABLE trips (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            start_time INTEGER NOT NULL,
            end_time INTEGER,
            fidelity TEXT NOT NULL,
            scenario TEXT,
            vehicle TEXT,
            mount_type TEXT,
            device_model TEXT,
            os_version TEXT,
            firestore_doc_id TEXT
          )
        ''');

        // Create GPS and summarized road-roughness sample table
        await db.execute('''
          CREATE TABLE gps_samples (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            trip_id INTEGER NOT NULL,
            ts INTEGER NOT NULL,
            lat REAL NOT NULL,
            lon REAL NOT NULL,
            speed REAL,
            accuracy REAL,
            accel_color TEXT,
            accel_val REAL,
            z_score REAL DEFAULT 0.0,
            ax REAL DEFAULT 0.0,
            ay REAL DEFAULT 0.0,
            az REAL DEFAULT 0.0,
            gx REAL DEFAULT 0.0,
            gy REAL DEFAULT 0.0,
            gz REAL DEFAULT 0.0,
            user_label TEXT,
            grav_x REAL DEFAULT 0.0,
            grav_y REAL DEFAULT 0.0,
            grav_z REAL DEFAULT 0.0,
            raw_ax REAL DEFAULT 0.0,
            raw_ay REAL DEFAULT 0.0,
            raw_az REAL DEFAULT 0.0,
            altitude REAL DEFAULT 0.0,
            heading REAL DEFAULT 0.0,
            speed_accuracy REAL DEFAULT 0.0,
            heading_accuracy REAL DEFAULT 0.0,
            altitude_accuracy REAL DEFAULT 0.0,
            is_braking INTEGER DEFAULT 0,
            is_tapping INTEGER DEFAULT 0,
            is_bump INTEGER DEFAULT 0,
            is_lane_change INTEGER DEFAULT 0,
            detector_label TEXT,
            gt_label TEXT,
            gt_source TEXT,
            gt_is_false INTEGER DEFAULT 0,
            FOREIGN KEY (trip_id) REFERENCES trips(id)
          )
        ''');

        // Discrete event log — the queryable unit for analysis (v1.3.0).
        // One row per detected OR human-labelled event, kept separate from the
        // per-sample flags so human ground truth and detector output are never
        // conflated.
        await db.execute('''
          CREATE TABLE events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            trip_id INTEGER NOT NULL,
            ts INTEGER NOT NULL,
            end_ts INTEGER,
            type TEXT NOT NULL,
            source TEXT NOT NULL,
            z_score REAL DEFAULT 0.0,
            peak_g REAL DEFAULT 0.0,
            jerk REAL DEFAULT 0.0,
            speed_kmh REAL DEFAULT 0.0,
            lat REAL,
            lon REAL,
            is_false INTEGER DEFAULT 0,
            FOREIGN KEY (trip_id) REFERENCES trips(id)
          )
        ''');

        // Evidence packets (alert system v2) — one row per detector event that
        // had camera frames and/or a sensor trace captured at impact time, plus
        // the post-trip human review verdict. See DESIGN_ALERT_SYSTEM_V2.md.
        await db.execute(_createEvidenceTableSql);
        await db.execute(
          'CREATE INDEX idx_evidence_trip_status ON evidence(trip_id, review_status)',
        );

        // Create raw high-frequency accelerometer sample table (used in high fidelity)
        await db.execute('''
          CREATE TABLE accel_samples (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            trip_id INTEGER NOT NULL,
            ts INTEGER NOT NULL,
            ax REAL NOT NULL,
            ay REAL NOT NULL,
            az REAL NOT NULL,
            vert_accel REAL,
            vert_accel_smoothed REAL,
            z_score REAL DEFAULT 0.0,
            FOREIGN KEY (trip_id) REFERENCES trips(id)
          )
        ''');
        
        // Performance indexing for quick query retrievals
        await db.execute(
          'CREATE INDEX idx_gps_trip_ts ON gps_samples(trip_id, ts)',
        );
        await db.execute(
          'CREATE INDEX idx_accel_trip_ts ON accel_samples(trip_id, ts)',
        );
        await db.execute(
          'CREATE INDEX idx_events_trip_type ON events(trip_id, type)',
        );

        // Lane-change telemetry (v1.3.3).
        await db.execute(_createLcDiagsTableSql);
        await db.execute(
          'CREATE INDEX idx_lc_diags_trip_ts ON lc_diags(trip_id, ts)',
        );
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        // Schema migrations
        if (oldVersion < 2) {
          await db.execute(
            'ALTER TABLE gps_samples ADD COLUMN accel_val REAL DEFAULT 0.0',
          );
        }
        if (oldVersion < 3) {
          await db.execute(
            'ALTER TABLE gps_samples ADD COLUMN z_score REAL DEFAULT 0.0',
          );
          await db.execute(
            'ALTER TABLE accel_samples ADD COLUMN z_score REAL DEFAULT 0.0',
          );
        }
        if (oldVersion < 4) {
          await db.execute(
            'ALTER TABLE trips ADD COLUMN scenario TEXT',
          );
        }
        if (oldVersion < 5) {
          await db.execute(
            'ALTER TABLE gps_samples ADD COLUMN ax REAL DEFAULT 0.0',
          );
          await db.execute(
            'ALTER TABLE gps_samples ADD COLUMN ay REAL DEFAULT 0.0',
          );
          await db.execute(
            'ALTER TABLE gps_samples ADD COLUMN az REAL DEFAULT 0.0',
          );
        }
        if (oldVersion < 6) {
          await db.execute(
            'ALTER TABLE gps_samples ADD COLUMN gx REAL DEFAULT 0.0',
          );
          await db.execute(
            'ALTER TABLE gps_samples ADD COLUMN gy REAL DEFAULT 0.0',
          );
          await db.execute(
            'ALTER TABLE gps_samples ADD COLUMN gz REAL DEFAULT 0.0',
          );
          await db.execute(
            'ALTER TABLE gps_samples ADD COLUMN user_label TEXT',
          );
        }
        if (oldVersion < 7) {
          await db.execute('ALTER TABLE trips ADD COLUMN vehicle TEXT');
          await db.execute('ALTER TABLE trips ADD COLUMN mount_type TEXT');
          await db.execute('ALTER TABLE trips ADD COLUMN device_model TEXT');
          await db.execute('ALTER TABLE trips ADD COLUMN os_version TEXT');
          
          await db.execute('ALTER TABLE gps_samples ADD COLUMN grav_x REAL DEFAULT 0.0');
          await db.execute('ALTER TABLE gps_samples ADD COLUMN grav_y REAL DEFAULT 0.0');
          await db.execute('ALTER TABLE gps_samples ADD COLUMN grav_z REAL DEFAULT 0.0');
          await db.execute('ALTER TABLE gps_samples ADD COLUMN raw_ax REAL DEFAULT 0.0');
          await db.execute('ALTER TABLE gps_samples ADD COLUMN raw_ay REAL DEFAULT 0.0');
          await db.execute('ALTER TABLE gps_samples ADD COLUMN raw_az REAL DEFAULT 0.0');
          await db.execute('ALTER TABLE gps_samples ADD COLUMN altitude REAL DEFAULT 0.0');
          await db.execute('ALTER TABLE gps_samples ADD COLUMN heading REAL DEFAULT 0.0');
          await db.execute('ALTER TABLE gps_samples ADD COLUMN speed_accuracy REAL DEFAULT 0.0');
          await db.execute('ALTER TABLE gps_samples ADD COLUMN heading_accuracy REAL DEFAULT 0.0');
          await db.execute('ALTER TABLE gps_samples ADD COLUMN altitude_accuracy REAL DEFAULT 0.0');
        }
        if (oldVersion < 8) {
          await db.execute('ALTER TABLE gps_samples ADD COLUMN is_braking INTEGER DEFAULT 0');
          await db.execute('ALTER TABLE gps_samples ADD COLUMN is_tapping INTEGER DEFAULT 0');
        }
        if (oldVersion < 9) {
          await db.execute('ALTER TABLE gps_samples ADD COLUMN is_bump INTEGER DEFAULT 0');
        }
        if (oldVersion < 10) {
          await db.execute('ALTER TABLE gps_samples ADD COLUMN is_lane_change INTEGER DEFAULT 0');
        }
        if (oldVersion < 11) {
          await db.execute('ALTER TABLE trips ADD COLUMN firestore_uploaded INTEGER DEFAULT 0');
        }
        if (oldVersion < 12) {
          // v1.3.0: separate human ground truth from detector output, and add
          // the discrete event log.
          await db.execute('ALTER TABLE gps_samples ADD COLUMN detector_label TEXT');
          await db.execute('ALTER TABLE gps_samples ADD COLUMN gt_label TEXT');
          await db.execute('ALTER TABLE gps_samples ADD COLUMN gt_source TEXT');
          await db.execute('ALTER TABLE gps_samples ADD COLUMN gt_is_false INTEGER DEFAULT 0');
          await db.execute('''
            CREATE TABLE IF NOT EXISTS events (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              trip_id INTEGER NOT NULL,
              ts INTEGER NOT NULL,
              end_ts INTEGER,
              type TEXT NOT NULL,
              source TEXT NOT NULL,
              z_score REAL DEFAULT 0.0,
              peak_g REAL DEFAULT 0.0,
              jerk REAL DEFAULT 0.0,
              speed_kmh REAL DEFAULT 0.0,
              lat REAL,
              lon REAL,
              is_false INTEGER DEFAULT 0,
              FOREIGN KEY (trip_id) REFERENCES trips(id)
            )
          ''');
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_events_trip_type ON events(trip_id, type)',
          );
        }
        if (oldVersion < 13) {
          // Alert system v2: evidence packets + post-trip review verdicts.
          await db.execute(_createEvidenceTableSql);
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_evidence_trip_status ON evidence(trip_id, review_status)',
          );
        }
        if (oldVersion < 14) {
          // Stable Firestore trip-doc id so retries reuse ONE doc instead of
          // minting a fresh (often half-finalized) duplicate each attempt.
          await db.execute('ALTER TABLE trips ADD COLUMN firestore_doc_id TEXT');
        }
        if (oldVersion < 15) {
          // Lane-change state-machine telemetry (v1.3.3).
          await db.execute(_createLcDiagsTableSql);
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_lc_diags_trip_ts ON lc_diags(trip_id, ts)',
          );
        }
      },
    );
    _db = db;
    return db;
  }

  /// Inserts a new trip entry and returns its generated integer ID.
  Future<int> insertTrip({
    required int startTimeMs,
    required String fidelity,
    String? scenario,
    String? vehicle,
    String? mountType,
    String? deviceModel,
    String? osVersion,
  }) async {
    final db = await database;
    return db.insert('trips', {
      'start_time': startTimeMs,
      'fidelity': fidelity,
      'scenario': scenario,
      'vehicle': vehicle,
      'mount_type': mountType,
      'device_model': deviceModel,
      'os_version': osVersion,
    });
  }

  /// Updates the trip end time when the recording stops.
  Future<void> endTrip({required int tripId, required int endTimeMs}) async {
    final db = await database;
    await db.update(
      'trips',
      {'end_time': endTimeMs},
      where: 'id = ?',
      whereArgs: [tripId],
    );
  }

  /// Fetches the ID of the most recently recorded trip, or null if none exist.
  Future<int?> getLatestTripId() async {
    final db = await database;
    final rows = await db.query(
      'trips',
      columns: ['id'],
      orderBy: 'start_time DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['id'] as int;
  }

  /// Fetches metadata for all saved trips, ordered by start time descending.
  Future<List<Map<String, Object?>>> getAllTrips() async {
    final db = await database;
    return db.query('trips', orderBy: 'start_time DESC');
  }

  /// Retrieves all GPS coordinates and vibration summary samples recorded for a specific trip.
  Future<List<Map<String, Object?>>> getGpsSamples(int tripId) async {
    final db = await database;
    return db.query(
      'gps_samples',
      where: 'trip_id = ?',
      whereArgs: [tripId],
      orderBy: 'ts ASC',
    );
  }

  /// Retrieves high-frequency raw and smoothed acceleration points for offline sandbox analysis.
  Future<List<Map<String, Object?>>> getAccelSamples(int tripId) async {
    final db = await database;
    return db.query(
      'accel_samples',
      where: 'trip_id = ?',
      whereArgs: [tripId],
      orderBy: 'ts ASC',
    );
  }

  /// Inserts a GPS location data point.
  Future<void> insertGpsSample({
    required int tripId,
    required int ts,
    required double lat,
    required double lon,
    double? speed,
    double? accuracy,
    String? accelColor,
    double? accelVal,
    double? zScore,
    double? ax,
    double? ay,
    double? az,
    double? gx,
    double? gy,
    double? gz,
    String? userLabel,
    double? gravX,
    double? gravY,
    double? gravZ,
    double? rawAx,
    double? rawAy,
    double? rawAz,
    double? altitude,
    double? heading,
    double? speedAccuracy,
    double? headingAccuracy,
    double? altitudeAccuracy,
    int? isBraking,
    int? isTapping,
    int? isBump,
  }) async {
    final db = await database;
    await db.insert('gps_samples', {
      'trip_id': tripId,
      'ts': ts,
      'lat': lat,
      'lon': lon,
      'speed': speed,
      'accuracy': accuracy,
      'accel_color': accelColor,
      'accel_val': accelVal,
      'z_score': zScore,
      'ax': ax,
      'ay': ay,
      'az': az,
      'gx': gx,
      'gy': gy,
      'gz': gz,
      'user_label': userLabel,
      'grav_x': gravX,
      'grav_y': gravY,
      'grav_z': gravZ,
      'raw_ax': rawAx,
      'raw_ay': rawAy,
      'raw_az': rawAz,
      'altitude': altitude,
      'heading': heading,
      'speed_accuracy': speedAccuracy,
      'heading_accuracy': headingAccuracy,
      'altitude_accuracy': altitudeAccuracy,
      'is_braking': isBraking,
      'is_tapping': isTapping,
      'is_bump': isBump,
    });
  }

  /// Persists the stable Firestore doc id created for a trip, so a later retry
  /// reuses the same document instead of creating a duplicate.
  Future<void> setTripFirestoreDocId(int tripId, String docId) async {
    final db = await database;
    await db.update(
      'trips',
      {'firestore_doc_id': docId},
      where: 'id = ?',
      whereArgs: [tripId],
    );
  }

  /// Marks a trip's Firestore upload as complete so it is skipped on retry.
  Future<void> markTripUploaded(int tripId) async {
    final db = await database;
    await db.update(
      'trips',
      {'firestore_uploaded': 1},
      where: 'id = ?',
      whereArgs: [tripId],
    );
  }

  /// Returns all completed trips that have not yet been successfully uploaded to Firestore.
  Future<List<Map<String, Object?>>> getUnuploadedTrips() async {
    final db = await database;
    return db.query(
      'trips',
      where: 'firestore_uploaded = 0 AND end_time IS NOT NULL',
      orderBy: 'start_time ASC',
    );
  }

  /// Rescues "orphan" trips that were never closed cleanly — e.g. the app was
  /// killed mid-drive, so [endTrip] never ran and `end_time` stayed NULL. Such
  /// trips are invisible to [getUnuploadedTrips] and can never upload. This
  /// stamps each one's `end_time` from its last recorded GPS sample (falling
  /// back to `start_time` when the trip captured nothing), making it eligible
  /// for upload without altering any of its samples.
  ///
  /// [excludeTripId] guards an in-progress recording from being closed out
  /// from under the recorder. Returns the number of trips finalized.
  Future<int> finalizeOrphanTrips({int? excludeTripId}) async {
    final db = await database;
    final whereClause = StringBuffer('firestore_uploaded = 0 AND end_time IS NULL');
    final whereArgs = <Object?>[];
    if (excludeTripId != null) {
      whereClause.write(' AND id != ?');
      whereArgs.add(excludeTripId);
    }
    final orphans = await db.query(
      'trips',
      columns: ['id', 'start_time'],
      where: whereClause.toString(),
      whereArgs: whereArgs,
    );

    int finalized = 0;
    for (final t in orphans) {
      final tripId = t['id'] as int;
      final startTime = t['start_time'] as int;
      final rows = await db.rawQuery(
        'SELECT MAX(ts) AS last_ts FROM gps_samples WHERE trip_id = ?',
        [tripId],
      );
      final lastTs = rows.isNotEmpty ? rows.first['last_ts'] as int? : null;
      await db.update(
        'trips',
        {'end_time': lastTs ?? startTime},
        where: 'id = ?',
        whereArgs: [tripId],
      );
      finalized++;
    }
    return finalized;
  }

  /// Updates or sets a custom label annotation on a specific GPS sample coordinate.
  Future<void> updateGpsSampleLabel({
    required int tripId,
    required int ts,
    required String label,
  }) async {
    final db = await database;
    await db.update(
      'gps_samples',
      {'user_label': label},
      where: 'trip_id = ? AND ts = ?',
      whereArgs: [tripId, ts],
    );
  }

  /// Sets the canonical HUMAN ground-truth annotation on the single sample whose
  /// timestamp is closest to [ts] within [windowMs]. Returns the ts actually
  /// tagged (the snapped anchor), or null if no sample fell in the window.
  ///
  /// This deliberately tags ONE sample (the anchor), not a multi-second range,
  /// so label localisation is preserved for offline analysis.
  Future<int?> setGroundTruth({
    required int tripId,
    required int ts,
    required String canonicalLabel,
    required String source,
    required bool isFalse,
    int windowMs = 3000,
  }) async {
    final db = await database;
    final rows = await db.query(
      'gps_samples',
      columns: ['ts'],
      where: 'trip_id = ? AND ts >= ? AND ts <= ?',
      whereArgs: [tripId, ts - windowMs, ts + windowMs],
      orderBy: 'ts ASC',
    );
    if (rows.isEmpty) return null;
    int anchor = rows.first['ts'] as int;
    int bestDelta = (anchor - ts).abs();
    for (final r in rows) {
      final t = r['ts'] as int;
      final d = (t - ts).abs();
      if (d < bestDelta) {
        bestDelta = d;
        anchor = t;
      }
    }
    await db.update(
      'gps_samples',
      {
        'gt_label': canonicalLabel,
        'gt_source': source,
        'gt_is_false': isFalse ? 1 : 0,
      },
      where: 'trip_id = ? AND ts = ?',
      whereArgs: [tripId, anchor],
    );
    return anchor;
  }

  /// Sets the detector's own classification on the sample nearest [ts].
  Future<void> setDetectorLabel({
    required int tripId,
    required int ts,
    required String canonicalLabel,
  }) async {
    final db = await database;
    await db.update(
      'gps_samples',
      {'detector_label': canonicalLabel},
      where: 'trip_id = ? AND ts = ?',
      whereArgs: [tripId, ts],
    );
  }

  /// Inserts a discrete [RoadEvent] into the event log.
  Future<void> insertEvent({
    required int tripId,
    required RoadEvent event,
  }) async {
    final db = await database;
    await db.insert('events', {
      'trip_id': tripId,
      'ts': event.ts,
      'end_ts': event.endTs,
      'type': event.type,
      'source': event.source,
      'z_score': event.zScore,
      'peak_g': event.peakG,
      'jerk': event.jerk,
      'speed_kmh': event.speedKmh,
      'lat': event.lat,
      'lon': event.lon,
      'is_false': event.isFalse ? 1 : 0,
    });
  }

  /// Returns all lane-change telemetry rows for a trip, ordered by time.
  Future<List<Map<String, Object?>>> getLcDiags(int tripId) async {
    final db = await database;
    return db.query(
      'lc_diags',
      where: 'trip_id = ?',
      whereArgs: [tripId],
      orderBy: 'ts ASC',
    );
  }

  /// Returns all discrete events for a trip, ordered by time.
  Future<List<Map<String, Object?>>> getEvents(int tripId) async {
    final db = await database;
    return db.query(
      'events',
      where: 'trip_id = ?',
      whereArgs: [tripId],
      orderBy: 'ts ASC',
    );
  }

  /// Inserts a raw high-frequency accelerometer observation point.
  Future<void> insertAccelSample({
    required int tripId,
    required int ts,
    required double ax,
    required double ay,
    required double az,
    double? vertAccel,
    double? vertAccelSmoothed,
    double? zScore,
  }) async {
    final db = await database;
    await db.insert('accel_samples', {
      'trip_id': tripId,
      'ts': ts,
      'ax': ax,
      'ay': ay,
      'az': az,
      'vert_accel': vertAccel,
      'vert_accel_smoothed': vertAccelSmoothed,
      'z_score': zScore,
    });
  }
}
