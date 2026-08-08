import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'dart:async';

import 'dart:math' as math;
import 'dart:io';
import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart'; // for kIsWeb
import 'package:geolocator/geolocator.dart';
import 'package:fl_chart/fl_chart.dart';

import 'event_ui.dart';
import 'firebase_options.dart';
import 'history.dart';
import 'models.dart';
import 'recorder.dart';
import 'road_db.dart';
import 'web_dashboard.dart';
import 'package:file_picker/file_picker.dart' as fp;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await ensureSignedIn();
  runApp(const RoadQualityApp());
}

/// Signs the device in anonymously so Firestore writes carry a uid.
///
/// WHY: until 2026-08-04 the Firestore rules were `allow read, write: if true`
/// — every drive ever recorded was world-readable AND world-writable to anyone
/// holding the project id, which ships inside every copy of this app and
/// therefore cannot be kept secret. The fix is authentication, not hiding the
/// id: the rules now require a uid and scope each trip to the device that
/// created it (see firebase/firestore.rules).
///
/// Anonymous auth is used because the app has no accounts and needs none — it
/// gives each install a stable uid with no login UX. The uid persists across
/// launches (cached by the Firebase SDK) but NOT across reinstalls, so a
/// reinstalled app cannot modify its own older trips. That is the intended
/// trade: trips stay readable for analysis, and nobody can rewrite history.
///
/// Failure is deliberately NON-FATAL. Recording writes to local SQLite first
/// and uploads later, so a device that starts a drive offline still collects
/// data; the upload path retries on the next launch once sign-in succeeds.
Future<void> ensureSignedIn() async {
  try {
    if (FirebaseAuth.instance.currentUser == null) {
      await FirebaseAuth.instance.signInAnonymously();
    }
  } catch (e) {
    debugPrint('Anonymous sign-in failed (recording continues locally): $e');
  }
}

class RoadQualityApp extends StatelessWidget {
  const RoadQualityApp({super.key, this.recorder});

  /// Test-only injection point; production always uses the real recorder.
  final RoadRecorder? recorder;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Road Quality Mapper',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: kIsWeb ? const WebDashboard() : RoadQualityHome(recorder: recorder),
    );
  }
}

class RoadQualityHome extends StatefulWidget {
  const RoadQualityHome({super.key, this.recorder});

  /// Test-only injection point; production always uses the real recorder.
  final RoadRecorder? recorder;

  @override
  State<RoadQualityHome> createState() => _RoadQualityHomeState();
}

class _RoadQualityHomeState extends State<RoadQualityHome> {
  late final RoadRecorder _recorder;
  late final _AlertController _alertController;
  final MapController _mapController = MapController();
  bool _autoCenter = true;

  String _selectedScenario = 'Normal Drive';
  String _selectedVehicle = 'Tesla Model Y';
  String _selectedMount = 'Stiff Mount';

  final List<int> _tapTimestamps = [];

  @override
  void initState() {
    super.initState();
    _recorder = widget.recorder ?? RoadRecorder(RoadDb.instance);
    _alertController = _AlertController(_recorder);
    _recorder.loadLatestTrip();
    _recorder.addListener(_onRecorderChanged);
    // Show any locally-stranded trips immediately, then retry them silently.
    unawaited(_recorder.refreshPendingUploadCount());
    unawaited(_recorder.retryUnuploadedTrips());
  }

  /// Manual "Upload / retry to Firebase". Unlike the silent launch-time retry,
  /// this always tells the driver what happened — including the "nothing to
  /// sync" case, since the button is now always available. It re-scans SQLite
  /// first so a stale pending count can't produce a misleading message.
  Future<void> _manualUpload() async {
    // Rescue any never-closed trips first (app killed mid-drive), so a trip
    // with a missing end time can't hide from the count and the message.
    await _recorder.finalizeOrphanedTrips();
    await _recorder.refreshPendingUploadCount();
    final int before = _recorder.pendingUploadCount;
    final bool allUploaded = await _recorder.retryUnuploadedTrips();
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    if (before == 0) {
      messenger.showSnackBar(SnackBar(
        content: const Text('All drives are already synced to Firebase.'),
        backgroundColor: Colors.green.shade700,
      ));
    } else if (allUploaded) {
      messenger.showSnackBar(SnackBar(
        content: Text('Uploaded $before trip${before == 1 ? '' : 's'} to Firebase'),
        backgroundColor: Colors.green.shade700,
      ));
    } else {
      messenger.showSnackBar(SnackBar(
        content: Text(
            'Upload incomplete — ${_recorder.pendingUploadCount} trip'
            '${_recorder.pendingUploadCount == 1 ? '' : 's'} still pending. '
            'Data is safe on this device; check network / Firestore rules.'),
        backgroundColor: Colors.red.shade700,
        duration: const Duration(seconds: 6),
      ));
    }
  }

  @override
  void dispose() {
    _alertController.dispose();
    _recorder.removeListener(_onRecorderChanged);
    _recorder.stop();
    _recorder.dispose();
    super.dispose();
  }

  void _onRecorderChanged() {
    if (_autoCenter && _recorder.gpsSamples.isNotEmpty) {
      final lastSample = _recorder.gpsSamples.last;
      _mapController.move(
        LatLng(lastSample.lat, lastSample.lon),
        _mapController.camera.zoom,
      );
    }
  }

  /// Stops the recording. Alerts are confirmed/rejected live during the drive
  /// (see [_DetectionTicker]), so there is no post-trip review step.
  Future<void> _stop() async {
    await _recorder.stop();
  }

  void _handleScreenTap() {
    if (!_recorder.isRecording) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    _tapTimestamps.add(now);
    _tapTimestamps.removeWhere((ts) => now - ts > 1500);

    if (_tapTimestamps.length >= 4) { // 4 taps within 1.5 seconds
      _tapTimestamps.clear();
      _recorder.triggerTappingAnomaly();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _recorder,
      builder: (context, _) {
        final samples = _recorder.gpsSamples;
        final polylines = _buildPolylines(samples);
        final center = samples.isNotEmpty
            ? LatLng(samples.last.lat, samples.last.lon)
            : const LatLng(37.773972, -122.431297);

        return Scaffold(
          appBar: AppBar(
            title: const Text('Road Quality Mapper'),
            backgroundColor: Theme.of(context).colorScheme.primaryContainer,
            actions: [
              PopupMenuButton<String>(
                onSelected: (value) async {
                  if (value == 'history') {
                    final tripId = await Navigator.of(context).push<int>(
                      MaterialPageRoute(
                        builder: (_) => const TripsHistoryScreen(),
                      ),
                    );
                    if (tripId != null) {
                      _recorder.loadTrip(tripId);
                    }
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(value: 'history', child: Text('History')),
                ],
              ),
            ],
          ),
          body: Column(
            children: [
              _StatusBar(
                isRecording: _recorder.isRecording,
                currentVibration: _recorder.currentVibration,
                recentVibrations: _recorder.recentVibrations,
                recorder: _recorder,
              ),
              _DetectionTicker(controller: _alertController),
              Expanded(
                child: Stack(
                  children: [
                    Listener(
                      behavior: HitTestBehavior.translucent,
                      onPointerDown: (_) => _handleScreenTap(),
                      child: FlutterMap(
                        mapController: _mapController,
                        options: MapOptions(
                          initialCenter: center,
                          initialZoom: 14.0,
                          onPositionChanged: (position, hasGesture) {
                            if (hasGesture && _autoCenter) {
                              setState(() {
                                _autoCenter = false;
                              });
                            }
                          },
                        ),
                        children: [
                          ColorFiltered(
                            colorFilter: const ColorFilter.matrix([
                              0.2126, 0.7152, 0.0722, 0, 0,
                              0.2126, 0.7152, 0.0722, 0, 0,
                              0.2126, 0.7152, 0.0722, 0, 0,
                              0,      0,      0,      1, 0,
                            ]),
                            child: TileLayer(
                              urlTemplate:
                                  'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                              userAgentPackageName: 'com.example.pothole_finder',
                            ),
                          ),
                          PolylineLayer(polylines: polylines),
                        ],
                      ),
                    ),
                    if (_recorder.isRecording)
                      _RightSideStopButton(onStop: _stop),
                    if (_recorder.isRecording)
                      _MarkLaneChangeButton(recorder: _recorder),
                    if (_recorder.isRecording)
                      _SideCorrectionPanel(controller: _alertController),
                    if (!_recorder.isRecording)
                      _TopRightSelectorsOverlay(
                        selectedScenario: _selectedScenario,
                        selectedVehicle: _selectedVehicle,
                        selectedMount: _selectedMount,
                        onScenarioChanged: (val) {
                          setState(() {
                            _selectedScenario = val;
                          });
                        },
                        onVehicleChanged: (val) {
                          setState(() {
                            _selectedVehicle = val;
                          });
                        },
                        onMountChanged: (val) {
                          setState(() {
                            _selectedMount = val;
                          });
                        },
                      ),
                  ],
                ),
              ),
              _Controls(
                isRecording: _recorder.isRecording,
                isDemoMode: _recorder.isDemoMode,
                fidelity: _recorder.fidelity,
                pendingUploadCount: _recorder.pendingUploadCount,
                isUploading: _recorder.isUploading,
                onUpload: _manualUpload,
                onStart: () => _recorder.start(
                  scenario: _selectedScenario,
                  vehicle: _selectedVehicle,
                  mountType: _selectedMount,
                ),
                onStop: _stop,
                onFidelityChanged: _recorder.setFidelity,
                onReplaySelected: (path) => _recorder.start(replayFilePath: path),
                onDemoStart: () {
                  // Anchor the fake route at the map's current centre.
                  final lat = _recorder.gpsSamples.isNotEmpty
                      ? _recorder.gpsSamples.last.lat
                      : 37.773972;
                  final lon = _recorder.gpsSamples.isNotEmpty
                      ? _recorder.gpsSamples.last.lon
                      : -122.431297;
                  _recorder.startDemo(startLat: lat, startLon: lon);
                },
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton(
            onPressed: () async {
              setState(() {
                _autoCenter = true;
              });
              try {
                final position = await Geolocator.getCurrentPosition(
                  locationSettings: const LocationSettings(
                    accuracy: LocationAccuracy.medium,
                  ),
                );
                _mapController.move(
                  LatLng(position.latitude, position.longitude),
                  15.0,
                );
              } catch (e) {
                debugPrint('Could not get location: $e');
              }
            },
            backgroundColor: _autoCenter ? Colors.teal : null,
            foregroundColor: _autoCenter ? Colors.white : null,
            child: Icon(_autoCenter ? Icons.gps_fixed : Icons.gps_not_fixed),
          ),
        );
      },
    );
  }

  List<Polyline> _buildPolylines(List<GpsSample> samples) {
    if (samples.length < 2) return [];

    final List<List<GpsSample>> segments = [];
    List<GpsSample> currentSegment = [samples.first];

    for (int i = 1; i < samples.length; i++) {
      final prev = samples[i - 1];
      final curr = samples[i];
      
      final timeGap = curr.ts - prev.ts;
      // approximate distance: 1 deg ~ 111,000 m
      final dx = (curr.lon - prev.lon) * math.cos(prev.lat * math.pi / 180.0) * 111000.0;
      final dy = (curr.lat - prev.lat) * 111000.0;
      final distGap = math.sqrt(dx * dx + dy * dy);

      if (timeGap > 10000 || distGap > 100.0) {
        segments.add(currentSegment);
        currentSegment = [curr];
      } else {
        currentSegment.add(curr);
      }
    }
    segments.add(currentSegment);

    final List<Polyline> polylines = [];

    for (final segment in segments) {
      if (segment.length < 2) continue;

      // A3: Douglas-Peucker Decimation (epsilon ~5m)
      final decimated = _douglasPeucker(segment, 5.0);

      List<LatLng> currentPoints = [];
      String currentColor = decimated.first.color;

      for (final sample in decimated) {
        if (sample.color != currentColor && currentPoints.length >= 2) {
          polylines.add(_polylineForColor(currentPoints, currentColor));
          currentPoints = [currentPoints.last];
          currentColor = sample.color;
        }
        currentPoints.add(LatLng(sample.lat, sample.lon));
      }

      if (currentPoints.length >= 2) {
        polylines.add(_polylineForColor(currentPoints, currentColor));
      }
    }

    return polylines;
  }

  List<GpsSample> _douglasPeucker(List<GpsSample> points, double epsilon) {
    if (points.length < 3) return points;

    double dmax = 0.0;
    int index = 0;
    for (int i = 1; i < points.length - 1; i++) {
      double d = _perpendicularDistance(points[i], points.first, points.last);
      if (d > dmax) {
        index = i;
        dmax = d;
      }
    }

    if (dmax > epsilon) {
      final res1 = _douglasPeucker(points.sublist(0, index + 1), epsilon);
      final res2 = _douglasPeucker(points.sublist(index, points.length), epsilon);
      return [...res1.sublist(0, res1.length - 1), ...res2];
    } else {
      return [points.first, points.last];
    }
  }

  double _perpendicularDistance(GpsSample point, GpsSample lineStart, GpsSample lineEnd) {
    double x = point.lat;
    double y = point.lon;
    double x1 = lineStart.lat;
    double y1 = lineStart.lon;
    double x2 = lineEnd.lat;
    double y2 = lineEnd.lon;

    double num = ((y2 - y1) * x - (x2 - x1) * y + x2 * y1 - y2 * x1).abs();
    double den = math.sqrt(math.pow(y2 - y1, 2) + math.pow(x2 - x1, 2));
    if (den == 0) return 0.0;
    // approximate distance in meters (1 deg ~= 111,000 meters)
    return (num / den) * 111000.0;
  }

  Polyline _polylineForColor(List<LatLng> points, String color) {
    return Polyline(points: points, strokeWidth: 5.0, color: _mapColor(color));
  }

  Color _mapColor(String color) {
    switch (color) {
      case 'yellow':
        return Colors.amber;
      case 'orange':
        return Colors.orange;
      case 'red':
        return Colors.redAccent;
      default:
        return Colors.green;
    }
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({
    required this.isRecording,
    required this.currentVibration,
    required this.recentVibrations,
    required this.recorder,
  });

  final bool isRecording;
  final ValueNotifier<double> currentVibration;
  final ValueNotifier<List<AccelSample>> recentVibrations;
  final RoadRecorder recorder;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: isRecording
          ? Colors.red.withValues(alpha: 0.1)
          : Colors.green.withValues(alpha: 0.1),
      child: Column(
        children: [
          Text(
            isRecording ? 'Recording...' : 'Idle',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (isRecording)
            ValueListenableBuilder<double>(
              valueListenable: currentVibration,
              builder: (context, val, _) {
                return Text('Live Vibration: ${val.toStringAsFixed(2)} g');
              },
            ),
          ValueListenableBuilder<List<AccelSample>>(
            valueListenable: recentVibrations,
            builder: (context, samples, _) {
              if (!isRecording || samples.isEmpty) {
                return const SizedBox.shrink();
              }

              double maxY = 0;
              for (final s in samples) {
                if (s.vertAccel > maxY) {
                  maxY = s.vertAccel;
                }
              }
              maxY = maxY * 1.1; // Add some padding
              if (maxY < 0.1) {
                maxY = 0.1; // Ensure minimum scale so it doesn't look flat
              }

              final spots = samples.map((s) {
                final x =
                    (s.ts - samples.last.ts) /
                    1000.0; // Seconds relative to now
                return FlSpot(x, s.vertAccel);
              }).toList();

              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    height: 100,
                    padding: const EdgeInsets.only(top: 8),
                    child: LineChart(
                      LineChartData(
                        minX: -10,
                        maxX: 0,
                        minY: 0,
                        maxY: maxY,
                        lineBarsData: [
                          LineChartBarData(
                            spots: spots,
                            isCurved: false,
                            color: Colors.blueAccent,
                            barWidth: 2,
                            dotData: const FlDotData(show: false),
                          ),
                        ],
                        titlesData: const FlTitlesData(show: false),
                        borderData: FlBorderData(show: false),
                        gridData: const FlGridData(show: false),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.isRecording,
    required this.isDemoMode,
    required this.fidelity,
    required this.pendingUploadCount,
    required this.isUploading,
    required this.onUpload,
    required this.onStart,
    required this.onStop,
    required this.onFidelityChanged,
    required this.onReplaySelected,
    required this.onDemoStart,
  });

  final bool isRecording;
  final bool isDemoMode;
  final String fidelity;

  /// Completed trips not yet in Firestore; > 0 shows the upload button.
  final int pendingUploadCount;
  final bool isUploading;
  final VoidCallback onUpload;

  final VoidCallback onStart;
  final VoidCallback onStop;
  final ValueChanged<String> onFidelityChanged;
  final ValueChanged<String> onReplaySelected;
  final VoidCallback onDemoStart;

  @override
  Widget build(BuildContext context) {
    // During demo playback, show a minimal stop bar with a DEMO label.
    if (isRecording && isDemoMode) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.amber.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: Colors.amber.shade700, width: 0.5),
              ),
              child: Text(
                'DEMO',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: Colors.amber.shade800,
                  letterSpacing: 1.2,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Playing scripted demo…',
                style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.6),
                ),
              ),
            ),
            OutlinedButton(
              onPressed: onStop,
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.red,
                side: const BorderSide(color: Colors.red),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 0),
                visualDensity: VisualDensity.compact,
              ),
              child: const Text('Stop'),
            ),
          ],
        ),
      );
    }

    if (isRecording) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      child: Column(
        children: [
          // ── Manual upload / retry to Firebase ──────────────────────────
          // Always available when not recording (no longer gated on a known
          // pending count): Firestore uploads had been failing silently, and
          // the pending counter can be stale or miss a drive, so the driver
          // needs a button they can always tap to force a re-scan + upload.
          // Styling is emphasised (teal) when trips are known-pending, and
          // subdued otherwise.
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: isUploading ? null : onUpload,
              icon: isUploading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      pendingUploadCount > 0
                          ? Icons.cloud_upload_outlined
                          : Icons.sync,
                      size: 18,
                    ),
              label: Text(
                isUploading
                    ? 'Uploading…'
                    : pendingUploadCount > 0
                        ? 'Upload $pendingUploadCount trip'
                            '${pendingUploadCount == 1 ? '' : 's'} to Firebase'
                        : 'Sync / retry Firebase upload',
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: pendingUploadCount > 0
                    ? Colors.teal.shade700
                    : Colors.blueGrey,
                side: BorderSide(
                  color: pendingUploadCount > 0
                      ? Colors.teal.shade400
                      : Colors.blueGrey.shade200,
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: onStart,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Start'),
                ),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: onDemoStart,
                icon: const Icon(Icons.science_outlined, size: 18),
                label: const Text('Demo'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 0),
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'high', label: Text('High')),
              ButtonSegment(value: 'medium', label: Text('Medium')),
              ButtonSegment(value: 'low', label: Text('Low')),
            ],
            selected: {fidelity},
            onSelectionChanged: (values) {
              if (values.isEmpty) return;
              onFidelityChanged(values.first);
            },
          ),
          const SizedBox(height: 8),
          const _FidelityLegend(),
          const SizedBox(height: 16),
          GestureDetector(
            onLongPress: () async {
              _showScenarioPicker(context);
            },
            child: const Text(
              'v1.0.0',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }


  void _showScenarioPicker(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return FutureBuilder(
          future: _fetchScenarios(),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(child: Text('Error: ${snapshot.error}'));
            }
            final scenarios = snapshot.data as List<dynamic>;
            return ListView.builder(
              itemCount: scenarios.length,
              itemBuilder: (context, index) {
                final id = scenarios[index]['id'];
                return ListTile(
                  leading: const Icon(Icons.map),
                  title: Text(id.toString().toUpperCase()),
                  onTap: () async {
                    Navigator.pop(context);
                    await _simulateAndLoad(context, id);
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  Future<List<dynamic>> _fetchScenarios() async {
    final client = HttpClient();
    final request = await client.getUrl(Uri.parse('http://localhost:8000/scenarios'));
    final response = await request.close();
    final stringData = await response.transform(utf8.decoder).join();
    final jsonResponse = jsonDecode(stringData);
    return jsonResponse['scenarios'];
  }

  Future<void> _simulateAndLoad(BuildContext context, String id) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    try {
      final client = HttpClient();
      // POST simulate
      final simReq = await client.postUrl(Uri.parse('http://localhost:8000/simulate/$id'));
      final simRes = await simReq.close();
      await simRes.drain();
      
      // GET data
      final dataReq = await client.getUrl(Uri.parse('http://localhost:8000/data/$id'));
      final dataRes = await dataReq.close();
      final stringData = await dataRes.transform(utf8.decoder).join();
      
      // Save to temp file
      final Directory tempDir = await getTemporaryDirectory();
      await tempDir.create(recursive: true);
      final File file = File('${tempDir.path}/$id.json');
      await file.writeAsString(stringData);
      
      if (context.mounted) {
        Navigator.pop(context); // Close loading dialog
        onReplaySelected(file.path);
      }
    } catch (e) {
      if (context.mounted) {
        Navigator.pop(context); // Close loading dialog
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }
}

class _FidelityLegend extends StatelessWidget {
  const _FidelityLegend();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: const [
        Text('High: GPS 1 Hz, accel 100 Hz'),
        Text('Medium: GPS 0.5 Hz, accel 50 Hz'),
        Text('Low: GPS 0.2 Hz, accel 20 Hz'),
      ],
    );
  }
}

/// Shared state for the live alert flow (v1.3.4): ONE controller owns the
/// latest detector alert and its resolution, and both the top banner
/// ([_DetectionTicker]) and the right-side correction panel
/// ([_SideCorrectionPanel]) render from it — so acting in either place
/// resolves the alert everywhere and double-labelling is impossible.
class _AlertController extends ChangeNotifier {
  _AlertController(this.recorder) {
    _sub = recorder.anomalyStream.listen(_onEvent);
    recorder.addListener(_onRecorderChanged);
    _wasRecording = recorder.isRecording;
  }

  /// Recorded silently (no ticker entry): manoeuvres need no road label.
  static const Set<String> _silentTypes = {EventTypes.braking};

  /// How long an unanswered alert stays on screen before it fades. Long enough
  /// to react to while driving, short enough that it can't be confused with a
  /// later event's jolt.
  static const Duration _fadeAfter = Duration(seconds: 12);

  /// Impact types the driver can correct an alert between. ALWAYS presented in
  /// this exact order (the detected type included, highlighted) so the panel
  /// can be operated on muscle memory while driving. roughRoad included so a
  /// rough-patch alert gets the same corrections as pothole/bump/joint.
  static const List<String> correctableTypes = [
    EventTypes.pothole,
    EventTypes.bump,
    EventTypes.concreteJoint,
    EventTypes.roughRoad,
  ];

  final RoadRecorder recorder;

  AnomalyEvent? latest;
  int tripCount = 0; // detections shown this trip
  bool rejected = false;
  bool confirmed = false;
  String? correctedTo; // canonical type the driver corrected the alert to

  Timer? _fadeTimer;
  Timer? _ageTicker; // repaints the "Xs ago" label once a second
  StreamSubscription<AnomalyEvent>? _sub;
  bool _wasRecording = false;

  bool get resolved => rejected || confirmed || correctedTo != null;

  @override
  void dispose() {
    _sub?.cancel();
    recorder.removeListener(_onRecorderChanged);
    _fadeTimer?.cancel();
    _ageTicker?.cancel();
    super.dispose();
  }

  void _onRecorderChanged() {
    final recording = recorder.isRecording;
    if (recording != _wasRecording) {
      _clear(); // new trip → reset counter; trip ended → hide the alert
    }
    _wasRecording = recording;
  }

  void _clear() {
    _fadeTimer?.cancel();
    _ageTicker?.cancel();
    _ageTicker = null;
    latest = null;
    tripCount = 0;
    rejected = false;
    confirmed = false;
    correctedTo = null;
    notifyListeners();
  }

  void _onEvent(AnomalyEvent event) {
    if (!recorder.isRecording) return;
    if (_silentTypes.contains(event.type)) return;

    _fadeTimer?.cancel();
    latest = event;
    tripCount++;
    rejected = false;
    confirmed = false;
    correctedTo = null;
    _fadeTimer = Timer(_fadeAfter, () {
      latest = null;
      notifyListeners();
    });
    _ageTicker ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (latest != null) notifyListeners();
    });
    notifyListeners();
  }

  /// Briefly acknowledge, then dismiss so the UI is ready for the next alert.
  void _dismissSoon() {
    _fadeTimer?.cancel();
    _fadeTimer = Timer(const Duration(seconds: 2), () {
      latest = null;
      notifyListeners();
    });
  }

  /// Driver confirms the alert was a real event → positive ground truth.
  void confirm() {
    final e = latest;
    if (e == null || resolved) return;
    unawaited(recorder.confirmDetectorEvent(e.ts, e.type, zScore: e.zScore));
    confirmed = true;
    _dismissSoon();
    notifyListeners();
  }

  /// Driver marks the alert a false alarm → negative ground truth.
  void reject() {
    final e = latest;
    if (e == null || resolved) return;
    unawaited(recorder.rejectDetectorEvent(e.ts, e.type, zScore: e.zScore));
    rejected = true;
    _dismissSoon();
    notifyListeners();
  }

  /// Driver corrects the detected type (e.g. pothole → bump). Records a
  /// negative for the detected type + a positive for [toType] as paired ground
  /// truth. Tapping the alert's OWN type is a confirm — the side panel always
  /// shows all four types in fixed positions, so this is the expected path.
  void correct(String toType) {
    final e = latest;
    if (e == null || resolved) return;
    if (EventTypes.normalize(e.type) == toType) {
      confirm();
      return;
    }
    unawaited(
        recorder.reclassifyDetectorEvent(e.ts, e.type, toType, zScore: e.zScore));
    correctedTo = toType;
    _dismissSoon();
    notifyListeners();
  }
}

/// Real-time alert banner: shows the latest detected event with ✓ / ✗ actions
/// (confirm / false alarm). Type corrections moved to the right-side
/// [_SideCorrectionPanel] (v1.3.4) — large fixed-position text buttons are
/// glanceable while driving in a way the old icon row was not.
class _DetectionTicker extends StatelessWidget {
  const _DetectionTicker({required this.controller});
  final _AlertController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final e = controller.latest;
        if (e == null) return const SizedBox.shrink();

        final type = EventTypes.normalize(e.type);
        final Color accent = EventUi.color(type);
        final int ageSec =
            ((DateTime.now().millisecondsSinceEpoch - e.ts) / 1000)
                .round()
                .clamp(0, 999)
                .toInt();
        final String? severity = e.peakG > 0
            ? '${e.peakG.toStringAsFixed(2)} g'
            : (e.zScore > 0 ? 'z ${e.zScore.toStringAsFixed(1)}' : null);

        final bool resolved = controller.resolved;
        final String headline = controller.rejected
            ? '${EventUi.label(type)} — false alarm'
            : controller.correctedTo != null
                ? '${EventUi.label(type)} → ${EventUi.label(controller.correctedTo!)}'
                : controller.confirmed
                    ? '${EventUi.label(type)} — confirmed'
                    : EventUi.label(type);
        final Color? mutedColor = Theme.of(context)
            .textTheme
            .bodySmall
            ?.color
            ?.withValues(alpha: 0.7);

        return Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            border: Border(
              top:
                  BorderSide(color: accent.withValues(alpha: 0.25), width: 0.5),
              bottom:
                  BorderSide(color: accent.withValues(alpha: 0.25), width: 0.5),
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Icon(EventUi.icon(type), color: accent, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    style: Theme.of(context).textTheme.bodyMedium,
                    children: [
                      TextSpan(
                        text: headline,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      if (!resolved && severity != null)
                        TextSpan(
                          text: '  $severity',
                          style: TextStyle(
                              color: accent,
                              fontWeight: FontWeight.bold,
                              fontSize: 12),
                        ),
                      TextSpan(
                        text:
                            '  · ${ageSec}s ago  · #${controller.tripCount} this trip',
                        style: TextStyle(color: mutedColor, fontSize: 11),
                      ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // Live confirm / false-alarm actions. Hidden once answered.
              if (!resolved) ...[
                _AlertActionButton(
                  icon: Icons.check,
                  color: Colors.green,
                  tooltip: 'Confirm — this was a real event',
                  onTap: controller.confirm,
                ),
                const SizedBox(width: 8),
                _AlertActionButton(
                  icon: Icons.close,
                  color: Colors.red,
                  tooltip: 'False alarm',
                  onTap: controller.reject,
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// Right-side correction panel (v1.3.4): when a correctable impact alert is
/// live, the four type labels — Pothole, Bump, Joint, Rough Road — appear as
/// large TEXT buttons on the right edge, ALWAYS in that order so their
/// positions never shift between alerts. The detected type is highlighted
/// (filled); tapping it confirms, tapping any other corrects the label. Text
/// matches the status bar's 'Idle'/'Recording…' size (titleMedium).
class _SideCorrectionPanel extends StatelessWidget {
  const _SideCorrectionPanel({required this.controller});
  final _AlertController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final e = controller.latest;
        if (e == null || controller.resolved) return const SizedBox.shrink();
        final type = EventTypes.normalize(e.type);
        if (!_AlertController.correctableTypes.contains(type)) {
          return const SizedBox.shrink();
        }
        final TextStyle? base = Theme.of(context).textTheme.titleMedium;

        return Positioned(
          right: 16,
          top: 16,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final t in _AlertController.correctableTypes) ...[
                _SideCorrectionButton(
                  label: EventUi.label(t),
                  color: EventUi.color(t),
                  selected: t == type,
                  style: base,
                  onTap: () => controller.correct(t),
                ),
                const SizedBox(height: 10),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// One large text option in the side correction panel. The selected (detected)
/// type is filled; the others are outlined on a translucent surface so the map
/// stays readable behind them.
class _SideCorrectionButton extends StatelessWidget {
  const _SideCorrectionButton({
    required this.label,
    required this.color,
    required this.selected,
    required this.style,
    required this.onTap,
  });

  final String label;
  final Color color;
  final bool selected;
  final TextStyle? style;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected
          ? color
          : Theme.of(context).colorScheme.surface.withValues(alpha: 0.92),
      borderRadius: BorderRadius.circular(14),
      elevation: 3,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          // Wide and tall — the driver is glancing, not aiming.
          width: 156,
          height: 52,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: color,
              width: selected ? 0 : 1.5,
            ),
          ),
          child: Text(
            label,
            style: style?.copyWith(
              color: selected ? Colors.white : color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

/// A single tappable confirm/reject action shown on the live alert banner.
class _AlertActionButton extends StatelessWidget {
  const _AlertActionButton({
    required this.icon,
    required this.color,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          // Large tap targets — the driver is glancing, not aiming.
          width: 56,
          height: 48,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: color.withValues(alpha: 0.4)),
          ),
          child: Icon(icon, size: 26, color: color),
        ),
      ),
    );
  }
}

class _TopRightSelectorsOverlay extends StatelessWidget {
  const _TopRightSelectorsOverlay({
    required this.selectedScenario,
    required this.selectedVehicle,
    required this.selectedMount,
    required this.onScenarioChanged,
    required this.onVehicleChanged,
    required this.onMountChanged,
  });

  final String selectedScenario;
  final String selectedVehicle;
  final String selectedMount;
  final ValueChanged<String> onScenarioChanged;
  final ValueChanged<String> onVehicleChanged;
  final ValueChanged<String> onMountChanged;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 16,
      right: 16,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildOverlayButton(
            context: context,
            icon: Icons.alt_route,
            tooltip: 'Scenario: $selectedScenario',
            selectedValue: selectedScenario,
            options: ['Normal Drive', 'Sudden Braking', 'Device Tapping'],
            onChanged: onScenarioChanged,
          ),
          const SizedBox(height: 12),
          _buildOverlayButton(
            context: context,
            icon: Icons.directions_car,
            tooltip: 'Vehicle: $selectedVehicle',
            selectedValue: selectedVehicle,
            options: ['Tesla Model Y', 'Lucid Gravity'],
            onChanged: onVehicleChanged,
          ),
          const SizedBox(height: 12),
          _buildOverlayButton(
            context: context,
            icon: Icons.phone_android,
            tooltip: 'Mount: $selectedMount',
            selectedValue: selectedMount,
            options: ['Stiff Mount', 'Wobbly Mount', 'Cup Holder (No Mount)'],
            onChanged: onMountChanged,
          ),
        ],
      ),
    );
  }

  Widget _buildOverlayButton({
    required BuildContext context,
    required IconData icon,
    required String tooltip,
    required String selectedValue,
    required List<String> options,
    required ValueChanged<String> onChanged,
  }) {
    return PopupMenuButton<String>(
      initialValue: selectedValue,
      onSelected: onChanged,
      offset: const Offset(-80, 0),
      tooltip: tooltip,
      itemBuilder: (context) {
        return options.map((opt) {
          final isSelected = opt == selectedValue;
          return PopupMenuItem<String>(
            value: opt,
            child: Row(
              children: [
                if (isSelected)
                  const Icon(Icons.check, size: 18, color: Colors.teal)
                else
                  const SizedBox(width: 18),
                const SizedBox(width: 8),
                Text(
                  opt,
                  style: TextStyle(
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                    color: isSelected ? Colors.teal : null,
                  ),
                ),
              ],
            ),
          );
        }).toList();
      },
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          shape: BoxShape.circle,
          boxShadow: const [
            BoxShadow(
              color: Colors.black26,
              blurRadius: 6,
              offset: Offset(0, 3),
            ),
          ],
        ),
        child: Icon(icon, color: Theme.of(context).colorScheme.onSurface),
      ),
    );
  }
}

/// Left-side "Mark lane change" button shown while recording (v1.3.3).
///
/// The lane-change detector's MISSES are invisible without this: ground truth
/// is otherwise only captured when an alert fires, so a manoeuvre the detector
/// never saw could never be labelled — which is why, after the 2026-07-18
/// drives, there were zero confirmed-real lane changes to tune against. Tapping
/// this records positive manual ground truth (GtSource.manual, anchored ~1.4 s
/// before the press for reaction time); offline analysis pairs it with the
/// lc_diags telemetry to see which gate rejected the real manoeuvre.
class _MarkLaneChangeButton extends StatefulWidget {
  const _MarkLaneChangeButton({required this.recorder});
  final RoadRecorder recorder;

  @override
  State<_MarkLaneChangeButton> createState() => _MarkLaneChangeButtonState();
}

class _MarkLaneChangeButtonState extends State<_MarkLaneChangeButton> {
  bool _acked = false;
  Timer? _ackTimer;

  @override
  void dispose() {
    _ackTimer?.cancel();
    super.dispose();
  }

  void _mark() {
    if (_acked) return; // debounce while the ack flash is showing
    unawaited(widget.recorder.markEvent(
        DateTime.now().millisecondsSinceEpoch, EventTypes.laneChange));
    HapticFeedback.mediumImpact();
    setState(() => _acked = true);
    _ackTimer?.cancel();
    _ackTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _acked = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final Color accent = EventUi.color(EventTypes.laneChange);
    return Positioned(
      left: 16,
      // Mirrors the right-side stop button so both sit thumb-height above the
      // bottom controls without overlapping the auto-center FAB.
      bottom: 96,
      child: Tooltip(
        message: 'Mark lane change (detector missed one)',
        child: SizedBox(
          width: 64,
          height: 64,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: _acked ? Colors.green : accent,
              foregroundColor: Colors.white,
              padding: EdgeInsets.zero,
              elevation: 4,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            onPressed: _mark,
            child: Icon(
              _acked ? Icons.check : EventUi.icon(EventTypes.laneChange),
              size: 32,
            ),
          ),
        ),
      ),
    );
  }
}

/// Right-side Stop button shown while recording.
///
/// The manual event-tag buttons (pothole / bump / rough road / concrete joint)
/// were removed for now — the confirm/correct flow on the alert banner is the
/// intended way to label events. Stop stays here because it's the only stop
/// control available during a live (non-demo) recording.
class _RightSideStopButton extends StatelessWidget {
  const _RightSideStopButton({required this.onStop});
  final Future<void> Function() onStop;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: 16,
      // Sits above the auto-center FAB (56 px + 16 px margin at bottom-right)
      // so the two controls never overlap.
      bottom: 96,
      child: Tooltip(
        message: 'Stop Recording',
        child: SizedBox(
          width: 64,
          height: 64,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
              padding: EdgeInsets.zero,
              elevation: 4,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            onPressed: () => unawaited(onStop()),
            child: const Icon(Icons.stop, size: 32),
          ),
        ),
      ),
    );
  }
}


