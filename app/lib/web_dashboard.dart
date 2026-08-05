import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'models.dart';

class WebDashboard extends StatefulWidget {
  const WebDashboard({super.key});

  @override
  State<WebDashboard> createState() => _WebDashboardState();
}

class _WebDashboardState extends State<WebDashboard> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final MapController _mapController = MapController();
  DateTimeRange? _selectedDateRange;

  // Loaded trip data: each entry is (trip metadata, flat list of samples).
  // Samples are now stored in a subcollection to avoid the 1 MB document limit.
  List<(Map<String, dynamic>, List<GpsSample>)> _loadedTrips = [];
  bool _loading = false;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _loadAllTrips();
  }

  /// Fetches all trip metadata documents, then for each trip fetches every
  /// sample batch from its `samples` subcollection and flattens them.
  Future<void> _loadAllTrips() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final tripsSnap = await _firestore.collection('trips').get();
      final results = <(Map<String, dynamic>, List<GpsSample>)>[];

      for (final tripDoc in tripsSnap.docs) {
        final meta = tripDoc.data();

        // Fetch all sample batches from the subcollection.
        final batchesSnap = await _firestore
            .collection('trips')
            .doc(tripDoc.id)
            .collection('samples')
            .orderBy('batchIndex')
            .get();

        final samples = <GpsSample>[];
        for (final batchDoc in batchesSnap.docs) {
          final batchData = batchDoc.data();
          final rawSamples = batchData['samples'] as List<dynamic>? ?? [];
          for (final s in rawSamples) {
            final map = s as Map<String, dynamic>;
            samples.add(GpsSample(
              ts: map['ts'] as int,
              lat: (map['lat'] as num).toDouble(),
              lon: (map['lon'] as num).toDouble(),
              color: map['color'] as String? ?? 'green',
              accelVal: (map['accelVal'] as num?)?.toDouble() ?? 0.0,
              zScore: (map['z_score'] as num?)?.toDouble() ?? 0.0,
            ));
          }
        }

        results.add((meta, samples));
      }

      setState(() {
        _loadedTrips = results;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _loadError = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _selectDateRange() async {
    final DateTimeRange? picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      initialDateRange: _selectedDateRange,
    );
    if (picked != null && picked != _selectedDateRange) {
      setState(() {
        _selectedDateRange = picked;
      });
    }
  }

  String _formatDate(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_loadError != null) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Error loading trips: $_loadError'),
              const SizedBox(height: 16),
              ElevatedButton(onPressed: _loadAllTrips, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }

    // Apply date filter to trip metadata.
    var filteredTrips = _loadedTrips;
    if (_selectedDateRange != null) {
      filteredTrips = _loadedTrips.where(((Map<String, dynamic>, List<GpsSample>) entry) {
        final startTimeMs = entry.$1['startTimeMs'] as num?;
        if (startTimeMs == null) return false;
        final tripDate = DateTime.fromMillisecondsSinceEpoch(startTimeMs.toInt());
        final start = DateTime(_selectedDateRange!.start.year, _selectedDateRange!.start.month, _selectedDateRange!.start.day);
        final end = DateTime(_selectedDateRange!.end.year, _selectedDateRange!.end.month, _selectedDateRange!.end.day, 23, 59, 59, 999);
        return tripDate.isAfter(start) && tripDate.isBefore(end);
      }).toList();
    }

    final allPolylines = <Polyline>[];
    LatLng? lastKnownCenter;

    for (final (_, samples) in filteredTrips) {
      if (samples.isNotEmpty) {
        lastKnownCenter = LatLng(samples.last.lat, samples.last.lon);
      }
      allPolylines.addAll(_buildPolylines(samples));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Road Quality Global Dashboard'),
        backgroundColor: Theme.of(context).colorScheme.primaryContainer,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Reload data',
            onPressed: _loadAllTrips,
          ),
          IconButton(
            icon: const Icon(Icons.date_range),
            tooltip: 'Filter by Date',
            onPressed: _selectDateRange,
          ),
        ],
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: lastKnownCenter ?? const LatLng(37.773972, -122.431297),
              initialZoom: 12.0,
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.pothole_finder',
              ),
              PolylineLayer(polylines: allPolylines),
            ],
          ),
          if (_selectedDateRange != null)
            Positioned(
              top: 16,
              left: 16,
              child: Card(
                color: Theme.of(context).colorScheme.surface.withOpacity(0.9),
                elevation: 4,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(30),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.date_range,
                        size: 18,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Filtered: ${_formatDate(_selectedDateRange!.start)} - ${_formatDate(_selectedDateRange!.end)}',
                        style: const TextStyle(fontWeight: FontWeight.w500),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () {
                          setState(() {
                            _selectedDateRange = null;
                          });
                        },
                        constraints: const BoxConstraints(),
                        padding: EdgeInsets.zero,
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          _mapController.move(const LatLng(37.773972, -122.431297), 12.0);
        },
        child: const Icon(Icons.center_focus_strong),
      ),
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
        return Colors.deepOrange;
      case 'red':
        return Colors.redAccent;
      default:
        return Colors.green;
    }
  }
}
