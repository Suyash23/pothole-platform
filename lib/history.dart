import 'package:flutter/material.dart';

import 'models.dart';
import 'road_db.dart';
import 'sandbox.dart';

class TripsHistoryScreen extends StatefulWidget {
  const TripsHistoryScreen({super.key});

  @override
  State<TripsHistoryScreen> createState() => _TripsHistoryScreenState();
}

class _TripsHistoryScreenState extends State<TripsHistoryScreen> {
  late Future<List<Trip>> _tripsFuture;

  @override
  void initState() {
    super.initState();
    _tripsFuture = _loadTrips();
  }

  Future<List<Trip>> _loadTrips() async {
    final rows = await RoadDb.instance.getAllTrips();
    return rows.map(Trip.fromRow).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Trip History'),
        backgroundColor: Theme.of(context).colorScheme.primaryContainer,
      ),
      body: Column(
        children: [
          _buildLegend(),
          Expanded(
            child: FutureBuilder<List<Trip>>(
              future: _tripsFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return Center(child: Text('Error: ${snapshot.error}'));
                }

                final trips = snapshot.data ?? [];
                if (trips.isEmpty) {
                  return const Center(child: Text('No past trips found.'));
                }

                return ListView.builder(
                  itemCount: trips.length,
                  itemBuilder: (context, index) {
                    final trip = trips[index];
                    final start = DateTime.fromMillisecondsSinceEpoch(
                      trip.startTimeMs,
                    );
                    final durationStr = trip.endTimeMs != null
                        ? _formatDuration(
                            DateTime.fromMillisecondsSinceEpoch(
                              trip.endTimeMs!,
                            ).difference(start),
                          )
                        : 'In progress';

                    return FutureBuilder<List<Map<String, Object?>>>(
                      future: RoadDb.instance.getGpsSamples(trip.id),
                      builder: (context, gpsSnapshot) {
                        double minVal = 0;
                        double maxVal = 0;
                        double avgVal = 0;

                        if (gpsSnapshot.hasData &&
                            gpsSnapshot.data!.isNotEmpty) {
                          final samples = gpsSnapshot.data!
                              .map(GpsSample.fromRow)
                              .toList();
                          final vals = samples
                              .map((s) => s.zScore)
                              .where((v) => v > 0)
                              .toList();
                          if (vals.isNotEmpty) {
                            minVal = vals.reduce((a, b) => a < b ? a : b);
                            maxVal = vals.reduce((a, b) => a > b ? a : b);
                            avgVal = vals.reduce((a, b) => a + b) / vals.length;
                          }
                        }

                        return ListTile(
                          title: Text(_formatDate(start)),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Fidelity: ${trip.fidelity} | Duration: $durationStr',
                              ),
                              if (trip.scenario != null)
                                Padding(
                                  padding: const EdgeInsets.only(top: 2.0),
                                  child: Text(
                                    'Scenario: ${trip.scenario}',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: Colors.teal,
                                    ),
                                  ),
                                ),
                              if (gpsSnapshot.hasData)
                                Text(
                                  'Min: ${minVal.toStringAsFixed(2)}σ | Max: ${maxVal.toStringAsFixed(2)}σ | Avg: ${avgVal.toStringAsFixed(2)}σ',
                                ),
                            ],
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () {
                            showModalBottomSheet(
                              context: context,
                              builder: (sheetCtx) {
                                return SafeArea(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      ListTile(
                                        leading: const Icon(Icons.map),
                                        title: const Text('Load onto Map'),
                                        onTap: () {
                                          Navigator.of(sheetCtx).pop();
                                          Navigator.of(context).pop(trip.id);
                                        },
                                      ),
                                      ListTile(
                                        leading: const Icon(Icons.analytics),
                                        title: const Text('Open Algorithm Sandbox'),
                                        onTap: () {
                                          Navigator.of(sheetCtx).pop();
                                          Navigator.of(context).push(
                                            MaterialPageRoute(
                                              builder: (_) => AlgorithmSandboxScreen(
                                                tripId: trip.id,
                                                scenario: trip.scenario,
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                                    ],
                                  ),
                                );
                              },
                            );
                          },
                        );
                      },
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLegend() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      color: Colors.grey.shade200,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Z-Score Severity Legend (σ above baseline):',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _legendItem(Colors.green, '< 2σ (Smooth)'),
              const SizedBox(width: 12),
              _legendItem(Colors.amber, '2σ - 3σ (Mild)'),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _legendItem(Colors.orange, '3σ - 4σ (Moderate)'),
              const SizedBox(width: 12),
              _legendItem(Colors.redAccent, '> 4σ (Severe)'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _legendItem(Color color, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 16, height: 16, color: color),
        const SizedBox(width: 6),
        Text(text, style: const TextStyle(fontSize: 12)),
      ],
    );
  }

  String _formatDate(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds.remainder(60);
    return '${minutes}m ${seconds}s';
  }
}
