import 'dart:collection';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'models.dart';
import 'road_db.dart';

class AlgorithmSandboxScreen extends StatefulWidget {
  const AlgorithmSandboxScreen({
    super.key,
    required this.tripId,
    this.scenario,
  });

  final int tripId;
  final String? scenario;

  @override
  State<AlgorithmSandboxScreen> createState() => _AlgorithmSandboxScreenState();
}

class _AlgorithmSandboxScreenState extends State<AlgorithmSandboxScreen> {
  bool _loading = true;
  String? _error;

  late final List<Map<String, dynamic>> _rawSamples;
  final Map<String, List<double>> _smoothedVibrations = {};
  final Map<String, List<double>> _zScores = {};
  final Map<String, Map<String, dynamic>> _stats = {};

  @override
  void initState() {
    super.initState();
    _analyzeTrip();
  }

  Future<void> _analyzeTrip() async {
    try {
      final dbSamples = await RoadDb.instance.getAccelSamples(widget.tripId);
      if (dbSamples.isEmpty) {
        setState(() {
          _error = 'No accelerometer samples found for this trip. Check if the trip had active recording.';
          _loading = false;
        });
        return;
      }

      _rawSamples = dbSamples;

      // Run algorithms
      _runAlgorithm1(); // Current
      _runAlgorithm2(); // HPF
      _runAlgorithm3(); // Covariance Gating
      _runAlgorithm4(); // LPF 2.5Hz

      setState(() {
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Error loading or analyzing trip data: $e';
        _loading = false;
      });
    }
  }

  // --- HELPER METHOD TO RUN ROLLING SMOOTHING & ROLLING Z-SCORE ---
  void _processVibrationToZScores(
    String algoName,
    List<double> rawVibrations,
    List<int> timestamps,
  ) {
    final int len = rawVibrations.length;
    final List<double> smoothed = List.filled(len, 0.0);
    final List<double> zScores = List.filled(len, 0.0);

    final Queue<MapEntry<int, double>> smoothWindow = Queue();
    final Queue<MapEntry<int, double>> zScoreWindow = Queue();

    double zScoreSum = 0.0;
    double zScoreSumSq = 0.0;

    for (int i = 0; i < len; i++) {
      final ts = timestamps[i];
      final val = rawVibrations[i];

      // 1. 750ms rolling average smoothing
      smoothWindow.add(MapEntry(ts, val));
      while (smoothWindow.isNotEmpty && smoothWindow.first.key < ts - 750) {
        smoothWindow.removeFirst();
      }
      final double avg = smoothWindow.fold(0.0, (sum, entry) => sum + entry.value) / smoothWindow.length;
      smoothed[i] = avg;

      // 2. 5-minute rolling Z-score baseline
      zScoreWindow.add(MapEntry(ts, avg));
      zScoreSum += avg;
      zScoreSumSq += avg * avg;

      while (zScoreWindow.isNotEmpty && zScoreWindow.first.key < ts - 5 * 60 * 1000) {
        final evicted = zScoreWindow.removeFirst().value;
        zScoreSum -= evicted;
        zScoreSumSq -= evicted * evicted;
      }

      double z = 0.0;
      if (zScoreWindow.length > 10) {
        final mean = zScoreSum / zScoreWindow.length;
        final variance = (zScoreSumSq / zScoreWindow.length) - (mean * mean);
        final stdDev = math.sqrt(math.max(0.0, variance));
        final cappedStd = stdDev < 0.001 ? 0.001 : stdDev;
        z = (avg - mean) / cappedStd;
      }
      zScores[i] = z;
    }

    _smoothedVibrations[algoName] = smoothed;
    _zScores[algoName] = zScores;

    // Calculate statistics
    int mildCount = 0;
    int modCount = 0;
    int sevCount = 0;
    double maxZ = 0.0;
    double sumZ = 0.0;

    for (final z in zScores) {
      sumZ += z;
      if (z > maxZ) maxZ = z;
      if (z >= 4.0) {
        sevCount++;
      } else if (z >= 3.0) {
        modCount++;
      } else if (z >= 2.0) {
        mildCount++;
      }
    }

    _stats[algoName] = {
      'avgZ': sumZ / len,
      'maxZ': maxZ,
      'mild': mildCount,
      'moderate': modCount,
      'severe': sevCount,
    };
  }

  // --- ALGORITHM 1: Current Standard Z-Score ---
  void _runAlgorithm1() {
    final List<double> rawVib = [];
    final List<int> ts = [];
    for (final s in _rawSamples) {
      rawVib.add((s['vert_accel'] as num).toDouble());
      ts.add((s['ts'] as num).toInt());
    }
    _processVibrationToZScores('Standard (Z-Score)', rawVib, ts);
  }

  // --- ALGORITHM 2: High-Pass Filter (HPF) on User Accel ---
  void _runAlgorithm2() {
    final List<double> rawVib = [];
    final List<int> ts = [];

    double lastHpZ = 0.0;
    double lastAz = 0.0;

    for (int i = 0; i < _rawSamples.length; i++) {
      final s = _rawSamples[i];
      final double az = (s['az'] as num).toDouble();
      final t = (s['ts'] as num).toInt();

      // Simple first-order high pass filter
      // alpha = RC / (RC + dt). RC = 1 / (2 * pi * cutoff).
      // At 25Hz (dt = 0.04s) and 0.5Hz cutoff, alpha = 0.88
      double hpZ = 0.0;
      if (i > 0) {
        hpZ = 0.88 * (lastHpZ + az - lastAz);
      }
      lastHpZ = hpZ;
      lastAz = az;

      rawVib.add(hpZ.abs());
      ts.add(t);
    }

    _processVibrationToZScores('High-Pass Filter (0.5Hz)', rawVib, ts);
  }

  // --- ALGORITHM 3: Covariance Gating (Wobbly Mount Detector) ---
  void _runAlgorithm3() {
    final List<double> rawVib = [];
    final List<int> ts = [];

    // Rolling window of 50 samples (~2 seconds at 25Hz) to compute correlation
    final List<double> horizontalMagHistory = [];
    final List<double> verticalMagHistory = [];
    const int correlationWindowSize = 50;

    for (int i = 0; i < _rawSamples.length; i++) {
      final s = _rawSamples[i];
      final double ax = (s['ax'] as num).toDouble();
      final double ay = (s['ay'] as num).toDouble();
      final double az = (s['az'] as num).toDouble();
      final double vertAccel = (s['vert_accel'] as num).toDouble();
      final t = (s['ts'] as num).toInt();

      final double hMag = math.sqrt(ax * ax + ay * ay);
      final double vMag = az.abs();

      horizontalMagHistory.add(hMag);
      verticalMagHistory.add(vMag);

      if (horizontalMagHistory.length > correlationWindowSize) {
        horizontalMagHistory.removeAt(0);
        verticalMagHistory.removeAt(0);
      }

      double correlation = 0.0;
      if (horizontalMagHistory.length >= 10) {
        // Compute Pearson Correlation
        final double avgH = horizontalMagHistory.reduce((a, b) => a + b) / horizontalMagHistory.length;
        final double avgV = verticalMagHistory.reduce((a, b) => a + b) / verticalMagHistory.length;

        double num = 0.0;
        double denH = 0.0;
        double denV = 0.0;

        for (int k = 0; k < horizontalMagHistory.length; k++) {
          final diffH = horizontalMagHistory[k] - avgH;
          final diffV = verticalMagHistory[k] - avgV;
          num += diffH * diffV;
          denH += diffH * diffH;
          denV += diffV * diffV;
        }

        final double den = math.sqrt(denH * denV);
        if (den > 0.0001) {
          correlation = num / den;
        }
      }

      // If correlation is high, we gate/attenuate vertical vibration
      // A correlation above 0.65 suggests swinging/bobbing
      final double processedVib = correlation.abs() > 0.65 ? vertAccel * 0.1 : vertAccel;

      rawVib.add(processedVib);
      ts.add(t);
    }

    _processVibrationToZScores('Covariance Gate', rawVib, ts);
  }

  // --- ALGORITHM 4: Low-Pass Filter at 2.5Hz (Resonance Suppressor) ---
  void _runAlgorithm4() {
    final List<double> rawVib = [];
    final List<int> ts = [];

    double lastLp = 0.0;

    for (int i = 0; i < _rawSamples.length; i++) {
      final s = _rawSamples[i];
      final double vertAccel = (s['vert_accel'] as num).toDouble();
      final t = (s['ts'] as num).toInt();

      // Simple first-order low pass filter
      // beta = dt / (RC + dt). At 2.5Hz cutoff on 25Hz sampling rate, beta = 0.38
      double lp = vertAccel;
      if (i > 0) {
        lp = 0.38 * vertAccel + 0.62 * lastLp;
      }
      lastLp = lp;

      rawVib.add(lp);
      ts.add(t);
    }

    _processVibrationToZScores('Low-Pass Filter (2.5Hz)', rawVib, ts);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Algorithm Sandbox'),
        backgroundColor: Theme.of(context).colorScheme.primaryContainer,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 16)),
                  ),
                )
              : SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildHeader(),
                      _buildChartCard(),
                      _buildComparisonTable(),
                      _buildExplanationCard(),
                    ],
                  ),
                ),
    );
  }

  Widget _buildHeader() {
    return Card(
      margin: const EdgeInsets.all(12),
      color: Colors.teal.shade50,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Trip #${widget.tripId} Sandbox Analysis',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.teal),
            ),
            const SizedBox(height: 6),
            Text(
              'Scenario/Label: ${widget.scenario ?? "None (Normal)"}',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            Text(
              'Total Samples Analyzed: ${_rawSamples.length}',
              style: const TextStyle(fontSize: 13, color: Colors.black54),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChartCard() {
    // We only display the first 250 samples on chart to keep it clean and performant
    final int maxPoints = math.min(250, _rawSamples.length);
    final List<String> algos = [
      'Standard (Z-Score)',
      'High-Pass Filter (0.5Hz)',
      'Covariance Gate',
      'Low-Pass Filter (2.5Hz)'
    ];
    final Map<String, Color> algoColors = {
      'Standard (Z-Score)': Colors.red,
      'High-Pass Filter (0.5Hz)': Colors.blue,
      'Covariance Gate': Colors.green,
      'Low-Pass Filter (2.5Hz)': Colors.orange,
    };

    final List<LineChartBarData> lines = [];
    for (final algo in algos) {
      final List<FlSpot> spots = [];
      final list = _zScores[algo]!;
      for (int i = 0; i < maxPoints; i++) {
        spots.add(FlSpot(i.toDouble(), list[i]));
      }
      lines.add(
        LineChartBarData(
          spots: spots,
          isCurved: true,
          color: algoColors[algo],
          barWidth: 2,
          dotData: const FlDotData(show: false),
        ),
      );
    }

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Z-Score Baseline Comparison Chart',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            const Text(
              'Shows estimated Z-scores over time (first 250 samples)',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
            const SizedBox(height: 20),
            SizedBox(
              height: 220,
              child: LineChart(
                LineChartData(
                  minY: -1,
                  maxY: 6,
                  lineBarsData: lines,
                  titlesData: const FlTitlesData(
                    rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 22,
                        interval: 50,
                      ),
                    ),
                  ),
                  gridData: const FlGridData(show: true),
                  borderData: FlBorderData(show: true),
                ),
              ),
            ),
            const SizedBox(height: 12),
            // Legend
            Wrap(
              spacing: 12,
              runSpacing: 6,
              children: algos.map((algo) {
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(width: 12, height: 12, color: algoColors[algo]),
                    const SizedBox(width: 4),
                    Text(algo, style: const TextStyle(fontSize: 12)),
                  ],
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildComparisonTable() {
    final List<String> algos = [
      'Standard (Z-Score)',
      'High-Pass Filter (0.5Hz)',
      'Covariance Gate',
      'Low-Pass Filter (2.5Hz)'
    ];

    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Performance Statistics',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columnSpacing: 16,
                columns: const [
                  DataColumn(label: Text('Algorithm')),
                  DataColumn(label: Text('Avg Z')),
                  DataColumn(label: Text('Max Z')),
                  DataColumn(label: Text('Mild (2-3σ)')),
                  DataColumn(label: Text('Mod (3-4σ)')),
                  DataColumn(label: Text('Sev (≥4σ)')),
                ],
                rows: algos.map((algo) {
                  final stat = _stats[algo]!;
                  return DataRow(
                    cells: [
                      DataCell(Text(algo, style: const TextStyle(fontWeight: FontWeight.w600))),
                      DataCell(Text((stat['avgZ'] as double).toStringAsFixed(2))),
                      DataCell(Text((stat['maxZ'] as double).toStringAsFixed(2))),
                      DataCell(Text(stat['mild'].toString())),
                      DataCell(Text(stat['moderate'].toString())),
                      DataCell(Text(stat['severe'].toString())),
                    ],
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildExplanationCard() {
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 24),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Sandbox Analysis Guidelines',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            _bullet('Standard (Z-Score)', 'The baseline algorithm. Vulnerable to sudden wobbly mount oscillation resonance, braking deceleration, and manual device tapping.'),
            _bullet('High-Pass Filter', 'Filters slow gravity/tilting changes and sudden braking deceleration. Reduces false severe impacts from speed adjustments.'),
            _bullet('Covariance Gate', 'Tracks coupling of X/Y (swaying) and Z (bouncing). Gates output when correlation exceeds 0.65, successfully suppressing wobbly suction mounts.'),
            _bullet('Low-Pass Filter', 'Low-passes at 2.5Hz to suppress high frequency mount resonance (typically 3-8Hz) at the cost of slight delay and damping of sharp potholes.'),
          ],
        ),
      ),
    );
  }

  Widget _bullet(String title, String desc) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('• ', style: TextStyle(fontWeight: FontWeight.bold)),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: const TextStyle(color: Colors.black, fontSize: 13),
                children: [
                  TextSpan(text: '$title: ', style: const TextStyle(fontWeight: FontWeight.bold)),
                  TextSpan(text: desc),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
